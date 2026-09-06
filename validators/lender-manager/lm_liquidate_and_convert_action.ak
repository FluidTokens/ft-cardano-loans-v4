use aiken/builtin
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto
use amm_dex_v2/types as minswap_types
use amm_dex_v2/utils as minswap_utils
use cardano/address.{Address, Credential, Inline, PaymentCredential, Script}
use cardano/assets.{ada_policy_id, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, Withdraw,
}
use fluidtokens/constants
use fluidtokens/types/asset_manager.{AssetManagerDatumWithToken} as r
use fluidtokens/types/general.{Asset, CollateralAsset, Liquidation}
use fluidtokens/types/lender_manager.{
  LMLiquidateAndConvertActionWithdrawRedeemer, LenderManagerDatum,
} as lm
use fluidtokens/types/loan.{LoanDatum} as loan
use fluidtokens/types/minswap_conversions
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

/// ADA overhead a Minswap V2 order UTxO must carry on top of the swapped
/// collateral, so that a batcher will actually pick the order up:
///   2_000_000  max_batcher_fee paid to the batcher
/// + 2_000_000  min-ADA for the order's own success/refund output
/// Both halves must be present: raising only the fee cap leaves the order short.
const minswap_order_overhead: Int = 4_000_000

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderManagerSpendScriptHash: ByteArray,
  assetManagerSpendScriptHash: ByteArray,
  assetManagerWithdrawScriptHash: ByteArray,
  minswapPoolPolicyId: ByteArray,
  minswapPoolSpendScriptHash: ByteArray,
  minswapPoolWithdrawScriptHash: ByteArray,
  minswapOrderSpendScriptHash: ByteArray,
  minswapOrderWithdrawScriptHash: ByteArray,
  loanClaimPaymentCredential: PaymentCredential,
) {
  withdraw(
    redeemer: LMLiquidateAndConvertActionWithdrawRedeemer,
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
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    let minswapPoolRefInputs =
      get_inputs_from_smart_credential(
        self.reference_inputs,
        Script(minswapPoolSpendScriptHash),
        Script(minswapPoolWithdrawScriptHash),
        smartTokensSpendScriptHash,
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
    let minswapOrderOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(minswapOrderSpendScriptHash),
        Script(minswapOrderWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )

    let liquidatedCollateralOutputsAreCorrect =
      utils.indexed_all(
        loanInputs,
        fn(index, loanInput) {
          let lenderBondAssetName =
            safe_list_at(redeemer.lenderBondAssetNames, index)
          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)
          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          let minswapPoolRefInput =
            safe_list_at(
              minswapPoolRefInputs,
              safe_list_at(redeemer.minswapRefInputIndexes, index),
            )
          let minswapPoolAssetName =
            safe_list_at(redeemer.minswapPoolAssetNames, index)
          let lenderBondOutput =
            safe_list_at(lenderBondOutputs, lenderBondIndex)
          let minswapOrderOutput = safe_list_at(minswapOrderOutputs, index)
          let minswapOrderSuccessInlineDatumOutput =
            safe_list_at(
              self.outputs,
              safe_list_at(
                redeemer.minswapOrderSuccessInlineDatumOutputIndexes,
                index,
              ),
            )
          let minswapOrderRefundInlineDatumOutput =
            safe_list_at(
              self.outputs,
              safe_list_at(
                redeemer.minswapOrderRefundInlineDatumOutputIndexes,
                index,
              ),
            )

          expect InlineDatum(loanInputDatum) = loanInput.output.datum
          expect LoanDatum { collateral, principalAsset, .. } = loanInputDatum
          expect Some(loanRedeemer) =
            pairs.get_first(
              self.redeemers,
              Withdraw(loanClaimPaymentCredential),
            )
          expect parsedLoanRedeemer: loan.LoanClaimActionWithdrawRedeemer =
            loanRedeemer
          let loanInputAction =
            safe_list_at(parsedLoanRedeemer.actionsForEachInput, index)
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderManagerDatum {
            shouldLiquidationConvertToPrincipal,
            liquidationFeePerMille,
            lenderAuth,
            lenderStakeCredential,
            ..
          } = inputLenderBondDatum
          // Ensure liquidationFeePerMille is non-negative
          expect liquidationFeePerMille >= 0
          let collateralPolicyId = collateral.policyId
          expect Some(collateralAssetName) = collateral.maybeAssetName
          let loanCollateralAmount =
            quantity_of(
              loanInput.output.value,
              collateralPolicyId,
              collateralAssetName,
            )
          let collateralAsset =
            Asset {
              policyId: collateralPolicyId,
              assetName: collateralAssetName,
            }
          expect InlineDatum(minswapPoolRefInputDatum) =
            minswapPoolRefInput.output.datum
          expect asset_a: minswap_types.Asset =
            minswapPoolRefInputDatum
              |> builtin.unconstr_fields
              |> builtin.tail_list
              |> builtin.head_list

          expect asset_b: minswap_types.Asset =
            minswapPoolRefInputDatum
              |> builtin.unconstr_fields
              |> builtin.tail_list
              |> builtin.tail_list
              |> builtin.head_list
          let lpABDirection =
            asset_a == minswap_conversions.to_minswap_asset(collateralAsset)
          let lpAssetName =
            minswap_utils.compute_lp_asset_name(
              asset_a.policy_id,
              asset_a.asset_name,
              asset_b.policy_id,
              asset_b.asset_name,
            )

          let liquidationFee =
            loanCollateralAmount * liquidationFeePerMille / 1000
          expect Liquidation { equityInPrincipalCurrency, .. } =
            loanInputAction.liquidationMode
          expect equityInPrincipalCurrency == False
          let swappableCollateralAmount =
            loanCollateralAmount - loanInputAction.equity - liquidationFee

          let ownerAsset =
            Asset {
              policyId: lenderBondPolicyId,
              assetName: lenderBondAssetName,
            }

          let orderType =
            minswap_types.SwapExactIn {
              a_to_b_direction: lpABDirection,
              swap_amount_option: minswap_types.SAOSpecificAmount {
                swap_amount: swappableCollateralAmount,
              },
              minimum_receive: loanInputAction.remainingDebt,
              killable: True,
            }

          let successDatumHash =
            crypto.blake2b_256(
              builtin.serialise_data(
                AssetManagerDatumWithToken {
                  inputOutputReference: OutputReference {
                    transaction_id: "",
                    output_index: 0,
                  },
                  action: constants.converted_to_liquidity_action,
                  data: collateralAsset,
                  ownerAsset,
                },
              ),
            )

          let refundDatumHash =
            AssetManagerDatumWithToken {
              inputOutputReference: loanInput.output_reference,
              action: constants.action_claimed_collateral,
              data: None,
              ownerAsset,
            }
              |> builtin.serialise_data
              |> crypto.blake2b_256

          //True if it's cip113-cip113 or native-cip113 or cip113-native pair.
          //False if it's native-native.
          let isCIP113Pair =
            minswapPoolRefInput.output.address.payment_credential == Script(
              smartTokensSpendScriptHash,
            )

          let receiver =
            get_smart_destination_address(
              isCIP113Pair,
              assetManagerSpendScriptHash,
              assetManagerWithdrawScriptHash,
              smartTokensSpendScriptHash,
            )

          let expectedOrderDatum =
            InlineDatum(
              minswap_types.OrderDatum {
                canceller: minswap_conversions.to_order_auth_method(lenderAuth),
                refund_receiver: receiver,
                refund_receiver_datum: minswap_types.EODInlineDatum {
                  hash: refundDatumHash,
                },
                success_receiver: receiver,
                success_receiver_datum: minswap_types.EODInlineDatum {
                  hash: successDatumHash,
                },
                lp_asset: minswap_types.Asset {
                  policy_id: minswapPoolPolicyId,
                  asset_name: lpAssetName,
                },
                step: orderType,
                max_batcher_fee: 2_000_000,
                expiry_setting_opt: None,
              },
            )

          let correctOrderValue =
            if collateralPolicyId == ada_policy_id {
              quantity_of(
                minswapOrderOutput.value,
                collateralPolicyId,
                collateralAssetName,
              ) == swappableCollateralAmount + minswap_order_overhead
            } else {
              and {
                quantity_of(
                  minswapOrderOutput.value,
                  collateralPolicyId,
                  collateralAssetName,
                ) == swappableCollateralAmount,
                quantity_of(minswapOrderOutput.value, "", "") == minswap_order_overhead,
              }
            }

          and {
            //Lender bond must allow conversion to principal
            shouldLiquidationConvertToPrincipal,
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
            //Minswap LP token must be present in minswap pool reference input
            quantity_of(
              minswapPoolRefInput.output.value,
              minswapPoolPolicyId,
              minswapPoolAssetName,
            ) == 1,
            //Ensure the minswap pool is for the correct assets
            if lpABDirection {
              asset_b == minswap_conversions.to_minswap_asset(principalAsset)
            } else {
              asset_b == minswap_conversions.to_minswap_asset(collateralAsset) && asset_a == minswap_conversions.to_minswap_asset(
                principalAsset,
              )
            },
            //Output with lender bond must be the same as input
            builtin.equals_data(lenderBondInput.output, lenderBondOutput),
            //Ensure the InlineDatum of the designated output is hashing correctly
            get_output_inline_datum_hash(minswapOrderSuccessInlineDatumOutput) == successDatumHash,
            //Ensure the InlineDatum of the designated output is hashing correctly
            get_output_inline_datum_hash(minswapOrderRefundInlineDatumOutput) == refundDatumHash,
            //Order must have correct datum and value
            builtin.equals_data(minswapOrderOutput.datum, expectedOrderDatum),
            correctOrderValue,
            //Ensure the order output is sent to the correct address, considering CIP113
            if isCIP113Pair {
              minswapOrderOutput.address == Address {
                payment_credential: Script(smartTokensSpendScriptHash),
                stake_credential: Some(
                  Inline(Script(minswapOrderWithdrawScriptHash)),
                ),
              }
            } else {
              minswapOrderOutput.address == Address {
                payment_credential: Script(minswapOrderSpendScriptHash),
                stake_credential: lenderStakeCredential,
              }
            },
          }
        },
      )

    and {
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

pub fn get_smart_destination_address(
  isCIP113: Bool,
  paymentHash: ByteArray,
  withdrawHash: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  if isCIP113 {
    Address(
      Script(smartTokensSpendScriptHash),
      Some(Inline(Script(withdrawHash))),
    )
  } else {
    Address(Script(paymentHash), None)
  }
}

pub fn get_output_inline_datum_hash(output: Output) {
  expect InlineDatum(outputDatum) = output.datum
  outputDatum |> builtin.serialise_data |> crypto.blake2b_256
}
