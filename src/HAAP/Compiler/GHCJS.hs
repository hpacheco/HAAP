{-
HAAP: Haskell Automated Assessment Platform

This module provides the @GHCJS@ plugin runs the _ghcjs_ Haskell-to-JavaScript compiler.

-}


{-# LANGUAGE EmptyDataDecls, TypeOperators, GeneralizedNewtypeDeriving, TypeFamilies, UndecidableInstances, FlexibleContexts, MultiParamTypeClasses, FlexibleInstances #-}

module HAAP.Compiler.GHCJS where
    
import HAAP.Core
import HAAP.Plugin
import HAAP.Shelly
import HAAP.IO
import HAAP.Web.Hakyll
import HAAP.Pretty
import HAAP.Log
import HAAP.Utils

import Data.Default
import Data.Proxy
import Data.String

import Control.Monad.Reader as Reader
import Control.Monad.Except

import Shelly (Sh(..))
import qualified Shelly as Sh

import System.FilePath
import System.Directory
import System.Process

data GHCJS

instance HaapPlugin GHCJS where
    type PluginI GHCJS = GHCJSArgs
    type PluginT GHCJS = ReaderT GHCJSArgs
    type PluginO GHCJS = ()
    type PluginK GHCJS t m = (MonadIO m)

    usePlugin getArgs m = do
        args <- getArgs
        x <- mapHaapMonad (flip Reader.runReaderT args . unComposeT) m
        return (x,())
    
data GHCJSArgs = GHCJSArgs
    { ghcjsSafe :: Bool -- compile with the -XSafe extension
    , ghcjsArgs :: [String] -- additional flags
    , ghcjsIO :: IOArgs
    }

instance Default GHCJSArgs where
    def = GHCJSArgs True [] def

instance HaapMonad m => HasPlugin GHCJS (ReaderT GHCJSArgs) m where
    liftPlugin = id
instance (HaapStack t2 m,HaapPluginT (ReaderT GHCJSArgs) m (t2 m)) => HasPlugin GHCJS (ComposeT (ReaderT GHCJSArgs) t2) m where
    liftPlugin m = ComposeT $ hoistPluginT liftStack m

useShGhcjs :: HaapStack t Sh => GHCJSArgs -> [FilePath] -> Haap t Sh IOResult
useShGhcjs args ins = usePlugin_ (return args) (shGhcjs ins)

shGhcjs :: (HasPlugin GHCJS t Sh) => [FilePath] -> Haap t Sh IOResult
shGhcjs ins = do
    args <- liftHaap $ liftPluginProxy (Proxy::Proxy GHCJS) $ Reader.ask
    liftSh $ shGhcjsWith args ins

shGhcjsWith :: GHCJSArgs -> [FilePath] -> Sh IOResult
shGhcjsWith ghc ins = shCommandWith (ghcjsIO ghc) "ghcjs" $ addArgs (ghcjsArgs ghc) $ addSafe (ghcjsSafe ghc) ins
    where
    addSafe True cmds = "-XSafe" : cmds
    addSafe False cmds = cmds
    addArgs xs ys = ys ++ xs

useIoGhcjs :: (HaapStack t m,MonadIO m) => GHCJSArgs -> [FilePath] -> Haap t m IOResult
useIoGhcjs args ins = usePlugin_ (return args) (ioGhcjs ins)

ioGhcjs :: (MonadIO m,HasPlugin GHCJS t m) => [FilePath] -> Haap t m IOResult
ioGhcjs ins = do
    args <- liftHaap $ liftPluginProxy (Proxy::Proxy GHCJS) $ Reader.ask
    liftStack $ liftIO $ ioGhcjsWith args ins


ioGhcjsWith :: GHCJSArgs -> [FilePath] -> IO IOResult
ioGhcjsWith ghc ins = do
    ioCommandWith (ghcjsIO ghc) "ghcjs" (addArgs (ghcjsArgs ghc) $ addSafe (ghcjsSafe ghc) ins)
  where
    addSafe True cmds = "-XSafe" : cmds
    addSafe False cmds = cmds
    addArgs xs ys = ys ++ xs
    
runGhcjs :: (MonadIO m,HasPlugin Hakyll t m,HasPlugin GHCJS t m) => FilePath -> FilePath -> Haap t m FilePath
runGhcjs hsFile hmtlPath = do
    hp <- getHakyllP
    ghcjs <- liftHaap $ liftPluginProxy (Proxy::Proxy GHCJS) $ Reader.ask
    do
        tmp <- getProjectTmpPath
        -- compile files with ghcjs
        let io = ghcjsIO ghcjs
        (destdir,destfolder) <- do
                let exec = takeFileName hsFile
                let destdir = dropExtension (hmtlPath </> exec)
                let destfolder = addExtension destdir "jsexe"
                return (destdir,destfolder)
        
        res <- orIOResult $ runBaseShWith (io) $ do
                let (dir,exec) = splitFileName hsFile
                let ghcjs' = ghcjs { ghcjsArgs = ghcjsArgs ghcjs ++ ["-o",dirToRoot dir </> tmp </> destdir], ghcjsIO = io }
                Sh.mkdir_p (fromString $ tmp </> destfolder)
                shCd dir
                shGhcjsWith ghcjs' [exec]
        
        if resOk res
            then addMessageToError (pretty res) $ do
                hakyllRules $ do 
                    match (fromGlob $ tmp </> destfolder </> "*.html") $ do
                        route   $ relativeRoute tmp `composeRoutes` funRoute (hakyllRoute hp)
                        compile $ getResourceString >>= hakyllCompile hp
                    let auxFiles = fromGlob (tmp </> destfolder </> "*.js")
                                   .||. fromGlob (tmp </> destfolder </> "*.externs")
                                   .||. fromGlob (tmp </> destfolder </> "*.webapp")
                                   .||. fromGlob (tmp </> destfolder </> "*.stats")
                    match auxFiles $ do
                        route   $ relativeRoute tmp
                        compile copyFileCompiler
                    
                return (hakyllRoute hp $ destfolder </> "all.js")
            else throwError $ HaapException $ pretty res