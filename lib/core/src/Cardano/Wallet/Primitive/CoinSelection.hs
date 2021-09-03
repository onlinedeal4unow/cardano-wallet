{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Copyright: © 2021 IOHK
-- License: Apache-2.0
--
-- This module provides a high-level interface for coin selection in a Cardano
-- wallet.
--
-- It handles the following responsibilities:
--
--  - selecting inputs from the UTxO set to pay for user-specified outputs;
--  - selecting inputs from the UTxO set to pay for collateral;
--  - producing change outputs to return excess value to the wallet;
--  - balancing a selection to pay for the transaction fee.
--
-- Use the 'performSelection' function to perform a coin selection.
--
module Cardano.Wallet.Primitive.CoinSelection
    ( runWalletCoinSelection
    , SelectionConstraints (..)
    , SelectionParams (..)

    , prepareOutputsForMinUTxO
    , ErrWalletSelection (..)
    , ErrPrepareOutputs (..)
    , ErrOutputTokenBundleSizeExceedsLimit (..)
    , ErrOutputTokenQuantityExceedsLimit (..)
    ) where

import Prelude

import Cardano.Wallet.Primitive.CoinSelection.Balance
    ( SelectionCriteria (..)
    , SelectionError
    , SelectionLimit
    , SelectionResult
    , SelectionSkeleton
    , performSelection
    , prepareOutputsWith
    )
import Cardano.Wallet.Primitive.Types.Address
    ( Address (..) )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (..), addCoin )
import Cardano.Wallet.Primitive.Types.TokenBundle
    ( TokenBundle )
import Cardano.Wallet.Primitive.Types.TokenMap
    ( AssetId, TokenMap )
import Cardano.Wallet.Primitive.Types.TokenQuantity
    ( TokenQuantity )
import Cardano.Wallet.Primitive.Types.Tx
    ( TokenBundleSizeAssessment (..)
    , TokenBundleSizeAssessor (..)
    , TxOut (..)
    , txOutMaxTokenQuantity
    )
import Cardano.Wallet.Primitive.Types.UTxOIndex
    ( UTxOIndex )
import Control.Monad.Random.Class
    ( MonadRandom )
import Control.Monad.Trans.Except
    ( ExceptT (..), withExceptT )
import Data.Generics.Internal.VL.Lens
    ( view )
import Data.Generics.Labels
    ()
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Word
    ( Word16 )
import GHC.Generics
    ( Generic )
import GHC.Stack
    ( HasCallStack )
import Numeric.Natural
    ( Natural )

import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Cardano.Wallet.Primitive.Types.TokenMap as TokenMap
import qualified Data.Foldable as F
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set

-- | Performs a coin selection.
--
-- This function has the following responsibilities:
--
--  - selecting inputs from the UTxO set to pay for user-specified outputs;
--  - selecting inputs from the UTxO set to pay for collateral;
--  - producing change outputs to return excess value to the wallet;
--  - balancing a selection to pay for the transaction fee.
--
runWalletCoinSelection
    :: (HasCallStack, MonadRandom m)
    => SelectionConstraints
    -> SelectionParams
    -> ExceptT ErrWalletSelection m (SelectionResult TokenBundle)
