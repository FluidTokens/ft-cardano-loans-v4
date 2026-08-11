use aiken/builtin
use aiken/collection/list.{length}
use aiken/crypto
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{Value, ada_policy_id, add, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/finance.{
  get_needed_collateral_with_oracles, get_needed_collateral_without_oracles,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{
  Asset, CardanoSignature, CardanoSpendScript, CollateralAsset, Liquidation,
  PerpetualLoan,
}
use fluidtokens/types/loan.{LoanDatum}
use fluidtokens/types/locked_borrower_manager.{LockedBorrowerManagerDatum}
use fluidtokens/types/pool.{
  BorrowData, PoolBorrowActionWithdrawRedeemer, PoolDatum,
}
use fluidtokens/utils.{
  asset_names_number_of_policy_id, is_output_to_spend_validator,
  quantity_of_policy_id, safe_list_at, validity_range_within_an_hour,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator pool_borrow_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: PoolBorrowActionWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let Transaction {
      inputs,
      outputs,
      reference_inputs,
      redeemers,
      mint,
      validity_range,
      withdrawals,
      ..
    } = self
    expect Finite(validFrom) = validity_range.lower_bound.bound_type
    expect Finite(validTo) = validity_range.upper_bound.bound_type
    let config =
      utils.get_config_as_data_list(
        safe_list_at(reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let borrowerBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 4))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let poolInputs =
      get_inputs_from_smart_credential(
        inputs,
        Script(poolSpendScriptHash),
        Script(poolPolicyId),
        smartTokensSpendScriptHash,
      )
    let loanOutputs =
      get_outputs_to_smart_credential(
        outputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
      )
    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    utils.indexed_all(
      poolInputs,
      fn(index, poolInput) {
        expect InlineDatum(inputDatum) = poolInput.output.datum
        expect poolDatum: PoolDatum = inputDatum
        let BorrowData {
          borrowerAddress,
          outputWithLenderTokenIndex,
          outputWithBorrowerTokenIndex,
          principalOracleRefInputIndex,
          chosenCollateralIndex,
          chosenCollateralOracleRefInputIndex,
          wantedPrincipalAmount,
          poolId,
          permissionedConditionWithdrawIndex,
        } = safe_list_at(redeemer.actionsForEachInput, index)
        let inputUtxoId = utils.hash_output_ref(poolInput.output_reference)
        let loanOutput = safe_list_at(loanOutputs, index)
        let outputWithLenderToken =
          safe_list_at(outputs, outputWithLenderTokenIndex)
        let outputWithBorrowerToken =
          safe_list_at(outputs, outputWithBorrowerTokenIndex)
        let chosenCollateral =
          safe_list_at(poolDatum.collateralOptions, chosenCollateralIndex)
        expect Some(minCollateral) =
          rational.new(
            safe_list_at(poolDatum.minCollateral, chosenCollateralIndex),
            safe_list_at(poolDatum.minCollateralDivider, chosenCollateralIndex),
          )

        //common data
        let cd = poolDatum.commonData
        let minNeededCollateral =
          if poolDatum.dynamicCollateralPrice {
            let collateralOracleRefInput =
              safe_list_at(
                reference_inputs,
                chosenCollateralOracleRefInputIndex,
              )
            let chosenCollateralOracleToken = chosenCollateral.oracleTokenAsset
            expect Some(collateralOraclePriceFeed) =
              retrieve_oracle_data(
                collateralOracleRefInput.output.address.payment_credential,
                collateralOracleRefInput.output.value,
                redeemers,
                validFrom,
                validTo,
                chosenCollateralOracleToken.policyId,
                chosenCollateralOracleToken.assetName,
                chosenCollateral.policyId,
                chosenCollateral.maybeAssetName,
              )
            let principalOracleRefInput =
              safe_list_at(reference_inputs, principalOracleRefInputIndex)
            expect Some(principalOraclePriceFeed) =
              retrieve_oracle_data(
                principalOracleRefInput.output.address.payment_credential,
                principalOracleRefInput.output.value,
                redeemers,
                validFrom,
                validTo,
                cd.principalOracleAsset.policyId,
                cd.principalOracleAsset.assetName,
                cd.principalAsset.policyId,
                Some(cd.principalAsset.assetName),
              )
            get_needed_collateral_with_oracles(
              wantedPrincipalAmount,
              minCollateral,
              principalOraclePriceFeed,
              collateralOraclePriceFeed,
            )
          } else {
            get_needed_collateral_without_oracles(
              wantedPrincipalAmount,
              minCollateral,
            )
          }
        let isLoanOutputValid =
          validate_output_to_loan(
            loanOutput,
            loanPolicyId,
            loanSpendScriptHash,
            poolDatum,
            wantedPrincipalAmount,
            chosenCollateral,
            minNeededCollateral,
            inputUtxoId,
            validTo,
            borrowerAddress,
            poolId,
          )
        and {
          wantedPrincipalAmount > 0,
          or {
            poolDatum.permissionedConditionScriptHash == constants.no_permissioned_condition,
            {
              expect Pair(Script(scriptHash), _amnt) =
                safe_list_at(withdrawals, permissionedConditionWithdrawIndex)

              poolDatum.permissionedConditionScriptHash == scriptHash
            },
          },
          quantity_of(poolInput.output.value, poolPolicyId, poolId) == 1,
          validity_range_within_an_hour(self),
          isLoanOutputValid,
          bonds_sent_to_both_parties(
            mint,
            outputWithLenderToken,
            borrowerBondPolicyId,
            lenderBondPolicyId,
            inputUtxoId,
            poolDatum.lenderBondAddress,
            poolDatum.lenderBondInlineDatumHash,
            outputWithBorrowerToken,
            borrowerAddress,
            cd.borrowerBondDestinationScriptHash,
            poolInput.output_reference,
          ),
          //The pool must return with the remaining liquidity even if completely emptied.
          validate_output_to_pool(
            poolInput.output.value,
            safe_list_at(outputs, index),
            poolDatum,
            poolInput.output.address,
            wantedPrincipalAmount,
          ),
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn validate_output_to_loan(
  output: Output,
  loanPolicyId: ByteArray,
  loanSpendScriptHash: ByteArray,
  poolDatum: PoolDatum,
  wantedPrincipalAmount: Int,
  chosenCollateral: CollateralAsset,
  minNeededCollateralAmount: Int,
  loanId: ByteArray,
  end: Int,
  borrowerAddress: Address,
  poolId: ByteArray,
) -> Bool {
  let outputValue = output.value
  let containsEnoughCollateral =
    when chosenCollateral.maybeAssetName is {
      Some(chosenCollateralAssetName) ->
        quantity_of(
          outputValue,
          chosenCollateral.policyId,
          chosenCollateralAssetName,
        ) >= minNeededCollateralAmount
      None ->
        quantity_of_policy_id(outputValue, chosenCollateral.policyId) >= minNeededCollateralAmount
    }

  let containsLoanNFT = quantity_of(outputValue, loanPolicyId, loanId) == 1
  expect InlineDatum(outputDatum) = output.datum
  //common data
  let cd = poolDatum.commonData
  let newDatum =
    LoanDatum {
      principalAsset: cd.principalAsset,
      principalOracleAsset: cd.principalOracleAsset,
      interestRate: cd.interestRate,
      installmentPeriod: cd.installmentPeriod,
      initialGracePeriod: cd.initialGracePeriod,
      liquidationMode: cd.liquidationMode,
      repaymentMode: cd.repaymentMode,
      repaymentTimeWindow: cd.repaymentTimeWindow,
      penaltyFeeForLateRepayment: cd.penaltyFeeForLateRepayment,
      repaymentReceipts: cd.repaymentReceipts,
      totalInstallments: cd.totalInstallments,
      originId: bytearray.concat("POOL", poolId),
      collateral: chosenCollateral,
      principalAmount: wantedPrincipalAmount,
      lendDate: end,
      repaidInstallments: 0,
      doneRecasts: 0,
    }

  let isLiquidationCorrectlySet =
    when newDatum.liquidationMode is {
      Liquidation { .. } ->
        newDatum.collateral.oracleTokenAsset != constants.no_oracle_token_asset
      _ -> True
    }

  let isInstallmentCountValid =
    when newDatum.repaymentMode is {
      PerpetualLoan { .. } -> True
      _ -> newDatum.totalInstallments > 0
    }
  let isDatumCorrect =
    builtin.equals_data(outputDatum, newDatum) && isLiquidationCorrectlySet && isInstallmentCountValid

  let correctDestination =
    if is_output_to_spend_validator(output, loanSpendScriptHash) {
      output.address.stake_credential == borrowerAddress.stake_credential
    } else {
      //outputs have been already filtered at the beginning
      True
    }
  let dosProtection =
    length(flatten(outputValue)) == when chosenCollateral.maybeAssetName is {
      Some(_chosenCollateralAssetName) ->
        if chosenCollateral.policyId == ada_policy_id {
          2
        } else {
          3
        }
      None ->
        asset_names_number_of_policy_id(outputValue, chosenCollateral.policyId) + 2
    }
  and {
    correctDestination,
    isDatumCorrect,
    containsLoanNFT,
    containsEnoughCollateral,
    dosProtection,
  }
}

//Expects that the bond minting policy allows minting of a token only if:
//- the AssetName is hash of a tx input
//- the quantity is strictly 1
//We force that the lender output contains a InlineDatum to allow PlutusV2 contracts to use it
fn bonds_sent_to_both_parties(
  mintedValue: Value,
  outputWithLenderToken: Output,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
  bondId: ByteArray,
  lenderBondAddress: Address,
  lenderBondInlineDatumHash: ByteArray,
  outputWithBorrowerToken: Output,
  borrowerAddress: Address,
  borrowerBondDestinationScriptHash: ByteArray,
  poolRef: OutputReference,
) {
  expect InlineDatum(outputWithLenderTokenDatum) = outputWithLenderToken.datum
  and {
    if borrowerBondDestinationScriptHash != "" {
      and {
        outputWithBorrowerToken.address == Address(
          Script(borrowerBondDestinationScriptHash),
          borrowerAddress.stake_credential,
        ),
        outputWithBorrowerToken.datum == InlineDatum(
          LockedBorrowerManagerDatum {
            originRef: poolRef,
            borrowerAuth: when borrowerAddress.payment_credential is {
              VerificationKey(payment_credential_hash) ->
                CardanoSignature { hash: payment_credential_hash }
              Script(payment_credential_hash) ->
                CardanoSpendScript { hash: payment_credential_hash }
            },
          },
        ),
        quantity_of(outputWithBorrowerToken.value, borrowerBondPolicyId, bondId) == 1,
        length(flatten(outputWithBorrowerToken.value)) == 2,
      }
    } else {
      True
    },
    outputWithLenderToken.address == lenderBondAddress,
    crypto.blake2b_256(builtin.serialise_data(outputWithLenderTokenDatum)) == lenderBondInlineDatumHash,
    quantity_of(mintedValue, borrowerBondPolicyId, bondId) == 1,
    quantity_of(outputWithLenderToken.value, lenderBondPolicyId, bondId) == 1,
    length(flatten(outputWithLenderToken.value)) <= 5,
  }
}

fn validate_output_to_pool(
  inputValue: Value,
  output: Output,
  datum: PoolDatum,
  poolInputAddress: Address,
  principalSpent: Int,
) {
  expect InlineDatum(outputDatum) = output.datum
  let expectedOutputValue =
    add(
      inputValue,
      datum.commonData.principalAsset.policyId,
      datum.commonData.principalAsset.assetName,
      -principalSpent,
    )
  let isDatumCorrect = builtin.equals_data(outputDatum, datum)
  let correctDestination = poolInputAddress == output.address
  and {
    expectedOutputValue == output.value,
    correctDestination,
    isDatumCorrect,
  }
}
