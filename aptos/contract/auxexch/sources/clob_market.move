module aux::clob_market {
    use std::signer;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::type_info;
    use aptos_framework::coin;
    use aptos_framework::timestamp;

    use aux::vault::{Self, has_aux_account};
    use aux::aux_coin::AuxCoin;
    use aux::authority;
    use aux::volume_tracker;
    use aux::fee;
    use aux::critbit::{Self, CritbitTree};
    use aux::critbit_v::{Self, CritbitTree as CritbitTreeV};
    use aux::util::{Self, exp};
    use aux::onchain_signer;

    // Config
    const CANCEL_EXPIRATION_TIME: u64 = 100000000; // 100 s
    const MAX_U64: u64 = 18446744073709551615;
    const CRITBIT_NULL_INDEX: u64 = 1 << 63;
    const ZERO_FEES: bool = true;

    //////////////////////////////////////////////////////////////////
    // Order type

    // Place an order in the order book. The portion of the order that matches
    // against passive orders on the opposite side of the book becomes
    // aggressive. The remainder is passive.
    const LIMIT_ORDER: u64 = 100;

    // Place an aggressive order. If the entire order cannot fill immediately,
    // cancel the entire order.
    const FILL_OR_KILL: u64 = 101;

    // Place an aggressive order. The portion of the order that does not fill
    // immediately is cancelled.
    const IMMEDIATE_OR_CANCEL: u64 = 102;

    // Place a passive order. If the order would be aggressive, optionally slide
    // it to become passive. Otherwise, cancel the order.
    const POST_ONLY: u64 = 103;

    // Join the best bid or best ask level. Optionally place the order more or
    // less aggressive than the best bid or ask up to the limit price.
    const PASSIVE_JOIN: u64 = 104;

    // Self-trading prevention (STP) action type
    // This order agrees on the specification that when a self-trading occur, cancel the passive one (the maker order)

    // Cancel passive side
    const CANCEL_PASSIVE: u64 = 200;
    // Cancel aggressive side
    const CANCEL_AGGRESSIVE: u64 = 201;
    // Cancel both sides
    const CANCEL_BOTH: u64 = 202;

    // Order Event Types
    const ORDER_FILL_EVENT: u64 = 1;
    const ORDER_CANCEL_EVENT: u64 = 2;
    const ORDER_PLACED_EVENT: u64 = 3;

    // end !!! CONSTANTS !!! Keep in sync clob.move, clob_market.move, router.move
    //////////////////////////////////////////////////////////////////


    /**********/
    /* ERRORS */
    /**********/
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
    const E_UNSUPPORTED_STP_ACTION_TYPE : u64 = 30;
    const E_CANCEL_WRONG_ORDER: u64 = 31;
    const E_LEVEL_SHOULD_NOT_EMPTY: u64 = 32;
    const E_LEVEL_NOT_EMPTY: u64 = 33;
    const E_ORDER_NOT_IN_OPEN_ORDER_ACCOUNT: u64 = 34;
    const E_NO_OPEN_ORDERS_ACCOUNT: u64 = 35;
    const E_UNAUTHORIZED_FOR_MARKET_UPDATE: u64 = 36;
    const E_UNAUTHORIZED_FOR_MARKET_CREATION: u64 = 37;
    const E_MARKET_NOT_UPDATING: u64 = 38;

    /*********/
    /* ORDER */
    /*********/

    struct Order has store {
        id: u128,
        client_order_id: u128,
        price: u64,
        quantity: u64,
        aux_au_to_burn_per_lot: u64,
        is_bid: bool,
        owner_id: address,
        timeout_timestamp: u64,
        order_type: u64,
        timestamp: u64,
    }

    fun destroy_order(order: Order) {
        let Order {
            id: _,
            client_order_id: _,
            price: _,
            quantity: _,
            aux_au_to_burn_per_lot: _,
            is_bid: _,
            owner_id: _,
            timeout_timestamp: _,
            order_type: _,
            timestamp: _,
        } = order;
    }

    fun create_order(
        id: u128,
        client_order_id: u128,
        price: u64,
        quantity: u64,
        aux_au_to_burn_per_lot: u64,
        is_bid: bool,
        owner_id: address,
        timeout_timestamp: u64,
        order_type: u64,
        timestamp: u64,
    ): Order {
        Order {
            id,
            client_order_id,
            price,
            quantity,
            aux_au_to_burn_per_lot,
            is_bid,
            owner_id,
            timeout_timestamp,
            order_type,
            timestamp,
        }
    }

    /*********/
    /* LEVEL */
    /*********/

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

    /**********/
    /* MARKET */
    /**********/

    struct Market<phantom B, phantom Q> has key {
        // Orderbook
        bids:  CritbitTree<Level>,
        asks:  CritbitTree<Level>,
        next_order_id: u64,

        // MarketInfo
        base_decimals: u8,
        quote_decimals: u8,
        lot_size: u64,
        tick_size: u64,

        // Events
        fill_events: event::EventHandle<OrderFillEvent>,
        cancel_events: event::EventHandle<OrderCancelEvent>,
        placed_events: event::EventHandle<OrderPlacedEvent>
    }


    /**********/
    /* EVENTS */
    /**********/

    struct OrderFillEvent has store, drop {
        order_id: u128,
        client_order_id: u128,
        is_bid: bool,
        owner: address,
        base_qty: u64,  // base qty filled
        price: u64,
        fee: u64,
        rebate: u64,
        remaining_qty: u64,
        timestamp: u64, // timestamp of when the event happens
    }

    struct OrderCancelEvent has store, drop {
        order_id: u128,
        client_order_id: u128,
        owner: address,
        cancel_qty: u64,
        timestamp: u64, // timestamp of when the event happens
        order_type: u64, // immediate-or-cancel, fill-or-kill, maker-or-cancel
    }

    struct OrderPlacedEvent has store, drop {
        order_id: u128,
        client_order_id: u128,
        owner: address,
        is_bid: bool,
        qty: u64,
        price: u64,
        timestamp: u64, // timestamp of when the event happens
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

        // The signer must own one of the coins or be the aux authority.
        let base_type = type_info::type_of<B>();
        let quote_type = type_info::type_of<Q>();
        let sender_address = signer::address_of(sender);
        if (type_info::account_address(&base_type) != sender_address &&
            type_info::account_address(&quote_type) != sender_address) {
            // Asserts that sender has the authority for @aux.
            assert!(
                authority::is_signer_owner(sender),
                E_UNAUTHORIZED_FOR_MARKET_CREATION,
            );
        };

        let base_decimals = coin::decimals<B>();
        let quote_decimals = coin::decimals<Q>();
        let base_exp = exp(10, (base_decimals as u128));
        // This invariant ensures that the smallest possible trade value is representable with quote asset decimals
        assert!((lot_size as u128) * (tick_size as u128) / base_exp > 0, E_INVALID_TICK_OR_LOT_SIZE);
        // This invariant ensures that the smallest possible trade value has no rounding issue with quote asset decimals
        assert!((lot_size as u128) * (tick_size as u128) % base_exp == 0, E_INVALID_TICK_OR_LOT_SIZE);

        assert!(!market_exists<B, Q>(), E_MARKET_ALREADY_EXISTS);

        let clob_signer = authority::get_signer_self();
        // Register quote coin on volume tracker if it hasn't been already
        let resource_addr = @aux;
        if (!volume_tracker::global_volume_tracker_registered(resource_addr)) {
            volume_tracker::register_global_volume_tracker(&clob_signer);
        };
        if (!volume_tracker::is_coin_volume_tracked<Q>(resource_addr)) {
            volume_tracker::register_coin_for_volume_track<Q>(resource_addr);
        };

        move_to(&clob_signer, Market<B, Q> {
            base_decimals,
            quote_decimals,
            lot_size,
            tick_size,
            bids: critbit::new(),
            asks: critbit::new(),
            next_order_id: 0,
            fill_events: account::new_event_handle<OrderFillEvent>(&clob_signer),
            cancel_events: account::new_event_handle<OrderCancelEvent>(&clob_signer),
            placed_events: account::new_event_handle<OrderPlacedEvent>(&clob_signer)
        });
    }

    /// Returns value of order in quote AU
    fun quote_qty<B>(price: u64, quantity: u64): u64 {
        // TODO: pass in decimals for gas saving
        ((price as u128) * (quantity as u128) / exp(10, (coin::decimals<B>() as u128)) as u64)
    }

    /// Place a limit order. Returns order ID of new order. Emits events on order placement and fills.
    public entry fun place_order<B, Q>(
        sender: &signer, // sender is the user who initiates the trade (can also be the vault_account_owner itself) on behalf of vault_account_owner. Will only succeed if sender is the creator of the account, or on the access control list of the account published under vault_account_owner address
        vault_account_owner: address, // vault_account_owner is, from the module's internal perspective, the address that actually makes the trade. It will be the actual account that has changes in balance (fee, volume tracker, etc is all associated with vault_account_owner, and independent of sender (i.e. delegatee))
        is_bid: bool,
        limit_price: u64,
        quantity: u64,
        aux_au_to_burn_per_lot: u64,
        client_order_id: u128,
        order_type: u64,
        ticks_to_slide: u64, // # of ticks to slide for post only
        direction_aggressive: bool, // only used in passive join order
        timeout_timestamp: u64, // if by the timeout_timestamp the submitted order is not filled, then it would be cancelled automatically, if the timeout_timestamp <= current_timestamp, the order would not be placed and cancelled immediately
        stp_action_type: u64 // STP action type
    ) acquires Market, OpenOrderAccount {
        // TODO: move these checks into new_order
        // First confirm the sender is allowed to trade on behalf of vault_account_owner
        vault::assert_trader_is_authorized_for_account(sender, vault_account_owner);

        // Confirm that vault_account_owner has an aux account
        assert!(has_aux_account(vault_account_owner), E_MISSING_AUX_USER_ACCOUNT);

        // Confirm the vault_account_owner has volume tracker registered
        assert!(volume_tracker::global_volume_tracker_registered(vault_account_owner), E_VOLUME_TRACKER_UNREGISTERED);

        // Confirm that market exists
        let resource_addr = @aux;
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);
        let market = borrow_global_mut<Market<B, Q>>(resource_addr);

        let(base_au, quote_au) = new_order(
            market,
            vault_account_owner,
            is_bid,
            limit_price,
            quantity,
            aux_au_to_burn_per_lot,
            order_type,
            client_order_id,
            ticks_to_slide,
            direction_aggressive,
            timeout_timestamp,
            stp_action_type,
        );
        if (base_au != 0 && quote_au != 0) {
            assert!(order_type != POST_ONLY && order_type != PASSIVE_JOIN, E_INVALID_STATE);
            // Debit/credit the sender's vault account
            if (is_bid) {
                // taker pays quote, receives base
                vault::decrease_user_balance<Q>(vault_account_owner, (quote_au as u128));
                vault::increase_user_balance<B>(vault_account_owner, (base_au as u128));
            } else {
                // taker receives quote, pays base
                vault::increase_user_balance<Q>(vault_account_owner, (quote_au as u128));
                vault::decrease_user_balance<B>(vault_account_owner, (base_au as u128));
            }
        } else if (base_au != 0 || quote_au != 0) {
            // abort if sender paid but did not receive and vice versa
            abort(E_INVALID_STATE)
        }

    }

    /// Returns (total_base_quantity_owed_au, quote_quantity_owed_au), the amounts that must be credited/debited to the sender.
    /// Emits OrderFill events
    fun handle_fill<B, Q>(
        fill_events: &mut event::EventHandle<OrderFillEvent>,
        taker_order: &Order,
        maker_order: &Order,
        base_qty: u64,
        lot_size: u128
    ): (u64, u64) acquires OpenOrderAccount {
        let timestamp = timestamp::now_microseconds();
        let resource_addr = @aux;

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

        // Emit event for taker
        let taker_order_id = taker_order.id;
        event::emit_event<OrderFillEvent>(
            fill_events,
            OrderFillEvent{
                order_id: taker_order_id,
                owner: taker,
                base_qty,  // base qty filled
                price,
                fee: taker_fee,
                rebate: 0,
                remaining_qty: util::sub_min_0(taker_order.quantity, (base_qty as u64)),
                is_bid: taker_order.is_bid,
                timestamp,
                client_order_id: taker_order.client_order_id,
            }
        );
        let maker_remaining_qty = util::sub_min_0(maker_order.quantity, (base_qty as u64));
        if (maker_order.aux_au_to_burn_per_lot > 0) {
            let aux_to_burn = (maker_order.aux_au_to_burn_per_lot as u128) * (base_qty as u128) / lot_size;
            vault::increase_available_balance<AuxCoin>(maker, aux_to_burn);
            vault::decrease_user_balance<AuxCoin>(maker, aux_to_burn);
        };

        // Emit event for maker
        event::emit_event<OrderFillEvent>(
            fill_events,
            OrderFillEvent{
                order_id: maker_order.id,
                owner: maker,
                base_qty,  // base qty filled
                price,
                fee: 0,
                rebate: maker_rebate,
                remaining_qty: maker_remaining_qty,
                is_bid: !taker_is_bid,
                timestamp,
                client_order_id: maker_order.client_order_id,
            },
        );

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

        // record the volume filled / traded
        // update global volume for such base coin
        volume_tracker::update_volume_tracker<Q>(resource_addr, timestamp::now_seconds(), quote_qty);

        // update taker's volume, if they have a registered volume tracker
        // TODO: this is kind of clunky, but necessary since not everyone trading against clob has a vault account (e.g. coming from router)
        if (volume_tracker::global_volume_tracker_registered(taker)) {
            if (!volume_tracker::is_coin_volume_tracked<Q>(taker)){
                volume_tracker::register_coin_for_volume_track<Q>(taker);
            };
            volume_tracker::update_volume_tracker<Q>(taker, timestamp::now_seconds(), quote_qty);
        };

        // update maker's volume
        if (!volume_tracker::is_coin_volume_tracked<Q>(maker) && volume_tracker::global_volume_tracker_registered(maker)){
            volume_tracker::register_coin_for_volume_track<Q>(maker);
        };
        volume_tracker::update_volume_tracker<Q>(maker, timestamp::now_seconds(), quote_qty);
        (total_base_quantity_owed_au, total_quote_quantity_owed_au)
    }

    fun handle_placed_order<B, Q>(market: &mut Market<B, Q>, order: &Order, vault_account_owner: address) acquires OpenOrderAccount {
        let timestamp = timestamp::now_microseconds();
        let placed_order_id = order.id;
        let lot_size = (market.lot_size as u128);

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
        if (order.aux_au_to_burn_per_lot > 0) {
            vault::decrease_available_balance<AuxCoin>(vault_account_owner, (order.aux_au_to_burn_per_lot as u128) * (qty as u128) / lot_size);
        };
        event::emit_event<OrderPlacedEvent>(
            &mut market.placed_events,
            OrderPlacedEvent{
                order_id: placed_order_id,
                owner: placed_order_owner,
                price,
                qty,
                is_bid: order.is_bid,
                timestamp,
                client_order_id: order.client_order_id,
            }
        );

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
        aux_au_to_burn_per_lot: u64,
        order_type: u64,
        client_order_id: u128,
        ticks_to_slide: u64,
        direction_aggressive: bool,
        timeout_timestamp: u64,
        stp_action_type: u64,
    ): (u64, u64) acquires OpenOrderAccount {
        // Confirm the order_owner has fee published
        if (!ZERO_FEES) {
            assert!(fee::fee_exists(order_owner), E_FEE_UNINITIALIZED);
        };
        // Check lot sizes
        let tick_size = market.tick_size;
        let lot_size = market.lot_size;

        if (quantity % lot_size != 0) {
            abort(E_INVALID_QUANTITY)
        } else if (limit_price % tick_size != 0) {
            abort(E_INVALID_PRICE)
        };
        let timestamp = timestamp::now_microseconds();
        let order_id = generate_order_id(market, aux_au_to_burn_per_lot);

        let order = Order{
            id: order_id,
            client_order_id,
            price: limit_price,
            quantity,
            aux_au_to_burn_per_lot,
            is_bid,
            owner_id: order_owner,
            timeout_timestamp,
            order_type,
            timestamp,
        };

        if (order_type == FILL_OR_KILL) {
            let filled = 0u64;
            let side = if (is_bid) { &mut market.asks } else { &mut market.bids };
            if (critbit::size(side) == 0) {
                // Just emit the event
                event::emit_event<OrderCancelEvent>(
                    &mut market.cancel_events,
                    OrderCancelEvent {
                        order_id,
                        owner: order.owner_id,
                        cancel_qty: order.quantity,
                        timestamp,
                        client_order_id: client_order_id, // this is same given the invariant
                        order_type: order_type, // this is same given the invariant
                    }
                );
                destroy_order(order);
                return (0,0)
            };

            let idx = if (is_bid) { critbit::get_min_index(side) } else { critbit::get_max_index(side) };

            while(idx != CRITBIT_NULL_INDEX && filled < quantity) {
                let (_, level) = critbit::borrow_at_index(side, idx);
                let can_fill = (is_bid && level.price <= limit_price) || (!is_bid && level.price >= limit_price);
                if (can_fill) {
                    // now walk the book.
                    // since some orders have already expired, we need to check the orders one by one.
                    let order_idx = critbit_v::get_min_index(&level.orders);
                    while (order_idx != CRITBIT_NULL_INDEX && filled < quantity) {
                        let (_, passive_order) = critbit_v::borrow_at_index(&level.orders, order_idx);
                        if (passive_order.owner_id == order_owner) {
                            if (stp_action_type == CANCEL_AGGRESSIVE) {
                                // Just emit the event
                                event::emit_event<OrderCancelEvent>(
                                    &mut market.cancel_events,
                                    OrderCancelEvent {
                                        order_id,
                                        owner: order.owner_id,
                                        cancel_qty: order.quantity,
                                        timestamp,
                                        client_order_id: client_order_id, // this is same given the invariant
                                        order_type: order_type, // this is same given the invariant
                                    }
                                );
                                destroy_order(order);
                                return (0,0)
                            } else if (stp_action_type == CANCEL_BOTH) {
                                let (_, level) = critbit::borrow_at_index_mut(side, idx);
                                let (_, cancelled) = critbit_v::remove(&mut level.orders, order_idx);
                                level.total_quantity = level.total_quantity - (cancelled.quantity as u128);
                                process_cancel_order<B, Q>(cancelled, timestamp, (lot_size as u128), &mut market.cancel_events);
                                // Just emit the event
                                event::emit_event<OrderCancelEvent>(
                                    &mut market.cancel_events,
                                    OrderCancelEvent {
                                        order_id,
                                        owner: order.owner_id,
                                        cancel_qty: order.quantity,
                                        timestamp,
                                        client_order_id: client_order_id, // this is same given the invariant
                                        order_type: order_type, // this is same given the invariant
                                    }
                                );
                                destroy_order(order);
                                return (0,0)
                            };
                        };
                        if (passive_order.timeout_timestamp >= timestamp) {
                            let remaining = quantity - filled;
                            if (remaining < passive_order.quantity) {
                                filled = quantity;
                            } else {
                                filled = filled + passive_order.quantity;
                            };
                        };
                        order_idx = critbit_v::next_in_order(&level.orders, order_idx);
                    };
                    idx = if (is_bid) {
                        critbit::next_in_order(side, idx)
                    } else {
                        critbit::next_in_reverse_order(side, idx)
                    };
                } else {
                    break
                }
            };

            if (filled < quantity) {
                // Just emit the event
                event::emit_event<OrderCancelEvent>(
                    &mut market.cancel_events,
                    OrderCancelEvent {
                        order_id,
                        owner: order.owner_id,
                        cancel_qty: order.quantity,
                        timestamp,
                        client_order_id: client_order_id, // this is same given the invariant
                        order_type: order_type, // this is same given the invariant
                    }
                );
                destroy_order(order);
                return (0,0)
            }
        };
        // Check for orders that should be cancelled immediately
        if (
            // order timed out
            timeout_timestamp <= timestamp
            // If the order is passive join, it will use ticks_to_slide and market to determine join price, and if join_price is not worse than limit_price, place the order, otherwise cancel
            || (order_type == PASSIVE_JOIN
                && order_price_worse_than_limit(market, &mut order, ticks_to_slide, direction_aggressive))
            // If the order is a moc order and any amount can be filled, the order won't touch the market and immediately "cancelled" like a no-op
            || (order_type == POST_ONLY
                && order_will_fill<B, Q>(market, &mut order, ticks_to_slide))
        ) {
            // Just emit the event
            event::emit_event<OrderCancelEvent>(
                &mut market.cancel_events,
                OrderCancelEvent {
                    order_id,
                    owner: order.owner_id,
                    cancel_qty: order.quantity,
                    timestamp,
                    client_order_id: client_order_id, // this is same given the invariant
                    order_type: order_type, // this is same given the invariant
                }
            );
            destroy_order(order);
            // return base quantity filled, quote quantity filled
            return (0, 0)
        };

        // Check for matches
        let (base_qty_filled, quote_qty_filled) = match(market, &mut order, timestamp, stp_action_type);
        // Check for remaining order quantity
        if (order.quantity > 0) {
            assert!(order_type != FILL_OR_KILL, E_INVALID_STATE);
            if (order_type == IMMEDIATE_OR_CANCEL) {
                event::emit_event<OrderCancelEvent>(
                    &mut market.cancel_events,
                    OrderCancelEvent {
                        order_id,
                        owner: order.owner_id,
                        cancel_qty: order.quantity,
                        timestamp,
                        client_order_id: client_order_id, // this is same given the invariant
                        order_type: order_type, // this is same given the invariant
                    }
                );
                destroy_order(order);
            } else {
                handle_placed_order(market, &order, order_owner);
                insert_order(market, order);
            }
        } else {
            destroy_order(order);
        };
        (base_qty_filled, quote_qty_filled)
    }

    public entry fun fast_cancel_order<B, Q>(sender: &signer, delegator: address, order_id: u128, price: u64, is_bid: bool) acquires Market, OpenOrderAccount {
        // First confirm the sender is allowed to trade on behalf of delegator
        vault::assert_trader_is_authorized_for_account(sender, delegator);

        // Confirm that delegator has a aux account
        assert!(has_aux_account(delegator), E_MISSING_AUX_USER_ACCOUNT);

        // Confirm that market exists
        let resource_addr = @aux;
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);

        // Cancel order
        let market = borrow_global_mut<Market<B, Q>>(resource_addr);
        let (cancelled, success) = inner_cancel_order(market, order_id, delegator, price, is_bid);
        let timestamp = timestamp::now_microseconds();
        if (!success){
            destroy_order(cancelled);
            return
        };
        let lot_size = (market.lot_size as u128);
        process_cancel_order<B, Q>(cancelled, timestamp, lot_size, &mut market.cancel_events);
    }

    public entry fun cancel_order<B, Q>(sender: &signer, delegator: address, order_id: u128) acquires Market, OpenOrderAccount {
        // First confirm the sender is allowed to trade on behalf of delegator
        vault::assert_trader_is_authorized_for_account(sender, delegator);

        // Confirm that delegator has a aux account
        assert!(has_aux_account(delegator), E_MISSING_AUX_USER_ACCOUNT);

        // Confirm that market exists
        let resource_addr = @aux;
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);

        // Cancel order
        let market = borrow_global_mut<Market<B, Q>>(resource_addr);
        let open_order_address = onchain_signer::get_signer_address(delegator);
        assert!(exists<OpenOrderAccount<B, Q>>(open_order_address), E_NO_OPEN_ORDERS_ACCOUNT);

        let open_order_account = borrow_global<OpenOrderAccount<B, Q>>(open_order_address);
        let order_idx = critbit::find(&open_order_account.open_orders, order_id);
        assert!(order_idx != CRITBIT_NULL_INDEX, E_ORDER_NOT_FOUND);
        let (_, OpenOrderInfo {price, is_bid}) = critbit::borrow_at_index(&open_order_account.open_orders, order_idx);
        let (cancelled, success) = inner_cancel_order(market, order_id, delegator, *price, *is_bid);
        let timestamp = timestamp::now_microseconds();
        if (!success){
            destroy_order(cancelled);
            return
        };
        let lot_size = (market.lot_size as u128);
        process_cancel_order<B, Q>(cancelled, timestamp, lot_size, &mut market.cancel_events);
    }

    public entry fun cancel_all<B, Q>(sender: &signer, delegator: address) acquires Market, OpenOrderAccount {
        // First confirm the sender is allowed to trade on behalf of delegator
        vault::assert_trader_is_authorized_for_account(sender, delegator);

        // Confirm that delegator has a aux account
        assert!(has_aux_account(delegator), E_MISSING_AUX_USER_ACCOUNT);

        // Confirm that market exists
        let resource_addr = @aux;
        assert!(market_exists<B, Q>(), E_MARKET_DOES_NOT_EXIST);

        let open_order_address = onchain_signer::get_signer_address(delegator);
        assert!(exists<OpenOrderAccount<B, Q>>(open_order_address), E_NO_OPEN_ORDERS_ACCOUNT);
        // Cancel order
        let open_order_account = borrow_global_mut<OpenOrderAccount<B, Q>>(
            open_order_address,
        );

        let market = borrow_global_mut<Market<B, Q>>(resource_addr);

        let timestamp = timestamp::now_microseconds();
        let n_open_order = critbit::size(&open_order_account.open_orders);

        let lot_size = (market.lot_size as u128);
        while (n_open_order > 0) {
            n_open_order = n_open_order - 1;
            let (order_id, OpenOrderInfo {price, is_bid}) = critbit::remove(&mut open_order_account.open_orders, n_open_order);
            let (order, cancelled) = inner_cancel_order(market, order_id, delegator, price, is_bid);
            if (cancelled) {
                process_cancel_without_open_order_account<B, Q>(order, timestamp, lot_size, &mut market.cancel_events);
            } else {
                destroy_order(order);
            };
        }
    }


    struct L2Event has store, drop {
        bids: vector<L2Quote>,
        asks: vector<L2Quote>,
    }

    struct L2Quote has store, drop {
        price: u64,
        quantity: u128,
    }

    struct AllOrdersEvent has store, drop {
        bids: vector<vector<OpenOrderEventInfo>>,
        asks: vector<vector<OpenOrderEventInfo>>,
    }

    // we don't want to add drop to type Order
    // so we create a copy of Order here for the event.
    struct OpenOrderEventInfo has store, drop {
        id: u128,
        client_order_id: u128,
        price: u64,
        quantity: u64,
        aux_au_to_burn_per_lot: u64,
        is_bid: bool,
        owner_id: address,
        timeout_timestamp: u64,
        order_type: u64,
        timestamp: u64,
    }

    struct OpenOrdersEvent has store, drop {
        open_orders: vector<OpenOrderEventInfo>,
    }

    struct MarketDataStore<phantom B, phantom Q> has key {
        l2_events: event::EventHandle<L2Event>,
        open_orders_events: event::EventHandle<OpenOrdersEvent>,
    }

    struct AllOrdersStore<phantom B, phantom Q> has key {
        all_ordes_events: event::EventHandle<AllOrdersEvent>,
    }

    public entry fun load_market_into_event<B, Q>(sender: &signer) acquires Market, MarketDataStore {
        assert!(market_exists<B, Q>(), E_MARKET_DOES_NOT_EXIST);
        if (!exists<MarketDataStore<B, Q>>(signer::address_of(sender))) {
            move_to(sender, MarketDataStore<B, Q> {
                l2_events: account::new_event_handle<L2Event>(sender),
                open_orders_events: account::new_event_handle<OpenOrdersEvent>(sender),
            });
        };

        let l2_event = L2Event {
            bids: vector::empty(),
            asks: vector::empty(),
        };

        let market = borrow_global<Market<B, Q>>(@aux);

        if (critbit::size(&market.bids) > 0) {
            let side = &market.bids;
            let idx = critbit::get_max_index(side);
            while (idx != CRITBIT_NULL_INDEX) {
                let (_, level) = critbit::borrow_at_index(side, idx);
                vector::push_back(&mut l2_event.bids, L2Quote {
                    price: level.price,
                    quantity: level.total_quantity,
                });
                idx = critbit::next_in_reverse_order(side, idx);
            }
        };

        if (critbit::size(&market.asks) > 0) {
            let side = &market.asks;
            let idx = critbit::get_min_index(side);
            while (idx != CRITBIT_NULL_INDEX) {
                let (_, level) = critbit::borrow_at_index(side, idx);
                vector::push_back(&mut l2_event.asks, L2Quote {
                    price: level.price,
                    quantity: level.total_quantity,
                });
                idx = critbit::next_in_order(side, idx);
            }
        };

        event::emit_event<L2Event>(
            &mut borrow_global_mut<MarketDataStore<B, Q>>(signer::address_of(sender)).l2_events,
            l2_event
        );
    }

    public entry fun load_all_orders_into_event<B,Q>(sender: &signer) acquires Market, AllOrdersStore {
        assert!(market_exists<B, Q>(), E_MARKET_DOES_NOT_EXIST);
        if (!exists<AllOrdersStore<B, Q>>(signer::address_of(sender))) {
            move_to(sender, AllOrdersStore<B, Q> {
                all_ordes_events: account::new_event_handle<AllOrdersEvent>(sender),
            });
        };

        let all_orders = AllOrdersEvent {
            bids: vector::empty(),
            asks: vector::empty(),
        };

        let market = borrow_global<Market<B, Q>>(@aux);

        if (critbit::size(&market.bids) > 0) {
            let side = &market.bids;
            let idx = critbit::get_max_index(side);
            while (idx != CRITBIT_NULL_INDEX) {
                let (_, level) = critbit::borrow_at_index(side, idx);

                let order_idx = critbit_v::size(&level.orders);
                let orders = vector::empty<OpenOrderEventInfo>();
                while (order_idx > 0) {
                    order_idx = order_idx - 1;
                    let (_, order) = critbit_v::borrow_at_index(&level.orders, order_idx);
                    vector::push_back(&mut orders, OpenOrderEventInfo{
                        id: order.id,
                        client_order_id: order.client_order_id,
                        price: order.price,
                        quantity: order.quantity,
                        aux_au_to_burn_per_lot: order.aux_au_to_burn_per_lot,
                        is_bid: order.is_bid,
                        owner_id: order.owner_id,
                        timeout_timestamp: order.timeout_timestamp,
                        order_type: order.order_type,
                        timestamp: order.timestamp,
                    });
                };
                vector::push_back(&mut all_orders.bids, orders);

                idx = critbit::next_in_reverse_order(side, idx);
            }
        };

        if (critbit::size(&market.asks) > 0) {
            let side = &market.asks;
            let idx = critbit::get_min_index(side);
            while (idx != CRITBIT_NULL_INDEX) {
                let (_, level) = critbit::borrow_at_index(side, idx);

                let order_idx = critbit_v::size(&level.orders);
                let orders = vector::empty<OpenOrderEventInfo>();
                while (order_idx > 0) {
                    order_idx = order_idx - 1;
                    let (_, order) = critbit_v::borrow_at_index(&level.orders, order_idx);
                    vector::push_back(&mut orders, OpenOrderEventInfo{
                        id: order.id,
                        client_order_id: order.client_order_id,
                        price: order.price,
                        quantity: order.quantity,
                        aux_au_to_burn_per_lot: order.aux_au_to_burn_per_lot,
                        is_bid: order.is_bid,
                        owner_id: order.owner_id,
                        timeout_timestamp: order.timeout_timestamp,
                        order_type: order.order_type,
                        timestamp: order.timestamp,
                    });
                };
                vector::push_back(&mut all_orders.asks, orders);

                idx = critbit::next_in_order(side, idx);
            }
        };

        event::emit_event<AllOrdersEvent>(
            &mut borrow_global_mut<AllOrdersStore<B, Q>>(signer::address_of(sender)).all_ordes_events,
            all_orders
        );
    }

    public entry fun load_open_orders_into_event<B, Q>(sender: &signer) acquires Market, MarketDataStore, OpenOrderAccount {
        load_open_orders_into_event_for_address<B, Q>(sender,  signer::address_of(sender))
    }

    public entry fun load_open_orders_into_event_for_address<B, Q>(sender: &signer, order_owner: address) acquires Market, MarketDataStore, OpenOrderAccount {
        assert!(market_exists<B, Q>(), E_MARKET_DOES_NOT_EXIST);
        if (!exists<MarketDataStore<B, Q>>(signer::address_of(sender))) {
            move_to(sender, MarketDataStore<B, Q> {
                l2_events: account::new_event_handle<L2Event>(sender),
                open_orders_events: account::new_event_handle<OpenOrdersEvent>(sender),
            });
        };

        let open_order_address = onchain_signer::get_signer_address(order_owner);
        let open_order_account = borrow_global<OpenOrderAccount<B, Q>>(open_order_address);
        let n_orders = critbit::size(&open_order_account.open_orders);
        let idx = 0;
        let open_orders_events = OpenOrdersEvent {
            open_orders: vector::empty(),
        };

        let market = borrow_global<Market<B, Q>>(@aux);
        while (idx < n_orders) {
            let (order_id, order_info) = critbit::borrow_at_index(&open_order_account.open_orders, idx);
            let side = if (order_info.is_bid) { &market.bids } else { &market.asks };
            let level_idx = critbit::find(side, (order_info.price as u128));
            assert!(
                level_idx != CRITBIT_NULL_INDEX,
                E_ORDER_NOT_FOUND
            );
            let (_, level) = critbit::borrow_at_index(side, level_idx);
            let order_idx = critbit_v::find(&level.orders, order_id);
            assert!(
                order_idx != CRITBIT_NULL_INDEX,
                E_ORDER_NOT_FOUND
            );
            let (_, order) = critbit_v::borrow_at_index(&level.orders, order_idx);
            vector::push_back(
                &mut open_orders_events.open_orders,
                OpenOrderEventInfo {
                    id: order.id,
                    client_order_id: order.client_order_id,
                    price: order.price,
                    quantity: order.quantity,
                    aux_au_to_burn_per_lot: order.aux_au_to_burn_per_lot,
                    is_bid: order.is_bid,
                    owner_id: order.owner_id,
                    timeout_timestamp: order.timeout_timestamp,
                    order_type: order.order_type,
                    timestamp: order.timestamp,
                }
            );
            idx = idx + 1;
        };

        event::emit_event<OpenOrdersEvent>(
            &mut borrow_global_mut<MarketDataStore<B, Q>>(signer::address_of(sender)).open_orders_events,
            open_orders_events,
        );
    }

    public entry fun update_market_parameter<B,Q>(sender: &signer, tick_size: u64, lot_size: u64) acquires Market, OpenOrderAccount {
        if (signer::address_of(sender) != @aux) {
            assert!(
                authority::is_signer_owner(sender),
                E_UNAUTHORIZED_FOR_MARKET_UPDATE,
            );
        };

        assert!(
            market_exists<B,Q>(),
            E_MARKET_DOES_NOT_EXIST
        );
        let timestamp = timestamp::now_microseconds();

        let market = borrow_global_mut<Market<B, Q>>(@aux);

        let base_exp = exp(10, (market.base_decimals as u128));
        // This invariant ensures that the smallest possible trade value is representable with quote asset decimals
        assert!((lot_size as u128) * (tick_size as u128) / base_exp > 0, E_INVALID_TICK_OR_LOT_SIZE);
        // This invariant ensures that the smallest possible trade value has no rounding issue with quote asset decimals
        assert!((lot_size as u128) * (tick_size as u128) % base_exp == 0, E_INVALID_TICK_OR_LOT_SIZE);

        assert!(
            tick_size != market.tick_size || lot_size != market.lot_size,
            E_MARKET_NOT_UPDATING,
        );

        let new_lot_size = market.lot_size != lot_size;
        let n_levels = critbit::size(&market.bids);
        let level_idx: u64 = 0;
        let old_lot_size_u128: u128 = (market.lot_size as u128);
        while (level_idx < n_levels) {
            let (_, level) = critbit::borrow_at_index(&market.bids, level_idx);
            if (level.price % tick_size != 0) {
                let (_, level) = critbit::remove(&mut market.bids, level_idx);
                // cancel the whole level
                let n_orders = critbit_v::size(&level.orders);
                while (n_orders > 0) {
                    n_orders = n_orders - 1;
                    let (_, order) = critbit_v::remove(&mut level.orders, n_orders);
                    process_cancel_order<B, Q>(order, timestamp, old_lot_size_u128, &mut market.cancel_events);
                };
                level.total_quantity = 0;
                destroy_empty_level(level);
                n_levels = n_levels - 1;
            } else {
                let (_, level) = critbit::borrow_at_index_mut(&mut market.bids, level_idx);
                let n_orders = critbit_v::size(&level.orders);
                let order_idx = 0u64;
                while(order_idx < n_orders) {
                    let (_, order) = critbit_v::borrow_at_index(&level.orders, order_idx);
                    if ((order.aux_au_to_burn_per_lot > 0 && new_lot_size) || order.quantity % lot_size != 0) {
                        let (_, order) = critbit_v::remove(&mut level.orders, order_idx);
                        level.total_quantity = level.total_quantity - (order.quantity as u128);
                        process_cancel_order<B,Q>(order, timestamp, old_lot_size_u128, &mut market.cancel_events);
                        n_orders = n_orders - 1;
                    } else {
                        order_idx = order_idx + 1;
                    };
                };

                if (level.total_quantity == 0) {
                    let (_, level) = critbit::remove(&mut market.bids, level_idx);
                    destroy_empty_level(level);
                    n_levels = n_levels - 1;
                } else {
                    level_idx = level_idx + 1;
                }
            };
        };

        let n_levels = critbit::size(&market.asks);
        let level_idx: u64 = 0;
        let old_lot_size_u128: u128 = (market.lot_size as u128);
        while (level_idx < n_levels) {
            let (_, level) = critbit::borrow_at_index(&market.asks, level_idx);
            if (level.price % tick_size != 0) {
                let (_, level) = critbit::remove(&mut market.asks, level_idx);
                // cancel the whole level
                let n_orders = critbit_v::size(&level.orders);
                while (n_orders > 0) {
                    n_orders = n_orders - 1;
                    let (_, order) = critbit_v::remove(&mut level.orders, n_orders);
                    process_cancel_order<B, Q>(order, timestamp, old_lot_size_u128, &mut market.cancel_events);
                };
                level.total_quantity = 0;
                destroy_empty_level(level);
                n_levels = n_levels - 1;
            } else {
                let (_, level) = critbit::borrow_at_index_mut(&mut market.asks, level_idx);
                let n_orders = critbit_v::size(&level.orders);
                let order_idx = 0u64;
                while(order_idx < n_orders) {
                    let (_, order) = critbit_v::borrow_at_index(&level.orders, order_idx);
                    if ((order.aux_au_to_burn_per_lot > 0 && new_lot_size) || order.quantity % lot_size != 0) {
                        let (_, order) = critbit_v::remove(&mut level.orders, order_idx);
                        level.total_quantity = level.total_quantity - (order.quantity as u128);
                        process_cancel_order<B,Q>(order, timestamp, old_lot_size_u128, &mut market.cancel_events);
                        n_orders = n_orders - 1;
                    } else {
                        order_idx = order_idx + 1;
                    };
                };

                if (level.total_quantity == 0) {
                    let (_, level) = critbit::remove(&mut market.asks, level_idx);
                    destroy_empty_level(level);
                    n_levels = n_levels - 1;
                } else {
                    level_idx = level_idx + 1;
                }
            };
        };

        market.lot_size = lot_size;
        market.tick_size = tick_size;
    }

    /********************/
    /* PUBLIC FUNCTIONS */
    /********************/

    public fun market_exists<B, Q>(): bool {
        exists<Market<B, Q>>(@aux)
    }

    public fun n_bid_levels<B, Q>(): u64 acquires Market {
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);
        let market = borrow_global<Market<B, Q>>(@aux);
        critbit::size(&market.bids)
    }

    public fun n_ask_levels<B, Q>(): u64 acquires Market {
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);
        let market = borrow_global<Market<B, Q>>(@aux);
        critbit::size(&market.asks)
    }

    public fun lot_size<B, Q>(): u64 acquires Market {
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);
        let market = borrow_global<Market<B, Q>>(@aux);
        market.lot_size
    }

    public fun tick_size<B, Q>(): u64 acquires Market {
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);
        let market = borrow_global<Market<B, Q>>(@aux);
        market.tick_size
    }

    // TODO: consolidate these with inner functions
    // Returns the best bid price as quote coin atomic units
    public fun best_bid_au<B, Q>(): u64 acquires Market {
        let market = borrow_global<Market<B, Q>>(@aux);
        best_bid_price(market)
    }

    // Returns the best bid price as quote coin atomic units
    public fun best_ask_au<B, Q>(): u64 acquires Market {
        let market = borrow_global<Market<B, Q>>(@aux);
        best_ask_price(market)
    }

    // cancel_order returns (order_cancelled, cancel_success)
    // cancel_success = false if the order_id is not found
    fun inner_cancel_order<B, Q>(market: &mut Market<B, Q>, order_id: u128, sender_addr: address, price: u64, is_bid: bool): (Order, bool) {
        let side = if (is_bid) { &mut market.bids } else { &mut market.asks };

        let level_idx = critbit::find(side, (price as u128));
        if (level_idx == CRITBIT_NULL_INDEX) {
            return (create_order(order_id, order_id, 0, 0, 0, false, sender_addr, MAX_U64, LIMIT_ORDER, 0), false)
        };
        let (_, level) = critbit::borrow_at_index_mut(side, level_idx);
        let order_idx = critbit_v::find(&level.orders, order_id);
        if (order_idx == CRITBIT_NULL_INDEX) {
            return (create_order(order_id, order_id, 0, 0, 0, false, sender_addr, MAX_U64, LIMIT_ORDER, 0), false)
        };

        let (_, order) = critbit_v::remove(&mut level.orders, order_idx);

        assert!(
            order.owner_id == sender_addr,
            E_NOT_ORDER_OWNER,
        );

        level.total_quantity = level.total_quantity - (order.quantity as u128);

        if (level.total_quantity == 0) {
            let (_, level) = critbit::remove(side, level_idx);
            destroy_empty_level(level);
        };

        return (order, true)
    }

    public fun place_market_order<B, Q>(
        sender_addr: address,
        base_coin: coin::Coin<B>,
        quote_coin: coin::Coin<Q>,
        is_bid: bool,
        order_type: u64,
        limit_price: u64,
        quantity: u64,
        client_order_id: u128,
    ): (coin::Coin<B>, coin::Coin<Q>)  acquires Market, OpenOrderAccount {
        place_market_order_mut(
            sender_addr,
            &mut base_coin,
            &mut quote_coin,
            is_bid,
            order_type,
            limit_price,
            quantity,
            client_order_id
        );
        (base_coin, quote_coin)
    }

    /// Place a market order (IOC or FOK) on behalf of the router.
    /// Returns (total_base_quantity_owed_au, quote_quantity_owed_au), the amounts that must be credited/debited to the sender.
    /// Emits events on order placement and fills.
    public fun place_market_order_mut<B, Q>(
        sender_addr: address,
        base_coin: &mut coin::Coin<B>,
        quote_coin: &mut coin::Coin<Q>,
        is_bid: bool,
        order_type: u64,
        limit_price: u64,
        quantity: u64,
        client_order_id: u128,
    ): (u64, u64)  acquires Market, OpenOrderAccount {

        // Confirm that market exists
        let resource_addr = @aux;
        assert!(market_exists<B, Q>(),E_MARKET_DOES_NOT_EXIST);
        let market = borrow_global_mut<Market<B, Q>>(resource_addr);

        // The router may only place FOK or IOC orders
        assert!(order_type == FILL_OR_KILL || order_type == IMMEDIATE_OR_CANCEL, E_INVALID_ROUTER_ORDER_TYPE);

        // round quantity down (router may submit un-quantized quantities)
        let lot_size = market.lot_size;
        let tick_size = market.tick_size;
        let rounded_quantity = quantity / lot_size * lot_size;
        let rounded_price = limit_price / tick_size * tick_size;

        let (base_au, quote_au) = new_order<B, Q>(
            market,
            sender_addr,
            is_bid,
            rounded_price,
            rounded_quantity,
            0,
            order_type,
            client_order_id,
            0,
            false,
            MAX_U64,
            CANCEL_AGGRESSIVE,
        );

        // Transfer coins
        let vault_addr = @aux;
        let module_signer = &authority::get_signer_self();
        if (base_au != 0 && quote_au != 0) {
            if (is_bid) {
                // taker pays quote, receives base
                let quote = coin::extract<Q>(quote_coin, (quote_au as u64));
                if (!coin::is_account_registered<Q>(@aux)) {
                    coin::register<Q>(module_signer);
                };
                coin::deposit<Q>(vault_addr, quote);
                let base = coin::withdraw<B>(module_signer, (base_au as u64));
                coin::merge<B>(base_coin, base);
            } else {
                // taker receives quote, pays base
                let base = coin::extract<B>(base_coin, (base_au as u64));
                if (!coin::is_account_registered<B>(@aux)) {
                    coin::register<B>(module_signer);
                };
                coin::deposit<B>(vault_addr, base);
                let quote = coin::withdraw<Q>(module_signer, (quote_au as u64));
                coin::merge<Q>(quote_coin, quote);

            }
        } else if (base_au != 0 || quote_au != 0) {
            // abort if sender paid but did not receive and vice versa
            abort(E_INVALID_STATE)
        };
        (base_au, quote_au)
    }

    /*********************/
    /* PRIVATE FUNCTIONS */
    /*********************/

    fun process_cancel_without_open_order_account<B, Q>(
        cancelled: Order,
        timestamp: u64,
        lot_size: u128,
        cancel_events: &mut event::EventHandle<OrderCancelEvent>
    ) {
        let cancel_qty = cancelled.quantity;
        let event = OrderCancelEvent {
                order_id: cancelled.id,
                owner: cancelled.owner_id,
                cancel_qty: cancelled.quantity,
                timestamp,
                client_order_id: cancelled.client_order_id,
                order_type: cancelled.order_type,
        };

        event::emit_event(cancel_events, event);
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

        // When a cancel is successful, credit the unused AUX back to the user.
        let aux_burned = cancelled.aux_au_to_burn_per_lot;
        let remaining_qty = (cancelled.quantity as u128);
        let refund_aux_au = (aux_burned as u128) * remaining_qty / lot_size;
        if (refund_aux_au > 0) {
            vault::increase_available_balance<AuxCoin>(cancelled.owner_id, refund_aux_au);
        };

        destroy_order(cancelled);
    }
    fun process_cancel_order<B, Q>(cancelled: Order, timestamp: u64, lot_size: u128, cancel_events: &mut event::EventHandle<OrderCancelEvent>) acquires OpenOrderAccount {
        let open_order_account = borrow_global_mut<OpenOrderAccount<B, Q>>(
                onchain_signer::get_signer_address(cancelled.owner_id)
            );

        let order_idx = critbit::find(&open_order_account.open_orders, cancelled.id);

        assert!(order_idx != CRITBIT_NULL_INDEX, E_ORDER_NOT_IN_OPEN_ORDER_ACCOUNT);

        critbit::remove(&mut open_order_account.open_orders, order_idx);
        process_cancel_without_open_order_account<B, Q>(cancelled, timestamp, lot_size, cancel_events);
    }

    fun generate_order_id<B, Q>(market: &mut Market<B, Q>, aux_au_to_burn_per_lot: u64): u128 {
        let aux_to_burn = ((MAX_U64 - aux_au_to_burn_per_lot) as u128);
        aux_to_burn = aux_to_burn << 64;
        let order_id = aux_to_burn + (market.next_order_id as u128);
        market.next_order_id = market.next_order_id + 1;
        order_id
    }

    // TODO: it's pretty unintuitive that this modifies the order. Maybe there's a better way to structure this.
    // true if any amount of the order can be filled by orderbook even after the maximum ticks_to_slide specified, otherwise return false and change the order.price_ticks by minimum_ticks_to_slide to make it not fill
    fun order_will_fill<B, Q>(market: &Market<B, Q>, order: &mut Order, ticks_to_slide: u64): bool {
        let tick_size = market.tick_size;
        let order_price = order.price;
        if (order.is_bid){
            // if there's no ask at all, then cannot fill with 0 ticks_to_slide
            if (critbit::size(&market.asks) == 0) return false;
            // TODO: confirm this level_price is also ticks?
            let level_price = best_ask_price(market);

            if (order_price < level_price) {
                return false
            };
            // TODO: confirm - 1 tick should be decrement 1 tick
            if ((order_price - level_price + tick_size) <= ticks_to_slide * tick_size) {
                assert!(level_price - tick_size > 0, E_SLIDE_TO_ZERO_PRICE);
                order.price = level_price - tick_size;
                return false
            };
            return true
        } else{
            // if there's no bid at all, then cannot fill with 0 ticks_to_slide
            if (critbit::size(&market.bids) == 0) {
                return false
            };
            let level_price = best_bid_price(market);
            if (order_price > level_price) {
                return false
            };
            // TODO: confirm + 1 should be increment 1 tick
            if ((level_price - order_price + tick_size) <= ticks_to_slide * tick_size) {
                order.price = level_price + tick_size;
                return false
            };
            return true
        }
    }

    public fun best_bid_price<B, Q>(market: &Market<B, Q>): u64 {
        assert!(critbit::size(&market.bids) > 0, E_NO_BIDS_IN_BOOK);
        let index = critbit::get_max_index(&market.bids);
        let (_, level) = critbit::borrow_at_index(&market.bids, index);
        level.price
    }

    public fun best_ask_price<B, Q>(market: &Market<B, Q>): u64 {
        assert!(critbit::size(&market.asks) > 0, E_NO_ASKS_IN_BOOK);
        let index = critbit::get_min_index(&market.asks);
        let (_, level) = critbit::borrow_at_index(&market.asks, index);
        level.price
    }

    // TODO: it's pretty unintuitive that this modifies the order. Maybe there's a better way to structure this.
    // return true if order_price is worse than limit (greater than limit when placing bid and smaller than limit when placing ask), otherwise false and change the order price to be specified price based on ticks and orderbook state
    fun order_price_worse_than_limit<B, Q>(market: &Market<B, Q>, order: &mut Order, ticks_to_slide: u64, direction_aggressive: bool) : bool {
        let tick_size = market.tick_size;
        let limit_price = order.price;
        let order_price;
        if (order.is_bid){
            // if there's no bids at all, then cannot passively join bids
            if (critbit::size(&market.bids) == 0) {
                return true
            };
            // derive the join price
            let best_bid_level_price =  best_bid_price(market);
            let best_ask_level_price = MAX_U64;
            if (critbit::size(&market.asks) > 0) {
                best_ask_level_price = best_ask_price(market);
            };
            if(direction_aggressive){
                order_price = best_bid_level_price + ticks_to_slide * tick_size;
                if (order_price >= best_ask_level_price) {
                    order_price = best_ask_level_price - tick_size;
                }
            } else {
                order_price = best_bid_level_price - ticks_to_slide * tick_size;
            };
            if (order_price <= limit_price) {
                order.price = order_price;
                return false
            };
            return true
        } else{
            // if there's no asks at all, then cannot passively join asks
            if (critbit::size(&market.asks) == 0) return true;
            // derive the join price
            let best_ask_level_price = best_ask_price(market);
            let best_bid_level_price = 0;
            if (critbit::size(&market.bids) > 0) {
                best_bid_level_price =  best_bid_price(market);
            };
            if(direction_aggressive){
                order_price = best_ask_level_price - ticks_to_slide * tick_size;
                if (order_price <= best_bid_level_price) {
                    order_price = best_bid_level_price + tick_size;
                }
            }else{
                order_price = best_ask_level_price + ticks_to_slide * tick_size;
            };
            if (order_price >= limit_price) {
                order.price = order_price;
                return false
            };
            return true
        }
    }

    fun match<B, Q>(market: &mut Market<B, Q>, taker_order: &mut Order, current_timestamp: u64, stp_action_type: u64): (u64, u64) acquires OpenOrderAccount {
        let side = if (taker_order.is_bid) { &mut market.asks } else { &mut market.bids };
        let order_price = taker_order.price;
        let total_base_quantity_owed_au = 0;
        let total_quote_quantity_owed_au = 0;

        let lot_size = (market.lot_size as u128);
        while (!critbit::empty(side) && taker_order.quantity > 0) {
            let min_level_index = if (taker_order.is_bid) {
                critbit::get_min_index(side)
            } else {
                critbit::get_max_index(side)
            };
            let (_, level) = critbit::borrow_at_index_mut(side, min_level_index);
            let level_price = level.price;

            if (
                (taker_order.is_bid && level_price <= order_price) ||   // match is an ask <= bid
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
                        process_cancel_order<B, Q>(min_order, current_timestamp, lot_size, &mut market.cancel_events);
                        continue
                    };

                    // Check whether self-trade occurs
                    if (taker_order.owner_id == maker_order.owner_id) {
                        // Follow the specification to cancel
                        if (stp_action_type == CANCEL_PASSIVE){
                            let (_, cancelled) = critbit_v::remove(&mut level.orders, min_order_idx);
                            level.total_quantity = level.total_quantity - (cancelled.quantity as u128);
                            process_cancel_order<B, Q>(cancelled, current_timestamp, lot_size, &mut market.cancel_events);
                        } else if (stp_action_type == CANCEL_AGGRESSIVE){
                            // Cancel the rest unfilled amount of taker order
                            let event = OrderCancelEvent {
                                    order_id: taker_order.id,
                                    owner: taker_order.owner_id,
                                    cancel_qty: taker_order.quantity,
                                    timestamp: current_timestamp,
                                    client_order_id: taker_order.client_order_id,
                                    order_type: taker_order.order_type,
                            };
                            event::emit_event(&mut market.cancel_events, event);
                            taker_order.quantity = 0;
                            break
                        } else if (stp_action_type == CANCEL_BOTH){
                            // Cancel the maker order
                            let (_, cancelled) = critbit_v::remove(&mut level.orders, min_order_idx);
                            level.total_quantity = level.total_quantity - (cancelled.quantity as u128);
                            process_cancel_order<B, Q>(cancelled, current_timestamp, lot_size, &mut market.cancel_events);
                            // Cancel the taker order
                            let event = OrderCancelEvent {
                                    order_id: taker_order.id,
                                    owner: taker_order.owner_id,
                                    cancel_qty: taker_order.quantity,
                                    timestamp: current_timestamp,
                                    client_order_id: taker_order.client_order_id,
                                    order_type: taker_order.order_type,
                            };
                            event::emit_event(&mut market.cancel_events, event);
                            taker_order.quantity = 0;
                            break
                        }else{
                            abort(E_UNSUPPORTED_STP_ACTION_TYPE)
                        };
                        // If maker order is cancelled, we want to continue matching
                        continue
                    };
                    let current_maker_quantity = maker_order.quantity;
                    if (current_maker_quantity <= taker_order.quantity) {
                        // emit fill event
                        let (base, quote) = handle_fill<B, Q>(&mut market.fill_events, taker_order, maker_order, current_maker_quantity, lot_size);
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
                        let (base, quote) = handle_fill<B, Q>(&mut market.fill_events, taker_order, maker_order, quantity, lot_size);
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
