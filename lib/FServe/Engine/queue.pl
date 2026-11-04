# The engine's job queue: queued GETs, their dispatch, pauses and cancels.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use File::Basename qw(basename);
use Scalar::Util qw(refaddr);

our (%FIND, %MANIFEST, %JOBS, %S, %SEARCHBOT, %SEARCHBOT_DIRECT, $DOWNLOAD_PATH_OWNER);

sub queue_add {
    my ($args, $server) = @_;
    my ($provider, $token, $tail) = $args =~ /^\s*(\S+)\s+(\S+)(?:\s+(.*?))?\s*$/s;
    unless (defined($provider) && defined($token)) {
        p('Usage: /fscrawl queue-add <find|manifest|crawl|searchbot> <selection-token> [mode or --sender <nick>]');
        return;
    }
    $provider = lc($provider);
    $tail //= '';
    unless (jobs_ready()) { return; }
    unless ($server && $server->{connected}) {
        p('Queue selections are connection-bound; run queue-add from the connected IRC network that produced the result.');
        return;
    }
    my ($job_id, $why);
    if ($provider eq 'find') {
        my ($query_id, $ordinal) = $token =~ /\Afind-([1-9][0-9]*)-([1-9][0-9]*)\z/;
        my $result = defined($ordinal) ? $FIND{results}[$ordinal - 1] : undef;
        unless (!$FIND{active} && defined($query_id) &&
                $query_id == ($FIND{query_id} || 0) && $result &&
                ($FIND{server_identity} // '') eq server_connection_identity($server) &&
                ($FIND{connection_epoch} || 0) == server_connection_epoch($server) &&
                lc($FIND{server_tag} // '') eq lc($server->{tag} // '') &&
                lc($FIND{network_id} // '') eq lc($server->{chatnet} // $server->{tag} // '')) {
            p('Find selection token is stale or belongs to another live IRC connection; no job was added.');
            return;
        }
        my $mode = $tail =~ /\A(channel|ctcp)\z/i ? lc($tail) : undef;
        $mode = 'channel_text' if defined($mode) && $mode eq 'channel';
        $mode ||= $result->{trigger_mode} || 'channel_text';
        unless ($mode eq 'channel_text' || $mode eq 'ctcp') {
            p('Find selection has no supported trigger mode; no job was added.');
            return;
        }
        my ($path, $parent, $name) = FServe::Model::split_remote_path($result->{remote_path} // '');
        unless (defined($path) && defined($parent) && defined($name)) {
            p('Find selection has an invalid remote path; no job was added.');
            return;
        }
        my %file = (type => 'file', path => $path, parent => $parent, name => $name,
            size_raw => $result->{size_raw}, size_bytes => $result->{size_bytes},
            trigger_raw => $result->{trigger_raw}, trigger_mode => $mode,
            discovery_channel => $FIND{channel}, server_nick => $result->{server_nick},
            network_id => $result->{network_id}, server_tag => $result->{server_tag}, source => 'find');
        $file{selection_token} = $token;
        $file{selection_generation} = $query_id;
        $job_id = fserve_job(\%file, $server, undef, $result->{server_nick});
    } elsif ($provider eq 'crawl') {
        my ($generation, $ordinal) = $token =~ /\Acrawl-([1-9][0-9]*)-([1-9][0-9]*)\z/;
        unless (defined($generation) && $generation == ($S{generation} || 0) &&
                $S{active} && $S{chat_connected} &&
                ($S{server_identity} // '') eq server_connection_identity($server) &&
                ($S{connection_epoch} || 0) == server_connection_epoch($server)) {
            p('Crawl selection token is stale or the originating DCC CHAT is no longer live; no job was added.');
            return;
        }
        my $files = FServe::Catalog::files($S{catalog});
        my $selected = defined($ordinal) ? $files->[$ordinal - 1] : undef;
        unless ($selected) {
            p('No crawl file matches that selection token; no job was added.');
            return;
        }
        my %file = (%$selected, server_nick => $S{nick}, network_id => $S{network_id},
            server_tag => $S{server_tag}, trigger_raw => $S{catalog_trigger_raw},
            trigger_mode => $S{catalog_trigger_mode},
            discovery_channel => $S{catalog_trigger_channel}, source => 'crawl');
        $file{selection_token} = $token;
        $file{selection_generation} = $generation;
        $job_id = fserve_job(\%file, $server, undef, $S{nick});
    } elsif ($provider eq 'manifest') {
        my ($query_id, $generation, $ordinal) =
            $token =~ /\Amanifest-([1-9][0-9]*)-([1-9][0-9]*)-([1-9][0-9]*)\z/;
        my $selected = defined($ordinal) ? $MANIFEST{page_items}[$ordinal - 1] : undef;
        unless (defined($query_id) && $query_id == ($MANIFEST{query_sequence} || 0) &&
                defined($generation) && $generation == ($MANIFEST{page_generation} || 0) && $selected &&
                lc($server->{tag} // '') eq lc($selected->{server_tag} // '') &&
                lc($server->{chatnet} // $server->{tag} // '') eq lc($selected->{network_id} // '')) {
            p('Manifest selection token is stale or belongs to another route/page; no job was added.');
            return;
        }
        my $mode = $tail =~ /\A(channel|ctcp)\z/i ? lc($tail) : undef;
        $mode = 'channel_text' if defined($mode) && $mode eq 'channel';
        my @allowed = grep { !defined($mode) || ($_->{mode} // '') eq $mode }
            @{$MANIFEST{page_endpoints} || []};
        unless (@allowed == 1) {
            p(@allowed ? 'More than one manifest endpoint matches; specify channel or ctcp.'
                       : 'No manifest endpoint matches that trigger mode; no job was added.');
            return;
        }
        my $endpoint = $allowed[0];
        my $actual_mode = $endpoint->{mode};
        my $channel = $endpoint->{channel} // '';
        my %file = (type => 'file', path => $selected->{path}, parent => $selected->{parent},
            name => $selected->{name}, size_raw => $selected->{size_raw},
            size_bytes => $selected->{size_bytes}, trigger_raw => $selected->{trigger_raw},
            trigger_mode => $actual_mode,
            discovery_channel => $actual_mode eq 'channel_text' ? $channel : undef,
            server_nick => $selected->{server_nick}, network_id => $selected->{network_id},
            server_tag => $selected->{server_tag}, source => 'manifest',
            manifest_selection => $selected->{token},
            manifest_snapshot_id => $selected->{snapshot_id},
            manifest_route_key => $selected->{route_key},
            selection_token => $token,
            selection_generation => $generation,
            manifest_page_generation => $generation);
        $job_id = fserve_job(\%file, $server, undef, $selected->{server_nick});
    } elsif ($provider eq 'searchbot') {
        my ($sender) = $tail =~ /\A--sender\s+(\S+)\z/;
        my ($status, $candidate) = searchbot_selection_candidate($token);
        unless ($candidate && defined($sender) && searchbot_nick_is_safe($sender) &&
                ($SEARCHBOT{server_identity} // '') eq server_connection_identity($server) &&
                ($SEARCHBOT{connection_epoch} || 0) == server_connection_epoch($server)) {
            p('SearchBot selection token/sender is stale or incomplete; include --sender and use the originating live connection.');
            return;
        }
        my $checked = FServe::Discovery::SearchBotRequest::validate_candidate(
            $candidate, channel => $SEARCHBOT{channel});
        unless (($checked->{type} // '') eq 'valid') {
            p('SearchBot row is not requestable: ' . safe_field($checked->{reason}));
            return;
        }
        my $content_limit = configured_searchbot_content_limit();
        unless ($content_limit) {
            p('Configured SearchBot content limit is invalid; no job was added.');
            return;
        }
        $job_id = new_job(provider => 'searchbot', server => $server,
            selection => {
                collection_id => $candidate->{collection_id},
                physical_source_row => $candidate->{result_row},
                result_ordinal => $candidate->{result_ordinal},
                exact_payload => $candidate->{request_line},
                payload_sha256 => $checked->{request_line_digest},
                basename => $candidate->{filename}, offered_basename => $candidate->{filename},
                originating_channel => $SEARCHBOT{channel}, expected_peer => $sender,
                sender => $sender, legacy_aliases => [],
            },
            context => { channel => $SEARCHBOT{channel}, server_tag => $SEARCHBOT{server_tag} },
            limits => { offer_timeout_ms => bounded_timeout_setting(
                    'fscrawl_searchbot_content_timeout_ms', 120000, 1000, 300000),
                transfer_timeout_ms => bounded_timeout_setting(
                    'fscrawl_searchbot_content_transfer_timeout_ms', 300000, 1000, 1800000),
                content_bytes => $content_limit });
    } else {
        p('Supported local queue providers are find, manifest, crawl, and searchbot.');
        return;
    }
    p("Added held job $job_id; queue-add sent no network traffic.") if $job_id;
}

sub queue_cancel_dispatch_timer {
    my $run = $JOBS{run_batch} or return;
    Irssi::timeout_remove($run->{timer}) if defined $run->{timer};
    $JOBS{scheduler}->cancel($run->{reservation}{token})
        if $run->{reservation} && $JOBS{scheduler};
    delete $run->{timer};
    delete $run->{reservation};
}

sub paused_get_context_for {
    my ($job_id) = @_;
    my $paused = $S{phase6_paused_get};
    return $paused if $paused && ($paused->{job_id} // '') eq ($job_id // '');
    return;
}

sub consume_paused_chat_response {
    my ($line) = @_;
    my $paused = $S{phase6_paused_get} or return 0;
    my $mode = $paused->{drain_response} // '';
    return 0 unless $mode eq 'prompt' || $mode eq 'listing';

    my $ev = FServeParser::parse_line($line);
    if ($mode eq 'prompt' && ($ev->{type} // '') eq 'prompt') {
        my ($actual, $is_listing_header) = prompt_path_info($ev->{path});
        unless ($is_listing_header) {
            # The acknowledged command may have changed the server's current
            # directory. Plan resumed navigation from that live path.
            $S{current_path} = [@$actual];
            delete $paused->{drain_response};
            delete $paused->{drain_header_seen};
            p('The outstanding CHAT navigation reply finished; rerun queue-run to resume this held job.');
        }
    } elsif ($mode eq 'listing') {
        if (($ev->{type} // '') eq 'prompt') {
            my @prompt = prompt_path_info($ev->{path});
            my $is_listing_header = $prompt[1];
            $paused->{drain_header_seen} = 1 if $is_listing_header;
        } elsif (($ev->{type} // '') eq 'end' && $paused->{drain_header_seen}) {
            delete $paused->{drain_response};
            delete $paused->{drain_header_seen};
            p('The outstanding CHAT listing reply finished; rerun queue-run to resume this held job.');
        }
    }
    # Keep every line in the old response out of the resumed verification,
    # including the line that marks its end.
    return 1;
}

sub queue_job_is_paused {
    my ($job_id) = @_;
    my $run = $JOBS{run_batch} or return 0;
    return $JOBS{paused} && defined($job_id) &&
        ($run->{current_job_id} // '') eq $job_id ? 1 : 0;
}

sub pause_active_queued_get {
    my ($job_id) = @_;
    return 0 unless defined($job_id) && $S{active} && $S{chat_connected} &&
        $S{pending_download} &&
        ($S{pending_download}{phase6_job_id} // '') eq $job_id;
    # Let the durable GET-dispatch callback record dispatch_intent -> held and
    # preserve its result when queue-pause withdraws that exact GET.
    return 0 if ($S{phase} // '') eq 'get_dispatch_pending';

    my $job = $JOBS{coordinator}->job($job_id);
    return 0 unless $job && ($job->{state} eq 'preparing' || $job->{state} eq 'held');
    my $crawl_session_match = $job->{provider} eq 'crawl' &&
        ($job->{selection}{session_generation} || 0) == ($S{generation} || 0);
    return 0 unless ($S{phase6_job_id} // '') eq $job_id || $crawl_session_match;
    if ($job->{state} eq 'preparing') {
        my $transitioned = job_transition($job_id, 'held',
            outcome => 'queue_paused_before_get',
            reason => 'queue pause stopped parent navigation/listing before any content GET');
        return 0 unless $transitioned;
        $job = $JOBS{coordinator}->job($job_id);
        return 0 unless $job && $job->{state} eq 'held';
    }

    my $pending = $S{pending_download};
    my %resume_file = %$pending;
    delete @resume_file{qw(fetch_lease request_token request_sent)};
    my $drain_response;
    my $drain_header_seen;
    $drain_response = 'prompt'
        if $S{nav_active} && !$S{nav_send_pending};
    if (!$drain_response && $S{listing_active} && !$S{listing_send_pending}) {
        $drain_response = 'listing';
        $drain_header_seen = $S{listing_header_seen} ? 1 : 0;
    }
    if (!$drain_response && $S{verify_get_active} && !$S{verify_get_send_pending}) {
        $drain_response = 'listing';
        $drain_header_seen = $S{verify_get_header_seen} ? 1 : 0;
    }
    my $generation = $S{generation};
    my $connection_identity = server_connection_identity($S{server});
    my $connection_epoch = server_connection_epoch($S{server});
    $S{phase6_paused_get} = {
        job_id => $job_id,
        generation => $generation,
        chat_identity_key => $S{chat_identity_key},
        connection_identity => $connection_identity,
        connection_epoch => $connection_epoch,
        file => \%resume_file,
        drain_response => $drain_response,
        drain_header_seen => $drain_header_seen,
    };

    # Invalidate both outbound-command callbacks and acknowledgement timers.
    # Resume starts over at the selected parent and requires a new live listing.
    cancel_session_timer($S{nav_timer});
    cancel_session_timer($S{sequence_timer});
    $S{nav_timer} = undef;
    $S{sequence_timer} = undef;
    $S{nav_seq} = ($S{nav_seq} || 0) + 1;
    $S{sequence_token} = ($S{sequence_token} || 0) + 1;
    $S{nav_active} = 0;
    $S{nav_steps} = [];
    delete $S{nav_after};
    $S{nav_expected} = undef;
    $S{nav_send_pending} = 0;
    $S{listing_active} = 0;
    $S{listing_send_pending} = 0;
    $S{verify_get_active} = 0;
    $S{verify_get_send_pending} = 0;
    $S{verified_parent_path} = undef;
    $S{verified_parent_files} = [];
    $S{pending_download} = undef;
    release_pending_manifest_lease($pending);
    restore_download_path_to_base();
    $S{phase} = 'paused_before_get';
    return 1;
}

sub paused_get_matches {
    my ($job, $server) = @_;
    return 0 unless $job && $server && $job->{state} eq 'held';
    my $paused = paused_get_context_for($job->{id}) or return 0;
    my $file = $paused->{file};
    my $selection = $job->{selection} || {};
    my $session_job_matches = ($S{phase6_job_id} // '') eq $job->{id} ||
        ($job->{provider} eq 'crawl' &&
            ($selection->{session_generation} || 0) == ($S{generation} || 0));
    return 0 unless ref($file) eq 'HASH' &&
        $S{active} && $S{chat_connected} && ($S{phase} // '') eq 'paused_before_get' &&
        $session_job_matches &&
        ($S{generation} || 0) == ($paused->{generation} || 0) &&
        ($S{chat_identity_key} // '') eq ($paused->{chat_identity_key} // '') &&
        server_connection_identity($server) eq ($paused->{connection_identity} // '') &&
        server_connection_epoch($server) == ($paused->{connection_epoch} || 0) &&
        server_connection_identity($S{server}) eq ($paused->{connection_identity} // '') &&
        server_connection_epoch($S{server}) == ($paused->{connection_epoch} || 0) &&
        !$S{pending_download} && !$S{nav_active} && !$S{verify_get_active} &&
        !$DOWNLOAD_PATH_OWNER && !has_active_download_transfer();
    return 0 unless ($selection->{remote_path} // '') eq ($file->{path} // '') &&
        ($selection->{name} // '') eq ($file->{name} // '') &&
        ($selection->{expected_peer} // '') eq ($file->{server_nick} // '') &&
        ($selection->{trigger_raw} // '') eq ($file->{trigger_raw} // '');
    if ($job->{provider} eq 'manifest') {
        return 0 unless ($selection->{manifest_selection} // '') eq
                ($file->{manifest_selection} // '') &&
            ($selection->{manifest_snapshot_id} // '') eq
                ($file->{manifest_snapshot_id} // '') &&
            ($selection->{manifest_route_key} // '') eq
                ($file->{manifest_route_key} // '');
    }
    return $job->{provider} =~ /\A(?:find|manifest|crawl)\z/ ? 1 : 0;
}

sub stale_paused_get {
    my ($job_id, $reason) = @_;
    my $paused = $S{phase6_paused_get};
    delete $S{phase6_paused_get}
        if $paused && ($paused->{job_id} // '') eq ($job_id // '');
    job_transition($job_id, 'stale',
        outcome => 'paused_get_preflight_failed', reason => $reason);
}

sub start_paused_get {
    my ($job_id, $file) = @_;
    my $pending = new_pending_download($file);
    $pending->{phase6_job_id} = $job_id;
    unless (prepare_download_staging($pending)) {
        release_pending_manifest_lease($pending);
        stale_paused_get($job_id,
            'fresh staging could not be prepared after queue pause');
        return 0;
    }
    $S{pending_download} = $pending;
    delete $S{phase6_paused_get};
    $S{verified_parent_path} = undef;
    $S{verified_parent_files} = [];
    $S{phase} = 'paused_before_get';
    if ($JOBS{run_batch} &&
            ($JOBS{run_batch}{current_job_id} // '') eq $job_id) {
        my $job = $JOBS{coordinator}->job($job_id);
        if ($job && $job->{provider} eq 'crawl') {
            $JOBS{run_batch}{waiting_crawl} = $job_id;
        } else {
            $JOBS{run_batch}{waiting_manifest} = $job_id;
        }
    }
    my @parts = grep { length } split m{/+}, ($pending->{parent} // '/');
    navigate_to(\@parts, sub { begin_download_verify($pending) });
    return 1;
}

sub resume_paused_get {
    my ($job, $server) = @_;
    return 0 unless paused_get_matches($job, $server);
    my $job_id = $job->{id};
    my $paused = paused_get_context_for($job_id);
    my %file = %{$paused->{file}};
    if ($job->{provider} ne 'manifest') {
        start_paused_get($job_id, \%file);
        return 1;
    }

    my $selection = $job->{selection};
    my $lease_token = new_manifest_lease_token($selection->{manifest_selection});
    $JOBS{run_batch}{waiting_manifest} = $job_id if $JOBS{run_batch};
    my $worker_id = start_catalog_worker('check', [
        '--selection', $selection->{manifest_selection}, '--acquire',
        '--lease-token', $lease_token, '--owner-pid', $$,
    ], timeout_ms => 10_000, lease_token => $lease_token,
        on_done => sub {
            my ($result, $error) = @_;
            my $run = $JOBS{run_batch};
            my $current = $run &&
                ($run->{current_job_id} // '') eq $job_id;
            my $fresh = $JOBS{coordinator}->job($job_id);
            unless ($current && $fresh && $fresh->{state} eq 'held') {
                release_manifest_lease($lease_token);
                return;
            }
            if ($JOBS{paused}) {
                release_manifest_lease($lease_token);
                $run->{current_job_id} = undef;
                $run->{waiting_manifest} = undef;
                return;
            }
            my $valid = !$error && $result && $result->{valid} &&
                ($result->{fetch_lease} // '') eq $lease_token &&
                ($result->{snapshot_id} // '') eq
                    ($selection->{manifest_snapshot_id} // '') &&
                ($result->{route_key} // '') eq
                    ($selection->{manifest_route_key} // '') &&
                ($result->{path} // '') eq ($selection->{remote_path} // '') &&
                ($result->{name} // '') eq ($selection->{name} // '') &&
                ($result->{server_tag} // '') eq ($job->{context}{server_tag} // '') &&
                ($result->{network_id} // '') eq ($job->{network_profile} // '');
            unless ($valid && paused_get_matches($fresh, $server)) {
                release_manifest_lease($lease_token);
                $run->{waiting_manifest} = undef;
                stale_paused_get($job_id,
                    $error || 'manifest selection or live session changed before resumed parent verification');
                return;
            }
            @file{qw(path parent name size_raw size_bytes server_nick server_tag network_id
                trigger_raw manifest_snapshot_id manifest_route_key fetch_lease)} =
                @{$result}{qw(path parent name size_raw size_bytes server_nick server_tag network_id
                    trigger_raw snapshot_id route_key fetch_lease)};
            start_paused_get($job_id, \%file);
        });
    unless (defined $worker_id) {
        if ($JOBS{run_batch}) {
            $JOBS{run_batch}{waiting_manifest} = undef;
        }
        stale_paused_get($job_id,
            'manifest selection could not be revalidated after queue pause');
    }
    return 1;
}

sub queue_dispatch_fire {
    my ($run, $server, $id, $job, $selection) = @_;
    my $current = $JOBS{run_batch};
    return unless $current && refaddr($current) == refaddr($run) &&
        !$JOBS{paused} && !$current->{dispatching} &&
        !defined($current->{current_job_id});
    my $current_job = $JOBS{coordinator}->job($id);
    if ($current_job && ($current_job->{state} eq 'stale' ||
            ($current_job->{state} eq 'cancelled' &&
                ($current_job->{outcome} // '') eq 'local_queue_cancelled'))) {
        queue_run_next();
        return;
    }
    unless ($current_job && $current_job->{state} eq 'held' &&
            job_is_on_connection($current_job, $server)) {
        $current->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        p("The job batch paused because job $id is stale or no longer held.");
        return;
    }
    $current->{dispatching} = 1;
    $current->{current_job_id} = $id;
    delete $current->{waiting_manifest};
    $JOBS{active_job_id} = $id;
    $JOBS{executing_job_id} = $id;
    my $token = $selection->{selection_token} // '';
    my $ok = eval {
        if (paused_get_context_for($id)) {
            resume_paused_get($job, $server);
        } elsif ($job->{provider} eq 'find' && $token =~ /^find-[1-9][0-9]*-([1-9][0-9]*)$/) {
            my $mode = ($selection->{trigger_mode} // '') eq 'ctcp' ? 'ctcp' : 'channel';
            cmd_fetch($1 . ' ' . $mode, $server);
        } elsif ($job->{provider} eq 'manifest' &&
                $token =~ /^manifest-[1-9][0-9]*-[1-9][0-9]*-([1-9][0-9]*)$/) {
            my $mode = ($selection->{trigger_mode} // '') eq 'ctcp' ? 'ctcp' : 'channel';
            cmd_manifest_get($1 . ' ' . $mode, $server);
        } elsif ($job->{provider} eq 'crawl' &&
                $token =~ /^crawl-[1-9][0-9]*-([1-9][0-9]*)$/) {
            cmd_get($1);
        } elsif ($job->{provider} eq 'searchbot' &&
                ($selection->{collection_id} // '') =~ /^searchbot-[1-9][0-9]*-[a-f0-9]{32}$/i &&
                ($selection->{result_ordinal} || 0) > 0) {
            cmd_searchbot_get($selection->{collection_id} . ':' .
                $selection->{result_ordinal} . ' --sender ' .
                ($selection->{expected_peer} // ''), $server);
        } else {
            p("Queued job $id has no supported immutable selection token; no request was sent.");
        }
        1;
    };
    delete $JOBS{executing_job_id};
    $current->{dispatching} = 0;
    unless ($ok) {
        my $error = $@ || 'provider adapter failed before dispatch';
        $error =~ s/[\r\n]+/ /g;
        p("Queued job $id stopped: $error");
    }
    my $after = $JOBS{coordinator}->job($id);
    if ($after && $after->{state} eq 'held' &&
            ($current->{waiting_manifest} // '') ne $id &&
            ($current->{waiting_crawl} // '') ne $id) {
        job_transition($id, 'stale', outcome => 'queued_selection_refused',
            reason => 'provider adapter did not advance the held job; no request was dispatched');
        queue_batch_settled($id);
    }
    if ($after && $after->{state} eq 'needs_attention') {
        $current->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        $current->{current_job_id} = undef;
        p("The job batch paused for inspection at $id.");
    } elsif ($current->{waiting_manifest} &&
            (!$after || $after->{state} ne 'held')) {
        $current->{waiting_manifest} = undef;
    }
}

sub queue_run_next {
    my $run = $JOBS{run_batch} or return;
    return if $JOBS{paused} || $run->{dispatching} || defined($run->{current_job_id});
    while ($run->{index} < @{$run->{job_ids}}) {
        my $skipped = $JOBS{coordinator}->job($run->{job_ids}[$run->{index}]);
        last unless $skipped && ($skipped->{state} eq 'stale' ||
            ($skipped->{state} eq 'cancelled' &&
                ($skipped->{outcome} // '') eq 'local_queue_cancelled'));
        $run->{index}++;
    }
    if ($run->{index} >= @{$run->{job_ids}}) {
        delete $JOBS{run_batch};
        p('The finite job run set is complete.');
        return;
    }
    my $id = $run->{job_ids}[$run->{index}];
    my $job = $JOBS{coordinator}->job($id);
    my $server = $run->{servers_by_job}{$id};
    unless ($server && $server->{connected} && $job &&
            $job->{state} eq 'held' && job_is_on_connection($job, $server)) {
        $run->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        p("The job batch paused at $id because its captured IRC connection is unavailable in this process.");
        return;
    }
    my $paused_context = paused_get_context_for($id);
    if ($paused_context && $paused_context->{drain_response}) {
        $run->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        p('The job batch remains paused until the outstanding CHAT reply finishes; rerun the same queue-run set afterward.');
        return;
    }
    my $paused_get_slot = paused_get_matches($job, $server);
    if (paused_get_context_for($id) && !$paused_get_slot) {
        stale_paused_get($id,
            'the original DCC CHAT session or immutable paused selection is no longer current');
        return;
    }
    my $crawl_slot = $job->{provider} eq 'crawl' && $S{active} && $S{chat_connected} &&
        ($S{server_identity} // '') eq ($job->{context}{connection_identity} // '') &&
        ($S{connection_epoch} || 0) == ($job->{context}{connection_epoch} || 0) &&
        !$S{pending_download} && !$S{nav_active} && !$S{verify_get_active};
    if ($S{active} && !$crawl_slot && ($S{phase} // '') eq 'complete' &&
            !$S{pending_download} && !$DOWNLOAD_PATH_OWNER && !has_active_download_transfer()) {
        stop_session(1);
    }
    if (($S{active} && !$crawl_slot && !$paused_get_slot) || searchbot_direct_active() ||
            $DOWNLOAD_PATH_OWNER || has_active_download_transfer()) {
        $run->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        p('The job batch paused because another session, DCC request, or transfer owns the global slot.');
        return;
    }
    if ($job->{provider} eq 'crawl' && !$crawl_slot && !$paused_get_slot) {
        $run->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        p('Queued crawl job requires its original active DCC CHAT session; it cannot be rebound.');
        return;
    }
    my $selection = $job->{selection} || {};
    queue_dispatch_fire($run, $server, $id, $job, $selection);
}

sub queue_batch_settled {
    my ($id) = @_;
    my $run = $JOBS{run_batch} or return;
    return unless defined($id) && ($run->{current_job_id} // '') eq $id;
    my $job = $JOBS{coordinator}->job($id);
    return unless $job && FServe::Transfer::Job::is_terminal($job->{state});
    my $explicit_local_cancel = $job->{state} eq 'cancelled' &&
        ($job->{outcome} // '') eq 'local_queue_cancelled';
    if ($job->{state} ne 'complete' && $job->{state} ne 'refused_without_queue' &&
            $job->{state} ne 'stale' &&
            !$explicit_local_cancel) {
        $run->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        $run->{current_job_id} = undef;
        $run->{waiting_manifest} = undef;
        $run->{waiting_crawl} = undef;
        p("The job batch paused after $id ended in $job->{state}; inspect before running another job.");
        return;
    }
    $run->{index}++;
    $run->{current_job_id} = undef;
    $run->{waiting_manifest} = undef;
    $run->{waiting_crawl} = undef;
    if ($run->{index} >= @{$run->{job_ids}}) {
        delete $JOBS{run_batch};
        delete $JOBS{active_job_id};
        p('The finite job run set is complete.');
        return;
    }
    return if $JOBS{paused};
    my $timer = eval { Irssi::timeout_add_once(10, sub {
        my $current = $JOBS{run_batch};
        return unless $current && refaddr($current) == refaddr($run) && !$JOBS{paused} &&
            $current->{index} == $run->{index};
        queue_run_next();
    }, undef) };
    unless (defined $timer) {
        $run->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        p('The job batch paused because Irssi could not schedule the next bounded job.');
        return;
    }
    $run->{advance_timer} = $timer;
}

sub pause_batch_for_cancel {
    my ($job_id) = @_;
    my $run = $JOBS{run_batch} or return;
    return unless ($run->{current_job_id} // '') eq ($job_id // '');
    $run->{paused_for_attention} = 1;
    $JOBS{paused} = 1;
}

sub cmd_queue_cancel {
    my ($id) = @_;
    return unless jobs_ready();
    $id //= '';
    $id =~ s/^\s+|\s+$//g;
    my $job = $id =~ /\Ajob-[a-f0-9]{32}\z/ ? $JOBS{coordinator}->job($id) : undef;
    unless ($job) { p('Unknown job ID.'); return; }
    if ($job->{state} eq 'held' &&
            !($S{active} && ($S{phase6_job_id} // '') eq $id)) {
        my $recorded = job_transition($id, 'cancelled', outcome => 'local_queue_cancelled',
            reason => 'operator cancelled the held local job; no remote request was sent');
        if ($recorded) {
            delete $S{phase6_paused_get}
                if paused_get_context_for($id);
            delete $JOBS{active_job_id}
                if ($JOBS{active_job_id} // '') eq $id;
        }
        p($recorded
            ? 'Held local job cancelled; its durable DCC tuple was not released.'
            : 'Held job cancellation could not be recorded; its durable DCC tuple and closed-session barrier remain.');
        return;
    }
    if (($SEARCHBOT_DIRECT{phase6_job_id} // '') eq $id && searchbot_direct_active()) {
        pause_batch_for_cancel($id);
        retire_searchbot_direct('cancelled', 'operator cancelled the exact queued SearchBot transfer');
        delete $JOBS{active_job_id} if ($JOBS{active_job_id} // '') eq $id;
        p('Active SearchBot job cancelled locally; any partial data remains staged and its offer guard is retained.');
        return;
    }
    my $cancelled_transfer = cancel_owned_transfer($id);
    if ($cancelled_transfer) {
        p($cancelled_transfer > 0
            ? 'The exact owned transfer was cancelled; its partial remains staged and its offer guard is retained.'
            : 'The exact native transfer was stopped locally, but its durable cancellation could not be recorded; its tuple guard and staging evidence remain.');
        return;
    }
    if ($S{active} && ($S{phase6_job_id} // '') eq $id) {
        pause_batch_for_cancel($id);
        cancel_wait_timer($id);
        cancel_outbound_owner('job', $id,
            'operator cancelled the queued FServe session before transfer dispatch');
        my $current = $JOBS{coordinator}->job($id);
        my $recorded = 1;
        unless (!$current || FServe::Transfer::Job::is_terminal($current->{state})) {
            $recorded = job_transition($id, 'cancelled',
                outcome => 'local_queue_cancelled',
                reason => 'operator cancelled the owning FServe session between protocol messages; no remote removal was sent');
        }
        delete $S{phase6_paused_get};
        stop_session(1);
        delete $JOBS{active_job_id} if ($JOBS{active_job_id} // '') eq $id;
        my $after_cancel = $JOBS{coordinator}->job($id);
        queue_batch_settled($id)
            if $after_cancel && FServe::Transfer::Job::is_terminal($after_cancel->{state}) &&
                ($after_cancel->{outcome} // '') eq 'local_queue_cancelled';
        p($recorded
            ? 'Queued FServe session cancelled locally; pending navigation/listing callbacks are inert and no GET or remote queue removal will be sent.'
            : 'Queued FServe session stopped locally, but durable cancellation could not be recorded; inspect its journal state before any further action.');
        return;
    }
    if (($JOBS{active_job_id} // '') eq $id &&
            ($job->{state} eq 'awaiting_offer' || $job->{state} eq 'remote_queued')) {
        pause_batch_for_cancel($id);
        cancel_wait_timer($id);
        job_transition($id, 'cancelled', outcome => 'local_queue_cancelled',
            reason => 'operator cancelled the local offer/remote-queue wait; no remote removal command was sent');
        stop_session(1) if $S{pending_download} &&
            ($S{pending_download}{phase6_job_id} // '') eq $id;
        delete $JOBS{active_job_id} if ($JOBS{active_job_id} // '') eq $id;
        p('Local offer/queue wait cancelled; the remote queue entry, if any, was not removed and its offer guard remains.');
        return;
    }
    if ($job->{state} =~ /\A(?:preparing|dispatch_intent)\z/ &&
            cancel_outbound_owner('job', $id,
                'operator cancelled this queued message before dispatch')) {
        pause_batch_for_cancel($id);
        my $after_cancel = $JOBS{coordinator}->job($id);
        if ($after_cancel && $after_cancel->{state} =~ /\A(?:preparing|dispatch_intent|needs_attention)\z/) {
            job_transition($id, 'cancelled', outcome => 'local_queue_cancelled',
                reason => 'operator cancelled the pending local message; no remote cancellation was sent');
        }
        stop_session(1) if $S{pending_download} &&
            ($S{pending_download}{phase6_job_id} // '') eq $id;
        delete $JOBS{active_job_id} if ($JOBS{active_job_id} // '') eq $id;
        p('Pending local message cancelled before dispatch; any later remote offer is still guarded.');
        return;
    }
    if ($job->{state} eq 'needs_attention' || $job->{state} eq 'interrupted') {
        job_transition($id, 'cancelled', outcome => 'local_queue_cancelled',
            reason => 'operator retired this ambiguous local job; durable stale-offer guards remain');
        p('Local job retired; this does not remove a remote queue entry, and its DCC tuple guard remains reserved.');
        return;
    }
    p('This job is no longer locally cancellable in its current state; no remote queue-removal command was sent.');
}

1;
