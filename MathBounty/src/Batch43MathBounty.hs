{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-# LANGUAGE NumericUnderscores #-}

module Batch43MathBounty where

import           Control.Monad             (void)
import Data.Default               (Default (..))
import Data.Text                  (Text)
import Data.Void
import Data.Map as Map
import qualified PlutusTx         as PlutusTx
import           PlutusTx.Prelude hiding (pure, (<$>), Semigroup (..))
import           Plutus.Contract
import           Plutus.Trace.Emulator  as Emulator
import           Ledger                    
import qualified Ledger.Constraints        as Constraints
import qualified Ledger.Typed.Scripts      as Scripts
import           Ledger.Ada                as Ada
import           Playground.Contract
import qualified Prelude
import Prelude (IO, Show, String, show, Semigroup (..))
import           Text.Printf          (printf)
import Ledger.TimeSlot
import qualified Plutus.Trace as Trace
import Wallet.Emulator.Wallet
import qualified Control.Monad.Freer.Extras as Extras
import PlutusTx.IsData.Class (toBuiltinData)

--ON-CHAIN

data MathBountyDatum = MBD 
                     { mbInput    :: Integer
                     , mbDeadline :: POSIXTime }  

PlutusTx.unstableMakeIsData ''MathBountyDatum

{-# INLINABLE mathBountyValidator #-}
mathBountyValidator :: MathBountyDatum -> Integer -> ScriptContext -> Bool
mathBountyValidator datum guess sContext = traceIfFalse "Wrong guess!" ((mbInput datum) == guess * guess) &&
                                           traceIfFalse "Deadline passed!" deadlineNotReached
    where 
        info :: TxInfo
        info = scriptContextTxInfo sContext

        deadlineNotReached :: Bool
        deadlineNotReached = contains (to $ mbDeadline datum) (txInfoValidRange info)
                          -- (to $ mbDeadline datum) `contains` (txInfoValidRange info)

data MathBounty
instance Scripts.ValidatorTypes MathBounty where
    type instance RedeemerType MathBounty = Integer
    type instance DatumType MathBounty = MathBountyDatum

bountyValidator :: Scripts.TypedValidator MathBounty
bountyValidator = Scripts.mkTypedValidator @MathBounty
                $$(PlutusTx.compile [|| mathBountyValidator ||])
                $$(PlutusTx.compile [|| wrap ||])
    where
        wrap = Scripts.wrapValidator @MathBountyDatum @Integer


validator :: Validator  -- Validator {<scripts>}
validator = Scripts.validatorScript bountyValidator

bountyAddress :: Ledger.Address
bountyAddress = scriptAddress validator  

-- Equivalent to Cardano-CLI cardano-cli address build --payment-script-file <JSON encoded CBORhex of script> $TESTNET --out-file <some output file>

--OFF-CHAIN

data BountyParams = BP
                  { bpInput  :: Integer
                  , bpAmount :: Integer
                  , bpDeadline :: POSIXTime
                  } deriving (Generic, FromJSON, ToJSON, Show, ToSchema)

type MathBountySchema =
        Endpoint "bounty" BountyParams
    .\/ Endpoint "solution" Integer  

bounty :: BountyParams -> Contract () MathBountySchema Text ()
bounty (BP input amount deadline) = do 
                                  let datum = MBD 
                                              { mbInput    = input
                                              , mbDeadline = deadline}  
                                      tx = Constraints.mustPayToTheScript datum (Ada.lovelaceValueOf amount)                                                                     
                                  ledgerTx <- submitTxConstraints bountyValidator tx
                                  void $ awaitTxConfirmed $ getCardanoTxId ledgerTx
                                  logInfo @String $ printf "Bounty created of amount = %s" (show amount)


solution :: Integer -> Contract () MathBountySchema Text ()
solution guess = do
                 now <- currentTime
                 utxos <- utxosAt bountyAddress
                 logInfo @String $ printf "The utxos: %s " (show $ Map.toList utxos)
                 case Map.toList utxos of
                    []                 -> logInfo @String $ printf "No UTxOs on the Contract!"
                    (oref,a):xs        -> do
                                          let lookups = Constraints.otherScript validator  <>
                                                        Constraints.unspentOutputs (Map.fromList [(oref,a)])
                                              tx      = Constraints.mustSpendScriptOutput oref (Redeemer $ toBuiltinData guess) <>
                                                        Constraints.mustValidateIn (to now)
                                          ledgerTx <- submitTxConstraintsWith @Void lookups tx
                                          void $ awaitTxConfirmed $ getCardanoTxId ledgerTx
                                          logInfo @String $ printf "Proposed solution was: %s " (show guess)

endpoints :: Contract () MathBountySchema Text ()
endpoints = awaitPromise (bounty' `select` solution') >> endpoints
  where 
    bounty'   = endpoint @"bounty" bounty
    solution' = endpoint @"solution" solution

mkSchemaDefinitions ''MathBountySchema
mkKnownCurrencies []

