use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{Output, Transaction, find_input}
use fluidtokens/types/pool.{
  Borrow, Cancel, Compound, PoolMintRedeemer, PoolWithdrawRedeemer,
  SellLenderPosition, Update,
} as p
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils as st_utils

validator pool(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray) {
  mint(redeemer: PoolMintRedeemer, policy_id: PolicyId, self: Transaction) {
    check_mint(self, redeemer, policy_id, configNFTPolicyId, configNFTAssetName)
  }

  withdraw(
    redeemer: PoolWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let poolCancelActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 22))
    let poolBorrowActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 23))
    let poolSellLenderPositionActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 24))
    let poolCompoundActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 25))
    let poolUpdateActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 33))
    let actionWithdrawScriptHash =
      when redeemer.action is {
        Cancel { .. } -> poolCancelActionScriptHash
        Borrow { .. } -> poolBorrowActionScriptHash
        SellLenderPosition { .. } -> poolSellLenderPositionActionScriptHash
        Compound { .. } -> poolCompoundActionScriptHash
        Update { .. } -> poolUpdateActionScriptHash
      }

    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(scriptHash), _amnt) ->
            scriptHash == actionWithdrawScriptHash
          _ -> False
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn check_mint(
  self: Transaction,
  redeemer: PoolMintRedeemer,
  policy_id: PolicyId,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) -> Bool {
  let config =
    utils.get_config_as_data_list(
      safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
      configNFTPolicyId,
      configNFTAssetName,
    )
  let smartTokensSpendScriptHash =
    builtin.un_b_data(utils.safe_list_at(config, 0))
  let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
  let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
  let poolOutputs =
    st_utils.get_outputs_to_smart_credential(
      self.outputs,
      Script(poolSpendScriptHash),
      Script(policy_id),
      smartTokensSpendScriptHash,
    )
  let isInputRefSpent =
    option.is_some(find_input(self.inputs, redeemer.inputRef))

  let mintedTokens =
    list.filter(
      dict.to_pairs(tokens(self.mint, policy_id)),
      fn(Pair(_assetName, quantity)) { quantity > 0 },
    )

  let isEachMintedTokenAccountedFor =
    utils.indexed_all(
      mintedTokens,
      fn(index, Pair(assetName, quantity)) {
        let correctAssetName = and {
            bytearray.at(assetName, 0) == index,
            bytearray.drop(assetName, 1) == inputRefHash,
          }

        let output = utils.safe_list_at(poolOutputs, index)
        let outputHasUniqueToken = and {
            dict.size(assets.tokens(output.value, policy_id)) == 1,
            assets.quantity_of(output.value, policy_id, assetName) == 1,
          }
        and {
          quantity == 1,
          correctAssetName,
          outputHasUniqueToken,
        }
      },
    )

  and {
    isInputRefSpent,
    isEachMintedTokenAccountedFor,
  }
}
