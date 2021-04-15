module Tunnel.Server.Relay (
  StreamId,
  Carrier,
  StreamLifecycleCallback,
  RelayState,
  newRelay,
  openConnection,
  openStream,
  closeStream,
  sendMessageToStream,
) where

import qualified Data.HashTable.ST.Cuckoo as H
import Control.Monad.ST
import Data.Int (Int64)
import Data.STRef
import Data.Hashable (Hashable)
import GHC.Generics
import Control.Exception
import Control.Monad
import Data.Maybe
import Data.IORef
import qualified Data.ByteString as B
import qualified Data.Text as T
import Tunnel.Mux.Control
import Tunnel.Mux.Message
import Control.Concurrent.STM (TQueue, newTQueueIO, writeTQueue, STM, newTVarIO, readTVar, TVar, stateTVar, atomically)

newtype StreamId = StreamId Int64
  deriving (Eq, Generic)

instance Hashable StreamId

newtype RelayException = RelayException String
  deriving (Show)
instance Exception RelayException

data RelayState k conn = RelayState {
  connections :: H.HashTable RealWorld k (ConnState conn),
  dispatchQueue :: TQueue (IO ())
}

data ConnState conn = ConnState {
  connBacking :: conn,
  connNotifiers :: NotifierSet,
  nextStreamId :: IORef Int64,
  streams :: H.HashTable RealWorld StreamId StreamState
}

type StreamLifecycleCallback = StreamLifecycleEvent -> IO ()
data StreamLifecycleEvent = StreamReady | IncomingData B.ByteString | StreamClosed

data StreamState = StreamState {
  color :: IORef StreamColor,
  lcCb :: StreamLifecycleCallback
}

data StreamColor = Opening | Established deriving (Eq)

data NotifierSet = NotifierSet {
  notifyIncomingMessage :: B.ByteString -> STM (),
  notifyCarrierBroken :: STM (),
  isConnClosed :: STM Bool
}

class Carrier a where
  sendMessage :: a -> NotifierSet -> B.ByteString -> IO ()
  recvMessage :: a -> NotifierSet -> IO B.ByteString
  close :: a -> IO ()

newRelay :: IO (RelayState k conn)
newRelay = do
  connTable <- stToIO H.new
  pendingIOList <- newIORef []
  RelayState connTable <$> newTQueueIO

openConnection :: (Hashable k, Eq k, Carrier conn) => RelayState k conn -> k -> conn -> IO ()
openConnection st k conn = do
  current <- stToIO $ H.lookup (connections st) k

  -- Close current connection
  forM_ current (close . connBacking)
  nextStreamId_ <- newIORef 0
  streamTable <- stToIO H.new
  connClosed <- newTVarIO False

  -- Generate notifier set
  let notifiers = NotifierSet {
    notifyCarrierBroken = enq st $ dropConnection st k connClosed,
    notifyIncomingMessage = enq st . onIncomingMessage st k,
    isConnClosed = readTVar connClosed
  }

  let state = ConnState {
    connBacking = conn,
    nextStreamId = nextStreamId_,
    connNotifiers = notifiers,
    streams = streamTable
  }
  stToIO $ H.insert (connections st) k state

openStream :: (Hashable k, Eq k, Carrier conn) => RelayState k conn -> k -> T.Text -> Int -> StreamLifecycleCallback -> IO StreamId
openStream st k peerIP peerPort lifecycleCallback = do
  conn <- fromJust <$> stToIO (H.lookup (connections st) k)

  -- Allocate stream id
  sid <- readIORef $ nextStreamId conn
  writeIORef (nextStreamId conn) (sid + 1)

  -- Create stream
  stream <- StreamState
    <$> newIORef Opening
    <*> pure lifecycleCallback
  stToIO $ H.insert (streams conn) (StreamId sid) stream

  -- Send opening message
  let msg = encodeMessage $ Control $ OpenStream sid peerIP peerPort
  sendMessage (connBacking conn) (connNotifiers conn) msg
  return $ StreamId sid


closeStream :: (Hashable k, Eq k, Carrier conn) => RelayState k conn -> k -> StreamId -> IO ()
closeStream st k sid = do
  conn <- stToIO (H.lookup (connections st) k)
  forM_ conn $ \conn -> do
    stream <- stToIO $ H.lookup (streams conn) sid
    forM_ stream $ \x -> do
      stToIO $ H.delete (streams conn) sid
      lcCb x StreamClosed

sendMessageToStream :: (Hashable k, Eq k, Carrier conn) => RelayState k conn -> k -> StreamId -> B.ByteString -> IO ()
sendMessageToStream st k sid payload = do
  conn <- stToIO (H.lookup (connections st) k)
  forM_ conn $ \conn -> do
    stream <- stToIO $ H.lookup (streams conn) sid
    forM_ stream $ \x -> do
      let StreamId sidN = sid
      sendMessage (connBacking conn) (connNotifiers conn) $ encodeMessage $ Payload sidN payload

enq :: RelayState k conn -> IO () -> STM ()
enq st = writeTQueue (dispatchQueue st)

onIncomingMessage :: (Hashable k, Eq k) => RelayState k conn -> k -> B.ByteString -> IO ()
onIncomingMessage st k raw = do
  forM_ (decodeMessage raw) $ \msg -> do
    let streamId = StreamId $ streamIdForMessage msg
    connState <- stToIO $ H.lookup (connections st) k
    forM_ connState $ \connState -> do
      stream <- stToIO $ H.lookup (streams connState) streamId
      forM_ stream $ \stream -> case msg of
        Control inner -> do
          case inner of
            StreamOpened _ -> do
              current <- readIORef (color stream)
              when (current == Opening) do
                writeIORef (color stream) Established
                lcCb stream StreamReady
            _ -> return ()
        Payload _ d -> lcCb stream (IncomingData d)

dropConnection :: (Hashable k, Eq k, Carrier conn) => RelayState k conn -> k -> TVar Bool -> IO ()
dropConnection st k closed = do
  closing <- atomically $ stateTVar closed modifier
  when closing do
    let table = connections st
    callbacks <- stToIO do
      x <- fromJust <$> H.lookup table k
      H.delete table k
      H.foldM (\p (_, v) -> pure (lcCb v:p)) [] (streams x)
    mapM_ (\x -> x StreamClosed) callbacks
  where
    modifier False = (True, True)
    modifier True = (False, True)
