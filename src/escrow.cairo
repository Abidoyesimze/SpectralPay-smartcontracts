use starknet::ContractAddress;
use super::interfaces::{EscrowDetails, EscrowStatus};

#[starknet::contract]
mod Escrow {
    use super::{EscrowDetails, EscrowStatus};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::Map;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
    use core::num::traits::Zero;

    #[storage]
    struct Storage {
        escrows: Map<u256, EscrowDetails>,
        next_escrow_id: u256,
        authorized_contracts: Map<ContractAddress, bool>,
        dispute_resolver: ContractAddress,
        dispute_fee: u256,
        auto_release_enabled: bool,
        max_dispute_duration: u64,
        platform_fee_rate: u256,
        fee_recipient: ContractAddress,
        emergency_multisig: ContractAddress,
        owner: ContractAddress,
        paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        EscrowCreated: EscrowCreated,
        PaymentReleased: PaymentReleased,
        PaymentDisputed: PaymentDisputed,
        DisputeResolved: DisputeResolved,
        PaymentRefunded: PaymentRefunded,
        AutoReleaseTriggered: AutoReleaseTriggered,
        EmergencyRefund: EmergencyRefund,
    }

    #[derive(Drop, starknet::Event)]
    struct EscrowCreated {
        #[key]
        escrow_id: u256,
        #[key]
        job_id: u256,
        employer: ContractAddress,
        worker_pseudonym: felt252,
        amount: u256,
        token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct PaymentReleased {
        #[key]
        escrow_id: u256,
        worker_payout_address: ContractAddress,
        amount: u256,
        platform_fee: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct PaymentDisputed {
        #[key]
        escrow_id: u256,
        disputer: ContractAddress,
        reason: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeResolved {
        #[key]
        escrow_id: u256,
        resolver: ContractAddress,
        release_to_worker: bool,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct PaymentRefunded {
        #[key]
        escrow_id: u256,
        employer: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct AutoReleaseTriggered {
        #[key]
        escrow_id: u256,
        worker_payout_address: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct EmergencyRefund {
        #[key]
        escrow_id: u256,
        employer: ContractAddress,
        amount: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        dispute_resolver: ContractAddress,
        platform_fee_rate: u256,
        fee_recipient: ContractAddress,
        emergency_multisig: ContractAddress
    ) {
        self.owner.write(owner);
        self.dispute_resolver.write(dispute_resolver);
        self.platform_fee_rate.write(platform_fee_rate);
        self.fee_recipient.write(fee_recipient);
        self.emergency_multisig.write(emergency_multisig);
        self.next_escrow_id.write(1);
        self.dispute_fee.write(10000000000000000); // 0.01 ETH equivalent
        self.auto_release_enabled.write(true);
        self.max_dispute_duration.write(30 * 86400); // 30 days
        self.paused.write(false);
    }

    // Simple interface implementation without external dependencies
    impl EscrowImpl of IEscrow<ContractState> {
        fn create_escrow(
            ref self: ContractState,
            job_id: u256,
            employer: ContractAddress,
            worker_pseudonym: felt252,
            worker_payout_address: ContractAddress,
            amount: u256,
            token: ContractAddress,
            auto_release_delay: u64
        ) -> u256 {
            let caller = get_caller_address();
            
            // Check if caller is authorized
            assert(self.authorized_contracts.read(caller), 'Unauthorized caller');
            
            // Validate inputs
            assert(worker_payout_address.is_non_zero(), 'Invalid payout address');
            assert(amount > 0, 'Amount must be positive');
            
            let escrow_id = self.next_escrow_id.read();
            self.next_escrow_id.write(escrow_id + 1);
            
            // Calculate platform fee
            let platform_fee = (amount * self.platform_fee_rate.read()) / 10000;
            
            let current_time = get_block_timestamp();
            let auto_release_at = current_time + auto_release_delay;
            let dispute_deadline = auto_release_at + self.max_dispute_duration.read();
            
            let escrow = EscrowDetails {
                id: escrow_id,
                job_id,
                employer,
                worker_pseudonym,
                worker_payout_address,
                amount,
                token,
                status: EscrowStatus::Active,
                created_at: current_time,
                auto_release_at,
                dispute_deadline,
                platform_fee,
            };
            
            self.escrows.write(escrow_id, escrow);
            
            self.emit(EscrowCreated {
                escrow_id,
                job_id,
                employer,
                worker_pseudonym,
                amount,
                token,
            });
            
            escrow_id
        }

        fn release_payment(ref self: ContractState, escrow_id: u256) {
            assert(!self.paused.read(), 'Contract is paused');
            
            let caller = get_caller_address();
            let mut escrow = self.escrows.read(escrow_id);
            
            // Check authorization
            let is_authorized = self.authorized_contracts.read(caller) ||
                              (get_block_timestamp() >= escrow.auto_release_at && self.auto_release_enabled.read());
            
            assert(is_authorized, 'Not authorized to release payment');
            
            // Update status
            escrow.status = EscrowStatus::Released;
            self.escrows.write(escrow_id, escrow);
            
            self.emit(PaymentReleased {
                escrow_id,
                worker_payout_address: escrow.worker_payout_address,
                amount: escrow.amount,
                platform_fee: escrow.platform_fee,
            });
        }

        fn dispute_payment(ref self: ContractState, escrow_id: u256, reason: ByteArray) {
            assert(!self.paused.read(), 'Contract is paused');
            
            let caller = get_caller_address();
            let mut escrow = self.escrows.read(escrow_id);
            
            escrow.status = EscrowStatus::Disputed;
            self.escrows.write(escrow_id, escrow);
            
            self.emit(PaymentDisputed {
                escrow_id,
                disputer: caller,
                reason,
            });
        }

        fn resolve_dispute(
            ref self: ContractState,
            escrow_id: u256,
            release_to_worker: bool
        ) {
            assert(!self.paused.read(), 'Contract is paused');
            
            let caller = get_caller_address();
            
            // Check authorization
            assert(
                caller == self.dispute_resolver.read() || 
                caller == self.owner.read() ||
                caller == self.emergency_multisig.read(),
                'Not authorized to resolve dispute'
            );
            
            let mut escrow = self.escrows.read(escrow_id);
            
            if release_to_worker {
                escrow.status = EscrowStatus::Released;
            } else {
                escrow.status = EscrowStatus::Refunded;
            }
            
            self.escrows.write(escrow_id, escrow);
            
            self.emit(DisputeResolved {
                escrow_id,
                resolver: caller,
                release_to_worker,
                amount: escrow.amount,
            });
        }

        fn emergency_refund(ref self: ContractState, escrow_id: u256) {
            assert(!self.paused.read(), 'Contract is paused');
            
            let caller = get_caller_address();
            
            // Only owner or emergency multisig can perform emergency refund
            assert(
                caller == self.owner.read() || 
                caller == self.emergency_multisig.read(),
                'Not authorized for emergency refund'
            );
            
            let mut escrow = self.escrows.read(escrow_id);
            let total_amount = escrow.amount + escrow.platform_fee;
            
            escrow.status = EscrowStatus::Refunded;
            self.escrows.write(escrow_id, escrow);
            
            self.emit(EmergencyRefund {
                escrow_id,
                employer: escrow.employer,
                amount: total_amount,
            });
        }

        fn get_escrow_details(self: @ContractState, escrow_id: u256) -> EscrowDetails {
            self.escrows.read(escrow_id)
        }
    }

    // Administrative functions
    #[generate_trait]
    impl AdminImpl of AdminTrait<ContractState> {
        fn authorize_contract(ref self: ContractState, contract_address: ContractAddress) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.authorized_contracts.write(contract_address, true);
        }

        fn revoke_contract(ref self: ContractState, contract_address: ContractAddress) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.authorized_contracts.write(contract_address, false);
        }

        fn set_dispute_resolver(ref self: ContractState, new_resolver: ContractAddress) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.dispute_resolver.write(new_resolver);
        }

        fn set_dispute_fee(ref self: ContractState, new_fee: u256) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.dispute_fee.write(new_fee);
        }

        fn set_platform_fee_rate(ref self: ContractState, new_rate: u256) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.platform_fee_rate.write(new_rate);
        }

        fn toggle_auto_release(ref self: ContractState) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            let current_state = self.auto_release_enabled.read();
            self.auto_release_enabled.write(!current_state);
        }

        fn set_max_dispute_duration(ref self: ContractState, duration: u64) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.max_dispute_duration.write(duration);
        }

        fn pause(ref self: ContractState) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.paused.write(true);
        }

        fn unpause(ref self: ContractState) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.paused.write(false);
        }

        fn set_emergency_multisig(ref self: ContractState, new_multisig: ContractAddress) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.emergency_multisig.write(new_multisig);
        }
    }
}