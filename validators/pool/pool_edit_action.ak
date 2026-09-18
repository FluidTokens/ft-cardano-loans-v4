use aiken/builtin
use aiken/collection/dict
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/pool.{EditActionWithdrawRedeemer, PoolDatum}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator pool_edit_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: EditActionWithdrawRedeemer,
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
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
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

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    utils.indexed_all(
      poolInputs,
      fn(index, input) {
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: PoolDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)
        let output = safe_list_at(poolOutputs, index)

        expect InlineDatum(outputDatum) = output.datum
        expect outDatum: PoolDatum = outputDatum

        and {
          //Pool NFT is never minted/burned by an update: the pool's identity (the asset
          //name outstanding loans reference to compound back into it) never changes
          quantity_of(input.output.value, poolPolicyId, redeemerAction.poolId) == 1,
          quantity_of(output.value, poolPolicyId, redeemerAction.poolId) == 1,
          dict.size(tokens(output.value, poolPolicyId)) == 1,
          //Value is free to change (add or remove liquidity): this is gated by the same
          //lenderAuth that can already fully drain the pool via Cancel, so it grants no
          //new capability - it just avoids a full cancel+recreate for a liquidity change
          //Address cannot change
          builtin.equals_data(input.output.address, output.address),
          //The lending asset (and its oracle) must stay fixed: outstanding loans and
          //lender bonds are denominated in it, and compounding relies on it matching
          builtin.equals_data(
            datum.commonData.principalAsset,
            outDatum.commonData.principalAsset,
          ),
          builtin.equals_data(
            datum.commonData.principalOracleAsset,
            outDatum.commonData.principalOracleAsset,
          ),
          //Only the pool owner can update the pool's terms
          authorize_action(
            create_auth(
              datum.lenderAuth,
              self.inputs,
              self.withdrawals,
              self.extra_signatories,
              self.mint,
            ),
          ),
        }
      },
    )
  }

  else(_) {
    fail
  }
}
