{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

 -- | This module converts `CardanoConfiguration` to `Genesis.Config`

module Cardano.Chain.Conversion
  ( convertConfig
  )
where

import Cardano.Prelude

import Text.Megaparsec
import Text.Megaparsec.Char (string)

import Cardano.Binary (Raw)
import Cardano.Chain.Genesis.Config
  ( Config
  , ConfigurationError(..)
  , mkConfigFromFile
  )
import Cardano.Crypto.Hashing (Hash, decodeAbstractHash)
import Cardano.Crypto.ProtocolMagic
  (RequiresNetworkMagic(..))
import Cardano.Shell.Constants.Types as Shell


-- | Converts 'CardanoConfiguration' (from 'cardano-shell') into a 'Config' (from 'cardano-ledger')
--   This function mostly relies on FromJSON parsing, because much of 'Config' originates from
--   data locked in the genesis block as JSON. Sadly when generating the 'Config' for mainnet,
--   this means that `cardano-ledger` can't benefit as much from `cardano-shell`'s function as
--   an insulating layer around config & parsing. - @mhuesch
convertConfig
  :: (MonadIO m, MonadError ConfigurationError m)
  => Shell.CardanoConfiguration
  -> m Config
convertConfig cc = do

    -- Genesis hash
    let mainnetGenFp = geSrc . coGenesis $ ccCore cc
    gHash <- decodeGenesisHash genesisHash `wrapError` GenesisHashDecodeError

    -- RequiresNetworkMagic
    reqNM <- reqNetworkMagic `wrapError` ConfigParsingError

    mkConfigFromFile reqNM mainnetGenFp gHash

 where
  decodeGenesisHash :: Text -> Either Text (Hash Raw)
  decodeGenesisHash genHash = decodeAbstractHash genHash
  genesisHash :: Text
  genesisHash = geGenesisHash . coGenesis $ ccCore cc
  reqNetworkMagic :: Either (ParseErrorBundle Text Void) RequiresNetworkMagic
  reqNetworkMagic = runParser
    pRequiresNetworkMagic
    "Cardano.Chain.Conversion"
    (coRequiresNetworkMagic $ ccCore cc)

--------------------------------------------------------------------------------
-- Parsers
--------------------------------------------------------------------------------

pRequiresNetworkMagic :: Parsec Void Text RequiresNetworkMagic
pRequiresNetworkMagic = choice
  [ RequiresNoMagic <$ string "RequiresNoMagic"
  , RequiresMagic <$ string "RequiresMagic"
  ]
