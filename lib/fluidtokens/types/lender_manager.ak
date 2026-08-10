use cardano/address.{Credential, StakeCredential}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type LMConfigDatum {
  adminCredential: Credential,
  lmWithdrawBondsActionScriptHash: ByteArray,
  lmLiquidateActionScriptHash: ByteArray,
  lmCompoundActionScriptHash: ByteArray,
  lmLiquidateAndPayInAdvanceActionScriptHash: ByteArray,
  lmLiquidateAndConvertActionScriptHash: ByteArray,
  lmLiquidatePayInAdvanceAndCompoundActionScriptHash: ByteArray,
  lmLiquidateConvertAndCompoundActionScriptHash: ByteArray,
}

pub type LenderManagerDatum {
  //Auth to get the lender bond back
  lenderAuth: AuthorizationMethod,
  //Stake credential of the lender, used for any utxo created by the bots
  lenderStakeCredential: Option<StakeCredential>,
  //If false, the collateral must not be converted to principal during liquidations
  shouldLiquidationConvertToPrincipal: Bool,
  //How much the bot gets of the liquidated collateral, expressed in per mille (1/1000)
  liquidationFeePerMille: Int,
  //If "", no compounding is allowed
  poolId: ByteArray,
  //The repaid/liquidated loan must have the same principal of the specified pool
  principalAsset: Asset,
}

pub type LenderManagerAction {
  //Lender can withdraw his bond any time
  WithdrawBonds
  //Liquidate loans and put the collaterals in this contract
  Liquidate
  //Compound available assets into the pool
  Compound
  //Liquidate loans and pay in advance the corresponding principal in exchange for the collateral
  LiquidateAndPayInAdvance
  //Liquidate loans and convert the collateral to principal
  LiquidateAndConvert
  //Liquidate + pay in advance + compound 
  LiquidatePayInAdvanceAndCompound
  //Liquidate + convert + compound
  LiquidateConvertAndCompound
}

pub type LenderManagerWithdrawRedeemer {
  configRefInputIndex: Int,
  action: LenderManagerAction,
}

pub type LMLiquidateWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  assetOutputIndexes: List<Int>,
}

pub type LMCompoundWithdrawRedeemer {
  configRefInputIndex: Int,
  poolIds: List<ByteArray>,
  poolInputIndexes: List<Int>,
  lenderBondInputIndexes: List<Int>,
}

pub type LMLiquidateAndPayInAdvanceWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  principalAndCollateralOracleRefInputIndexes: List<(Int, Int)>,
  assetOutputIndexes: List<Int>,
}

pub type LMLiquidateAndConvertActionWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  minswapRefInputIndexes: List<Int>,
  minswapPoolAssetNames: List<ByteArray>,
  minswapOrderSuccessInlineDatumOutputIndexes: List<Int>,
  minswapOrderRefundInlineDatumOutputIndexes: List<Int>,
}

pub type LMLiquidatePayInAdvanceAndCompoundWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  poolIds: List<ByteArray>,
  poolInputIndexes: List<Int>,
  principalAndCollateralOracleRefInputIndexes: List<(Int, Int)>,
}

pub type LMLiquidatConvertAndCompoundWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  minswapV2InfoRefInputIndex: Int,
}
