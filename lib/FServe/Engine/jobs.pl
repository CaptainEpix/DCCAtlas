# Durable jobs: their records, reservations, limits, recovery and waits.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use File::Basename qw(basename);

our (%FIND, %JOBS, %S, $PROCESS_INCARNATION);

sub new_job {
    my (%args) = @_;
    return unless jobs_ready();
    my $context = server_context($args{server});
    my $network = $args{network_profile} // $context->{network_profile};
    my $limits = { %{$args{limits} || {}} };
    $limits->{queue_wait_ms} = bounded_timeout_setting(
        'fscrawl_queue_max_wait_ms', 900000, 30000, 3600000)
        unless defined $limits->{queue_wait_ms};
    my $job = eval {
        $JOBS{coordinator}->create_job(
            provider => $args{provider}, network_profile => $network,
            selection => $args{selection},
            context => { %$context, %{$args{context} || {}} },
            limits => $limits,
        );
    };
    unless ($job) {
        my $error = $@ || 'job could not be recorded';
        $error =~ s/[\r\n]+/ /g;
        if ($error =~ /identical provider selection/) {
            p($args{duplicate_message} ||
                'The job journal refused this selection because identical provider history already exists; no network activity occurred.');
        } else {
            p("The job journal refused this selection before network activity: $error");
        }
        return;
    }
    remember_live_server($args{server});
    return $job->{id};
}

sub job_transition {
    my ($job_id, $state, %meta) = @_;
    return 1 unless defined($job_id) && length($job_id);
    return 0 unless jobs_ready();
    my $ok = eval { $JOBS{coordinator}->transition($job_id, $state, %meta); 1 };
    unless ($ok) {
        my $error = $@ || 'job transition could not be persisted';
        $error =~ s/[\r\n]+/ /g;
        p("The job journal could not persist job $job_id state $state: $error");
        return 0;
    }
    queue_batch_settled($job_id)
        if FServe::Transfer::Job::is_terminal($state) && defined &queue_batch_settled;
    return 1;
}

