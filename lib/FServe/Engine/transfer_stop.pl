# Stopping a transfer: stop intents, and partial files kept and sealed.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use JSON::PP ();
use Scalar::Util qw(refaddr);

our (%JOBS, %S, %SEARCHBOT_DIRECT, %TRANSFERS, $DOWNLOAD_PATH_OWNER);

sub record_transfer_stop_intent {
    my ($transfer, $intent) = @_;
    return 1 unless ref($transfer) eq 'HASH' &&
        defined($transfer->{phase6_job_id}) && jobs_ready();
    my $recorded = eval {
        $JOBS{coordinator}->record_transfer_stop_intent(
            job_id => $transfer->{phase6_job_id},
            transfer_key => $transfer->{key},
            request_id => $transfer->{request_id},
            intent => $intent || {},
        );
        1;
    };
    unless ($recorded) {
        my $error = $@ || 'stop intent could not be recorded';
        $error =~ s/[\r\n]+/ /g;
        p("The job journal could not record the stop intent for $transfer->{phase6_job_id}: $error");
    }
    return $recorded ? 1 : 0;
}

sub transfer_stop_pending {
    my ($job_id) = @_;
    return 0 unless defined $job_id;
    return scalar grep {
        ($_->{phase6_job_id} // '') eq $job_id &&
            ref($_->{stop_intent}) eq 'HASH'
    } values %TRANSFERS;
}

sub transfer_partial_evidence {
    my ($transfer, $dcc, $writer_closed) = @_;
    my $path = $transfer->{receive_source} // $transfer->{dcc_file} //
        ($dcc ? ($dcc->{file} // '') : '');
    my $advertised = $transfer->{expected_size} // ($dcc ? $dcc->{size} : undef);
    my $size = length($path) && -f $path
        ? -s $path : ($dcc ? ($dcc->{transfd} // 0) : 0);
    return {
        path => $path,
        size => $size,
        partial_receive_metadata($transfer),
        staging_root => (($transfer->{file} && $transfer->{file}{staging_dir}) //
            $transfer->{staging_dir}),
        total_size => $advertised,
        offered_basename => $transfer->{offered_name},
        writer_closed => $writer_closed ? JSON::PP::true : JSON::PP::false,
        captured_at => time(),
        resume_supported => JSON::PP::false,
    };
}

sub finish_stopped_transfer {
    my ($transfer, $dcc) = @_;
    my $intent = $transfer->{stop_intent};
    return 0 unless ref($intent) eq 'HASH' && $intent->{writer_closed};
    my $job_id = $transfer->{phase6_job_id};
    my $phase6_available = defined($job_id) ? jobs_ready() : 1;
    unless ($phase6_available) {
        p("DCC writer closed, but the job journal is unavailable for $job_id; its transfer remains reserved for recovery.");
        return 0;
    }
    my $job = defined($job_id) ? $JOBS{coordinator}->job($job_id) : undef;
    if (defined($job_id) && !$job) {
        p("DCC writer closed, but the job journal could not find job $job_id; its transfer remains reserved for recovery.");
        return 0;
    }
    if ($job && $job->{state} eq 'receiving') {
        my $partial = transfer_partial_evidence($transfer, $dcc, 1);
        my $recorded;
        if (($intent->{job_state} // '') eq 'cancelled') {
            $recorded = job_transition($job_id, 'cancelled',
                outcome => $intent->{job_outcome} // 'local_queue_cancelled',
                reason => $intent->{reason},
                data => { partial => $partial, stop_intent => { %$intent } });
        } elsif (($intent->{job_state} // '') eq 'interrupted') {
            $recorded = mark_interrupted($job_id, %$partial,
                outcome => $intent->{job_outcome} // 'transfer_interrupted',
                reason => $intent->{reason});
        } else {
            $recorded = retire_job($job_id,
                $intent->{job_outcome} // 'failed', $intent->{reason});
        }
        unless ($recorded) {
            log_to_path($transfer->{log_file}, 'STOPPED_TRANSFER_OUTCOME_UNRECORDED',
                'job=' . $job_id . ' key=' . ($transfer->{key} // ''));
            p("DCC writer closed, but the job journal could not record the stopped outcome for $job_id; the transfer remains reserved for recovery.");
            return 0;
        }
    } elsif ($job && !FServe::Transfer::Job::is_terminal($job->{state})) {
        my $recorded = retire_job($job_id,
            $intent->{job_outcome} // 'failed', $intent->{reason});
        unless ($recorded) {
            p("DCC writer closed, but the job journal could not retire $job_id; its transfer remains reserved for recovery.");
            return 0;
        }
    }

    if (($transfer->{kind} // '') eq 'searchbot_content' &&
        ($SEARCHBOT_DIRECT{request_id} // '') eq ($transfer->{request_id} // '')) {
        clear_searchbot_direct_timer(\%SEARCHBOT_DIRECT);
        $SEARCHBOT_DIRECT{state} = $intent->{request_state} // 'interrupted';
        $SEARCHBOT_DIRECT{terminal_reason} = $intent->{reason};
        $SEARCHBOT_DIRECT{retiring} = 1;
    }
    delete $TRANSFERS{$transfer->{key}}
        if defined($transfer->{key}) && $TRANSFERS{$transfer->{key}} &&
            refaddr($TRANSFERS{$transfer->{key}}) == refaddr($transfer->{_binding});
    release_pending_manifest_lease($transfer->{file});
    release_download_path_owner($transfer);

    if (session_is_current($transfer->{generation}) && $S{pending_download} &&
        ($S{pending_download}{request_token} || 0) == ($transfer->{request_token} || 0)) {
        $S{pending_download} = undef;
        $S{phase} = 'error';
        restore_download_path_to_base() unless $DOWNLOAD_PATH_OWNER;
    }
    log_to_path($transfer->{log_file}, 'TRANSFER_STOP_CONFIRMED',
        'job=' . ($job_id // '') . ' outcome=' .
        safe_field($intent->{job_outcome} // 'stopped') . ' reason=' .
        safe_field($intent->{reason} // ''));
    return 1;
}

sub request_transfer_stop {
    my ($transfer, $intent) = @_;
    return 0 unless ref($transfer) eq 'HASH';
    unless (ref($transfer->{stop_intent}) eq 'HASH') {
        $transfer->{stop_intent} = {
            %{$intent || {}},
            requested_at => time(),
            writer_closed => 0,
        };
        record_transfer_stop_intent($transfer, $transfer->{stop_intent});
    }
    my $saved = $transfer->{stop_intent};
    if (($transfer->{kind} // '') eq 'searchbot_content' &&
        ($SEARCHBOT_DIRECT{request_id} // '') eq ($transfer->{request_id} // '')) {
        $SEARCHBOT_DIRECT{retiring} = 1;
    }
    if ($saved->{writer_closed}) {
        my %snapshot = (%$transfer, _binding => $transfer,
            dcc => $transfer->{dcc});
        my $finished = finish_stopped_transfer(\%snapshot, $transfer->{dcc});
        resume_guard_release_if_owned($transfer->{key}, 0)
            if $finished;
        return $finished;
    }
    if ($saved->{close_pending}) {
        if (($transfer->{kind} // '') eq 'searchbot_content' &&
            ($SEARCHBOT_DIRECT{request_id} // '') eq ($transfer->{request_id} // '')) {
            $SEARCHBOT_DIRECT{state} = 'close_pending';
            $SEARCHBOT_DIRECT{terminal_reason} = $saved->{reason};
        }
        return 0;
    }
    my $dcc = $transfer->{dcc};
    return 0 unless $dcc;
    $transfer->{suppress_destroy_finalize} = 1;
    my $closed = eval { $dcc->destroy(); 1 } ? 1 : 0;
    delete $transfer->{suppress_destroy_finalize};
    if ($closed) {
        $saved->{writer_closed} = 1;
        delete $saved->{close_pending};
        my %snapshot = (%$transfer, _binding => $transfer, dcc => $dcc);
        my $finished = finish_stopped_transfer(\%snapshot, $dcc);
        resume_guard_release_if_owned($transfer->{key}, 0)
            if $finished;
        return $finished;
    }
    $saved->{close_pending} = 1;
    if (($transfer->{kind} // '') eq 'searchbot_content' &&
        ($SEARCHBOT_DIRECT{request_id} // '') eq ($transfer->{request_id} // '')) {
        clear_searchbot_direct_timer(\%SEARCHBOT_DIRECT);
        $SEARCHBOT_DIRECT{state} = 'close_pending';
        $SEARCHBOT_DIRECT{terminal_reason} = $saved->{reason};
    }
    log_to_path($transfer->{log_file}, 'TRANSFER_CLOSE_PENDING',
        'job=' . ($transfer->{phase6_job_id} // '') .
        ' reason=' . safe_field($saved->{reason} // ''));
    p('Could not confirm native DCC writer closure; its transfer and staging ownership remain reserved.');
    return 0;
}

sub schedule_partial_seal_tick {
    my ($delay_ms) = @_;
    return if defined $JOBS{partial_seal_timer};
    my $queue = $JOBS{partial_seal_queue} || [];
    return unless @$queue;
    my $timer = eval { Irssi::timeout_add_once($delay_ms, \&partial_seal_tick, undef) };
    unless (defined $timer) {
        p('Interrupted partial remains owned but unsealed: Irssi could not schedule the cooperative digest worker.');
        cancel_partial_sealers();
        return;
    }
    $JOBS{partial_seal_timer} = $timer;
}

sub schedule_partial_seal {
    my ($job_id) = @_;
    return unless defined($job_id) && length($job_id) && jobs_ready();
    my $job = $JOBS{coordinator}->job($job_id) or return;
    my $partial = $job->{partial};
    return unless $job->{state} eq 'interrupted' && ref($partial) eq 'HASH' &&
        $partial->{writer_closed} &&
        ($partial->{ownership_status} // '') eq 'captured' &&
        ($partial->{digest_status} // '') eq 'not-sealed' &&
        ref($partial->{file_identity}) eq 'HASH' &&
        defined($partial->{path}) && defined($partial->{staging_root}) &&
        defined($partial->{total_size}) && defined($partial->{size}) &&
        $partial->{size} > 0 && $partial->{size} < $partial->{total_size};
    $JOBS{partial_sealers} ||= {};
    return if $JOBS{partial_sealers}{$job_id};
    $JOBS{partial_sealers}{$job_id} = { session => undef };
    $JOBS{partial_seal_queue} ||= [];
    push @{$JOBS{partial_seal_queue}}, $job_id;
    schedule_partial_seal_tick(25);
}

sub partial_seal_tick {
    delete $JOBS{partial_seal_timer};
    my $queue = $JOBS{partial_seal_queue} || [];
    while (@$queue) {
        my $job_id = shift @$queue;
        my $entry = $JOBS{partial_sealers}{$job_id} or next;
        if ($JOBS{compaction_active}) {
            unshift @$queue, $job_id;
            schedule_partial_seal_tick(10);
            return;
        }
        my $job = $JOBS{coordinator}
            ? $JOBS{coordinator}->job($job_id) : undef;
        my $partial = $job ? $job->{partial} : undef;
        unless ($job && $job->{state} eq 'interrupted' && ref($partial) eq 'HASH' &&
                $partial->{writer_closed} &&
                ($partial->{ownership_status} // '') eq 'captured' &&
                ($partial->{digest_status} // '') eq 'not-sealed') {
            FServe::Transfer::Resume::cancel_partial_seal($entry->{session})
                if $entry->{session};
            delete $JOBS{partial_sealers}{$job_id};
            schedule_partial_seal_tick(10) if @$queue;
            return if @$queue;
            next;
        }

        unless ($entry->{session}) {
            my $started = eval {
                FServe::Transfer::Resume::begin_partial_seal(
                    path => $partial->{path}, staging_root => $partial->{staging_root},
                    expected_identity => $partial->{file_identity},
                    total_size => $partial->{total_size});
            };
            if (!$started || $@ || ($started->{type} // '') ne 'sealing') {
                my $reason = $@ || ($started ? $started->{reason} : undef) ||
                    'partial ownership or closed-writer verification failed';
                $reason =~ s/[\r\n]+/ /g;
                p("Interrupted partial for $job_id remains unsealed: $reason.");
                delete $JOBS{partial_sealers}{$job_id};
                schedule_partial_seal_tick(10) if @$queue;
                return if @$queue;
                next;
            }
            $entry->{session} = $started;
        }

        my $result = eval {
            FServe::Transfer::Resume::step_partial_seal($entry->{session}, 64 * 1024);
        };
        if (!$result || $@) {
            my $reason = $@ || 'partial digest worker returned no result';
            $reason =~ s/[\r\n]+/ /g;
            FServe::Transfer::Resume::cancel_partial_seal($entry->{session});
            p("Interrupted partial for $job_id remains unsealed: $reason.");
            delete $JOBS{partial_sealers}{$job_id};
            schedule_partial_seal_tick(10) if @$queue;
            return if @$queue;
            next;
        }
        if (($result->{type} // '') eq 'in_progress') {
            push @$queue, $job_id;
            schedule_partial_seal_tick(10);
            return;
        }
        if (($result->{type} // '') eq 'sealed_partial') {
            my $saved = eval {
                $JOBS{coordinator}->seal_interrupted_partial($job_id, %$result);
            };
            if ($saved && !$@) {
                p("Interrupted partial for $job_id was sealed (" . $result->{size} .
                    ' bytes; SHA-256 ' . $result->{sha256} . ').');
            } else {
                my $reason = $@ || 'durable partial digest record could not be written';
                $reason =~ s/[\r\n]+/ /g;
                p("Interrupted partial for $job_id remains unsealed: $reason.");
            }
            delete $JOBS{partial_sealers}{$job_id};
            schedule_partial_seal_tick(10) if @$queue;
            return if @$queue;
            next;
        }

        p("Interrupted partial for $job_id remains unsealed: " .
            safe_field($result->{reason} // 'partial digest verification refused') . '.');
        delete $JOBS{partial_sealers}{$job_id};
        schedule_partial_seal_tick(10) if @$queue;
        return if @$queue;
    }
    delete @JOBS{qw(partial_seal_queue partial_sealers)};
}

sub cancel_partial_sealers {
    Irssi::timeout_remove($JOBS{partial_seal_timer})
        if defined $JOBS{partial_seal_timer};
    for my $entry (values %{$JOBS{partial_sealers} || {}}) {
        FServe::Transfer::Resume::cancel_partial_seal($entry->{session})
            if $entry->{session};
    }
    delete @JOBS{qw(partial_seal_timer partial_seal_queue partial_sealers)};
    return 1;
}

sub partial_receive_metadata {
    my ($transfer) = @_;
    return (receive_path => undef, receive_identity => undef,
        source_invalid => JSON::PP::true) unless ref($transfer) eq 'HASH';
    my $dcc = $transfer->{dcc};
    my $path = $transfer->{receive_source} // $transfer->{dcc_file} //
        ($dcc ? $dcc->{file} : undef);
    my $identity = defined($transfer->{receive_dev}) && defined($transfer->{receive_ino})
        ? { device => 0 + $transfer->{receive_dev}, inode => 0 + $transfer->{receive_ino} }
        : undef;
    my $invalid = $transfer->{direct_source_invalid} || $transfer->{partial_source_invalid};
    return (receive_path => $path, receive_identity => $identity,
        source_invalid => $invalid ? JSON::PP::true : JSON::PP::false);
}

sub cleanup_owned_transfers_for_unload {
    for my $transfer (values %TRANSFERS) {
        my $dcc = $transfer->{dcc};
        my $closed = ref($transfer->{stop_intent}) eq 'HASH' &&
            $transfer->{stop_intent}{writer_closed} ? 1 :
            ($dcc && eval { $dcc->destroy(); 1 });
        unless ($closed) {
            my $server = $transfer->{server};
            my $nick = $transfer->{nick} // '';
            my $name = $transfer->{offered_name} // '';
            $closed = eval {
                $server->command('DCC CLOSE GET ' . $nick . ' ' . quote_irssi_arg($name));
                1;
            } if $server && length($nick) && length($name);
        }
        if ($closed && $dcc && $TRANSFERS{$transfer->{key}}) {
            finish_transfer($dcc, 'closed');
        } elsif (!$closed) {
            p('Could not close an FServe DCC GET owned by this script during unload.');
            log_to_path($transfer->{log_file}, 'UNLOAD_TRANSFER_CLOSE_FAILED',
                'nick=' . ($transfer->{nick} // '') . ' offered=[' .
                ($transfer->{offered_name} // '') . ']');
            release_pending_manifest_lease($transfer->{file});
        }
    }
}

sub cancel_owned_transfer {
    my ($job_id) = @_;
    my @owned = grep { ($_->{phase6_job_id} // '') eq $job_id } values %TRANSFERS;
    return 0 unless @owned;

    pause_batch_for_cancel($job_id);
    cancel_wait_timer($job_id);
    my ($transfer) = @owned;
    my $dcc = $transfer->{dcc};
    my $partial_path = $transfer->{receive_source} // $transfer->{dcc_file} //
        ($dcc ? $dcc->{file} : undef) // '';
    my $partial_size = length($partial_path) && -f $partial_path
        ? -s $partial_path : ($dcc ? ($dcc->{transfd} // 0) : 0);
    for my $owned_transfer (@owned) {
        $owned_transfer->{stop_intent} ||= {
            job_state => 'cancelled',
            job_outcome => 'local_queue_cancelled',
            request_state => 'cancelled',
            reason => 'operator cancelled the exact owned DCC transfer; staged bytes were retained',
            requested_at => time(),
            writer_closed => 0,
        };
    }
    my $stop_intent = $transfer->{stop_intent};
    my %data;
    $data{partial} = {
        path => $partial_path, size => $partial_size,
        partial_receive_metadata($transfer),
        staging_root => (($transfer->{file} && $transfer->{file}{staging_dir}) //
            $transfer->{staging_dir}),
        total_size => $transfer->{expected_size} // ($dcc ? $dcc->{size} : undef),
        offered_basename => $transfer->{offered_name}, captured_at => time(),
        writer_closed => JSON::PP::false,
        resume_supported => JSON::PP::false,
    } if length($partial_path) || $partial_size;
    $data{stop_intent} = { %$stop_intent };
    my %transition_meta = (
        outcome => 'local_queue_cancelled',
        reason => 'operator cancelled the exact owned DCC transfer; staged bytes were retained',
    );
    $transition_meta{data} = \%data if keys %data;
    my $recorded = job_transition($job_id, 'cancelled', %transition_meta);

    # The browser owns one direct fetch, not an interactive FServe CHAT
    # session. A stop that completes at once clears the session's pending
    # download, so decide beforehand whether this cancel must also close the
    # session; otherwise it would block the next web search, download or
    # source disconnect until the remote side closed the CHAT.
    my $web_session_generation = $S{active} && $S{pending_download} &&
        ($S{pending_download}{phase6_job_id} // '') eq $job_id &&
        ($S{pending_download}{web_operation_id} // '') =~ /\Aweb-download-[a-f0-9]{64}\z/
            ? $S{generation} : undef;
    for my $owned_transfer (@owned) {
        request_transfer_stop($owned_transfer, $owned_transfer->{stop_intent});
    }
    if ($S{active} && (($S{pending_download} &&
            ($S{pending_download}{phase6_job_id} // '') eq $job_id) ||
            (defined($web_session_generation) &&
                session_is_current($web_session_generation)))) {
        stop_session(1);
    }
    delete $JOBS{active_job_id}
        if ($JOBS{active_job_id} // '') eq $job_id;
    return $recorded ? 1 : -1;
}

1;
