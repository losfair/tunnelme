module Tunnel.App.TServer (main) where

import Options.Applicative
import qualified Data.Text as T
import qualified Data.ByteString as B
import Tunnel.Server.App (runApp)

data Opts = Opts {
  configPath :: T.Text
}

main :: IO ()
main = do
  args <- execParser argParseInfo
  cfgData <- B.readFile $ T.unpack $ configPath args
  runApp cfgData
  return ()

argParser :: Parser Opts
argParser = Opts
  <$> strOption (long "config" <> short 'c' <> help "path to configuration")

argParseInfo :: ParserInfo Opts
argParseInfo = info argParser (fullDesc <> progDesc "Tunnel server")
