package FServe::Transfer::Coordinator;

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();
use Digest::SHA ();
use Fcntl qw(O_RDONLY);
use File::Spec;
use IO::Handle ();
use Time::HiRes ();
use FServe::ConnectionIdentity qw(tuple_key);
use FServe::Transfer::Journal;
use FServe::Transfer::Resume qw(capture_partial consume_resumed_file_verification);
use FServe::Transfer::Job qw(new_job clone_job transition_job resume_binding_fingerprint resume_partial_fingerprint job_identity_key tuple_keys_for_job is_terminal unfinished_count validate_job);

our @EXPORT_OK = qw(open_coordinator);
our $MAX_UNFINISHED = 100;
our $MAX_RESERVED_TUPLES = 10_000;
our $MAX_RECENT_TERMINAL_JOBS = 100;
our $MAX_JOB_IDENTITIES = 10_000;
our $MAX_COMPACTION_AUDIT_EVENTS = 100_000;
my $RESUME_ADMISSION_TOKEN = {};
my $RESUME_FINALIZATION_TOKEN = {};
my $RESUME_PUBLICATION_TOKEN = {};

sub _same_path {
    my ($left, $right) = @_;
    return 0 unless defined($left) && defined($right) &&
        !ref($left) && !ref($right);
    return File::Spec->canonpath(File::Spec->rel2abs($left)) eq
        File::Spec->canonpath(File::Spec->rel2abs($right));
}

sub _resume_verification_matches_intent {
    my ($verification, $intent) = @_;
    return 0 unless ref($verification) eq 'HASH' && ref($intent) eq 'HASH';
    my %allowed = map { $_ => 1 } qw(
        schema_version attempt_id path staging_root offset total_size
        partial_sha256 expected_sha256 sha256 prefix_sha256 writer_closed
        identity directory_identities
    );
    return 0 if grep { !$allowed{$_} } keys %$verification;
    return 0 if grep { !exists($verification->{$_}) } keys %allowed;
    return 0 unless defined($verification->{schema_version}) &&
        !ref($verification->{schema_version}) &&
        $verification->{schema_version} eq '1' &&
        defined($verification->{writer_closed}) &&
        !ref($verification->{writer_closed}) &&
        $verification->{writer_closed} eq '1';
    return 0 unless defined($verification->{attempt_id}) &&
        $verification->{attempt_id} eq $intent->{attempt_id} &&
        _same_path($verification->{path}, $intent->{snapshot_path}) &&
        _same_path($verification->{staging_root}, $intent->{staging_root}) &&
        defined($verification->{offset}) &&
        "$verification->{offset}" eq "$intent->{offset}" &&
        defined($verification->{total_size}) &&
        "$verification->{total_size}" eq "$intent->{total_size}" &&
        defined($verification->{partial_sha256}) &&
        $verification->{partial_sha256} eq $intent->{partial_sha256} &&
        defined($verification->{prefix_sha256}) &&
        $verification->{prefix_sha256} eq $intent->{partial_sha256} &&
        defined($verification->{expected_sha256}) &&
        $verification->{expected_sha256} eq $intent->{expected_sha256} &&
        defined($verification->{sha256}) &&
        $verification->{sha256} eq $intent->{expected_sha256};
    my $identity = $verification->{identity};
    my $snapshot = $intent->{snapshot_identity};
    return 0 unless ref($identity) eq 'HASH' && ref($snapshot) eq 'HASH';
    my %identity_fields = map { $_ => 1 } qw(device inode mode links size mtime ctime);
    return 0 if grep { !$identity_fields{$_} } keys %$identity;
    return 0 if grep { !exists($identity->{$_}) } keys %identity_fields;
    return 0 if grep { !defined($identity->{$_}) || ref($identity->{$_}) ||
        $identity->{$_} !~ /\A-?\d+(?:\.\d+)?\z/ } keys %identity_fields;
    return 0 unless "$identity->{device}" eq "$snapshot->{device}" &&
        "$identity->{inode}" eq "$snapshot->{inode}" &&
        "$identity->{links}" eq '1' && ($identity->{mode} & 0777) == 0600 &&
        "$identity->{size}" eq "$intent->{total_size}";
    return 0 unless ref($verification->{directory_identities}) eq 'ARRAY' &&
        ref($intent->{snapshot_directory_identities}) eq 'ARRAY' &&
        JSON::PP->new->canonical(1)->encode($verification->{directory_identities}) eq
            JSON::PP->new->canonical(1)->encode($intent->{snapshot_directory_identities});
    return 1;
}

sub _resume_finalization_binding_matches {
    my ($finalization, $intent) = @_;
    return 0 unless ref($finalization) eq 'HASH' &&
        _resume_verification_matches_intent(
            $finalization->{resume_verification}, $intent) &&
        _same_path($finalization->{staging_path},
            $finalization->{resume_verification}{path}) &&
        defined($finalization->{destination_path}) &&
        !ref($finalization->{destination_path}) &&
        length($finalization->{destination_path}) &&
        defined($finalization->{expected_size}) &&
        "$finalization->{expected_size}" eq
            "$finalization->{resume_verification}{total_size}" &&
        defined($finalization->{expected_sha256}) &&
        lc($finalization->{expected_sha256}) eq
            $finalization->{resume_verification}{expected_sha256};
}

sub _same_resume_finalization_binding {
    my ($left, $right) = @_;
    return 0 unless ref($left) eq 'HASH' && ref($right) eq 'HASH';
    for my $field (qw(staging_path destination_path expected_size expected_sha256)) {
        return 0 unless defined($left->{$field}) && defined($right->{$field}) &&
            "$left->{$field}" eq "$right->{$field}";
    }
    return 0 unless ref($left->{resume_verification}) eq 'HASH' &&
        ref($right->{resume_verification}) eq 'HASH';
    return JSON::PP->new->canonical(1)->encode($left->{resume_verification}) eq
        JSON::PP->new->canonical(1)->encode($right->{resume_verification});
}

sub _json_boolean_value {
    my ($value) = @_;
    return unless defined($value) &&
        (!ref($value) || ref($value) eq 'JSON::PP::Boolean') &&
        ("$value" eq '0' || "$value" eq '1');
    return "$value" eq '1' ? 1 : 0;
}

