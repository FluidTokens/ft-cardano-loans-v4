use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/asset_manager.{
  AssetManagerDatum, AssetManagerDatumWithHash, AssetManagerDatumWithToken,
  AssetManagerMintRedeemer, AssetManagerWithdrawRedeemer,
} as r
use fluidtokens/types/general.{Liquidation}
use fluidtokens/types/loan.{
  ChangeCollateral, Claim, ClaimData, LoanClaimActionWithdrawRedeemer,
  LoanWithdrawRedeemer, Recast, Repay,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator assetManager(
  configNFTPolicyId: PolicyId,
  configNFTAssetName: ByteArray,
) {
  //Receipt NFTs for specific loan actions to track the operations on-chain.
  //These outputs are already checked by the loan validator, here we just ensure we don't mint additional undesired tokens
  //Burning is always allowed
  //Each output has a unique NFT
  mint(
    redeemer: AssetManagerMintRedeemer,
    policy_id: PolicyId,
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
    let loanClaimActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 11))
    let loanInputs =
      st_utils.get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
      )

    //We exclude the burnt tokens (quantity < 0) as they are always allowed
    let mintedNFTs =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(tokenPair) {
          expect tokenPair.2nd < 0 || tokenPair.2nd == 1
          tokenPair.2nd > 0
        },
      )

    if list.length(mintedNFTs) > 0 {
      let expectedMintedNFTs = {
        let loanWithdrawRedeemer =
          safe_list_at(self.redeemers, redeemer.loanWithdrawRedeemerIndex)
        expect loanWithdrawRedeemer.1st == Withdraw(Script(loanPolicyId))
        expect loanRedeemer: LoanWithdrawRedeemer = loanWithdrawRedeemer.2nd

        when loanRedeemer.action is {
          Claim -> {
            let loanClaimActionWithdrawRedeemer =
              safe_list_at(
                self.redeemers,
                redeemer.loanClaimActionWithdrawRedeemerIndex,
              )
            expect
              loanClaimActionWithdrawRedeemer.1st == Withdraw(
                Script(loanClaimActionScriptHash),
              )
            expect loanClaimActionRedeemer: LoanClaimActionWithdrawRedeemer =
              loanClaimActionWithdrawRedeemer.2nd
            list.indexed_foldr(
              loanInputs,
              [],
              fn(index, input, result) {
                let ClaimData { liquidationMode, equity, .. } =
                  safe_list_at(
                    loanClaimActionRedeemer.actionsForEachInput,
                    index,
                  )
                let repaymentAssetName =
                  utils.hash_output_ref(input.output_reference)
                expect Liquidation { partialLiquidationPenaltyPerMille, .. } =
                  liquidationMode
                expect partialLiquidationPenaltyPerMille >= 0 && equity > 0
                list.push(result, Pair(repaymentAssetName, 1))
              },
            )
          }
          Repay ->
            list.foldr(
              loanInputs,
              [],
              fn(input, result) {
                let repaymentAssetName =
                  utils.hash_output_ref(input.output_reference)
                list.push(result, Pair(repaymentAssetName, 1))
              },
            )
          ChangeCollateral -> fail
          Recast ->
            list.foldr(
              loanInputs,
              [],
              fn(input, result) {
                let repaymentAssetName =
                  utils.hash_output_ref(input.output_reference)
                list.push(result, Pair(repaymentAssetName, 1))
              },
            )
        }
      }

      list.sort(expectedMintedNFTs, utils.pairs_ordering) == mintedNFTs
    } else {
      True
    }
  }

  withdraw(
    redeemer: AssetManagerWithdrawRedeemer,
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
    let assetManagerSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 15))
    let assetInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(assetManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    list.all(
      assetInputs,
      fn(input) {
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: AssetManagerDatum = inputDatum
        when datum is {
          AssetManagerDatumWithToken { ownerAsset, .. } ->
            list.any(
              self.inputs,
              fn(input) {
                quantity_of(
                  input.output.value,
                  ownerAsset.policyId,
                  ownerAsset.assetName,
                ) > 0
              },
            )
          AssetManagerDatumWithHash { ownerAuth, .. } ->
            authorize_action(
              create_auth(
                ownerAuth,
                self.inputs,
                self.withdrawals,
                self.extra_signatories,
                self.mint,
              ),
            )
        }
      },
    )
  }

  else(_) {
    fail
  }
}
