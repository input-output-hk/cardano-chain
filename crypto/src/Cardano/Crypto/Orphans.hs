{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Crypto.Orphans
       (
       ) where

import           Cardano.Prelude

import qualified Codec.CBOR.Encoding as E
import           Crypto.Error (CryptoFailable (..))
import qualified Crypto.PubKey.Ed25519 as Ed25519
import qualified Crypto.SCRAPE as Scrape
import           Crypto.Scrypt (EncryptedPass (..))
import           Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import           Data.ByteString.Base64.Type (getByteString64, makeByteString64)
import qualified Data.Text as T

import           Cardano.Binary.Class (Bi (..), Size, decodeBinary,
                     encodeBinary, withWordSize)


fromByteStringToBytes :: BS.ByteString -> BA.Bytes
fromByteStringToBytes = BA.convert

fromByteStringToScrubbedBytes :: BS.ByteString -> BA.ScrubbedBytes
fromByteStringToScrubbedBytes = BA.convert

toByteString :: (BA.ByteArrayAccess bin) => bin -> BS.ByteString
toByteString = BA.convert

instance Ord Ed25519.PublicKey where
  compare x1 x2 = compare (toByteString x1) (toByteString x2)

instance Ord Ed25519.SecretKey where
  compare x1 x2 = compare (toByteString x1) (toByteString x2)

instance Ord Ed25519.Signature where
  compare x1 x2 = compare (toByteString x1) (toByteString x2)

fromCryptoFailable :: MonadFail m => T.Text -> CryptoFailable a -> m a
fromCryptoFailable item (CryptoFailed e) =
  fail
    $  T.unpack
    $  "Cardano.Crypto.Orphan."
    <> item
    <> " failed because "
    <> show e
fromCryptoFailable _ (CryptoPassed r) = return r

instance FromJSON Ed25519.PublicKey where
  parseJSON v = do
    res <-
      Ed25519.publicKey
      .   fromByteStringToBytes
      .   getByteString64
      <$> parseJSON v
    fromCryptoFailable "parseJSON Ed25519.PublicKey" res

instance ToJSON Ed25519.PublicKey where
  toJSON = toJSON . makeByteString64 . toByteString

instance FromJSON Ed25519.Signature where
  parseJSON v = do
    res <-
      Ed25519.signature
      .   fromByteStringToBytes
      .   getByteString64
      <$> parseJSON v
    fromCryptoFailable "parseJSON Ed25519.Signature" res

instance ToJSON Ed25519.Signature where
  toJSON = toJSON . makeByteString64 . toByteString

instance Bi Ed25519.PublicKey where
  encodedSizeExpr _ _ = bsSize 32
  encode = E.encodeBytes . toByteString
  decode = do
    res <- Ed25519.publicKey . fromByteStringToBytes <$> decode
    fromCryptoFailable "decode Ed25519.PublicKey" res

instance Bi Ed25519.SecretKey where
  encodedSizeExpr _ _ = bsSize 64
  encode sk = E.encodeBytes
    $ BS.append (toByteString sk) (toByteString $ Ed25519.toPublic sk)
  decode = do
    res <-
      Ed25519.secretKey
      .   fromByteStringToScrubbedBytes
      .   BS.take Ed25519.secretKeySize
      <$> decode
    fromCryptoFailable "decode Ed25519.SecretKey" res

instance Bi Ed25519.Signature where
  encodedSizeExpr _ _ = bsSize 64
  encode = E.encodeBytes . toByteString
  decode = do
    res <- Ed25519.signature . fromByteStringToBytes <$> decode
    fromCryptoFailable "decode Ed25519.Signature" res

-- Helper for encodedSizeExpr in Bi instances
bsSize :: Int -> Size
bsSize x = fromIntegral (x + withWordSize x)


--------------------------------------------------------------------------------
-- Bi instances for Scrape
--------------------------------------------------------------------------------

instance Bi Scrape.PublicKey where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.KeyPair where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.Secret where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.DecryptedShare where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.EncryptedSi where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.ExtraGen where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.Commitment where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.Proof where
  encode = encodeBinary
  decode = decodeBinary

instance Bi Scrape.ParallelProofs where
  encode = encodeBinary
  decode = decodeBinary

instance Bi EncryptedPass where
  encode (EncryptedPass ep) = encode ep
  decode = EncryptedPass <$> decode
