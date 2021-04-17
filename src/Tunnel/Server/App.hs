module Tunnel.Server.App (runApp) where

import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Data.String (fromString)
import Network.HTTP.Types
import qualified Data.Aeson as A
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.Yaml as Yaml
import Data.Maybe
import qualified Network.WebSockets as WS
import Network.WebSockets (PendingConnection, defaultConnectionOptions, acceptRequestWith, defaultAcceptRequest)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Control.Exception
import Crypto.Random.Entropy (getEntropy)
import qualified Data.ByteString.Base16 as Base16
import Tunnel.Server.Relay
import Control.Concurrent.STM (atomically, newTQueue, newTQueueIO, writeTQueue, readTQueue, TQueue, registerDelay, orElse, check, readTVar, TVar, newTVar, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forever, forM_, unless)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Control.Concurrent (forkIO, killThread)
import qualified Tunnel.OpenProto as OpenProto
import qualified Crypto.Hash as Hash
import qualified Data.ByteArray as BA
import qualified Data.HashTable.ST.Cuckoo as H
import Control.Monad.ST (RealWorld, stToIO)
import qualified StmContainers.Map as StmMap
import Control.Monad.Fix (fix)

data AppConfig = AppConfig {
  appPort :: Int,
  appHost :: String,
  appTokens :: [T.Text]
}

data AppSt = AppSt {
  keepaliveSessions :: StmMap.Map B.ByteString (TQueue ()),
  pongHandler :: TVar (Maybe (IO ()))
}

type RelaySt = RelayState B.ByteString WS.Connection

instance A.FromJSON AppConfig where
  parseJSON = A.withObject "AppConfig" $ \obj -> AppConfig
    <$> obj A..: "port"
    <*> obj A..: "host"
    <*> obj A..: "tokens"

runApp :: B.ByteString -> IO ()
runApp c_ = do
  c <- Yaml.decodeThrow c_ :: IO AppConfig
  let settings = Warp.setPort (appPort c) $ Warp.setHost (fromString $ appHost c) Warp.defaultSettings
  putStrLn $ "Listening on " ++ appHost c ++ ":" ++ show (appPort c)
  relay <- newRelay
  forkIO $ runDispatchQueue relay

  appSt <- AppSt
    <$> StmMap.newIO
    <*> newTVarIO Nothing
  let connOpts = defaultConnectionOptions { WS.connectionOnPong = runPongHandler appSt }
  Warp.runSettings settings $ websocketsOr defaultConnectionOptions (wsApp c relay appSt) $ application c
  return ()
  where
    runPongHandler appSt = do
      v <- readTVarIO $ pongHandler appSt
      forM_ v id

application :: AppConfig -> Wai.Application
application c req respond = do
  respond $ Wai.responseLBS status200 [] "OK"

wsApp :: AppConfig -> RelaySt -> AppSt -> PendingConnection -> IO ()
wsApp config st appSt pendingConn = do
  let head = WS.pendingRequest pendingConn
  case WS.requestPath head of
    "/client" -> do
      conn <- acceptRequestWith pendingConn defaultAcceptRequest
      finally (handleWsClient st conn appSt) (WS.sendClose conn ("close" :: B.ByteString))
    "/open" -> do
      conn <- acceptRequestWith pendingConn defaultAcceptRequest
      finally (handleWsOpen config st conn) (WS.sendClose conn ("close" :: B.ByteString))
    _ -> WS.rejectRequest pendingConn "invalid request path"
  return ()

instance Carrier WS.Connection where
  sendMessage conn notifiers d = do
    WS.sendBinaryData conn d
  close conn = WS.sendClose conn ("close" :: B.ByteString)

