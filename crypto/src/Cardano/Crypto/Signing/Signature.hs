{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}

module Cardano.Crypto.Signing.Signature
  (
  -- * Signature
    Signature(..)
  , toCBORXSignature
  , fromCBORXSignature
  , fullSignatureHexF
  , parseFullSignature

  -- * Signing
  , sign
  , signEncoded
  , signRaw
  , safeSign
  , safeSignRaw

  -- * Verification
  , verifySignature
  , verifySignatureDecoded
  , verifySignatureRaw
  )
where

import Cardano.Prelude

import qualified Cardano.Crypto.Wallet as CC
import Data.Aeson (FromJSON(..), ToJSON(..))
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteString.Lazy as BSL
import Data.Coerce (coerce)
import Formatting (Format, bprint, build, formatToString, later, sformat, stext)
import qualified Formatting.Buildable as B
import Text.JSON.Canonical (JSValue(..))
import qualified Text.JSON.Canonical as TJC (FromJSON(..), ToJSON(..))

import Cardano.Binary
  ( Annotated(..)
  , Decoded(..)
  , Decoder
  , Encoding
  , FromCBOR(..)
  , Raw
  , ToCBOR(..)
  , serialize'
  , serializeEncoding
  )
import Cardano.Crypto.ProtocolMagic (ProtocolMagicId)
import Cardano.Crypto.Signing.PublicKey (PublicKey(..))
import Cardano.Crypto.Signing.SecretKey (SecretKey(..))
import Cardano.Crypto.Signing.Tag (SignTag(..), signTag, signTagDecoded)
import Cardano.Crypto.Signing.Safe
  (SafeSigner(..), PassPhrase(..), EncryptedSecretKey(..))


--------------------------------------------------------------------------------
-- Signature
--------------------------------------------------------------------------------

-- | Wrapper around 'CC.XSignature'
newtype Signature a =
  Signature CC.XSignature
  deriving (Eq, Ord, Show, Generic, NFData)

instance B.Buildable (Signature a) where
  build _ = "<signature>"

instance FromJSON (Signature w) where
  parseJSON v = parseJSON v >>= toAesonError . parseFullSignature

instance ToJSON (Signature w) where
  toJSON = toJSON . sformat fullSignatureHexF

instance Monad m => TJC.ToJSON m (Signature w) where
  toJSON = pure . JSString . formatToString fullSignatureHexF

instance (Typeable x, MonadError SchemaError m) => TJC.FromJSON m (Signature x) where
  fromJSON = parseJSString parseFullSignature

-- | Formatter for 'Signature' to show it in hex.
fullSignatureHexF :: Format r (Signature a -> r)
fullSignatureHexF =
  later $ \(Signature x) -> base16Builder . CC.unXSignature $ x

data SignatureParseError
  = SignatureParseBase16Error Base16ParseError
  | SignatureParseXSignatureError Text
  deriving (Eq, Show)

instance B.Buildable SignatureParseError where
  build = \case
    SignatureParseBase16Error err -> bprint
      ("Failed to parse base 16 while parsing Signature.\n Error: " . build)
      err
    SignatureParseXSignatureError err -> bprint
      ("Failed to construct XSignature while parsing Signature.\n Error: "
      . stext
      )
      err

-- | Parse 'Signature' from base16 encoded string.
parseFullSignature :: Text -> Either SignatureParseError (Signature a)
parseFullSignature s = do
  b <- first SignatureParseBase16Error $ parseBase16 s
  Signature <$> first (SignatureParseXSignatureError . toS) (CC.xsignature b)

toCBORXSignature :: CC.XSignature -> Encoding
toCBORXSignature a = toCBOR $ CC.unXSignature a

fromCBORXSignature :: Decoder s CC.XSignature
fromCBORXSignature = toCborError . CC.xsignature =<< fromCBOR

instance Typeable a => ToCBOR (Signature a) where
  toCBOR (Signature a) = toCBORXSignature a

instance Typeable a => FromCBOR (Signature a) where
  fromCBOR = fmap Signature fromCBORXSignature


--------------------------------------------------------------------------------
-- Signing
--------------------------------------------------------------------------------

-- | Encode something with 'ToCBOR' and sign it
sign
  :: ToCBOR a
  => ProtocolMagicId
  -> SignTag
  -- ^ See docs for 'SignTag'
  -> SecretKey
  -> a
  -> Signature a
sign pm tag sk = signEncoded pm tag sk . toCBOR

-- | Like 'sign' but without the 'ToCBOR' constraint
signEncoded
  :: ProtocolMagicId -> SignTag -> SecretKey -> Encoding -> Signature a
signEncoded pm tag sk = coerce . signRaw pm (Just tag) sk . BSL.toStrict . serializeEncoding

-- | Sign a 'Raw' bytestring
signRaw
  :: ProtocolMagicId
  -> Maybe SignTag
  -- ^ See docs for 'SignTag'. Unlike in 'sign', we allow no tag to be provided
  --   just in case you need to sign /exactly/ the bytestring you provided.
  -> SecretKey
  -> ByteString
  -> Signature Raw
signRaw pm mTag (SecretKey sk) x = Signature
  (CC.sign (mempty :: ScrubbedBytes) sk (tag <> x))
  where tag = maybe mempty (signTag pm) mTag

safeSign
  :: ToCBOR a => ProtocolMagicId -> SignTag -> SafeSigner -> a -> Signature a
safeSign pm t ss = coerce . safeSignRaw pm (Just t) ss . serialize'

safeSignRaw
  :: ProtocolMagicId
  -> Maybe SignTag
  -> SafeSigner
  -> ByteString
  -> Signature Raw
safeSignRaw pm mbTag (SafeSigner (EncryptedSecretKey sk _) (PassPhrase pp)) x =
  Signature (CC.sign pp sk (tag <> x))
  where tag = maybe mempty (signTag pm) mbTag


--------------------------------------------------------------------------------
-- Verification
--------------------------------------------------------------------------------

-- | Verify a signature
verifySignature
  :: (a -> Encoding)
  -> ProtocolMagicId
  -> SignTag
  -> PublicKey
  -> a
  -> Signature a
  -> Bool
verifySignature toEnc pm tag pk x sig =
  verifySignatureRaw pk (signTag pm tag <> (BSL.toStrict . serializeEncoding $ toEnc x)) (coerce sig)

-- | Verify a signature
verifySignatureDecoded
  :: Decoded t
  => Annotated ProtocolMagicId ByteString
  -> SignTag
  -> PublicKey
  -> t
  -> Signature (BaseType t)
  -> Bool
verifySignatureDecoded pm tag pk x sig =
  verifySignatureRaw pk (signTagDecoded pm tag <> recoverBytes x) (coerce sig)

-- | Verify 'Raw' signature
verifySignatureRaw
  :: PublicKey
  -> ByteString
  -> Signature Raw
  -> Bool
verifySignatureRaw (PublicKey k) x (Signature sig) = CC.verify k x sig
