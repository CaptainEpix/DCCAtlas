# The job journal's compaction.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;

our (%JOBS, %S, %SEARCHBOT, $DOWNLOAD_PATH_OWNER);

sub compaction_pause_reason {
    return $JOBS{compaction_failed}
        ? 'journal compaction could not be verified; reload the script to recover the journal'
        : 'local journal compaction is in progress';
}

sub compaction_is_quiet {
    return 0 if $S{active} || $S{pending_download} || $SEARCHBOT{active} ||
        searchbot_direct_active() || any_find_active() || $DOWNLOAD_PATH_OWNER ||
        has_active_download_transfer() || $JOBS{active_job_id} ||
        $JOBS{run_batch} || $JOBS{compaction_active} ||
        keys(%{$JOBS{outbound_messages} || {}});
    return 0 if $JOBS{scheduler} && $JOBS{scheduler}->pending_count;
    my $coordinator = $JOBS{coordinator} or return 0;
    my $jobs = $coordinator->jobs();
    for my $job (values %$jobs) {
        next if $job->{state} eq 'held' || $job->{state} eq 'needs_attention';
        return 0 unless FServe::Transfer::Job::is_terminal($job->{state});
    }
    return 1;
}

sub fail_journal_compaction {
    my ($reason) = @_;
    Irssi::timeout_remove($JOBS{compaction_validation_timer})
        if defined $JOBS{compaction_validation_timer};
    delete $JOBS{compaction_validation_timer};
    my $coordinator = $JOBS{compaction_coordinator};
    eval { $coordinator->close() if $coordinator };
    $JOBS{coordinator} = undef;
    delete @JOBS{qw(compaction_coordinator compaction_source_identity compaction_result compaction_saved_scheduler)};
    $JOBS{compaction_active} = 1;
    $JOBS{compaction_failed} = 1;
    $JOBS{compaction_worker_id} = undef;
    $reason ||= 'worker result or journal validation was incomplete';
    $reason =~ s/[\r\n]+/ /g;
    p("Journal compaction could not be verified. the job journal stays closed; reload the script to run full journal recovery. $reason");
}

sub complete_journal_compaction {
    my $coordinator = $JOBS{compaction_coordinator};
    my $result = $JOBS{compaction_result};
    unless ($coordinator && ref($result) eq 'HASH') {
        fail_journal_compaction('validated coordinator or worker result is missing');
        return;
    }
    $JOBS{coordinator} = $coordinator;
    delete @JOBS{qw(compaction_coordinator compaction_source_identity compaction_result)};
    delete $JOBS{compaction_failed};
    $JOBS{compaction_active} = 0;
    $JOBS{scheduler} = $JOBS{compaction_saved_scheduler}
        if $JOBS{compaction_saved_scheduler};
    delete $JOBS{compaction_saved_scheduler};
    for my $job (values %{$coordinator->jobs()}) {
        next unless $job->{state} eq 'held';
        next if server_for_job($job, undef);
        job_transition($job->{id}, 'stale', outcome => 'connection_epoch_ended',
            reason => 'saved selection lost its originating live IRC connection while local journal compaction was running');
    }
    p('Local journal compaction completed asynchronously: ' . $result->{old_bytes} .
        ' bytes reduced to ' . $result->{new_bytes} . ' bytes across ' .
        $result->{record_count} . ' retained records. Snapshot integrity was checked in bounded background timer steps. No IRC traffic was sent.');
}

sub schedule_compaction_validation {
    my $timer_api = catalog_worker_timer_api();
    my $timer = eval {
        $timer_api->{schedule}->(10, sub { validate_compaction_step(); });
    };
    unless (defined($timer) && !ref($timer) && $timer =~ /\A[1-9][0-9]*\z/) {
        my $error = $@ || 'Irssi did not register a journal validation timer';
        fail_journal_compaction($error);
        return 0;
    }
    $JOBS{compaction_validation_timer} = $timer;
    return 1;
}

sub validate_compaction_step {
    delete $JOBS{compaction_validation_timer};
    my $coordinator = $JOBS{compaction_coordinator};
    unless ($coordinator) {
        fail_journal_compaction('suspended coordinator disappeared during journal validation');
        return;
    }
    my $complete = eval {
        $coordinator->validate_compaction_resume_step(
            max_bytes => 262_144,
            max_records => 4);
    };
    unless (defined($complete) && !$@) {
        my $error = $@ || 'journal hash-chain validation failed';
        fail_journal_compaction($error);
        return;
    }
    if (!$complete) {
        schedule_compaction_validation();
        return;
    }
    complete_journal_compaction();
}

sub finish_journal_compaction {
    my ($status, $stderr, $failure, $cancelled, $result) = @_;
    $JOBS{compaction_worker_id} = undef;
    my $coordinator = $JOBS{compaction_coordinator};
    my $expected_source = $JOBS{compaction_source_identity};
    my $worker_ok = !$failure && !$cancelled && defined($status) && $status == 0 &&
        ref($result) eq 'HASH' && ($result->{event} // '') eq 'result';
    unless ($worker_ok && $coordinator && ref($expected_source) eq 'HASH') {
        my $reason = $failure || ($result && $result->{reason}) || $stderr ||
            'worker exited without a successful result';
        fail_journal_compaction($reason);
        return;
    }
    my $source = $result->{source_identity};
    my $same_source = ref($source) eq 'HASH' &&
        ($source->{bytes} // '') eq ($expected_source->{bytes} // '') &&
        ($source->{sequence} // '') eq ($expected_source->{sequence} // '') &&
        ($source->{tail_hash} // '') eq ($expected_source->{tail_hash} // '');
    unless ($same_source) {
        fail_journal_compaction('worker source identity did not match the suspended coordinator');
        return;
    }
    my $began = eval {
        $coordinator->begin_resume_after_compaction(
            snapshot_identity => $result->{snapshot_identity},
            file_identity => $result->{file_identity});
        1;
    };
    unless ($began) {
        my $error = $@ || 'could not lock the compacted journal for integrity validation';
        fail_journal_compaction($error);
        return;
    }
    $JOBS{compaction_result} = $result;
    $JOBS{compaction_saved_scheduler} = $JOBS{scheduler};
    schedule_compaction_validation();
}

1;
