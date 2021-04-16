module Main where

import qualified Wuss
import qualified Network.WebSockets as WS
import Data.Text.Encoding (decodeUtf8)
import qualified Data.Text as T
import Control.Monad (forever, forM_, void, unless)
import Tunnel.Mux.Message
import qualified Data.ByteString.Lazy as BL
import qualified Tunnel.Mux.Control as C
import qualified Data.HashTable.ST.Cuckoo as H
import Control.Monad.ST (RealWorld, stToIO)
import Data.Int (Int64)
import qualified Network.Socket as Sock
import Control.Exception
import Control.Concurrent.STM (TQueue, newTQueueIO, writeTQueue, atomically, newTQueue, readTQueue, orElse)
import Control.Concurrent (forkIO)
import qualified Network.Socket.ByteString as SockBS
import qualified Data.Aeson as A
import qualified Data.ByteString as B
import Text.Printf (printf)
import System.Exit (exitFailure, die)

serverName = "localhost"
serverPort = 9011
serverSecure = False

data LocalControl =
  LcStreamOpenOutput Int64 (Maybe Sock.Socket) |
  LcCloseSocket Int64

data ClientState = ClientState {
  csStreams :: H.HashTable RealWorld Int64 Sock.Socket,
  csLocalControl :: TQueue LocalControl
}

main :: IO ()
main = do
  if serverSecure then
    Wuss.runSecureClient serverName (fromIntegral serverPort) "/client" clientApp
  else
    WS.runClient serverName serverPort "/client" clientApp

clientApp :: WS.Connection -> IO ()
clientApp conn = WS.withPingThread conn 10 (pure ()) do
  msg <- WS.receiveDataMessage conn
  clientId <- case msg of
    WS.Text x _ -> return $ decodeUtf8 $ BL.toStrict x
    _ -> fail "invalid client id message"

  putStrLn $ T.unpack clientId

  streams <- stToIO H.new
  lc <- newTQueueIO 
  let st = ClientState streams lc

  msgQ <- newTQueueIO
  forkIO $ finally (stateTh st msgQ conn) $ WS.sendClose conn ("state thread exited" :: B.ByteString)

  forever do
    msg <- WS.receiveDataMessage conn
    case msg of
      WS.Binary x -> case decodeMessage (BL.toStrict x) of
        Nothing -> fail "bad message"
        Just x -> atomically $ writeTQueue msgQ x
      _ -> fail "expecting binary message"

  return ()

stateTh :: ClientState -> TQueue Message -> WS.Connection -> IO ()
stateTh st msgCh conn = forever do
  event <- atomically $
    orElse (Left <$> readTQueue msgCh) (Right <$> readTQueue (csLocalControl st))
  case event of
    Left (Control c) -> case c of
      C.OpenStream sid remoteIP remotePort -> do
        putStrLn $ printf "Attempting to open stream %d to %s:%d" sid (T.unpack remoteIP) remotePort
        void <$> forkIO $ runOpenStream sid remoteIP remotePort
      C.CloseStream sid -> do
        stream <- stToIO $ H.lookup (csStreams st) sid
        forM_ stream $ \s -> do
          -- Don't close yet. Do it in backChannel.
          try $ Sock.shutdown s Sock.ShutdownBoth :: IO (Either SomeException ())
      _ -> return ()
    Left (Payload sid d) -> do
      stream <- stToIO $ H.lookup (csStreams st) sid
      forM_ stream $ \s -> do
        catch (SockBS.sendAll s d) $ \(e :: SomeException) -> do
          putStrLn $ "error sending to relayed connection: " ++ show e
          sendControlMessage conn $ C.StreamBroken sid
    Right (LcStreamOpenOutput sid sock) -> do
      case sock of
        Just sock -> do
          stToIO $ H.insert (csStreams st) sid sock
          sendControlMessage conn $ C.StreamOpened sid
        Nothing -> sendControlMessage conn $ C.StreamBroken sid
    Right (LcCloseSocket sid) -> do
      -- A signal from backChannel that we can now safely close the socket.
      putStrLn $ printf "Closing stream %d." sid
      stream <- stToIO $ H.lookup (csStreams st) sid
      forM_ stream $ \s -> do
        stToIO $ H.delete (csStreams st) sid
        Sock.close s
  where
    runOpenStream sid remoteIP remotePort = onException (runOpenStream_ sid remoteIP remotePort) do
      atomically $ writeTQueue (csLocalControl st) (LcStreamOpenOutput sid Nothing)
    runOpenStream_ sid remoteIP remotePort = do
      addr <- resolve (T.unpack remoteIP) (show remotePort)
      sock <- Sock.socket (Sock.addrFamily addr) (Sock.addrSocketType addr) (Sock.addrProtocol addr)
      Sock.connect sock (Sock.addrAddress addr)
      atomically $ writeTQueue (csLocalControl st) (LcStreamOpenOutput sid (Just sock))
      forkIO $ backChannel sid sock
      return ()

    backChannel sid sock = finally (backChannel_ sid sock) do
      -- Signal that we can now safely close the socket.
      atomically $ writeTQueue (csLocalControl st) (LcCloseSocket sid)

    backChannel_ sid sock = do
      msg <- SockBS.recv sock 4096
      unless (B.null msg) do
        WS.sendBinaryData conn $ encodeMessage $ Payload sid msg
        backChannel_ sid sock

sendControlMessage :: WS.Connection -> C.ControlMessage -> IO ()
sendControlMessage conn msg_ = do
  let msg = encodeMessage $ Control msg_
  WS.sendBinaryData conn msg

resolve :: String -> String -> IO Sock.AddrInfo
resolve ip port = do
  let hints = Sock.defaultHints { Sock.addrFlags = [], Sock.addrSocketType = Sock.Stream}
  head <$> Sock.getAddrInfo (Just hints) (Just ip) (Just port)
