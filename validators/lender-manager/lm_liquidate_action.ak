use aiken/builtin
use aiken/collection/list
use aiken/collection/pairs
use cardano/address.{Credential, PaymentCredential, Script}
use cardano/assets.{ada_policy_id, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, Withdraw,
}
use fluidtokens/constants
use fluidtokens/types/asset_manager.{AssetManagerDatumWithToken} as r
use fluidtokens/types/general.{Asset, CollateralAsset, Liquidation}
use fluidtokens/types/lender_manager.{
  LMLiquidateWithdrawRedeemer, LenderManagerDatum,
} as lm
use fluidtokens/types/loan.{LoanDatum} as loan
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
  loanClaimCredential: PaymentCredential,
) {
  withdraw(
    redeemer: LMLiquidateWithdrawRedeemer,
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
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let loanWithdrawScriptHash = loanPolicyId
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
    let assetOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(assetManagerSpendScriptHash),
        Script(assetManagerWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    let liquidatedCollateralOutputsAreCorrect =
      utils.indexed_all(
        loanInputs,
        fn(index, loanInput) {
          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)
          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          let assetOutput =
            safe_list_at(
              assetOutputs,
              safe_list_at(redeemer.assetOutputIndexes, index),
            )
          let lenderBondOutput =
            safe_list_at(lenderBondOutputs, lenderBondIndex)

          expect InlineDatum(loanInputDatum) = loanInput.output.datum
          expect LoanDatum { collateral, .. } = loanInputDatum
          expect Some(loanRedeemer) =
            pairs.get_first(self.redeemers, Withdraw(loanClaimCredential))
          expect parsedLoanRedeemer: loan.LoanClaimActionWithdrawRedeemer =
            loanRedeemer
          let loanInputAction =
            safe_list_at(parsedLoanRedeemer.actionsForEachInput, index)
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderManagerDatum {
            shouldLiquidationConvertToPrincipal,
            liquidationFeePerMille,
            ..
          } = inputLenderBondDatum
          let collateralPolicyId = collateral.policyId
          //NFT collections as collateral are not allowed
          expect Some(collateralAssetName) = collateral.maybeAssetName
          let loanCollateralAmount =
            quantity_of(
              loanInput.output.value,
              collateralPolicyId,
              collateralAssetName,
            )
          //A single NFT as collateral is not allowed
          expect loanCollateralAmount > 1

          let liquidationFee =
            loanCollateralAmount * liquidationFeePerMille / 1000
          expect Liquidation { equityInPrincipalCurrency, .. } =
            loanInputAction.liquidationMode
          expect equityInPrincipalCurrency == False
          let loanCollateralThatLenderShouldReceive =
            loanCollateralAmount - loanInputAction.equity - liquidationFee

          let lenderBondAssetName =
            safe_list_at(redeemer.lenderBondAssetNames, index)

          and {
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
            //Lender bond must NOT allow conversion to principal
            shouldLiquidationConvertToPrincipal == False,
            //Output with lender bond must be the same as input
            builtin.equals_data(lenderBondInput.output, lenderBondOutput),
            //Ensures lender receives the correct assets, the eventual output to borrower is already checked by loan.ak
            validate_repayment_output(
              loanInputOutputReference: loanInput.output_reference,
              repaymentOutput: assetOutput,
              lenderBondAsset: Asset {
                policyId: lenderBondPolicyId,
                assetName: lenderBondAssetName,
              },
              repaymentAsset: Asset(collateralPolicyId, collateralAssetName),
              repaymentAmount: loanCollateralThatLenderShouldReceive,
              action: constants.action_claimed_collateral,
            ),
          }
        },
      )

    and {
      //No duplicates in the redeemer output indexes to avoid double satisfaction attacks
      list.unique(redeemer.assetOutputIndexes) == redeemer.assetOutputIndexes,
      //No asset input should be spent, so asset_manager withdraw script should not be in the tx
      list.find(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(scriptHash), _amnt) ->
              scriptHash == assetManagerWithdrawScriptHash
            _ -> False
          }
        },
      ) == None,
      //The following 2 equalities prevent unauthorized spending of LenderManager utxos
      list.length(list.unique(redeemer.lenderBondInputIndexes)) == list.length(
        lenderBondInputs,
      ),
      list.length(redeemer.lenderBondInputIndexes) == list.length(loanInputs),
      liquidatedCollateralOutputsAreCorrect,
    }
  }

  else(_) {
    fail
  }
}

fn validate_repayment_output(
  loanInputOutputReference: OutputReference,
  repaymentOutput: Output,
  lenderBondAsset: Asset,
  repaymentAsset: Asset,
  repaymentAmount: Int,
  action: ByteArray,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  let newDatum =
    AssetManagerDatumWithToken {
      inputOutputReference: loanInputOutputReference,
      action,
      data: None,
      ownerAsset: lenderBondAsset,
    }
  let containsCorrectAmount =
    quantity_of(
      repaymentOutput.value,
      repaymentAsset.policyId,
      repaymentAsset.assetName,
    ) >= repaymentAmount

  let isDatumCorrect = builtin.equals_data(outputDatum, newDatum)

  let dosProtection =
    if repaymentAsset.policyId == ada_policy_id {
      list.length(flatten(repaymentOutput.value)) == 1
    } else {
      list.length(flatten(repaymentOutput.value)) == 2
    }
  and {
    //No staking check here
    isDatumCorrect,
    containsCorrectAmount,
    dosProtection,
  }
}
