{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumDecimals       #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeApplications  #-}

-- | Generation of genesis data for testnet

module Cardano.Chain.Genesis.Generate
  ( GeneratedSecrets(..)
  , gsSigningKeys
  , gsSigningKeysPoor
  , PoorSecret(..)
  , generateGenesisData
  , generateGenesisConfig
  , GenesisDataGenerationError(..)
  )
where

import Cardano.Prelude

import Crypto.Random (MonadRandom, getRandomBytes)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.Time (UTCTime)
import Data.Coerce (coerce)
import Formatting (build, bprint, int, stext)
import qualified Formatting.Buildable as B

import Cardano.Binary (serialize')
import Cardano.Chain.Common
  ( Address
  , Lovelace
  , LovelaceError
  , naturalToLovelace
  , addLovelace
  , divLovelace
  , makeVerKeyAddress
  , hashKey
  , modLovelace
  , scaleLovelace
  , scaleLovelaceRational
  , subLovelace
  , sumLovelace
  )
import Cardano.Chain.Common.NetworkMagic (makeNetworkMagic)
import qualified Cardano.Chain.Delegation.Certificate as Delegation
import Cardano.Chain.Genesis.AvvmBalances (GenesisAvvmBalances(..))
import Cardano.Chain.Genesis.Data (GenesisData(..))
import Cardano.Chain.Genesis.Delegation
  (GenesisDelegation(..), GenesisDelegationError, mkGenesisDelegation)
import Cardano.Chain.Genesis.Hash (GenesisHash(..))
import Cardano.Chain.Genesis.Initializer
  (FakeAvvmOptions(..), GenesisInitializer(..), TestnetBalanceOptions(..))
import Cardano.Chain.Genesis.NonAvvmBalances (GenesisNonAvvmBalances(..))
import Cardano.Chain.Genesis.Spec (GenesisSpec(..))
import Cardano.Chain.Genesis.Config (Config(..))
import Cardano.Chain.UTxO.UTxOConfiguration (defaultUTxOConfiguration)
import Cardano.Chain.Genesis.KeyHashes (GenesisKeyHashes(..))
import Cardano.Crypto
  ( SigningKey
  , deterministic
  , getProtocolMagicId
  , getRequiresNetworkMagic
  , hash
  , keyGen
  , noPassSafeSigner
  , redeemDeterministicKeyGen
  , toCompactRedeemVerificationKey
  , toVerification
  )


-- | Poor node secret
newtype PoorSecret = PoorSecret { poorSecretToKey :: SigningKey }
  deriving (Generic, NoUnexpectedThunks)

-- | Valuable secrets which can unlock genesis data.
data GeneratedSecrets = GeneratedSecrets
    { gsDlgIssuersSecrets :: ![SigningKey]
    -- ^ Secret keys which issued heavyweight delegation certificates
    -- in genesis data. If genesis heavyweight delegation isn't used,
    -- this list is empty.
    , gsRichSecrets       :: ![SigningKey]
    -- ^ All secrets of rich nodes.
    , gsPoorSecrets       :: ![PoorSecret]
    -- ^ Keys for HD addresses of poor nodes.
    , gsFakeAvvmSeeds     :: ![ByteString]
    -- ^ Fake avvm seeds.
    }
  deriving (Generic, NoUnexpectedThunks)

gsSigningKeys :: GeneratedSecrets -> [SigningKey]
gsSigningKeys gs = gsRichSecrets gs <> gsSigningKeysPoor gs

gsSigningKeysPoor :: GeneratedSecrets -> [SigningKey]
gsSigningKeysPoor = map poorSecretToKey . gsPoorSecrets

data GenesisDataGenerationError
  = GenesisDataAddressBalanceMismatch Text Int Int
  | GenesisDataGenerationDelegationError GenesisDelegationError
  | GenesisDataGenerationDistributionMismatch Lovelace Lovelace
  | GenesisDataGenerationLovelaceError LovelaceError
  | GenesisDataGenerationPassPhraseMismatch
  | GenesisDataGenerationRedeemKeyGen
  deriving (Eq, Show)

instance B.Buildable GenesisDataGenerationError where
  build = \case
    GenesisDataAddressBalanceMismatch distr addresses balances ->
      bprint ("GenesisData address balance mismatch, Distribution: "
             . stext
             . " Addresses list length: "
             . int
             . " Balances list length: "
             . int
             )
             distr
             addresses
             balances
    GenesisDataGenerationDelegationError genesisDelegError ->
      bprint ("GenesisDataGenerationDelegationError: "
             . build
             )
             genesisDelegError
    GenesisDataGenerationDistributionMismatch testBalance totalBalance ->
      bprint ("GenesisDataGenerationDistributionMismatch: Test balance: "
             . build
             . " Total balance: "
             . build
             )
             testBalance
             totalBalance
    GenesisDataGenerationLovelaceError lovelaceErr ->
      bprint ("GenesisDataGenerationLovelaceError: "
             . build
             )
             lovelaceErr
    GenesisDataGenerationPassPhraseMismatch ->
      bprint "GenesisDataGenerationPassPhraseMismatch"
    GenesisDataGenerationRedeemKeyGen ->
      bprint "GenesisDataGenerationRedeemKeyGen"

-- | In Cardano Byron, the total supply is always limited to 45e15 Lovelace.
--
genesisMaximumLovelaceSupply :: Lovelace
genesisMaximumLovelaceSupply = naturalToLovelace 45e15

generateGenesisData
  :: MonadError GenesisDataGenerationError m
  => UTCTime
  -> GenesisSpec
  -> m (GenesisData, GeneratedSecrets)
generateGenesisData startTime genesisSpec = do
  -- Genesis Keys
  let
    genesisSecrets =
      if giUseHeavyDlg gi then dlgIssuersSecrets else richSecrets

    genesisKeyHashes :: GenesisKeyHashes
    genesisKeyHashes =
      GenesisKeyHashes
        .   Set.fromList
        $   hashKey
        .   toVerification
        <$> genesisSecrets

  -- Heavyweight delegation.
  -- genesisDlgList is empty if giUseHeavyDlg = False
  let
    genesisDlgList :: [Delegation.Certificate]
    genesisDlgList =
      (\(issuerSK, delegateSK) -> Delegation.signCertificate
          (getProtocolMagicId pm)
          (toVerification delegateSK)
          0
          (noPassSafeSigner issuerSK)
        )
        <$> zip dlgIssuersSecrets richSecrets

  genesisDlg <-
    mkGenesisDelegation
        (  M.elems (unGenesisDelegation $ gsHeavyDelegation genesisSpec)
        <> genesisDlgList
        )
      `wrapError` GenesisDataGenerationDelegationError

  -- Real AVVM Balances
  let
    applyAvvmBalanceFactor :: Map k Lovelace -> Map k Lovelace
    applyAvvmBalanceFactor =
      map (flip scaleLovelaceRational (giAvvmBalanceFactor gi))

    realAvvmMultiplied :: GenesisAvvmBalances
    realAvvmMultiplied =
      GenesisAvvmBalances . applyAvvmBalanceFactor $ unGenesisAvvmBalances
        realAvvmBalances

  -- Fake AVVM Balances
  fakeAvvmVerificationKeys <-
    mapM
      (maybe (throwError GenesisDataGenerationRedeemKeyGen)
             (pure . toCompactRedeemVerificationKey . fst))
      $ fmap redeemDeterministicKeyGen (gsFakeAvvmSeeds generatedSecrets)
  let
    fakeAvvmDistr = GenesisAvvmBalances . M.fromList $ map
      (, faoOneBalance fao)
      fakeAvvmVerificationKeys

  -- Non AVVM balances
  ---- Addresses
  let
    createAddressPoor
      :: MonadError GenesisDataGenerationError m => PoorSecret -> m Address
    createAddressPoor (PoorSecret secret) =
      pure $ makeVerKeyAddress nm (toVerification secret)
  let richAddresses = map (makeVerKeyAddress nm . toVerification) richSecrets

  poorAddresses        <- mapM createAddressPoor poorSecrets

  ---- Balances
  let totalFakeAvvmBalance = scaleLovelace (faoOneBalance fao) (faoCount fao)

  -- Compute total balance to generate
  let avvmSum = sumLovelace (unGenesisAvvmBalances realAvvmMultiplied)

  maxTnBalance <-
    subLovelace genesisMaximumLovelaceSupply avvmSum
      `wrapError` GenesisDataGenerationLovelaceError
  let tnBalance = min maxTnBalance (tboTotalBalance tbo)

  let
    safeZip
      :: MonadError GenesisDataGenerationError m
      => Text
      -> [a]
      -> [b]
      -> m [(a, b)]
    safeZip s a b = if length a /= length b
      then throwError
        $ GenesisDataAddressBalanceMismatch s (length a) (length b)
      else pure $ zip a b

  nonAvvmBalance <-
    subLovelace tnBalance totalFakeAvvmBalance
      `wrapError` GenesisDataGenerationLovelaceError

  (richBals, poorBals) <- genTestnetDistribution tbo nonAvvmBalance

  richDistr <- safeZip "richDistr" richAddresses richBals
  poorDistr <- safeZip "poorDistr" poorAddresses poorBals

  let
    nonAvvmDistr = GenesisNonAvvmBalances . M.fromList $ richDistr ++ poorDistr

  let
    genesisData = GenesisData
      { gdGenesisKeyHashes = genesisKeyHashes
      , gdHeavyDelegation = genesisDlg
      , gdStartTime = startTime
      , gdNonAvvmBalances = nonAvvmDistr
      , gdProtocolParameters = gsProtocolParameters genesisSpec
      , gdK         = gsK genesisSpec
      , gdProtocolMagicId = getProtocolMagicId pm
      , gdAvvmDistr = fakeAvvmDistr <> realAvvmMultiplied
      }

  pure (genesisData, generatedSecrets)
 where
  pm          = gsProtocolMagic genesisSpec
  nm          = makeNetworkMagic pm
  realAvvmBalances = gsAvvmDistr genesisSpec

  gi          = gsInitializer genesisSpec

  generatedSecrets = generateSecrets gi
  dlgIssuersSecrets = gsDlgIssuersSecrets generatedSecrets
  richSecrets = gsRichSecrets generatedSecrets
  poorSecrets = gsPoorSecrets generatedSecrets

  fao         = giFakeAvvmBalance gi
  tbo         = giTestBalance gi


generateSecrets :: GenesisInitializer -> GeneratedSecrets
generateSecrets gi = deterministic (serialize' $ giSeed gi) $ do

  -- Generate fake AVVM seeds
  fakeAvvmSeeds <- replicateM (fromIntegral $ faoCount fao) (getRandomBytes 32)

  -- Generate secret keys
  dlgIssuersSecrets <- if giUseHeavyDlg gi
    then replicateRich (snd <$> keyGen)
    else pure []

  richSecrets <- replicateRich (snd <$> keyGen)

  poorSecrets <- replicateM (fromIntegral $ tboPoors tbo) genPoorSecret

  pure $ GeneratedSecrets
    { gsDlgIssuersSecrets = dlgIssuersSecrets
    , gsRichSecrets       = richSecrets
    , gsPoorSecrets       = poorSecrets
    , gsFakeAvvmSeeds     = fakeAvvmSeeds
    }
 where
  fao = giFakeAvvmBalance gi
  tbo = giTestBalance gi

  replicateRich :: Applicative m => m a -> m [a]
  replicateRich = replicateM (fromIntegral $ tboRichmen tbo)

  genPoorSecret :: MonadRandom m => m PoorSecret
  genPoorSecret = PoorSecret . snd <$> keyGen


----------------------------------------------------------------------------
-- Generating a Genesis Config
----------------------------------------------------------------------------

-- | Generate a genesis 'Config' from a 'GenesisSpec'. This is used only for
-- tests. For the real node we always generate an external JSON genesis file.
--
generateGenesisConfig
  :: MonadError GenesisDataGenerationError m
  => UTCTime -> GenesisSpec -> m (Config, GeneratedSecrets)
generateGenesisConfig startTime genesisSpec = do
    (genesisData, generatedSecrets) <- generateGenesisData startTime genesisSpec

    let config = Config
          { configGenesisData       = genesisData
          , configGenesisHash       = genesisHash
          , configReqNetMagic       = getRequiresNetworkMagic
                                        (gsProtocolMagic genesisSpec)
          , configUTxOConfiguration = defaultUTxOConfiguration
          }
    return (config, generatedSecrets)
  where
    -- Anything will do for the genesis hash. A hash of "patak" was used before,
    -- and so it remains. Here lies the last of the Serokell code. RIP.
    genesisHash = GenesisHash $ coerce $ hash ("patak" :: Text)


----------------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------------

-- | Generates balance distribution for testnet
genTestnetDistribution
  :: MonadError GenesisDataGenerationError m
  => TestnetBalanceOptions
  -> Lovelace
  -> m ([Lovelace], [Lovelace])
genTestnetDistribution TestnetBalanceOptions {
                         tboPoors,
                         tboRichmen,
                         tboRichmenShare
                       } testBalance = do

    let desiredRichBalance  = scaleLovelaceRational testBalance tboRichmenShare
        richmanBalance      = divLovelace desiredRichBalance tboRichmen
        richmanBalanceExtra = modLovelace desiredRichBalance tboRichmen

        richmanBalance'
          | tboRichmen == 0 = naturalToLovelace 0
          | otherwise       = addLovelace
                                richmanBalance
                                (if richmanBalanceExtra > naturalToLovelace 0
                                  then naturalToLovelace 1
                                  else naturalToLovelace 0
                                )

        totalRichBalance    = scaleLovelace richmanBalance' tboRichmen

    desiredPoorsBalance <- subLovelace testBalance totalRichBalance
                             `wrapError` GenesisDataGenerationLovelaceError

    let poorBalance
          | tboPoors == 0 = naturalToLovelace 0
          | otherwise     = divLovelace desiredPoorsBalance tboPoors

        totalPoorBalance  = scaleLovelace poorBalance tboPoors

        totalBalance      = addLovelace totalRichBalance totalPoorBalance

        richBalances      = replicate (fromIntegral tboRichmen) richmanBalance'
        poorBalances      = replicate (fromIntegral tboPoors)   poorBalance

    (totalBalance <= testBalance)
      `orThrowError`  GenesisDataGenerationDistributionMismatch
                        testBalance totalBalance

    pure (richBalances, poorBalances)

