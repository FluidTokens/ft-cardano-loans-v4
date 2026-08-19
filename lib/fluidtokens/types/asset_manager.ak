use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type AssetManagerDatum {
  AssetManagerDatumWithToken {
    inputOutputReference: OutputReference,
    action: ByteArray,
    data: Data,
    ownerAsset: Asset,
  }
  AssetManagerDatumWithHash {
    inputOutputReference: OutputReference,
    action: ByteArray,
    data: Data,
    ownerAuth: AuthorizationMethod,
  }
}

pub type AssetManagerMintRedeemer {
  configRefInputIndex: Int,
  inputRef: OutputReference,
  loanWithdrawRedeemerIndex: Int,
  //This is used only if the loan action is Claim, otherwise it is ignored
  loanClaimActionWithdrawRedeemerIndex: Int,
}

pub type AssetManagerWithdrawRedeemer {
  configRefInputIndex: Int,
}
