module Tunnel.Mux.Control where

import GHC.Generics
import qualified Data.Text as T
import Data.Int (Int64)
import Data.Aeson

data ControlMessage =
  OpenStream {
    id :: Int64,
    peerIP :: T.Text,
    peerPort :: Int
  } |
  CloseStream {
    id :: Int64
  } |
  StreamOpened {
    id :: Int64
  } |
  StreamBroken {
    id :: Int64
  }
  deriving (Generic)

instance FromJSON ControlMessage
instance ToJSON ControlMessage
