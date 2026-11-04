# Stored file lists: the catalog worker, its leases, and fetching a listed file.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Digest::SHA qw(sha256_hex);
use File::Spec ();
use JSON::PP ();

our (%CATALOG, %CATALOG_WORKER, %MANIFEST, %JOBS, %S, %TRANSFERS, $DOWNLOAD_PATH_OWNER);

sub record_catalog_observations {
    my ($observations) = @_;
    return 0 unless ref($observations) eq 'ARRAY' && @$observations;
    return 0 unless load_catalog_module();

    my @valid;
    for my $observation (@$observations) {
        my $added = eval {
            FServe::Catalog::add_record($CATALOG{store}, $observation);
            1;
        };
        if ($added) {
            push @valid, $observation;
        } else {
            my $error = $@ || 'invalid catalog record';
            $error =~ s/[\r\n]+/ /g;
            p("Could not index a discovered file: $error");
        }
    }

    return 0 unless @valid;
    my $saved = eval {
        FServe::Catalog::append_observations($CATALOG{jsonl_path}, \@valid);
        1;
    };
    unless ($saved) {
        my $error = $@ || 'catalog write failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not persist discovered files to [$CATALOG{jsonl_path}]: $error");
    }
    return scalar @valid;
}

sub catalog_worker_timer_api {
    return {
        schedule => sub {
            my ($delay_ms, $callback) = @_;
            return Irssi::timeout_add_once($delay_ms, $callback, undef);
        },
        cancel => sub { Irssi::timeout_remove($_[0]); },
    };
}

sub catalog_worker_paths {
    my $library_dir = add_library_dir_to_inc();
    my $worker = File::Spec->catfile($library_dir, 'FServe', 'Catalog', 'worker.py');
    my $helper = File::Spec->catfile($library_dir, 'FServe', 'Catalog', 'ManifestStream.pl');
    my $root = File::Spec->catdir(
        resolve_irssi_path(Irssi::settings_get_str('fscrawl_output_dir')),
        'manifest-catalog',
    );
    return ($library_dir, $worker, $helper, $root);
}

