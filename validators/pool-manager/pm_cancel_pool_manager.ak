use aiken/builtin
use aiken/collection/list
use cardano/address.{Address, Credential, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/pool.{Cancel, PoolWithdrawRedeemer} as pw
use fluidtokens/types/pool_manager.{
  CancelPoolManagerActionWithdrawRedeemer, PoolManagerDatum,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator poolManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolPolicyId: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: CancelPoolManagerActionWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let poolManagerSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 27))
    let poolManagerPolicyId = builtin.un_b_data(utils.safe_list_at(config, 28))

    let poolManagerInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
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

    and {
      //Pools must be spent
      list.length(poolInputs) > 0,
      //Same number of pools and pool managers being cancelled
      list.length(poolInputs) == list.length(poolManagerInputs),
      //Same number of pool managers and their NFT asset names
      list.length(poolManagerInputs) == list.length(
        redeemer.poolManagerNFTAssetNames,
      ),
      //No duplicate NFT names, so every input below is matched exactly once
      list.unique(redeemer.poolManagerNFTAssetNames) == redeemer.poolManagerNFTAssetNames,
      //Pool cancel action must be executed
      {
        let poolWithdrawRedeemer =
          safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
        expect poolWithdrawRedeemer.1st == Withdraw(Script(poolPolicyId))
        expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd

        when poolRedeemer.action is {
          pw.Cancel { .. } -> True
          _ -> False
        }
      },
      list.all(
        redeemer.poolManagerNFTAssetNames,
        fn(poolManagerNFTAssetName) {
          //Match the pool manager input by the NFT it holds, not by list position
          expect Some(input) =
            list.find(
              poolManagerInputs,
              fn(mgrInput) {
                quantity_of(
                  mgrInput.output.value,
                  poolManagerPolicyId,
                  poolManagerNFTAssetName,
                ) == 1
              },
            )

          //Pool must have same NFT of pool manager
          expect Some(_poolInput) =
            list.find(
              poolInputs,
              fn(pInput) {
                quantity_of(
                  pInput.output.value,
                  poolPolicyId,
                  poolManagerNFTAssetName,
                ) == 1
              },
            )

          expect InlineDatum(inputDatum) = input.output.datum
          expect PoolManagerDatum { poolOwnerAuth, .. } = inputDatum

          and {
            //The pool manager NFT must be burnt
            quantity_of(self.mint, poolManagerPolicyId, poolManagerNFTAssetName) == -1,
            //Authorize the pool owner to execute this action
            authorize_action(
              create_auth(
                poolOwnerAuth,
                self.inputs,
                self.withdrawals,
                self.extra_signatories,
                self.mint,
              ),
            ),
          }
        },
      ),
    }
  }

  else(_) {
    fail
  }
}
