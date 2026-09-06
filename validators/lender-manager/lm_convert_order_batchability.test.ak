//// Batchability of the Minswap V2 order produced by
//// `lm_liquidate_and_convert_action`.
////
//// The property under test is the one that was missing entirely: an order this
//// validator accepts must be one a Minswap batcher will actually pick up. That
//// needs BOTH halves of `minswap_order_overhead` present in the order UTxO —
//// `max_batcher_fee` (2 ADA) and the order output's own min-ADA (2 ADA).
////
//// Before the fix the ADA-collateral branch added nothing at all, so every
//// order it produced was unbatchable by construction and sat unfilled forever.

use aiken/builtin
use aiken/collection/list
use aiken/crypto
use amm_dex_v2/types as minswap_types
use amm_dex_v2/utils as minswap_utils
use cardano/address.{Address, Script}
use cardano/assets.{Value, add, from_lovelace}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, Withdraw,
}
use fluidtokens/constants
use fluidtokens/types/asset_manager.{AssetManagerDatumWithToken}
use fluidtokens/types/general.{
  Asset, CardanoWithdrawScript, CollateralAsset, Liquidation,
  PrincipalAndInterestOnInstallments,
}
use fluidtokens/types/lender_manager.{
  LMLiquidateAndConvertActionWithdrawRedeemer, LenderManagerDatum,
}
use fluidtokens/types/loan.{
  ClaimData, LoanClaimActionWithdrawRedeemer, LoanDatum,
}
use fluidtokens/types/minswap_conversions
use lender_manager/lm_liquidate_and_convert_action

// ---------------------------------------------------------------------------
// Script hashes — every role gets a DISTINCT hash, so no filter in the
// validator sweeps a UTxO belonging to another role (a real fixture trap).
// All are 28 bytes, as on chain.
// ---------------------------------------------------------------------------

const config_nft_policy: ByteArray =
  #"c1000000000000000000000000000000000000000000000000000000"

const config_holder_hash: ByteArray =
  #"c2000000000000000000000000000000000000000000000000000000"

const loan_claim_hash: ByteArray =
  #"c3000000000000000000000000000000000000000000000000000000"

const smart_tokens_spend_hash: ByteArray =
  #"50000000000000000000000000000000000000000000000000000000"

const lender_manager_spend_hash: ByteArray =
  #"1a000000000000000000000000000000000000000000000000000000"

const asset_manager_spend_hash: ByteArray =
  #"a1000000000000000000000000000000000000000000000000000000"

const asset_manager_withdraw_hash: ByteArray =
  #"a2000000000000000000000000000000000000000000000000000000"

const minswap_pool_policy: ByteArray =
  #"e0000000000000000000000000000000000000000000000000000000"

const minswap_pool_spend_hash: ByteArray =
  #"e1000000000000000000000000000000000000000000000000000000"

const minswap_pool_withdraw_hash: ByteArray =
  #"e2000000000000000000000000000000000000000000000000000000"

const minswap_order_spend_hash: ByteArray =
  #"e3000000000000000000000000000000000000000000000000000000"

const minswap_order_withdraw_hash: ByteArray =
  #"e4000000000000000000000000000000000000000000000000000000"

const loan_spend_hash: ByteArray =
  #"11000000000000000000000000000000000000000000000000000000"

const loan_policy: ByteArray =
  #"12000000000000000000000000000000000000000000000000000000"

const lender_bond_policy: ByteArray =
  #"b1000000000000000000000000000000000000000000000000000000"

const lender_auth_hash: ByteArray =
  #"aa000000000000000000000000000000000000000000000000000000"

const dummy_hash: ByteArray =
  #"dd000000000000000000000000000000000000000000000000000000"

const principal_policy: ByteArray =
  #"f1000000000000000000000000000000000000000000000000000000"

const collateral_policy: ByteArray =
  #"f2000000000000000000000000000000000000000000000000000000"

const config_nft_name: ByteArray = #"434f4e464947"

const bond_name: ByteArray = #"424f4e44"

const pool_nft_name: ByteArray = #"504f4f4c"

const principal_name: ByteArray = #"5553444d"

const collateral_name: ByteArray = #"544f4b"

// ---------------------------------------------------------------------------
// Loan arithmetic, mirrored from the validator so the expected order value is
// derived rather than copied:
//   swappable = collateral - equity - collateral * feePerMille / 1000
//             = 100_000_000 - 0 - 1_000_000
// ---------------------------------------------------------------------------

const collateral_amount: Int = 100_000_000

const liquidation_fee_per_mille: Int = 10

const equity: Int = 0

const swappable: Int = 99_000_000

const remaining_debt: Int = 28_004_852

/// The overhead the fix introduces: 2 ADA batcher fee + 2 ADA order min-ADA.
const overhead: Int = 4_000_000

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

