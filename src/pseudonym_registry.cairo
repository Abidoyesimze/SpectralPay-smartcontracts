use starknet::ContractAddress;
use super::interfaces::{
    IPseudonymRegistry, IZKVerifier, WorkerProfile, SkillProof, 
    ZKProofComponents, SkillLevel
};

#[starknet::contract]
mod PseudonymRegistry {
    use super::{
        IPseudonymRegistry, IZKVerifier, WorkerProfile, SkillProof, 
        ZKProofComponents, SkillLevel
    };
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::reentrancy_guard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl ReentrancyGuardImpl = ReentrancyGuardComponent::ReentrancyGuardImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        worker_profiles: LegacyMap<felt252, WorkerProfile>,
        worker_skill_proofs: LegacyMap<(felt252, felt252), SkillProof>,
        pseudonym_skill_count: LegacyMap<felt252, u32>,
        pseudonym_to_recovery_hash: LegacyMap<felt252, felt252>,
        nonce_tracker: LegacyMap<felt252, u256>,
        reputation_history: LegacyMap<(felt252, u256), i32>,
        last_activity: LegacyMap<felt252, u64>,
        reputation_bond_token: ContractAddress,
        min_reputation_bond: u256,
        max_reputation_score: u32,
        zk_verifier_contract: ContractAddress,
        authorized_updaters: LegacyMap<ContractAddress, bool>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PseudonymRegistered: PseudonymRegistered,
        SkillProofAdded: SkillProofAdded,
        SkillVerified: SkillVerified,
        ReputationUpdated: ReputationUpdated,
        PseudonymRecovered: PseudonymRecovered,
        SkillRequirementVerified: SkillRequirementVerified,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct PseudonymRegistered {
        #[key]
        pseudonym: felt252,
        registration_timestamp: u64,
        initial_reputation: u32,
    }

