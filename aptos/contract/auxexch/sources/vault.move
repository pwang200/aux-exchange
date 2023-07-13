// vault defines
// - a vault, or a resource account, that holds many coins that users deposit. One of the coins is funding coin,
//   which every other coin is priced in.
// - user balances in each of the coins (or the shares of the coins that the user entitled to in the treasury).
module aux::vault {
    use std::error;
    use std::signer;

    use aptos_framework::coin;

    use aux::onchain_signer;
    use aux::util::Type;

    friend aux::clob_market;

    const EVAULT_ALREADY_EXISTS: u64 = 1;
    const EACCOUNT_ALREADY_EXISTS: u64 = 2;
    const EACCOUNT_NOT_FOUND: u64 = 3;
    const ENOT_MODULE: u64 = 4;
    const EUNINITIALIZED_COIN: u64 = 5;
    const EUNINITIALIZED_VAULT: u64 = 6;
    const EBALANCE_INVARIANT_VIOLATION: u64 = 7;
    const ECANNOT_DOUBLE_REGISTER_SAME_COIN: u64 = 9;
    const EINSUFFICIENT_FUNDS: u64 = 10;
    const ETRADER_NOT_AUTHORIZED: u64 = 11;

    // CoinInfo provides information about a coin that can be borrowed.
    struct CoinInfo has store {
        coin_type: Type,
        decimals: u8,
        mark_price: u64,
    }

    // Balance for one coin
    struct CoinBalance<phantom CoinType> has key {
        balance: u128,
        available_balance: u128
    }

    // Used for set definition.
    struct Nothing has store, copy, drop {}

    struct Vault has key {}

    /*******************/
    /* ENTRY FUNCTIONS */
    /*******************/

    public entry fun create_vault(sender: &signer) {
        assert!(signer::address_of(sender) == @aux, error::permission_denied(ENOT_MODULE));
        onchain_signer::create_onchain_signer(sender);
        if (!exists<Vault>(@aux)) {
            move_to(sender, Vault {});
        }
    }

    /// Transfer the coins between two different accounts of the ledger.
    public entry fun transfer<CoinType>(
        from: &signer,
        to: address,
        amount_au: u64
    ) acquires CoinBalance {
        let from_addr = signer::address_of(from);
        decrease_user_balance<CoinType>(from_addr, (amount_au as u128));
        increase_user_balance<CoinType>(to, (amount_au as u128));
    }

    /// Deposit funds. Returns user's new balance. Can only deposit to sender's
    /// own AuxUserAccount or an AuxUserAccount that sender's address is
    /// whitelisted.
    public entry fun deposit<CoinType>(
        sender: &signer,
        amount: u64
    ) acquires CoinBalance {
        coin::transfer<CoinType>(sender, @aux, amount);
        increase_user_balance<CoinType>(signer::address_of(sender), (amount as u128));
    }

    /// Withdraw funds. Returns user's new balance.
    public entry fun withdraw<CoinType>(
        sender: &signer,
        amount_au: u64
    ) acquires CoinBalance {
        let owner_addr = signer::address_of(sender);
        //assert!(exists<AuxUserAccount>(owner_addr), error::not_found(EACCOUNT_NOT_FOUND));
        decrease_user_balance<CoinType>(owner_addr, (amount_au as u128));
        let vault_signer = onchain_signer::get_signer(@aux);
        coin::transfer<CoinType>(&vault_signer, owner_addr, amount_au);
    }

    /// Return's the user balance in CoinType. Returns zero if no amount of
    /// CoinType has ever been transferred to the user.
    public fun balance<CoinType>(user_addr: address): u128 acquires CoinBalance {
        let balance_address = onchain_signer::get_signer_address(user_addr);
        if (exists<CoinBalance<CoinType>>(balance_address)) {
            let balance = borrow_global<CoinBalance<CoinType>>(balance_address);
            balance.balance
        } else {
            0
        }
    }

    /// Return's the user available balance in CoinType. Returns zero if no
    /// amount of CoinType has ever been transferred to the user.
    public fun available_balance<CoinType>(user_addr: address): u128 acquires CoinBalance {
        let balance_address = onchain_signer::get_signer_address(user_addr);
        if (exists<CoinBalance<CoinType>>(balance_address)) {
            let balance = borrow_global<CoinBalance<CoinType>>(balance_address);
            balance.available_balance
        } else {
            0
        }
    }

