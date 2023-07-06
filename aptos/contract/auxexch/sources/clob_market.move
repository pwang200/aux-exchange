module aux::clob_market {
    use std::signer;

    use aptos_framework::coin;
    use aptos_framework::timestamp;

    use aux::critbit::{Self, CritbitTree};
    use aux::critbit_v::{Self, CritbitTree as CritbitTreeV};
    use aux::fee;
    use aux::onchain_signer;
    use aux::util::{Self, exp};
    use aux::vault;

    const MAX_U64: u64 = 18446744073709551615;
    const CRITBIT_NULL_INDEX: u64 = 1 << 63;
    const ZERO_FEES: bool = true;

    //////////////////////////////////////////////////////////////////
    // Place an order in the order book. The portion of the order that matches
    // against passive orders on the opposite side of the book becomes
    // aggressive. The remainder is passive.
    const LIMIT_ORDER: u64 = 100;
    // Cancel passive side
    const CANCEL: u64 = 200;

    //////////////////////////////////////////////////////////////////

    const E_ONLY_MODULE_PUBLISHER_CAN_CREATE_MARKET: u64 = 1;
    const E_MARKET_ALREADY_EXISTS: u64 = 2;
    const E_MISSING_AUX_USER_ACCOUNT: u64 = 3;
    const E_MARKET_DOES_NOT_EXIST: u64 = 4;
    const E_INSUFFICIENT_BALANCE: u64 = 5;
    const E_INSUFFICIENT_AUX_BALANCE: u64 = 6;
    const E_INVALID_STATE: u64 = 7;
    const E_TEST_FAILURE: u64 = 8;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 9;
    const E_UNABLE_TO_FILL_MARKET_ORDER: u64 = 10;
    const E_UNREACHABLE: u64 = 11;
    const E_INVALID_ROUTER_ORDER_TYPE: u64 = 12;
    const E_USER_FEE_NOT_INITIALIZED: u64 = 13;
    const E_UNSUPPORTED: u64 = 14;
    const E_VOLUME_TRACKER_UNREGISTERED: u64 = 15;
    const E_FEE_UNINITIALIZED: u64 = 16;
    const E_ORDER_NOT_FOUND: u64 = 17;
    const E_UNIMPLEMENTED_ERROR: u64 = 18;
    const E_FAILED_INVARIANT: u64 = 19;
    const E_INVALID_ARGUMENT: u64 = 20;
    const E_INVALID_ORDER_ID: u64 = 21;
    const E_INVALID_QUANTITY: u64 = 22;
    const E_INVALID_PRICE: u64 = 23;
    const E_NOT_ORDER_OWNER: u64 = 24;
    const E_INVALID_QUOTE_QUANTITY: u64 = 25;
    const E_INVALID_TICK_OR_LOT_SIZE: u64 = 26;
    const E_NO_ASKS_IN_BOOK: u64 = 27;
    const E_NO_BIDS_IN_BOOK: u64 = 28;
    const E_SLIDE_TO_ZERO_PRICE: u64 = 29;
    const E_UNSUPPORTED_STP_ACTION_TYPE: u64 = 30;
    const E_CANCEL_WRONG_ORDER: u64 = 31;
    const E_LEVEL_SHOULD_NOT_EMPTY: u64 = 32;
    const E_LEVEL_NOT_EMPTY: u64 = 33;
    const E_ORDER_NOT_IN_OPEN_ORDER_ACCOUNT: u64 = 34;
    const E_NO_OPEN_ORDERS_ACCOUNT: u64 = 35;
    const E_UNAUTHORIZED_FOR_MARKET_UPDATE: u64 = 36;
    const E_UNAUTHORIZED_FOR_MARKET_CREATION: u64 = 37;
    const E_MARKET_NOT_UPDATING: u64 = 38;
    const E_ORDER_EXPIRED_ON_ARRIVAL: u64 = 39;

    struct Order has store {
        id: u128,
        client_order_id: u128,
        price: u64,
        quantity: u64,
        is_bid: bool,
        owner_id: address,
        timeout_timestamp: u64,
    }

    fun destroy_order(order: Order) {
        let Order {
            id: _,
            client_order_id: _,
            price: _,
            quantity: _,
            is_bid: _,
            owner_id: _,
            timeout_timestamp: _,
        } = order;
    }

    fun create_order(
        id: u128,
        client_order_id: u128,
        price: u64,
        quantity: u64,
        is_bid: bool,
        owner_id: address,
        timeout_timestamp: u64
    ): Order {
        Order {
            id,
            client_order_id,
            price,
            quantity,
            is_bid,
            owner_id,
            timeout_timestamp,
        }
    }

    struct Level has store {
        // price
        price: u64,
        // total quantity
        total_quantity: u128,
        orders: CritbitTreeV<Order>,
    }

    fun destroy_empty_level(level: Level) {
        assert!(level.total_quantity == 0, E_LEVEL_NOT_EMPTY);
        let Level {
            price: _,
            total_quantity: _,
            orders
        } = level;

        critbit_v::destroy_empty(orders);
    }

    struct Market<phantom B, phantom Q> has key {
        // Orderbook
        bids: CritbitTree<Level>,
        asks: CritbitTree<Level>,
        next_order_id: u64,

        // MarketInfo
        base_decimals: u8,
        quote_decimals: u8,
        lot_size: u64,
        tick_size: u64,
    }

    struct OpenOrderInfo has store, drop {
        price: u64,
        is_bid: bool,
    }

    struct OpenOrderAccount<phantom B, phantom Q> has key {
        open_orders: CritbitTree<OpenOrderInfo>,
    }

    /*******************/
    /* ENTRY FUNCTIONS */
    /*******************/

    /// Create market, and move it to authority's resource account
    public entry fun create_market<B, Q>(
        sender: &signer,
        lot_size: u64,
        tick_size: u64
    ) {
        let base_decimals = coin::decimals<B>();
        let quote_decimals = coin::decimals<Q>();
        let base_exp = exp(10, (base_decimals as u128));
        // This invariant ensures that the smallest possible trade value is representable with quote asset decimals
        assert!((lot_size as u128) * (tick_size as u128) / base_exp > 0, E_INVALID_TICK_OR_LOT_SIZE);
        // This invariant ensures that the smallest possible trade value has no rounding issue with quote asset decimals
        assert!((lot_size as u128) * (tick_size as u128) % base_exp == 0, E_INVALID_TICK_OR_LOT_SIZE);
        assert!(!market_exists<B, Q>(), E_MARKET_ALREADY_EXISTS);

        move_to(sender, Market<B, Q> {
            base_decimals,
            quote_decimals,
            lot_size,
            tick_size,
            bids: critbit::new(),
            asks: critbit::new(),
            next_order_id: 0,
        });
    }

    /// Returns value of order in quote AU
    fun quote_qty<B>(price: u64, quantity: u64): u64 {
        // TODO: pass in decimals for gas saving
        ((price as u128) * (quantity as u128) / exp(10, (coin::decimals<B>() as u128)) as u64)
    }

    /// Place a limit order. Returns order ID of new order. Emits events on order placement and fills.
    public entry fun place_order<B, Q>(
        sender: &signer,
        is_bid: bool,
        limit_price: u64,
        quantity: u64,
        client_order_id: u128,
        order_type: u64,
        timeout_timestamp: u64,
    ) acquires Market, OpenOrderAccount {
        assert!(market_exists<B, Q>(), E_MARKET_DOES_NOT_EXIST);
        let sender_addr = signer::address_of(sender);
        let resource_addr = @aux;
        let market = borrow_global_mut<Market<B, Q>>(resource_addr);

        let (base_au, quote_au) = new_order(
            market,
            sender_addr,
            is_bid,
            limit_price,
            quantity,
            client_order_id,
            timeout_timestamp,
            order_type,
        );
        if (base_au != 0 && quote_au != 0) {
            // Debit/credit the sender's vault account
            if (is_bid) {
                // taker pays quote, receives base
                vault::decrease_user_balance<Q>(sender_addr, (quote_au as u128));
                vault::increase_user_balance<B>(sender_addr, (base_au as u128));
            } else {
                // taker receives quote, pays base
                vault::increase_user_balance<Q>(sender_addr, (quote_au as u128));
                vault::decrease_user_balance<B>(sender_addr, (base_au as u128));
            }
        } else if (base_au != 0 || quote_au != 0) {
            // abort if sender paid but did not receive and vice versa
            abort (E_INVALID_STATE)
        }
    }

    /// Returns (total_base_quantity_owed_au, quote_quantity_owed_au),
    /// the amounts that must be credited/debited to the sender.
    /// Emits OrderFill events
    fun handle_fill<B, Q>(
        taker_order: &Order,
        maker_order: &Order,
        base_qty: u64,
    ): (u64, u64) acquires OpenOrderAccount {
        let taker = taker_order.owner_id;
        let maker = maker_order.owner_id;
        let price = maker_order.price;
        let quote_qty = quote_qty<B>(price, base_qty);
        let taker_is_bid = taker_order.is_bid;
        let (taker_fee, maker_rebate) = if (ZERO_FEES) {
            (0, 0)
        } else {
            (fee::taker_fee(taker, quote_qty), fee::maker_rebate(maker, quote_qty))
        };
        let total_base_quantity_owed_au = 0;
        let total_quote_quantity_owed_au = 0;
        if (taker_is_bid) {
            // taker pays quote + fee, receives base
            total_base_quantity_owed_au = total_base_quantity_owed_au + base_qty;
            total_quote_quantity_owed_au = total_quote_quantity_owed_au + quote_qty + taker_fee;

            // maker receives quote - fee, pays base
            vault::increase_user_balance<Q>(maker, (quote_qty + maker_rebate as u128));
            vault::decrease_unavailable_balance<B>(maker, (base_qty as u128));
        } else {
            // maker pays quote + fee, receives base
            vault::increase_available_balance<Q>(maker, (quote_qty as u128));
            vault::decrease_user_balance<Q>(maker, (quote_qty - maker_rebate as u128));
            vault::increase_user_balance<B>(maker, (base_qty as u128));

            // taker receives quote - fee, pays base
            total_base_quantity_owed_au = total_base_quantity_owed_au + base_qty;
            total_quote_quantity_owed_au = total_quote_quantity_owed_au + quote_qty - taker_fee;
        };

        // The net proceeds go to the protocol. This implicitly asserts that
        // taker fees can cover the maker rebate.
        if (!ZERO_FEES) {
            vault::increase_user_balance<Q>(@aux, (taker_fee - maker_rebate as u128));
        };

        let maker_remaining_qty = util::sub_min_0(maker_order.quantity, (base_qty as u64));
        if (maker_remaining_qty == 0) {
            let open_order_address = onchain_signer::get_signer_address(maker);
            assert!(exists<OpenOrderAccount<B, Q>>(open_order_address), E_NO_OPEN_ORDERS_ACCOUNT);
            let open_order_account = borrow_global_mut<OpenOrderAccount<B, Q>>(
                open_order_address,
            );

            let order_idx = critbit::find(&open_order_account.open_orders, maker_order.id);
            assert!(order_idx != CRITBIT_NULL_INDEX, E_ORDER_NOT_IN_OPEN_ORDER_ACCOUNT);
            critbit::remove(&mut open_order_account.open_orders, order_idx);
        };

        (total_base_quantity_owed_au, total_quote_quantity_owed_au)
    }

    fun handle_placed_order<B, Q>(order: &Order, vault_account_owner: address) acquires OpenOrderAccount {
        let placed_order_owner = order.owner_id;
        assert!(placed_order_owner == vault_account_owner, E_INVALID_STATE);

        let qty = order.quantity;
        let price = order.price;
        let placed_quote_qty = quote_qty<B>(price, qty);

        if (order.is_bid) {
            vault::decrease_available_balance<Q>(vault_account_owner, (placed_quote_qty as u128));
        } else {
            vault::decrease_available_balance<B>(vault_account_owner, (qty as u128));
        };

        let open_order_address = onchain_signer::get_signer_address(placed_order_owner);
        if (!exists<OpenOrderAccount<B, Q>>(open_order_address)) {
            move_to(
                &onchain_signer::get_signer(placed_order_owner),
                OpenOrderAccount<B, Q> {
                    open_orders: critbit::new(),
                }
            )
        };

        let open_order_account = borrow_global_mut<OpenOrderAccount<B, Q>>(open_order_address);
        critbit::insert(&mut open_order_account.open_orders, order.id, OpenOrderInfo {
            is_bid: order.is_bid,
            price: order.price,
        });
    }

    /// Attempts to place a new order and returns resulting events
    /// ticks_to_slide is only used for post only order and passively join order
    /// direction_aggressive is only used for passively join order
    /// Returns (base_quantity_filled, quote_quantity_filled)
    fun new_order<B, Q>(
        market: &mut Market<B, Q>,
        order_owner: address,
        is_bid: bool,
        limit_price: u64,
        quantity: u64,
        client_order_id: u128,
        timeout_timestamp: u64,
        order_type: u64,
    ): (u64, u64) acquires OpenOrderAccount {
        // Confirm the order_owner has fee published
        if (!ZERO_FEES) {
            assert!(fee::fee_exists(order_owner), E_FEE_UNINITIALIZED);
        };
        // Check lot sizes
        let tick_size = market.tick_size;
        let lot_size = market.lot_size;

        assert!(quantity % lot_size == 0, E_INVALID_QUANTITY);
        assert!(limit_price % tick_size == 0, E_INVALID_PRICE);
        let timestamp = timestamp::now_microseconds();
        assert!(timestamp < timeout_timestamp, E_ORDER_EXPIRED_ON_ARRIVAL);

        let order_id = generate_order_id(market);
        let order = Order {
            id: order_id,
            client_order_id,
            price: limit_price,
            quantity,
            is_bid,
            owner_id: order_owner,
            timeout_timestamp,
        };

        // Check for matches
        let (base_qty_filled, quote_qty_filled) = match(market, &mut order, timestamp, order_type);
        // Check for remaining order quantity
        if (order.quantity > 0) {
            handle_placed_order<B, Q>(&order, order_owner);
            insert_order(market, order);
        } else {
            destroy_order(order);
        };
        (base_qty_filled, quote_qty_filled)
    }

    public entry fun cancel_order<B, Q>(sender: &signer, order_id: u128) acquires Market, OpenOrderAccount {
        assert!(market_exists<B, Q>(), E_MARKET_DOES_NOT_EXIST);
        let delegator = signer::address_of(sender);
        let resource_addr = @aux;

        let market = borrow_global_mut<Market<B, Q>>(resource_addr);
        let open_order_address = onchain_signer::get_signer_address(delegator);
        assert!(exists<OpenOrderAccount<B, Q>>(open_order_address), E_NO_OPEN_ORDERS_ACCOUNT);

        let open_order_account = borrow_global<OpenOrderAccount<B, Q>>(open_order_address);
        let order_idx = critbit::find(&open_order_account.open_orders, order_id);
        assert!(order_idx != CRITBIT_NULL_INDEX, E_ORDER_NOT_FOUND);
        let (_, OpenOrderInfo { price, is_bid }) = critbit::borrow_at_index(&open_order_account.open_orders, order_idx);
        let cancelled = inner_cancel_order(market, order_id, delegator, *price, *is_bid);

        process_cancel_order<B, Q>(cancelled);
    }

    public fun market_exists<B, Q>(): bool {
        exists<Market<B, Q>>(@aux)
    }

    fun inner_cancel_order<B, Q>(
        market: &mut Market<B, Q>,
        order_id: u128,
        sender_addr: address,
        price: u64,
        is_bid: bool
    ): Order {
        let side = if (is_bid) { &mut market.bids } else { &mut market.asks };
        let level_idx = critbit::find(side, (price as u128));
        assert!(level_idx != CRITBIT_NULL_INDEX, E_CANCEL_WRONG_ORDER);

        let (_, level) = critbit::borrow_at_index_mut(side, level_idx);
        let order_idx = critbit_v::find(&level.orders, order_id);
        assert!(order_idx != CRITBIT_NULL_INDEX, E_CANCEL_WRONG_ORDER);

        let (_, order) = critbit_v::remove(&mut level.orders, order_idx);
        assert!(order.owner_id == sender_addr, E_NOT_ORDER_OWNER);

        level.total_quantity = level.total_quantity - (order.quantity as u128);
        if (level.total_quantity == 0) {
            let (_, level) = critbit::remove(side, level_idx);
            destroy_empty_level(level);
        };

        return order
    }

    fun process_cancel_order<B, Q>(cancelled: Order) acquires OpenOrderAccount {
        let open_order_account = borrow_global_mut<OpenOrderAccount<B, Q>>(
            onchain_signer::get_signer_address(cancelled.owner_id)
        );

        let order_idx = critbit::find(&open_order_account.open_orders, cancelled.id);
        assert!(order_idx != CRITBIT_NULL_INDEX, E_ORDER_NOT_IN_OPEN_ORDER_ACCOUNT);

        critbit::remove(&mut open_order_account.open_orders, order_idx);

        let cancel_qty = cancelled.quantity;
        // Release hold on user funds
        if (cancelled.is_bid) {
            vault::increase_available_balance<Q>(
                cancelled.owner_id,
                (quote_qty<B>(cancelled.price, cancel_qty) as u128),
            );
        } else {
            vault::increase_available_balance<B>(
                cancelled.owner_id,
                (cancelled.quantity as u128),
            );
        };

        destroy_order(cancelled);
    }

    fun generate_order_id<B, Q>(market: &mut Market<B, Q>): u128 {
        let order_id = (market.next_order_id as u128);
        market.next_order_id = market.next_order_id + 1;
        order_id
    }

    fun match<B, Q>(
        market: &mut Market<B, Q>,
        taker_order: &mut Order,
        current_timestamp: u64,
        order_type: u64
    ): (u64, u64) acquires OpenOrderAccount {
        let side = if (taker_order.is_bid) { &mut market.asks } else { &mut market.bids };
        let order_price = taker_order.price;
        let total_base_quantity_owed_au = 0;
        let total_quote_quantity_owed_au = 0;

        while (!critbit::empty(side) && taker_order.quantity > 0) {
            let min_level_index = if (taker_order.is_bid) {
                critbit::get_min_index(side)
            } else {
                critbit::get_max_index(side)
            };
            let (_, level) = critbit::borrow_at_index_mut(side, min_level_index);
            let level_price = level.price;

            if (
                (taker_order.is_bid && level_price <= order_price) || // match is an ask <= bid
                    (!taker_order.is_bid && level_price >= order_price)     // match is a bid >= ask
            ) {
                // match within level
                while (level.total_quantity > 0 && taker_order.quantity > 0) {
                    let min_order_idx = critbit_v::get_min_index(&level.orders);
                    let (_, maker_order) = critbit_v::borrow_at_index(&level.orders, min_order_idx);
                    // cancel the maker orde if it's already timed out.
                    if (maker_order.timeout_timestamp <= current_timestamp) {
                        let (_, min_order) = critbit_v::remove(&mut level.orders, min_order_idx);
                        level.total_quantity = level.total_quantity - (min_order.quantity as u128);
                        process_cancel_order<B, Q>(min_order);
                        continue
                    };

                    // Check whether self-trade occurs
                    if (taker_order.owner_id == maker_order.owner_id) {
                        // Follow the specification to cancel
                        if (order_type == CANCEL) {
                            let (_, cancelled) = critbit_v::remove(&mut level.orders, min_order_idx);
                            level.total_quantity = level.total_quantity - (cancelled.quantity as u128);
                            process_cancel_order<B, Q>(cancelled);
                            taker_order.quantity = 0;
                            // break //TODO really remove?
                        }else {
                            abort (E_UNSUPPORTED_STP_ACTION_TYPE)
                        };
                        // If maker order is cancelled, we want to continue matching
                        continue
                    };
                    let current_maker_quantity = maker_order.quantity;
                    if (current_maker_quantity <= taker_order.quantity) {
                        // emit fill event
                        let (base, quote) = handle_fill<B, Q>(
                            taker_order, maker_order, current_maker_quantity);
                        total_base_quantity_owed_au = total_base_quantity_owed_au + base;
                        total_quote_quantity_owed_au = total_quote_quantity_owed_au + quote;
                        // update taker quantity
                        taker_order.quantity = taker_order.quantity - current_maker_quantity;
                        // delete maker order (order was fully filled)
                        let (_, filled) = critbit_v::remove(&mut level.orders, min_order_idx);
                        level.total_quantity = level.total_quantity - (filled.quantity as u128);
                        destroy_order(filled);
                    } else {
                        // emit fill event
                        let quantity = taker_order.quantity;
                        let (base, quote) = handle_fill<B, Q>(
                            taker_order, maker_order, quantity);
                        total_base_quantity_owed_au = total_base_quantity_owed_au + base;
                        total_quote_quantity_owed_au = total_quote_quantity_owed_au + quote;

                        let (_, maker_order) = critbit_v::borrow_at_index_mut(&mut level.orders, min_order_idx);
                        maker_order.quantity = maker_order.quantity - taker_order.quantity;
                        level.total_quantity = level.total_quantity - (taker_order.quantity as u128);
                        taker_order.quantity = 0;
                    };
                };
                if (level.total_quantity == 0) {
                    let (_, level) = critbit::remove(side, min_level_index);
                    destroy_empty_level(level);
                };
            } else {
                // if the order doesn't cross, stop looking for a match
                break
            };
        };
        (total_base_quantity_owed_au, total_quote_quantity_owed_au)
    }

    fun insert_order<B, Q>(market: &mut Market<B, Q>, order: Order) {
        let side = if (order.is_bid) { &mut market.bids } else { &mut market.asks };
        let price = (order.price as u128);
        let level_idx = critbit::find(side, price);
        if (level_idx == CRITBIT_NULL_INDEX) {
            let level = Level {
                orders: critbit_v::new(),
                total_quantity: (order.quantity as u128),
                price: order.price,
            };
            critbit_v::insert(&mut level.orders, order.id, order);
            critbit::insert(side, price, level);
        } else {
            let (_, level) = critbit::borrow_at_index_mut(side, level_idx);
            level.total_quantity = level.total_quantity + (order.quantity as u128);
            critbit_v::insert(&mut level.orders, order.id, order);
        }
    }
}
