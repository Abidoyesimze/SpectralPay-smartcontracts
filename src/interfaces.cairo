use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store)]
struct JobDetails {
    id: u256,
    employer: ContractAddress,
    title: ByteArray,
    description: ByteArray,
    required_skills_hash: felt252,
    payment_amount: u256,
    payment_token: ContractAddress,
    deadline: u64,
    status: JobStatus,
    assigned_worker: felt252,
    created_at: u64,
    escrow_id: u256,
}

#[derive(Drop, Serde, starknet::Store)]
struct WorkerApplication {
    worker_pseudonym: felt252,
    skill_proof_hash: felt252,
    proposal_hash: felt252,
    applied_at: u64,
    status: ApplicationStatus,
}

#[derive(Drop, Serde, starknet::Store)]
struct WorkerProfile {
    pseudonym: felt252,
    owner_commitment: felt252,
    skills_commitment: felt252,
    reputation_score: u32,
    completed_jobs: u32,
    total_earnings: u256,
    registration_timestamp: u64,
    reputation_bond: u256,
    is_active: bool,
}

#[derive(Drop, Serde, starknet::Store)]
struct SkillProof {
    skill_type_hash: felt252,
    skill_level: SkillLevel,
    proof_data: Array<felt252>,
    verification_key: felt252,
    proof_timestamp: u64,
    is_verified: bool,
}

#[derive(Drop, Serde, starknet::Store)]
struct EscrowDetails {
    id: u256,
    job_id: u256,
    employer: ContractAddress,
    worker_pseudonym: felt252,
    worker_payout_address: ContractAddress,
    amount: u256,
    token: ContractAddress,
    status: EscrowStatus,
    created_at: u64,
    auto_release_at: u64,
    dispute_deadline: u64,
    platform_fee: u256,
}

#[derive(Drop, Serde, starknet::Store)]
struct ZKProofComponents {
    proof_a: (felt252, felt252),
    proof_b: ((felt252, felt252), (felt252, felt252)),
    proof_c: (felt252, felt252),
    public_inputs: Array<felt252>,
}

#[derive(Drop, Serde, starknet::Store)]
enum JobStatus {
    Open,
    Assigned,
    Submitted,
    Completed,
    Disputed,
    Cancelled,
}

#[derive(Drop, Serde, starknet::Store)]
enum ApplicationStatus {
    Pending,
    Accepted,
    Rejected,
}

#[derive(Drop, Serde, starknet::Store)]
enum EscrowStatus {
    Active,
    Released,
    Disputed,
    Refunded,
}

#[derive(Drop, Serde, starknet::Store)]
enum SkillLevel {
    Beginner,
    Intermediate,
    Advanced,
    Expert,
}

#[starknet::interface]
trait IJobMarketplace<TContractState> {
    fn post_job(
        ref self: TContractState,
        job_title: ByteArray,
        job_description: ByteArray,
        required_skills_hash: felt252,
        payment_amount: u256,
        deadline: u64,
        payment_token: ContractAddress
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
    fn get_job_details(self: @TContractState, job_id: u256) -> JobDetails;
    fn get_worker_applications(self: @TContractState, job_id: u256) -> Array<WorkerApplication>;
}

#[starknet::interface]
trait IPseudonymRegistry<TContractState> {
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
trait IEscrow<TContractState> {
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
trait IZKVerifier<TContractState> {
    fn verify_skill_proof(
        self: @TContractState,
        skill_type_hash: felt252,
        required_level: SkillLevel,
        zk_proof: ZKProofComponents,
        verification_key: felt252
    ) -> bool;
    
    fn verify_identity_proof(
        self: @TContractState,
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