    public fun withdraw_coin<CoinType>(
        sender: &signer,
        amount_au: u64
    ): coin::Coin<CoinType> acquires CoinBalance {
        let owner_addr = signer::address_of(sender);
        //assert!(exists<AuxUserAccount>(owner_addr), error::not_found(EACCOUNT_NOT_FOUND));
        decrease_user_balance<CoinType>(owner_addr, (amount_au as u128));
        let vault_signer = onchain_signer::get_signer(@aux);
        let coin = coin::withdraw<CoinType>(&vault_signer, amount_au);
        coin
    }

    public fun deposit_coin<CoinType>(
        to: address,
        coin: coin::Coin<CoinType>,
    ) acquires CoinBalance {
        //assert!(exists<AuxUserAccount>(to), error::not_found(EACCOUNT_NOT_FOUND));
        if (!coin::is_account_registered<CoinType>(@aux)) {
            let vault_signer = onchain_signer::get_signer(@aux);
            coin::register<CoinType>(&vault_signer);
        };
        let amount = coin::value<CoinType>(&coin);
        coin::deposit<CoinType>(@aux, coin);
        increase_user_balance<CoinType>(to, (amount as u128));
    }


    /********************/
    /* FRIEND FUNCTIONS */
    /********************/

    /// add position
    public(friend) fun increase_user_balance<CoinType>(
        user_addr: address,
        amount: u128
    ): u128 acquires CoinBalance {
        let balance_address = onchain_signer::get_signer_address(user_addr);
        if (exists<CoinBalance<CoinType>>(balance_address)) {
            let coin_balance = borrow_global_mut<CoinBalance<CoinType>>(balance_address);
            coin_balance.balance = coin_balance.balance + amount;
            coin_balance.available_balance = coin_balance.available_balance + amount;
            coin_balance.balance
        } else {
            let signer_address = onchain_signer::get_signer(user_addr);
            move_to(
                &signer_address,
                CoinBalance<CoinType> {
                    balance: amount,
                    available_balance: amount,
                }
            );
            amount
        }
    }

    /// decrease balance
    public(friend) fun decrease_user_balance<CoinType>(user_addr: address, amount: u128): u128 acquires CoinBalance {
        let balance_address = onchain_signer::get_signer_address(user_addr);
        let coin_balance = borrow_global_mut<CoinBalance<CoinType>>(balance_address);
        assert!(
            coin_balance.balance >= amount,
            EINSUFFICIENT_FUNDS
        );
        coin_balance.balance = coin_balance.balance - amount;
        assert!(
            coin_balance.available_balance >= amount,
            EINSUFFICIENT_FUNDS
        );
        coin_balance.available_balance = coin_balance.available_balance - amount;
        coin_balance.balance
    }

    /// decrease balance that was previously marked unavailable
    public(friend) fun decrease_unavailable_balance<CoinType>(
        user_addr: address,
        amount: u128
    ): u128 acquires CoinBalance {
        let balance_address = onchain_signer::get_signer_address(user_addr);
        let coin_balance = borrow_global_mut<CoinBalance<CoinType>>(balance_address);
        assert!(
            coin_balance.balance >= amount,
            EINSUFFICIENT_FUNDS
        );
        coin_balance.balance = coin_balance.balance - amount;
        assert!(
            coin_balance.available_balance <= coin_balance.balance,
            error::invalid_state(EBALANCE_INVARIANT_VIOLATION)
        );
        coin_balance.balance
    }

    /// Note for vault-delegation PR: since decrease_user_balance and
    /// already passed in user_addr, change this signer to user_addr doesn't
    /// decrease security, depend on the caller / wrapper that do all the proper check
    public(friend) fun decrease_available_balance<CoinType>(
        user_addr: address,
        amount: u128
    ): u128 acquires CoinBalance {
        // TODO: Account health check must be done before available balance can be decreased
        let balance_address = onchain_signer::get_signer_address(user_addr);
        let coin_balance = borrow_global_mut<CoinBalance<CoinType>>(balance_address);
        assert!(
            coin_balance.available_balance >= amount,
            EINSUFFICIENT_FUNDS
        );
        coin_balance.available_balance = coin_balance.available_balance - amount;
        coin_balance.available_balance
    }

    public(friend) fun increase_available_balance<CoinType>(
        user_addr: address,
        amount: u128
    ): u128 acquires CoinBalance {
        let balance_address = onchain_signer::get_signer_address(user_addr);
        let coin_balance = borrow_global_mut<CoinBalance<CoinType>>(balance_address);

        coin_balance.available_balance = coin_balance.available_balance + amount;
        // Available balance can be at most == total balance
        if (coin_balance.available_balance > coin_balance.balance) {
            coin_balance.available_balance = coin_balance.balance;
        };
        coin_balance.available_balance
    }
}
