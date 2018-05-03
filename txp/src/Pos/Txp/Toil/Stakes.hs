{-# LANGUAGE TypeFamilies #-}

-- | Functions which work in 'GlobalToilM' and are part of Toil logic
-- related to stakes.

module Pos.Txp.Toil.Stakes
       ( applyTxsToStakes
       , rollbackTxsStakes
       ) where

import           Universum

import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS

import           Pos.Core (HasGenesisData, StakesList, StakeholderId, coinToInteger,
                           mkCoin, sumCoins, unsafeIntegerToCoin)
import           Pos.Core.Txp (Tx (..), TxAux (..), TxOutAux (..), TxUndo)
import           Pos.Txp.Base (txOutStake)
import           Pos.Txp.Toil.Monad (GlobalToilM, getStake, getTotalStake, setStake, setTotalStake)

-- | Apply transactions to stakes.
-- Returned list is those 'StakeholderId's which were created.
applyTxsToStakes :: HasGenesisData => [(TxAux, TxUndo)] -> GlobalToilM [StakeholderId]
applyTxsToStakes txun = do
    let (txOutPlus, txInMinus) = concatStakes txun
    recomputeStakes txOutPlus txInMinus

-- | Rollback application of transactions to stakes.
-- Returned list is those 'StakeholderId's which were created.
-- FIXME look into this. Why should rolling back lead to created stakes?
rollbackTxsStakes :: HasGenesisData => [(TxAux, TxUndo)] -> GlobalToilM [StakeholderId]
rollbackTxsStakes txun = do
    let (txOutMinus, txInPlus) = concatStakes txun
    recomputeStakes txInPlus txOutMinus

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- | Compute new stakeholder's stakes by lists of spent and received coins.
-- The 'StakeholderId's which are created are returned.
recomputeStakes
    :: StakesList
    -> StakesList
    -> GlobalToilM [StakeholderId]
recomputeStakes plusDistr minusDistr = do
    let (plusStakeHolders, plusCoins) = unzip plusDistr
        (minusStakeHolders, minusCoins) = unzip minusDistr
        needResolve =
            HS.toList $
            HS.fromList plusStakeHolders `HS.union`
            HS.fromList minusStakeHolders
    resolvedStakesRaw <- mapM resolve needResolve
    let resolvedStakes = map fst resolvedStakesRaw
    let createdStakes = concatMap snd resolvedStakesRaw
    totalStake <- getTotalStake
    let (positiveDelta, negativeDelta) = (sumCoins plusCoins, sumCoins minusCoins)
        newTotalStake = unsafeIntegerToCoin $
                        coinToInteger totalStake + positiveDelta - negativeDelta
    let newStakes
          = HM.toList $
            -- It's safe befause user's stake can't be more than a
            -- limit. Also we first add then subtract, so we return to
            -- the word64 range.
            map unsafeIntegerToCoin $
            calcNegStakes minusDistr
                (calcPosStakes $ zip needResolve resolvedStakes ++ plusDistr)
    setTotalStake newTotalStake
    mapM_ (uncurry setStake) newStakes
    pure createdStakes
  where
    resolve ad = getStake ad >>= \case
        Just x -> pure (x, [])
        Nothing -> pure (mkCoin 0, [ad])
    calcPosStakes = foldl' plusAt HM.empty
    -- This implementation does all the computation using
    -- Integer. Maybe it's possible to do it in word64. (@volhovm)
    calcNegStakes distr hm = foldl' minusAt hm distr
    plusAt hm (key, c) = HM.insertWith (+) key (coinToInteger c) hm
    minusAt hm (key, c) =
        HM.alter (maybe err (\v -> Just (v - coinToInteger c))) key hm
      where
        -- FIXME do not use 'error'?
        err = error ("recomputeStakes: no stake for " <> show key)

-- Concatenate stakes of the all passed transactions and undos.
concatStakes :: HasGenesisData => [(TxAux, TxUndo)] -> (StakesList, StakesList)
concatStakes (unzip -> (txas, undo)) = (txasTxOutDistr, undoTxInDistr)
  where
    onlyKnownUndos = catMaybes . toList
    txasTxOutDistr = concatMap concatDistr txas
    undoTxInDistr = concatMap (txOutStake . toaOut) (foldMap onlyKnownUndos undo)
    concatDistr (TxAux UnsafeTx {..} _) =
        concatMap (txOutStake . toaOut) $ toList (map TxOutAux _txOutputs)
