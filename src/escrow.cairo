use starknet::ContractAddress;
use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
use core::num::traits::Zero;
use super::interfaces::{IEscrow, EscrowDetails, EscrowStatus};

#[starknet::contract]
mod Escrow {
    use super::{IEscrow, EscrowDetails, EscrowStatus};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address, Map};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
    use core::num::traits::Zero;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::pausable::PausableComponent;
    use openzeppelin::security::reentrancy_guard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl ReentrancyGuardImpl = ReentrancyGuardComponent::ReentrancyGuardImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

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
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
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
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
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
        auto_release_at: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct PaymentReleased {
        #[key]
        escrow_id: u256,
        #[key]
        job_id: u256,
        worker_payout_address: ContractAddress,
        amount: u256,
        platform_fee: u256,
        released_by: ContractAddress,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct PaymentDisputed {
        #[key]
        escrow_id: u256,
        #[key]
        job_id: u256,
        disputed_by: ContractAddress,
        reason: ByteArray,
        dispute_deadline: u64,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeResolved {
        #[key]
        escrow_id: u256,
        resolved_by: ContractAddress,
        release_to_worker: bool,
        resolution_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct PaymentRefunded {
        #[key]
        escrow_id: u256,
        employer: ContractAddress,
        amount: u256,
        refund_reason: ByteArray,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct AutoReleaseTriggered {
        #[key]
        escrow_id: u256,
        worker_payout_address: ContractAddress,
        amount: u256,
        trigger_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct EmergencyRefund {
        #[key]
        escrow_id: u256,
        authorized_by: ContractAddress,
        refund_to: ContractAddress,
        amount: u256,
        timestamp: u64,
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
        self.ownable.initializer(owner);
        self.dispute_resolver.write(dispute_resolver);
        self.platform_fee_rate.write(platform_fee_rate);
        self.fee_recipient.write(fee_recipient);
        self.emergency_multisig.write(emergency_multisig);
        self.next_escrow_id.write(1);
        self.dispute_fee.write(10000000000000000);
        self.auto_release_enabled.write(true);
        self.max_dispute_duration.write(30 * 86400);
    }

    #[abi(embed_v0)]
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
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
            
            let caller = get_caller_address();
            assert(self.authorized_contracts.read(caller), 'Unauthorized caller');
            assert(amount > 0, 'Invalid amount');
            assert(worker_payout_address.is_non_zero(), 'Invalid payout address');
            assert(auto_release_delay > 0, 'Invalid auto release delay');
            
            let current_time = get_block_timestamp();
            let escrow_id = self.next_escrow_id.read();
            self.next_escrow_id.write(escrow_id + 1);
            
            let platform_fee = self._calculate_platform_fee(amount);
            let total_required = amount + platform_fee;
            
            let erc20_token = IERC20Dispatcher { contract_address: token };
            erc20_token.transfer_from(employer, get_contract_address(), total_required);
            
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
                auto_release_at,
            });
            
            self.reentrancy_guard.end();
            escrow_id
        }

        fn release_payment(ref self: ContractState, escrow_id: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            let mut escrow = self.escrows.read(escrow_id);
            assert(escrow.id != 0, 'Escrow not found');
            assert(escrow.status == EscrowStatus::Active, 'Escrow not active');
            
            let is_authorized = self.authorized_contracts.read(caller) || 
                              caller == escrow.employer ||
                              (current_time >= escrow.auto_release_at && self.auto_release_enabled.read());
            
            assert(is_authorized, 'Unauthorized release');
            
            let erc20_token = IERC20Dispatcher { contract_address: escrow.token };
            
            erc20_token.transfer(escrow.worker_payout_address, escrow.amount);
            
            if escrow.platform_fee > 0 {
                erc20_token.transfer(self.fee_recipient.read(), escrow.platform_fee);
            }
            
            escrow.status = EscrowStatus::Released;
            self.escrows.write(escrow_id, escrow);
            
            if current_time >= escrow.auto_release_at {
                self.emit(AutoReleaseTriggered {
                    escrow_id,
                    worker_payout_address: escrow.worker_payout_address,
                    amount: escrow.amount,
                    trigger_timestamp: current_time,
                });
            }
            
            self.emit(PaymentReleased {
                escrow_id,
                job_id: escrow.job_id,
                worker_payout_address: escrow.worker_payout_address,
                amount: escrow.amount,
                platform_fee: escrow.platform_fee,
                released_by: caller,
                timestamp: current_time,
            });
            
            self.reentrancy_guard.end();
        }

        fn dispute_payment(ref self: ContractState, escrow_id: u256, reason: ByteArray) {
            self.pausable.assert_not_paused();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            let mut escrow = self.escrows.read(escrow_id);
            assert(escrow.id != 0, 'Escrow not found');
            assert(escrow.status == EscrowStatus::Active, 'Escrow not active');
            assert(caller == escrow.employer, 'Only employer can dispute');
            assert(current_time < escrow.dispute_deadline, 'Dispute period expired');
            
            if self.dispute_fee.read() > 0 {
                let erc20_token = IERC20Dispatcher { contract_address: escrow.token };
                erc20_token.transfer_from(caller, get_contract_address(), self.dispute_fee.read());
            }
            
            escrow.status = EscrowStatus::Disputed;
            self.escrows.write(escrow_id, escrow);
            
            self.emit(PaymentDisputed {
                escrow_id,
                job_id: escrow.job_id,
                disputed_by: caller,
                reason,
                dispute_deadline: escrow.dispute_deadline,
                timestamp: current_time,
            });
        }

        fn resolve_dispute(ref self: ContractState, escrow_id: u256, release_to_worker: bool) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            assert(
                caller == self.dispute_resolver.read() || 
                caller == self.owner() ||
                caller == self.emergency_multisig.read(),
                'Unauthorized resolver'
            );
            
            let mut escrow = self.escrows.read(escrow_id);
            assert(escrow.id != 0, 'Escrow not found');
            assert(escrow.status == EscrowStatus::Disputed, 'Escrow not disputed');
            
            let erc20_token = IERC20Dispatcher { contract_address: escrow.token };
            
            if release_to_worker {
                erc20_token.transfer(escrow.worker_payout_address, escrow.amount);
                if escrow.platform_fee > 0 {
                    erc20_token.transfer(self.fee_recipient.read(), escrow.platform_fee);
                }
                escrow.status = EscrowStatus::Released;
            } else {
                erc20_token.transfer(escrow.employer, escrow.amount + escrow.platform_fee);
                escrow.status = EscrowStatus::Refunded;
            }
            
            if self.dispute_fee.read() > 0 {
                if release_to_worker {
                    erc20_token.transfer(escrow.worker_payout_address, self.dispute_fee.read());
                } else {
                    erc20_token.transfer(escrow.employer, self.dispute_fee.read());
                }
            }
            
            self.escrows.write(escrow_id, escrow);
            
            self.emit(DisputeResolved {
                escrow_id,
                resolved_by: caller,
                release_to_worker,
                resolution_timestamp: current_time,
            });
            
            self.reentrancy_guard.end();
        }

        fn emergency_refund(ref self: ContractState, escrow_id: u256) {
            self.reentrancy_guard.start();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            assert(
                caller == self.owner() || 
                caller == self.emergency_multisig.read(),
                'Unauthorized emergency refund'
            );
            
            let mut escrow = self.escrows.read(escrow_id);
            assert(escrow.id != 0, 'Escrow not found');
            assert(escrow.status == EscrowStatus::Active, 'Escrow not active');
            
            let erc20_token = IERC20Dispatcher { contract_address: escrow.token };
            let total_amount = escrow.amount + escrow.platform_fee;
            erc20_token.transfer(escrow.employer, total_amount);
            
            escrow.status = EscrowStatus::Refunded;
            self.escrows.write(escrow_id, escrow);
            
            self.emit(EmergencyRefund {
                escrow_id,
                authorized_by: caller,
                refund_to: escrow.employer,
                amount: total_amount,
                timestamp: current_time,
            });
            
            self.reentrancy_guard.end();
        }

        fn get_escrow_details(self: @ContractState, escrow_id: u256) -> EscrowDetails {
            self.escrows.read(escrow_id)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _calculate_platform_fee(self: @ContractState, amount: u256) -> u256 {
            (amount * self.platform_fee_rate.read()) / 10000
        }

        fn _is_auto_release_ready(self: @ContractState, escrow: @EscrowDetails) -> bool {
            let current_time = get_block_timestamp();
            current_time >= escrow.auto_release_at && self.auto_release_enabled.read()
        }

        fn _is_dispute_expired(self: @ContractState, escrow: @EscrowDetails) -> bool {
            let current_time = get_block_timestamp();
            current_time > escrow.dispute_deadline
        }
    }

    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn authorize_contract(ref self: ContractState, contract_address: ContractAddress) {
            self.ownable.assert_only_owner();
            self.authorized_contracts.write(contract_address, true);
        }

        fn revoke_contract(ref self: ContractState, contract_address: ContractAddress) {
            self.ownable.assert_only_owner();
            self.authorized_contracts.write(contract_address, false);
        }

        fn set_dispute_resolver(ref self: ContractState, new_resolver: ContractAddress) {
            self.ownable.assert_only_owner();
            self.dispute_resolver.write(new_resolver);
        }

        fn set_dispute_fee(ref self: ContractState, new_fee: u256) {
            self.ownable.assert_only_owner();
            self.dispute_fee.write(new_fee);
        }

        fn set_platform_fee_rate(ref self: ContractState, new_rate: u256) {
            self.ownable.assert_only_owner();
            assert(new_rate <= 1000, 'Fee rate too high');
            self.platform_fee_rate.write(new_rate);
        }

        fn toggle_auto_release(ref self: ContractState) {
            self.ownable.assert_only_owner();
            let current_state = self.auto_release_enabled.read();
            self.auto_release_enabled.write(!current_state);
        }

        fn set_max_dispute_duration(ref self: ContractState, duration: u64) {
            self.ownable.assert_only_owner();
            assert(duration <= 90 * 86400, 'Duration too long');
            self.max_dispute_duration.write(duration);
        }

        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.unpause();
        }

        fn update_emergency_multisig(ref self: ContractState, new_multisig: ContractAddress) {
            self.ownable.assert_only_owner();
            self.emergency_multisig.write(new_multisig);
        }

        fn batch_auto_release(ref self: ContractState, escrow_ids: Array<u256>) {
            self.ownable.assert_only_owner();
            
            let mut i = 0;
            loop {
                if i >= escrow_ids.len() {
                    break;
                }
                let escrow_id = *escrow_ids.at(i);
                let escrow = self.escrows.read(escrow_id);
                
                if escrow.status == EscrowStatus::Active && self._is_auto_release_ready(@escrow) {
                    self.release_payment(escrow_id);
                }
                i += 1;
            };
        }
    }
}