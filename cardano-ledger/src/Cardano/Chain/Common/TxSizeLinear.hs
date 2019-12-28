{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TypeApplications   #-}

module Cardano.Chain.Common.TxSizeLinear
  ( TxSizeLinear(..)
  , txSizeLinearMinValue
  , calculateTxSizeLinear
  )
where

import Cardano.Prelude

import Data.Fixed (Nano)
import Formatting (bprint, build)
import qualified Formatting.Buildable as B

import Cardano.Binary
  ( FromCBOR(..)
  , ToCBOR(..)
  , encodeListLen
  , enforceSize
  )
import Cardano.Chain.Common.Lovelace
  ( Lovelace
  , LovelaceError
  , addLovelace
  , scaleLovelace
  , lovelaceToNatural
  , naturalToLovelace
  )


-- | A linear equation on the transaction size. Represents the @\s -> a + b*s@
-- function where @s@ is the transaction size in bytes, @a@ and @b@ are
-- constant coefficients.
data TxSizeLinear =
  TxSizeLinear !Lovelace !Lovelace
  deriving (Eq, Ord, Show, Generic)
  deriving anyclass (NFData, NoUnexpectedThunks)

instance B.Buildable TxSizeLinear where
  build (TxSizeLinear a b) = bprint (build . " + " . build . "*s") a b

instance ToCBOR TxSizeLinear where
  -- We encode as 'Nano' for backwards compatibility
  toCBOR (TxSizeLinear a b) =
    encodeListLen 2
      <> toCBOR (fromIntegral (lovelaceToNatural a) :: Nano)
      <> toCBOR (fromIntegral (lovelaceToNatural b) :: Nano)

instance FromCBOR TxSizeLinear where
  fromCBOR = do
    enforceSize "TxSizeLinear" 2
    !a <- naturalToLovelace . round <$> fromCBOR @Nano
    !b <- naturalToLovelace . round <$> fromCBOR @Nano
    return $ TxSizeLinear a b

calculateTxSizeLinear
  :: TxSizeLinear -> Natural -> Either LovelaceError Lovelace
calculateTxSizeLinear (TxSizeLinear a b) = addLovelace a <=< scaleLovelace b

txSizeLinearMinValue :: TxSizeLinear -> Lovelace
txSizeLinearMinValue (TxSizeLinear a _) = a
