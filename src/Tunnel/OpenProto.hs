module Tunnel.OpenProto where

import qualified Data.Text as T
import GHC.Generics (Generic)
import Data.Aeson (FromJSON, ToJSON)

data OpenRequest = OpenRequest {
  peerID :: T.Text,
  remoteIP :: T.Text,
  remotePort :: Int
} deriving (Generic)

instance FromJSON OpenRequest
instance ToJSON OpenRequest
