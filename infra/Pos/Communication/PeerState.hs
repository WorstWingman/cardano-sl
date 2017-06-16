{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Class which provides access to NodePeerState.

module Pos.Communication.PeerState
       ( WithPeerState (..)
       , PeerStateTag
       , PeerStateCtx
       , PeerStateSnapshot
       , peerStateFromSnapshot
       , module Pos.Communication.Types.State
       , getPeerStateReal
       , clearPeerStateReal
       , getAllStatesReal
       ) where

import           Control.Monad.Trans.Class        (MonadTrans)
import           Data.Default                     (Default (def))
import qualified Ether
import qualified ListT                            as LT
import           Mockable                         (Mockable, SharedAtomic, SharedAtomicT,
                                                   newSharedAtomic, readSharedAtomic)
import           Pos.Communication.Types.Protocol (NodeId)
import qualified STMContainers.Map                as STM
import           Universum

import           Pos.Communication.Types.State
import           Pos.Util.Util                    ()

type PeerStateCtx m = STM.Map NodeId (SharedAtomicT m PeerState)

-- | PeerStateCtx with no dependency on `m` type.
newtype PeerStateSnapshot = PeerStateSnapshot [(NodeId, PeerState)]

class WithPeerState m where
    getPeerState   :: NodeId -> m (SharedAtomicT m PeerState)
    clearPeerState :: NodeId -> m ()
    getAllStates   :: m PeerStateSnapshot

instance {-# OVERLAPPABLE #-}
    ( WithPeerState m, Monad m, MonadTrans t, Monad (t m)
    , SharedAtomicT m ~ SharedAtomicT (t m) ) =>
        WithPeerState (t m)
  where
    getPeerState = lift . getPeerState
    clearPeerState = lift . clearPeerState
    getAllStates = lift getAllStates

peerStateFromSnapshot
    :: (MonadIO m, Mockable SharedAtomic m)
    => PeerStateSnapshot -> m (PeerStateCtx m)
peerStateFromSnapshot (PeerStateSnapshot snapshot) = do
    ctx <- forM snapshot $ mapM newSharedAtomic
    m   <- liftIO STM.newIO
    atomically $ for_ ctx $ \(k, v) -> STM.insert v k m
    return m

data PeerStateTag

type PeerStateRealMonad m =
    ( MonadIO m, Mockable SharedAtomic m
    , Ether.MonadReader PeerStateTag (PeerStateCtx m) m )

getPeerStateReal
    :: PeerStateRealMonad m
    => NodeId -> m (SharedAtomicT m PeerState)
getPeerStateReal nodeId = Ether.ask @PeerStateTag >>= \m -> do
    mV <- atomically $ nodeId `STM.lookup` m
    case mV of
      Just v -> return v
      _ -> do
        st <- newSharedAtomic def
        atomically $ do
            mV' <- nodeId `STM.lookup` m
            case mV' of
              Just v -> return v
              _      -> STM.insert st nodeId m $> st

clearPeerStateReal
    :: PeerStateRealMonad m
    => NodeId -> m ()
clearPeerStateReal nodeId = do
    m <- Ether.ask @PeerStateTag
    atomically $ nodeId `STM.delete` m

getAllStatesReal
    :: PeerStateRealMonad m
    => m PeerStateSnapshot
getAllStatesReal = do
    m <- Ether.ask @PeerStateTag
    stream <- atomically $ LT.toList $ STM.stream m
    PeerStateSnapshot <$> forM stream (mapM readSharedAtomic)