sub fserve_job {
    my ($file, $server, $existing_id, $expected_peer) = @_;
    return $existing_id if defined($existing_id) && length($existing_id);
    return $file->{phase6_job_id} if $file && defined($file->{phase6_job_id});
    return unless $file && ref($file) eq 'HASH';
    return unless jobs_ready();
    my $recovery_limits = $JOBS{scheduler}->limits;
    my $provider = ($file->{source} // '') eq 'manifest' ? 'manifest'
        : ($file->{source} // '') eq 'find' ? 'find' : 'crawl';
    my $legacy = $file->{name} // '';
    $legacy =~ s/ /_/g;
    my @aliases = length($legacy) && $legacy ne ($file->{name} // '') ? ($legacy) : ();
    my $id = new_job(
        provider => $provider,
        server => $server,
        selection => {
            remote_path => $file->{path}, parent => $file->{parent},
            name => $file->{name}, basename => $file->{name},
            offered_basename => $file->{name}, legacy_aliases => \@aliases,
            expected_peer => $file->{server_nick} // $expected_peer,
            trigger_raw => $file->{trigger_raw},
            trigger_mode => $file->{trigger_mode}, discovery_channel => $file->{discovery_channel},
            selection_token => $file->{selection_token},
            selection_generation => $file->{selection_generation},
            provenance => $file->{source}, manifest_selection => $file->{manifest_selection},
            manifest_snapshot_id => $file->{manifest_snapshot_id},
            manifest_route_key => $file->{manifest_route_key},
            manifest_page_generation => $file->{manifest_page_generation},
            find_query_id => $FIND{query_id}, session_generation => $S{generation},
        },
        context => { server_tag => $file->{server_tag},
            session_generation => $S{generation},
            (defined($file->{web_operation_id})
                ? (web_operation_id => $file->{web_operation_id}) : ()) },
        limits => { offer_timeout_ms => bounded_timeout_setting(
                'fscrawl_offer_timeout_ms', 120000, 1000, 300000),
            transfer_stall_ms => 120000,
            # A web download asks for it itself (retry_before_request, 2026-10-22).
            pre_dispatch_recovery_enabled => defined($file->{web_operation_id})
                ? ($file->{web_auto_recovery} ? 1 : 0)
                : (Irssi::settings_get_bool('fscrawl_auto_recovery') ? 1 : 0),
            max_recovery_attempts => $recovery_limits->{max_recovery_attempts},
            recovery_backoff_ms => [@{$recovery_limits->{recovery_backoff_ms}}],
            recovery_jitter_percent => $recovery_limits->{recovery_jitter_percent},
            recovery_total_ms => $recovery_limits->{recovery_total_ms} },
    );
    $file->{phase6_job_id} = $id if $id;
    return $id;
}

sub mark_interrupted {
    my ($job_id, %meta) = @_;
    return unless defined($job_id) && length($job_id) && jobs_ready();
    my $job;
    my $ok = eval { $job = $JOBS{coordinator}->mark_interrupted($job_id, %meta); 1 };
    unless ($ok) {
        my $error = $@ || 'partial transfer evidence could not be persisted';
        $error =~ s/[\r\n]+/ /g;
        p("The job journal could not persist interrupted-transfer evidence for $job_id: $error");
        return 0;
    }
    schedule_partial_seal($job_id)
        if $job && $job->{state} eq 'interrupted' && $job->{partial}{writer_closed};
    return 1;
}

sub fail_job {
    my ($job_id, $state, %meta) = @_;
    return 1 unless defined($job_id) && length($job_id);
    return job_transition($job_id, $state, %meta);
}

sub retire_job {
    my ($job_id, $outcome, $reason) = @_;
    return 1 unless defined($job_id) && length($job_id) && jobs_ready();
    my $job = $JOBS{coordinator}->job($job_id) or return 0;
    return 1 if FServe::Transfer::Job::is_terminal($job->{state});
    my $target = $outcome eq 'disconnected' || $outcome eq 'dispatch_uncertain'
        ? 'needs_attention'
        : $outcome eq 'expired' ? 'expired'
        : $outcome eq 'cancelled' || $outcome eq 'preflight_failed' ? 'cancelled'
        : 'failed';
    return 1 if $job->{state} eq $target;
    return job_transition($job_id, $target, outcome => $outcome, reason => $reason);
}

# A file server may offer a file again after the operator cancelled it:
# SysReset puts a cancelled send back in its queue. Nothing here will take
# that offer, and left unanswered it holds the server's send slot until the
# server's own timeout. Decline it, so the slot is freed at once. This answers
# only an offer for a file this client asked that server for and the operator
# then cancelled, on this same IRC connection, and at most three times a job.
sub decline_cancelled_reoffer {
    my ($dcc) = @_;
    return 0 unless ref($dcc) && uc($dcc->{type} // '') eq 'GET';
    my $server = $dcc->{server};
    return 0 unless ref($server) && $server->{connected} && jobs_ready();
    my ($peer, $offered) = ($dcc->{nick} // '', $dcc->{arg} // '');
    return 0 unless length($peer) && length($offered);
    my $tuple = FServe::ConnectionIdentity::tuple_key(
        network_profile => server_context($server)->{network_profile},
        peer => $peer, basename => $offered, casemapping => server_casemapping($server));
    return 0 unless defined $tuple;
    my $job_id = $JOBS{coordinator}->tuple_owner($tuple);
    my $job = defined($job_id) ? $JOBS{coordinator}->job($job_id) : undef;
    return 0 unless $job && ($job->{state} // '') eq 'cancelled' &&
        job_is_on_connection($job, $server);
    return 0 if ($JOBS{declined_reoffers}{$job_id} || 0) >= 3;
    $JOBS{declined_reoffers}{$job_id}++;
    reject_dcc_get($dcc, 'operator-cancelled-request', 0);
    return 1;
}

sub offer_belongs_to_job {
    my ($job_id, $server, $peer, $basename) = @_;
    return 0 unless defined($job_id) && defined($basename) && jobs_ready();
    my $job = $JOBS{coordinator}->job($job_id) or return 0;
    my $tuple = FServe::ConnectionIdentity::tuple_key(
        network_profile => $job->{network_profile}, peer => $peer,
        basename => $basename, casemapping => job_casemapping($job, $server));
    return 0 unless defined $tuple;
    return (($JOBS{coordinator}->tuple_owner($tuple) // '') eq $job_id) ? 1 : 0;
}

# A list request reserves its sender's list, not a name (2026-10-27): an
# offer is its own only while that reservation is this job's and no other
# job has reserved the offered name from that sender.
sub list_offer_belongs_to_job {
    my ($job_id, $server, $peer, $basename, $offered_by) = @_;
    return 0 unless defined($job_id) && defined($basename) && jobs_ready() &&
        load_searchbot_provider();
    my $job = $JOBS{coordinator}->job($job_id) or return 0;
    my $mapping = job_casemapping($job, $server);
    my %key = (network_profile => $job->{network_profile}, peer => $peer, casemapping => $mapping);
    # The list name this job reserved: a second ask on a connection has its
    # own (2026-10-29).
    my $reserved = $job->{selection}{basename} // '';
    my $prefix = $FServe::Discovery::SearchBotRequest::LIST_TUPLE_NAME;
    return 0 unless $reserved eq $prefix || $reserved =~ /\A\Q$prefix\E\x1f[0-9]+\z/;
    my $list = FServe::ConnectionIdentity::tuple_key(%key, basename => $reserved);
    # A typed nick's list sent by another nick (2026-11-02): that nick's
    # name is the one no other job may hold.
    my $named = FServe::ConnectionIdentity::tuple_key(%key,
        (defined($offered_by) ? (peer => $offered_by) : ()), basename => $basename);
    return 0 unless defined($list) && defined($named);
    return 0 unless ($JOBS{coordinator}->tuple_owner($list) // '') eq $job_id;
    my $owner = $JOBS{coordinator}->tuple_owner($named);
    return !defined($owner) || $owner eq $job_id ? 1 : 0;
}

sub reserve_finalization {
    my ($file, $source, $destination, $size, $digest) = @_;
    my $job_id = $file->{phase6_job_id} if ref($file) eq 'HASH';
    return 1 unless defined($job_id) && length($job_id);
    return 0 unless jobs_ready();
    my $ok = eval {
        $JOBS{coordinator}->reserve_finalization($job_id,
            staging_path => $source, destination_path => $destination,
            expected_size => $size, expected_sha256 => $digest);
        1;
    };
    unless ($ok) {
        my $error = $@ || 'final destination could not be reserved';
        $error =~ s/[\r\n]+/ /g;
        p("Refusing publication for job $job_id because durable destination reservation failed: $error");
        return 0;
    }
    return 1;
}

sub finish_finalization {
    my ($file, $success, $destination, $size, $digest, $reason) = @_;
    my $job_id = $file->{phase6_job_id} if ref($file) eq 'HASH';
    return 1 unless defined($job_id) && length($job_id);
    my $available = jobs_ready();
    unless ($available) {
        $file->{phase6_published_unrecorded} = {
            job_id => $job_id, destination_path => $destination,
            staging_path => $file->{phase6_staging_path}, size => $size,
            sha256 => $digest,
        } if $success;
        if (my $run = $JOBS{run_batch}) {
            if (($run->{current_job_id} // '') eq $job_id) {
                $run->{paused_for_attention} = 1;
                $JOBS{paused} = 1;
            }
        }
        p($success
            ? "Job $job_id was published to $destination, but the durable coordinator is unavailable. Staging evidence remains at " . ($file->{phase6_staging_path} // '(unknown path)') . '.'
            : "Job $job_id finalization could not be recorded because the durable coordinator is unavailable.");
        return 0;
    }
    my $ok = eval {
        $JOBS{coordinator}->complete_finalization($job_id,
            success => $success, destination_path => $destination,
            observed_size => $size, observed_sha256 => $digest, reason => $reason);
        1;
    };
    unless ($ok) {
        my $error = $@ || 'finalization result could not be recorded';
        $error =~ s/[\r\n]+/ /g;
        $file->{phase6_published_unrecorded} = {
            job_id => $job_id, destination_path => $destination,
            staging_path => $file->{phase6_staging_path}, size => $size,
            sha256 => $digest,
        } if $success;
        if (my $run = $JOBS{run_batch}) {
            if (($run->{current_job_id} // '') eq $job_id) {
                $run->{paused_for_attention} = 1;
                $JOBS{paused} = 1;
            }
        }
        p($success
            ? "Job $job_id was published to $destination, but durable completion could not be recorded: $error. Staging evidence remains at " . ($file->{phase6_staging_path} // '(unknown path)') . '.'
            : "Job $job_id finalization evidence could not be recorded: $error");
        return 0;
    }
    queue_batch_settled($job_id);
    return 1;
}

sub effective_job_limit {
    my ($job, $name, $current) = @_;
    return unless defined($current) && $current =~ /\A\d+\z/ && $current > 0;
    return $current unless $job;
    my $captured = $job->{limits}{$name};
    return unless defined($captured) && $captured =~ /\A\d+\z/ && $captured > 0;
    return $captured < $current ? $captured : $current;
}

sub monotonic_now {
    require Time::HiRes;
    return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
}

sub finish_pre_dispatch_recovery {
    my ($reason, %options) = @_;
    my $recovery = delete $JOBS{pre_dispatch_recovery} or return 0;
    Irssi::timeout_remove($recovery->{retry_timer})
        if defined $recovery->{retry_timer};
    Irssi::timeout_remove($recovery->{deadline_timer})
        if defined $recovery->{deadline_timer};
    if (jobs_ready()) {
        eval { $JOBS{coordinator}->record_event(
            'pre_dispatch_recovery_finished', {
                job_id => $recovery->{job_id},
                recovery_id => $recovery->{id},
                attempts => $recovery->{attempts} || 0,
                outcome => safe_field($options{outcome} // 'stopped'),
                reason => safe_field($reason // ''),
                connection_identity => $recovery->{connection_identity},
                connection_epoch => $recovery->{connection_epoch},
                finished_monotonic => monotonic_now(),
            }); };
        my $job = defined($recovery->{job_id})
            ? $JOBS{coordinator}->job($recovery->{job_id}) : undef;
        if ($options{needs_attention} && $job &&
                $job->{state} eq 'preparing') {
            job_transition($job->{id}, 'needs_attention',
                outcome => $options{outcome} // 'pre_dispatch_recovery_stopped',
                reason => $reason // 'bounded pre-dispatch recovery stopped');
        }
    }
    my $active_owner = $S{active} && $S{pending_download} &&
        ($S{pending_download}{phase6_job_id} // '') eq
            ($recovery->{job_id} // '');
    release_untransferred_manifest_lease($recovery->{file})
        if $options{release_lease} && !$active_owner;
    return 1;
}

sub finish_pre_dispatch_recovery_for_job {
    my ($job_id, $reason, %options) = @_;
    my $recovery = $JOBS{pre_dispatch_recovery} or return 0;
    return 0 unless defined($job_id) &&
        ($recovery->{job_id} // '') eq $job_id;
    return finish_pre_dispatch_recovery($reason, %options);
}

sub recovery_deadline_allows_dispatch {
    my ($job_id, $deadline) = @_;
    return 1 unless defined($deadline) &&
        monotonic_now() >= $deadline;

    finish_pre_dispatch_recovery_for_job(
        $job_id, '120-second recovery window elapsed before dispatch',
        release_lease => 1,
        outcome => 'pre_dispatch_recovery_deadline');
    p('Pre-dispatch recovery window expired before dispatch; the job needs attention.');
    return 0;
}

sub fire_pre_dispatch_recovery {
    my ($recovery_id, $attempt) = @_;
    my $recovery = $JOBS{pre_dispatch_recovery};
    return unless $recovery && $recovery->{id} == $recovery_id &&
        $recovery->{attempts} == $attempt;
    $recovery->{retry_timer} = undef;
    my $now = monotonic_now();
    if ($now >= $recovery->{deadline_monotonic}) {
        finish_pre_dispatch_recovery(
            '120-second recovery window elapsed before another attempt',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_deadline');
        p('Pre-dispatch recovery window expired; the job needs attention.');
        return;
    }
    my $server = $recovery->{server};
    my $same_connection = $server && $server->{connected} &&
        server_connection_identity($server) eq $recovery->{connection_identity} &&
        server_connection_epoch($server) == $recovery->{connection_epoch};
    my $job = jobs_ready()
        ? $JOBS{coordinator}->job($recovery->{job_id}) : undef;
    unless ($same_connection && $job && $job->{state} eq 'preparing' &&
            job_is_on_connection($job, $server) &&
            find_selection_is_current($recovery->{file}, $server)) {
        finish_pre_dispatch_recovery(
            'job selection or captured IRC connection changed before retry',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_context_stale');
        p('Pre-dispatch recovery stopped because its job or IRC connection is no longer current.');
        return;
    }
    my $recorded = eval {
        $JOBS{coordinator}->record_event(
            'pre_dispatch_recovery_attempt_started', {
                job_id => $recovery->{job_id},
                recovery_id => $recovery_id,
                attempt => $attempt,
                connection_identity => $recovery->{connection_identity},
                connection_epoch => $recovery->{connection_epoch},
                started_monotonic => $now,
            });
        1;
    };
    unless ($recorded) {
        finish_pre_dispatch_recovery(
            'could not durably record the recovery attempt before trigger dispatch',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_journal_failure');
        p('Pre-dispatch recovery stopped because its attempt could not be recorded.');
        return;
    }

    my %file = %{$recovery->{file}};
    reset_state();
    my $started = start_fserve_session(
        $recovery->{nick}, $server, $recovery->{trigger_command},
        \%file, $recovery_id);
    unless ($started && $S{active} &&
            ($S{pre_dispatch_recovery_id} || 0) == $recovery_id) {
        finish_pre_dispatch_recovery(
            'fresh FServe session could not be started safely',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_start_failed');
        p('Pre-dispatch recovery could not start a fresh FServe session.');
    }
}

sub schedule_pre_dispatch_recovery {
    my ($dcc, $pending) = @_;
    return 0 unless $pending && defined($pending->{phase6_job_id}) &&
        $S{active} && $S{chat_connected} && $S{trigger_dispatched} &&
        !$S{chat_authorization_revoked} && same_chat($dcc) &&
        !$pending->{accepted_transfer_key} && !$pending->{request_sent} &&
        !$S{phase6_paused_get} && !$JOBS{run_batch};
    my $server = $S{server};
    return 0 unless $server && $server->{connected} &&
        server_connection_identity($server) eq ($S{server_identity} // '') &&
        server_connection_epoch($server) == ($S{connection_epoch} || 0) &&
        defined($S{trigger_cmd}) && length($S{trigger_cmd});
    return 0 unless jobs_ready();
    my $job = $JOBS{coordinator}->job($pending->{phase6_job_id});
    return 0 unless $job && $job->{state} eq 'preparing' &&
        $job->{provider} =~ /\A(?:crawl|find|manifest)\z/ &&
        ($job->{limits}{pre_dispatch_recovery_enabled} || 0) == 1 &&
        job_is_on_connection($job, $server) &&
        find_selection_is_current($pending, $server);

    my $recovery = $JOBS{pre_dispatch_recovery};
    if ($recovery) {
        return 0 unless defined($S{pre_dispatch_recovery_id}) &&
            $S{pre_dispatch_recovery_id} == $recovery->{id} &&
            $recovery->{attempt_chat_established} &&
            $recovery->{job_id} eq $job->{id} &&
            $recovery->{connection_identity} eq $S{server_identity} &&
            $recovery->{connection_epoch} == $S{connection_epoch};
    } else {
        my $limits = $job->{limits};
        my $max_attempts = $limits->{max_recovery_attempts};
        my $total_ms = $limits->{recovery_total_ms};
        my $backoffs = $limits->{recovery_backoff_ms};
        return 0 unless defined($max_attempts) && $max_attempts =~ /\A[1-2]\z/ &&
            defined($total_ms) && $total_ms =~ /\A\d+\z/ &&
            $total_ms >= 1000 && $total_ms <= 120000 &&
            ref($backoffs) eq 'ARRAY' && @$backoffs >= $max_attempts;
        my $now = monotonic_now();
        $recovery = {
            id => ++$JOBS{pre_dispatch_recovery_sequence},
            job_id => $job->{id},
            attempts => 0,
            max_attempts => $max_attempts,
            backoffs_ms => [@$backoffs[0 .. $max_attempts - 1]],
            jitter_percent => $limits->{recovery_jitter_percent},
            started_monotonic => $now,
            deadline_monotonic => $now + $total_ms / 1000,
            server => $server,
            connection_identity => $S{server_identity},
            connection_epoch => $S{connection_epoch},
            nick => $S{nick},
            trigger_command => $S{trigger_cmd},
            file => {},
        };
    }
    return 0 if $recovery->{attempts} >= $recovery->{max_attempts};
    my $attempt = $recovery->{attempts} + 1;
    my $base_ms = $recovery->{backoffs_ms}[$attempt - 1];
    my $jitter_percent = $recovery->{jitter_percent};
    return 0 unless defined($base_ms) && $base_ms =~ /\A\d+\z/ &&
        $base_ms >= 1 && $base_ms <= 30000 &&
        defined($jitter_percent) && $jitter_percent =~ /\A\d+\z/ &&
        $jitter_percent <= 20;
    my $jitter_max_ms = int($base_ms * $jitter_percent / 100);
    my $delay_ms = $base_ms + ($jitter_max_ms ? int(rand($jitter_max_ms + 1)) : 0);
    my $now = monotonic_now();
    return 0 if $now + $delay_ms / 1000 >= $recovery->{deadline_monotonic};

    my %file = %$pending;
    delete @file{qw(request_token accepted_transfer_key request_sent log_file
        download_dir session_server_tag session_generation)};
    $recovery->{file} = \%file;
    my $recorded = eval {
        $JOBS{coordinator}->record_event(
            'pre_dispatch_recovery_scheduled', {
                job_id => $job->{id},
                recovery_id => $recovery->{id},
                attempt => $attempt,
                delay_ms => $delay_ms,
                jitter_ms => $delay_ms - $base_ms,
                connection_identity => $recovery->{connection_identity},
                connection_epoch => $recovery->{connection_epoch},
                started_monotonic => $recovery->{started_monotonic},
                deadline_monotonic => $recovery->{deadline_monotonic},
            });
        1;
    };
    return 0 unless $recorded;

    $recovery->{attempts} = $attempt;
    $recovery->{attempt_chat_established} = 0;
    $JOBS{pre_dispatch_recovery} = $recovery;
    my $retry_timer = eval {
        Irssi::timeout_add_once($delay_ms, sub {
            fire_pre_dispatch_recovery($recovery->{id}, $attempt);
        }, undef);
    };
    unless (defined $retry_timer) {
        finish_pre_dispatch_recovery(
            'could not arm the bounded recovery retry timer',
            release_lease => 0,
            outcome => 'pre_dispatch_recovery_timer_failure');
        return 0;
    }
    $recovery->{retry_timer} = $retry_timer;
    unless (defined $recovery->{deadline_timer}) {
        my $remaining_ms = int(($recovery->{deadline_monotonic} - $now) * 1000 + 0.999);
        my $deadline_timer = eval {
            Irssi::timeout_add_once($remaining_ms, sub {
                my $current = $JOBS{pre_dispatch_recovery};
                return unless $current && $current->{id} == $recovery->{id};
                my $active = $S{active} &&
                    ($S{pre_dispatch_recovery_id} || 0) == $recovery->{id};
                finish_pre_dispatch_recovery(
                    '120-second recovery window elapsed',
                    needs_attention => 1, release_lease => 1,
                    outcome => 'pre_dispatch_recovery_deadline');
                if ($active) {
                    p('Pre-dispatch recovery window expired; the job needs attention.');
                    stop_session(1);
                } else {
                    p('Pre-dispatch recovery window expired; the job needs attention.');
                }
            }, undef);
        };
        unless (defined $deadline_timer) {
            Irssi::timeout_remove($retry_timer);
            $recovery->{retry_timer} = undef;
            finish_pre_dispatch_recovery(
                'could not arm the bounded recovery deadline',
                release_lease => 0, outcome => 'pre_dispatch_recovery_timer_failure');
            return 0;
        }
        $recovery->{deadline_timer} = $deadline_timer;
    }
    $recovery->{trigger_command} = $S{trigger_cmd};
    $recovery->{nick} = $S{nick};
    $recovery->{server} = $server;
    p("Pre-dispatch recovery attempt $attempt/$recovery->{max_attempts} scheduled in ${delay_ms}ms; the parent will be verified again before GET.");
    return 1;
}

sub cancel_wait_timer {
    my ($job_id) = @_;
    my $timer = $JOBS{wait_timer};
    return 0 unless $timer &&
        (!defined($job_id) || ($timer->{job_id} // '') eq $job_id);
    Irssi::timeout_remove($timer->{handle}) if defined $timer->{handle};
    delete $JOBS{wait_timer};
    return 1;
}

sub remote_queue_wait_survives_chat_close {
    my ($job, $server) = @_;
    return 0 unless $job && ($job->{state} // '') eq 'remote_queued';
    my $remote = $job->{remote_queue};
    return 0 unless ref($remote) eq 'HASH' &&
        ($remote->{dialect} // '') eq 'synthetic-phase6' &&
        $remote->{chat_close_offer_supported};
    return 0 unless ($JOBS{active_job_id} // '') eq ($job->{id} // '');
    return 0 unless job_is_on_connection($job, $server);
    my $timer = $JOBS{wait_timer};
    return 0 unless $timer && ($timer->{job_id} // '') eq $job->{id} &&
        ($timer->{kind} // '') eq 'remote_queue' &&
        ($timer->{connection_identity} // '') eq server_connection_identity($server) &&
        ($timer->{connection_epoch} || 0) == server_connection_epoch($server);
    my $deadline = $remote->{absolute_deadline_monotonic};
    return 0 unless defined($deadline) && $deadline =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ &&
        monotonic_now() < $deadline;
    return 1;
}

sub offer_wait_state {
    my ($job, $server) = @_;
    return 'unbound' unless $job && $server &&
        ($JOBS{active_job_id} // '') eq ($job->{id} // '') &&
        job_is_on_connection($job, $server);
    return 'dispatching' if ($job->{state} // '') eq 'dispatch_intent' &&
        ($S{phase} // '') eq 'requesting_file' && $S{pending_download} &&
        ($S{pending_download}{phase6_job_id} // '') eq $job->{id};
    my $state = $job->{state} // '';
    return 'unbound' unless $state eq 'awaiting_offer' || $state eq 'remote_queued';
    my $timer = $JOBS{wait_timer};
    my $expected_kind = $state eq 'remote_queued' ? 'remote_queue' : 'offer';
    return 'unbound' unless $timer && ($timer->{job_id} // '') eq $job->{id} &&
        ($timer->{kind} // '') eq $expected_kind &&
        ($timer->{connection_identity} // '') eq server_connection_identity($server) &&
        ($timer->{connection_epoch} || 0) == server_connection_epoch($server);
    my $deadline = $timer->{deadline_monotonic};
    if ($state eq 'remote_queued') {
        my $remote = $job->{remote_queue};
        return 'unbound' unless ref($remote) eq 'HASH';
        my $remote_deadline = $remote->{absolute_deadline_monotonic};
        return 'unbound' unless defined($remote_deadline) &&
            $remote_deadline =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/;
        $deadline = $remote_deadline
            if !defined($deadline) || $remote_deadline < $deadline;
    }
    return 'unbound' unless defined($deadline) &&
        $deadline =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/;
    return monotonic_now() < $deadline ? 'live' : 'expired';
}

sub arm_wait_timer {
    my ($job_id, $timeout_ms, $kind) = @_;
    my $detached_queue_wait = ($kind // '') eq 'remote_queue' &&
        ($S{phase} // '') eq 'awaiting_queued_offer';
    return 0 unless defined($job_id) && $timeout_ms >= 1 &&
        $S{active} && ($S{chat_connected} || $detached_queue_wait) && $S{server};
    cancel_wait_timer();
    my ($connection, $epoch, $generation) = (
        $S{server_identity}, $S{connection_epoch}, $S{generation});
    my $deadline = monotonic_now() + $timeout_ms / 1000;
    my $handle;
    $handle = eval {
        my $registered = Irssi::timeout_add_once($timeout_ms, sub {
            my $timer = $JOBS{wait_timer};
            return unless $timer && ($timer->{job_id} // '') eq $job_id &&
                ($timer->{kind} // '') eq $kind &&
                ($JOBS{active_job_id} // '') eq $job_id &&
                ($S{generation} || 0) == ($generation || 0) &&
                ($S{server_identity} // '') eq ($connection // '') &&
                ($S{connection_epoch} || 0) == ($epoch || 0);
            delete $JOBS{wait_timer};
            my $job = jobs_ready() ? $JOBS{coordinator}->job($job_id) : undef;
            return unless $job && ($job->{state} eq 'awaiting_offer' ||
                ($kind eq 'remote_queue' && $job->{state} eq 'remote_queued'));
            job_transition($job_id, 'expired', outcome => $kind . '_deadline',
                reason => $kind eq 'remote_queue'
                    ? 'absolute confirmed queue-wait deadline elapsed'
                    : 'offer deadline elapsed without an authorized DCC SEND');
            p($kind eq 'remote_queue'
                ? 'The confirmed remote queue wait expired; no request was resent.'
                : 'The FServe offer deadline expired; no request was resent.');
            stop_session(1);
        }, undef);
        die 'Irssi did not return a timer handle' unless defined $registered;
        $registered;
    };
    unless (defined $handle) {
        return 0;
    }
    $JOBS{wait_timer} = { handle => $handle, job_id => $job_id, kind => $kind,
        connection_identity => $connection, connection_epoch => $epoch,
        generation => $generation, deadline_monotonic => $deadline };
    return 1;
}

# Queue statuses are read from inside CHAT line handling. Closing that CHAT
# there frees it under Irssi's own input loop, which has crashed Irssi on a
# real file server's reply, so close it from a timer. The isolated responder's
# path is left exactly as it was accepted.
sub stop_after_queue_status {
    my ($synthetic) = @_;
    my $generation = $S{generation};
    return stop_session(1) if $synthetic || !defined $generation;
    my $stop = sub { stop_session(1) if session_is_current($generation); };
    $S{stop_due} = $stop;
    $stop->() unless eval { Irssi::timeout_add_once(10, $stop, undef) };
}

sub handle_queue_status {
    my ($raw) = @_;
    my $job_id = $JOBS{active_job_id};
    return 0 unless defined($job_id) && $S{active} && $S{chat_connected} && $S{server};
    return 0 if !defined($raw) || length($raw) > 2048;
    my $mapping = $S{casemapping} // server_casemapping($S{server});
    my $connection_matches =
        server_connection_identity($S{server}) eq ($S{server_identity} // '') &&
        server_connection_epoch($S{server}) == ($S{connection_epoch} || 0);
    # A real file server's reply names no request, so it counts only while
    # this job's own GET is the one outstanding request in this CHAT.
    my $outstanding = eval { $JOBS{coordinator}->job($job_id) };
    my $pending = $S{pending_download};
    my $request_outstanding = $outstanding &&
        $outstanding->{state} =~ /\A(?:dispatch_intent|awaiting_offer)\z/ &&
        $pending && ($pending->{phase6_job_id} // '') eq $job_id &&
        !$pending->{accepted_transfer_key} ? 1 : 0;
    my $status = FServe::Protocol::SysResetStatus::parse_status($raw,
        peer_matches => FServe::ConnectionIdentity::same_irc_identity(
            $S{nick}, $S{server_nick} // $S{nick}, $mapping),
        connection_matches => $connection_matches,
        message_context => 'dcc_chat', job_id => $job_id,
        request_outstanding => $request_outstanding);
    return 0 unless $status->{type} ne 'unknown' && $status->{correlated};
    my $recorded = eval {
        $JOBS{coordinator}->record_event('queue_status_observed', {
            job_id => $job_id, normalized => $status->{type}, raw => $raw,
            dialect => $status->{dialect}, position => $status->{position},
            reason => $status->{reason}, connection_identity => $S{server_identity},
            connection_epoch => $S{connection_epoch}, observed_monotonic => monotonic_now(),
        });
        1;
    };
    unless ($recorded) {
        p('Queue status was recognized but could not be durably recorded; automatic action was withheld.');
        return 1;
    }
    my $job = $JOBS{coordinator}->job($job_id);
    return 1 unless $job;
    my $synthetic = ($status->{dialect} // '') eq 'synthetic-phase6';
    my $said = $synthetic ? undef : substr(safe_field($status->{text} // ''), 0, 200);
    if ($status->{type} eq 'queued') {
        if ($job->{state} eq 'awaiting_offer' || $job->{state} eq 'dispatch_intent') {
            my $current_wait_ms = bounded_timeout_setting(
                'fscrawl_queue_max_wait_ms', 900000, 30000, 3600000);
            my $wait_ms = effective_job_limit($job, 'queue_wait_ms', $current_wait_ms);
            unless ($wait_ms) {
                job_transition($job_id, 'needs_attention',
                    outcome => 'queue_wait_limit_missing',
                    reason => 'this dispatched job has no validated captured remote queue deadline');
                cancel_wait_timer($job_id);
                p("The queue acknowledgement cannot be bounded by this job's captured limits; it requires inspection.");
                stop_after_queue_status($synthetic);
                return 1;
            }
            my $deadline = monotonic_now() + $wait_ms / 1000;
            my $transitioned = eval {
                $JOBS{coordinator}->transition($job_id, 'remote_queued',
                    outcome => 'correlated_remote_queue_ack',
                    reason => $synthetic
                        ? 'recognized synthetic fixture queue acknowledgement'
                        : "file server queued the request: $said",
                    data => { remote_queue => { dialect => $status->{dialect},
                        position => $status->{position}, wait_ms => $wait_ms,
                        absolute_deadline_monotonic => $deadline,
                        chat_close_offer_supported =>
                            $status->{dialect} eq 'synthetic-phase6' ? 1 : 0 } });
                1;
            };
            unless ($transitioned && arm_wait_timer($job_id, $wait_ms, 'remote_queue')) {
                job_transition($job_id, 'needs_attention',
                    outcome => 'queue_deadline_unavailable',
                    reason => 'confirmed queue wait could not be bounded by a timer');
                stop_after_queue_status($synthetic);
                p('Confirmed queue acknowledgement requires attention because its bounded timer could not be armed.');
                return 1;
            }
            p(($synthetic ? 'The isolated test responder' : 'The file server') .
                ' confirmed this job is queued at position ' .
                $status->{position} . '; waiting only until its captured absolute deadline.');
        } elsif ($job->{state} eq 'remote_queued') {
            p('Remote queue position is now ' . $status->{position} . '; the absolute wait deadline is unchanged.');
        }
    } elsif ($status->{type} eq 'queue_position') {
        p('Remote queue position is now ' . $status->{position} . '; the absolute wait deadline is unchanged.')
            if $job->{state} eq 'remote_queued';
    } elsif ($status->{type} eq 'already_queued') {
        cancel_wait_timer($job_id);
        job_transition($job_id, 'needs_attention', outcome => 'already_queued_ambiguous',
            reason => $synthetic
                ? 'server status cannot prove which request occupies its queue'
                : "file server said an earlier request already holds this file: $said")
            if $job->{state} eq 'awaiting_offer' || $job->{state} eq 'remote_queued';
        p('Server reported an already-queued item without proving this job owns it; automatic waiting or retry stopped.');
        stop_after_queue_status($synthetic);
    } elsif ($status->{type} eq 'explicit_refusal' ||
             $status->{type} =~ /\A(?:sends_full|user_queue_full|queue_full)\z/) {
        cancel_wait_timer($job_id);
        if ($job->{state} eq 'dispatch_intent' || $job->{state} eq 'awaiting_offer' ||
                $job->{state} eq 'remote_queued') {
            $JOBS{coordinator}->transition($job_id, 'refused_without_queue',
                outcome => $status->{type}, reason => $synthetic
                    ? 'explicit synthetic responder refusal without queueing'
                    : "file server refused the request: $said");
            queue_batch_settled($job_id);
        }
        p(($synthetic ? 'The isolated responder' : 'The file server') .
            ' explicitly refused this request without queueing it; no automatic retry was sent.');
        stop_after_queue_status($synthetic);
    }
    return 1;
}

sub job_is_on_connection {
    my ($job, $server) = @_;
    return 0 unless $job && $server && $server->{connected};
    return 0 unless ($job->{context}{process_incarnation} // '') eq $PROCESS_INCARNATION;
    return 0 unless ($job->{context}{connection_identity} // '') eq server_connection_identity($server);
    return 0 unless ($job->{context}{connection_epoch} || 0) == server_connection_epoch($server);
    return lc($job->{network_profile} // '') eq
        lc($server->{chatnet} // $server->{tag} // '') ? 1 : 0;
}

sub server_for_job {
    my ($job, $fallback_server) = @_;
    return unless $job;
    remember_live_server($fallback_server)
        if job_is_on_connection($job, $fallback_server);
    my $identity = $job->{context}{connection_identity} // '';
    my $epoch = $job->{context}{connection_epoch};
    return unless length($identity) && defined($epoch);
    my $server = $JOBS{live_servers}{$identity}{$epoch};
    return unless job_is_on_connection($job, $server);
    return $server;
}

sub timer_delay_ms {
    my ($delay_seconds) = @_;
    return 0 unless defined($delay_seconds) && $delay_seconds > 0;
    my $exact_ms = $delay_seconds * 1000;
    my $delay_ms = int($exact_ms);
    $delay_ms++ if $delay_ms < $exact_ms;
    $delay_ms = 10 if $delay_ms < 10;
    return $delay_ms;
}

1;
