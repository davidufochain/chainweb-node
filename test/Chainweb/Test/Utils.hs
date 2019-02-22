{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Test.Utils
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Test.Utils
(
-- * BlockHeaderDb Generation
  toyBlockHeaderDb
, toyGenesis
, withDB
, insertN
, prettyTree
, normalizeTree
, treeLeaves
, SparseTree(..)
, Growth(..)
, tree

-- * Test BlockHeaderDbs Configurations
, singleton
, peterson
, testBlockHeaderDbs
, petersonGenesisBlockHeaderDbs
, singletonGenesisBlockHeaderDbs
, linearBlockHeaderDbs
, starBlockHeaderDbs

-- * Toy Server Interaction
, withSingleChainServer

-- * Tasty TestTree Server and ClientEnv
, testHost
, TestClientEnv(..)
, pattern BlockHeaderDbsTestClientEnv
, pattern PeerDbsTestClientEnv
, withTestAppServer
, withSingleChainTestServer
, clientEnvWithSingleChainTestServer
, withBlockHeaderDbsServer
, withPeerDbsServer

-- * QuickCheck Properties
, prop_iso
, prop_iso'
, prop_encodeDecodeRoundtrip

-- * Expectations
, assertExpectation
, assertGe
, assertLe

-- * Scheduling Tests
, RunStyle(..)
, ScheduledTest
, schedule
, testCaseSch
, testGroupSch
, testPropertySch
) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception (SomeException, bracket, handle)
import Control.Lens (deep, filtered, toListOf)
import Control.Monad.IO.Class

import Data.Aeson (FromJSON, ToJSON)
import Data.Bifunctor hiding (second)
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Coerce (coerce)
import Data.Foldable
import Data.List (sortOn)
import qualified Data.Text as T
import Data.Tree
import qualified Data.Tree.Lens as LT
import Data.Word (Word64)

import qualified Network.HTTP.Client as HTTP
import Network.Socket (close)
import qualified Network.Wai as W
import qualified Network.Wai.Handler.Warp as W
import Network.Wai.Handler.WarpTLS as W (runTLSSocket)

import Numeric.Natural

import Servant.Client (BaseUrl(..), ClientEnv, Scheme(..), mkClientEnv)

import Test.QuickCheck
import Test.QuickCheck.Gen (chooseAny)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import Text.Printf (printf)

-- internal modules

import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.ChainId
import Chainweb.Crypto.MerkleLog hiding (header)
import Chainweb.Difficulty (targetToDifficulty)
import Chainweb.Graph
import Chainweb.Mempool.Mempool (MempoolBackend(..))
import Chainweb.RestAPI (singleChainApplication)
import Chainweb.RestAPI.NetworkID
import Chainweb.Test.Orphans.Internal ()
import Chainweb.Test.P2P.Peer.BootstrapConfig
    (bootstrapCertificate, bootstrapKey)
import Chainweb.Time
import Chainweb.TreeDB
import Chainweb.Utils
import Chainweb.Version (ChainwebVersion(..))

import Network.X509.SelfSigned

import Numeric.AffineSpace

import qualified P2P.Node.PeerDB as P2P

-- -------------------------------------------------------------------------- --
-- BlockHeaderDb Generation

toyVersion :: ChainwebVersion
toyVersion = Test singletonChainGraph

toyGenesis :: ChainId -> BlockHeader
toyGenesis cid = genesisBlockHeader toyVersion cid

-- | Initialize an length-1 `BlockHeaderDb` for testing purposes.
--
-- Borrowed from TrivialSync.hs
--
toyBlockHeaderDb :: ChainId -> IO (BlockHeader, BlockHeaderDb)
toyBlockHeaderDb cid = (g,) <$> initBlockHeaderDb (Configuration g)
  where
    g = toyGenesis cid

-- | Given a function that accepts a Genesis Block and
-- an initialized `BlockHeaderDb`, perform some action
-- and cleanly close the DB.
--
withDB :: ChainId -> (BlockHeader -> BlockHeaderDb -> IO ()) -> IO ()
withDB cid = bracket (toyBlockHeaderDb cid) (closeBlockHeaderDb . snd) . uncurry

-- | Populate a `TreeDb` with /n/ generated `BlockHeader`s.
--
insertN :: (TreeDb db, DbEntry db ~ BlockHeader) => Int -> BlockHeader -> db -> IO ()
insertN n g db = traverse_ (insert db) bhs
  where
    bhs = take n $ testBlockHeaders g

-- | Useful for terminal-based debugging. A @Tree BlockHeader@ can be obtained
-- from any `TreeDb` via `toTree`.
--
prettyTree :: Tree BlockHeader -> String
prettyTree = drawTree . fmap f
  where
    f h = printf "%d - %s"
              (coerce @BlockHeight @Word64 $ _blockHeight h)
              (take 12 . drop 1 . show $ _blockHash h)

normalizeTree :: Ord a => Tree a -> Tree a
normalizeTree n@(Node _ []) = n
normalizeTree (Node r f) = Node r . map normalizeTree $ sortOn rootLabel f

-- | The leaf nodes of a `Tree`.
--
treeLeaves :: Tree a -> [a]
treeLeaves = toListOf . deep $ filtered (null . subForest) . LT.root

-- | A `Tree` which doesn't branch much. The `Arbitrary` instance of this type
-- ensures that other than the main trunk, branches won't ever be much longer
-- than 4 nodes.
--
newtype SparseTree = SparseTree { _sparseTree :: Tree BlockHeader } deriving (Show)

instance Arbitrary SparseTree where
    arbitrary = SparseTree <$> tree toyVersion Randomly

-- | A specification for how the trunk of the `SparseTree` should grow.
--
data Growth = Randomly | AtMost BlockHeight deriving (Eq, Ord, Show)

-- | Randomly generate a `Tree BlockHeader` according some to `Growth` strategy.
-- The values of the tree constitute a legal chain, i.e. block heights start
-- from 0 and increment, parent hashes propagate properly, etc.
--
tree :: ChainwebVersion -> Growth -> Gen (Tree BlockHeader)
tree v g = do
    h <- genesis v
    Node h <$> forest g h

-- | Generate a sane, legal genesis block for 'Test' chainweb instance
--
genesis :: ChainwebVersion -> Gen BlockHeader
genesis v = return $ genesisBlockHeader v (testChainId 0)

forest :: Growth -> BlockHeader -> Gen (Forest BlockHeader)
forest Randomly h = randomTrunk h
forest g@(AtMost n) h | n < _blockHeight h = pure []
                      | otherwise = fixedTrunk g h

fixedTrunk :: Growth -> BlockHeader -> Gen (Forest BlockHeader)
fixedTrunk g h = frequency [ (1, sequenceA [fork h, trunk g h])
                           , (5, sequenceA [trunk g h]) ]

randomTrunk :: BlockHeader -> Gen (Forest BlockHeader)
randomTrunk h = frequency [ (2, pure [])
                          , (4, sequenceA [fork h, trunk Randomly h])
                          , (18, sequenceA [trunk Randomly h]) ]

fork :: BlockHeader -> Gen (Tree BlockHeader)
fork h = do
    next <- header h
    Node next <$> frequency [ (1, pure []), (1, sequenceA [fork next]) ]

trunk :: Growth -> BlockHeader -> Gen (Tree BlockHeader)
trunk g h = do
    next <- header h
    Node next <$> forest g next

-- | Generate some new `BlockHeader` based on a parent.
--
header :: BlockHeader -> Gen BlockHeader
header h = do
    nonce <- Nonce <$> chooseAny
    miner <- arbitrary
    return
        . fromLog
        . newMerkleLog
        $ _blockHash h
            :+: target
            :+: testBlockPayload h
            :+: BlockCreationTime (scaleTimeSpan (10 :: Int) second `add` t)
            :+: nonce
            :+: _chainId h
            :+: BlockWeight (targetToDifficulty v target) + _blockWeight h
            :+: succ (_blockHeight h)
            :+: v
            :+: miner
            :+: MerkleLogBody mempty
   where
    BlockCreationTime t = _blockCreationTime h
    target = _blockTarget h -- no difficulty adjustment
    v = _blockChainwebVersion h

-- -------------------------------------------------------------------------- --
-- Test Chain Database Configurations

peterson :: ChainGraph
peterson = petersonChainGraph

singleton :: ChainGraph
singleton = singletonChainGraph

testBlockHeaderDbs
    :: ChainwebVersion
    -> IO [(ChainId, BlockHeaderDb)]
testBlockHeaderDbs v = mapM toEntry $ toList $ chainIds_ (_chainGraph v)
  where
    toEntry c = do
        d <- db c
        return $! (c, d)
    db c = initBlockHeaderDb . Configuration $ genesisBlockHeader v c

petersonGenesisBlockHeaderDbs
    :: IO [(ChainId, BlockHeaderDb)]
petersonGenesisBlockHeaderDbs = testBlockHeaderDbs (Test petersonChainGraph)

singletonGenesisBlockHeaderDbs
    :: IO [(ChainId, BlockHeaderDb)]
singletonGenesisBlockHeaderDbs = testBlockHeaderDbs (Test singletonChainGraph)

linearBlockHeaderDbs
    :: Natural
    -> IO [(ChainId, BlockHeaderDb)]
    -> IO [(ChainId, BlockHeaderDb)]
linearBlockHeaderDbs n genDbs = do
    dbs <- genDbs
    mapM_ populateDb dbs
    return dbs
  where
    populateDb (_, db) = do
        gbh0 <- root db
        traverse_ (insert db) . take (int n) $ testBlockHeaders gbh0

starBlockHeaderDbs
    :: Natural
    -> IO [(ChainId, BlockHeaderDb)]
    -> IO [(ChainId, BlockHeaderDb)]
starBlockHeaderDbs n genDbs = do
    dbs <- genDbs
    mapM_ populateDb dbs
    return dbs
  where
    populateDb (_, db) = do
        gbh0 <- root db
        traverse_ (\i -> insert db $ newEntry i gbh0) [0 .. (int n-1)]

    newEntry i h = head $ testBlockHeadersWithNonce (Nonce i) h

-- -------------------------------------------------------------------------- --
-- Toy Server Interaction

--
-- | Spawn a server that acts as a peer node for the purpose of querying / syncing.
--
withSingleChainServer
    :: (ToJSON t, FromJSON t, Show t)
    => [(ChainId, BlockHeaderDb)]
    -> [(ChainId, MempoolBackend t)]
    -> [(NetworkId, P2P.PeerDb)]
    -> (ClientEnv -> IO a)
    -> IO a
withSingleChainServer chainDbs mempools peerDbs f = W.testWithApplication (pure app) work
  where
    app = singleChainApplication (Test singletonChainGraph) chainDbs mempools peerDbs
    work port = do
        mgr <- HTTP.newManager HTTP.defaultManagerSettings
        f $ mkClientEnv mgr (BaseUrl Http "localhost" port "")

-- -------------------------------------------------------------------------- --
-- Tasty TestTree Server and Client Environment

testHost :: String
testHost = "localhost"

data TestClientEnv t = TestClientEnv
    { _envClientEnv :: !ClientEnv
    , _envBlockHeaderDbs :: ![(ChainId, BlockHeaderDb)]
    , _envMempools :: ![(ChainId, MempoolBackend t)]
    , _envPeerDbs :: ![(NetworkId, P2P.PeerDb)]
    }

pattern BlockHeaderDbsTestClientEnv
    :: ClientEnv
    -> [(ChainId, BlockHeaderDb)]
    -> TestClientEnv t
pattern BlockHeaderDbsTestClientEnv { _cdbEnvClientEnv, _cdbEnvBlockHeaderDbs }
    = TestClientEnv _cdbEnvClientEnv _cdbEnvBlockHeaderDbs [] []

pattern PeerDbsTestClientEnv
    :: ClientEnv
    -> [(NetworkId, P2P.PeerDb)]
    -> TestClientEnv t
pattern PeerDbsTestClientEnv { _pdbEnvClientEnv, _pdbEnvPeerDbs }
    = TestClientEnv _pdbEnvClientEnv [] [] _pdbEnvPeerDbs

withTestAppServer
    :: Bool
    -> IO W.Application
    -> (Int -> IO a)
    -> (a -> IO b)
    -> IO b
withTestAppServer tls appIO envIO userFunc = bracket start stop go
  where
    v = Test singletonChainGraph
    eatExceptions = handle (\(_ :: SomeException) -> return ())
    warpOnException _ _ = return ()
    start = do
        app <- appIO
        (port, sock) <- W.openFreePort
        readyVar <- newEmptyMVar
        server <- async $ eatExceptions $ do
            let settings = W.setOnException warpOnException $
                           W.setBeforeMainLoop (putMVar readyVar ()) W.defaultSettings
            if
                | tls -> do
                    let certBytes = bootstrapCertificate v
                    let keyBytes = bootstrapKey v
                    let tlsSettings = tlsServerSettings certBytes keyBytes
                    W.runTLSSocket tlsSettings settings sock app
                | otherwise ->
                    W.runSettingsSocket settings sock app

        link server
        _ <- takeMVar readyVar
        env <- envIO port
        return (server, sock, env)
    stop (server, sock, _) = do
        uninterruptibleCancel server
        close sock
    go (_, _, env) = userFunc env


-- TODO: catch, wrap, and forward exceptions from chainwebApplication
--
withSingleChainTestServer
    :: Bool
    -> IO W.Application
    -> (Int -> IO a)
    -> (IO a -> TestTree)
    -> TestTree
withSingleChainTestServer tls appIO envIO test = withResource start stop $ \x ->
    test $ x >>= \(_, _, env) -> return env
  where
    v = Test singletonChainGraph
    start = do
        app <- appIO
        (port, sock) <- W.openFreePort
        readyVar <- newEmptyMVar
        server <- async $ do
            let settings = W.setBeforeMainLoop (putMVar readyVar ()) W.defaultSettings
            if
                | tls -> do
                    let certBytes = bootstrapCertificate v
                    let keyBytes = bootstrapKey v
                    let tlsSettings = tlsServerSettings certBytes keyBytes
                    W.runTLSSocket tlsSettings settings sock app
                | otherwise ->
                    W.runSettingsSocket settings sock app

        link server
        _ <- takeMVar readyVar
        env <- envIO port
        return (server, sock, env)

    stop (server, sock, _) = do
        uninterruptibleCancel server
        close sock

clientEnvWithSingleChainTestServer
    :: (Show t, ToJSON t, FromJSON t)
    => Bool
    -> IO [(ChainId, BlockHeaderDb)]
    -> IO [(ChainId, MempoolBackend t)]
    -> IO [(NetworkId, P2P.PeerDb)]
    -> (IO (TestClientEnv t) -> TestTree)
    -> TestTree
clientEnvWithSingleChainTestServer tls chainDbsIO mempoolsIO peerDbsIO
    = withSingleChainTestServer tls mkApp mkEnv
  where
    v = Test singletonChainGraph
    mkApp = singleChainApplication v <$> chainDbsIO <*> mempoolsIO <*> peerDbsIO
    mkEnv port = do
        mgrSettings <- if
            | tls -> certificateCacheManagerSettings TlsInsecure Nothing
            | otherwise -> return HTTP.defaultManagerSettings
        mgr <- HTTP.newManager mgrSettings
        TestClientEnv (mkClientEnv mgr (BaseUrl (if tls then Https else Http) testHost port ""))
            <$> chainDbsIO
            <*> mempoolsIO
            <*> peerDbsIO


withPeerDbsServer
    :: (Show t, FromJSON t, ToJSON t)
    => Bool
    -> IO [(NetworkId, P2P.PeerDb)]
    -> (IO (TestClientEnv t) -> TestTree)
    -> TestTree
withPeerDbsServer tls = clientEnvWithSingleChainTestServer tls (return []) (return [])

withBlockHeaderDbsServer
    :: (Show t, FromJSON t, ToJSON t)
    => Bool
    -> IO [(ChainId, BlockHeaderDb)]
    -> IO [(ChainId, MempoolBackend t)]
    -> (IO (TestClientEnv t) -> TestTree)
    -> TestTree
withBlockHeaderDbsServer tls chainDbsIO mempoolsIO
    = clientEnvWithSingleChainTestServer tls chainDbsIO mempoolsIO (return [])

-- -------------------------------------------------------------------------- --
-- Isomorphisms and Roundtrips

prop_iso :: Eq a => Show a => (b -> a) -> (a -> b) -> a -> Property
prop_iso d e a = a === d (e a)

prop_iso'
    :: Show e
    => Eq a
    => Show a
    => (b -> Either e a)
    -> (a -> b)
    -> a
    -> Property
prop_iso' d e a = Right a === first show (d (e a))

prop_encodeDecodeRoundtrip
    :: Eq a
    => Show a
    => (forall m . MonadGet m => m a)
    -> (forall m . MonadPut m => a -> m ())
    -> a
    -> Property
prop_encodeDecodeRoundtrip d e = prop_iso' (runGetEither d) (runPutS . e)

-- -------------------------------------------------------------------------- --
-- Expectations

-- | Assert that the actual value equals the expected value
--
assertExpectation
    :: MonadIO m
    => Eq a
    => Show a
    => T.Text
    -> Expected a
    -> Actual a
    -> m ()
assertExpectation msg expected actual = liftIO $ assertBool
    (T.unpack $ unexpectedMsg msg expected actual)
    (getExpected expected == getActual actual)

-- | Assert that the actual value is smaller or equal than the expected value
--
assertLe
    :: Show a
    => Ord a
    => T.Text
    -> Actual a
    -> Expected a
    -> Assertion
assertLe msg actual expected = assertBool msg_
    (getActual actual <= getExpected expected)
  where
    msg_ = T.unpack msg
        <> ", expected: <= " <> show (getExpected expected)
        <> ", actual: " <> show (getActual actual)

-- | Assert that the actual value is greater or equal than the expected value
--
assertGe
    :: Show a
    => Ord a
    => T.Text
    -> Actual a
    -> Expected a
    -> Assertion
assertGe msg actual expected = assertBool msg_
    (getActual actual >= getExpected expected)
  where
    msg_ = T.unpack msg
        <> ", expected: >= " <> show (getExpected expected)
        <> ", actual: " <> show (getActual actual)

-- -------------------------------------------------------------------------- --
-- Scheduling Tests

data RunStyle = Sequential | Parallel

-- | A structure similar to that procuded by `testGroup`, except that we can
-- optionally schedule groups of this type.
--
data ScheduledTest = ScheduledTest { _schLabel :: String , _schTest :: TestTree }

testCaseSch :: String -> Assertion -> ScheduledTest
testCaseSch l a = ScheduledTest l $ testCase l a

testGroupSch :: String -> [TestTree] -> ScheduledTest
testGroupSch l ts = ScheduledTest l $ testGroup l ts

testPropertySch :: Testable a => String -> a -> ScheduledTest
testPropertySch l p = ScheduledTest l $ testProperty l p

-- | Schedule groups of tests according to some `RunStyle`. When `Sequential`,
-- each group will be made to run one after another. This can be used to prevent
-- various tests from starving each other of resources.
--
schedule :: RunStyle -> [ScheduledTest] -> [TestTree]
schedule _ [] = []
schedule Parallel tgs = map _schTest tgs
schedule Sequential tgs@(h : _) = _schTest h : zipWith f tgs (tail tgs)
  where
    f a b = after AllFinish (_schLabel a) $ _schTest b
