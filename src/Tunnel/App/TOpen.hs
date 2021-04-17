module Tunnel.App.TOpen (main) where

import Options.Applicative
import qualified Data.Text as T
import qualified Data.ByteString as B
import Tunnel.Server.App (runApp)
import qualified Wuss
import qualified Network.WebSockets as WS
import Network.Socket (PortNumber)
import Text.Printf (printf)
import qualified Data.Aeson as A
import qualified Tunnel.OpenProto as OpenProto
import qualified Network.Socket as Sock
import Control.Exception (bracketOnError, finally)
import Control.Monad (forever, unless)
import Control.Concurrent (forkIO, killThread)
import qualified Network.Socket.ByteString as SockBS
import qualified Data.ByteString.Lazy as BL
import Control.Concurrent.STM (TQueue, newTQueueIO, writeTQueue, atomically, readTQueue)
import qualified Data.Yaml as Yaml
import System.Directory (getHomeDirectory)
import Data.Maybe (fromJust)

data Opts = Opts {
  configPath :: String,
  peerID :: T.Text,
  remoteIP :: T.Text,
  remotePort :: Int,
  localIP :: String,
  localPort :: String,
  cfg :: Maybe Cfg
}

data Cfg = Cfg {
  cfgServerSecure :: Bool,
  cfgServerName :: String,
  cfgServerPort :: Int,
  cfgUserToken :: T.Text
}

instance A.FromJSON Cfg where
  parseJSON = A.withObject "Cfg" $ \obj -> Cfg
    <$> obj A..: "secure"
    <*> obj A..: "server"
    <*> obj A..: "port"
    <*> obj A..: "token"

main :: IO ()
main = do
  opts <- execParser argParseInfo
  realConfigPath <-
    if null (configPath opts) then
      (++ "/.topen_config.yaml") <$> getHomeDirectory
    else
      pure (configPath opts)
  cfgData <- Yaml.decodeFileThrow realConfigPath :: IO Cfg
  beginListen opts { cfg = Just cfgData }

argParser :: Parser Opts
argParser = Opts
  <$> strOption (long "config" <> short 'c' <> value "" <> help "path to config (defaults to ~/.topen_config.yaml)")
  <*> strOption (long "peer" <> help "peer id")
  <*> strOption (long "remote" <> help "remote ip")
  <*> (read <$> strOption (long "remote-port" <> help "remote port"))
  <*> strOption (long "local" <> help "local ip")
  <*> strOption (long "local-port" <> help "local port")
  <*> pure Nothing

argParseInfo :: ParserInfo Opts
argParseInfo = info argParser (fullDesc <> progDesc "Open connection to server")

beginListen :: Opts -> IO ()
beginListen opts = do
  resolvedAddr <- resolve
  listener <- listen resolvedAddr
  forever do
    (conn, peer) <- Sock.accept listener
    putStrLn $ "Got new local connection from " ++ show peer
    forkIO $ finally (runLocalRelay opts conn) (Sock.close conn)
  where
    resolve = do
      let hints = Sock.defaultHints { Sock.addrFlags = [Sock.AI_PASSIVE], Sock.addrSocketType = Sock.Stream}
      head <$> Sock.getAddrInfo (Just hints) (Just $ localIP opts) (Just $ localPort opts)
    listen addr = do
      let sock = Sock.socket (Sock.addrFamily addr) (Sock.addrSocketType addr) (Sock.addrProtocol addr)
      bracketOnError sock Sock.close $ \sock -> do
        Sock.setSocketOption sock Sock.ReuseAddr 1
        Sock.withFdSocket sock Sock.setCloseOnExecIfNeeded
        Sock.bind sock $ Sock.addrAddress addr
        Sock.listen sock 1024
        return sock

runLocalRelay :: Opts -> Sock.Socket -> IO ()
runLocalRelay opts local = do
  let config = fromJust $ cfg opts
  if cfgServerSecure config then
    Wuss.runSecureClient (cfgServerName config) (fromIntegral $ cfgServerPort config) "/open" $ clientApp opts local
  else
    WS.runClient (cfgServerName config) (cfgServerPort config) "/open" $ clientApp opts local

clientApp :: Opts -> Sock.Socket -> WS.Connection -> IO ()
clientApp opts local conn = WS.withPingThread conn 10 (pure ()) do
  let config = fromJust $ cfg opts
  let openMsg = OpenProto.OpenRequest (peerID opts) (remoteIP opts) (remotePort opts) (cfgUserToken config)
  WS.sendTextData conn $ A.encode openMsg
  ack <- WS.receiveDataMessage conn

  kill <- newTQueueIO :: IO (TQueue ())
  fs <- forkIO $ finally forwardStream (atomically $ writeTQueue kill ())
  bs <- forkIO $ finally backwardStream (atomically $ writeTQueue kill ())
  atomically $ readTQueue kill
  killThread fs
  killThread bs

  where
    forwardStream = forever do
      msg <- WS.receiveDataMessage conn
      case msg of
        WS.Binary x -> SockBS.sendAll local $ BL.toStrict x
        _ -> return ()
    backwardStream = do
      msg <- SockBS.recv local 4096
      unless (B.null msg) do
        WS.sendBinaryData conn msg
        backwardStream
