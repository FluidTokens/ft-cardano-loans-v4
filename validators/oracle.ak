use aiken/builtin
use aiken/collection/list
use aiken/math
use aiken/math/rational.{compare}
use aiken/primitive/bytearray.{starts_with}
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, OutputReference, Transaction}
use fluidtokens/authorizer
use fluidtokens/constants
use fluidtokens/types/oracle.{
  CharlieTokenSpecs, FspDat, OracleDatum, OracleRedeemer, OrcfaxTokenSpecs,
  PriceDataCharlie, PriceDataOrcfax, RationalDatum,
} as o
use fluidtokens/utils.{
  get_oracle_config, get_oracle_info, get_oracle_orcfax_config,
}

validator oracle(
  verification_keys: List<ByteArray>,
  threshold: Int,
  _oracle_asset_policy_id: ByteArray,
  _oracle_asset_asset_name: ByteArray,
  governance_token_policy_id: ByteArray,
  governance_token_asset_name: ByteArray,
  charlie_specs: CharlieTokenSpecs,
  orcfax_specs: OrcfaxTokenSpecs,
) {
  //Allow to move Oracle NFT if governance have signed off.
  spend(
    _datum_opt: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    //Governance approval (transaction signed by governance NFT holder)
    authorizer.authorize_via_nft_ownership(
      governance_token_policy_id,
      governance_token_asset_name,
      self.reference_inputs,
      self.inputs,
      self.withdrawals,
    )
  }

  withdraw(redeemer: OracleRedeemer, _credential: Credential, self: Transaction) {
    //Ensure signatures are unique
    let unique_signatures = list.unique(redeemer.signatures)
    expect unique_signatures == redeemer.signatures

    //Ensure signers are unique by forcing a different key position of the verification_keys list
    //(supposing the oracle has been correctly built with unique elements in verification_keys)
    let redeemer_key_positions =
      list.map(unique_signatures, fn(redem) { redem.key_position })
    let unique_key_positions = list.unique(redeemer_key_positions)
    expect unique_key_positions == redeemer_key_positions

    when redeemer.data is {
      PriceDataCharlie {
        provider_ref_input_index,
        common,
        price_in_lovelaces,
        price_denominator,
      } -> {
        //Charlie 3 provides a utxo that keeps refreshing his value price and expiration, so we check that the redeemer that we are passing 
        //is parsing correct information from the main feed, in this way we can use the same withdraw oracle contract to read from our oracles or charlie3
        let charlie_input =
          utils.safe_list_at(self.reference_inputs, provider_ref_input_index)
        expect InlineDatum(referenceDatum) = charlie_input.output.datum
        expect oracleDatum: OracleDatum = referenceDatum

        //Information coming from charli3
        let (price_oracle, start_oracle, end_oracle) =
          get_oracle_info(oracleDatum.price_data)

        //For each assetname our contracts knows what token identifier should look for and also the multipliers to parse the datum from provider to our lovelace format
        let provider_info = get_oracle_config(charlie_specs, common.token)
        let token_provider_identifier = provider_info.1st
        let decimals = provider_info.2nd

        //Suppose token price of 1 FLDT is 0.35 ADA
        //Charlie says 1 FLDT = 350000 lovelace and that it has 6 decimals
        //Therefore 1000000 unitFLDT = 350000 lovelace 
        //unitFLDT/lovelace=0.35
        //So we will write in the redeemer 35 as value and 100 as divider.
        //Another example, token price of 1 SNEK is 0.003 ADA
        //Charlie says 1 SNEK = 3000 lovelace and that it has 0 decimals
        //Therefore 1 unitSNEK = 3000 lovelace
        //So we will write in redeemer 3000 and 1 as divider.
        //Again, token price of 1 Raulito  is 0.20 ADA
        //Charlie says 1 Raulito = 200000 lovelace and that it has 8 decimals
        //Therefore 100000000 unitRaulito = 200000 lovelace
        //1 unitRaulito = 0.002 lovelace
        //So we will write in redeemer 2 and 1000 as divider.
        //The equality that must hold then it's:
        //redeemer_price*charlie3_token_decimals/redeemer_divider == charlie3_price_oracle
        and {
          quantity_of(
            charlie_input.output.value,
            token_provider_identifier,
            constants.charlie_identifier_asset_name,
          ) == 1,
          common.valid_from >= start_oracle,
          common.valid_to <= end_oracle,
          price_in_lovelaces * math.pow(10, decimals) / price_denominator == price_oracle,
        }
      }

      PriceDataOrcfax {
        pointer_ref_input_index,
        provider_ref_input_index,
        common,
        price_in_lovelaces,
        price_denominator,
      } -> {
        let orcfax_pointer_input =
          utils.safe_list_at(self.reference_inputs, pointer_ref_input_index)
        expect InlineDatum(referenceDatum) = orcfax_pointer_input.output.datum
        expect pointerDatum: FspDat = referenceDatum

        let orcfax_price_input =
          utils.safe_list_at(self.reference_inputs, provider_ref_input_index)
        expect InlineDatum(referenceDatum) = orcfax_price_input.output.datum
        expect oracleDatum: RationalDatum = referenceDatum

        let provider_info = get_oracle_orcfax_config(orcfax_specs, common.token)
        let policy_pointer_identifier = provider_info.1st
        let decimals = provider_info.2nd
        let feed_id = provider_info.3rd

        expect Script(orcfax_feed_scripthash) =
          orcfax_price_input.output.address.payment_credential

        expect Script(orcfax_pointer_scripthash) =
          orcfax_pointer_input.output.address.payment_credential

        //Orcfax provides price in numerator/denominator in TOKEN/ADA, but we use unitTOKEN/lovelace so in order to convert it 
        //FLDT/ADA 0.3
        //unitFLDT/lovelace 0.3 because same decimals
        //SNEK/ADA 0.0002 so 200/1000000
        //200 unitSNEK/lovelace 
        //therefore in order to get we multipliy numerator by 10^6 and denominator by 10^decimals of token 
        expect Some(token_price) =
          rational.new(price_in_lovelaces, price_denominator)
        expect Some(multiplier) = rational.new(math.pow(10, decimals), 1000000)
        let result = rational.mul(token_price, multiplier)
        expect Some(orcfax_price) =
          rational.new(
            oracleDatum.statement.body.num,
            oracleDatum.statement.body.denom,
          )
        //Orcfax does not has expiration however has tolerance, meaning that a feed older than that time should not be considered
        //In our case we have 6 hours tolerance
        and {
          orcfax_feed_scripthash == pointerDatum,
          starts_with(oracleDatum.statement.feed_id, feed_id),
          orcfax_pointer_scripthash == policy_pointer_identifier,
          quantity_of(
            orcfax_pointer_input.output.value,
            policy_pointer_identifier,
            constants.orcfax_identifier_pointer_asset_name,
          ) == 1,
          quantity_of(
            orcfax_price_input.output.value,
            pointerDatum,
            constants.orcfax_identifier_feed_asset_name,
          ) == 1,
          common.valid_to - constants.max_orcfax_tolerance <= oracleDatum.statement.created_at,
          compare(result, orcfax_price) == Equal,
        }
      }
      _ -> {
        //Validate that n/m oracles have signed this tx
        let serialise_data = builtin.serialise_data(redeemer.data)
        let valid_signatures =
          list.foldl(
            unique_signatures,
            0,
            fn(redem, valid_signatures) -> Int {
              let verification_key =
                utils.safe_list_at(verification_keys, redem.key_position)
              expect
                builtin.verify_ed25519_signature(
                  verification_key,
                  serialise_data,
                  redem.signature,
                ) == True
              valid_signatures + 1
            },
          )
        valid_signatures >= threshold
      }
    }
  }

  else(_) {
    fail
  }
}
