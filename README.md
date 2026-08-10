# FluidTokens Lending V4

This repo contains the official smart contracts for the lending platform of FluidTokens.
The logic is thought to be highly customizable, as the same contracts may be used for different flavours of lending.

## Features
The following features are supported:
* Static lending pools: owned by a single user (can be wallet or script) and can be spent by multiple borrowers until they are emptied
* Native multisig wallet support for institutionals and whales that don't want to delegate their liquidity
* Dynamic lending pools: like static pools but the borrowable amount is enstablished by LTV and oracles
* In the same tx, the borrower can borrow from multiple pools
* Static and dynamic loan requests: borrower can request a specific loan that lenders can accept
* Each pool can accept different collaterals but only 1 for each loan
* Installments: split the repayment of the loan in multiple installments
* Initial grace period where borrower doesn't have to repay yet
* Penalty fee for late repayments
* 4 liquidation types:
    * No liquidation, lender gets all the collateral if borrower doesn't repay in time
    * No liquidation, collateral goes to a dutch auction that can potentially repay the difference to the borrower
    * Oracle liquidation, lender gets all the collateral
    * Oracle liquidation, lender gets the collateral but has to pay the difference to the borrower 
* 3 repayment formulas:
    * (Principal+Interest)/Installments
    * Amortization formula
    * Perpetual loans, without a deadline, pay installments the interest accumulated along a curve
* Generation of bonds for lender and borrower in order to be flexible with their position
* Lender bond can have datum to be compatible with PlutusV2 scripts
* Recast: in case the Amortization formula is used, borrower can repay a number of times the principal to reduce the debt. Recast is allowed also in perpetual loans with 0 installments.
* Refinancing: repaying in one tx the loan with the liquidity coming from a new loan
* Permissioned pools and loan requests:
    * The pool is spendable if a KYC token is properly added to the tx
    * The request can be accepted if the lender is a specific user (wallet or script)
* Pools, requests, loans and repayments utxos are identified by a unique NFT to allow on-chain accounting (no fake pools, etc.)
* 3 types of oracle feeds (they are always tokenX/lovelace):
    * Aggregated: from CEX
    * Pooled: from DEX
    * Dedicated: dedicated for specific use cases (where the value of the collateral must come from outside sources)
* CIP113 (smart tokens) support: principal, collateral and oracle feed support CIP113 tokens
* Custom field to explain what a particular repayment is referring to
* Automatic liquidations and compounding (see next section)
* Lenders can sell their positions to compatible pools to receive the liquidity back when needed
* Borrowers can be locked so they cannot transfer their loan position to anyone else

## Lending and borrowing
* Pools, requests and loans are all identified by unique NFTs.
* Lender and Borrower positions are represented by bonds (NFTs) that can be exchanged, sold or transferred.
* Repayments are sent directly to the Lender specified address with a specified Datum.
* The borrower can borrow from multiple pools at the same time.
* The lender can specify multiple markets to participate at once with his liquidity pool.
* In any moment, in case of emergency, the lender can sale the loan to another available pool (it must have the same parameters and it must not be a permissioned pool) for the value of the principal lent.
* Providing ADA in your own liquidity Pool allows you to earn the ADA staking rewards when the liquidity is idle.
* The contracts are composable with other Cardano DeFi protocols.
* FluidTokens doesn't have any custody of your assets, they are always fully yours.

## Automatic liquidations and compounding
Lenders can enable automatic loan liquidations and optional automatic principal compounding to the pool.
Bots compete to execute these transactions and earn liquidation and compounding fees that are set by the lender.