fn bdata(b: ByteArray) -> Data {
  builtin.b_data(b)
}

/// The protocol config is a positional list of untyped `Data`. The validator
/// reads slots 0, 5, 6 and 10; the rest is padding, but the list must still be
/// long enough or the read aborts at runtime rather than failing to typecheck.
fn config_datum() -> Data {
  builtin.constr_data(
    0,
    [
      bdata(smart_tokens_spend_hash),
      bdata(dummy_hash),
      bdata(dummy_hash),
      bdata(dummy_hash),
      bdata(dummy_hash),
      bdata(lender_bond_policy),
      bdata(loan_policy),
      bdata(dummy_hash),
      bdata(dummy_hash),
      bdata(dummy_hash),
      bdata(loan_spend_hash),
    ],
  )
}

fn script_address(hash: ByteArray) -> Address {
  Address { payment_credential: Script(hash), stake_credential: None }
}

fn out(address: Address, value: Value, datum: Data) -> Output {
  Output { address, value, datum: InlineDatum(datum), reference_script: None }
}

fn input(index: Int, output: Output) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"00000000000000000000000000000000000000000000000000000000000000aa",
      output_index: index,
    },
    output,
  }
}

fn minswap_asset_data(policy: ByteArray, name: ByteArray) -> Data {
  builtin.constr_data(0, [bdata(policy), bdata(name)])
}

/// Mirrors a LIVE Minswap V2 pool datum: field 0 is the batching stake
/// credential in its real on-chain `Inline(Script(h))` shape. The validator
/// must never read it — it takes fields 1 and 2 positionally. If a future
/// change reintroduces a typed `PoolDatum` cast, this fixture fails.
fn pool_datum(asset_a: Data, asset_b: Data) -> Data {
  builtin.constr_data(
    0,
    [
      builtin.constr_data(0, [builtin.constr_data(1, [bdata(dummy_hash)])]),
      asset_a,
      asset_b,
      builtin.i_data(1_000_000),
      builtin.i_data(500_000_000),
      builtin.i_data(500_000_000),
    ],
  )
}

fn lender_manager_datum() -> LenderManagerDatum {
  LenderManagerDatum {
    lenderAuth: CardanoWithdrawScript { hash: lender_auth_hash },
    lenderStakeCredential: None,
    shouldLiquidationConvertToPrincipal: True,
    liquidationFeePerMille: liquidation_fee_per_mille,
    poolId: "",
    principalAsset: Asset {
      policyId: principal_policy,
      assetName: principal_name,
    },
  }
}

fn liquidation_mode() -> general.LiquidationMode {
  Liquidation {
    lTV: 700,
    lTVDivider: 1000,
    partialLiquidationPenaltyPerMille: -1,
    equityInPrincipalCurrency: False,
  }
}

fn loan_datum(collateral: CollateralAsset) -> LoanDatum {
  LoanDatum {
    doneRecasts: 0,
    principalAmount: 25_000_000,
    lendDate: 1_700_000_000_000,
    repaidInstallments: 0,
    interestRate: 1000,
    totalInstallments: 1,
    principalAsset: Asset {
      policyId: principal_policy,
      assetName: principal_name,
    },
    principalOracleAsset: Asset { policyId: "NONE", assetName: "NONE" },
    installmentPeriod: 720,
    initialGracePeriod: 0,
    liquidationMode: liquidation_mode(),
    repaymentMode: PrincipalAndInterestOnInstallments,
    repaymentTimeWindow: 24,
    penaltyFeeForLateRepayment: 0,
    repaymentReceipts: False,
    originId: "",
    collateral,
  }
}

fn claim_data() -> ClaimData {
  ClaimData {
    liquidationMode: liquidation_mode(),
    lenderBondOutputIndex: 1,
    collateralOracleRefInputIndex: 0,
    principalOracleRefInputIndex: 0,
    lenderAuth: CardanoWithdrawScript { hash: lender_auth_hash },
    equity,
    loanId: bond_name,
    remainingDebt: remaining_debt,
  }
}

