use aiken/builtin
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math.{pow}
use aiken/math/rational
use cardano/address.{Address, Credential, Script}
use cardano/assets.{ada_policy_id, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/finance.{get_next_installment_amount, get_remaining_debt}
use fluidtokens/types/asset_manager.{AssetManagerDatumWithToken}
use fluidtokens/types/general.{
  Asset, InterestOnRemainingPrincipal, PerpetualLoan,
}
use fluidtokens/types/loan.{LoanDatum, LoanRecastActionWithdrawRedeemer} as l
use fluidtokens/utils.{
  is_nft_in_output, is_output_to_spend_validator, safe_list_at,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator loan_recast_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  assetManagerSpendScriptHash: ByteArray,
  assetManagerWithdrawScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LoanRecastActionWithdrawRedeemer,
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
    utils.indexed_all(
      loanInputs,
      fn(index, input) {
        let inputAction = safe_list_at(redeemer.actionsForEachInput, index)

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum

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
        let periodToLatestPaidInstallment =
          datum.repaidInstallments * datum.installmentPeriod
        let timePassedSinceLastRepaidInstallment =
          validTo - (
            datum.lendDate + (
              datum.initialGracePeriod + periodToLatestPaidInstallment
            ) * constants.hour_to_millis
          )

        let isPerpetualLoanWithNoInstallments =
          when datum.repaymentMode is {
            PerpetualLoan { .. } -> datum.installmentPeriod == 0
            _ -> False
          }

        let dueInstallments =
          if isPerpetualLoanWithNoInstallments {
            0
          } else {
            timePassedSinceLastRepaidInstallment / (
              datum.installmentPeriod * constants.hour_to_millis
            )
          }

        let principalAfterRecasting =
          when datum.repaymentMode is {
            InterestOnRemainingPrincipal { .. } -> {
              //Formula is: remainingPrincipal = P*r^t - A*(r^t - 1)/(r - 1)
              //where P = principal amount, r = 1 + interest rate per installment, t = latest paid installment and A = installment amount
              expect Some(interestRateAsRational) =
                rational.new(datum.interestRate, 10000)
              let a =
                get_next_installment_amount(
                  datum.repaymentMode,
                  rational.from_int(datum.principalAmount),
                  interestRateAsRational,
                  datum.totalInstallments,
                  datum.repaidInstallments,
                  datum.installmentPeriod,
                  datum.initialGracePeriod,
                  False,
                  datum.penaltyFeeForLateRepayment,
                )

              let interestPerInstallment =
                datum.interestRate / datum.totalInstallments

              let r = 1 + interestPerInstallment

              let remainingPrincipalToPay =
                if r > 0 {
                  let rToTheT = pow(r, datum.repaidInstallments)

                  datum.principalAmount * rToTheT - a * ( rToTheT - 1 ) / (
                    r - 1
                  )
                } else {
                  datum.principalAmount - datum.repaidInstallments * a
                }

              remainingPrincipalToPay - inputAction.amountPaid
            }
            PerpetualLoan { .. } -> {
              expect Some(interestRateAsRational) =
                rational.new(datum.interestRate, 10000)

              let remainingDebt =
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
              let leftoverInterest = remainingDebt - datum.principalAmount
              //Ensure the amountPaid is bigger than the leftOverInterest, otherwise the new principal could become bigger than the old one!
              expect inputAction.amountPaid > leftoverInterest

              remainingDebt - inputAction.amountPaid
            }
            _ -> fail
          }

        and {
          inputAction.amountPaid > 0,
          quantity_of(input.output.value, loanPolicyId, inputAction.loanId) == 1,
          is_nft_in_output(
            borrowerBondPolicyId,
            inputAction.loanId,
            borrowerBondOutput,
          ),
          //Either it is a perpetual loan with no installments or the due installments + 1 are paid
          or {
            isPerpetualLoanWithNoInstallments,
            and {
              //A recast is permitted only if the loan has installments
              datum.installmentPeriod > 0,
              //A recast is permitted only when all due installments + 1 are paid, otherwise the borrower avoids paying what is due
              datum.repaidInstallments >= dueInstallments + 1,
            },
          },
          //A recast must be within the number of recasts allowed
          when datum.repaymentMode is {
            InterestOnRemainingPrincipal { max_possible_recasts } ->
              datum.doneRecasts < max_possible_recasts
            PerpetualLoan { max_possible_recasts, .. } ->
              datum.doneRecasts < max_possible_recasts
            _ -> fail
          },
          validate_repayment_output(
            loanInputOutputReference: input.output_reference,
            repaymentOutput: repaymentOutput,
            lenderBondAsset: Asset {
              policyId: lenderBondPolicyId,
              assetName: inputAction.loanId,
            },
            repaymentAsset: datum.principalAsset,
            repaymentAmount: inputAction.amountPaid,
            action: constants.action_recast,
            extra_data: inputAction.loanId,
            repaymentReceipts: datum.repaymentReceipts,
            repaymentPolicyId: repaymentPolicyId,
          ),
          or {
            and {
              //If principal becomes 0 or less, then the loan is closed (there can't be outstanding interest to pay)
              principalAfterRecasting <= 0,
              quantity_of(self.mint, loanPolicyId, inputAction.loanId) == -1,
            },
            and {
              principalAfterRecasting > 0,
              //Loan output is correct
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
                expect InlineDatum(outputDatum) = loanOutput.datum
                let newLoanExpectedDatum =
                  when datum.repaymentMode is {
                    InterestOnRemainingPrincipal { .. } -> {
                      let newTotalInstallments =
                        datum.totalInstallments - datum.repaidInstallments
                      let newRepaidInstallments = 0

                      //Loan datum except the first 6 fields
                      let datumUnchangedPart =
                        datum
                          |> builtin.unconstr_fields
                          |> builtin.tail_list
                          |> builtin.tail_list
                          |> builtin.tail_list
                          |> builtin.tail_list
                          |> builtin.tail_list
                          |> builtin.tail_list

                      //Adding the new first 6 fields and remaking it a constructor
                      builtin.constr_data(
                        0,
                        builtin.cons_list(
                          builtin.i_data(datum.doneRecasts + 1),
                          builtin.cons_list(
                            builtin.i_data(principalAfterRecasting),
                            builtin.cons_list(
                              builtin.i_data(datum.lendDate),
                              builtin.cons_list(
                                builtin.i_data(newRepaidInstallments),
                                builtin.cons_list(
                                  builtin.i_data(
                                    (
                                      datum.interestRate * newTotalInstallments + datum.totalInstallments - 1
                                    ) / datum.totalInstallments,
                                  ),
                                  builtin.cons_list(
                                    builtin.i_data(newTotalInstallments),
                                    datumUnchangedPart,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    }
                    PerpetualLoan { .. } -> {
                      //Loan datum except the first 2 fields
                      let datumUnchangedPart =
                        datum
                          |> builtin.unconstr_fields
                          |> builtin.tail_list
                          |> builtin.tail_list

                      //Adding the new first 2 fields and remaking it a constructor
                      builtin.constr_data(
                        0,
                        builtin.cons_list(
                          builtin.i_data(datum.doneRecasts + 1),
                          builtin.cons_list(
                            builtin.i_data(principalAfterRecasting),
                            datumUnchangedPart,
                          ),
                        ),
                      )
                    }
                    _ -> fail
                  }
                let correctDestination =
                  if is_output_to_spend_validator(
                    loanOutput,
                    loanSpendScriptHash,
                  ) {
                    loanOutput.address.stake_credential == input.output.address.stake_credential
                  } else {
                    //outputs have been already filtered at the beginning
                    True
                  }
                and {
                  correctDestination,
                  builtin.equals_data(outputDatum, newLoanExpectedDatum),
                  //loanNFT is already included in the value
                  input.output.value == loanOutput.value,
                }
              },
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
    AssetManagerDatumWithToken {
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
    if repaymentAsset.policyId == ada_policy_id {
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
