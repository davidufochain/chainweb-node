{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module: Chainweb.Pact.Backend.SQLiteCheckpointer
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Emmanuel Denloye-Ito <emmanuel@kadena.io>
-- Stability: experimental
-- Pact SQLite checkpoint module for Chainweb
module Chainweb.Pact.Backend.SQLiteCheckpointer where

import qualified Data.Aeson as A
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Bytes.Serial hiding (store)
import qualified Data.ByteString as B
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HMS
import qualified Data.Map.Strict as M
import Data.Serialize
import Data.String

import Control.Concurrent.MVar
import Control.Exception
import Control.Lens
import Control.Monad.Catch

import GHC.Generics

import System.Directory
import System.IO.Extra

import qualified Pact.Persist as P
import qualified Pact.Persist.SQLite as P
import qualified Pact.PersistPactDb as P
import qualified Pact.Types.Logger as P
import qualified Pact.Types.Persistence as P
import qualified Pact.Types.Runtime as P
import qualified Pact.Types.Server as P

-- internal modules
import Chainweb.BlockHeader
import Chainweb.Pact.Backend.Orphans
import Chainweb.Pact.Backend.Types

initSQLiteCheckpointEnv :: P.CommandConfig -> P.Logger -> P.GasEnv -> IO CheckpointEnv
initSQLiteCheckpointEnv cmdConfig logger gasEnv = do
    inmem <- newMVar mempty
    return $
        CheckpointEnv
            { _cpeCheckpointer =
                  Checkpointer
                      { restore = restore' inmem
                      , save = save' inmem
                      }
            , _cpeCommandConfig = cmdConfig
            , _cpeLogger = logger
            , _cpeGasEnv = gasEnv
            }

type Store = HashMap (BlockHeight, BlockPayloadHash) FilePath

changeSQLFilePath ::
       FilePath
    -> (FilePath -> FilePath -> FilePath)
    -> P.SQLiteConfig
    -> P.SQLiteConfig
changeSQLFilePath fp f (P.SQLiteConfig dbFile pragmas) =
    P.SQLiteConfig (f fp dbFile) pragmas

reinitDbEnv :: P.Loggers -> P.Persister P.SQLite -> SaveData -> IO PactDbState
reinitDbEnv loggers funrec (SaveData {..}) = do
    _db <- P.initSQLite _sSQLiteConfig loggers
    return (PactDbState (EnvPersist' (PactDbEnvPersist P.pactdb (P.DbEnv {..}))) _sCommandState)
    where
    _persist = funrec
    _logger = P.newLogger loggers (fromString "<to fill with something meaningful>") -- TODO: Needs a better message
    _txRecord = _sTxRecord
    _txId = _sTxId

data SQLiteCheckpointException = RestoreNotFoundException | CheckpointDecodeException String deriving Show

instance Exception SQLiteCheckpointException

-- This should open a connection with the assumption that there is not
--  any connection open. There should be tests that assert this
--  essential aspect of the 'restore' semantics.
restore' :: MVar Store -> BlockHeight -> BlockPayloadHash -> IO PactDbState
restore' lock height hash = do
    withMVarMasked lock $ \store -> do

      case HMS.lookup (height, hash) store of

        Just cfile -> do

          let copy_c_file = "chainweb_pact_temp_" ++ cfile
          copyFile cfile copy_c_file
          cdata <- B.readFile copy_c_file >>= either (throwM . CheckpointDecodeException) return . decode

          -- create copy of the sqlite file
          let temp_c_data = over sSQLiteConfig (changeSQLFilePath "chainweb_pact_temp_" (++)) cdata

          -- Open a database connection.
          dbstate <- reinitDbEnv P.neverLog P.persister temp_c_data
          case _pdbsDbEnv dbstate of
            EnvPersist' (PactDbEnvPersist {..}) ->
              case _pdepEnv of
                P.DbEnv {..} -> openDb _db
          return dbstate
          -- need to return dbstate (should contain copy of sqlite file) copy_c_file (should contain copy of bytestring file)
        Nothing -> throwM RestoreNotFoundException

-- Prepare/Save should change the field 'dbFile' (the filename of the
-- current database) of SQLiteConfig so that the retrieval of the
-- database (referenced by the aforementioned filename) is possible in
-- a 'restore'.

-- -- prepareForValidBlock :: MVar Store -> BlockHeight -> BlockPayloadHash -> IO (Either String PactDbState)
-- prepareForValidBlock = undefined

-- prepareForNewBlock :: MVar Store -> BlockHeight -> BlockPayloadHash -> IO (Either String PactDbState)
-- prepareForNewBlock = undefined

-- This should close the database connection currently open upon
-- arrival in this function. The database should either be closed (or
-- throw an error) before departure from this function. There should
-- be tests that assert this essential aspect of the 'save' semantics.

save' :: MVar Store -> BlockHeight -> BlockPayloadHash -> PactDbState -> IO ()
save' lock height hash PactDbState {..}
 =
  case _pdbsDbEnv of
    EnvPersist' (PactDbEnvPersist {..}) ->
      case _pdepEnv of
        P.DbEnv {..} -> do
          let cfg = undefined _db  -- TODO: how?
          let savedata = SaveData _txRecord _txId cfg _pdbsState
          let serializedData = encode savedata
          preparedFileName <- prepare _db serializedData
          let serializedDataFileName = fromTempFileName preparedFileName
          modifyMVarMasked_ lock (return . HMS.insert (height, hash) serializedDataFileName)
             -- Closing database connection.
          closeDb _db
  where
    prepare = undefined
    fromTempFileName = undefined

-- save' :: MVar Store -> BlockHeight -> BlockPayloadHash -> PactDbState -> IO ()
-- save' lock height hash PactDbState {..}
--  =
--   case _pdbsDbEnv of
--     EnvPersist' (PactDbEnvPersist {..}) ->
--       case _pdepEnv of
--         P.DbEnv {..} -> do
--           let cfg = undefined _db  -- TODO: how?
--           let savedata = SaveData _txRecord _txId cfg _pdbsState
--           let serializedData = encode savedata
--           preparedFileName <- prepare _db serializedData
--           let serializedDataFileName = fromTempFileName preparedFileName
--           modifyMVarMasked_ lock (return . HMS.insert (height, hash) serializedDataFileName)
--              -- Closing database connection.
--           closeDb _db
--   where
--     prepare = undefined
--     fromTempFileName = undefined
