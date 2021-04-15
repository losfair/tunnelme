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

data AppConfig = AppConfig {
  appPort :: Int,
  appHost :: String,
  appTokens :: [T.Text]
}

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
  Warp.runSettings settings $ application c
  return ()

application :: AppConfig -> Wai.Application
application c req respond = do
  respond $ Wai.responseLBS status200 [] "OK"
