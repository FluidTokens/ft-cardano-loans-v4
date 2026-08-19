use aiken/builtin
use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{
  PolicyId, Value, ada_policy_id, add, flatten, quantity_of, tokens,
  without_lovelace,
}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/constants
use fluidtokens/finance.{
  get_collateral_amount, get_min_principal_for_collateral_with_oracles,
  get_min_principal_for_collateral_without_oracles,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CardanoSignature, CardanoSpendScript,
  CollateralAsset, Liquidation, PerpetualLoan,
}
use fluidtokens/types/loan.{LoanDatum}
use fluidtokens/types/locked_borrower_manager.{LockedBorrowerManagerDatum}
use fluidtokens/types/pool.{CommonData}
use fluidtokens/types/request.{
  Cancel, CancelAfterExpiration, Lend, RequestDatum, RequestMintRedeemer,
  RequestWithdrawRedeemer,
} as r
use fluidtokens/utils.{
  asset_names_number_of_policy_id, is_output_to_spend_validator, safe_list_at,
  validity_range_within_an_hour,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
  is_output_to_user_smart_credential,
} as st_utils

validator request(configNFTPolicyId: PolicyId, configNFTAssetName: ByteArray) {
  mint(redeemer: RequestMintRedeemer, policy_id: PolicyId, self: Transaction) {
    check_mint(self, redeemer, policy_id, configNFTPolicyId, configNFTAssetName)
  }

  withdraw(
    redeemer: RequestWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(requestPolicyId) = credential
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let requestSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 9))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let borrowerBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 4))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let requestInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(requestSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    utils.indexed_all(
      requestInputs,
      fn(index, input) {
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: RequestDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

        when redeemerAction is {
          Cancel { requestId } ->
            check_cancel(
              input.output.value,
              requestPolicyId,
              requestId,
              self,
              datum.borrowerAuth,
            )
          CancelAfterExpiration { requestId } ->
            check_cancel_after_expiration(
              input.output_reference,
              input.output.value,
              requestPolicyId,
              requestId,
              self,
              datum,
              index,
            )
          Lend {
            principalOracleRefInputIndex,
            collateralOracleRefInputIndex,
            givenPrincipalAmount,
            requestId,
            permissionedConditionWithdrawIndex,
          } ->
            check_lend(
              self,
              input,
              datum,
              index,
              principalOracleRefInputIndex,
              collateralOracleRefInputIndex,
              givenPrincipalAmount,
              requestId,
              requestPolicyId,
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
  redeemer: RequestMintRedeemer,
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
  let requestSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 9))
  let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
  let requestOutputs =
    st_utils.get_outputs_to_smart_credential(
      self.outputs,
      Script(requestSpendScriptHash),
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

        let output = utils.safe_list_at(requestOutputs, index)
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
  requestPolicyId: ByteArray,
  requestId: ByteArray,
  self: Transaction,
  borrowerAuth: AuthorizationMethod,
) {
  and {
    quantity_of(inputValue, requestPolicyId, requestId) == 1,
    quantity_of(self.mint, requestPolicyId, requestId) == -1,
    authorize_action(
      create_auth(
        borrowerAuth,
        self.inputs,
        self.withdrawals,
        self.extra_signatories,
        self.mint,
      ),
    ),
  }
}

fn check_cancel_after_expiration(
  inputRef: OutputReference,
  inputValue: Value,
  requestPolicyId: ByteArray,
  requestId: ByteArray,
  self: Transaction,
  datum: RequestDatum,
  index: Int,
) {
  expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
  let requestExpired = validFrom > datum.requestExpiration
  let borrowerOutput = safe_list_at(self.outputs, index)
  and {
    quantity_of(inputValue, requestPolicyId, requestId) == 1,
    quantity_of(self.mint, requestPolicyId, requestId) == -1,
    requestExpired,
    validate_collateral_less_penalty_output(
      inputRef,
      inputValue,
      borrowerOutput,
      datum.borrowerAddress,
      datum.requestExpirationPenalty,
      requestPolicyId,
      requestId,
    ),
  }
}

fn check_lend(
  self: Transaction,
  input: Input,
  datum: RequestDatum,
  index: Int,
  principalOracleRefInputIndex: Int,
  collateralOracleRefInputIndex: Int,
  givenPrincipalAmount: Int,
  requestId: ByteArray,
  requestPolicyId: ByteArray,
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
  //Request not expired
  expect validTo < datum.requestExpiration
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
  let outputWithBorrowerToken = safe_list_at(self.outputs, index * 2)
  let outputWithPrincipal = safe_list_at(self.outputs, index * 2 + 1)

  expect Some(minPrincipal) =
    rational.new(datum.minPrincipal, datum.minPrincipalDivider)
  let collateralAmount =
    get_collateral_amount(input.output.value, datum.collateral)
  let isLoanOutputValid =
    if datum.dynamicCollateralPrice {
      let collateralOracleRefInput =
        safe_list_at(self.reference_inputs, collateralOracleRefInputIndex)
      let collateralOracleToken = datum.collateral.oracleTokenAsset
      expect Some(collateralOraclePriceFeed) =
        retrieve_oracle_data(
          collateralOracleRefInput.output.address.payment_credential,
          collateralOracleRefInput.output.value,
          self.redeemers,
          validFrom,
          validTo,
          collateralOracleToken.policyId,
          collateralOracleToken.assetName,
          datum.collateral.policyId,
          datum.collateral.maybeAssetName,
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
      expect
        givenPrincipalAmount == get_min_principal_for_collateral_with_oracles(
          collateralAmount,
          minPrincipal,
          principalOraclePriceFeed,
          collateralOraclePriceFeed,
        )
      validate_output_to_loan(
        loanOutput,
        loanPolicyId,
        loanSpendScriptHash,
        datum,
        input.output.value,
        givenPrincipalAmount,
        datum.collateral,
        inputUtxoId,
        validTo,
        datum.borrowerAddress,
        requestPolicyId,
        requestId,
      )
    } else {
      expect
        givenPrincipalAmount >= get_min_principal_for_collateral_without_oracles(
          collateralAmount,
          minPrincipal,
        ) && givenPrincipalAmount <= datum.maxPrincipal

      validate_output_to_loan(
        loanOutput,
        loanPolicyId,
        loanSpendScriptHash,
        datum,
        input.output.value,
        givenPrincipalAmount,
        datum.collateral,
        inputUtxoId,
        validTo,
        datum.borrowerAddress,
        requestPolicyId,
        requestId,
      )
    }
  and {
    or {
      datum.permissionedConditionScriptHash == constants.no_permissioned_condition,
      {
        expect Pair(Script(scriptHash), _amnt) =
          safe_list_at(self.withdrawals, permissionedConditionWithdrawIndex)

        datum.permissionedConditionScriptHash == scriptHash
      },
    },
    quantity_of(input.output.value, requestPolicyId, requestId) == 1,
    quantity_of(self.mint, requestPolicyId, requestId) == -1,
    validity_range_within_an_hour(self),
    isLoanOutputValid,
    bonds_sent_to_both_parties_and_principal_sent_to_borrower(
      input.output_reference,
      self.mint,
      outputWithBorrowerToken,
      outputWithPrincipal,
      borrowerBondPolicyId,
      lenderBondPolicyId,
      inputUtxoId,
      datum.borrowerAddress,
      givenPrincipalAmount,
      datum.commonData.principalAsset,
      datum.commonData.borrowerBondDestinationScriptHash,
      smartTokensSpendScriptHash,
    ),
  }
}

fn validate_collateral_less_penalty_output(
  requestRef: OutputReference,
  requestValue: Value,
  borrowerOutput: Output,
  borrowerAddress: Address,
  requestExpirationPenalty: Int,
  requestPolicyId: ByteArray,
  requestAssetName: ByteArray,
) {
  let inputValueNoAda =
    add(without_lovelace(requestValue), requestPolicyId, requestAssetName, -1)
  let outputValueNoAda = without_lovelace(borrowerOutput.value)
  let outputAdaCorrect =
    quantity_of(borrowerOutput.value, ada_policy_id, "") >= quantity_of(
      requestValue,
      ada_policy_id,
      "",
    ) - requestExpirationPenalty

  and {
    borrowerOutput.address == borrowerAddress,
    borrowerOutput.datum == InlineDatum(requestRef),
    inputValueNoAda == outputValueNoAda,
    outputAdaCorrect,
  }
}

//Expects that the bond minting policy allows minting of a token only if:
//- the AssetName is hash of a tx input
//- the quantity is strictly 1
//We force that the borrower output contains a InlineDatum to allow PlutusV2 contracts to use it
fn bonds_sent_to_both_parties_and_principal_sent_to_borrower(
  requestRef: OutputReference,
  mintedValue: Value,
  outputWithBorrowerToken: Output,
  outputWithPrincipal: Output,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
  bondId: ByteArray,
  borrowerAddress: Address,
  givenPrincipalAmount: Int,
  principalAsset: Asset,
  borrowerBondDestinationScriptHash: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  and {
    is_output_to_user_smart_credential(
      outputWithPrincipal,
      borrowerAddress.payment_credential,
      borrowerAddress.stake_credential,
      smartTokensSpendScriptHash,
    ),
    outputWithPrincipal.datum == InlineDatum(requestRef),
    quantity_of(
      outputWithPrincipal.value,
      principalAsset.policyId,
      principalAsset.assetName,
    ) >= givenPrincipalAmount,
    length(flatten(outputWithPrincipal.value)) == if principalAsset.policyId == ada_policy_id {
      1
    } else {
      2
    },
    if borrowerBondDestinationScriptHash != "" {
      outputWithBorrowerToken.address == Address(
        Script(borrowerBondDestinationScriptHash),
        borrowerAddress.stake_credential,
      )
    } else {
      outputWithBorrowerToken.address == borrowerAddress
    },
    outputWithBorrowerToken.datum == InlineDatum(
      LockedBorrowerManagerDatum {
        originRef: requestRef,
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
    quantity_of(mintedValue, lenderBondPolicyId, bondId) == 1,
  }
}

fn validate_output_to_loan(
  output: Output,
  loanPolicyId: ByteArray,
  loanSpendScriptHash: ByteArray,
  requestDatum: RequestDatum,
  requestValue: Value,
  givenPrincipalAmount: Int,
  collateral: CollateralAsset,
  loanId: ByteArray,
  end: Int,
  borrowerAddress: Address,
  requestPolicyId: ByteArray,
  requestId: ByteArray,
) -> Bool {
  let collateralUnchanged =
    if collateral.policyId == ada_policy_id {
      add(output.value, loanPolicyId, loanId, -1) == add(
        requestValue,
        requestPolicyId,
        requestId,
        -1,
      )
    } else {
      add(without_lovelace(output.value), loanPolicyId, loanId, -1) == add(
        without_lovelace(requestValue),
        requestPolicyId,
        requestId,
        -1,
      )
    }

  let containsLoanNFT = quantity_of(output.value, loanPolicyId, loanId) == 1
  expect InlineDatum(outputDatum) = output.datum
  let newDatum =
    LoanDatum {
      principalAsset: requestDatum.commonData.principalAsset,
      principalOracleAsset: requestDatum.commonData.principalOracleAsset,
      interestRate: requestDatum.commonData.interestRate,
      installmentPeriod: requestDatum.commonData.installmentPeriod,
      initialGracePeriod: requestDatum.commonData.initialGracePeriod,
      liquidationMode: requestDatum.commonData.liquidationMode,
      repaymentMode: requestDatum.commonData.repaymentMode,
      repaymentTimeWindow: requestDatum.commonData.repaymentTimeWindow,
      penaltyFeeForLateRepayment: requestDatum.commonData.penaltyFeeForLateRepayment,
      repaymentReceipts: requestDatum.commonData.repaymentReceipts,
      totalInstallments: requestDatum.commonData.totalInstallments,
      originId: bytearray.concat("REQUEST", requestId),
      collateral,
      principalAmount: givenPrincipalAmount,
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
    length(flatten(output.value)) == when collateral.maybeAssetName is {
      Some(_chosenCollateralAssetName) ->
        if collateral.policyId == ada_policy_id {
          2
        } else {
          3
        }
      None ->
        asset_names_number_of_policy_id(output.value, collateral.policyId) + 2
    }
  and {
    correctDestination,
    isDatumCorrect,
    containsLoanNFT,
    collateralUnchanged,
    dosProtection,
  }
}
