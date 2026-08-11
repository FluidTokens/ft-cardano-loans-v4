use aiken/builtin
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use cardano/address.{Credential, Script}
use cardano/assets.{ada_policy_id, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/authorizer
use fluidtokens/constants
use fluidtokens/types/asset_manager.{
  AssetManagerDatum, AssetManagerDatumWithHash, AssetManagerDatumWithToken,
}
use fluidtokens/types/dutch_auction.{
  Buy, Cancel, DutchAuctionDatum, DutchAuctionRedeemer,
} as da
use fluidtokens/types/general.{Asset}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator dutch_auction(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  assetManagerSpendScriptHash: ByteArray,
  assetManagerWithdrawScriptHash: ByteArray,
) {
  withdraw(
    redeemer: DutchAuctionRedeemer,
    credential: Credential,
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
    let dutchAuctionSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 16))
    let scInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(dutchAuctionSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionsForEachInput)
    expect (Finite(validFrom), Finite(validTo)) =
      (
        self.validity_range.lower_bound.bound_type,
        self.validity_range.upper_bound.bound_type,
      )

    utils.indexed_all(
      scInputs,
      fn(index, input) {
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: DutchAuctionDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)
        let currentPrice =
          get_current_price(
            datum.startingPrice,
            datum.loweringAmount,
            datum.loweringFrequency,
            datum.startDate,
            validFrom,
          )

        when redeemerAction is {
          Cancel -> and {
              authorizer.authorize_action(
                authorizer.create_auth(
                  datum.ownerAuth,
                  self.inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              ),
              or {
                and {
                  datum.borrowerAssetManagerDatum == None,
                  validTo < datum.startDate,
                },
                currentPrice < datum.minPriceToCancel,
              },
            }
          Buy -> {
            let asset_manager_outputs =
              get_outputs_to_smart_credential(
                self.outputs,
                Script(assetManagerSpendScriptHash),
                Script(assetManagerWithdrawScriptHash),
                smartTokensSpendScriptHash,
              )
            let ownerOutput =
              utils.safe_list_at(asset_manager_outputs, index * 2)
            and {
              datum.startDate <= validFrom,
              currentPrice >= datum.minPriceToCancel,
              if datum.borrowerAssetManagerDatum != None && currentPrice > datum.debtAmount {
                expect Some(borrowerAssetManagerDatum) =
                  datum.borrowerAssetManagerDatum
                let borrowerOutput =
                  utils.safe_list_at(asset_manager_outputs, index * 2 + 1)
                and {
                  correctAmountSentToUser(
                    input.output_reference,
                    constants.dutch_auction_owner_revenue,
                    datum.currency,
                    datum.debtAmount,
                    datum.ownerAssetManagerDatum,
                    ownerOutput,
                  ),
                  correctAmountSentToUser(
                    input.output_reference,
                    constants.dutch_auction_borrower_compensation,
                    datum.currency,
                    currentPrice - datum.debtAmount,
                    borrowerAssetManagerDatum,
                    borrowerOutput,
                  ),
                }
              } else {
                correctAmountSentToUser(
                  input.output_reference,
                  constants.dutch_auction_owner_revenue,
                  datum.currency,
                  currentPrice,
                  datum.ownerAssetManagerDatum,
                  ownerOutput,
                )
              },
            }
          }
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn get_current_price(
  startingPrice: Int,
  loweringAmount: Int,
  loweringFrequency: Int,
  startDate: Int,
  now: Int,
) {
  startingPrice - ( now - startDate ) / loweringFrequency * loweringAmount
}

fn correctAmountSentToUser(
  auctionRef: OutputReference,
  action: ByteArray,
  currency: Asset,
  amount: Int,
  userAssetManagerDatum: AssetManagerDatum,
  userOutput: Output,
) {
  let correctDatum =
    when userAssetManagerDatum is {
      AssetManagerDatumWithToken { ownerAsset, .. } ->
        InlineDatum(
          AssetManagerDatumWithToken {
            inputOutputReference: auctionRef,
            action,
            data: userAssetManagerDatum,
            ownerAsset,
          },
        )
      AssetManagerDatumWithHash { ownerAuth, .. } ->
        InlineDatum(
          AssetManagerDatumWithHash {
            inputOutputReference: auctionRef,
            action,
            data: userAssetManagerDatum,
            ownerAuth,
          },
        )
    } == userOutput.datum
  let correctValue = and {
      quantity_of(userOutput.value, currency.policyId, currency.assetName) >= amount,
      if currency.policyId == ada_policy_id {
        length(flatten(userOutput.value)) == 1
      } else {
        length(flatten(userOutput.value)) == 2
      },
    }
  and {
    correctDatum,
    correctValue,
  }
}
