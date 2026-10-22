use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, PaymentCredential, Script}
use cardano/assets.{ada_policy_id, add, flatten, quantity_of, without_lovelace}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/finance
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/asset_manager.{AssetManagerDatumWithToken} as r
use fluidtokens/types/general.{Asset, CollateralAsset, Liquidation}
use fluidtokens/types/lender_manager.{
  LMLiquidatePayInAdvanceAndCompoundWithdrawRedeemer, LenderManagerDatum,
} as lm
use fluidtokens/types/loan.{LoanDatum} as loan
use fluidtokens/types/pool.{PoolDatum}
use fluidtokens/types/pool_manager.{PoolManagerDatum}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderManagerSpendScriptHash: ByteArray,
  assetManagerSpendScriptHash: ByteArray,
  assetManagerWithdrawScriptHash: ByteArray,
  poolManagerSpendScriptHash: ByteArray,
  poolManagerPolicyId: ByteArray,
  loanClaimPaymentCredential: PaymentCredential,
) {
  withdraw(
    redeemer: LMLiquidatePayInAdvanceAndCompoundWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let repaymentPolicyId = builtin.un_b_data(utils.safe_list_at(config, 7))
    let loanWithdrawScriptHash = loanPolicyId
    expect (Finite(validFrom), Finite(validTo)) =
      (
        self.validity_range.lower_bound.bound_type,
        self.validity_range.upper_bound.bound_type,
      )
    //Lender bonds always reside in lender_manager.ak, so we don't need to consider CIP113 utxos
    let lenderBondInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            lenderManagerSpendScriptHash,
          )
        },
      )
    //Lender bonds always reside in lender_manager.ak, so we don't need to consider CIP113 utxos
    let lenderBondOutputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(
            lenderManagerSpendScriptHash,
          )
        },
      )
    let assetInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(assetManagerSpendScriptHash),
        Script(assetManagerWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    let poolManagerInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        },
      )
    let poolManagerOutputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        },
      )
    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        Script(poolPolicyId),
        smartTokensSpendScriptHash,
      )
    let poolOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(poolSpendScriptHash),
        Script(poolPolicyId),
        smartTokensSpendScriptHash,
      )
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )

    //Use oracles to convert the collateral to principal asset and sum them up for each pool manager
    let totalConvertedClaimedCollateralForEachPoolManager =
      list.indexed_foldr(
        loanInputs,
        dict.empty,
        fn(index, loanInput, result) {
          let (principalOracleRefInputIndex, collateralOracleRefInputIndex) =
            safe_list_at(
              redeemer.principalAndCollateralOracleRefInputIndexes,
              index,
            )
          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)
          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          let collateralOracleRefInput =
            safe_list_at(self.reference_inputs, collateralOracleRefInputIndex)
          let principalOracleRefInput =
            safe_list_at(self.reference_inputs, principalOracleRefInputIndex)

          expect InlineDatum(loanInputDatum) = loanInput.output.datum
          expect LoanDatum {
            collateral,
            principalOracleAsset,
            principalAsset,
            ..
          } = loanInputDatum
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderManagerDatum {
            shouldLiquidationConvertToPrincipal,
            poolId,
            liquidationFeePerMille,
            ..
          } = inputLenderBondDatum
          // Ensure liquidationFeePerMille is non-negative
          expect liquidationFeePerMille >= 0
          expect Some(loanRedeemer) =
            pairs.get_first(
              self.redeemers,
              Withdraw(loanClaimPaymentCredential),
            )
          expect parsedLoanRedeemer: loan.LoanClaimActionWithdrawRedeemer =
            loanRedeemer
          let loanInputAction =
            safe_list_at(parsedLoanRedeemer.actionsForEachInput, index)
          let lenderBondOutput =
            safe_list_at(lenderBondOutputs, lenderBondIndex)
          let collateralPolicyId = collateral.policyId
          expect Some(collateralAssetName) = collateral.maybeAssetName
          let collateralOracleToken = collateral.oracleTokenAsset
          expect Some(collateralOraclePriceFeed) =
            retrieve_oracle_data(
              collateralOracleRefInput.output.address.payment_credential,
              collateralOracleRefInput.output.value,
              self.redeemers,
              validFrom,
              validTo,
              collateralOracleToken.policyId,
              collateralOracleToken.assetName,
              collateralPolicyId,
              collateral.maybeAssetName,
            )
          expect Some(principalOraclePriceFeed) =
            retrieve_oracle_data(
              principalOracleRefInput.output.address.payment_credential,
              principalOracleRefInput.output.value,
              self.redeemers,
              validFrom,
              validTo,
              principalOracleAsset.policyId,
              principalOracleAsset.assetName,
              principalAsset.policyId,
              Some(principalAsset.assetName),
            )
          let loanCollateralAmount =
            quantity_of(
              loanInput.output.value,
              collateralPolicyId,
              collateralAssetName,
            )
          expect Liquidation { equityInPrincipalCurrency, .. } =
            loanInputAction.liquidationMode
          expect equityInPrincipalCurrency == False
          let liquidationFee =
            loanCollateralAmount * liquidationFeePerMille / 1000
          let loanCollateralToSend =
            loanCollateralAmount - loanInputAction.equity - liquidationFee
          let convertedLoanCollateralToPrincipalAmount =
            finance.convertFromAToBWithOracles(
              collateralOraclePriceFeed,
              principalOraclePriceFeed,
              rational.from_int(loanCollateralToSend),
            )

          let lenderBondAssetName =
            safe_list_at(redeemer.lenderBondAssetNames, index)

          expect and {
              //Loan NFT AssetName must be same of lender bond
              quantity_of(
                loanInput.output.value,
                loanPolicyId,
                lenderBondAssetName,
              ) == 1,
              //Lender bond must be present in input
              quantity_of(
                lenderBondInput.output.value,
                lenderBondPolicyId,
                lenderBondAssetName,
              ) == 1,
              //Lender bond must allow conversion to principal
              shouldLiquidationConvertToPrincipal,
              //Output with lender bond must be the same as input
              builtin.equals_data(lenderBondInput.output, lenderBondOutput),
            }

          dict.insert_with(
            result,
            poolId,
            convertedLoanCollateralToPrincipalAmount,
            fn(_k, a, b) { Some(a + b) },
          )
        },
      )

    //Add repayments sitting in the lm to the total to compound for each pool manager
    let totalAssetsToCompoundForEachPoolManager =
      list.indexed_foldr(
        assetInputs,
        totalConvertedClaimedCollateralForEachPoolManager,
        fn(index, assetInput, result) {
          expect InlineDatum(assetInputDatum) = assetInput.output.datum
          expect AssetManagerDatumWithToken { ownerAsset, .. } = assetInputDatum

          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)

          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderManagerDatum {
            principalAsset,
            poolId,
            liquidationFeePerMille,
            ..
          } = inputLenderBondDatum
          // Ensure liquidationFeePerMille is non-negative
          expect liquidationFeePerMille >= 0
          let assetAmount =
            quantity_of(
              assetInput.output.value,
              principalAsset.policyId,
              principalAsset.assetName,
            )
          let receiptNFTCount =
            utils.quantity_of_policy_id(
              assetInput.output.value,
              repaymentPolicyId,
            )

          expect
            if principalAsset.policyId == ada_policy_id {
              // 1. If principal asset is ADA, ensure no other tokens are present, except eventual receipt NFT
              list.length(flatten(assetInput.output.value)) == 1 + receiptNFTCount
            } else {
              // 2. If principal asset is not ADA, ensure only min-ADA and principal token are present, except eventual receipt NFT
              list.length(flatten(assetInput.output.value)) == 2 + receiptNFTCount
            }

          //Selected lender bond must correspond to the ownerAsset of the datum
          expect
            quantity_of(
              lenderBondInput.output.value,
              ownerAsset.policyId,
              ownerAsset.assetName,
            ) == 1

          dict.insert_with(
            result,
            poolId,
            assetAmount,
            fn(_k, a, b) { Some(a + b) },
          )
        },
      )

    let allCompoundedPoolsAreCorrect =
      utils.indexed_all(
        poolManagerInputs,
        fn(index, poolManagerInput) {
          let poolId = safe_list_at(redeemer.poolIds, index)
          expect Some(addedLiquidity) =
            dict.get(totalAssetsToCompoundForEachPoolManager, poolId)
          let poolManagerOutput = safe_list_at(poolManagerOutputs, index)
          let poolInputIndex = safe_list_at(redeemer.poolInputIndexes, index)
          let poolInput = safe_list_at(poolInputs, poolInputIndex)
          let poolOutput = safe_list_at(poolOutputs, poolInputIndex)
          expect InlineDatum(poolManagerDatum) = poolManagerInput.output.datum
          expect PoolManagerDatum { compoudingFeePerMille, .. } =
            poolManagerDatum
          expect InlineDatum(oldPoolDatum) = poolInput.output.datum
          expect PoolDatum { commonData, .. } = oldPoolDatum
          let principal = commonData.principalAsset
          let compoundingFee =
            finance.get_compounding_fee(
              addedLiquidity,
              compoudingFeePerMille,
              principal.policyId,
            )
          //Value must be same except for the added principal
          let correctOutputValue =
            if principal.policyId == ada_policy_id {
              builtin.equals_data(
                poolOutput.value,
                poolInput.output.value
                  |> add(
                      principal.policyId,
                      principal.assetName,
                      addedLiquidity - compoundingFee,
                    ),
              )
            } else {
              builtin.equals_data(
                without_lovelace(poolOutput.value),
                without_lovelace(
                  poolInput.output.value
                    |> add(
                        principal.policyId,
                        principal.assetName,
                        addedLiquidity - compoundingFee,
                      ),
                ),
              )
            }

          and {
            //If poolId is "", no compounding allowed so the whole action must fail
            poolId != "",
            //Input poolManager must contain the NFT specified in the lender bond datums
            quantity_of(
              poolManagerInput.output.value,
              poolManagerPolicyId,
              poolId,
            ) == 1,
            //Pool must have same PoolManager asset name
            quantity_of(poolInput.output.value, poolPolicyId, poolId) == 1,
            //Pool compound action already ensures datum and address are correct
            correctOutputValue,
            //PoolManager must be same in input and output
            builtin.equals_data(poolManagerOutput, poolManagerInput.output),
          }
        },
      )

    let allLenderBondsAreCorrect =
      utils.indexed_all(
        lenderBondInputs,
        fn(index, lenderBondInput) {
          let lenderBondOutput = safe_list_at(lenderBondOutputs, index)

          //Output with lender bond must be the same as input
          builtin.equals_data(lenderBondInput.output, lenderBondOutput)
        },
      )

    and {
      //The following 2 equalities prevent unauthorized spending of LenderManager utxos
      list.length(list.unique(redeemer.lenderBondInputIndexes)) == list.length(
        lenderBondInputs,
      ),
      list.length(redeemer.lenderBondInputIndexes) == list.length(loanInputs),
      //All pool managers in input must have been used for compounding
      list.length(poolManagerInputs) == list.length(
        dict.to_pairs(totalAssetsToCompoundForEachPoolManager),
      ),
      //No additional pools spent
      list.length(poolManagerInputs) == list.length(poolInputs),
      //All compounded pool are correct
      allCompoundedPoolsAreCorrect,
      //All spent lender bonds return correctly to the sc
      allLenderBondsAreCorrect,
    }
  }

  else(_) {
    fail
  }
}
