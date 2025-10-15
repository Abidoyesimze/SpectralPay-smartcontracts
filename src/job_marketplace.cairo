// use starknet::ContractAddress;
use super::interfaces::{
    IJobMarketplace, JobDetails, WorkerApplication, JobStatus, ApplicationStatus, ZKProofComponents,
    ExtensionRequest, ExtensionRequestStatus, IEscrowDispatcher, IEscrowDispatcherTrait
};

#[starknet::contract]
mod JobMarketplace {
    use super::{IJobMarketplace, JobDetails, WorkerApplication, JobStatus, ApplicationStatus, ZKProofComponents,
                ExtensionRequest, ExtensionRequestStatus, IEscrowDispatcher, IEscrowDispatcherTrait};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess, Map};
    use core::num::traits::Zero;
    use core::pedersen;

    #[storage]
    struct Storage {
        jobs: Map<u256, JobDetails>,
        job_applications: Map<(u256, felt252), WorkerApplication>,
        job_applicant_count: Map<u256, u32>,
        job_applicants: Map<(u256, u32), felt252>,
        extension_requests: Map<(u256, felt252), ExtensionRequest>,
        job_extension_count: Map<u256, u32>,
        job_extensions: Map<(u256, u32), felt252>,
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
        ExtensionRequested: ExtensionRequested,
        ExtensionResponded: ExtensionResponded,
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

    #[derive(Drop, starknet::Event)]
    struct ExtensionRequested {
        #[key]
        job_id: u256,
        worker_pseudonym: felt252,
        requested_days: u64,
        reason: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct ExtensionResponded {
        #[key]
        job_id: u256,
        worker_pseudonym: felt252,
        approved: bool,
        response: ByteArray,
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
            work_deadline_days: u64,
        ) -> u256 {
            assert(!self.paused.read(), 'Contract paused');
            
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            
            // Comprehensive input validation
            assert(job_title.len() > 0, 'Job title cannot be empty');
            assert(job_title.len() <= 100, 'Job title too long');
            assert(job_description.len() > 0, 'Job description cannot be empty');
            assert(job_description.len() <= 1000, 'Job description too long');
            assert(required_skills_hash != 0, 'Invalid skills hash');
            assert(payment_amount > 0, 'Payment amount must be positive');
            assert(payment_amount <= 1000000000000000000000, 'Payment amount too large'); // Max 1000 ETH
            assert(work_deadline_days > 0, 'Deadline must be positive');
            assert(work_deadline_days <= 365, 'Deadline too long');
            
            // Calculate platform fee
            let platform_fee = self.calculate_platform_fee(payment_amount);
            let total_amount = payment_amount + platform_fee;
            
            // Note: In Starknet, ETH is the native token
            // The employer must send ETH with the transaction when calling post_job()
            // The contract will receive the ETH and hold it until the job is completed
            
            
            // Generate job ID
            let job_id = self.next_job_id.read();
            self.next_job_id.write(job_id + 1);
            
            // Create job - work_deadline will be set when worker is assigned
            let job = JobDetails {
                id: job_id,
                employer: caller,
                title: job_title.clone(),
                description: job_description,
                required_skills_hash: required_skills_hash,
                payment_amount: payment_amount,
                payment_token: Zero::zero(), // Native ETH
                work_deadline_days: work_deadline_days,
                work_deadline: 0,  // Will be set when worker is assigned
                status: JobStatus::Open,
                assigned_worker: 0,
                created_at: current_time,
                assigned_at: 0,  // Will be set when worker is assigned
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
            // Comprehensive input validation
            assert(job_id > 0, 'Invalid job ID');
            assert(worker_pseudonym != 0, 'Invalid worker pseudonym');
            assert(proposal_hash != 0, 'Invalid proposal hash');
            
            // Validate ZK proof structure
            let ZKProofComponents { proof_a, proof_b, proof_c, public_inputs } = skill_zk_proof;
            let (a_x, a_y) = proof_a;
            let ((b1_x, b1_y), (b2_x, b2_y)) = proof_b;
            let (c_x, c_y) = proof_c;
            let (p1, p2, p3, p4) = public_inputs;
            
            assert(a_x != 0 && a_y != 0, 'Invalid proof_a');
            assert(b1_x != 0 && b1_y != 0, 'Invalid proof_b1');
            assert(b2_x != 0 && b2_y != 0, 'Invalid proof_b2');
            assert(c_x != 0 && c_y != 0, 'Invalid proof_c');
            assert(p1 != 0 || p2 != 0 || p3 != 0 || p4 != 0, 'Invalid public inputs');
            
            assert(!self.paused.read(), 'Contract paused');
            
            let job = self.jobs.read(job_id);
            assert(job.status == JobStatus::Open, 'Job not open');
            
            // Check if already applied
            let existing_app = self.job_applications.read((job_id, worker_pseudonym));
            assert(existing_app.applied_at == 0, 'Already applied');
            
            // Create application with proper skill proof hashing
            let skill_proof_hash = self._hash_zk_proof(@skill_zk_proof);
            let application = WorkerApplication {
                worker_pseudonym: worker_pseudonym,
                skill_proof_hash: skill_proof_hash,
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
            assert(worker_payout_address.is_non_zero(), 'Invalid payout address');
            
            let application = self.job_applications.read((job_id, selected_worker));
            assert(application.status == ApplicationStatus::Pending, 'Invalid application');
            
            // Calculate platform fee
            let platform_fee = self.calculate_platform_fee(job.payment_amount);
            let total_amount = job.payment_amount + platform_fee;
            
            // Create escrow with proper deadline integration
            let auto_release_delay = job.work_deadline_days * 86400;
            
            // Create actual escrow and get escrow ID
            let escrow_dispatcher = IEscrowDispatcher { contract_address: self.escrow_contract.read() };
            let escrow_id = IEscrowDispatcherTrait::create_escrow(
                escrow_dispatcher,
                job_id, 
                job.employer, 
                selected_worker, 
                worker_payout_address, 
                job.payment_amount, 
                Zero::zero(), // Native ETH
                auto_release_delay
            );
            
            // Note: ETH transfer to escrow will be handled by the escrow contract
            // The escrow contract will receive ETH when it's created
            
            // Set the actual work deadline when worker is assigned
            let current_time = get_block_timestamp();
            let work_deadline = current_time + (job.work_deadline_days * 86400);
            
            // Update job
            let mut updated_job = job;
            updated_job.status = JobStatus::Assigned;
            updated_job.assigned_worker = selected_worker;
            updated_job.escrow_id = escrow_id;
            updated_job.work_deadline = work_deadline;
            updated_job.assigned_at = current_time;
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

        fn extend_deadline(
            ref self: ContractState,
            job_id: u256,
            additional_days: u64,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            
            let job = self.jobs.read(job_id);
            assert(job.employer == get_caller_address(), 'Not employer');
            assert(job.status == JobStatus::Assigned, 'Job not assigned');
            assert(additional_days > 0, 'Invalid additional days');
            assert(additional_days <= 30, 'Extension too long'); // Max 30 days extension
            
            // Check if current deadline hasn't passed
            let current_time = get_block_timestamp();
            let current_deadline = job.work_deadline;
            assert(current_deadline > current_time, 'Deadline already passed');
            
            // Extend the deadline
            let mut updated_job = job;
            updated_job.work_deadline = current_deadline + (additional_days * 86400);
            self.jobs.write(job_id, updated_job);
            
            // Note: We could emit an event here if needed
        }

        fn request_deadline_extension(
            ref self: ContractState,
            job_id: u256,
            requested_days: u64,
            reason: ByteArray,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            
            let job = self.jobs.read(job_id);
            assert(job.status == JobStatus::Assigned, 'Job not assigned');
            assert(requested_days > 0, 'Invalid requested days');
            assert(requested_days <= 30, 'Request too long'); // Max 30 days extension
            
            // Check if current deadline hasn't passed
            let current_time = get_block_timestamp();
            let current_deadline = job.work_deadline;
            assert(current_deadline > current_time, 'Deadline already passed');
            
            // Verify caller is the assigned worker
            let caller_pseudonym = get_caller_address().into();
            assert(job.assigned_worker == caller_pseudonym, 'Not assigned worker');
            
            // Check if there's already a pending request
            let existing_request = self.extension_requests.read((job_id, caller_pseudonym));
            assert(existing_request.status == ExtensionRequestStatus::Unknown, 'Request already exists');
            
            // Create extension request
            let request = ExtensionRequest {
                job_id: job_id,
                worker_pseudonym: caller_pseudonym,
                requested_days: requested_days,
                reason: reason.clone(),
                requested_at: current_time,
                status: ExtensionRequestStatus::Pending,
                employer_response: reason.clone(), // Temporary - will be updated when employer responds
                responded_at: 0,
            };
            
            self.extension_requests.write((job_id, caller_pseudonym), request);
            
            // Update extension count
            let extension_count = self.job_extension_count.read(job_id);
            self.job_extensions.write((job_id, extension_count), caller_pseudonym);
            self.job_extension_count.write(job_id, extension_count + 1);
            
            self.emit(ExtensionRequested {
                job_id: job_id,
                worker_pseudonym: caller_pseudonym,
                requested_days: requested_days,
                reason: reason,
            });
        }

        fn respond_to_extension_request(
            ref self: ContractState,
            job_id: u256,
            approve: bool,
            response: ByteArray,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            
            let job = self.jobs.read(job_id);
            assert(job.employer == get_caller_address(), 'Not employer');
            assert(job.status == JobStatus::Assigned, 'Job not assigned');
            
            // For simplicity, we'll respond to the first pending request
            // In a more complex system, you might want to specify which worker's request
            let extension_count = self.job_extension_count.read(job_id);
            let mut found_request = false;
            let mut i = 0;
            
            while i < extension_count {
                let worker_pseudonym = self.job_extensions.read((job_id, i));
                let mut request = self.extension_requests.read((job_id, worker_pseudonym));
                
                if request.status == ExtensionRequestStatus::Pending {
                    // Update request status
                    if approve {
                        request.status = ExtensionRequestStatus::Approved;
                        
                        // Extend the deadline
                        let current_time = get_block_timestamp();
                        let current_deadline = job.work_deadline;
                        let mut updated_job = job;
                        updated_job.work_deadline = current_deadline + (request.requested_days * 86400);
                        self.jobs.write(job_id, updated_job);
                    } else {
                        request.status = ExtensionRequestStatus::Rejected;
                    }
                    
                    request.employer_response = response.clone();
                    request.responded_at = get_block_timestamp();
                    self.extension_requests.write((job_id, worker_pseudonym), request);
                    
                    self.emit(ExtensionResponded {
                        job_id: job_id,
                        worker_pseudonym: worker_pseudonym,
                        approved: approve,
                        response: response,
                    });
                    
                    found_request = true;
                    break;
                };
                i += 1;
            };
            
            assert(found_request, 'No pending request found');
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

        fn get_extension_requests(self: @ContractState, job_id: u256) -> Array<ExtensionRequest> {
            let extension_count = self.job_extension_count.read(job_id);
            let mut requests = ArrayTrait::new();
            
            let mut i = 0;
            while i < extension_count {
                let _pseudonym = self.job_extensions.read((job_id, i));
                let request = self.extension_requests.read((job_id, _pseudonym));
                requests.append(request);
                i += 1;
            };
            
            requests
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

        fn _hash_zk_proof(self: @ContractState, proof: @ZKProofComponents) -> felt252 {
            let ZKProofComponents { proof_a, proof_b, proof_c, public_inputs } = proof;
            
            // Hash the proof components to create a unique identifier
            let (a_x, a_y) = *proof_a;
            let ((b1_x, b1_y), (b2_x, b2_y)) = *proof_b;
            let (c_x, c_y) = *proof_c;
            let (p1, p2, p3, p4) = *public_inputs;
            
            // Create a deterministic hash from all proof components
            let hash1 = pedersen::pedersen(a_x, a_y);
            let hash2 = pedersen::pedersen(b1_x, b1_y);
            let hash3 = pedersen::pedersen(b2_x, b2_y);
            let hash4 = pedersen::pedersen(c_x, c_y);
            let hash5 = pedersen::pedersen(p1, p2);
            let hash6 = pedersen::pedersen(p3, p4);
            
            let combined_hash1 = pedersen::pedersen(hash1, hash2);
            let combined_hash2 = pedersen::pedersen(hash3, hash4);
            let combined_hash3 = pedersen::pedersen(hash5, hash6);
            
            let final_hash1 = pedersen::pedersen(combined_hash1, combined_hash2);
            pedersen::pedersen(final_hash1, combined_hash3)
        }
    }

}