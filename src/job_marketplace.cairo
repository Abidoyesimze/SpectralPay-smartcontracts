// use starknet::ContractAddress;
use super::interfaces::{
    IJobMarketplace, JobDetails, WorkerApplication, JobStatus, ApplicationStatus, ZKProofComponents
};

#[starknet::contract]
mod JobMarketplace {
    use super::{IJobMarketplace, JobDetails, WorkerApplication, JobStatus, ApplicationStatus, ZKProofComponents};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess, Map};
    // use core::num::traits::Zero;

    #[storage]
    struct Storage {
        jobs: Map<u256, JobDetails>,
        job_applications: Map<(u256, felt252), WorkerApplication>,
        job_applicant_count: Map<u256, u32>,
        job_applicants: Map<(u256, u32), felt252>,
        pseudonym_registry: ContractAddress,
        escrow_contract: ContractAddress,
        platform_fee_rate: u256,
        fee_recipient: ContractAddress,
        next_job_id: u256,
        min_job_amount: u256,
        max_deadline_days: u64,
        min_reputation_required: u32,
        owner: ContractAddress,
        paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        JobPosted: JobPosted,
        ApplicationSubmitted: ApplicationSubmitted,
        WorkerSelected: WorkerSelected,
        WorkSubmitted: WorkSubmitted,
        JobCompleted: JobCompleted,
        JobDisputed: JobDisputed,
    }

    #[derive(Drop, starknet::Event)]
    struct JobPosted {
        #[key]
        job_id: u256,
        employer: ContractAddress,
        title: ByteArray,
        payment_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct ApplicationSubmitted {
        #[key]
        job_id: u256,
        worker_pseudonym: felt252,
        proposal_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct WorkerSelected {
        #[key]
        job_id: u256,
        worker_pseudonym: felt252,
        escrow_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct WorkSubmitted {
        #[key]
        job_id: u256,
        worker_pseudonym: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct JobCompleted {
        #[key]
        job_id: u256,
        worker_pseudonym: felt252,
        payment_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct JobDisputed {
        #[key]
        job_id: u256,
        reason: ByteArray,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        pseudonym_registry: ContractAddress,
        escrow_contract: ContractAddress,
        platform_fee_rate: u256,
        fee_recipient: ContractAddress,
    ) {
        self.owner.write(owner);
        self.pseudonym_registry.write(pseudonym_registry);
        self.escrow_contract.write(escrow_contract);
        self.platform_fee_rate.write(platform_fee_rate);
        self.fee_recipient.write(fee_recipient);
        self.next_job_id.write(1);
        self.min_job_amount.write(1000000000000000);
        self.max_deadline_days.write(365);
        self.min_reputation_required.write(50);
        self.paused.write(false);
    }


    #[abi(embed_v0)]
    impl JobMarketplaceImpl of IJobMarketplace<ContractState> {
        fn post_job(
            ref self: ContractState,
            job_title: ByteArray,
            job_description: ByteArray,
            required_skills_hash: felt252,
            payment_amount: u256,
            deadline: u64,
            payment_token: ContractAddress,
        ) -> u256 {
            assert(!self.paused.read(), 'Contract paused');
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            // Validate inputs
            assert(payment_amount >= self.min_job_amount.read(), 'Payment too low');
            assert(deadline > current_time, 'Invalid deadline');
            assert(deadline - current_time <= self.max_deadline_days.read() * 86400, 'Deadline too far');
            
            // Generate job ID
            let job_id = self.next_job_id.read();
            self.next_job_id.write(job_id + 1);
            
            // Create job
            let job = JobDetails {
                id: job_id,
                employer: caller,
                title: job_title.clone(),
                description: job_description,
                required_skills_hash: required_skills_hash,
                payment_amount: payment_amount,
                payment_token: payment_token,
                deadline: deadline,
                status: JobStatus::Open,
                assigned_worker: 0,
                created_at: current_time,
                escrow_id: 0,
            };
            
            self.jobs.write(job_id, job);
            
            self.emit(JobPosted {
                job_id: job_id,
                employer: caller,
                title: job_title,
                payment_amount: payment_amount,
            });
            
            job_id
        }

        fn apply_for_job(
            ref self: ContractState,
            job_id: u256,
            worker_pseudonym: felt252,
            skill_zk_proof: ZKProofComponents,
            proposal_hash: felt252,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            
            let job = self.jobs.read(job_id);
            assert(job.status == JobStatus::Open, 'Job not open');
            
            // Check if already applied
            let existing_app = self.job_applications.read((job_id, worker_pseudonym));
            assert(existing_app.applied_at == 0, 'Already applied');
            
            // Create application
            let application = WorkerApplication {
                worker_pseudonym: worker_pseudonym,
                skill_proof_hash: 0, // Placeholder - would hash the zk_proof
                proposal_hash: proposal_hash,
                applied_at: get_block_timestamp(),
                status: ApplicationStatus::Pending,
            };
            
            self.job_applications.write((job_id, worker_pseudonym), application);
            
            // Update applicant count
            let applicant_count = self.job_applicant_count.read(job_id);
            self.job_applicants.write((job_id, applicant_count), worker_pseudonym);
            self.job_applicant_count.write(job_id, applicant_count + 1);
            
            self.emit(ApplicationSubmitted {
                job_id: job_id,
                worker_pseudonym: worker_pseudonym,
                proposal_hash: proposal_hash,
            });
        }

        fn assign_job(
            ref self: ContractState,
            job_id: u256,
            selected_worker: felt252,
            worker_payout_address: ContractAddress,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            
            let mut job = self.jobs.read(job_id);
            assert(job.employer == get_caller_address(), 'Not employer');
            assert(job.status == JobStatus::Open, 'Job not open');
            
            let application = self.job_applications.read((job_id, selected_worker));
            assert(application.status == ApplicationStatus::Pending, 'Invalid application');
            
            // Create escrow (simplified - no actual escrow creation for now)
            let escrow_id = 1; // Placeholder
            
            // Update job
            let mut updated_job = job;
            updated_job.status = JobStatus::Assigned;
            updated_job.assigned_worker = selected_worker;
            updated_job.escrow_id = escrow_id;
            self.jobs.write(job_id, updated_job);
            
            // Update application
            let mut updated_application = application;
            updated_application.status = ApplicationStatus::Accepted;
            self.job_applications.write((job_id, selected_worker), updated_application);
            
            self.emit(WorkerSelected {
                job_id: job_id,
                worker_pseudonym: selected_worker,
                escrow_id: escrow_id,
            });
        }

        fn submit_work(
            ref self: ContractState,
            job_id: u256,
            work_proof_hash: felt252,
            submission_uri: ByteArray,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            
            let mut job = self.jobs.read(job_id);
            assert(job.assigned_worker == get_caller_address().into(), 'Not assigned worker');
            assert(job.status == JobStatus::Assigned, 'Job not assigned');
            
            let worker_pseudonym = job.assigned_worker;
            let mut updated_job = job;
            updated_job.status = JobStatus::Submitted;
            self.jobs.write(job_id, updated_job);
            
            self.emit(WorkSubmitted {
                job_id: job_id,
                worker_pseudonym: worker_pseudonym,
            });
        }

        fn approve_work(ref self: ContractState, job_id: u256) {
            assert(!self.paused.read(), 'Contract paused');
            
            let mut job = self.jobs.read(job_id);
            assert(job.employer == get_caller_address(), 'Not employer');
            assert(job.status == JobStatus::Submitted, 'Work not submitted');
            
            let worker_pseudonym = job.assigned_worker;
            let payment_amount = job.payment_amount;
            let mut updated_job = job;
            updated_job.status = JobStatus::Completed;
            self.jobs.write(job_id, updated_job);
            
            self.emit(JobCompleted {
                job_id: job_id,
                worker_pseudonym: worker_pseudonym,
                payment_amount: payment_amount,
            });
        }


        fn dispute_work(
            ref self: ContractState,
            job_id: u256,
            reason: ByteArray,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            
            let mut job = self.jobs.read(job_id);
            assert(job.employer == get_caller_address(), 'Not employer');
            assert(job.status == JobStatus::Submitted, 'Work not submitted');
            
            let mut updated_job = job;
            updated_job.status = JobStatus::Disputed;
            self.jobs.write(job_id, updated_job);
            
            self.emit(JobDisputed {
                job_id: job_id,
                reason: reason,
            });
        }

        fn get_job_details(self: @ContractState, job_id: u256) -> JobDetails {
            self.jobs.read(job_id)
        }

        fn get_worker_applications(self: @ContractState, job_id: u256) -> Array<WorkerApplication> {
            let applicant_count = self.job_applicant_count.read(job_id);
            let mut applications = ArrayTrait::new();
            
            let mut i = 0;
            while i < applicant_count {
                let _pseudonym = self.job_applicants.read((job_id, i));
                let application = self.job_applications.read((job_id, _pseudonym));
                applications.append(application);
                i += 1;
            };
            
            applications
        }
    }

    // Administrative functions
    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn set_platform_fee_rate(ref self: ContractState, new_rate: u256) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.platform_fee_rate.write(new_rate);
        }

        fn set_min_job_amount(ref self: ContractState, new_amount: u256) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.min_job_amount.write(new_amount);
        }

        fn set_min_reputation_required(ref self: ContractState, new_min: u32) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.min_reputation_required.write(new_min);
        }

        fn set_max_deadline_days(ref self: ContractState, new_days: u64) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.max_deadline_days.write(new_days);
        }

        fn pause(ref self: ContractState) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.paused.write(true);
        }

        fn unpause(ref self: ContractState) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            self.paused.write(false);
        }

        fn cancel_job(ref self: ContractState, job_id: u256) {
            assert(self.owner.read() == get_caller_address(), 'Only owner');
            
            let mut job = self.jobs.read(job_id);
            assert(job.status == JobStatus::Open, 'Cannot cancel');
            
            let mut updated_job = job;
            updated_job.status = JobStatus::Cancelled;
            self.jobs.write(job_id, updated_job);
        }
    }

    // Helper functions
    #[generate_trait]
    impl HelperImpl of HelperTrait {
        fn calculate_platform_fee(self: @ContractState, amount: u256) -> u256 {
            (amount * self.platform_fee_rate.read()) / 10000
        }
    }

}