sub start_catalog_worker {
    my ($operation, $args, %callbacks) = @_;
    return unless ref($args) eq 'ARRAY';
    return if $CATALOG_WORKER{unloading} && $operation ne 'release';
    return unless load_catalog_worker_client();
    my ($library_dir, $worker, $helper, $root) = catalog_worker_paths();
    unless (-f $worker && -f $helper) {
        p("SQLite catalog worker files are missing from [$library_dir].");
        return;
    }
    my $python = Irssi::settings_get_str('fscrawl_python_executable') || 'python';
    my @command = ($python, $worker, $operation, '--root', $root, @$args);
    my $timer_api = catalog_worker_timer_api();
    my $lease_acquisition = 0;
    $lease_acquisition = scalar grep { $_ eq '--acquire' } @$args
        if $operation eq 'check';
    my $request = {
        result => undef, error => undef, %callbacks,
        operation => $operation,
        lease_acquisition => $lease_acquisition ? 1 : 0,
    };
    my $job_id;
    my $started = eval {
        $job_id = FServe::Catalog::WorkerClient::run_async(
            command => \@command,
            timeout_ms => $callbacks{timeout_ms} // 15_000,
            schedule_timer => $timer_api->{schedule},
            cancel_timer => $timer_api->{cancel},
            on_event => sub {
                my ($line) = @_;
                my $event = eval { JSON::PP::decode_json($line) };
                die 'worker returned invalid JSON' unless ref($event) eq 'HASH';
                if (($event->{event} // '') eq 'progress') {
                    $request->{on_progress}->($event) if $request->{on_progress};
                } elsif (($event->{event} // '') eq 'error') {
                    $request->{error} = $event->{reason} // 'catalog worker failed';
                } elsif (($event->{event} // '') eq 'result') {
                    $request->{result} = $event;
                } else {
                    die 'worker returned an unknown event';
                }
            },
            on_done => sub {
                my ($status, $stderr, $failure, $cancelled) = @_;
                my $error = $failure || $request->{error};
                $error ||= "catalog worker exited with status " . ($status >> 8)
                    if $status != 0;
                $error ||= 'catalog worker returned no result'
                    unless $request->{result} || $error;
                $request->{on_done}->($request->{result}, $error, $cancelled)
                    if $request->{on_done};
                delete $CATALOG_WORKER{jobs}{$job_id} if defined $job_id;
            },
        );
        1;
    };
    unless ($started) {
        my $error = $@ || 'could not start the local catalog worker';
        $error =~ s/[\r\n]+/ /g;
        p("Could not start catalog worker: $error");
        return;
    }
    $request->{job_id} = $job_id;
    $CATALOG_WORKER{jobs}{$job_id} = $request;
    return $job_id;
}

sub confirmed_manifest_import_result {
    my ($result) = @_;
    return 0 unless ref($result) eq 'HASH';
    return 0 unless ($result->{event} // '') eq 'result';
    return 0 unless ($result->{status} // '') =~ /\A(?:published|repaired|reused|unchanged)\z/;
    return 0 unless ($result->{route_key} // '') =~ /\A[0-9a-f]{64}\z/i;
    return 0 unless ($result->{snapshot_id} // '') =~ /\A[0-9a-f]{64}\z/i;
    return 0 unless defined($result->{generation}) && $result->{generation} =~ /\A[1-9][0-9]*\z/;
    return 0 unless defined($result->{records}) && $result->{records} =~ /\A[0-9]+\z/;
    return 0 unless ($result->{sha256} // '') =~ /\A[0-9a-f]{64}\z/i;
    return 1;
}

sub report_manifest_import_completion {
    my ($result, $error, $cancelled) = @_;
    if (confirmed_manifest_import_result($result)) {
        p(sprintf('Manifest snapshot %s: %d files, generation %d, %s; route %s.',
            $result->{status}, $result->{records}, $result->{generation},
            $result->{snapshot_id}, $result->{route_key}));
        if ($cancelled || $error) {
            my $detail = $error || 'worker cancellation was requested';
            $detail =~ s/[\r\n]+/ /g;
            p("The worker reported an interruption after this publication result ($detail); the result confirms generation $result->{generation}.");
        }
        p('Use /fscrawl manifest-routes, then manifest-search, manifest-prefix, manifest-parent, or manifest-exact.');
        return 1;
    }

    my $reason = $error || 'worker returned no valid publication result';
    $reason =~ s/[\r\n]+/ /g;
    p("Manifest import ended without a confirmed publication result; the active snapshot outcome is unconfirmed: $reason");
    return 0;
}

sub release_manifest_lease {
    my ($token) = @_;
    return unless defined($token) && $token =~ /^[0-9a-f]{32}$/;
    for my $job_id (keys %{$CATALOG_WORKER{jobs} || {}}) {
        my $request = $CATALOG_WORKER{jobs}{$job_id};
        return $job_id if ($request->{operation} // '') eq 'release' &&
            ($request->{lease_token} // '') eq $token;
    }
    start_catalog_worker('release', ['--lease-token', $token],
        timeout_ms => 10_000, lease_token => $token, on_done => sub {
            my ($result, $error) = @_;
            p("Could not release a manifest fetch lease during cleanup: $error") if $error;
        });
}

sub new_manifest_lease_token {
    my ($selection_token) = @_;
    my $nonce = ++$MANIFEST{lease_sequence};
    return substr(sha256_hex(join("\0", $selection_token, $$, time, $nonce, rand())), 0, 32);
}

sub release_pending_manifest_lease {
    my ($file) = @_;
    return unless ref($file) eq 'HASH';
    my $token = delete $file->{fetch_lease};
    release_manifest_lease($token) if defined $token;
}

sub release_untransferred_manifest_lease {
    my ($file) = @_;
    return unless ref($file) eq 'HASH';
    my $transfer_key = $file->{accepted_transfer_key};
    return if defined($transfer_key) && $TRANSFERS{$transfer_key};
    release_pending_manifest_lease($file);
}

sub verify_manifest_snapshot_before_get {
    my ($f) = @_;
    my $generation = $S{generation};
    my $request_token = $f->{request_token};
    my $selection = $f->{manifest_selection};
    my $snapshot_id = $f->{manifest_snapshot_id};
    unless (defined($selection) && defined($snapshot_id)) {
        p('Refusing GET: manifest selection is missing its immutable snapshot identity.');
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        $S{phase} = 'error';
        return;
    }
    my $job = start_catalog_worker('check', [
        '--selection', $selection, '--lease-token', ($f->{fetch_lease} // ''),
        '--owner-pid', $$,
    ], timeout_ms => 10_000, on_done => sub {
        my ($result, $error) = @_;
        return unless session_is_current($generation) && $S{pending_download} &&
            ($S{pending_download}{request_token} || 0) == $request_token;
        unless (!$error && $result && $result->{valid} &&
                ($result->{snapshot_id} // '') eq $snapshot_id &&
                ($result->{path} // '') eq ($f->{path} // '')) {
            my $reason = $error || 'manifest snapshot or selected path changed';
            finish_pre_dispatch_recovery_for_job(
                $f->{phase6_job_id}, $reason,
                needs_attention => 1, release_lease => 1,
                outcome => 'pre_dispatch_recovery_manifest_refused');
            p("Refusing GET: manifest selection is no longer current ($reason).");
            log_line('MANIFEST_GET_REFUSED', $reason);
            delete $S{pending_download};
            release_pending_manifest_lease($f);
            $S{phase} = 'error';
            restore_download_path_to_base();
            return;
        }
        log_line('MANIFEST_GET_REVALIDATED', "snapshot=$snapshot_id path=[$f->{path}]");
        send_verified_get($f);
    });
    unless ($job) {
        finish_pre_dispatch_recovery_for_job(
            $f->{phase6_job_id}, 'manifest snapshot validation could not be scheduled',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_manifest_check_unavailable');
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        $S{phase} = 'error';
        restore_download_path_to_base();
    }
}

sub write_catalog {
    return FServe::Catalog::write_catalog(
        $S{catalog}, $S{catalog_jsonl}, $S{catalog_tsv}
    );
}

sub drain_catalog_leases_for_unload {
    return unless $CATALOG_WORKER{loaded};
    my @acquire_ids = grep {
        $CATALOG_WORKER{jobs}{$_}{lease_acquisition}
    } keys %{$CATALOG_WORKER{jobs} || {}};
    for my $job_id (@acquire_ids) {
        my $request = $CATALOG_WORKER{jobs}{$job_id};
        my $finished = eval {
            FServe::Catalog::WorkerClient::wait_for_job($job_id, 15_000);
        };
        p("Could not cleanly finish manifest selection worker $job_id during unload.")
            unless $finished && !$@;
        release_manifest_lease($request->{lease_token})
            if defined $request->{lease_token};
    }

    my %waited;
    while (1) {
        my @release_ids = grep {
            ($CATALOG_WORKER{jobs}{$_}{operation} // '') eq 'release'
        } keys %{$CATALOG_WORKER{jobs} || {}};
        last unless @release_ids;
        my $progress = 0;
        for my $job_id (@release_ids) {
            next if $waited{$job_id}++;
            $progress = 1;
            my $finished = eval {
                FServe::Catalog::WorkerClient::wait_for_job($job_id, 15_000);
            };
            p("Could not finish manifest lease release worker $job_id during unload.")
                unless $finished && !$@;
        }
        last unless $progress;
    }
}

sub catalog_trigger_context {
    my ($trigger_command) = @_;
    if (($trigger_command // '') =~ /^\s*MSG\s+(\S+)\s+(\S+)/i) {
        return {
            trigger_raw       => $2,
            trigger_mode      => 'channel_text',
            discovery_channel => $1,
        };
    }
    if (($trigger_command // '') =~ /^\s*CTCP\s+(\S+)\s+(\S+)/i) {
        return {
            trigger_raw  => $2,
            trigger_mode => 'ctcp',
        };
    }
    return { trigger_raw => 'crawl', trigger_mode => 'unknown' };
}

sub manifest_queue_stale {
    my ($job_id, $reason) = @_;
    return unless defined $job_id;
    my $job = jobs_ready() ? $JOBS{coordinator}->job($job_id) : undef;
    job_transition($job_id, 'stale', outcome => 'queued_manifest_preflight_failed',
        reason => $reason) if $job && $job->{state} eq 'held';
}

sub cmd_manifest_get {
    my ($args, $server) = @_;
    my $queued_job_id = delete $JOBS{executing_job_id};
    if (any_find_active()) {
        p('Wait for @Find collection to finish before requesting a manifest selection.');
        return;
    }
    if ($S{active} || searchbot_direct_active() || $DOWNLOAD_PATH_OWNER || has_active_download_transfer()) {
        p('Stop the active FServe session and wait for any DCC GET to close before manifest-get.');
        return;
    }
    unless ($args =~ /^\s*(\d+)(?:\s+(channel|ctcp))?\s*$/i) {
        p('Usage: /fscrawl manifest-get <page-index> [channel|ctcp]');
        return;
    }
    my ($index, $mode_override) = ($1, defined($2) ? lc($2) : undef);
    my $query_id = $MANIFEST{query_sequence} || 0;
    my $selected = $MANIFEST{page_items}[$index - 1];
    unless ($index > 0 && $selected && ($selected->{token} // '') =~ /^[0-9a-f]{64}$/) {
        p('No selection at that page index. Run a manifest query and use one of its displayed page numbers.');
        return;
    }
    if (defined $queued_job_id) {
        my $job = jobs_ready() ? $JOBS{coordinator}->job($queued_job_id) : undef;
        my $selection = $job ? $job->{selection} : {};
        my $expected_token = 'manifest-' . $query_id . '-' .
            ($MANIFEST{page_generation} || 0) . '-' . $index;
        unless ($job && $job->{provider} eq 'manifest' && $job->{state} eq 'held' &&
                job_is_on_connection($job, $server) &&
                ($selection->{selection_token} // '') eq $expected_token &&
                ($selection->{manifest_page_generation} || 0) == ($MANIFEST{page_generation} || 0) &&
                ($selection->{manifest_selection} // '') eq ($selected->{token} // '') &&
                ($selection->{manifest_snapshot_id} // '') eq ($selected->{snapshot_id} // '') &&
                ($selection->{manifest_route_key} // '') eq ($selected->{route_key} // '') &&
                ($selection->{remote_path} // '') eq ($selected->{path} // '') &&
                ($selection->{name} // '') eq ($selected->{name} // '')) {
            job_transition($queued_job_id, 'stale', outcome => 'queued_manifest_selection_stale',
                reason => 'the queued manifest page, snapshot, route, or connection no longer matches')
                if $job && $job->{state} eq 'held';
            p('Queued manifest selection is stale or belongs to another connection/page; no trigger was sent.');
            return;
        }
    }
    my $modes = $MANIFEST{page_endpoints} || [];
    my @allowed = grep {
        !defined($mode_override) ||
        ($_->{mode} // '') eq ($mode_override eq 'channel' ? 'channel_text' : $mode_override)
    } @$modes;
    unless (@allowed == 1) {
        p(@allowed ? 'More than one endpoint matches; use a root profile that distinguishes these routes.'
                   : 'That trigger mode is not registered for this catalog route.');
        return;
    }
    my $endpoint = $allowed[0];
    my $mode = $endpoint->{mode};
    my $channel = $endpoint->{channel} // '';
    unless (($mode eq 'ctcp') ||
            ($mode eq 'channel_text' && $channel =~ /^[#&+!][^\s,\x00-\x1f\x7f]{0,199}$/)) {
        p('Catalog endpoint is not a safe CTCP or channel trigger; refusing selection.');
        return;
    }
    my $server_network = $server ? ($server->{chatnet} // $server->{tag} // '') : '';
    unless ($server && $server->{connected} &&
            lc($server->{tag} // '') eq lc($selected->{server_tag} // '') &&
            lc($server_network) eq lc($selected->{network_id} // '')) {
        p('Run manifest-get from a window on the same already-connected IRC network as this catalog route.');
        return;
    }
    unless (($selected->{server_nick} // '') =~ /^[^\s\x00-\x1f\x7f]{1,64}$/ &&
            ($selected->{trigger_raw} // '') =~ /^[^\s\x00-\x1f\x7f]{1,128}$/ &&
            ($selected->{path} // '') =~ m{^/}) {
        p('Catalog selection contains an unsafe nick, trigger, or path; refusing fetch.');
        return;
    }
    return unless load_fserve_parser() && load_dcc_policy() && load_catalog_module();
    my $token = $selected->{token};
    my $lease_token = new_manifest_lease_token($token);
    my $expected_snapshot = $selected->{snapshot_id};
    my $expected_route = $selected->{route_key};
    my $page_item = { %$selected };
    my $fetch_sequence = ++$MANIFEST{fetch_sequence};
    my $job = start_catalog_worker('check', [
        '--selection', $token, '--acquire', '--lease-token', $lease_token,
        '--owner-pid', $$,
    ], timeout_ms => 10_000, lease_token => $lease_token, on_done => sub {
        my ($result, $error) = @_;
        if (defined $queued_job_id && $JOBS{run_batch} &&
                ($JOBS{run_batch}{current_job_id} // '') eq $queued_job_id) {
            delete $JOBS{run_batch}{waiting_manifest};
        }
        if (defined $queued_job_id) {
            my $queued = jobs_ready() ? $JOBS{coordinator}->job($queued_job_id) : undef;
            unless ($queued && $queued->{state} eq 'held' &&
                    job_is_on_connection($queued, $server) &&
                    !$JOBS{paused}) {
                release_manifest_lease($lease_token);
                if ($queued && $queued->{state} eq 'held') {
                    if ($JOBS{paused} && $JOBS{run_batch}) {
                        $JOBS{run_batch}{current_job_id} = undef;
                    } else {
                        manifest_queue_stale($queued_job_id,
                            'job was cancelled or its live connection changed while snapshot verification ran');
                    }
                }
                return;
            }
        }
        unless (($MANIFEST{fetch_sequence} || 0) == $fetch_sequence &&
                ($MANIFEST{query_sequence} || 0) == $query_id) {
            release_manifest_lease($lease_token);
            manifest_queue_stale($queued_job_id,
                'manifest query changed while snapshot verification ran');
            return;
        }
        unless (!$error && $result && $result->{valid} &&
                ($result->{snapshot_id} // '') eq $expected_snapshot &&
                ($result->{route_key} // '') eq $expected_route &&
                ($result->{path} // '') eq ($page_item->{path} // '') &&
                ($result->{fetch_lease} // '') eq $lease_token) {
            release_manifest_lease($lease_token);
            p('Manifest selection is stale or unavailable; no trigger was sent. ' . ($error // 'Search the active snapshot again.'));
            manifest_queue_stale($queued_job_id,
                'catalog snapshot check did not confirm the exact queued selection');
            return;
        }
        if (($MANIFEST{query_sequence} || 0) != $query_id || $S{active} || searchbot_direct_active() ||
            $DOWNLOAD_PATH_OWNER || has_active_download_transfer() ||
            !$server->{connected} || lc($server->{tag} // '') ne lc($result->{server_tag} // '') ||
            lc(($server->{chatnet} // $server->{tag} // '')) ne lc($result->{network_id} // '')) {
            release_manifest_lease($lease_token);
            p('Selection context changed before retrieval; no trigger was sent.');
            manifest_queue_stale($queued_job_id,
                'route, global slot, or connection context changed before retrieval');
            return;
        }
        my ($parent, $name) = ($result->{parent}, $result->{name});
        unless (defined($parent) && defined($name) && length($name)) {
            release_manifest_lease($lease_token);
            p('Catalog worker returned an incomplete path; no trigger was sent.');
            manifest_queue_stale($queued_job_id,
                'catalog worker returned an incomplete path');
            return;
        }
        my %download = (
            type => 'file', path => $result->{path}, parent => $parent, name => $name,
            size_raw => $result->{size_raw}, size_bytes => $result->{size_bytes},
            trigger_raw => $result->{trigger_raw}, trigger_mode => $mode,
            discovery_channel => ($mode eq 'channel_text' ? $channel : undef),
            server_nick => $result->{server_nick}, network_id => $result->{network_id},
            server_tag => $result->{server_tag}, source => 'manifest',
            manifest_selection => $token, manifest_snapshot_id => $result->{snapshot_id},
            manifest_route_key => $result->{route_key}, fetch_lease => $lease_token,
        );
        $download{phase6_job_id} = $queued_job_id if defined $queued_job_id;
        my $trigger_command = $mode eq 'ctcp'
            ? 'CTCP ' . $result->{server_nick} . ' ' . $result->{trigger_raw}
            : 'MSG ' . $channel . ' ' . $result->{trigger_raw};
        start_fserve_session($result->{server_nick}, $server, $trigger_command, \%download);
        unless ($S{active} && $S{pending_download} &&
                ($S{pending_download}{manifest_selection} // '') eq $token) {
            release_manifest_lease($lease_token);
            p('Could not start the direct-fetch session; no trigger was sent.');
            manifest_queue_stale($queued_job_id,
                'direct-fetch session did not start after snapshot verification');
        }
    });
    $JOBS{run_batch}{waiting_manifest} = $queued_job_id
        if defined($queued_job_id) && defined($job) && $JOBS{run_batch} &&
            ($JOBS{run_batch}{current_job_id} // '') eq $queued_job_id;
    p("Selection validation job $job started; no trigger is sent until it succeeds.") if defined $job;
}

1;