handleWsClient :: RelaySt -> WS.Connection -> AppSt -> IO ()
handleWsClient st conn appSt = WS.withPingThread conn 25 (pure ()) do
  msg <- WS.receiveDataMessage conn
  connPrivateId <- case msg of
    WS.Binary x -> acquirePrivateId appSt $ BL.toStrict x
    _ -> fail "bad initial message"

  let connId_ = Hash.hash connPrivateId :: Hash.Digest Hash.SHA256
  let connId = B.pack $ take 8 (BA.unpack connId_)
  let connIdStr = Base16.encode connId
  WS.sendBinaryData conn connPrivateId

  atomically $ writeTVar (pongHandler appSt) $ Just do
    session <- atomically $ StmMap.lookup connPrivateId $ keepaliveSessions appSt
    forM_ session $ \x -> do
      atomically $ writeTQueue x ()

  notifiers <- enqSync st $ openConnection st connId conn

  putStrLn $ "New connection: " ++ T.unpack (decodeUtf8 connIdStr)
  finally
    (run notifiers)
    (synchronouslyNotifyCarrierBroken notifiers
      >> putStrLn ("Connection closed: " ++ T.unpack (decodeUtf8 connIdStr)))
  return ()

  where
    run notifiers = forever do
      msg <- WS.receiveDataMessage conn
      case msg of
        WS.Text t _ -> return ()
        WS.Binary d -> atomically $ notifyIncomingMessage notifiers $ BL.toStrict d

handleWsOpen :: AppConfig -> RelaySt -> WS.Connection -> IO ()
handleWsOpen config st conn = do
  req_ <- WS.receiveDataMessage conn
  case req_ of
    WS.Text raw _ -> do
      forM_ (A.decode raw) $ \(req :: OpenProto.OpenRequest) -> do
        unless (OpenProto.token req `elem` appTokens config) $
          fail "invalid token"
        let peerID = Base16.decodeLenient $ encodeUtf8 $ OpenProto.peerID req
        let peerIDStr = decodeUtf8 $ Base16.encode peerID
        events <- newTQueueIO
        streamId <- enqSync st $
          openStream st peerID (OpenProto.remoteIP req) (OpenProto.remotePort req)
            (atomically . writeTQueue events)
        forM_ streamId $ \streamId -> do
          putStrLn $ "New stream to peer " ++ T.unpack peerIDStr ++ ": " ++ show streamId
          finally
            (runBidirectionalStream peerID streamId events)
            do
              atomically $ enq st $ closeStream st peerID streamId
              putStrLn $ "Closed stream to peer " ++ T.unpack peerIDStr ++ ": " ++ show streamId
          return ()
    _ -> return ()
  where
    runBidirectionalStream :: B.ByteString -> StreamId -> TQueue StreamLifecycleEvent -> IO ()
    runBidirectionalStream peerID streamId events = do
      kill <- newTQueueIO :: IO (TQueue ())
      fs <- forkIO $ finally forward (atomically $ writeTQueue kill ())
      bs <- forkIO $ finally backward (atomically $ writeTQueue kill ())
      atomically $ readTQueue kill
      killThread fs
      killThread bs
      where
        forward = forever do
          msg <- WS.receiveDataMessage conn
          case msg of
            WS.Binary x ->
              atomically $ enq st $ sendMessageToStream st peerID streamId $ BL.toStrict x
            _ -> return ()
        backward = do
          msg <- atomically $ readTQueue events
          case msg of
            StreamReady -> do
              -- ACK
              WS.sendTextData conn ("OK" :: B.ByteString)
              backward
            IncomingData d -> do
              WS.sendBinaryData conn d
              backward
            StreamClosed -> return ()

acquirePrivateId :: AppSt -> B.ByteString -> IO B.ByteString
acquirePrivateId appSt reqId = do
  if not $ B.null reqId then do
    ch <- atomically (StmMap.lookup reqId $ keepaliveSessions appSt)
    case ch of
      Just ch -> do
        atomically $ writeTQueue ch ()
        return reqId
      Nothing -> fallback
  else fallback
  where
    fallback = do
      -- Generate a new session
      id <- getEntropy 32 :: IO B.ByteString
      q <- newTQueueIO 
      atomically (StmMap.insert q id $ keepaliveSessions appSt)

      -- Session timeout
      forkIO $ fix \f -> do
        -- Two minutes
        timeout <- registerDelay (120 * 1000 * 1000)
        v <- atomically do
          timeoutValue <- readTVar timeout
          orElse (Left <$> check timeoutValue) (Right <$> readTQueue q)
        case v of
          Left _ -> do
            putStrLn "Removing expired keepalive entry."
            atomically $ StmMap.delete id $ keepaliveSessions appSt
          Right _ -> f
      return id
