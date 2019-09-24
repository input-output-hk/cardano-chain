{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | Hashing capabilities.

module Cardano.Crypto.Hashing
  ( -- * AbstractHash
    AbstractHash(..)
  , decodeAbstractHash
  , decodeHash
  , abstractHash
  , unsafeAbstractHash

         -- * Common Hash
  , Hash
  , hashHexF
  , mediumHashF
  , shortHashF
  , hash
  , hashDecoded
  , hashRaw

         -- * Utility
  , HashAlgorithm
  , hashDigestSize'
  )
where

import Cardano.Prelude
import qualified Prelude

import Crypto.Hash (Blake2b_256, Digest, HashAlgorithm, hashDigestSize)
import qualified Crypto.Hash as Hash
import Data.Aeson
  ( FromJSON(..)
  , FromJSONKey(..)
  , FromJSONKeyFunction(..)
  , ToJSON(..)
  , ToJSONKey(..)
  )
import Data.Aeson.Types (toJSONKeyText)
import qualified Data.ByteArray as ByteArray
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Formatting (Format, bprint, build, fitLeft, later, sformat, (%.))
import qualified Formatting.Buildable as B (Buildable(..))

import Cardano.Binary
  ( Decoded(..)
  , DecoderError(..)
  , FromCBOR(..)
  , Raw
  , ToCBOR(..)
  , serialize
  , withWordSize
  )


--------------------------------------------------------------------------------
-- AbstractHash
--------------------------------------------------------------------------------

-- | Hash wrapper with phantom type for more type-safety
--
--   Made abstract in order to support different algorithms
newtype AbstractHash algo a =
  AbstractHash (Digest algo)
  deriving (Show, Eq, Ord, ByteArray.ByteArrayAccess, Generic, NFData)
  deriving NoUnexpectedThunks via UseIsNormalForm (Digest algo) 

instance HashAlgorithm algo => Read (AbstractHash algo a) where
  readsPrec _ s = case parseBase16 $ toS s of
    Left  _  -> []
    Right bs -> case Hash.digestFromByteString bs of
      Nothing -> []
      Just h  -> [(AbstractHash h, "")]

instance B.Buildable (AbstractHash algo a) where
  build = bprint mediumHashF

instance ToJSON (AbstractHash algo a) where
  toJSON = toJSON . sformat hashHexF

instance HashAlgorithm algo => FromJSON (AbstractHash algo a) where
  parseJSON = toAesonError . readEither <=< parseJSON

instance (HashAlgorithm algo, FromJSON (AbstractHash algo a))
         => FromJSONKey (AbstractHash algo a) where
  fromJSONKey = FromJSONKeyTextParser (toAesonError . decodeAbstractHash)

instance ToJSONKey (AbstractHash algo a) where
  toJSONKey = toJSONKeyText (sformat hashHexF)

instance (Typeable algo, Typeable a, HashAlgorithm algo) => ToCBOR (AbstractHash algo a) where
  toCBOR (AbstractHash digest) =
    toCBOR (ByteArray.convert digest :: BS.ByteString)

  encodedSizeExpr _ _ =
    let realSz = hashDigestSize (panic "unused, I hope!" :: algo)
    in fromInteger (toInteger (withWordSize realSz + realSz))

instance (Typeable algo, Typeable a, HashAlgorithm algo) => FromCBOR (AbstractHash algo a) where
  -- FIXME bad decode: it reads an arbitrary-length byte string.
  -- Better instance: know the hash algorithm up front, read exactly that
  -- many bytes, fail otherwise. Then convert to a digest.
  fromCBOR = do
    bs <- fromCBOR @ByteString
    maybe
      (cborError $ DecoderErrorCustom
        "AbstractHash"
        "Cannot convert ByteString to digest"
      )
      (pure . AbstractHash)
      (Hash.digestFromByteString bs)

instance HeapWords (AbstractHash algo a) where
  heapWords _
    -- We have
    --
    -- > newtype AbstractHash algo a = AbstractHash (Digest algo)
    -- > newtype Digest a = Digest (Block Word8)
    -- > data Block ty = Block ByteArray#
    --
    -- so @AbstractHash algo a@ requires:
    --
    -- - 1 word for the 'Block' object header
    -- - 1 word for the pointer to the byte array object
    -- - 1 word for the byte array object header
    -- - 1 word for the size of the byte array payload in bytes
    -- - 4 words (on a 64-bit arch) for the byte array payload containing the digest
    --
    -- +---------+
    -- │Block│ * │
    -- +-------+-+
    --         |
    --         v
    --         +--------------+
    --         │BA#│sz│payload│
    --         +--------------+
    --
    = 8

hashDigestSize' :: forall algo . HashAlgorithm algo => Int
hashDigestSize' = hashDigestSize @algo
  (panic
    "Cardano.Crypto.Hashing.hashDigestSize': HashAlgorithm value is evaluated!"
  )

-- | Parses given hash in base16 form.
decodeAbstractHash
  :: HashAlgorithm algo => Text -> Either Text (AbstractHash algo a)
decodeAbstractHash prettyHash = do
  bytes <- first (sformat build) $ parseBase16 prettyHash
  case Hash.digestFromByteString bytes of
    Nothing -> Left
      (  "decodeAbstractHash: "
      <> "can't convert bytes to hash,"
      <> " the value was "
      <> toS prettyHash
      )
    Just digest -> return (AbstractHash digest)

-- | Parses given hash in base16 form.
decodeHash :: Text -> Either Text (Hash a)
decodeHash = decodeAbstractHash @Blake2b_256

-- | Hash the 'ToCBOR'-serialised version of a value
abstractHash :: (HashAlgorithm algo, ToCBOR a) => a -> AbstractHash algo a
abstractHash = unsafeAbstractHash . serialize

-- | Make an 'AbstractHash' from a lazy 'ByteString'
--
--   You can choose the phantom type, hence the "unsafe"
unsafeAbstractHash
  :: HashAlgorithm algo => LByteString -> AbstractHash algo anything
unsafeAbstractHash = AbstractHash . Hash.hashlazy


--------------------------------------------------------------------------------
-- Hash
--------------------------------------------------------------------------------

-- | Type alias for commonly used hash
type Hash = AbstractHash Blake2b_256

-- | Short version of 'unsafeHash'.
hash :: ToCBOR a => a -> Hash a
hash = abstractHash

-- | Hashes the annotation
hashDecoded :: (Decoded t) => t -> Hash (BaseType t)
hashDecoded = unsafeAbstractHash . LBS.fromStrict . recoverBytes

-- | Raw constructor application.
hashRaw :: LBS.ByteString -> Hash Raw
hashRaw = unsafeAbstractHash

-- | Specialized formatter for 'Hash'.
hashHexF :: Format r (AbstractHash algo a -> r)
hashHexF = later $ \(AbstractHash x) -> B.build (show x :: Text)

-- | Smart formatter for 'Hash' to show only first @16@ characters of 'Hash'.
mediumHashF :: Format r (AbstractHash algo a -> r)
mediumHashF = fitLeft 16 %. hashHexF

-- | Smart formatter for 'Hash' to show only first @8@ characters of 'Hash'.
shortHashF :: Format r (AbstractHash algo a -> r)
shortHashF = fitLeft 8 %. hashHexF
