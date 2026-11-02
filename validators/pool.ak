use aiken/builtin
use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/crypto
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, Value, flatten, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, find_input}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/constants
use fluidtokens/finance.{
  get_needed_collateral_with_oracles, get_needed_collateral_without_oracles,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CollateralAsset, Liquidation,
}
use fluidtokens/types/loan.{LoanDatum}
use fluidtokens/types/pool.{
  Borrow, Cancel, PoolDatum, PoolMintRedeemer, PoolWithdrawRedeemer,
} as p
use fluidtokens/utils.{
  asset_names_number_of_policy_id, is_output_to_spend_validator,
  quantity_of_policy_id, safe_list_at, validity_range_within_an_hour,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator pool(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray) {
  mint(redeemer: PoolMintRedeemer, policy_id: PolicyId, self: Transaction) {
    check_mint(self, redeemer, policy_id, configNFTPolicyId, configNFTAssetName)
  }

  withdraw(
    redeemer: PoolWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(poolPolicyId) = credential
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let borrowerBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 4))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      poolInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: PoolDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

        when redeemerAction is {
          Cancel { poolId } ->
            check_cancel(
              input.output.value,
              poolPolicyId,
              poolId,
              self,
              datum.lenderAuth,
            )
          Borrow {
            borrowerAddress,
            outputWithLenderTokenIndex,
            principalOracleRefInputIndex,
            chosenCollateralIndex,
            chosenCollateralOracleRefInputIndex,
            wantedPrincipalAmount,
            poolId,
            permissionedConditionWithdrawIndex,
          } ->
            check_borrow(
              self,
              input,
              datum,
              index,
              outputWithLenderTokenIndex,
              chosenCollateralIndex,
              wantedPrincipalAmount,
              chosenCollateralOracleRefInputIndex,
              principalOracleRefInputIndex,
              borrowerAddress,
              poolPolicyId,
              poolId,
              permissionedConditionWithdrawIndex,
              loanSpendScriptHash,
              loanPolicyId,
              smartTokensSpendScriptHash,
              borrowerBondPolicyId,
              lenderBondPolicyId,
            )
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
    list.indexed_foldr(
      mintedTokens,
      True,
      fn(index, Pair(assetName, quantity), result) {
        expect result

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

fn check_cancel(
  inputValue: Value,
  poolPolicyId: ByteArray,
  poolId: ByteArray,
  self: Transaction,
  lenderAuth: AuthorizationMethod,
) {
  and {
    quantity_of(inputValue, poolPolicyId, poolId) == 1,
    quantity_of(self.mint, poolPolicyId, poolId) == -1,
    authorize_action(
      create_auth(
        lenderAuth,
        self.inputs,
        self.withdrawals,
        self.extra_signatories,
        self.mint,
      ),
    ),
  }
}

fn check_borrow(
  self: Transaction,
  input: Input,
  datum: PoolDatum,
  index: Int,
  outputWithLenderTokenIndex: Int,
  chosenCollateralIndex: Int,
  wantedPrincipalAmount: Int,
  chosenCollateralOracleRefInputIndex: Int,
  principalOracleRefInputIndex: Int,
  borrowerAddress: Address,
  poolPolicyId: ByteArray,
  poolId: ByteArray,
  permissionedConditionWithdrawIndex: Int,
  loanSpendScriptHash: ByteArray,
  loanPolicyId: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
) {
  expect (Finite(validFrom), Finite(validTo)) =
    (
      self.validity_range.lower_bound.bound_type,
      self.validity_range.upper_bound.bound_type,
    )
  let inputUtxoId = utils.hash_output_ref(input.output_reference)
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
  let outputWithLenderToken =
    safe_list_at(self.outputs, outputWithLenderTokenIndex)
  let chosenCollateral =
    safe_list_at(datum.collateralOptions, chosenCollateralIndex)
  let remainingPrincipalAmountAfterBorrow =
    quantity_of(
      input.output.value,
      datum.commonData.principalAsset.policyId,
      datum.commonData.principalAsset.assetName,
    ) - wantedPrincipalAmount

  expect Some(minCollateral) =
    rational.new(
      safe_list_at(datum.minCollateral, chosenCollateralIndex),
      safe_list_at(datum.minCollateralDivider, chosenCollateralIndex),
    )
  let isLoanOutputValid =
    if datum.dynamicCollateralPrice {
      let collateralOracleRefInput =
        safe_list_at(self.reference_inputs, chosenCollateralOracleRefInputIndex)
      let chosenCollateralOracleToken = chosenCollateral.oracleTokenAsset
      expect Some(collateralOraclePriceFeed) =
        retrieve_oracle_data(
          collateralOracleRefInput.output.address.payment_credential,
          collateralOracleRefInput.output.value,
          self.redeemers,
          validFrom,
          validTo,
          chosenCollateralOracleToken.policyId,
          chosenCollateralOracleToken.assetName,
          chosenCollateral.policyId,
          chosenCollateral.maybeAssetName,
        )
      let principalOracleRefInput =
        safe_list_at(self.reference_inputs, principalOracleRefInputIndex)
      expect Some(principalOraclePriceFeed) =
        retrieve_oracle_data(
          principalOracleRefInput.output.address.payment_credential,
          principalOracleRefInput.output.value,
          self.redeemers,
          validFrom,
          validTo,
          datum.commonData.principalOracleAsset.policyId,
          datum.commonData.principalOracleAsset.assetName,
          datum.commonData.principalAsset.policyId,
          Some(datum.commonData.principalAsset.assetName),
        )
      validate_output_to_loan(
        loanOutput,
        loanPolicyId,
        loanSpendScriptHash,
        datum,
        wantedPrincipalAmount,
        chosenCollateral,
        get_needed_collateral_with_oracles(
          wantedPrincipalAmount,
          minCollateral,
          principalOraclePriceFeed,
          collateralOraclePriceFeed,
        ),
        inputUtxoId,
        validTo,
        borrowerAddress,
        poolId,
      )
    } else {
      validate_output_to_loan(
        loanOutput,
        loanPolicyId,
        loanSpendScriptHash,
        datum,
        wantedPrincipalAmount,
        chosenCollateral,
        get_needed_collateral_without_oracles(
          wantedPrincipalAmount,
          minCollateral,
        ),
        inputUtxoId,
        validTo,
        borrowerAddress,
        poolId,
      )
    }
  and {
    wantedPrincipalAmount > 0,
    or {
      datum.permissionedConditionScriptHash == constants.no_permissioned_condition,
      {
        expect Pair(Script(scriptHash), _amnt) =
          safe_list_at(self.withdrawals, permissionedConditionWithdrawIndex)

        datum.permissionedConditionScriptHash == scriptHash
      },
    },
    quantity_of(input.output.value, poolPolicyId, poolId) == 1,
    validity_range_within_an_hour(self),
    isLoanOutputValid,
    bonds_sent_to_both_parties(
      self.mint,
      outputWithLenderToken,
      borrowerBondPolicyId,
      lenderBondPolicyId,
      inputUtxoId,
      datum.lenderBondAddress,
      datum.lenderBondInlineDatumHash,
    ),
    or {
      and {
        remainingPrincipalAmountAfterBorrow == 0,
        quantity_of(self.mint, poolPolicyId, poolId) == -1,
      },
      and {
        remainingPrincipalAmountAfterBorrow > 0,
        validate_eventual_output_to_pool(
          safe_list_at(self.outputs, index),
          datum,
          remainingPrincipalAmountAfterBorrow,
          poolPolicyId,
          poolId,
          input.output.address,
          length(flatten(input.output.value)),
        ),
      },
    },
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
) {
  expect InlineDatum(outputWithLenderTokenDatum) = outputWithLenderToken.datum
  and {
    outputWithLenderToken.address == lenderBondAddress,
    crypto.blake2b_256(builtin.serialise_data(outputWithLenderTokenDatum)) == lenderBondInlineDatumHash,
    quantity_of(mintedValue, borrowerBondPolicyId, bondId) == 1,
    quantity_of(outputWithLenderToken.value, lenderBondPolicyId, bondId) == 1,
    length(flatten(outputWithLenderToken.value)) == 2,
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
  let containsEnoughCollateral =
    when chosenCollateral.maybeAssetName is {
      Some(chosenCollateralAssetName) ->
        quantity_of(
          output.value,
          chosenCollateral.policyId,
          chosenCollateralAssetName,
        ) >= minNeededCollateralAmount
      None ->
        quantity_of_policy_id(output.value, chosenCollateral.policyId) >= minNeededCollateralAmount
    }

  let containsLoanNFT = quantity_of(output.value, loanPolicyId, loanId) == 1
  expect InlineDatum(outputDatum) = output.datum
  let newDatum =
    LoanDatum {
      principalAsset: poolDatum.commonData.principalAsset,
      principalOracleAsset: poolDatum.commonData.principalOracleAsset,
      interestRate: poolDatum.commonData.interestRate,
      installmentPeriod: poolDatum.commonData.installmentPeriod,
      initialGracePeriod: poolDatum.commonData.initialGracePeriod,
      liquidationMode: poolDatum.commonData.liquidationMode,
      repaymentMode: poolDatum.commonData.repaymentMode,
      repaymentTimeWindow: poolDatum.commonData.repaymentTimeWindow,
      penaltyFeeForLateRepayment: poolDatum.commonData.penaltyFeeForLateRepayment,
      repaymentReceipts: poolDatum.commonData.repaymentReceipts,
      totalInstallments: poolDatum.commonData.totalInstallments,
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
  let isDatumCorrect =
    builtin.equals_data(outputDatum, newDatum) && isLiquidationCorrectlySet

  let correctDestination =
    if is_output_to_spend_validator(output, loanSpendScriptHash) {
      output.address.stake_credential == borrowerAddress.stake_credential
    } else {
      //outputs have been already filtered at the beginning
      True
    }
  let dosProtection =
    length(flatten(output.value)) == when chosenCollateral.maybeAssetName is {
      Some(_chosenCollateralAssetName) ->
        if chosenCollateral.policyId == "" {
          2
        } else {
          3
        }
      None ->
        asset_names_number_of_policy_id(output.value, chosenCollateral.policyId) + 2
    }
  and {
    correctDestination,
    isDatumCorrect,
    containsLoanNFT,
    containsEnoughCollateral,
    dosProtection,
  }
}

//Expects remainingPrincipalAmountAfterBorrow > 0
fn validate_eventual_output_to_pool(
  output: Output,
  datum: PoolDatum,
  remainingPrincipalAmountAfterBorrow: Int,
  poolPolicyId: ByteArray,
  poolId: ByteArray,
  poolInputOutputAddress: Address,
  poolInputAssetsLength: Int,
) {
  expect InlineDatum(outputDatum) = output.datum

  let containsCorrectAmount =
    quantity_of(
      output.value,
      datum.commonData.principalAsset.policyId,
      datum.commonData.principalAsset.assetName,
    ) == remainingPrincipalAmountAfterBorrow

  let containsPoolNFT = quantity_of(output.value, poolPolicyId, poolId) == 1

  let isDatumCorrect = builtin.equals_data(outputDatum, datum)

  let dosProtection = length(flatten(output.value)) == poolInputAssetsLength

  let correctDestination = poolInputOutputAddress == output.address

  and {
    correctDestination,
    isDatumCorrect,
    containsPoolNFT,
    containsCorrectAmount,
    dosProtection,
  }
}