    #[derive(Drop, starknet::Event)]
    struct SkillProofAdded {
        #[key]
        pseudonym: felt252,
        #[key]
        skill_type_hash: felt252,
        skill_level: SkillLevel,
        proof_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct SkillVerified {
        #[key]
        pseudonym: felt252,
        #[key]
        skill_type_hash: felt252,
        verifier: ContractAddress,
        verification_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ReputationUpdated {
        #[key]
        pseudonym: felt252,
        old_score: u32,
        new_score: u32,
        score_delta: i32,
        job_id: u256,
        updated_by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct PseudonymRecovered {
        #[key]
        pseudonym: felt252,
        recovery_timestamp: u64,
        new_owner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct SkillRequirementVerified {
        #[key]
        pseudonym: felt252,
        #[key]
        required_skill_hash: felt252,
        verification_success: bool,
        timestamp: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        reputation_bond_token: ContractAddress,
        min_reputation_bond: u256,
        zk_verifier_contract: ContractAddress
    ) {
        self.ownable.initializer(owner);
        self.reputation_bond_token.write(reputation_bond_token);
        self.min_reputation_bond.write(min_reputation_bond);
        self.max_reputation_score.write(1000);
        self.zk_verifier_contract.write(zk_verifier_contract);
    }

    #[abi(embed_v0)]
    impl PseudonymRegistryImpl of IPseudonymRegistry<ContractState> {
        fn register_pseudonym(
            ref self: ContractState,
            pseudonym: felt252,
            identity_commitment: felt252,
            skills_commitment: felt252,
            reputation_bond: u256
        ) {
            self.reentrancy_guard.start();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            assert(pseudonym != 0, 'Invalid pseudonym');
            assert(self.worker_profiles.read(pseudonym).pseudonym == 0, 'Pseudonym taken');
            assert(reputation_bond >= self.min_reputation_bond.read(), 'Bond too low');
            assert(identity_commitment != 0, 'Invalid identity commitment');
            assert(skills_commitment != 0, 'Invalid skills commitment');
            
            let bond_token = IERC20Dispatcher {
                contract_address: self.reputation_bond_token.read()
            };
            bond_token.transfer_from(caller, get_contract_address(), reputation_bond);
            
            let profile = WorkerProfile {
                pseudonym,
                owner_commitment: identity_commitment,
                skills_commitment,
                reputation_score: 100,
                completed_jobs: 0,
                total_earnings: 0,
                registration_timestamp: current_time,
                reputation_bond,
                is_active: true,
            };
            
            self.worker_profiles.write(pseudonym, profile);
            self.last_activity.write(pseudonym, current_time);
            
            let recovery_hash = pedersen::pedersen(caller.into(), pseudonym);
            self.pseudonym_to_recovery_hash.write(pseudonym, recovery_hash);
            
            self.emit(PseudonymRegistered {
                pseudonym,
                registration_timestamp: current_time,
                initial_reputation: 100,
            });
            
            self.reentrancy_guard.end();
        }

        fn add_skill_proof(
            ref self: ContractState,
            pseudonym: felt252,
            skill_type_hash: felt252,
            skill_level: SkillLevel,
            zk_proof: ZKProofComponents,
            verification_key: felt252
        ) {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            let profile = self.worker_profiles.read(pseudonym);
            assert(profile.pseudonym != 0, 'Pseudonym not found');
            assert(profile.is_active, 'Pseudonym inactive');
            
            assert(
                self._verify_pseudonym_ownership(pseudonym, caller, @zk_proof),
                'Pseudonym ownership verification failed'
            );
            
            let verifier = IZKVerifierDispatcher {
                contract_address: self.zk_verifier_contract.read()
            };
            
            let skill_verified = verifier.verify_skill_proof(
                skill_type_hash,
                skill_level,
                zk_proof,
                verification_key
            );
            
            assert(skill_verified, 'Skill proof verification failed');
            
            let skill_proof = SkillProof {
                skill_type_hash,
                skill_level,
                proof_data: zk_proof.public_inputs,
                verification_key,
                proof_timestamp: current_time,
                is_verified: true,
            };
            
            self.worker_skill_proofs.write((pseudonym, skill_type_hash), skill_proof);
            
            let current_count = self.pseudonym_skill_count.read(pseudonym);
            self.pseudonym_skill_count.write(pseudonym, current_count + 1);
            
            self.last_activity.write(pseudonym, current_time);
            
            self.emit(SkillProofAdded {
                pseudonym,
                skill_type_hash,
                skill_level,
                proof_timestamp: current_time,
            });
        }

        fn verify_skill_requirement(
            ref self: ContractState,
            pseudonym: felt252,
            required_skill_hash: felt252,
            zk_proof: ZKProofComponents
        ) -> bool {
            let current_time = get_block_timestamp();
            
            let profile = self.worker_profiles.read(pseudonym);
            if profile.pseudonym == 0 || !profile.is_active {
                self.emit(SkillRequirementVerified {
                    pseudonym,
                    required_skill_hash,
                    verification_success: false,
                    timestamp: current_time,
                });
                return false;
            }
            
            let stored_skill_proof = self.worker_skill_proofs.read((pseudonym, required_skill_hash));
            if stored_skill_proof.skill_type_hash != 0 && stored_skill_proof.is_verified {
                self.emit(SkillRequirementVerified {
                    pseudonym,
                    required_skill_hash,
                    verification_success: true,
                    timestamp: current_time,
                });
                return true;
            }
            
            let verifier = IZKVerifierDispatcher {
                contract_address: self.zk_verifier_contract.read()
            };
            
            let verification_result = if stored_skill_proof.verification_key != 0 {
                verifier.verify_skill_proof(
                    required_skill_hash,
                    stored_skill_proof.skill_level,
                    zk_proof,
                    stored_skill_proof.verification_key
                )
            } else {
                self._verify_skills_commitment(pseudonym, required_skill_hash, @zk_proof)
            };
            
            self.emit(SkillRequirementVerified {
                pseudonym,
                required_skill_hash,
                verification_success: verification_result,
                timestamp: current_time,
            });
            
            verification_result
        }

        fn update_reputation(
            ref self: ContractState,
            pseudonym: felt252,
            score_delta: i32,
            job_id: u256
        ) {
            let caller = get_caller_address();
            assert(self.authorized_updaters.read(caller), 'Unauthorized reputation update');
            
            let mut profile = self.worker_profiles.read(pseudonym);
            assert(profile.pseudonym != 0, 'Pseudonym not found');
            
            let old_score = profile.reputation_score;
            
            if score_delta >= 0 {
                let delta_u32: u32 = score_delta.try_into().unwrap();
                profile.reputation_score = if profile.reputation_score + delta_u32 > self.max_reputation_score.read() {
                    self.max_reputation_score.read()
                } else {
                    profile.reputation_score + delta_u32
                };
            } else {
                let abs_delta: u32 = (-score_delta).try_into().unwrap();
                profile.reputation_score = if profile.reputation_score > abs_delta {
                    profile.reputation_score - abs_delta
                } else {
                    0
                };
            }
            
            if score_delta > 0 {
                profile.completed_jobs += 1;
            }
            
            self.worker_profiles.write(pseudonym, profile);
            self.reputation_history.write((pseudonym, job_id), score_delta);
            self.last_activity.write(pseudonym, get_block_timestamp());
            
            self.emit(ReputationUpdated {
                pseudonym,
                old_score,
                new_score: profile.reputation_score,
                score_delta,
                job_id,
                updated_by: caller,
            });
        }

        fn prove_pseudonym_ownership(
            ref self: ContractState,
            pseudonym: felt252,
            ownership_proof: ZKProofComponents
        ) -> bool {
            let caller = get_caller_address();
            
            let profile = self.worker_profiles.read(pseudonym);
            if profile.pseudonym == 0 {
                return false;
            }
            
            let verifier = IZKVerifierDispatcher {
                contract_address: self.zk_verifier_contract.read()
            };
            
            verifier.verify_identity_proof(
                pseudonym,
                profile.owner_commitment,
                ownership_proof
            )
        }

        fn get_worker_profile(self: @ContractState, pseudonym: felt252) -> WorkerProfile {
            self.worker_profiles.read(pseudonym)
        }

        fn is_pseudonym_registered(self: @ContractState, pseudonym: felt252) -> bool {
            let profile = self.worker_profiles.read(pseudonym);
            profile.pseudonym != 0 && profile.is_active
        }

        fn get_skill_proofs(self: @ContractState, pseudonym: felt252) -> Array<SkillProof> {
            array![]
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _verify_pseudonym_ownership(
            self: @ContractState,
            pseudonym: felt252,
            caller: ContractAddress,
            zk_proof: @ZKProofComponents
        ) -> bool {
            let profile = self.worker_profiles.read(pseudonym);
            if profile.pseudonym == 0 {
                return false;
            }
            
            let verifier = IZKVerifierDispatcher {
                contract_address: self.zk_verifier_contract.read()
            };
            
            verifier.verify_identity_proof(
                pseudonym,
                profile.owner_commitment,
                *zk_proof
            )
        }

        fn _verify_skills_commitment(
            self: @ContractState,
            pseudonym: felt252,
            required_skill_hash: felt252,
            zk_proof: @ZKProofComponents
        ) -> bool {
            let profile = self.worker_profiles.read(pseudonym);
            if profile.pseudonym == 0 {
                return false;
            }
            
            let ZKProofComponents { proof_a, proof_b, proof_c, public_inputs } = zk_proof;
            
            if public_inputs.len() < 2 {
                return false;
            }
            
            let skill_commitment = *public_inputs.at(0);
            let skill_hash = *public_inputs.at(1);
            
            let expected_commitment = pedersen::pedersen(profile.skills_commitment, skill_hash);
            skill_commitment == expected_commitment && skill_hash == required_skill_hash
        }
    }

    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn authorize_updater(ref self: ContractState, updater: ContractAddress) {
            self.ownable.assert_only_owner();
            self.authorized_updaters.write(updater, true);
        }

        fn revoke_updater(ref self: ContractState, updater: ContractAddress) {
            self.ownable.assert_only_owner();
            self.authorized_updaters.write(updater, false);
        }

        fn update_min_bond(ref self: ContractState, new_min_bond: u256) {
            self.ownable.assert_only_owner();
            self.min_reputation_bond.write(new_min_bond);
        }

        fn emergency_disable_pseudonym(ref self: ContractState, pseudonym: felt252) {
            self.ownable.assert_only_owner();
            let mut profile = self.worker_profiles.read(pseudonym);
            profile.is_active = false;
            self.worker_profiles.write(pseudonym, profile);
        }
    }
}