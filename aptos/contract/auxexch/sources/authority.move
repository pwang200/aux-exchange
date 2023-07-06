// Auto generated from aptos/deployer/cmd/gen-aptos-deployer-selfsign
// Modify by hand with caution.
// Argumenets: -a aux -f amm -f aux_coin -f clob_market -f vault -n authority -o sources/authority.move
// authority controls the signer capability of this module.
module aux::authority {
    use std::signer;
    use aptos_framework::account::{Self, SignerCapability};
    use std::bcs;
    use std::vector;

    friend aux::clob_market;
    friend aux::vault;

    const E_NOT_SELF_SIGNED: u64 = 1001;
    const E_CANNOT_SIGN_FOR_OTHER: u64 = 1002;
    const E_NOT_OWNER: u64 = 1003;

    struct Authority has key {
        signer_capability: SignerCapability,
        owner_address: address,
    }

    // on module initialization, the module will tries to get the signer capability from deployer.
    fun init_module(source: &signer) {
        let source_addr = signer::address_of(source);
        if(!exists<Authority>(source_addr)) {
            let bytes = bcs::to_bytes(&@aux);
            vector::append(&mut bytes, b"aux-Authority");
            let (auth_signer, signer_capability) =
                account::create_resource_account(source, bytes);
            let owner_address = signer::address_of(&auth_signer);
            assert!(
                signer::address_of(source) == owner_address,
                E_CANNOT_SIGN_FOR_OTHER,
            );

            move_to(source, Authority {
                signer_capability,
                owner_address,
            });
        }
    }

    // get signer for the module itself.
    public(friend) fun get_signer_self(): signer acquires Authority {
        assert!(
            exists<Authority>(@aux),
            E_NOT_SELF_SIGNED,
        );

        let auth = borrow_global<Authority>(@aux);

        let auth_signer = account::create_signer_with_capability(&auth.signer_capability);

        assert!(
            signer::address_of(&auth_signer) == @aux,
            E_CANNOT_SIGN_FOR_OTHER,
        );

        auth_signer
    }

    // get the signer for the owner.
    public fun get_signer(owner: &signer): signer acquires Authority {
        assert!(
            exists<Authority>(@aux),
            E_NOT_SELF_SIGNED,
        );

        let auth = borrow_global<Authority>(@aux);

        assert!(
            signer::address_of(owner) == auth.owner_address,
            E_NOT_OWNER,
        );

        let auth_signer = account::create_signer_with_capability(&auth.signer_capability);

        assert!(
            signer::address_of(&auth_signer) == @aux,
            E_CANNOT_SIGN_FOR_OTHER,
        );

        auth_signer
    }

    public(friend) fun is_signer_owner(user: &signer): bool acquires Authority {
        assert!(
            exists<Authority>(@aux),
            E_NOT_SELF_SIGNED,
        );

        let auth = borrow_global<Authority>(@aux);

        signer::address_of(user) == auth.owner_address
    }

    // #[test_only]
    // public fun init_module_for_test(source: &signer) {
    //     init_module(source)
    // }
}