/// Builds the whole accept-path transaction. `collateral_is_ada` picks which
/// branch of `correctOrderValue` is exercised; `order_value` is the value
/// actually placed on the Minswap order output — the single knob most tests
/// turn; `batcher_fee` likewise for the order datum's declared cap.
fn build_tx(
  collateral_is_ada: Bool,
  order_value: Value,
  batcher_fee: Int,
) -> Transaction {
  let collateral_asset =
    if collateral_is_ada {
      Asset { policyId: "", assetName: "" }
    } else {
      Asset { policyId: collateral_policy, assetName: collateral_name }
    }
  let collateral =
    CollateralAsset {
      policyId: collateral_asset.policyId,
      maybeAssetName: Some(collateral_asset.assetName),
      oracleTokenAsset: Asset { policyId: "NONE", assetName: "NONE" },
    }

  // The loan UTxO holds the collateral plus the loan NFT.
  let loan_value =
    if collateral_is_ada {
      from_lovelace(collateral_amount) |> add(loan_policy, bond_name, 1)
    } else {
      from_lovelace(2_000_000)
        |> add(collateral_policy, collateral_name, collateral_amount)
        |> add(loan_policy, bond_name, 1)
    }

  let loan_input =
    input(
      1,
      out(script_address(loan_spend_hash), loan_value, loan_datum(collateral)),
    )

  let lender_bond_output =
    out(
      script_address(lender_manager_spend_hash),
      from_lovelace(2_000_000) |> add(lender_bond_policy, bond_name, 1),
      lender_manager_datum(),
    )
  let lender_bond_input = input(0, lender_bond_output)

  // The pool is COLLATERAL/PRINCIPAL: asset_a is the collateral, which makes
  // lpABDirection True and asset_b the principal.
  let pool_ref_input =
    input(
      2,
      out(
        script_address(minswap_pool_spend_hash),
        from_lovelace(10_000_000) |> add(minswap_pool_policy, pool_nft_name, 1),
        pool_datum(
          minswap_asset_data(
            collateral_asset.policyId,
            collateral_asset.assetName,
          ),
          minswap_asset_data(principal_policy, principal_name),
        ),
      ),
    )

  let config_ref_input =
    input(
      3,
      out(
        script_address(config_holder_hash),
        from_lovelace(2_000_000) |> add(config_nft_policy, config_nft_name, 1),
        config_datum(),
      ),
    )

  let owner_asset = Asset { policyId: lender_bond_policy, assetName: bond_name }
  let receiver = script_address(asset_manager_spend_hash)

  let success_datum =
    AssetManagerDatumWithToken {
      inputOutputReference: OutputReference {
        transaction_id: "",
        output_index: 0,
      },
      action: constants.converted_to_liquidity_action,
      data: collateral_asset,
      ownerAsset: owner_asset,
    }
  let refund_datum =
    AssetManagerDatumWithToken {
      inputOutputReference: loan_input.output_reference,
      action: constants.action_claimed_collateral,
      data: None,
      ownerAsset: owner_asset,
    }

  let order_datum =
    minswap_types.OrderDatum {
      canceller: minswap_conversions.to_order_auth_method(
        CardanoWithdrawScript { hash: lender_auth_hash },
      ),
      refund_receiver: receiver,
      refund_receiver_datum: minswap_types.EODInlineDatum {
        hash: builtin.serialise_data(refund_datum) |> crypto.blake2b_256,
      },
      success_receiver: receiver,
      success_receiver_datum: minswap_types.EODInlineDatum {
        hash: builtin.serialise_data(success_datum) |> crypto.blake2b_256,
      },
      lp_asset: minswap_types.Asset {
        policy_id: minswap_pool_policy,
        asset_name: minswap_utils.compute_lp_asset_name(
          collateral_asset.policyId,
          collateral_asset.assetName,
          principal_policy,
          principal_name,
        ),
      },
      step: minswap_types.SwapExactIn {
        a_to_b_direction: True,
        swap_amount_option: minswap_types.SAOSpecificAmount {
          swap_amount: swappable,
        },
        minimum_receive: remaining_debt,
        killable: True,
      },
      max_batcher_fee: batcher_fee,
      expiry_setting_opt: None,
    }

  let order_output =
    out(script_address(minswap_order_spend_hash), order_value, order_datum)

  // Outputs 2 and 3 sit at a neutral address so they do not pollute the
  // order / lender-manager output filters.
  let success_output =
    out(script_address(dummy_hash), from_lovelace(2_000_000), success_datum)
  let refund_output =
    out(script_address(dummy_hash), from_lovelace(2_000_000), refund_datum)

  let claim_redeemer: Data =
    LoanClaimActionWithdrawRedeemer {
      configRefInputIndex: 0,
      actionsForEachInput: [claim_data()],
    }

  Transaction {
    ..transaction.placeholder,
    inputs: [lender_bond_input, loan_input],
    reference_inputs: [config_ref_input, pool_ref_input],
    outputs: [order_output, lender_bond_output, success_output, refund_output],
    redeemers: [Pair(Withdraw(Script(loan_claim_hash)), claim_redeemer)],
    withdrawals: [],
  }
}

fn redeemer() -> LMLiquidateAndConvertActionWithdrawRedeemer {
  LMLiquidateAndConvertActionWithdrawRedeemer {
    configRefInputIndex: 0,
    lenderBondInputIndexes: [0],
    lenderBondAssetNames: [bond_name],
    minswapRefInputIndexes: [0],
    minswapPoolAssetNames: [pool_nft_name],
    minswapOrderSuccessInlineDatumOutputIndexes: [2],
    minswapOrderRefundInlineDatumOutputIndexes: [3],
  }
}

