{-# LANGUAGE ScopedTypeVariables #-}

module HAAP.IO where

import HAAP.Core
import HAAP.Log
import HAAP.Pretty

import Control.DeepSeq as DeepSeq
import Control.Monad.IO.Class
import qualified Control.Monad.Reader as Reader
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad

import Data.Default
import Data.Text (Text(..))
import qualified Data.Text as Text
import Data.Foldable

import System.Timeout
import System.FilePath
import System.Exit
import System.Process
import System.Directory
import System.Environment

import Text.Read

import GHC.Stack

import Shelly (Sh(..))
import qualified Shelly as Sh

instance HaapMonad m => MonadIO (Haap p args db m) where
    {-# INLINE liftIO #-}
    liftIO io = runIOWith def io

data IOArgs = IOArgs
    { ioTimeout :: Maybe Int -- in seconds
    , ioSilent :: Bool -- run silently without printing to stderr or stdout
    , ioStdin :: Maybe Text -- input file or handle for processes
    , ioSandbox :: Maybe FilePath -- run inside a cabal sandbox (with given config file) or not; relative to the current path
    , ioEscaping :: Bool -- escape shell characters or not
    , ioEnv :: [(String,FilePath)] -- additional environment variables
    }

addIOEnv :: [(String,FilePath)] -> IOArgs -> IOArgs
addIOEnv xs io = io { ioEnv = ioEnv io ++ xs }

data IOResult = IOResult
    { resExitCode :: Int
    , resStdout :: Text
    , resStderr :: Text
    }

exitCode :: ExitCode -> Int
exitCode (ExitFailure i) = i
exitCode (ExitSuccess) = 0

instance Monoid IOResult where
    mempty = IOResult 0 Text.empty Text.empty
    mappend x y = IOResult
        (resExitCode x `min` resExitCode y)
        (resStdout x `Text.append` resStdout y)
        (resStdout x `Text.append` resStdout y)

instance Out IOResult where
    docPrec i x = doc x
    doc io =   text "Output:" $+$ text (Text.unpack $ resStdout io)
           $+$ text "Errors:" $+$ text (Text.unpack $ resStderr io)
           $+$ text "Exit Code:" <+> doc (resExitCode io)

defaultIOArgs :: IOArgs
defaultIOArgs = IOArgs Nothing False Nothing Nothing True []

instance Default IOArgs where
    def = defaultIOArgs

runIOWith :: HaapMonad m => (args -> IOArgs) -> IO a -> Haap p args db m a
runIOWith getArgs io = do
    args <- Reader.reader getArgs
    runIOCore args io

runIOWith' :: (HaapMonad m,NFData a) => (args -> IOArgs) -> IO a -> Haap p args db m a
runIOWith' getArgs io = forceM $ runIOWith getArgs io

runIO :: HaapMonad m => IO a -> Haap p args db m a
runIO = runIOWith (const defaultIOArgs)

runIOExit :: HaapMonad m => IO () -> Haap p args db m ExitCode
runIOExit m = runIOWith (const defaultIOArgs) (catch (m >> exitSuccess) catchExit)
    where
    catchExit :: ExitCode -> IO ExitCode
    catchExit e = return e

ioExit :: IO () -> IO ExitCode
ioExit m = catch (m >> exitSuccess) catchExit
    where
    catchExit :: ExitCode -> IO ExitCode
    catchExit e = return e

runShWith :: HaapMonad m => (args -> IOArgs) -> Sh a -> Haap p args db m a
runShWith getArgs io = do
    args <- Reader.reader getArgs
    runShCore args io

runSh :: HaapMonad m => Sh a -> Haap p args db m a
runSh = runShWith (const defaultIOArgs)

shCommand :: String -> [String] -> Sh IOResult
shCommand = shCommandWith defaultIOArgs

shCommandWith :: IOArgs -> String -> [String] -> Sh IOResult
shCommandWith ioargs name args  = do
    forM_ (ioStdin ioargs) Sh.setStdin
    forM_ (ioEnv ioargs) $ \(evar,epath) -> Sh.setenv (Text.pack evar) (Text.pack epath)
    let cmds = addTimeout (ioTimeout ioargs) $ addSandbox (ioSandbox ioargs) (name:args)
    stdout <- Sh.errExit False $ Sh.run (shFromFilePath $ head cmds) (map Text.pack $ tail cmds)
    stderr <- Sh.lastStderr
    exit <- Sh.lastExitCode
    return $ IOResult exit stdout stderr
  where
--    addEnv cmd = if ioEscaping ioargs then cmd else "env":cmd
    addTimeout Nothing cmds = cmds
    addTimeout (Just secs) cmds = ["timeout",pretty secs++"s"]++cmds
    addSandbox Nothing cmds = cmds
    addSandbox (Just cfg) cmds = ["cabal","--sandbox-config-file="++cfg,"exec","--"]++cmds

ioCommandWith :: IOArgs -> String -> [String] -> IO IOResult
ioCommandWith ioargs name args = do
    forM_ (ioEnv ioargs) $ \(evar,epath) -> setEnv evar epath
    let stdin = maybe [] Text.unpack $ ioStdin ioargs
    let cmds = addTimeout (ioTimeout ioargs) $ addSandbox (ioSandbox ioargs) (name:args)
    (exit,stdout,stderr) <- readProcessWithExitCode (head cmds) (tail cmds) stdin
    unless (ioSilent ioargs) $ do
        putStrLn $ "Running IO: " ++ unwords cmds
        putStrLn $ stderr
        putStrLn $ stdout
    return $ IOResult (exitCode exit) (Text.pack stdout) (Text.pack stderr)
  where
--    addEnv cmd = if ioEscaping ioargs then cmd else "env":cmd
    addTimeout Nothing cmds = cmds
    addTimeout (Just secs) cmds = ["timeout",pretty secs++"s"]++cmds
    addSandbox Nothing cmds = cmds
    addSandbox (Just cfg) cmds = ["cabal","--sandbox-config-file="++cfg,"exec","--"]++cmds

shPipeWith :: (Show a,Read b) => IOArgs -> String -> [String] -> a -> Sh b
shPipeWith io n args x = do
    let io' = io { ioStdin = Just $ Text.pack $ show x }
    res <- shCommandWith io' n args
    let out = Text.unpack (resStdout res)
    case readMaybe out of
        Nothing -> error $ "failed to parse pipe output: " ++ show out
        Just y -> return y

orErrorWritePage :: (HaapMonad m,Out a) => FilePath -> a -> Haap p args db m a -> Haap p args db m a
orErrorWritePage path def m = orDo go $ do
    x <- m
    ok <- orLogDefault False $ runIO $ doesFileExist path
    unless ok $ orLogDefault () $ runSh $ shWriteFile path $ pretty x
    return x
  where
    go e = do
        runIO $ writeFile path $ show e
        return def

addToError :: (HaapMonad m) => String -> Haap p args db m a -> Haap p args db m a
addToError msg m = orDo (\e -> throwError $ HaapException $ msg ++ "\n" ++ pretty e) m

haapLiftIO :: HaapMonad m => IO a -> Haap p args db m a
haapLiftIO io = Haap $ catch (liftIO io) (\(e::SomeException) -> throwError $ HaapIOException e)

runShCore :: HaapMonad m => IOArgs -> Sh a -> Haap p args db m a
runShCore args sh = case ioTimeout args of
    Nothing -> haapLiftIO io
    Just secs -> do
        mb <- haapLiftIO $ timeout (secs * 10^6) io
        case mb of
            Nothing -> throwError $ HaapTimeout callStack secs
            Just a -> return a
  where
    io = Sh.shelly $ silent $ Sh.escaping (ioEscaping args) sh
    silent = if ioSilent args then Sh.silently else Sh.verbosely

runShCoreIO :: IOArgs -> Sh a -> IO a
runShCoreIO args sh = case ioTimeout args of
    Nothing -> io
    Just secs -> do
        mb <- timeout (secs * 10^6) io
        case mb of
            Nothing -> error $ pretty $ HaapTimeout callStack secs
            Just a -> return a
  where
    io = Sh.shelly $ silent $ Sh.escaping (ioEscaping args) sh
    silent = if ioSilent args then Sh.silently else Sh.verbosely

runIOCore :: HaapMonad m => IOArgs -> IO a -> Haap p args db m a
runIOCore args io = case ioTimeout args of
    Nothing -> haapLiftIO io
    Just secs -> do
        mb <- haapLiftIO $ timeout (secs * 10^6) io
        case mb of
            Nothing -> throwError $ HaapTimeout callStack secs
            Just a -> return a

runIO' :: (HaapMonad m,NFData a) => IO a -> Haap p args db m a
runIO' = runIOWith' (const defaultIOArgs)

orMaybe :: HaapMonad m => Haap p args db m a -> Haap p args db m (Maybe a)
orMaybe m = orDo (\e -> return Nothing) (liftM Just m)

orDo :: HaapMonad m => (HaapException -> Haap p args db m a) -> Haap p args db m a -> Haap p args db m a
orDo ex m = catchError m ex

orLogDefault :: HaapMonad m => a -> Haap p args db m a -> Haap p args db m a
orLogDefault a m = orDo (\e -> logEvent (pretty e) >> return a) m

orDefault :: HaapMonad m => a -> Haap p args db m a -> Haap p args db m a
orDefault a m = orDo (\e -> return a) m

orError :: HaapMonad m => Haap p args db m a -> Haap p args db m (Either a HaapException)
orError m = orDo (return . Right) (liftM Left m)

orDo' :: (HaapMonad m,NFData a) => (HaapException -> Haap p args db m a) -> Haap p args db m a -> Haap p args db m a
orDo' ex m = catchError (forceM m) ex

ignoreError :: HaapMonad m => Haap p args db m () -> Haap p args db m ()
ignoreError m = orDo (\e -> logEvent (show e)) m

forceM :: (Monad m,NFData a) => m a -> m a
forceM m = do
    x <- m
    return $! DeepSeq.force x

shWriteFile :: FilePath -> String -> Sh ()
shWriteFile path ct = do
    Sh.mkdir_p $ shFromFilePath $ takeDirectory path
    Sh.writefile (shFromFilePath path) (Text.pack ct)

shFromFilePath :: FilePath -> Sh.FilePath
shFromFilePath = Sh.fromText . Text.pack

shToFilePath :: Sh.FilePath -> FilePath
shToFilePath = Text.unpack . Sh.toTextIgnore

shCd :: FilePath -> Sh ()
shCd = Sh.cd . shFromFilePath

shCp :: FilePath -> FilePath -> Sh ()
shCp from to = Sh.cp_r (shFromFilePath from) (shFromFilePath to)

shRm :: FilePath -> Sh ()
shRm from = Sh.rm_rf (shFromFilePath from)

shLs :: FilePath -> Sh [FilePath]
shLs = liftM (map shToFilePath) . Sh.ls . shFromFilePath

shCanonalize :: FilePath -> Sh FilePath
shCanonalize = liftM shToFilePath . Sh.canonicalize . shFromFilePath

shDoesDirectoryExist :: FilePath -> Sh Bool
shDoesDirectoryExist = Sh.test_d . shFromFilePath

shCpRecursive :: FilePath -> FilePath -> Sh ()
shCpRecursive = shRecursive shCp

shRecursive :: (FilePath -> FilePath -> Sh ()) -> FilePath -> FilePath -> Sh ()
shRecursive op from to = do
    isfromdir <- shDoesDirectoryExist from
    istodir <- shDoesDirectoryExist to
    if (isfromdir && istodir)
        then do
            froms <- shLs from
            forM_ froms $ \x -> shRecursive op (from </> x) to
        else op from to

equalPathIO :: FilePath -> FilePath -> IO Bool
equalPathIO x y = do
    x' <- canonicalizePath x
    y' <- canonicalizePath y
    return $ x' `equalFilePath` y'

equalPathSh :: FilePath -> FilePath -> Sh Bool
equalPathSh x y = do
    x' <- shCanonalize x
    y' <- shCanonalize y
    return $ equalFilePath x y

        
        
        
        