sub _resume_publication_success_evidence_error {
    my ($finalization) = @_;
    return 'resumed job completion lacks a finalization record'
        unless ref($finalization) eq 'HASH';
    return 'resumed job completion lacks a successful publication result'
        unless ($finalization->{status} // '') =~ /\A(?:published|reconciled_complete)\z/ &&
            ref($finalization->{result}) eq 'HASH';

    my $result = $finalization->{result};
    return 'resumed job completion publication result is not successful'
        unless _json_boolean_value($result->{success}) &&
            defined($result->{destination_path}) &&
            _same_path($result->{destination_path}, $finalization->{destination_path}) &&
            defined($result->{observed_size}) &&
            "$result->{observed_size}" eq "$finalization->{expected_size}" &&
            defined($result->{observed_sha256}) &&
            lc($result->{observed_sha256}) eq lc($finalization->{expected_sha256});

    my $evidence = $result->{publication_evidence};
    return 'resumed job completion lacks durable publication evidence'
        unless ref($evidence) eq 'HASH';
    my %allowed = map { $_ => 1 } qw(
        schema_version method destination_path device inode size sha256
        content_verified payload_synced directory_synced
    );
    return 'resumed job completion publication evidence is malformed'
        if (grep { !$allowed{$_} } keys %$evidence) ||
            (grep { !exists($evidence->{$_}) } keys %allowed);

    my $expected_method = $finalization->{status} eq 'published'
        ? 'exclusive_hard_link' : 'recovery_verified';
    return 'resumed job publication evidence has an invalid schema version'
        unless defined($evidence->{schema_version}) &&
            !ref($evidence->{schema_version}) &&
            "$evidence->{schema_version}" eq '1';
    return 'resumed job publication evidence has the wrong method'
        unless defined($evidence->{method}) && !ref($evidence->{method}) &&
            $evidence->{method} eq $expected_method;
    return 'resumed job publication evidence has the wrong destination'
        unless defined($evidence->{destination_path}) &&
            _same_path($evidence->{destination_path}, $finalization->{destination_path});
    return 'resumed job publication evidence has an invalid file identity'
        unless defined($evidence->{device}) && !ref($evidence->{device}) &&
            $evidence->{device} =~ /\A\d+\z/ &&
            defined($evidence->{inode}) && !ref($evidence->{inode}) &&
            $evidence->{inode} =~ /\A\d+\z/;
    return 'resumed job publication evidence has the wrong size'
        unless defined($evidence->{size}) && !ref($evidence->{size}) &&
            "$evidence->{size}" eq "$finalization->{expected_size}";
    return 'resumed job publication evidence has the wrong digest'
        unless defined($evidence->{sha256}) && !ref($evidence->{sha256}) &&
            lc($evidence->{sha256}) eq lc($finalization->{expected_sha256});
    return 'resumed job publication evidence lacks successful verification and sync flags'
        unless _json_boolean_value($evidence->{content_verified}) &&
            _json_boolean_value($evidence->{payload_synced}) &&
            _json_boolean_value($evidence->{directory_synced});

    if ($expected_method eq 'exclusive_hard_link') {
        my $verified_identity = $finalization->{resume_verification}{identity};
        return 'resumed job publication evidence does not identify the verified staging inode'
            unless ref($verified_identity) eq 'HASH' &&
                "$evidence->{device}" eq "$verified_identity->{device}" &&
                "$evidence->{inode}" eq "$verified_identity->{inode}";
    }
    return;
}

sub _resume_publication_failure_result_matches_intent {
    my ($finalization, $intent) = @_;
    return 0 unless ref($finalization) eq 'HASH' &&
        ref($intent) eq 'HASH' &&
        ($finalization->{status} // '') eq 'unresolved' &&
        _resume_finalization_binding_matches($finalization, $intent) &&
        ref($finalization->{result}) eq 'HASH';
    my $result = $finalization->{result};
    my $success = _json_boolean_value($result->{success});
    return 0 unless defined($success) && !$success &&
        defined($result->{destination_path}) &&
        _same_path($result->{destination_path},
            $finalization->{destination_path}) &&
        defined($result->{reason}) && !ref($result->{reason}) &&
        !exists($result->{publication_evidence});
    return 1;
}

sub _same_resume_publication_result {
    my ($left, $right) = @_;
    return 0 unless ref($left) eq 'HASH' && ref($right) eq 'HASH' &&
        _json_boolean_value($left->{success}) &&
        _json_boolean_value($right->{success}) &&
        defined($left->{destination_path}) &&
        _same_path($left->{destination_path}, $right->{destination_path}) &&
        defined($left->{observed_size}) && defined($right->{observed_size}) &&
        "$left->{observed_size}" eq "$right->{observed_size}" &&
        defined($left->{observed_sha256}) && defined($right->{observed_sha256}) &&
        lc($left->{observed_sha256}) eq lc($right->{observed_sha256});
    my $left_proof = $left->{publication_evidence};
    my $right_proof = $right->{publication_evidence};
    return 0 unless ref($left_proof) eq 'HASH' && ref($right_proof) eq 'HASH';
    for my $field (qw(schema_version method device inode size sha256
            content_verified payload_synced directory_synced)) {
        return 0 unless defined($left_proof->{$field}) &&
            defined($right_proof->{$field}) &&
            "$left_proof->{$field}" eq "$right_proof->{$field}";
    }
    return _same_path($left_proof->{destination_path},
        $right_proof->{destination_path});
}

sub _resume_job_finalization_error {
    my ($job, $reservation) = @_;
    return unless ref($job) eq 'HASH';
    if (exists $job->{resume_intent}) {
        if (ref($job->{finalization}) eq 'HASH') {
            return 'resume job transition has an invalid finalization binding'
                unless _resume_finalization_binding_matches(
                    $job->{finalization}, $job->{resume_intent}) &&
                    ref($reservation) eq 'HASH' &&
                    _same_resume_finalization_binding(
                        $job->{finalization}, $reservation);
            if (($job->{state} // '') eq 'complete') {
                my $evidence_error = _resume_publication_success_evidence_error(
                    $job->{finalization});
                return $evidence_error if defined $evidence_error;
                return 'resumed published completion lacks its durable success record'
                    if $job->{finalization}{status} eq 'published' &&
                        ref($reservation->{result}) ne 'HASH';
                if (ref($reservation->{result}) eq 'HASH') {
                    return 'resumed completion transition differs from durable publication evidence'
                        unless _same_resume_publication_result(
                            $job->{finalization}{result}, $reservation->{result});
                }
            }
        } elsif (($job->{state} // '') eq 'finalizing' ||
                ($job->{state} // '') eq 'complete') {
            return 'resume job advanced without a verified finalization reservation';
        }
    } elsif (ref($job->{finalization}) eq 'HASH' &&
            exists $job->{finalization}{resume_verification}) {
        return 'ordinary job transition contains resume verification evidence';
    }
    return;
}

sub _same_trusted_content_digest {
    my ($left, $right) = @_;
    my $left_has = exists($left->{trusted_content_digest});
    my $right_has = exists($right->{trusted_content_digest});
    return 0 if $left_has != $right_has;
    return 1 unless $left_has;
    return JSON::PP->new->canonical(1)->encode($left->{trusted_content_digest}) eq
        JSON::PP->new->canonical(1)->encode($right->{trusted_content_digest});
}

sub _same_resume_intent {
    my ($left, $right) = @_;
    my $left_has = exists($left->{resume_intent});
    my $right_has = exists($right->{resume_intent});
    return 0 if $left_has != $right_has;
    return 1 unless $left_has;
    return JSON::PP->new->canonical(1)->encode($left->{resume_intent}) eq
        JSON::PP->new->canonical(1)->encode($right->{resume_intent});
}

sub _resume_intent_matches_prior {
    my (%args) = @_;
    my ($job, $intent) = @args{qw(job)};
    $intent = $job->{resume_intent} if ref($job) eq 'HASH';
    return 0 unless ref($job) eq 'HASH' && ref($intent) eq 'HASH' &&
        !$args{previous_had_intent} &&
        ($args{previous_state} // '') eq 'interrupted' &&
        ($job->{state} // '') eq 'resume_pending' &&
        ($job->{outcome} // '') eq 'resume_intent_durable' &&
        defined($args{previous_binding}) &&
        $intent->{job_binding_sha256} eq $args{previous_binding} &&
        resume_binding_fingerprint($job) eq $args{previous_binding} &&
        defined($args{previous_partial_binding}) &&
        $intent->{partial_binding_sha256} eq $args{previous_partial_binding} &&
        defined(resume_partial_fingerprint($job->{partial})) &&
        resume_partial_fingerprint($job->{partial}) eq $args{previous_partial_binding} &&
        defined($args{previous_lifecycle_identity}) &&
        defined($job->{accepted_lifecycle}) &&
        "$intent->{previous_lifecycle_identity}" eq
            "$args{previous_lifecycle_identity}" &&
        "$job->{accepted_lifecycle}" eq "$args{previous_lifecycle_identity}";
    my $peer = $intent->{sender};
    my $basename = $intent->{offered_basename};
    my $tuple = tuple_key(network_profile => $job->{network_profile},
        peer => $peer, basename => $basename,
        casemapping => $job->{context}{casemapping});
    my $owner = defined($tuple) ? $args{tuple_owners}{$tuple} : undef;
    $owner = $owner->{job_id} if ref($owner) eq 'HASH';
    return defined($owner) && $owner eq $job->{id} ? 1 : 0;
}

sub _compacted_resume_pending_snapshot_details {
    my ($job) = @_;
    my $intent = $job->{resume_intent} || {};
    return {
        job_id => $job->{id},
        state => $job->{state},
        outcome => $job->{outcome},
        accepted_lifecycle => $job->{accepted_lifecycle},
        previous_lifecycle_identity => $intent->{previous_lifecycle_identity},
        job_binding_sha256 => $intent->{job_binding_sha256},
        current_job_binding_sha256 => resume_binding_fingerprint($job),
        partial_binding_sha256 => $intent->{partial_binding_sha256},
        current_partial_binding_sha256 =>
            resume_partial_fingerprint($job->{partial}),
        tuple => tuple_key(network_profile => $job->{network_profile},
            peer => $intent->{sender}, basename => $intent->{offered_basename},
            casemapping => $job->{context}{casemapping}),
    };
}

sub _compacted_resume_pending_snapshot_is_valid {
    my ($details, $tuple_owners) = @_;
    return 0 unless ref($details) eq 'HASH' && ref($tuple_owners) eq 'HASH' &&
        ($details->{state} // '') eq 'resume_pending' &&
        ($details->{outcome} // '') eq 'resume_intent_durable' &&
        defined($details->{job_id}) &&
        defined($details->{job_binding_sha256}) &&
        defined($details->{current_job_binding_sha256}) &&
        $details->{job_binding_sha256} eq $details->{current_job_binding_sha256} &&
        defined($details->{partial_binding_sha256}) &&
        defined($details->{current_partial_binding_sha256}) &&
        $details->{partial_binding_sha256} eq
            $details->{current_partial_binding_sha256} &&
        defined($details->{previous_lifecycle_identity}) &&
        defined($details->{accepted_lifecycle}) &&
        "$details->{previous_lifecycle_identity}" eq
            "$details->{accepted_lifecycle}" &&
        defined($details->{tuple});
    my $owner = $tuple_owners->{$details->{tuple}};
    $owner = $owner->{job_id} if ref($owner) eq 'HASH';
    return defined($owner) && $owner eq $details->{job_id} ? 1 : 0;
}

sub _validate_compacted_resume_pending_snapshots {
    my ($self) = @_;
    for my $id (keys %{$self->{compacted_resume_pending_snapshots} || {}}) {
        die "compacted resume_pending snapshot lacks consistent admission evidence ($id)"
            unless _compacted_resume_pending_snapshot_is_valid(
                $self->{compacted_resume_pending_snapshots}{$id},
                $self->{tuples});
    }
}

sub _trusted_content_digest_fingerprint {
    my ($job) = @_;
    return unless exists $job->{trusted_content_digest};
    return JSON::PP->new->canonical(1)->encode($job->{trusted_content_digest});
}

sub open_coordinator {
    my (%args) = @_;
    my $self = bless {
        jobs => {},
        terminal_jobs => {},
        terminal_order => [],
        job_ids => {},
        job_lifecycle => {},
        job_identity => {},
        web_operation_jobs => {},
        tuples => {},
        tuple_count => 0,
        finalizations => {},
        stop_intents => {},
        recovery => [],
        compacted_resume_pending_snapshots => {},
        closed => 0,
    }, __PACKAGE__;
    my $journal = FServe::Transfer::Journal->open_store(
        path => $args{path},
        max_record_bytes => $args{max_record_bytes},
        max_journal_bytes => $args{max_journal_bytes},
        on_event => sub { $self->_replay_event($_[0]); },
    );
    $self->{journal} = $journal;
    $self->_validate_compacted_resume_pending_snapshots();
    $self->_recover_abandoned_jobs();
    return $self;
}

sub _retain_job {
    my ($self, $job) = @_;
    my $id = $job->{id};
    if (is_terminal($job->{state})) {
        delete $self->{jobs}{$id};
        delete $self->{terminal_jobs}{$id};
        @{$self->{terminal_order}} = grep { $_ ne $id } @{$self->{terminal_order}};
        $self->{terminal_jobs}{$id} = clone_job($job);
        push @{$self->{terminal_order}}, $id;
        while (@{$self->{terminal_order}} > $MAX_RECENT_TERMINAL_JOBS) {
            my $expired = shift @{$self->{terminal_order}};
            delete $self->{terminal_jobs}{$expired};
            delete $self->{finalizations}{$expired};
        }
    } else {
        delete $self->{terminal_jobs}{$id};
        $self->{jobs}{$id} = clone_job($job);
    }
}

sub _replay_event {
    my ($self, $record) = @_;
    my $event = $record->{event};
    my $data = $record->{data};
    if ($event eq 'job_created' || $event eq 'job_transition') {
        my $job = $data->{job};
        validate_job($job);
        my $id = $job->{id};
        my $web_operation_id = $job->{context}{web_operation_id};
        if (defined $web_operation_id) {
            die 'job has an invalid web operation identity'
                unless $web_operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
            die 'journal repeats a web operation identity'
                if exists($self->{web_operation_jobs}{$web_operation_id}) &&
                    $self->{web_operation_jobs}{$web_operation_id} ne $id;
            $self->{web_operation_jobs}{$web_operation_id} = $id;
        }
        die "journal repeats job creation without a transition ($id)"
            if $event eq 'job_created' && $self->{job_ids}{$id};
            if ($event eq 'job_created') {
                my $compacted_resume_snapshot =
                    exists($data->{compacted_resume_snapshot}) &&
                    defined($data->{compacted_resume_snapshot}) &&
                    !ref($data->{compacted_resume_snapshot}) &&
                    "$data->{compacted_resume_snapshot}" eq '1';
                die "journal has an invalid compacted resume snapshot marker ($id)"
                    if exists($data->{compacted_resume_snapshot}) &&
                        !$compacted_resume_snapshot;
                die "journal creates a resume job outside a validated compacted snapshot ($id)"
                    if ($job->{state} eq 'resume_pending' ||
                            exists($job->{resume_intent})) &&
                        (!$compacted_resume_snapshot ||
                            !exists($job->{resume_intent}));
                die "journal marks a non-resume creation as a compacted resume snapshot ($id)"
                    if $compacted_resume_snapshot && !exists($job->{resume_intent});
                if (ref($job->{finalization}) eq 'HASH') {
                    if (exists $job->{resume_intent}) {
                        die "compacted resume job has an invalid finalization binding ($id)"
                            unless _resume_finalization_binding_matches(
                                $job->{finalization}, $job->{resume_intent});
                    } elsif (exists $job->{finalization}{resume_verification}) {
                        die "ordinary job contains a resume verification finalization ($id)";
                    }
                } elsif (exists($job->{resume_intent}) &&
                        ($job->{state} eq 'finalizing' ||
                            $job->{state} eq 'complete')) {
                    die "compacted resume job advanced without a verified finalization reservation ($id)";
                }
                if (exists($job->{resume_intent}) && $job->{state} eq 'complete') {
                    my $finalization_error = _resume_job_finalization_error(
                        $job, $job->{finalization});
                    die "$finalization_error ($id)" if defined $finalization_error;
                }
                $self->{compacted_resume_pending_snapshots}{$id} =
                    _compacted_resume_pending_snapshot_details($job)
                    if $compacted_resume_snapshot &&
                        $job->{state} eq 'resume_pending';
            }
        if ($event eq 'job_transition') {
            die "journal transition refers to an unknown job ($id)" unless exists $self->{jobs}{$id};
            die "journal transition sequence is discontinuous ($id)"
                unless $job->{transition_sequence} == $self->{jobs}{$id}{transition_sequence} + 1;
            die "journal transition mutates immutable job context ($id)"
                unless JSON::PP->new->canonical(1)->encode($job->{context}) eq
                    JSON::PP->new->canonical(1)->encode($self->{jobs}{$id}{context});
            die "journal transition mutates immutable trusted content digest ($id)"
                unless _same_trusted_content_digest($self->{jobs}{$id}, $job);
            my $resume_intent_unchanged = _same_resume_intent($self->{jobs}{$id}, $job);
            if ($job->{state} eq 'resume_pending' || !$resume_intent_unchanged) {
                my $valid_admission = _resume_intent_matches_prior(
                    job => $job,
                    previous_state => $self->{job_lifecycle}{$id}{state},
                    previous_binding => resume_binding_fingerprint($self->{jobs}{$id}),
                    previous_partial_binding => resume_partial_fingerprint(
                        $self->{jobs}{$id}{partial}),
                    previous_lifecycle_identity => $self->{jobs}{$id}{accepted_lifecycle},
                    previous_had_intent => exists($self->{jobs}{$id}{resume_intent}),
                    tuple_owners => $self->{tuples});
                if (!$resume_intent_unchanged) {
                    die "journal transition mutates immutable resume intent ($id)"
                        unless $valid_admission;
                } else {
                    die "journal transition enters resume_pending without valid durable admission ($id)"
                        unless $valid_admission;
                }
            }
            my $finalization_error = _resume_job_finalization_error(
                $job, $self->{finalizations}{$id});
            die "$finalization_error ($id)" if defined $finalization_error;
            my $stop = $self->{stop_intents}{$id};
            delete $self->{stop_intents}{$id}
                if $stop && $job->{transition_sequence} > $stop->{lifecycle_sequence};
        }
        $job = clone_job($job);
        if ($self->{finalizations}{$id} && !defined($job->{finalization})) {
            $job->{finalization} = { %{$self->{finalizations}{$id}} };
        }
        $self->{finalizations}{$id} = { %{$job->{finalization}} }
            if ref($job->{finalization}) eq 'HASH';
        if ($event eq 'job_created') {
            die 'journal exceeds job identity history capacity'
                if keys(%{$self->{job_ids}}) >= $MAX_JOB_IDENTITIES;
            $self->{job_ids}{$id} = 1;
        }
        $self->{job_lifecycle}{$id} = {
            state => $job->{state},
            transition_sequence => $job->{transition_sequence},
        };
        my $identity = job_identity_key($job);
        die 'journal contains duplicate provider identity'
            if exists($self->{job_identity}{$identity}) && $self->{job_identity}{$identity} ne $id;
        if ($event eq 'job_created') {
            die 'journal exceeds job identity history capacity'
                if keys(%{$self->{job_identity}}) >= $MAX_JOB_IDENTITIES;
        }
        $self->{job_identity}{$identity} = $id;
        if (!is_terminal($job->{state}) &&
                unfinished_count($self->{jobs}) >= $MAX_UNFINISHED &&
                !exists($self->{jobs}{$id})) {
            die 'journal exceeds unfinished job capacity';
        }
        $self->_retain_job($job);
    } elsif ($event eq 'tuple_reserved') {
        my $tuple = $data->{tuple};
        my $job_id = $data->{job_id};
        die 'journal tuple reservation is malformed'
            unless defined($tuple) && length($tuple) && defined($job_id) && length($job_id);
        if (exists $self->{tuples}{$tuple}) {
            die 'journal contains a tuple reservation collision'
                unless $self->{tuples}{$tuple} eq $job_id;
        } else {
            die 'journal exceeds unresolved tuple capacity' if $self->{tuple_count} >= $MAX_RESERVED_TUPLES;
            $self->{tuples}{$tuple} = $job_id;
            $self->{tuple_count}++;
        }
    } elsif ($event eq 'tuple_alias_reserved') {
        my $tuple = $data->{tuple};
        my $job_id = $data->{job_id};
        die 'journal alias tuple reservation is malformed'
            unless defined($tuple) && length($tuple) && defined($job_id) && length($job_id);
        if (exists $self->{tuples}{$tuple}) {
            die 'journal contains a tuple alias collision'
                unless $self->{tuples}{$tuple} eq $job_id;
        } else {
            die 'journal exceeds unresolved tuple capacity' if $self->{tuple_count} >= $MAX_RESERVED_TUPLES;
            $self->{tuples}{$tuple} = $job_id;
            $self->{tuple_count}++;
        }
    } elsif ($event eq 'finalization_reservation') {
        die 'finalization reservation refers to an unknown job'
            unless defined($data->{job_id}) && exists $self->{jobs}{$data->{job_id}};
        die 'finalization reservation is malformed'
            unless defined($data->{staging_path}) && length($data->{staging_path}) &&
                defined($data->{destination_path}) && length($data->{destination_path});
        my $id = $data->{job_id};
        my $valid_size = defined($data->{expected_size}) && $data->{expected_size} =~ /\A\d+\z/;
        my $valid_digest = defined($data->{expected_sha256}) &&
            $data->{expected_sha256} =~ /\A[a-f0-9]{64}\z/i;
        my $job = $self->{jobs}{$id};
        if (exists $job->{resume_intent}) {
            my $verification = $data->{resume_verification};
            die "resume finalization lacks a matching verified-file receipt ($id)"
                unless _resume_verification_matches_intent(
                    $verification, $job->{resume_intent}) &&
                    _same_path($data->{staging_path}, $verification->{path}) &&
                    $valid_size && "$data->{expected_size}" eq
                        "$verification->{total_size}" &&
                    $valid_digest && lc($data->{expected_sha256}) eq
                        $verification->{expected_sha256};
        } elsif (exists $data->{resume_verification}) {
            die "ordinary finalization contains a resume verification receipt ($id)";
        }
        $self->{finalizations}{$id} = {
            status => 'reserved', staging_path => $data->{staging_path},
            destination_path => $data->{destination_path},
            expected_size => $valid_size ? 0 + $data->{expected_size} : undef,
            expected_sha256 => $valid_digest ? lc($data->{expected_sha256}) : undef,
            (exists($data->{resume_verification})
                ? (resume_verification => $data->{resume_verification}) : ()),
        };
        $self->{jobs}{$id}{finalization} = { %{$self->{finalizations}{$id}} };
    } elsif ($event eq 'finalization_result') {
        die 'finalization result refers to an unknown job'
            unless defined($data->{job_id}) && exists $self->{jobs}{$data->{job_id}};
        my $id = $data->{job_id};
        my $reservation = $self->{finalizations}{$id} ||
            $self->{jobs}{$id}{finalization} || {};
        my $success = _json_boolean_value($data->{success});
        die 'finalization result success flag is malformed' unless defined $success;
        my $finalization = {
            %$reservation,
            status => $success ? 'published' : 'unresolved',
            result => {
                success => $success,
                destination_path => $data->{destination_path},
                observed_size => $data->{observed_size},
                observed_sha256 => $data->{observed_sha256},
                reason => $data->{reason},
                (exists($data->{publication_evidence})
                    ? (publication_evidence => $data->{publication_evidence}) : ()),
            },
        };
        if (exists($self->{jobs}{$id}{resume_intent}) && $success) {
            my $evidence_error = _resume_publication_success_evidence_error(
                $finalization);
            die "$evidence_error ($id)" if defined $evidence_error;
        }
        $self->{finalizations}{$id} = $finalization;
        $self->{jobs}{$id}{finalization} = { %{$self->{finalizations}{$id}} };
    } elsif ($event eq 'transfer_stop_intent') {
        my $id = $data->{job_id};
        my $job = defined($id)
            ? ($self->{jobs}{$id} || $self->{terminal_jobs}{$id}) : undef;
        my $evicted_terminal = !$job;
        $job = $self->{job_lifecycle}{$id}
            if $evicted_terminal && defined($id);
        die 'transfer stop intent refers to an unknown job' unless $job;
        die 'transfer stop intent is malformed'
            unless ref($data->{intent}) eq 'HASH' &&
                ($data->{intent}{job_state} // '') =~ /\A(?:cancelled|interrupted)\z/;
        my $sequence = $data->{lifecycle_sequence};
        # Older records did not carry a lifecycle sequence. They can only
        # apply to the receiving lifecycle visible at their journal position.
        $sequence = $job->{transition_sequence}
            if !defined($sequence) && $job->{state} eq 'receiving';
        die 'transfer stop intent lifecycle sequence is malformed'
            if defined($sequence) && $sequence !~ /\A\d+\z/;
        die 'transfer stop intent refers to a future lifecycle'
            if defined($sequence) && $sequence > $job->{transition_sequence};
        # Compaction writes each latest job snapshot before its retained
        # audit records. A known terminal job may have aged out of the small
        # terminal-object cache by the time its audit is replayed. Its saved
        # lifecycle metadata proves the identity and sequence; the audit must
        # not recreate or alter that terminal job.
        return 1 if $evicted_terminal;
        if ($job->{state} eq 'receiving' &&
                defined($sequence) &&
                $sequence == $job->{transition_sequence}) {
            my $existing = $self->{stop_intents}{$id};
            if ($existing && $existing->{lifecycle_sequence} == $sequence) {
                die 'conflicting transfer stop intents for one receive lifecycle'
                    unless JSON::PP->new->canonical(1)->encode($existing->{intent}) eq
                        JSON::PP->new->canonical(1)->encode($data->{intent});
            } else {
                $self->{stop_intents}{$id} = {
                    lifecycle_sequence => 0 + $sequence,
                    intent => JSON::PP->new->decode(
                        JSON::PP->new->canonical(1)->encode($data->{intent})),
                };
            }
        }
    }
    return 1;
}

sub _recover_abandoned_jobs {
    my ($self) = @_;
    for my $job (values %{$self->{jobs}}) {
        next if is_terminal($job->{state}) || $job->{state} eq 'held' || $job->{state} eq 'needs_attention';
        my $previous = $job->{state};
        if ($previous eq 'finalizing') {
            my $finalization = $job->{finalization} || $self->{finalizations}{$job->{id}};
            # A resumed publication result is durable before its following
            # state transition. Preserve either recorded outcome unchanged so
            # replay and compaction can match it to the transition. A recorded
            # success proves publication; a recorded refusal must not be
            # upgraded because an unrelated file happens to match the bytes.
            my $durable_resume_publication =
                ref($job->{resume_intent}) eq 'HASH' &&
                ref($finalization) eq 'HASH' &&
                ($finalization->{status} // '') eq 'published' &&
                !defined(_resume_publication_success_evidence_error($finalization)) &&
                !defined(_resume_job_finalization_error($job, $finalization));
            my $durable_resume_refusal =
                ref($job->{resume_intent}) eq 'HASH' &&
                _resume_publication_failure_result_matches_intent(
                    $finalization, $job->{resume_intent}) &&
                !defined(_resume_job_finalization_error($job, $finalization));
            my $durable_resume_result =
                $durable_resume_publication || $durable_resume_refusal;
            my $file_proof = $durable_resume_result
                ? undef : $self->_verify_finalization_file($finalization);
            my $destination_valid = $durable_resume_publication ||
                (!$durable_resume_refusal &&
                    ref($file_proof) eq 'HASH' && $file_proof->{ok});
            if ($destination_valid && !$durable_resume_result) {
                my $directory_synced = 0;
                my $sync_ok = eval {
                    $self->{journal}->sync_parent_directory(
                        $finalization->{destination_path});
                    1;
                };
                $directory_synced = $sync_ok ? 1 : 0;
                $destination_valid = 0 unless $directory_synced;
            }
            $destination_valid = 0
                if $destination_valid && !$durable_resume_result &&
                    !_path_matches_file_proof(
                        $finalization->{destination_path}, $file_proof);
            my $target = $durable_resume_refusal ? 'needs_attention'
                : $destination_valid ? 'complete' : 'needs_attention';
            my $reason = $durable_resume_publication
                ? 'restart completed from the matching durable publication result; no request was repeated'
                : $durable_resume_refusal
                ? $finalization->{result}{reason}
                : $destination_valid
                ? 'restart reverified and durably synced the already-published destination; no copy or request was repeated'
                : 'restart could not verify and durably sync the reserved published destination; staging and destination evidence were retained for inspection';
            my $recovered_finalization = {
                %{$finalization || {}},
                status => $durable_resume_publication ? 'published'
                    : $durable_resume_refusal ? 'unresolved'
                    : $destination_valid
                    ? 'reconciled_complete' : 'reconciliation_required',
            };
            if ($destination_valid && !$durable_resume_result) {
                $recovered_finalization->{result} = {
                    success => JSON::PP::true,
                    destination_path => $finalization->{destination_path},
                    observed_size => $file_proof->{size},
                    observed_sha256 => $file_proof->{sha256},
                    reason => $reason,
                    publication_evidence => {
                        schema_version => 1,
                        method => 'recovery_verified',
                        destination_path => $finalization->{destination_path},
                        device => $file_proof->{device},
                        inode => $file_proof->{inode},
                        size => $file_proof->{size},
                        sha256 => $file_proof->{sha256},
                        content_verified => JSON::PP::true,
                        payload_synced => JSON::PP::true,
                        directory_synced => JSON::PP::true,
                    },
                };
            }
            my $updated = transition_job($job, $target,
                outcome => $durable_resume_refusal ? 'finalization_unresolved'
                    : $destination_valid ? 'finalization_reconciled' : 'finalization_needs_attention',
                reason => $reason,
                data => { finalization => $recovered_finalization });
            $self->{journal}->append('job_transition', { job => $updated, recovered_from => $previous });
            $self->_retain_job($updated);
            $self->{finalizations}{$job->{id}} = { %{$updated->{finalization}} };
            push @{$self->{recovery}}, { id => $job->{id}, previous_state => $previous,
                state => $target, destination_verified => $destination_valid ? 1 : 0 };
            next;
        }
        my $stop = $self->{stop_intents}{$job->{id}};
        if ($previous eq 'receiving' && $stop &&
                $stop->{lifecycle_sequence} == $job->{transition_sequence}) {
            my $intent = $stop->{intent};
            my $target = $intent->{job_state};
            my $outcome = $intent->{job_outcome} //
                ($target eq 'cancelled' ? 'transfer_cancelled' : 'transfer_interrupted');
            my $reason = $intent->{reason} //
                'process restarted while a native transfer stop was pending';
            my $updated = transition_job($job, $target,
                outcome => $outcome, reason => $reason,
                data => { stop_intent => { %$intent } });
            $self->{journal}->append('job_transition', {
                job => $updated, recovered_from => $previous,
                recovered_stop_intent => 1,
            });
            $self->_retain_job($updated);
            delete $self->{stop_intents}{$job->{id}};
            push @{$self->{recovery}}, {
                id => $job->{id}, previous_state => $previous,
                state => $target, stop_intent => 1,
            };
            next;
        }
        my $target = $previous eq 'receiving' || $previous eq 'resume_pending'
            ? 'interrupted' : 'needs_attention';
        my $reason = "process restarted while job was $previous; no pointer or network request was restored";
        my $updated = transition_job($job, $target, outcome => 'restart_recovery', reason => $reason);
        $self->{journal}->append('job_transition', { job => $updated, recovered_from => $previous });
        $self->_retain_job($updated);
        push @{$self->{recovery}}, { id => $job->{id}, previous_state => $previous, state => $target };
    }
}

sub _stat_file_identity {
    my ($stat) = @_;
    return unless ref($stat) eq 'ARRAY' && @$stat >= 11;
    return {
        device => 0 + $stat->[0], inode => 0 + $stat->[1],
        mode => 0 + $stat->[2], links => 0 + $stat->[3],
        size => 0 + $stat->[7], mtime => 0 + $stat->[9],
        ctime => 0 + $stat->[10],
    };
}

sub _same_file_identity {
    my ($left, $right) = @_;
    return 0 unless ref($left) eq 'HASH' && ref($right) eq 'HASH';
    for my $field (qw(device inode mode links size mtime ctime)) {
        return 0 unless defined($left->{$field}) && defined($right->{$field}) &&
            "$left->{$field}" eq "$right->{$field}";
    }
    return 1;
}

sub _path_matches_file_proof {
    my ($path, $proof) = @_;
    return 0 unless defined($path) && ref($proof) eq 'HASH';
    my @entry = lstat($path);
    return 0 unless @entry && ($entry[2] & 0170000) == 0100000;
    my @path_stat = Time::HiRes::stat($path);
    my $path_identity = _stat_file_identity(\@path_stat);
    return 0 unless _same_file_identity($proof, $path_identity) &&
        $entry[0] == $proof->{device} && $entry[1] == $proof->{inode} &&
        $entry[7] == $proof->{size};
    return 1;
}

sub _verify_finalization_file {
    my ($self, $finalization) = @_;
    my $path = ref($finalization) eq 'HASH'
        ? $finalization->{destination_path} : undef;
    return { ok => 0, reason => 'finalization destination or digest is missing' }
        unless defined($path) && length($path) &&
        defined($finalization->{expected_size}) &&
        $finalization->{expected_size} =~ /\A\d+\z/ &&
        defined($finalization->{expected_sha256}) &&
        $finalization->{expected_sha256} =~ /\A[a-f0-9]{64}\z/;
    my @entry_before = lstat($path);
    return { ok => 0, reason => 'finalization destination is not a regular file' }
        unless @entry_before && ($entry_before[2] & 0170000) == 0100000;
    sysopen(my $fh, $path, O_RDONLY)
        or return { ok => 0, reason => "cannot open finalization payload: $!" };
    binmode($fh, ':raw') or do {
        my $error = "$!";
        close $fh;
        return { ok => 0, reason => "cannot set finalization payload to raw mode: $error" };
    };

    my $refuse = sub {
        my ($reason) = @_;
        close $fh;
        return { ok => 0, reason => $reason };
    };
    my @handle_before = Time::HiRes::stat($fh);
    my @path_before = Time::HiRes::stat($path);
    my @entry_after_open = lstat($path);
    my $identity = _stat_file_identity(\@handle_before);
    my $path_identity = _stat_file_identity(\@path_before);
    return $refuse->('finalization destination changed while it was opened')
        unless @entry_after_open && ($entry_after_open[2] & 0170000) == 0100000 &&
            _same_file_identity($identity, $path_identity) &&
            $identity->{size} == $finalization->{expected_size};
    return $refuse->('resumed publication destination permissions are not private')
        if ref($finalization->{resume_verification}) eq 'HASH' &&
            ($identity->{mode} & 0777) != 0600;

    my $first_sha = Digest::SHA->new(256);
    my $first_ok = eval { $first_sha->addfile($fh); 1 };
    return $refuse->('finalization payload could not be hashed') unless $first_ok;
    my $expected_sha = lc($finalization->{expected_sha256});
    return $refuse->('finalization payload digest does not match its reservation')
        unless lc($first_sha->hexdigest) eq $expected_sha;

    my $payload_synced = eval { $self->_sync_payload_handle($fh) };
    return $refuse->('finalization payload durable sync failed: ' .
        ($@ || $! || 'sync failed')) unless $payload_synced;
    seek($fh, 0, 0)
        or return $refuse->("cannot rewind finalization payload after sync: $!");
    my $second_sha = Digest::SHA->new(256);
    my $second_ok = eval { $second_sha->addfile($fh); 1 };
    my $second_digest = $second_ok ? lc($second_sha->hexdigest) : undef;
    return $refuse->('finalization payload could not be rehashed after sync')
        unless defined($second_digest) && $second_digest eq $expected_sha;
    my $resynced = eval { $self->_sync_payload_handle($fh) };
    return $refuse->('finalization payload durable resync failed: ' .
        ($@ || $! || 'sync failed')) unless $resynced;

    my @handle_after = Time::HiRes::stat($fh);
    my @path_after = Time::HiRes::stat($path);
    my @entry_after = lstat($path);
    my $after_identity = _stat_file_identity(\@handle_after);
    my $after_path_identity = _stat_file_identity(\@path_after);
    return $refuse->('finalization payload identity changed during digest verification')
        unless @entry_after && ($entry_after[2] & 0170000) == 0100000 &&
            _same_file_identity($identity, $after_identity) &&
            _same_file_identity($identity, $after_path_identity);
    my $closed = close $fh;
    return { ok => 0, reason => "cannot close finalization payload after sync: $!" }
        unless $closed;
    return { ok => 1, %$identity, sha256 => $second_digest };
}

sub _sync_payload_handle {
    my ($self, $fh) = @_;
    return $fh->sync() ? 1 : 0;
}

sub create_job {
    my ($self, %args) = @_;
    die 'coordinator is closed' if $self->{closed};
    die 'unfinished job capacity reached' if unfinished_count($self->{jobs}) >= $MAX_UNFINISHED;
    my $job = new_job(%args);
    my $web_operation_id = $job->{context}{web_operation_id};
    if (defined $web_operation_id) {
        die 'job has an invalid web operation identity'
            unless $web_operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
        die 'web operation identity already has a durable job'
            if exists $self->{web_operation_jobs}{$web_operation_id};
    }
    my $identity = job_identity_key($job);
    die 'an identical provider selection already has a job'
        if exists $self->{job_identity}{$identity};
    die 'job identity history capacity reached; existing duplicate guards cannot be retired safely'
        if keys(%{$self->{job_identity}}) >= $MAX_JOB_IDENTITIES;
    die 'job identifier collision' if $self->{job_ids}{$job->{id}};
    $self->{journal}->append('job_created', { job => $job });
    $self->{job_ids}{$job->{id}} = 1;
    $self->{job_identity}{$identity} = $job->{id};
    # Journal replay rebuilds this index; a running process must record it
    # too, or a lost reply could not be reconciled until the next restart.
    $self->{web_operation_jobs}{$web_operation_id} = $job->{id}
        if defined $web_operation_id;
    $self->_retain_job($job);
    return clone_job($job);
}

sub transition {
    my ($self, $id, $next, %meta) = @_;
    die 'unknown job id' unless exists $self->{jobs}{$id};
    if (($next // '') eq 'resume_pending') {
        die 'resume_pending requires the checked durable resume-admission path'
            unless ref($meta{_resume_admission_token}) eq 'HASH' &&
                $meta{_resume_admission_token} == $RESUME_ADMISSION_TOKEN;
        delete $meta{_resume_admission_token};
    }
    my $current = $self->{jobs}{$id};
    if (($next // '') eq 'complete' && exists($current->{resume_intent})) {
        my $publication_token = delete $meta{_resume_publication_token};
        die 'resumed-job completion requires the exclusive verified-file publisher'
            unless ref($publication_token) eq 'HASH' &&
                $publication_token == $RESUME_PUBLICATION_TOKEN;
    } elsif (exists $meta{_resume_publication_token}) {
        die 'resume publication token is only valid for a resumed-job completion';
    }
    if (ref($meta{data}) eq 'HASH' && ref($meta{data}{partial}) eq 'HASH') {
        my %data = %{$meta{data}};
        my %partial = %{$meta{data}{partial}};
        my $capture;
        if ($partial{source_invalid}) {
            $capture = { type => 'refusal', reason => 'receive path was marked changed during DCC receive' };
        } elsif (ref($partial{receive_identity}) ne 'HASH' ||
                !defined($partial{receive_identity}{device}) ||
                !defined($partial{receive_identity}{inode})) {
            $capture = { type => 'refusal', reason => 'receive-time partial identity is unavailable' };
        } elsif (!defined($partial{receive_path}) || !defined($partial{path}) ||
                File::Spec->canonpath(File::Spec->rel2abs($partial{receive_path})) ne
                File::Spec->canonpath(File::Spec->rel2abs($partial{path}))) {
            $capture = { type => 'refusal', reason => 'partial path differs from its receive-time path' };
        } else {
            $capture = capture_partial(path => $partial{path},
                staging_root => $partial{staging_root},
                expected_identity => $partial{receive_identity});
        }
        if ($capture->{type} eq 'captured_partial') {
            $partial{path} = $capture->{path};
            $partial{staging_root} = $capture->{staging_root};
            $partial{file_identity} = $capture->{identity};
            $partial{ownership_status} = 'captured';
            delete $partial{ownership_refusal};
        } else {
            $partial{ownership_status} = 'unverified';
            $partial{ownership_refusal} = $capture->{reason};
            delete $partial{file_identity};
        }
        $partial{digest_status} = 'not-sealed';
        $data{partial} = \%partial;
        $meta{data} = \%data;
    }
    my $updated = transition_job($current, $next, %meta);
    my $finalization_error = _resume_job_finalization_error(
        $updated, $self->{finalizations}{$id});
    die "$finalization_error ($id)" if defined $finalization_error;
    $self->{journal}->append('job_transition', { job => $updated });
    my $stop = $self->{stop_intents}{$id};
    delete $self->{stop_intents}{$id}
        if $stop && $updated->{transition_sequence} > $stop->{lifecycle_sequence};
    $self->_retain_job($updated);
    return clone_job($updated);
}

sub begin_dispatch {
    my ($self, $id, %args) = @_;
    die 'unknown job id' unless exists $self->{jobs}{$id};
    my $job = $self->{jobs}{$id};
    die 'job is not in a dispatchable preflight state'
        unless $job->{state} eq 'held' || $job->{state} eq 'preparing';
    die 'provider selection changed before dispatch' if $args{validate} && !$args{validate}->(clone_job($job));
    my $check = $self->preflight_tuples($id, casemapping => $args{casemapping});
    die $check->{reason} unless $check->{available};
    my @tuples = @{$check->{tuples}};

    # Persist every ambiguous tuple before preparing transport. Reservations
    # are intentionally retained after every terminal outcome.
    for my $index (0 .. $#tuples) {
        my $tuple = $tuples[$index];
        next if exists($self->{tuples}{$tuple}) && $self->{tuples}{$tuple} eq $id;
        my $event = $index ? 'tuple_alias_reserved' : 'tuple_reserved';
        $self->{journal}->append($event, { tuple => $tuple, job_id => $id });
        $self->{tuples}{$tuple} = $id;
        $self->{tuple_count}++;
    }
    if ($job->{state} eq 'held') {
        $self->transition($id, 'ready', reason => 'included in explicit finite run');
        $self->transition($id, 'preparing');
    }
    my %intent_meta = (
        outcome => 'dispatch_intent', reason => 'durable intent recorded before transport invocation');
    $intent_meta{data} = { effective_limits => $args{effective_limits} }
        if ref($args{effective_limits}) eq 'HASH';
    my $intent = $self->transition($id, 'dispatch_intent', %intent_meta);
    return $intent;
}

sub preflight_tuples {
    my ($self, $id, %args) = @_;
    die 'unknown job id' unless exists $self->{jobs}{$id};
    my $job = $self->{jobs}{$id};
    my $mapping = $job->{context}{casemapping} // $args{casemapping};
    my @tuples = tuple_keys_for_job($job, $mapping);
    return { available => 0, reason => 'job has no reserveable DCC offer identity', tuples => [] }
        unless @tuples;
    for my $tuple (@tuples) {
        return { available => 0,
            reason => 'DCC offer tuple is already reserved by job ' . $self->{tuples}{$tuple},
            tuples => \@tuples }
            if exists($self->{tuples}{$tuple}) && $self->{tuples}{$tuple} ne $id;
    }
    return { available => 0, reason => 'unresolved DCC offer tuple capacity reached', tuples => \@tuples }
        if $self->{tuple_count} + scalar(grep { !exists $self->{tuples}{$_} } @tuples) > $MAX_RESERVED_TUPLES;
    return { available => 1, tuples => \@tuples };
}

sub record_dispatch_result {
    my ($self, $id, $result, %meta) = @_;
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    # A native offer may be delivered reentrantly while send() is on stack.
    return clone_job($job) unless $job->{state} eq 'dispatch_intent';
    if ($result eq 'sent') {
        return $self->transition($id, 'awaiting_offer', %meta)
            if $job->{state} eq 'dispatch_intent';
    } elsif ($result eq 'cancelled_before_transport') {
        return $self->transition($id, 'held', outcome => 'dispatch_cancelled_before_transport', %meta)
            if $job->{state} eq 'dispatch_intent';
    } elsif ($result eq 'refused_without_queue') {
        return $self->transition($id, 'refused_without_queue', outcome => $result, %meta);
    } else {
        return $self->transition($id, 'needs_attention', outcome => 'dispatch_outcome_unknown', %meta);
    }
    return clone_job($self->{jobs}{$id});
}

sub accept_offer {
    my ($self, $id, %meta) = @_;
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    return clone_job($job) if $job->{state} eq 'receiving';
    die 'offer cannot be attached to this job state'
        unless $job->{state} eq 'dispatch_intent' || $job->{state} eq 'awaiting_offer' || $job->{state} eq 'remote_queued';
    my %data;
    $data{accepted_lifecycle} = $meta{accepted_lifecycle} if defined $meta{accepted_lifecycle};
    $data{offered_basename} = $meta{offered_basename} if defined $meta{offered_basename};
    return $self->transition($id, 'receiving', outcome => 'offer_accepted',
        data => \%data, reason => 'native DCC offer matched and was bound to this live request');
}

sub record_event {
    my ($self, $event, $data) = @_;
    die 'job lifecycle events must use validated coordinator methods'
        if defined($event) && ($event eq 'job_created' || $event eq 'job_transition');
    return $self->{journal}->append($event, $data);
}

sub record_transfer_stop_intent {
    my ($self, %args) = @_;
    die 'coordinator is closed' if $self->{closed};
    my $id = $args{job_id};
    my $job = defined($id)
        ? ($self->{jobs}{$id} || $self->{terminal_jobs}{$id}) : undef;
    die 'transfer stop intent refers to an unknown job' unless $job;
    die 'transfer stop intent must be cancelled or interrupted'
        unless ref($args{intent}) eq 'HASH' &&
            ($args{intent}{job_state} // '') =~ /\A(?:cancelled|interrupted)\z/;
    my $sequence = $job->{transition_sequence};
    if ($job->{state} eq 'receiving') {
        my $existing = $self->{stop_intents}{$id};
        if ($existing && $existing->{lifecycle_sequence} == $sequence) {
            die 'conflicting transfer stop intents for one receive lifecycle'
                unless JSON::PP->new->canonical(1)->encode($existing->{intent}) eq
                    JSON::PP->new->canonical(1)->encode($args{intent});
            return 1;
        }
    }
    my $intent = JSON::PP->new->decode(
        JSON::PP->new->canonical(1)->encode($args{intent}));
    $self->{journal}->append('transfer_stop_intent', {
        job_id => $id,
        transfer_key => $args{transfer_key},
        request_id => $args{request_id},
        lifecycle_sequence => 0 + $sequence,
        intent => $intent,
    });
    if ($job->{state} eq 'receiving') {
        $self->{stop_intents}{$id} = {
            lifecycle_sequence => 0 + $sequence, intent => $intent,
        };
    }
    return 1;
}

sub transfer_stop_intent {
    my ($self, $id) = @_;
    my $entry = defined($id) ? $self->{stop_intents}{$id} : undef;
    return unless $entry;
    return {
        lifecycle_sequence => $entry->{lifecycle_sequence},
        intent => JSON::PP->new->decode(
            JSON::PP->new->canonical(1)->encode($entry->{intent})),
    };
}

sub compact_journal {
    my ($self) = @_;
    die 'coordinator is closed' if $self->{closed};
    my $journal = $self->{journal};
    my (%latest_job_sequence, %finalizations, %resume_finalization_reservations_at_scan,
        %tuple_records, %audit_sequences);
    my (%job_lifecycle_at_scan, %job_digest_at_scan,
        %job_resume_intent_at_scan, %job_resume_binding_at_scan,
        %job_resume_intent_record_at_scan,
        %job_resume_partial_binding_at_scan,
        %compacted_resume_pending_snapshots_at_scan,
        %audit_lifecycle_overrides);

    return $journal->compact(sub {
        my ($emit) = @_;
        $journal->replay(on_event => sub {
            my ($record, $sequence) = @_;
            my $event = $record->{event};
            my $data = $record->{data};
            if ($event eq 'job_created' || $event eq 'job_transition') {
                my $job = $data->{job};
                die 'journal compaction found a malformed job record'
                    unless ref($job) eq 'HASH' && defined($job->{id});
                validate_job($job);
                my $id = $job->{id};
                my $digest = _trusted_content_digest_fingerprint($job);
                my $resume_intent = exists($job->{resume_intent})
                    ? JSON::PP->new->canonical(1)->encode($job->{resume_intent}) : undef;
                my $resume_binding = resume_binding_fingerprint($job);
                if ($event eq 'job_created') {
                    my $compacted_resume_snapshot =
                        exists($data->{compacted_resume_snapshot}) &&
                        defined($data->{compacted_resume_snapshot}) &&
                        !ref($data->{compacted_resume_snapshot}) &&
                        "$data->{compacted_resume_snapshot}" eq '1';
                    die "journal compaction found an invalid resume snapshot marker ($id)"
                        if exists($data->{compacted_resume_snapshot}) &&
                            !$compacted_resume_snapshot;
                    die "journal compaction found an unvalidated resume snapshot ($id)"
                        if ($job->{state} eq 'resume_pending' ||
                                exists($job->{resume_intent})) &&
                            (!$compacted_resume_snapshot ||
                                !exists($job->{resume_intent}));
                    die "journal compaction found an invalid resume snapshot marker ($id)"
                        if $compacted_resume_snapshot &&
                            !exists($job->{resume_intent});
                    if (ref($job->{finalization}) eq 'HASH') {
                        if (exists $job->{resume_intent}) {
                            die "journal compaction found an invalid resume finalization snapshot ($id)"
                                unless _resume_finalization_binding_matches(
                                    $job->{finalization}, $job->{resume_intent});
                            $resume_finalization_reservations_at_scan{$id} =
                                { %{$job->{finalization}} }
                                if $compacted_resume_snapshot;
                        } elsif (exists $job->{finalization}{resume_verification}) {
                            die "journal compaction found resume evidence on an ordinary job ($id)";
                        }
                    } elsif (exists($job->{resume_intent}) &&
                            ($job->{state} eq 'finalizing' ||
                                $job->{state} eq 'complete')) {
                        die "journal compaction found a resumed job without a verified finalization reservation ($id)";
                    }
                    if (exists($job->{resume_intent}) && $job->{state} eq 'complete') {
                        my $finalization_error = _resume_job_finalization_error(
                            $job, $job->{finalization});
                        die "journal compaction found $finalization_error ($id)"
                            if defined $finalization_error;
                    }
                    $compacted_resume_pending_snapshots_at_scan{$id} =
                        _compacted_resume_pending_snapshot_details($job)
                        if $compacted_resume_snapshot &&
                            $job->{state} eq 'resume_pending';
                    die "journal compaction found repeated job creation ($id)"
                        if exists $job_digest_at_scan{$id};
                    die 'journal compaction exceeds job identity capacity'
                        if keys(%job_digest_at_scan) >= $MAX_JOB_IDENTITIES;
                    $job_resume_intent_at_scan{$id} =
                        $compacted_resume_snapshot ? $resume_intent : undef;
                } else {
                    my $previous = $job_lifecycle_at_scan{$id};
                    die "journal compaction found a transition for an unknown job ($id)"
                        unless $previous;
                    die "journal compaction found a discontinuous transition sequence ($id)"
                        unless $job->{transition_sequence} == $previous->{transition_sequence} + 1;
                    my $previous_digest = $job_digest_at_scan{$id};
                    die "journal compaction found a transition that mutates immutable trusted content digest ($id)"
                        if (defined($previous_digest) ? 1 : 0) != (defined($digest) ? 1 : 0) ||
                            (defined($previous_digest) && $previous_digest ne $digest);
                    my $previous_resume_intent = $job_resume_intent_at_scan{$id};
                    my $resume_intent_unchanged =
                        (defined($previous_resume_intent) ? 1 : 0) ==
                            (defined($resume_intent) ? 1 : 0) &&
                        (!defined($previous_resume_intent) ||
                            $previous_resume_intent eq $resume_intent);
                    if ($job->{state} eq 'resume_pending' || !$resume_intent_unchanged) {
                        my $valid_admission = _resume_intent_matches_prior(
                            job => $job,
                            previous_state => $job_lifecycle_at_scan{$id}{state},
                            previous_binding => $job_resume_binding_at_scan{$id},
                            previous_partial_binding =>
                                $job_resume_partial_binding_at_scan{$id},
                            previous_lifecycle_identity =>
                                $job_lifecycle_at_scan{$id}{accepted_lifecycle},
                            previous_had_intent => defined($previous_resume_intent),
                            tuple_owners => \%tuple_records);
                        if (!$resume_intent_unchanged) {
                            die "journal compaction found a transition that mutates immutable resume intent ($id)"
                                unless $valid_admission;
                        } else {
                            die "journal compaction found resume_pending without valid durable admission ($id)"
                                unless $valid_admission;
                        }
                    }
                    my $finalization_error = _resume_job_finalization_error(
                        $job, $resume_finalization_reservations_at_scan{$id});
                    die "journal compaction found $finalization_error ($id)"
                        if defined $finalization_error;
                }
                $job_digest_at_scan{$id} = $digest;
                $job_resume_intent_at_scan{$id} = $resume_intent;
                $job_resume_intent_record_at_scan{$id} =
                    exists($job->{resume_intent}) ? $job->{resume_intent} : undef;
                $job_resume_binding_at_scan{$id} = $resume_binding;
                $job_resume_partial_binding_at_scan{$id} =
                    resume_partial_fingerprint($job->{partial});
                $latest_job_sequence{$id} = $sequence;
                $job_lifecycle_at_scan{$id} = {
                    state => $job->{state},
                    transition_sequence => $job->{transition_sequence},
                    accepted_lifecycle => $job->{accepted_lifecycle},
                };
                $finalizations{$id} = { %{$job->{finalization}} }
                    if ref($job->{finalization}) eq 'HASH';
            } elsif ($event eq 'tuple_reserved' || $event eq 'tuple_alias_reserved') {
                my ($tuple, $job_id) = @{$data}{qw(tuple job_id)};
                die 'journal compaction found a malformed tuple reservation'
                    unless defined($tuple) && length($tuple) && defined($job_id) && length($job_id);
                if (exists($tuple_records{$tuple})) {
                    die 'journal compaction found a tuple-owner collision'
                        unless $tuple_records{$tuple}{job_id} eq $job_id;
                } else {
                    $tuple_records{$tuple} = {
                        sequence => $sequence, event => $event,
                        job_id => $job_id,
                    };
                }
            } elsif ($event eq 'finalization_reservation') {
                my $id = $data->{job_id};
                die 'journal compaction found a finalization for an unknown job'
                    unless defined($id) && length($id) &&
                        exists($job_lifecycle_at_scan{$id}) &&
                        !is_terminal($job_lifecycle_at_scan{$id}{state});
                die 'journal compaction found a malformed finalization reservation'
                    unless defined($data->{staging_path}) && length($data->{staging_path}) &&
                        defined($data->{destination_path}) && length($data->{destination_path});
                my $valid_size = defined($data->{expected_size}) &&
                    $data->{expected_size} =~ /\A\d+\z/;
                my $valid_digest = defined($data->{expected_sha256}) &&
                    $data->{expected_sha256} =~ /\A[a-f0-9]{64}\z/i;
                my $resume_intent = $job_resume_intent_record_at_scan{$id};
                if (ref($resume_intent) eq 'HASH') {
                    my $verification = $data->{resume_verification};
                    my $lifecycle = $job_lifecycle_at_scan{$id};
                    die "journal compaction found a resume finalization without verified content ($id)"
                        unless $lifecycle &&
                            $lifecycle->{state} =~ /\A(?:receiving|finalizing|complete|needs_attention)\z/ &&
                            _resume_verification_matches_intent(
                                $verification, $resume_intent) &&
                            _same_path($data->{staging_path}, $verification->{path}) &&
                            $valid_size &&
                            "$data->{expected_size}" eq "$verification->{total_size}" &&
                            $valid_digest &&
                            lc($data->{expected_sha256}) eq
                                $verification->{expected_sha256};
                } elsif (exists $data->{resume_verification}) {
                    die "journal compaction found resume evidence on an ordinary job ($id)";
                }
                $finalizations{$id} = {
                    status => 'reserved',
                    staging_path => $data->{staging_path},
                    destination_path => $data->{destination_path},
                    expected_size => $valid_size ? 0 + $data->{expected_size} : undef,
                    expected_sha256 => $valid_digest ? lc($data->{expected_sha256}) : undef,
                    (exists($data->{resume_verification})
                        ? (resume_verification => $data->{resume_verification}) : ()),
                };
                $resume_finalization_reservations_at_scan{$id} =
                    { %{$finalizations{$id}} }
                    if ref($resume_intent) eq 'HASH';
            } elsif ($event eq 'finalization_result') {
                my $id = $data->{job_id};
                die 'journal compaction found a finalization result for an unknown job'
                    unless defined($id) && length($id) &&
                        exists($job_lifecycle_at_scan{$id}) &&
                        !is_terminal($job_lifecycle_at_scan{$id}{state});
                my $previous = $finalizations{$id} || {};
                my $success = _json_boolean_value($data->{success});
                die 'journal compaction found a malformed finalization result flag'
                    unless defined $success;
                $finalizations{$id} = {
                    %$previous,
                    status => $success ? 'published' : 'unresolved',
                    result => {
                        success => $success,
                        destination_path => $data->{destination_path},
                        observed_size => $data->{observed_size},
                        observed_sha256 => $data->{observed_sha256},
                        reason => $data->{reason},
                        (exists($data->{publication_evidence})
                            ? (publication_evidence => $data->{publication_evidence}) : ()),
                    },
                };
                if (ref($job_resume_intent_record_at_scan{$id}) eq 'HASH' &&
                        $success) {
                    my $evidence_error = _resume_publication_success_evidence_error(
                        $finalizations{$id});
                    die "journal compaction found $evidence_error ($id)"
                        if defined $evidence_error;
                }
                $resume_finalization_reservations_at_scan{$id} =
                    { %{$finalizations{$id}} }
                    if ref($job_resume_intent_record_at_scan{$id}) eq 'HASH';
            } else {
                my $job_id = defined($data->{job_id}) ? $data->{job_id} : '';
                my $key = $event . "\0" . $job_id;
                $audit_sequences{$key} = $sequence;
                if ($event eq 'transfer_stop_intent' &&
                        !defined($data->{lifecycle_sequence}) &&
                        $job_lifecycle_at_scan{$job_id}) {
                    # Legacy stop events were scoped by the receiving job
                    # visible at their original journal position. Preserve
                    # that association when the compacted job snapshot moves
                    # ahead of audit records.
                    $audit_lifecycle_overrides{$key} =
                        $job_lifecycle_at_scan{$job_id}{transition_sequence};
                } else {
                    delete $audit_lifecycle_overrides{$key};
                }
                die 'journal compaction audit index exceeds its memory bound'
                    if keys(%audit_sequences) > $MAX_COMPACTION_AUDIT_EVENTS;
            }
        });

        for my $id (keys %compacted_resume_pending_snapshots_at_scan) {
            die "journal compaction found inconsistent compacted resume_pending admission evidence ($id)"
                unless _compacted_resume_pending_snapshot_is_valid(
                    $compacted_resume_pending_snapshots_at_scan{$id},
                    \%tuple_records);
        }

        my %selected;
        my %job_by_sequence = map {
            $latest_job_sequence{$_} => $_
        } keys %latest_job_sequence;
        $selected{$latest_job_sequence{$_}} = ['job', $_]
            for keys %latest_job_sequence;
        for my $tuple (keys %tuple_records) {
            my $reservation = $tuple_records{$tuple};
            $selected{$reservation->{sequence}} = ['tuple', $tuple];
        }
        for my $key (keys %audit_sequences) {
            $selected{$audit_sequences{$key}} = ['audit', $key];
        }
        die 'journal compaction found finalization metadata without a job'
            if grep { !exists $latest_job_sequence{$_} } keys %finalizations;
        # Replay the latest job snapshots first so every retained audit event
        # sees its job, even when its original event preceded a later terminal
        # transition. Keep job snapshots chronological to preserve the bounded
        # recent-terminal cache semantics; emit all other retained records in
        # their original relative order.
        my @ordered_sequences = sort { $a <=> $b } keys %selected;
        my @job_sequences =
            grep { $selected{$_}[0] eq 'job' } @ordered_sequences;
        my @other_sequences =
            grep { $selected{$_}[0] ne 'job' } @ordered_sequences;
        my %tuple_by_sequence = map {
            $tuple_records{$_}{sequence} => $_
        } keys %tuple_records;
        my $emit_selected_record = sub {
            my ($record, $sequence) = @_;
            my $kind = $selected{$sequence}[0];
            if ($kind eq 'job') {
                my $id = $job_by_sequence{$sequence};
                my $job = clone_job($record->{data}{job});
                $job->{finalization} = { %{$finalizations{$id}} }
                    if exists $finalizations{$id};
                # The entire input stream was checked above; retain an explicit
                # marker so replay can distinguish this validated compacted
                # state from an ordinary job creation record.
                my %snapshot = (job => $job);
                $snapshot{compacted_resume_snapshot} = 1
                    if exists($job->{resume_intent});
                $emit->('job_created', \%snapshot);
            } elsif ($kind eq 'tuple') {
                my $tuple = $tuple_by_sequence{$sequence};
                my $reservation = $tuple_records{$tuple};
                $emit->($reservation->{event}, { tuple => $tuple,
                    job_id => $reservation->{job_id} });
            } else {
                my $key = $selected{$sequence}[1];
                if (exists $audit_lifecycle_overrides{$key}) {
                    my %data = (%{$record->{data}},
                        lifecycle_sequence => $audit_lifecycle_overrides{$key});
                    $emit->($record->{event}, \%data);
                } else {
                    $emit->($record->{event}, $record->{data});
                }
            }
        };
        my $emit_sequence_set = sub {
            my ($sequences) = @_;
            my $next_selected = 0;
            $journal->replay(on_event => sub {
                my ($record, $sequence) = @_;
                return if $next_selected >= @$sequences ||
                    $sequence != $sequences->[$next_selected];
                $emit_selected_record->($record, $sequence);
                $next_selected++;
            });
            die 'journal changed while compaction was building its snapshot'
                unless $next_selected == @$sequences;
        };
        # Keep replay dependencies intact while ensuring an old stopped-job
        # audit cannot precede its latest job snapshot in the compacted file.
        # Jobs are streamed first; tuple and audit events follow in source order.
        $emit_sequence_set->(\@job_sequences);
        $emit_sequence_set->(\@other_sequences);
    });
}

sub reserve_finalization {
    my ($self, $id, %meta) = @_;
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    die 'job is not receiving or already finalizing'
        unless $job->{state} eq 'receiving' || $job->{state} eq 'finalizing';
    my $resume_token = delete $meta{_resume_finalization_token};
    my $resume_verification = delete $meta{_resume_verification_record};
    if (exists $job->{resume_intent}) {
        die 'resumed jobs require the checked whole-file verification handoff'
            unless ref($resume_token) eq 'HASH' &&
                $resume_token == $RESUME_FINALIZATION_TOKEN &&
                _resume_verification_matches_intent(
                    $resume_verification, $job->{resume_intent}) &&
                _same_path($meta{staging_path}, $resume_verification->{path}) &&
                defined($meta{expected_size}) &&
                "$meta{expected_size}" eq "$resume_verification->{total_size}" &&
                defined($meta{expected_sha256}) &&
                lc($meta{expected_sha256}) eq $resume_verification->{expected_sha256};
    } else {
        die 'ordinary finalization cannot accept a resume verification handoff'
            if defined($resume_token) || defined($resume_verification);
    }
    die 'finalization staging path is required' unless defined($meta{staging_path}) && length($meta{staging_path});
    die 'finalization destination path is required' unless defined($meta{destination_path}) && length($meta{destination_path});
    die 'finalization size is invalid' unless defined($meta{expected_size}) && $meta{expected_size} =~ /\A\d+\z/;
    die 'finalization SHA-256 is invalid' unless defined($meta{expected_sha256}) && $meta{expected_sha256} =~ /\A[a-f0-9]{64}\z/;
    my $finalization = {
        status => 'reserved', staging_path => $meta{staging_path},
        destination_path => $meta{destination_path}, expected_size => 0 + $meta{expected_size},
        expected_sha256 => lc($meta{expected_sha256}),
        (defined($resume_verification)
            ? (resume_verification => $resume_verification) : ()),
    };
    $self->{journal}->append('finalization_reservation', {
        job_id => $id, staging_path => $meta{staging_path},
        destination_path => $meta{destination_path}, expected_size => $meta{expected_size},
        expected_sha256 => lc($meta{expected_sha256}),
        (defined($resume_verification)
            ? (resume_verification => $resume_verification) : ()),
    });
    $self->{finalizations}{$id} = $finalization;
    return $job->{state} eq 'receiving'
        ? $self->transition($id, 'finalizing', outcome => 'finalization_started',
            data => { finalization => $finalization })
        : clone_job($job);
}

sub reserve_verified_resume_finalization {
    my ($self, $id, %args) = @_;
    die 'coordinator is closed' if $self->{closed};
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    die 'verified resume finalization requires a receiving job with a durable resume intent'
        unless $job->{state} eq 'receiving' &&
            ref($job->{resume_intent}) eq 'HASH';
    die 'verified resume finalization destination path is required'
        unless defined($args{destination_path}) && length($args{destination_path});

    my $consumed = consume_resumed_file_verification($args{verification});
    die $consumed->{reason}
        unless ref($consumed) eq 'HASH' &&
            ($consumed->{type} // '') eq 'consumed_resume_verification';
    my $verification = $consumed->{verification};
    die 'verified resumed file does not match the durable resume intent'
        unless _resume_verification_matches_intent(
            $verification, $job->{resume_intent});
    my $current = capture_partial(path => $verification->{path},
        staging_root => $verification->{staging_root},
        expected_identity => $verification->{identity},
        expected_directory_identities => $verification->{directory_identities});
    die 'verified resumed file ownership changed before finalization reservation'
        unless $current->{type} eq 'captured_partial' &&
            JSON::PP->new->canonical(1)->encode($current->{identity}) eq
                JSON::PP->new->canonical(1)->encode($verification->{identity}) &&
            JSON::PP->new->canonical(1)->encode($current->{directory_identities}) eq
                JSON::PP->new->canonical(1)->encode($verification->{directory_identities});

    return $self->reserve_finalization($id,
        staging_path => $verification->{path},
        destination_path => $args{destination_path},
        expected_size => $verification->{total_size},
        expected_sha256 => $verification->{expected_sha256},
        _resume_verification_record => $verification,
        _resume_finalization_token => $RESUME_FINALIZATION_TOKEN);
}

sub complete_finalization {
    my ($self, $id, %meta) = @_;
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    die 'job is not finalizing' unless $job->{state} eq 'finalizing';
    my $publication_token = delete $meta{_resume_publication_token};
    my $publication_evidence = delete $meta{_resume_publication_evidence};
    my $finalization_error = _resume_job_finalization_error(
        $job, $self->{finalizations}{$id});
    die "$finalization_error ($id)" if defined $finalization_error;
    my $success = $meta{success} ? 1 : 0;
    if (exists($job->{resume_intent}) && $success) {
        my $reservation = $self->{finalizations}{$id};
        die 'resumed-job publication requires the exclusive verified-file publisher'
            unless ref($publication_token) eq 'HASH' &&
                $publication_token == $RESUME_PUBLICATION_TOKEN &&
                ref($reservation) eq 'HASH' &&
                defined($meta{destination_path}) &&
                _same_path($meta{destination_path}, $reservation->{destination_path}) &&
                defined($meta{observed_size}) &&
                "$meta{observed_size}" eq "$reservation->{expected_size}" &&
                defined($meta{observed_sha256}) &&
                lc($meta{observed_sha256}) eq $reservation->{expected_sha256} &&
                ref($publication_evidence) eq 'HASH';
    } elsif (defined $publication_evidence) {
        die 'publication evidence is only valid for verified resumed-file publication';
    }
    my $result = {
        job_id => $id, success => $success ? JSON::PP::true : JSON::PP::false,
        destination_path => $meta{destination_path}, observed_size => $meta{observed_size},
        observed_sha256 => $meta{observed_sha256}, reason => $meta{reason},
        ($success && exists($job->{resume_intent})
            ? (publication_evidence => $publication_evidence) : ()),
    };
    my $finalization = {
        %{$self->{finalizations}{$id} || $job->{finalization} || {}},
        status => $success ? 'published' : 'unresolved',
        result => {
            success => $success,
            destination_path => $meta{destination_path},
            observed_size => $meta{observed_size},
            observed_sha256 => $meta{observed_sha256},
            reason => $meta{reason},
            (exists($result->{publication_evidence})
                ? (publication_evidence => $result->{publication_evidence}) : ()),
        },
    };
    if (exists($job->{resume_intent}) && $success) {
        my $evidence_error = _resume_publication_success_evidence_error($finalization);
        die "$evidence_error ($id)" if defined $evidence_error;
    }
    $self->{journal}->append('finalization_result', $result);
    $self->{finalizations}{$id} = $finalization;
    return $self->transition($id, $success ? 'complete' : 'needs_attention',
        outcome => $success ? 'finalized' : 'finalization_unresolved', reason => $meta{reason},
        data => { finalization => $finalization },
        ($success && exists($job->{resume_intent})
            ? (_resume_publication_token => $publication_token) : ()));
}

sub publish_verified_resume_finalization {
    my ($self, $id) = @_;
    die 'coordinator is closed' if $self->{closed};
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    die 'verified resume publication requires a finalizing resumed job'
        unless $job->{state} eq 'finalizing' &&
            ref($job->{resume_intent}) eq 'HASH';
    my $reservation = $self->{finalizations}{$id};
    die 'verified resume publication lacks its checked finalization reservation'
        unless ref($reservation) eq 'HASH' &&
            !_resume_job_finalization_error($job, $reservation);
    my $verification = $reservation->{resume_verification};
    die 'verified resume publication cannot target the staging file itself'
        if _same_path($reservation->{staging_path},
            $reservation->{destination_path});

    my $source = capture_partial(
        path => $reservation->{staging_path},
        staging_root => $verification->{staging_root},
        expected_identity => $verification->{identity},
        expected_directory_identities => $verification->{directory_identities});
    die 'verified resume staging ownership changed before publication'
        unless ($source->{type} // '') eq 'captured_partial' &&
            JSON::PP->new->canonical(1)->encode($source->{identity}) eq
                JSON::PP->new->canonical(1)->encode($verification->{identity}) &&
            JSON::PP->new->canonical(1)->encode($source->{directory_identities}) eq
                JSON::PP->new->canonical(1)->encode($verification->{directory_identities}) &&
            "$source->{identity}{size}" eq "$reservation->{expected_size}" &&
            ($source->{identity}{mode} & 0777) == 0600 &&
            "$source->{identity}{links}" eq '1';

    # link() creates the destination atomically and fails if any file or
    # symlink already occupies that name. It also proves the published bytes
    # are the exact inode that passed whole-file verification. Cross-volume
    # publication is deliberately refused; it needs its own bounded copier.
    unless ($self->_link_resume_staging(
            $reservation->{staging_path}, $reservation->{destination_path})) {
        my $error = "$!";
        my $completed = $self->complete_finalization($id,
            success => 0, destination_path => $reservation->{destination_path},
            observed_size => $reservation->{expected_size},
            observed_sha256 => $reservation->{expected_sha256},
            reason => "exclusive same-filesystem publication failed: $error");
        return { type => 'publication_refused', reason => $error, job => $completed };
    }

    my $proof = $self->_verify_finalization_file($reservation);
    my @source_stat = lstat($reservation->{staging_path});
    my $published_matches = ref($proof) eq 'HASH' && $proof->{ok} &&
        $proof->{device} == $verification->{identity}{device} &&
        $proof->{inode} == $verification->{identity}{inode} &&
        $proof->{size} == $reservation->{expected_size} &&
        $proof->{links} == 2 && ($proof->{mode} & 0777) == 0600 &&
        @source_stat && ($source_stat[2] & 0170000) == 0100000 &&
        $source_stat[0] == $proof->{device} &&
        $source_stat[1] == $proof->{inode} &&
        $source_stat[7] == $reservation->{expected_size} &&
        ($source_stat[2] & 0777) == 0600;
    unless ($published_matches) {
        # Remove only the destination name if it still refers to the inode
        # reserved by this publication. Preserve unrelated replacements.
        my @current_destination = lstat($reservation->{destination_path});
        unlink($reservation->{destination_path})
            if @source_stat && @current_destination &&
                ($current_destination[2] & 0170000) == 0100000 &&
                $current_destination[0] == $verification->{identity}{device} &&
                $current_destination[1] == $verification->{identity}{inode};
        my $reason = ref($proof) eq 'HASH' && defined($proof->{reason})
            ? $proof->{reason}
            : 'published destination did not retain the verified staging inode';
        my $completed = $self->complete_finalization($id,
            success => 0, destination_path => $reservation->{destination_path},
            observed_size => $reservation->{expected_size},
            observed_sha256 => ref($proof) eq 'HASH' ? $proof->{sha256} : undef,
            reason => $reason);
        return { type => 'publication_refused',
            reason => $reason, job => $completed };
    }

    # Persist the destination directory entry before journaling job completion.
    # If syncing fails, both names remain and the job stays finalizing for
    # conservative restart reconciliation.
    my $directory_synced = eval {
        $self->{journal}->sync_parent_directory($reservation->{destination_path});
        1;
    };
    unless ($directory_synced) {
        my $error = $@ || 'destination directory sync failed';
        return { type => 'publication_refused',
            reason => "destination directory durable sync failed: $error",
            job => clone_job($self->{jobs}{$id}),
            staging_path => $reservation->{staging_path} };
    }

    unless (_path_matches_file_proof(
            $reservation->{destination_path}, $proof) &&
            _path_matches_file_proof($reservation->{staging_path}, $proof)) {
        my @current_destination = lstat($reservation->{destination_path});
        unlink($reservation->{destination_path})
            if @current_destination && ($current_destination[2] & 0170000) == 0100000 &&
                $current_destination[0] == $proof->{device} &&
                $current_destination[1] == $proof->{inode};
        my $reason = 'published destination or staging name changed before durable completion';
        my $completed = $self->complete_finalization($id,
            success => 0, destination_path => $reservation->{destination_path},
            observed_size => $proof->{size}, observed_sha256 => $proof->{sha256},
            reason => $reason);
        return { type => 'publication_refused', reason => $reason, job => $completed };
    }

    my $publication_evidence = {
        schema_version => 1,
        method => 'exclusive_hard_link',
        destination_path => $reservation->{destination_path},
        device => $proof->{device}, inode => $proof->{inode},
        size => $proof->{size}, sha256 => $proof->{sha256},
        content_verified => JSON::PP::true,
        payload_synced => JSON::PP::true,
        directory_synced => JSON::PP::true,
    };

    my $completed = $self->complete_finalization($id,
        success => 1, destination_path => $reservation->{destination_path},
        observed_size => $reservation->{expected_size},
        observed_sha256 => $reservation->{expected_sha256},
        reason => 'published by exclusive hard link after matching SHA-256 and syncing payload and destination directory',
        _resume_publication_evidence => $publication_evidence,
        _resume_publication_token => $RESUME_PUBLICATION_TOKEN);

    my @source_after = lstat($reservation->{staging_path});
    my $source_removed = @source_after &&
        ($source_after[2] & 0170000) == 0100000 &&
        $source_after[0] == $verification->{identity}{device} &&
        $source_after[1] == $verification->{identity}{inode} &&
        unlink($reservation->{staging_path});
    return { type => 'published_verified_resume', job => $completed,
        staging_removed => $source_removed ? 1 : 0,
        ($source_removed ? () : (staging_path => $reservation->{staging_path})) };
}

sub _link_resume_staging {
    my ($self, $staging_path, $destination_path) = @_;
    return link($staging_path, $destination_path);
}

sub mark_interrupted {
    my ($self, $id, %meta) = @_;
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    die 'job is not receiving' unless $job->{state} eq 'receiving';
    return $self->transition($id, 'interrupted',
        reason => $meta{reason} // 'DCC transfer stopped before full completion',
        outcome => $meta{outcome} // 'transfer_interrupted',
        data => { partial => { path => $meta{path}, size => $meta{size},
            staging_root => $meta{staging_root},
            receive_path => $meta{receive_path},
            receive_identity => $meta{receive_identity},
            source_invalid => $meta{source_invalid} ? JSON::PP::true : JSON::PP::false,
            # Missing proof must fail closed. Callers attest only after an
            # orderly DCC close stack or confirmed native destruction.
            writer_closed => $meta{writer_closed}
                ? JSON::PP::true : JSON::PP::false,
            total_size => $meta{total_size}, offered_basename => $meta{offered_basename},
            captured_at => time(), resume_supported => JSON::PP::false } });
}

sub seal_interrupted_partial {
    my ($self, $id, %seal) = @_;
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    die 'partial digest can only be sealed for an interrupted job'
        unless $job->{state} eq 'interrupted';
    my $partial = $job->{partial};
    die 'interrupted writer is not closed or partial ownership is missing'
        unless ref($partial) eq 'HASH' &&
            $partial->{writer_closed} &&
            ($partial->{ownership_status} // '') eq 'captured' &&
            ($partial->{digest_status} // '') eq 'not-sealed' &&
            ref($partial->{file_identity}) eq 'HASH';
    die 'sealed partial digest is invalid'
        unless defined($seal{sha256}) && $seal{sha256} =~ /\A[0-9a-f]{64}\z/i;
    die 'sealed partial path or staging root changed'
        unless defined($seal{path}) && defined($partial->{path}) &&
            File::Spec->canonpath(File::Spec->rel2abs($seal{path})) eq
                File::Spec->canonpath(File::Spec->rel2abs($partial->{path})) &&
            defined($seal{staging_root}) && defined($partial->{staging_root}) &&
            File::Spec->canonpath(File::Spec->rel2abs($seal{staging_root})) eq
                File::Spec->canonpath(File::Spec->rel2abs($partial->{staging_root}));
    die 'sealed partial identity or length changed'
        unless ref($seal{identity}) eq 'HASH' &&
            JSON::PP->new->canonical(1)->encode($seal{identity}) eq
                JSON::PP->new->canonical(1)->encode($partial->{file_identity}) &&
            defined($seal{size}) && $seal{size} =~ /\A\d+\z/ &&
            $seal{size} > 0 && $seal{size} < ($partial->{total_size} // 0) &&
            $seal{size} == ($partial->{file_identity}{size} // -1) &&
            $seal{size} == ($partial->{size} // -1);

    my %updated_partial = %$partial;
    $updated_partial{digest_status} = 'sealed';
    $updated_partial{partial_sha256} = lc($seal{sha256});
    $updated_partial{sealed_at} = time();
    my $updated = clone_job($job);
    $updated->{transition_sequence}++;
    $updated->{updated_at} = time();
    $updated->{outcome} = 'partial_digest_sealed';
    $updated->{reason} = 'interrupted partial was hashed incrementally after DCC writer closure';
    $updated->{partial} = \%updated_partial;
    push @{$updated->{outcomes}}, {
        type => 'partial_digest_sealed', at => $updated->{updated_at},
        detail => $updated->{reason},
    };
    validate_job($updated);
    $self->{journal}->append('job_transition', { job => $updated });
    $self->_retain_job($updated);
    return clone_job($updated);
}

sub begin_resume_intent {
    my ($self, $id, %args) = @_;
    die 'coordinator is closed' if $self->{closed};
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    die 'job is not interrupted' unless $job->{state} eq 'interrupted';
    die 'this job already has a durable resume attempt'
        if exists $job->{resume_intent};

    my $profile = $args{profile};
    die 'production native resume capability is unsupported; only test-only profiles may exercise admission'
        unless ref($profile) eq 'HASH' && $profile->{supported} &&
            defined($profile->{name}) && !ref($profile->{name}) &&
            $profile->{name} =~ /\Atest-only-/;
    die 'native resume capability profile name is invalid'
        unless defined($profile->{name}) && !ref($profile->{name}) &&
            $profile->{name} =~ /\A[\x20-\x7e]{1,96}\z/;

    my $context = $job->{context};
    for my $field (qw(process_incarnation connection_identity connection_epoch)) {
        die "current $field does not match the interrupted job"
            unless defined($args{$field}) && !ref($args{$field}) &&
                defined($context->{$field}) &&
                "$args{$field}" eq "$context->{$field}";
    }
    die 'resume connection epoch is invalid'
        unless $args{connection_epoch} =~ /\A[1-9][0-9]{0,18}\z/;

    my $partial = $job->{partial};
    die 'interrupted partial is not closed, owned, and sealed'
        unless ref($partial) eq 'HASH' && $partial->{writer_closed} &&
            ($partial->{ownership_status} // '') eq 'captured' &&
            ($partial->{digest_status} // '') eq 'sealed' &&
            ref($partial->{file_identity}) eq 'HASH' &&
            defined($partial->{partial_sha256}) &&
            $partial->{partial_sha256} =~ /\A[a-f0-9]{64}\z/ &&
            defined($partial->{total_size}) && $partial->{total_size} =~ /\A[1-9][0-9]*\z/ &&
            defined($partial->{size}) && $partial->{size} =~ /\A[1-9][0-9]*\z/ &&
            $partial->{size} < $partial->{total_size};
    my $trusted = $job->{trusted_content_digest};
    die 'trusted whole-file digest is missing'
        unless ref($trusted) eq 'HASH' &&
            defined($trusted->{sha256}) && $trusted->{sha256} =~ /\A[a-f0-9]{64}\z/;

    my $offer = $args{offer};
    die 'continuation offer evidence is malformed' unless ref($offer) eq 'HASH';
    die 'interrupted native DCC lifecycle identity is missing'
        unless defined($job->{accepted_lifecycle}) &&
            !ref($job->{accepted_lifecycle}) && length($job->{accepted_lifecycle});
    for my $field (qw(offer_kind connection_identity connection_epoch server_tag sender
            offered_basename total_size native_lifecycle_identity)) {
        die "continuation offer lacks $field"
            unless defined($offer->{$field}) && !ref($offer->{$field}) &&
                length($offer->{$field});
    }
    die 'continuation offer is not an incoming file-send offer'
        unless $offer->{offer_kind} eq 'incoming-file-send';
    die 'continuation offer belongs to a different connection'
        unless "$offer->{connection_identity}" eq "$args{connection_identity}" &&
            "$offer->{connection_epoch}" eq "$args{connection_epoch}" &&
            (!defined($context->{server_tag}) ||
                "$offer->{server_tag}" eq "$context->{server_tag}");
    die 'continuation offer size differs from the selected file'
        unless $offer->{total_size} =~ /\A(?:0|[1-9][0-9]{0,18})\z/ &&
            "$offer->{total_size}" eq "$partial->{total_size}";
    die 'continuation offer lifecycle identity is malformed'
        unless $offer->{native_lifecycle_identity} =~ /\A[\x21-\x7e]{1,128}\z/;
    die 'continuation offer reuses the interrupted native lifecycle'
        if "$offer->{native_lifecycle_identity}" eq "$job->{accepted_lifecycle}";

    my $selected_name = $job->{selection}{offered_basename} //
        $job->{selection}{basename} // $job->{selection}{name};
    die 'continuation offer basename differs from the immutable selection'
        unless defined($selected_name) &&
            $offer->{offered_basename} eq $selected_name &&
            (!defined($partial->{offered_basename}) ||
                $offer->{offered_basename} eq $partial->{offered_basename});
    my $mapping = $context->{casemapping} // 'rfc1459';
    my $peer = $job->{selection}{expected_peer} //
        $job->{selection}{sender} // $context->{expected_peer};
    my $offer_tuple = tuple_key(network_profile => $job->{network_profile},
        peer => $offer->{sender}, basename => $offer->{offered_basename},
        casemapping => $mapping);
    die 'continuation offer does not match the job reserved DCC identity'
        unless defined($peer) && defined($offer_tuple) &&
            exists($self->{tuples}{$offer_tuple}) &&
            $self->{tuples}{$offer_tuple} eq $id;

    my $validated = $args{validated_partial};
    die 'incrementally validated partial snapshot is required'
        unless ref($validated) eq 'HASH' &&
            ($validated->{type} // '') eq 'valid_partial' &&
            defined($validated->{source_path}) &&
            defined($validated->{snapshot_path}) &&
            defined($validated->{staging_root}) &&
            defined($validated->{size}) && $validated->{size} =~ /\A[1-9][0-9]*\z/ &&
            defined($validated->{sha256}) && $validated->{sha256} =~ /\A[a-f0-9]{64}\z/ &&
            ref($validated->{identity}) eq 'HASH' &&
            ref($validated->{snapshot_directory_identities}) eq 'ARRAY';
    my $same_path = sub {
        my ($left, $right) = @_;
        return defined($left) && defined($right) &&
            File::Spec->canonpath(File::Spec->rel2abs($left)) eq
                File::Spec->canonpath(File::Spec->rel2abs($right));
    };
    die 'validated snapshot does not correspond to the sealed partial'
        unless $same_path->($validated->{source_path}, $partial->{path}) &&
            $same_path->($validated->{staging_root}, $partial->{staging_root}) &&
            !$same_path->($validated->{snapshot_path}, $partial->{path}) &&
            "$validated->{size}" eq "$partial->{size}" &&
            lc($validated->{sha256}) eq $partial->{partial_sha256};
    my $snapshot = capture_partial(path => $validated->{snapshot_path},
        staging_root => $validated->{staging_root},
        expected_identity => $validated->{identity},
        expected_directory_identities => $validated->{snapshot_directory_identities});
    die 'validated snapshot ownership changed before resume intent'
        unless $snapshot->{type} eq 'captured_partial' &&
            JSON::PP->new->canonical(1)->encode($snapshot->{identity}) eq
                JSON::PP->new->canonical(1)->encode($validated->{identity}) &&
            JSON::PP->new->canonical(1)->encode($snapshot->{directory_identities}) eq
                JSON::PP->new->canonical(1)->encode($validated->{snapshot_directory_identities}) &&
            "$snapshot->{identity}{size}" eq "$partial->{size}" &&
            ($snapshot->{identity}{mode} & 0777) == 0600;

    my $attempt_id = 'resume-' . substr(Digest::SHA::sha256_hex(join("\0",
        $id, $$, time, rand(), $offer->{native_lifecycle_identity}, rand())), 0, 32);
    my $resume_intent = {
        schema_version => 1,
        attempt_id => $attempt_id,
        capability_profile => $profile->{name},
        process_incarnation => "$context->{process_incarnation}",
        connection_identity => "$context->{connection_identity}",
        connection_epoch => "$context->{connection_epoch}",
        server_tag => "$context->{server_tag}",
        previous_lifecycle_identity => "$job->{accepted_lifecycle}",
        offer_lifecycle_identity => "$offer->{native_lifecycle_identity}",
        sender => "$offer->{sender}",
        offered_basename => "$offer->{offered_basename}",
        total_size => "$partial->{total_size}",
        offset => "$partial->{size}",
        partial_sha256 => $partial->{partial_sha256},
        expected_sha256 => $trusted->{sha256},
        source_path => $partial->{path},
        snapshot_path => $validated->{snapshot_path},
        staging_root => $validated->{staging_root},
        snapshot_identity => $snapshot->{identity},
        snapshot_directory_identities => $snapshot->{directory_identities},
        partial_evidence => clone_job({ evidence => $partial })->{evidence},
        partial_binding_sha256 => resume_partial_fingerprint($partial),
        get_dispatched_by_admission => 0,
        selection_replayed_by_admission => 0,
        job_binding_sha256 => resume_binding_fingerprint($job),
        created_at => int(time()),
    };
    my $updated = $self->transition($id, 'resume_pending',
        outcome => 'resume_intent_durable',
        reason => 'validated partial and matching live continuation bound before native RESUME',
        _resume_admission_token => $RESUME_ADMISSION_TOKEN,
        data => { resume_intent => $resume_intent });
    return $updated;
}

sub finalize {
    my ($self, $id, %meta) = @_;
    my $job = $self->{jobs}{$id} or die 'unknown job id';
    $self->reserve_finalization($id, %meta);
    return $self->complete_finalization($id, %meta);
}

sub job {
    my ($self, $id) = @_;
    return unless defined($id) && $id =~ /\Ajob-[a-f0-9]{32}\z/;
    return clone_job($self->{jobs}{$id}) if exists $self->{jobs}{$id};
    return clone_job($self->{terminal_jobs}{$id}) if exists $self->{terminal_jobs}{$id};
    return unless $self->{job_ids}{$id};
    my $job = $self->{journal}->find_job($id);
    return ref($job) eq 'HASH' ? clone_job($job) : undef;
}
sub job_by_web_operation {
    my ($self, $operation_id) = @_;
    return unless defined($operation_id) &&
        $operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
    my $id = $self->{web_operation_jobs}{$operation_id} or return;
    return $self->job($id);
}
sub jobs {
    my ($self) = @_;
    my %all = (%{$self->{terminal_jobs}}, %{$self->{jobs}});
    return { map { $_ => clone_job($all{$_}) } keys %all };
}
sub tuple_owner { return $_[0]{tuples}{$_[1]}; }
sub tuple_count { return $_[0]{tuple_count}; }
sub recovery_events { return [map { { %$_ } } @{$_[0]{recovery}}]; }
sub journal { return $_[0]{journal}; }

sub begin_resume_after_compaction {
    my ($self, %args) = @_;
    die 'coordinator is not suspended for compaction' unless $self->{closed};
    $self->{journal}->begin_compacted_reopen(%args);
    return 1;
}

sub validate_compaction_resume_step {
    my ($self, %args) = @_;
    die 'coordinator is not suspended for compaction' unless $self->{closed};
    my $complete = $self->{journal}->validate_compacted_reopen_step(%args);
    $self->{closed} = 0 if $complete;
    return $complete;
}

sub close {
    my ($self) = @_;
    $self->{closed} = 1;
    return $self->{journal}->close();
}

sub DESTROY { eval { $_[0]->close() }; }

1;