runWalletCoinSelection sc@SelectionConstraints{..} SelectionParams{..} = do
    -- TODO: [ADP-1037] Adjust coin selection and fee estimation to handle
    -- collateral inputs.
    --
    -- TODO: [ADP-1070] Adjust coin selection and fee estimation to handle
    -- pre-existing inputs.
    preparedOutputsToCover <- withExceptT ErrWalletSelectionOutputs $ ExceptT $
        pure $ ensureNonEmptyOutputs >>= prepareOutputsForMinUTxO sc

    withExceptT ErrWalletSelectionBalance $ ExceptT $ fixup <$> performSelection
        computeMinimumAdaQuantity
        computeMinimumCost
        assessTokenBundleSize
        SelectionCriteria
            { outputsToCover = preparedOutputsToCover
            , selectionLimit =
                computeSelectionLimit $ F.toList preparedOutputsToCover
            , extraCoinSource = Just $ rewardWithdrawals
                `plusDeposits` certificateDepositsReturned
            , .. }
  where
    plusDeposits :: Coin -> Natural -> Coin
    plusDeposits amt n = amt `addCoin` scale n depositAmount

    scale :: Natural -> Coin -> Coin
    scale s (Coin a) = Coin (fromIntegral s * a)

    _computeMinimumCostWithDeposits tx = computeMinimumCost tx
        `plusDeposits` certificateDepositsTaken

    extraCoinSink = scale certificateDepositsTaken depositAmount
    extraCoinSinkBundle = TokenBundle.fromCoin extraCoinSink

    ensureNonEmptyOutputs = case NE.nonEmpty outputsToCover of
        Just (TxOut hd amt :| tl) -> Right $
            TxOut hd (TokenBundle.add extraCoinSinkBundle amt) :| tl
        Nothing -> case extraCoinSink of
            Coin 0 -> Left ErrPrepareOutputsTxOutMissing
            amt -> Right $ TxOut dummyAddress (TokenBundle.fromCoin amt) :| []
    dummyAddress = Address ""

    fixup sel = case extraCoinSink of
        Coin 0 -> sel
        amt -> over #outputsCovered (filter ((/= dummyAddress) . view #address))
            . over #changeGenerated (addToHead surplus) $ sel
     where
         surplus = TokenBundle.unsafeSubtract
                (view #tokens (head $ outputsCovered sel))
                extraCoinSinkBundle
{-
selectAssetsNoOutputsBroken
    :: forall ctx s k result.
        ( HasTransactionLayer k ctx
        , HasLogger WalletWorkerLog ctx
        , HasDBLayer IO s k ctx
        , HasNetworkLayer IO ctx
        )
    => ctx
    -> WalletId
    -> (UTxOIndex, Wallet s, Set Tx)
    -> TransactionCtx
    -> (s -> SelectionResult TokenBundle -> result)
    -> ExceptT ErrSelectAssets IO result
selectAssetsNoOutputsBroken ctx wid wal txCtx transform = do
    -- NOTE:
    -- Could be made nicer by allowing 'performSelection' to run with no target
    -- outputs, but to satisfy a minimum Ada target.
    --
    -- To work-around this immediately, I am simply creating a dummy output of
    -- exactly the required deposit amount, only to discard it on the final
    -- result. The resulting selection will therefore have a delta that is at
    -- least the size of the deposit (in practice, slightly bigger because this
    -- extra outputs also increases the apparent minimum fee).
    deposit <- withExceptT ErrSelectAssetsNoSuchWallet $
        calcMinimumDeposit @_ @s @k ctx wid
    let txCtx' = over #txDelegationActions (filter (/= RegisterKey)) txCtx
    let
    let dummyOutput  = TxOut dummyAddress (TokenBundle.fromCoin deposit)
    let outs = dummyOutput :| []
    selectAssets @ctx @s @k ctx wal txCtx' outs $ \s sel -> transform s $ sel
        { outputsCovered = mempty
        , changeGenerated =
            let
                -- NOTE 1: There are in principle 6 cases we may ran into, which
                -- can be grouped in 3 groups of 2 cases:
                --
                -- (1) When registering a key and delegating
                -- (2) When delegating
                -- (3) When de-registering a key
                --
                -- For each case, there may be one or zero change output. For
                -- all 3 cases, we'll treat the case where there's no change
                -- output as an edge-case and also leave no change. This may be
                -- in practice more costly than necessary because, by removing
                -- the fake output, we'd in practice have some more Ada
                -- available to create a change (and a less expensive
                -- transaction). Yet, this would require quite some extra logic
                -- here in addition to all the existing logic inside the
                -- CoinSelection/Balance module already. If we were not
                -- able to add a change output already, let's not try to do it
                -- here. Worse that can be list is:
                --
                --     max (minUTxOValue, keyDepositValue)
                --
                -- which we'll deem acceptable under the circumstances (that can
                -- only really happen if one is trying to delegate with already
                -- a very small Ada balance, so that it's left with no Ada after
                -- having paid for the delegation certificate. Why would one be
                -- delegating almost nothing certainly is an edge-case not worth
                -- considering for too long).
                --
                -- However, if a change output has been create, then we want to
                -- transfer the surplus of value from the change output to that
                -- change output (which is already safe). That surplus is
                -- non-null if the `minUTxOValue` protocol parameter is
                -- non-null, and comes from the fact that the selection
                -- algorithm automatically assigns this value when presented
                -- with a null output. In the case of (1), the output's value is
                -- equal to the stake key deposit value, which may be in
                -- practice greater than the `minUTxOValue`. In the case of (2)
                -- and (3), the deposit is null. So it suffices to subtract
                -- `deposit` to the value of the covered output to get the
                -- surplus.
                --
                -- NOTE 2: This subtraction and head are safe because of the
                -- invariants enforced by the asset selection algorithm. The
                -- output list has the exact same length as the input list, and
                -- outputs are at least as large as the specified outputs.
                surplus = TokenBundle.unsafeSubtract
                    (view #tokens (head $ outputsCovered sel))
                    (TokenBundle.fromCoin deposit)
            in
                surplus `addToHead` changeGenerated sel
        }
  where
-}

-- | Specifies all constraints required for coin selection.
--
-- Selection constraints:
--
--    - place limits on the coin selection algorithm, enabling it to produce
--      selections that are acceptable to the ledger.
--
--    - are dependent on the current set of protocol parameters.
--
--    - are not specific to a given selection.
--
data SelectionConstraints = SelectionConstraints
    { assessTokenBundleSize
        :: TokenBundleSizeAssessor
        -- ^ Assesses the size of a token bundle relative to the upper limit of
        -- what can be included in a transaction output. See documentation for
        -- the 'TokenBundleSizeAssessor' type to learn about the expected
        -- properties of this field.
    , computeMinimumAdaQuantity
        :: TokenMap -> Coin
        -- ^ Computes the minimum ada quantity required for a given output.
    , computeMinimumCost
        :: SelectionSkeleton -> Coin
        -- ^ Computes the minimum cost of a given selection skeleton.
    , computeSelectionLimit
        :: [TxOut] -> SelectionLimit
        -- ^ Computes an upper bound for the number of ordinary inputs to
        -- select, given a current set of outputs.
    , maximumCollateralInputCount
        :: Word16
        -- ^ Specifies an inclusive upper bound on the number of unique inputs
        -- that can be selected as collateral.
    , depositAmount
        :: Coin
        -- ^ Amount that should be taken from/returned back to the wallet for
        -- each stake key registration/de-registration in the transaction.
    }

-- | Specifies all parameters that are specific to a given selection.
--
data SelectionParams = SelectionParams
    { assetsToBurn
        :: !TokenMap
        -- ^ Specifies a set of assets to burn.
    , assetsToMint
        :: !TokenMap
        -- ^ Specifies a set of assets to mint.
    , rewardWithdrawals
        :: !Coin
        -- ^ Specifies the value of a withdrawal from a reward account.
    , certificateDepositsTaken
        :: !Natural
        -- ^ Number of deposits for stake key registrations.
    , certificateDepositsReturned
        :: !Natural
        -- ^ Number of deposits from stake key de-registrations.
    , outputsToCover
        :: ![TxOut]
        -- ^ Specifies a set of outputs that must be paid for.
    , utxoAvailable
        :: !UTxOIndex
        -- ^ Specifies the set of all available UTxO entries. The algorithm
        -- will choose entries from this set when selecting ordinary inputs
        -- and collateral inputs.
    }
    deriving (Eq, Generic, Show)

-- | Indicates that coin selection failed, or a precondition to coin selection
-- failed.
data ErrWalletSelection
    = ErrWalletSelectionBalance SelectionError
    | ErrWalletSelectionOutputs ErrPrepareOutputs
    deriving (Eq, Show)

-- | Prepares the given user-specified outputs, ensuring that they are valid.
--
prepareOutputsForMinUTxO
    :: SelectionConstraints
    -> NonEmpty TxOut
    -> Either ErrPrepareOutputs (NonEmpty TxOut)
prepareOutputsForMinUTxO constraints outputsUnprepared
    | (address, assetCount) : _ <- excessivelyLargeBundles =
        Left $
            -- We encountered one or more excessively large token bundles.
            -- Just report the first such bundle:
            ErrPrepareOutputsTokenBundleSizeExceedsLimit $
            ErrOutputTokenBundleSizeExceedsLimit {address, assetCount}
    | (address, asset, quantity) : _ <- excessiveTokenQuantities =
        Left $
            -- We encountered one or more excessive token quantities.
            -- Just report the first such quantity:
            ErrPrepareOutputsTokenQuantityExceedsLimit $
            ErrOutputTokenQuantityExceedsLimit
                { address
                , asset
                , quantity
                , quantityMaxBound = txOutMaxTokenQuantity
                }
    | otherwise =
        pure outputsToCover
  where
    SelectionConstraints
        { assessTokenBundleSize
        , computeMinimumAdaQuantity
        } = constraints

    -- The complete list of token bundles whose serialized lengths are greater
    -- than the limit of what is allowed in a transaction output:
    excessivelyLargeBundles :: [(Address, Int)]
    excessivelyLargeBundles =
        [ (address, assetCount)
        | output <- F.toList outputsToCover
        , let bundle = view #tokens output
        , bundleIsExcessivelyLarge bundle
        , let address = view #address output
        , let assetCount = Set.size $ TokenBundle.getAssets bundle
        ]

      where
        bundleIsExcessivelyLarge b = case assessSize b of
            TokenBundleSizeWithinLimit -> False
            OutputTokenBundleSizeExceedsLimit -> True
          where
            assessSize = view #assessTokenBundleSize assessTokenBundleSize

    -- The complete list of token quantities that exceed the maximum quantity
    -- allowed in a transaction output:
    excessiveTokenQuantities :: [(Address, AssetId, TokenQuantity)]
    excessiveTokenQuantities =
        [ (address, asset, quantity)
        | output <- F.toList outputsToCover
        , let address = view #address output
        , (asset, quantity) <-
            TokenMap.toFlatList $ view #tokens $ view #tokens output
        , quantity > txOutMaxTokenQuantity
        ]

    outputsToCover = prepareOutputsWith computeMinimumAdaQuantity
        outputsUnprepared

-- | Indicates a problem when preparing outputs for a coin selection.
--
data ErrPrepareOutputs
    = ErrPrepareOutputsTokenBundleSizeExceedsLimit
        ErrOutputTokenBundleSizeExceedsLimit
    | ErrPrepareOutputsTokenQuantityExceedsLimit
        ErrOutputTokenQuantityExceedsLimit
    | ErrPrepareOutputsTxOutMissing
    deriving (Eq, Generic, Show)

data ErrOutputTokenBundleSizeExceedsLimit = ErrOutputTokenBundleSizeExceedsLimit
    { address :: !Address
      -- ^ The address to which this token bundle was to be sent.
    , assetCount :: !Int
      -- ^ The number of assets within the token bundle.
    }
    deriving (Eq, Generic, Show)

-- | Indicates that a token quantity exceeds the maximum quantity that can
--   appear in a transaction output's token bundle.
--
data ErrOutputTokenQuantityExceedsLimit = ErrOutputTokenQuantityExceedsLimit
    { address :: !Address
      -- ^ The address to which this token quantity was to be sent.
    , asset :: !AssetId
      -- ^ The asset identifier to which this token quantity corresponds.
    , quantity :: !TokenQuantity
      -- ^ The token quantity that exceeded the bound.
    , quantityMaxBound :: !TokenQuantity
      -- ^ The maximum allowable token quantity.
    }
    deriving (Eq, Generic, Show)
