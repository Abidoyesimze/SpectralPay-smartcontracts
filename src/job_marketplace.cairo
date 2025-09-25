use starknet::ContractAddress;
use super::interfaces::{
    IJobMarketplace, IPseudonymRegistry, IEscrow, JobDetails, WorkerApplication,
    JobStatus, ApplicationStatus, ZKProofComponents
};

#[starknet::contract]
mod JobMarketplace {
    use super::{
        IJobMarketplace, IPseudonymRegistry, IEscrow, JobDetails, WorkerApplication,
        JobStatus, ApplicationStatus, ZKProofComponents
    };
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp, get_contract_address
    };
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::pausable::PausableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        jobs: LegacyMap<u256, JobDetails>,
        job_applications: LegacyMap<(u256, felt252), WorkerApplication>,
        job_applicant_count: LegacyMap<u256, u32>,
        job_applicants: LegacyMap<(u256, u32), felt252>,
        next_job_id: u256,
        platform_fee_rate: u256,
        fee_recipient: ContractAddress,
        pseudonym_registry: ContractAddress,
        escrow_contract: ContractAddress,
        min_job_amount: u256,
        max_deadline_days: u64,
        min_reputation_required: u32,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        JobPosted: JobPosted,
        JobApplicationSubmitted: JobApplicationSubmitted,
        JobAssigned: JobAssigned,
        WorkSubmitted: WorkSubmitted,
        JobCompleted: JobCompleted,
        JobDisputed: JobDisputed,
        JobCancelled: JobCancelled,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct JobPosted {
        #[key]
        job_id: u256,
        #[key]
        employer: ContractAddress,
        payment_amount: u256,
        deadline: u64,
        required_skills_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct JobApplicationSubmitted {
        #[key]
        job_id: u256,
        #[key]
        worker_pseudonym: felt252,
        applied_at: u64,
        skill_proof_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct JobAssigned {
        #[key]
        job_id: u256,
        #[key]
        worker_pseudonym: felt252,
        escrow_id: u256,
        assignment_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct WorkSubmitted {
        #[key]
        job_id: u256,
        #[key]
        worker_pseudonym: felt252,
        submission_timestamp: u64,
        work_proof_hash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct JobCompleted {
        #[key]
        job_id: u256,
        #[key]
        worker_pseudonym: felt252,
        payment_amount: u256,
        completion_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct JobDisputed {
        #[key]
        job_id: u256,
        disputed_by: ContractAddress,
        reason: ByteArray,
        dispute_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct JobCancelled {
        #[key]
        job_id: u256,
        cancelled_by: ContractAddress,
        reason: ByteArray,
        cancellation_timestamp: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        pseudonym_registry: ContractAddress,
        escrow_contract: ContractAddress,
        platform_fee_rate: u256,
        fee_recipient: ContractAddress
    ) {
        self.ownable.initializer(owner);
        self.pseudonym_registry.write(pseudonym_registry);
        self.escrow_contract.write(escrow_contract);
        self.platform_fee_rate.write(platform_fee_rate);
        self.fee_recipient.write(fee_recipient);
        self.next_job_id.write(1);
        self.min_job_amount.write(1000000000000000);
        self.max_deadline_days.write(365);
        self.min_reputation_required.write(50);
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
            payment_token: ContractAddress
        ) -> u256 {
            self.pausable.assert_not_paused();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            assert(payment_amount >= self.min_job_amount.read(), 'Payment too low');
            assert(deadline > current_time, 'Invalid deadline');
            assert(deadline - current_time <= self.max_deadline_days.read() * 86400, 'Deadline too far');
            assert(job_title.len() > 0, 'Title required');
            assert(job_description.len() > 0, 'Description required');
            assert(required_skills_hash != 0, 'Skills hash required');
            
            let job_id = self.next_job_id.read();
            self.next_job_id.write(job_id + 1);
            
            let job = JobDetails {
                id: job_id,
                employer: caller,
                title: job_title,
                description: job_description,
                required_skills_hash,
                payment_amount,
                payment_token,
                deadline,
                status: JobStatus::Open,
                assigned_worker: 0,
                created_at: current_time,
                escrow_id: 0,
            };
            
            self.jobs.write(job_id, job);
            
            self.emit(JobPosted {
                job_id,
                employer: caller,
                payment_amount,
                deadline,
                required_skills_hash,
            });
            
            job_id
        }

        fn apply_for_job(
            ref self: ContractState,
            job_id: u256,
            worker_pseudonym: felt252,
            skill_zk_proof: ZKProofComponents,
            proposal_hash: felt252
        ) {
            self.pausable.assert_not_paused();
            
            let current_time = get_block_timestamp();
            let job = self.jobs.read(job_id);
            
            assert(job.id != 0, 'Job not found');
            assert(job.status == JobStatus::Open, 'Job not open');
            assert(current_time < job.deadline, 'Job expired');
            
            let registry = IPseudonymRegistryDispatcher {
                contract_address: self.pseudonym_registry.read()
            };
            
            assert(registry.is_pseudonym_registered(worker_pseudonym), 'Pseudonym not registered');
            
            let existing_app = self.job_applications.read((job_id, worker_pseudonym));
            assert(existing_app.worker_pseudonym == 0, 'Already applied');
            
            let worker_profile = registry.get_worker_profile(worker_pseudonym);
            assert(worker_profile.reputation_score >= self.min_reputation_required.read(), 'Insufficient reputation');
            assert(worker_profile.is_active, 'Worker inactive');
            
            assert(
                registry.verify_skill_requirement(
                    worker_pseudonym,
                    job.required_skills_hash,
                    skill_zk_proof
                ),
                'Skill verification failed'
            );
            
            let skill_proof_hash = self._hash_zk_proof(@skill_zk_proof);
            
            let application = WorkerApplication {
                worker_pseudonym,
                skill_proof_hash,
                proposal_hash,
                applied_at: current_time,
                status: ApplicationStatus::Pending,
            };
            
            self.job_applications.write((job_id, worker_pseudonym), application);
            
            let applicant_count = self.job_applicant_count.read(job_id);
            self.job_applicants.write((job_id, applicant_count), worker_pseudonym);
            self.job_applicant_count.write(job_id, applicant_count + 1);
            
            self.emit(JobApplicationSubmitted {
                job_id,
                worker_pseudonym,
                applied_at: current_time,
                skill_proof_hash,
            });
        }

        fn assign_job(
            ref self: ContractState,
            job_id: u256,
            selected_worker: felt252,
            worker_payout_address: ContractAddress
        ) {
            self.pausable.assert_not_paused();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            let mut job = self.jobs.read(job_id);
            assert(job.id != 0, 'Job not found');
            assert(job.employer == caller, 'Not job owner');
            assert(job.status == JobStatus::Open, 'Job not open');
            
            let application = self.job_applications.read((job_id, selected_worker));
            assert(application.worker_pseudonym != 0, 'No application found');
            assert(application.status == ApplicationStatus::Pending, 'Application not pending');
            
            let escrow = IEscrowDispatcher {
                contract_address: self.escrow_contract.read()
            };
            
            let platform_fee = (job.payment_amount * self.platform_fee_rate.read()) / 10000;
            let worker_amount = job.payment_amount - platform_fee;
            
            let escrow_id = escrow.create_escrow(
                job_id,
                job.employer,
                selected_worker,
                worker_payout_address,
                worker_amount,
                job.payment_token,
                7 * 86400
            );
            
            job.status = JobStatus::Assigned;
            job.assigned_worker = selected_worker;
            job.escrow_id = escrow_id;
            self.jobs.write(job_id, job);
            
            let mut application = self.job_applications.read((job_id, selected_worker));
            application.status = ApplicationStatus::Accepted;
            self.job_applications.write((job_id, selected_worker), application);
            
            self._reject_other_applications(job_id, selected_worker);
            
            self.emit(JobAssigned {
                job_id,
                worker_pseudonym: selected_worker,
                escrow_id,
                assignment_timestamp: current_time,
            });
        }

        fn submit_work(
            ref self: ContractState,
            job_id: u256,
            work_proof_hash: felt252,
            submission_uri: ByteArray
        ) {
            self.pausable.assert_not_paused();
            
            let current_time = get_block_timestamp();
            let mut job = self.jobs.read(job_id);
            
            assert(job.id != 0, 'Job not found');
            assert(job.status == JobStatus::Assigned, 'Job not assigned');
            assert(current_time < job.deadline, 'Job deadline passed');
            
            let registry = IPseudonymRegistryDispatcher {
                contract_address: self.pseudonym_registry.read()
            };
            
            let caller = get_caller_address();
            
            job.status = JobStatus::Submitted;
            self.jobs.write(job_id, job);
            
            self.emit(WorkSubmitted {
                job_id,
                worker_pseudonym: job.assigned_worker,
                submission_timestamp: current_time,
                work_proof_hash,
            });
        }

        fn approve_work(ref self: ContractState, job_id: u256) {
            self.pausable.assert_not_paused();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            let mut job = self.jobs.read(job_id);
            assert(job.id != 0, 'Job not found');
            assert(job.employer == caller, 'Not job owner');
            assert(job.status == JobStatus::Submitted, 'Work not submitted');
            
            let escrow = IEscrowDispatcher {
                contract_address: self.escrow_contract.read()
            };
            escrow.release_payment(job.escrow_id);
            
            let registry = IPseudonymRegistryDispatcher {
                contract_address: self.pseudonym_registry.read()
            };
            registry.update_reputation(job.assigned_worker, 10, job_id);
            
            let platform_fee = (job.payment_amount * self.platform_fee_rate.read()) / 10000;
            if platform_fee > 0 {
                let fee_token = IERC20Dispatcher { contract_address: job.payment_token };
                fee_token.transfer_from(caller, self.fee_recipient.read(), platform_fee);
            }
            
            job.status = JobStatus::Completed;
            self.jobs.write(job_id, job);
            
            self.emit(JobCompleted {
                job_id,
                worker_pseudonym: job.assigned_worker,
                payment_amount: job.payment_amount - platform_fee,
                completion_timestamp: current_time,
            });
        }

        fn dispute_work(ref self: ContractState, job_id: u256, reason: ByteArray) {
            self.pausable.assert_not_paused();
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            let mut job = self.jobs.read(job_id);
            assert(job.id != 0, 'Job not found');
            assert(job.employer == caller, 'Not job owner');
            assert(job.status == JobStatus::Submitted, 'Work not submitted');
            
            let escrow = IEscrowDispatcher {
                contract_address: self.escrow_contract.read()
            };
            escrow.dispute_payment(job.escrow_id, reason.clone());
            
            job.status = JobStatus::Disputed;
            self.jobs.write(job_id, job);
            
            self.emit(JobDisputed {
                job_id,
                disputed_by: caller,
                reason,
                dispute_timestamp: current_time,
            });
        }

        fn get_job_details(self: @ContractState, job_id: u256) -> JobDetails {
            self.jobs.read(job_id)
        }

        fn get_worker_applications(self: @ContractState, job_id: u256) -> Array<WorkerApplication> {
            let mut applications = array![];
            let applicant_count = self.job_applicant_count.read(job_id);
            
            let mut i = 0;
            loop {
                if i >= applicant_count {
                    break;
                }
                let pseudonym = self.job_applicants.read((job_id, i));
                let application = self.job_applications.read((job_id, pseudonym));
                applications.append(application);
                i += 1;
            };
            
            applications
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _hash_zk_proof(self: @ContractState, proof: @ZKProofComponents) -> felt252 {
            let ZKProofComponents { proof_a, proof_b, proof_c, public_inputs } = proof;
            let (a_x, a_y) = *proof_a;
            let (c_x, c_y) = *proof_c;
            
            let proof_hash = pedersen::pedersen(a_x, a_y);
            let proof_hash = pedersen::pedersen(proof_hash, c_x);
            pedersen::pedersen(proof_hash, c_y)
        }

        fn _reject_other_applications(ref self: ContractState, job_id: u256, selected_worker: felt252) {
            let applicant_count = self.job_applicant_count.read(job_id);
            
            let mut i = 0;
            loop {
                if i >= applicant_count {
                    break;
                }
                let pseudonym = self.job_applicants.read((job_id, i));
                if pseudonym != selected_worker {
                    let mut application = self.job_applications.read((job_id, pseudonym));
                    application.status = ApplicationStatus::Rejected;
                    self.job_applications.write((job_id, pseudonym), application);
                }
                i += 1;
            };
        }

        fn _calculate_platform_fee(self: @ContractState, amount: u256) -> u256 {
            (amount * self.platform_fee_rate.read()) / 10000
        }
    }

    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn set_platform_fee(ref self: ContractState, new_rate: u256) {
            self.ownable.assert_only_owner();
            assert(new_rate <= 1000, 'Fee too high');
            self.platform_fee_rate.write(new_rate);
        }

        fn set_min_job_amount(ref self: ContractState, new_amount: u256) {
            self.ownable.assert_only_owner();
            self.min_job_amount.write(new_amount);
        }

        fn set_min_reputation(ref self: ContractState, new_min: u32) {
            self.ownable.assert_only_owner();
            self.min_reputation_required.write(new_min);
        }

        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.unpause();
        }

        fn cancel_job(ref self: ContractState, job_id: u256, reason: ByteArray) {
            self.ownable.assert_only_owner();
            
            let mut job = self.jobs.read(job_id);
            assert(job.id != 0, 'Job not found');
            
            if job.status == JobStatus::Assigned {
                let escrow = IEscrowDispatcher {
                    contract_address: self.escrow_contract.read()
                };
                escrow.emergency_refund(job.escrow_id);
            }
            
            job.status = JobStatus::Cancelled;
            self.jobs.write(job_id, job);
            
            self.emit(JobCancelled {
                job_id,
                cancelled_by: get_caller_address(),
                reason,
                cancellation_timestamp: get_block_timestamp(),
            });
        }
    }
}