fn run(tx: Transaction) -> Bool {
  lm_liquidate_and_convert_action.actionValidator.withdraw(
    config_nft_policy,
    config_nft_name,
    lender_manager_spend_hash,
    asset_manager_spend_hash,
    asset_manager_withdraw_hash,
    minswap_pool_policy,
    minswap_pool_spend_hash,
    minswap_pool_withdraw_hash,
    minswap_order_spend_hash,
    minswap_order_withdraw_hash,
    Script(loan_claim_hash),
    redeemer(),
    Script(dummy_hash),
    tx,
  )
}

// ---------------------------------------------------------------------------
// ACCEPT paths — written first, because a suite of rejections proves nothing
// until one accept passes.
// ---------------------------------------------------------------------------

/// ADA collateral: the order must carry the swapped collateral PLUS the 4 ADA
/// overhead. This is the branch that previously added nothing at all.
test ada_collateral_order_with_overhead_is_accepted() {
  run(build_tx(True, from_lovelace(swappable + overhead), 2_000_000))
}

/// Token collateral: the order carries the collateral token plus exactly the
/// 4 ADA overhead as its lovelace.
test token_collateral_order_with_overhead_is_accepted() {
  run(
    build_tx(
      False,
      from_lovelace(overhead)
        |> add(collateral_policy, collateral_name, swappable),
      2_000_000,
    ),
  )
}

// ---------------------------------------------------------------------------
// REJECT paths — each turns exactly one knob away from the accepted order.
// ---------------------------------------------------------------------------

/// THE REGRESSION TEST. This is precisely what the validator built before the
/// fix on the ADA branch: collateral only, no room for a batcher fee at all.
/// Such an order confirmed on chain and then sat unbatchable forever.
test ada_collateral_order_without_overhead_is_rejected() {
  !run(build_tx(True, from_lovelace(swappable), 2_000_000))
}

/// The old token-branch literal (2.8 ADA) is below what a batcher needs.
test ada_collateral_order_with_old_literal_is_rejected() {
  !run(build_tx(True, from_lovelace(swappable + 2_800_000), 2_000_000))
}

/// Same for the token branch: 2.8 ADA of lovelace is no longer enough.
test token_collateral_order_with_old_literal_is_rejected() {
  !run(
    build_tx(
      False,
      from_lovelace(2_800_000)
        |> add(collateral_policy, collateral_name, swappable),
      2_000_000,
    ),
  )
}

/// An order carrying the right ADA but declaring the OLD 0.7 ADA cap is
/// refused, because the datum no longer matches the expected one. Both halves
/// of the fix are load-bearing.
test order_with_old_batcher_fee_cap_is_rejected() {
  !run(build_tx(True, from_lovelace(swappable + overhead), 700_000))
}

// ---------------------------------------------------------------------------
// The overhead is a FLOOR. Overfunding is accepted on purpose: if min-UTxO
// rises by protocol parameter, a bot can top the order up rather than every
// convert stranding until this script is redeployed. The surplus is not lost —
// Minswap swaps only `swap_amount` and returns the remainder to
// success_receiver, the lender's asset manager.
// ---------------------------------------------------------------------------

test ada_collateral_order_overfunded_is_accepted() {
  run(
    build_tx(True, from_lovelace(swappable + overhead + 5_000_000), 2_000_000),
  )
}

test token_collateral_order_overfunded_ada_is_accepted() {
  run(
    build_tx(
      False,
      from_lovelace(overhead + 5_000_000)
        |> add(collateral_policy, collateral_name, swappable),
      2_000_000,
    ),
  )
}

/// The collateral amount stays an EQUALITY even though the ADA is a floor:
/// Minswap's optimised swap path has strict requirements on the order value's
/// asset entries, so surplus collateral is not the harmless residue surplus
/// ADA is.
test token_collateral_order_with_excess_collateral_is_rejected() {
  !run(
    build_tx(
      False,
      from_lovelace(overhead)
        |> add(collateral_policy, collateral_name, swappable + 1),
      2_000_000,
    ),
  )
}

// ---------------------------------------------------------------------------
// Fixture canary — cannot legitimately fail. If this goes red alongside the
// rest, the shared fixture rotted rather than the validator changing.
// ---------------------------------------------------------------------------

test canary_fixture_shape_is_intact() {
  let tx = build_tx(True, from_lovelace(swappable + overhead), 2_000_000)
  and {
    list.length(tx.inputs) == 2,
    list.length(tx.outputs) == 4,
    list.length(tx.reference_inputs) == 2,
  }
}
