use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store)]
pub struct JobDetails {
    pub id: u256,
    pub employer: ContractAddress,
    pub title: ByteArray,
    pub description: ByteArray,
    pub required_skills_hash: felt252,
    pub payment_amount: u256,
    pub payment_token: ContractAddress,
    pub work_deadline_days: u64,  // Duration in days for work completion
    pub work_deadline: u64,       // Actual deadline timestamp (set when worker assigned)
    pub status: JobStatus,
    pub assigned_worker: felt252,
    pub created_at: u64,
    pub assigned_at: u64,         // When worker was assigned
    pub escrow_id: u256,
}

#[derive(Drop, Serde, starknet::Store, Copy)]
pub struct WorkerApplication {
    pub worker_pseudonym: felt252,
    pub skill_proof_hash: felt252,
    pub proposal_hash: felt252,
    pub applied_at: u64,
    pub status: ApplicationStatus,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct ExtensionRequest {
    pub job_id: u256,
    pub worker_pseudonym: felt252,
    pub requested_days: u64,
    pub reason: ByteArray,
    pub requested_at: u64,
    pub status: ExtensionRequestStatus,
    pub employer_response: ByteArray,
    pub responded_at: u64,
}

#[derive(Drop, Serde, starknet::Store, Copy)]
pub struct WorkerProfile {
    pub pseudonym: felt252,
    pub owner_commitment: felt252,
    pub skills_commitment: felt252,
    pub reputation_score: u32,
    pub completed_jobs: u32,
    pub total_earnings: u256,
    pub registration_timestamp: u64,
    pub reputation_bond: u256,
    pub is_active: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct SkillProof {
    pub skill_type_hash: felt252,
    pub skill_level: SkillLevel,
    pub proof_data: (felt252, felt252, felt252, felt252), // Fixed size tuple instead of Array
    pub verification_key: felt252,
    pub proof_timestamp: u64,
    pub is_verified: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct EscrowDetails {
    pub id: u256,
    pub job_id: u256,
    pub employer: ContractAddress,
    pub worker_pseudonym: felt252,
    pub worker_payout_address: ContractAddress,
    pub amount: u256,
    pub token: ContractAddress,
    pub status: EscrowStatus,
    pub created_at: u64,
    pub auto_release_at: u64,
    pub dispute_deadline: u64,
    pub platform_fee: u256,
}

#[derive(Drop, Serde, starknet::Store, Copy)]
pub struct ZKProofComponents {
    pub proof_a: (felt252, felt252),
    pub proof_b: ((felt252, felt252), (felt252, felt252)),
    pub proof_c: (felt252, felt252),
    pub public_inputs: (felt252, felt252, felt252, felt252), // Fixed size tuple instead of Array
}

#[derive(Drop, Serde, starknet::Store, Copy, PartialEq)]
pub enum JobStatus {
    #[default]
    Unknown,
    Open,
    Assigned,
    Submitted,
    Completed,
    Disputed,
    Cancelled,
}

#[derive(Drop, Serde, starknet::Store, Copy, PartialEq)]
pub enum ApplicationStatus {
    #[default]
    Unknown,
    Pending,
    Accepted,
    Rejected,
}

#[derive(Drop, Serde, starknet::Store, Copy, PartialEq)]
pub enum ExtensionRequestStatus {
    #[default]
    Unknown,
    Pending,
    Approved,
    Rejected,
}

#[derive(Drop, Serde, starknet::Store, PartialEq)]
pub enum EscrowStatus {
    #[default]
    Unknown,
    Active,
    Released,
    Disputed,
    Refunded,
}

#[derive(Drop, Serde, starknet::Store, Copy, PartialEq)]
pub enum SkillLevel {
    #[default]
    Unknown,
    Beginner,
    Intermediate,
    Advanced,
    Expert,
}

#[starknet::interface]
pub trait IJobMarketplace<TContractState> {
    fn post_job(
        ref self: TContractState,
        job_title: ByteArray,
        job_description: ByteArray,
        required_skills_hash: felt252,
        payment_amount: u256,
        work_deadline_days: u64
    ) -> u256;
    
    fn apply_for_job(
        ref self: TContractState,
        job_id: u256,
        worker_pseudonym: felt252,
        skill_zk_proof: ZKProofComponents,
        proposal_hash: felt252
    );
    
    fn assign_job(
        ref self: TContractState,
        job_id: u256,
        selected_worker: felt252,
        worker_payout_address: ContractAddress
    );
    
    fn submit_work(
        ref self: TContractState,
        job_id: u256,
        work_proof_hash: felt252,
        submission_uri: ByteArray
    );
    
    fn approve_work(ref self: TContractState, job_id: u256);
    fn dispute_work(ref self: TContractState, job_id: u256, reason: ByteArray);
    fn extend_deadline(ref self: TContractState, job_id: u256, additional_days: u64);
    fn request_deadline_extension(ref self: TContractState, job_id: u256, requested_days: u64, reason: ByteArray);
    fn respond_to_extension_request(ref self: TContractState, job_id: u256, approve: bool, response: ByteArray);
    fn get_job_details(self: @TContractState, job_id: u256) -> JobDetails;
    fn get_worker_applications(self: @TContractState, job_id: u256) -> Array<WorkerApplication>;
    fn get_extension_requests(self: @TContractState, job_id: u256) -> Array<ExtensionRequest>;
}

#[starknet::interface]
pub trait IPseudonymRegistry<TContractState> {
    fn register_pseudonym(
        ref self: TContractState,
        pseudonym: felt252,
        identity_commitment: felt252,
        skills_commitment: felt252,
        reputation_bond: u256
    );
    
    fn add_skill_proof(
        ref self: TContractState,
        pseudonym: felt252,
        skill_type_hash: felt252,
        skill_level: SkillLevel,
        zk_proof: ZKProofComponents,
        verification_key: felt252
    );
    
    fn verify_skill_requirement(
        ref self: TContractState,
        pseudonym: felt252,
        required_skill_hash: felt252,
        zk_proof: ZKProofComponents
    ) -> bool;
    
    fn update_reputation(
        ref self: TContractState,
        pseudonym: felt252,
        score_delta: i32,
        job_id: u256
    );
    
    fn prove_pseudonym_ownership(
        ref self: TContractState,
        pseudonym: felt252,
        ownership_proof: ZKProofComponents
    ) -> bool;
    
    fn get_worker_profile(self: @TContractState, pseudonym: felt252) -> WorkerProfile;
    fn is_pseudonym_registered(self: @TContractState, pseudonym: felt252) -> bool;
    fn get_skill_proofs(self: @TContractState, pseudonym: felt252) -> Array<SkillProof>;
}

#[starknet::interface]
pub trait IEscrow<TContractState> {
    fn create_escrow(
        ref self: TContractState,
        job_id: u256,
        employer: ContractAddress,
        worker_pseudonym: felt252,
        worker_payout_address: ContractAddress,
        amount: u256,
        token: ContractAddress,
        auto_release_delay: u64
    ) -> u256;
    
    fn release_payment(ref self: TContractState, escrow_id: u256);
    fn dispute_payment(ref self: TContractState, escrow_id: u256, reason: ByteArray);
    fn resolve_dispute(ref self: TContractState, escrow_id: u256, release_to_worker: bool);
    fn emergency_refund(ref self: TContractState, escrow_id: u256);
    fn get_escrow_details(self: @TContractState, escrow_id: u256) -> EscrowDetails;
}

#[starknet::interface]
pub trait IZKVerifier<TContractState> {
    fn verify_skill_proof(
        ref self: TContractState,
        skill_type_hash: felt252,
        required_level: SkillLevel,
        zk_proof: ZKProofComponents,
        verification_key: felt252
    ) -> bool;
    
    fn verify_identity_proof(
        ref self: TContractState,
        pseudonym: felt252,
        identity_commitment: felt252,
        zk_proof: ZKProofComponents
    ) -> bool;
    
    fn add_verification_key(
        ref self: TContractState,
        skill_type_hash: felt252,
        verification_key: felt252
    );
    
    fn is_valid_verification_key(
        self: @TContractState,
        skill_type_hash: felt252,
        verification_key: felt252
    ) -> bool;
}


#[starknet::interface]
pub trait AdminTrait<TContractState> {
    fn authorize_contract(ref self: TContractState, contract_address: ContractAddress);
    fn revoke_contract(ref self: TContractState, contract_address: ContractAddress);
    fn set_dispute_resolver(ref self: TContractState, new_resolver: ContractAddress);
    fn set_dispute_fee(ref self: TContractState, new_fee: u256);
    fn set_platform_fee_rate(ref self: TContractState, new_rate: u256);
    fn toggle_auto_release(ref self: TContractState);
    fn set_max_dispute_duration(ref self: TContractState, duration: u64);
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn set_emergency_multisig(ref self: TContractState, new_multisig: ContractAddress);
}
