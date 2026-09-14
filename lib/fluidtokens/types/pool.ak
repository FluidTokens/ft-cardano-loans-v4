//NOT DONE: Deferment (with and without interest accruement)
//NOT DONE: Variable interest rate with oracle, eventual with min and max caps, eventual with first N installments at a fixed rate
//Margin calls are done off-chain as soon as the oracle signals a too-low LTV.
//Forgiveness in case of default is accomplished by sending the collateral back to the borrower in case of Full Collateral Claim.
//If the penalty fee should be sent to an address different from the lender, then the lender nft must be locked in a dedicated contract that says so.
//Loan refinancing is done spending the new loan and the old loan in the same tx.
use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CollateralAsset, LiquidationMode, RepaymentMode,
}

pub type CommonData {
  principalAsset: Asset,
  //Used in dynamicPriced pools and in partial liquidations, it indicates the oracle NFT for the principal
  principalOracleAsset: Asset,
  //The interest rate of the loan is this number/10000, so 0.01% is expressed as 1.
  //For perpetuals this variable actually represents c in the formula APY=mx+c, and it can be used for:
  //installmentAmount (hourly) = c/10000/8760
  interestRate: Int,
  //How much time between 2 consecutive installments, expressed in hours
  //In case of Perpetual loans if it's > 0 it means we have infinite installments otherwise == 0 means no installments
  installmentPeriod: Int,
  //Total number of installments, ignored in Perpetual loans
  totalInstallments: Int,
  //Period after starting the loan and before starting repaying (borrower can't be liquidated in this period)
  //Expressed in hours
  initialGracePeriod: Int,
  liquidationMode: LiquidationMode,
  repaymentMode: RepaymentMode,
  //Period to repay without being considered late, expressed in hours
  //After this period, borrower can be liquidated if he hasn't paid the installment
  repaymentTimeWindow: Int,
  //Fee borrower pays when he could be liquidated but he repays, <= 0 means no penalty
  penaltyFeeForLateRepayment: Int,
  //If true, each payment for claim, recast and repay must be accompanied by a minted repayment receipt NFT
  repaymentReceipts: Bool,
  //If "" then the borrower wallet gets the bond, otherwise it's the script hash that receives it
  //with a standard Inline LockedBorrowerManagerDatum 
  borrowerBondDestinationScriptHash: ByteArray,
}

pub type PoolDatum {
  //Permissioned pools use this field to specify an extra Withdraw validator to force the conditions of the Borrow action.
  //Put "NONE" if it's a permissionless pool
  permissionedConditionScriptHash: ByteArray,
  //Extend the pool datum for cases like permissioned pools. It will be parsed properly depending on specific use case.
  extraData: Data,
  commonData: CommonData,
  //The auth that can cancel the pool
  lenderAuth: AuthorizationMethod,
  //Where the lender bond NFT is sent when a loan is created
  lenderBondAddress: Address,
  //The datum blake2b_256 hash of the InlineDatum serialised data of the lender bond NFT output
  lenderBondInlineDatumHash: ByteArray,
  //This pool can cover multiple collections/token, but only one of them can be chosen for each loan (ie. no mixed bundle loans).
  //Important requirement: if Liquidation is enabled, ALL the collateralOptions must have an oracle NFT
  collateralOptions: List<CollateralAsset>,
  //When oracle is used, this is the LTV for each collateral option (borrower can ask more using an exact multiple). 
  //This is the ratio between principal and collateral when their value is expressed in lovelace.
  //For example, a LTV of 0.123 mean that principalInLovelace / collateralInLovelace = 0.123.
  //In this case, minCollateral = 123 and minCollateralDivider = 1000 .
  //If no oracle is used, then this is the collateral amount expressed in units of the token for each unit of principal.
  //For example, if the principal is lovelace and the collateral unitFLDT and lender wants 0.123 unitFLDT for each lovelace lent: 
  //minCollateral = 123 and minCollateralDivider = 1000 .
  minCollateral: List<Int>,
  minCollateralDivider: List<Int>,
  //True if borrowable amount of the collateralOptions must be updated through oracles
  dynamicCollateralPrice: Bool,
}

pub type PoolMintRedeemer {
  configRefInputIndex: Int,
  inputRef: OutputReference,
}

pub type Action {
  //Pool's owner can cancel the pool
  Cancel
  //Any user can become borrower
  Borrow
  //This pool acquires an existing lender position if all loan params are compatible
  SellLenderPosition
  //Bots can compound to the pool
  Compound
  //Pool's owner can update the pool's terms in place, without burning/reminting its NFT,
  //so outstanding loans (which reference this pool by its NFT asset name) can still compound
  Update
}

pub type PoolWithdrawRedeemer {
  configRefInputIndex: Int,
  action: Action,
}

pub type CancelData {
  poolId: ByteArray,
}

pub type BorrowData {
  borrowerAddress: Address,
  outputWithLenderTokenIndex: Int,
  outputWithBorrowerTokenIndex: Int,
  //Ref input index of the principal oracle, if principal is ADA this must be -1
  principalOracleRefInputIndex: Int,
  //Index of the Asset that the borrower is providing, must be accepted by the pool
  chosenCollateralIndex: Int,
  //If collateral doesn't use oracle or is ADA, this must be -1
  chosenCollateralOracleRefInputIndex: Int,
  //How much principal the borrower wants in units. 
  //For example if borrower wants 123 FLDT he must write 123000000 .
  //It cannot be completely arbitrary as pools allow only certain amounts.
  wantedPrincipalAmount: Int,
  poolId: ByteArray,
  permissionedConditionWithdrawIndex: Int,
}

pub type SellingLenderBondInfo {
  lenderBondInputIndex: Int,
  lenderBondAssetName: ByteArray,
  loanRefInputIndex: Int,
  outputWithLenderTokenIndex: Int,
  poolCollateralIndex: Int,
  collateralOracleRefInputIndex: Int,
  principalOracleRefInputIndex: Int,
}

pub type SellLenderPositionData {
  lenderBondsInfo: List<SellingLenderBondInfo>,
  poolId: ByteArray,
}

pub type CompoundData {
  poolId: ByteArray,
}

pub type PoolCancelActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<CancelData>,
}

pub type PoolBorrowActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<BorrowData>,
}

pub type PoolSellLenderPositionActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<SellLenderPositionData>,
}

pub type PoolCompoundActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<CompoundData>,
}

pub type UpdateData {
  poolId: ByteArray,
}

pub type PoolUpdateActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<UpdateData>,
}
