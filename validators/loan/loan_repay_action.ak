use aiken/builtin
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/finance.{
  get_next_installment_amount, get_remaining_debt, is_repayment_late,
}
use fluidtokens/types/general.{Asset, PerpetualLoan}
use fluidtokens/types/loan.{
  LoanDatum, LoanRepayActionWithdrawRedeemer, LoanRepaymentData,
} as l
use fluidtokens/types/repayment.{RepaymentDatumWithToken}
use fluidtokens/utils.{
  is_nft_in_output, is_output_to_spend_validator, safe_list_at,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator loan_repay_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  assetManagerSpendScriptHash: ByteArray,
  assetManagerWithdrawScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LoanRepayActionWithdrawRedeemer,
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
    let borrowerBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 4))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let repaymentPolicyId = builtin.un_b_data(utils.safe_list_at(config, 7))
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      loanInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result
        let inputAction = safe_list_at(redeemer.actionsForEachInput, index)

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum

        expect Some(interestRateAsRational) =
          rational.new(datum.interestRate, 10000)

        expect Finite(validTo) = self.validity_range.upper_bound.bound_type
        let borrowerBondOutput =
          safe_list_at(self.outputs, inputAction.borrowerBondOutputIndex)
        let repaymentOutput =
          utils.safe_list_at(
            get_outputs_to_smart_credential(
              self.outputs,
              Script(assetManagerSpendScriptHash),
              Script(assetManagerWithdrawScriptHash),
              smartTokensSpendScriptHash,
            ),
            index,
          )

        let isPerpetualLoan =
          when datum.repaymentMode is {
            PerpetualLoan { .. } -> True
            _ -> False
          }

        let isRepaymentLate =
          is_repayment_late(
            isPerpetualLoan,
            validTo,
            datum.lendDate,
            datum.initialGracePeriod,
            datum.repaidInstallments,
            datum.installmentPeriod,
            datum.repaymentTimeWindow,
          )
        let nextRepaymentAmount =
          if isPerpetualLoan && (
            inputAction.isFinalRepayment || datum.installmentPeriod == 0
          ) {
            get_remaining_debt(
              datum.repaymentMode,
              rational.from_int(datum.principalAmount),
              interestRateAsRational,
              datum.totalInstallments,
              datum.repaidInstallments,
              datum.installmentPeriod,
              datum.initialGracePeriod,
              validTo - datum.lendDate,
            )
          } else {
            get_next_installment_amount(
              datum.repaymentMode,
              rational.from_int(datum.principalAmount),
              interestRateAsRational,
              datum.totalInstallments,
              datum.repaidInstallments,
              datum.installmentPeriod,
              datum.initialGracePeriod,
              isRepaymentLate,
              datum.penaltyFeeForLateRepayment,
            )
          }
        and {
          quantity_of(input.output.value, loanPolicyId, inputAction.loanId) == 1,
          is_nft_in_output(
            borrowerBondPolicyId,
            inputAction.loanId,
            borrowerBondOutput,
          ),
          validate_repayment_output(
            loanInputOutputReference: input.output_reference,
            repaymentOutput: repaymentOutput,
            lenderBondAsset: Asset {
              policyId: lenderBondPolicyId,
              assetName: inputAction.loanId,
            },
            repaymentAsset: datum.principalAsset,
            repaymentAmount: nextRepaymentAmount,
            action: constants.repayment_action_installment,
            extra_data: LoanRepaymentData {
              loanId: inputAction.loanId,
              principalAmount: datum.principalAmount,
              interestRate: datum.interestRate,
              repaidInstallments: datum.repaidInstallments + 1,
              totalInstallments: datum.totalInstallments,
              repaymentMode: datum.repaymentMode,
            },
            repaymentReceipts: datum.repaymentReceipts,
            repaymentPolicyId: repaymentPolicyId,
          ),
          or {
            and {
              if isPerpetualLoan {
                inputAction.isFinalRepayment || datum.installmentPeriod == 0
              } else {
                datum.repaidInstallments == datum.totalInstallments - 1
              },
              quantity_of(self.mint, loanPolicyId, inputAction.loanId) == -1,
            },
            {
              let loanOutput =
                safe_list_at(
                  get_outputs_to_smart_credential(
                    self.outputs,
                    Script(loanSpendScriptHash),
                    Script(loanPolicyId),
                    smartTokensSpendScriptHash,
                  ),
                  index,
                )
              validate_eventual_output_to_loan_for_repayment(
                loanOutput,
                datum,
                input.output.value == loanOutput.value,
                input.output.address.stake_credential,
                loanSpendScriptHash,
              )
            },
          },
        }
      },
    )
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
  extra_data: Data,
  repaymentReceipts: Bool,
  repaymentPolicyId: ByteArray,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  let newDatum =
    RepaymentDatumWithToken {
      inputOutputReference: loanInputOutputReference,
      action,
      data: extra_data,
      ownerAsset: lenderBondAsset,
    }
  let containsCorrectAmount =
    quantity_of(
      repaymentOutput.value,
      repaymentAsset.policyId,
      repaymentAsset.assetName,
    ) >= repaymentAmount
  let receiptCondition =
    repaymentReceipts == False || quantity_of(
      repaymentOutput.value,
      repaymentPolicyId,
      utils.hash_output_ref(loanInputOutputReference),
    ) == 1

  let isDatumCorrect = builtin.equals_data(outputDatum, newDatum)
  let receiptAssetCount =
    if repaymentReceipts {
      1
    } else {
      0
    }
  let dosProtection =
    if repaymentAsset.policyId == "" {
      length(flatten(repaymentOutput.value)) == 1 + receiptAssetCount
    } else {
      length(flatten(repaymentOutput.value)) == 2 + receiptAssetCount
    }
  and {
    //No staking check here
    isDatumCorrect,
    receiptCondition,
    containsCorrectAmount,
    dosProtection,
  }
}

fn validate_eventual_output_to_loan_for_repayment(
  loanOutput: Output,
  datum: LoanDatum,
  outputValueSameOfInputValue: Bool,
  prevStakeCredential: Option<StakeCredential>,
  loanSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = loanOutput.datum

  //Loan datum except the first 4 fields
  let datumUnchangedPart =
    datum
      |> builtin.unconstr_fields
      |> builtin.tail_list
      |> builtin.tail_list
      |> builtin.tail_list
      |> builtin.tail_list

  //Adding the new 4th field and remaking it a constructor
  let newLoanExpectedDatum =
    builtin.constr_data(
      0,
      builtin.cons_list(
        builtin.i_data(datum.doneRecasts),
        builtin.cons_list(
          builtin.i_data(datum.principalAmount),
          builtin.cons_list(
            builtin.i_data(datum.lendDate),
            builtin.cons_list(
              builtin.i_data(datum.repaidInstallments + 1),
              datumUnchangedPart,
            ),
          ),
        ),
      ),
    )

  let isDatumCorrect = builtin.equals_data(outputDatum, newLoanExpectedDatum)

  let correctDestination =
    if is_output_to_spend_validator(loanOutput, loanSpendScriptHash) {
      loanOutput.address.stake_credential == prevStakeCredential
    } else {
      //outputs have been already filtered at the beginning
      True
    }
  and {
    correctDestination,
    isDatumCorrect,
    //loanNFT is already included in the value
    outputValueSameOfInputValue,
  }
}
