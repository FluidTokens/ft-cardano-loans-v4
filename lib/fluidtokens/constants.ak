use fluidtokens/types/general.{Asset}

pub const config_asset_name = "parameters"

pub const max_oracle_validity_range = 3600000

pub const no_permissioned_condition = "NONE"

pub const action_installment_repayment = "installment_repayment"

pub const action_recast = "recast"

pub const action_partial_liquidation_compensation = "partial_liquidation"

pub const action_claimed_collateral = "claimed_collateral"

pub const action_dutch_auction_partial_liquidation_compensation =
  "dutch_auction_partial_liquidation_compensation"

pub const action_dutch_auction_claimed_collateral =
  "dutch_auction_claimed_collateral"

pub const converted_to_liquidity_action = "converted_to_liquidity"

pub const dutch_auction_owner_revenue = "dutch_auction_owner_revenue"

pub const dutch_auction_borrower_compensation =
  "dutch_auction_borrower_compensation"

pub const charlie_identifier_asset_name = "OracleFeed"

pub const orcfax_identifier_pointer_asset_name = #"000de140"

//feed is empty
pub const orcfax_identifier_feed_asset_name = ""

//7 hours max time heartbeat
pub const max_orcfax_tolerance = 25200000

pub const hour_to_millis = 3600000

pub const no_oracle_token_asset = Asset { policyId: "NONE", assetName: "NONE" }

//Minimum fee a bot earns when compounding into an ADA pool (1 ADA)
pub const min_compounding_fee_lovelace = 1000000
