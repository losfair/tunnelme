module Tunnel.Mux.Message (
  Message(Control, Payload),
  streamIdForMessage,
  decodeMessage,
  encodeMessage,
) where

import Tunnel.Mux.Control (ControlMessage)
import qualified Tunnel.Mux.Control as C
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Binary (Get, getWord8, Binary (get, put), Put, putWord8)
import Data.Int (Int64)
import qualified Data.Aeson as A
import Data.Either.Combinators (leftToMaybe, rightToMaybe)
import Data.Binary.Get (runGetOrFail)
import Data.Text.Encoding (encodeUtf8)
import Data.Binary.Put (runPut)

data Message = Control ControlMessage | Payload Int64 B.ByteString

streamIdForMessage :: Message -> Int64
streamIdForMessage (Control m) = C.id m
streamIdForMessage (Payload x _) = x

decodeMessage :: B.ByteString -> Maybe Message
decodeMessage = fmap third . rightToMaybe . runGetOrFail decodeMessage_ . BL.fromStrict

decodeMessage_ :: Get Message
decodeMessage_ = do
  ty <- getWord8
  if ty == 0 then do
    text <- get :: Get BL.ByteString
    case A.decode text of
      Just x -> return $ Control x
      Nothing -> fail "json decode failed"
  else if ty == 1 then do
    streamId <- get :: Get Int64
    payload <- get :: Get B.ByteString
    return $ Payload (fromIntegral streamId) payload
  else fail "invalid message type"

encodeMessage :: Message -> B.ByteString
encodeMessage = BL.toStrict . runPut . encodeMessage_

encodeMessage_ :: Message -> Put
encodeMessage_ x = do
  case x of
    Control x -> do
      putWord8 0
      put $ A.encode x
    Payload streamId x -> do
      putWord8 1
      put streamId
      put x

third :: (a, b, c) -> c
third (_, _, x) = x