* When a Lender creates a liquidity pool, in the same transaction he must also mint a PoolManager with the poolId field equal to the ID of the new pool:
    1) The pool lenderAuth field must be set as the Withdraw script hash of the PoolManager. 
    2) The pool lenderBondAddress field must be set as the Spend script hash of the LenderManager.
    3) The pool lenderBondInlineDatumHash field must be the blake2b_256 hash of the LenderManagerDatum.
    4) The field shouldLiquidationConvertToPrincipal must be set to True if bots should convert the liquidated collateral into principal (either paying it in advance or converting it through DEX), otherwise they will simply liquidate the collateral and put it in the LenderManager Spend script.
    5) For automatic compounding, the field poolId must be set as the NFT AssetName of the newly created PoolManager, otherwise leave it empty.
* When a new loan is created, the Lender's bond will now get locked in LenderManager Spend script.
* Each borrower repayment (installment, full amount, recast) will be sent to the LenderManager Spend script.
* To cancel/edit a pool, the Lender now has to also burn the corresponding PoolManager.
* The Lender can edit the PoolManager datum to change ownership of the lender bond or to change the compounding fee.
* If shouldLiquidationConvertToPrincipal is False, bots can only liquidate the loans collateral. The result is placed in the LenderManager Spend script.
* If shouldLiquidationConvertToPrincipal is True, bots must liquidate and convert the collateral to principal. They can do either by placing an order on the DEX (if the calculated slippage is within acceptable limits) or by anticipating the principal to the Lender and keeping the collateral. The result is placed in the LenderManager Spend script.
* If any utxo in the LenderManager Spend script contains some principal and points to the proper PoolManager, bots can compound the liquidity into the pool, taking an additional fee.
* For the loans that correctly point to a PoolManager, bots can liquidate, pay in advance and compound all in 1 transaction, taking both the liquidation and the compounding fees.
* The Lender always has the ability to manually withdraw assets that belong to him from the LenderManager Spend script.
* The Lender always has the ability to withdraw his bonds from the LenderManager Spend script.

### Bots logic
A bot runs to earn liquidation and compounding fees, trying to maximize its profits being the first to actually execute these Cardano transactions.
The general bot steps are:
1. Scan all the existing lender_manager.ak utxos that contain a Lender bond nft
2. For each lender bond, look for the existing loan in loan.ak
3. If the loan exists, check that it allows liquidation and check its Loan-To-Value (LTV) health
4. If it is unhealthy, it can be liquidated
5. Check if the lender_manager utxo has shouldLiquidationConvertToPrincipal. If False, liquidate the loan and send the collateral (minus fees) to the lender_manager.ak. If True, continue with the next step
6. Check if the lender_manager utxo has poolId set. If is empty, just convert the collateral into principal (either paying in advance or through the DEX order) and set lender_manager.ak the result destination. If it's not empty, look for the existing pool_manager.ak utxo.
7. If it doesn't exist, liquidate as before. If it exists, look for the relative pool in pool.ak
8. If it doesn't exist, liquidate as before. If it exists, you have 2 options: either liquidate and convert as before or convert, pay in advance and compound to that pool.
9. For each lender bond, if lender_manager utxo has poolId set and the relative pool in pool.ak exists, scan all the remaining lender_manager.ak utxos and look for utxos with datum AssetManagerDatumWithToken where the ownerAsset is the lender bond and where it contains the pool's principal asset. Compound them to the pool.

## Scripts
The most important scripts contained are the following:
* config.ak: global configuration of the whole protocol, upgradable
* general_spend.ak: a general spend validator that delegates to a specific withdraw validator (we always use the Withdraw 0 trick)
* oracle.ak: uses the withdraw validator to allow a set of signers to confirm the oracle value
* authorizer.ak: manage authorization of different ways (signature, withdraw, mint, etc.) 
* pool.ak: lender pools
* request.ak: borrower requests
* loan.ak: active loan (in progress)
* repayment.ak: all types of repayments (installments, partial liquidations, recasts, etc.)
* dutch_auction.ak: dutch auction where the price gradually decreases until someone buys it
* pool_managaer.ak: allows compounding managing Pools for the Lenders
* lender_manager.ak: allows automatic liquidation and compounding
