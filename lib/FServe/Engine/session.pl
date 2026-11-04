# An FServe session: the DCC CHAT, its navigation, listings and GETs.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Fcntl qw(O_RDWR);
use Digest::SHA qw(sha256_hex);
use File::Spec ();
use POSIX qw(strftime);
use bytes ();
use Socket qw(AF_INET AF_INET6 MSG_DONTWAIT MSG_PEEK inet_pton sockaddr_family unpack_sockaddr_in unpack_sockaddr_in6);

our (%FIND, %MANIFEST, %JOBS, %S, %SEARCHBOT, %TRANSFERS, %WEB_BRIDGE,
     $DOWNLOAD_PATH_OWNER, $SESSION_GENERATION, $WEB_BRIDGE, $old_dcc_download_path);

sub same_chat {
    my ($dcc) = @_;
    return 0 unless $S{active} && $S{chat_identity_key};
    # Once the file server has changed nick, only the renamed CHAT is ours.
    return renamed_chat_matches($dcc) if defined $S{chat_renamed_to};
    return 0 unless same_dcc_peer($dcc);
    my $key = dcc_chat_identity_key($dcc);
    return defined($key) && $key eq $S{chat_identity_key};
}

sub send_chat_now {
    my ($cmd, %args) = @_;
    return unless $S{active} && $S{chat_connected} && $S{chat_id} &&
        $S{chat_identity_key} && $S{server} && $S{server}{connected};
    my ($generation, $chat_key, $chat_id, $server) =
        @S{qw(generation chat_identity_key chat_id server)};
    my $caller_guard = $args{guard};
    my $caller_done = $args{on_done};
    my $job_id = defined($args{job_id}) ? $args{job_id}
        : $S{pending_download} ? $S{pending_download}{phase6_job_id}
        : $S{direct_fetch} ? $S{phase6_job_id} : undef;
    my $scheduled = schedule_irc_message(
        server => $server, kind => 'chat',
        owner_kind => $args{owner_kind} // 'session',
        owner_id => defined($args{owner_id}) ? $args{owner_id} : "$generation",
        owner_job_id => $job_id,
        guard => sub {
            chat_session_is_current($generation, $chat_key) &&
                ($S{chat_id} // '') eq ($chat_id // '') &&
                $S{server} && server_connection_identity($S{server}) eq
                    server_connection_identity($server) &&
                server_connection_epoch($S{server}) == server_connection_epoch($server) &&
                (!ref($caller_guard) || $caller_guard->())
        },
        before_send => $args{before_send},
        send => sub {
            log_line('OUT', $cmd);
            Irssi::command('MSG =' . $chat_id . ' ' . $cmd);
        },
        on_done => sub {
            my ($status, $reason) = @_;
            # queue-pause snapshots and invalidates this selection before it
            # withdraws any pending protocol command. Do not let the command's
            # ordinary failure handler tear down that resumable checkpoint.
            return if $status eq 'paused_before_send' && defined($job_id) &&
                paused_get_context_for($job_id);
            $caller_done->($status, $reason) if ref($caller_done) eq 'CODE';
        },
    );
    return $scheduled;
}

sub session_is_current {
    my ($generation) = @_;
    return $S{active} && defined($S{generation}) &&
        $S{generation} == $generation && $SESSION_GENERATION == $generation;
}

sub chat_session_is_current {
    my ($generation, $chat_key) = @_;
    return 0 unless session_is_current($generation) && $S{chat_connected};
    return defined($S{chat_identity_key}) && $S{chat_identity_key} eq $chat_key;
}

sub schedule_session_timer {
    my ($ms, $callback, $guard) = @_;
    return unless $S{active} && defined $S{generation};
    my $generation = $S{generation};
    my $timer_store = $S{session_timers} ||= {};
    my $handle;
    my $wrapped = sub {
        delete $timer_store->{$handle} if defined $handle;
        return unless session_is_current($generation);
        return if $guard && !$guard->();
        $callback->();
    };
    $handle = Irssi::timeout_add_once($ms, $wrapped, undef);
    $timer_store->{$handle} = 1 if defined $handle;
    return $handle;
}

sub cancel_session_timer {
    my ($handle) = @_;
    return unless defined $handle;
    my $timer_store = $S{session_timers} || {};
    delete $timer_store->{$handle};
    Irssi::timeout_remove($handle);
}

sub cancel_session_timers {
    my $timer_store = $S{session_timers} || {};
    Irssi::timeout_remove($_) for keys %$timer_store;
    %$timer_store = ();
}

sub send_sequence {
    my ($commands, $done) = @_;
    return unless $S{active} && $S{chat_connected} && $S{chat_identity_key};
    cancel_session_timer($S{sequence_timer});
    my $generation = $S{generation};
    my $chat_key = $S{chat_identity_key};
    my $token = ++$S{sequence_token};
    my @q = @$commands;
    my $delay = Irssi::settings_get_int('fscrawl_command_delay_ms') || 400;
    $delay = 400 if $delay < 400;

    my $step;
    $step = sub {
        return unless chat_session_is_current($generation, $chat_key);
        return unless ($S{sequence_token} || 0) == $token;
        if (!@q) {
            $S{sequence_timer} = undef;
            $done->() if $done;
            return;
        }
        my $cmd = shift @q;
        my $scheduled = send_chat_now($cmd, on_done => sub {
            my ($status, $reason) = @_;
            return unless chat_session_is_current($generation, $chat_key) &&
                ($S{sequence_token} || 0) == $token;
            unless ($status eq 'sent') {
                nav_fail('DCC CHAT command did not dispatch: ' . safe_field($reason // $status));
                return;
            }
            my $timer = schedule_session_timer(
                $delay, $step,
                sub {
                    chat_session_is_current($generation, $chat_key) &&
                        ($S{sequence_token} || 0) == $token
                },
            );
            unless (defined $timer) {
                nav_fail('could not schedule the bounded DCC CHAT command interval');
                return;
            }
            $S{sequence_timer} = $timer;
        });
        unless ($scheduled) {
            nav_fail('could not reserve the DCC CHAT application-message rate budget');
            return;
        }
    };
    $step->();
}

sub path_key { return join("\x1f", @{$_[0] || []}); }

sub common_prefix_len {
    my ($a, $b) = @_;
    my $n = @$a < @$b ? @$a : @$b;
    my $i = 0;
    $i++ while $i < $n && $a->[$i] eq $b->[$i];
    return $i;
}

sub path_eq {
    my ($a, $b) = @_;
    $a ||= [];
    $b ||= [];
    return 0 unless @$a == @$b;
    for my $i (0 .. $#$a) {
        return 0 unless lc($a->[$i]) eq lc($b->[$i]);
    }
    return 1;
}

sub prompt_path_info {
    my ($path) = @_;
    $path //= '\\';
    $path =~ s{/}{\\}g;
    $path =~ s{\\+}{\\}g;
    my $is_listing = ($path =~ s{(?:\\)?\*\.\*$}{}i) ? 1 : 0;
    $path =~ s{^\\+}{};
    $path =~ s{\\+$}{};
    my @parts = length($path) ? grep { length } split(/\\+/, $path) : ();
    return (\@parts, $is_listing);
}

sub nav_fail {
    my ($why, $outcome) = @_;
    my $generation = $S{generation};
    $S{nav_active} = 0;
    $S{sequence_token} = ($S{sequence_token} || 0) + 1;
    cancel_outbound_owner('session', "$generation",
        'FServe navigation/session operation failed before delayed dispatch')
        if defined $generation;
    cancel_session_timer($S{nav_timer});
    cancel_session_timer($S{sequence_timer});
    $S{nav_timer} = undef;
    $S{sequence_timer} = undef;
    p("Navigation failed closed: $why");
    log_line('NAV_ERROR', $why);
    $S{phase} = 'error';
    $S{listing_active} = 0;
    $S{verify_get_active} = 0;
    if ($S{direct_fetch}) {
        my $pending = delete $S{pending_download};
        release_pending_manifest_lease($pending);
        restore_download_path_to_base();
        web_bridge_settle_refused_fetch($pending, $outcome // 'parent_navigation_failed', $why);
    }
    fail_queued_crawl_preflight($S{pending_download},
        'crawl_parent_navigation_failed', $why)
        if defined &fail_queued_crawl_preflight;
}

sub nav_send_next {
    return unless $S{nav_active};
    my $steps = $S{nav_steps} || [];
    if (!@$steps) {
        my $after = delete $S{nav_after};
        $S{nav_active} = 0;
        $S{nav_expected} = undef;
        $after->() if $after;
        return;
    }

    my $step = shift @$steps;
    $S{nav_expected} = [ @{$step->{expected}} ];
    $S{nav_seq} = ($S{nav_seq} || 0) + 1;
    my $seq = $S{nav_seq};
    my $generation = $S{generation};
    my $chat_key = $S{chat_identity_key};
    log_line('NAV_EXPECT', FServeParser::join_path(@{$S{nav_expected}}));
    $S{nav_send_pending} = 1;
    my $scheduled = send_chat_now($step->{cmd},
        guard => sub { $S{nav_active} && ($S{nav_seq} || 0) == $seq },
        before_send => sub {
            return 0 unless $S{nav_active} && ($S{nav_seq} || 0) == $seq;
            $S{nav_send_pending} = 0;
            return 1;
        },
        on_done => sub {
            my ($status, $reason) = @_;
            return unless chat_session_is_current($generation, $chat_key) &&
                $S{nav_active} && ($S{nav_seq} || 0) == $seq;
            unless ($status eq 'sent') {
                nav_fail('navigation command did not dispatch: ' . safe_field($reason // $status));
                return;
            }
            my $ms = Irssi::settings_get_int('fscrawl_navigation_timeout_ms') || 5000;
            $S{nav_timer} = schedule_session_timer($ms, sub {
                my $want = FServeParser::join_path(@{$S{nav_expected} || []});
                nav_fail("timeout waiting for directory prompt $want after [$step->{cmd}]");
            }, sub {
                chat_session_is_current($generation, $chat_key) &&
                    $S{nav_active} && ($S{nav_seq} || 0) == $seq
            });
            nav_fail('could not arm navigation acknowledgement deadline')
                unless defined $S{nav_timer};
        });
    unless ($scheduled) {
        $S{nav_send_pending} = 0;
        nav_fail('could not reserve the DCC CHAT navigation message rate budget');
    }
}

sub navigate_to {
    my ($target, $after) = @_;
    return nav_fail('attempted navigation while another navigation is active') if $S{nav_active};

    my @from = @{$S{current_path} || []};
    my @to   = @$target;
    my $common = common_prefix_len(\@from, \@to);
    my @steps;
    my @cursor = @from;

    for (my $i = $#from; $i >= $common; $i--) {
        pop @cursor;
        push @steps, { cmd => 'cd..', expected => [@cursor] };
    }
    for my $i ($common .. $#to) {
        push @cursor, $to[$i];
        push @steps, { cmd => 'cd ' . $to[$i], expected => [@cursor] };
    }

    if (!@steps) {
        $after->() if $after;
        return;
    }

    $S{nav_active} = 1;
    $S{nav_steps} = \@steps;
    $S{nav_after} = $after;
    $S{phase} = 'navigating';
    nav_send_next();
}

sub begin_listing {
    my ($path) = @_;
    $S{folders_listed} = ($S{folders_listed} || 0) + 1;
    $S{listing_active} = 1;
    $S{listing_header_seen} = 0;
    $S{listing_path} = [@$path];
    $S{listing_dirs} = [];
    $S{listing_files} = [];
    $S{phase} = 'listing';
    $S{listing_send_pending} = 1;
    log_line('LIST_EXPECT', FServeParser::join_path(@$path));
    my $generation = $S{generation};
    my $scheduled = send_chat_now('dir',
        guard => sub { $S{listing_active} && ($S{generation} || 0) == $generation },
        before_send => sub {
            return 0 unless $S{listing_active} && ($S{generation} || 0) == $generation;
            $S{listing_send_pending} = 0;
            return 1;
        },
        on_done => sub {
            my ($status, $reason) = @_;
            return unless $S{active} && ($S{generation} || 0) == $generation;
            return if $status eq 'sent';
            $S{listing_active} = 0;
            $S{listing_send_pending} = 0;
            $S{phase} = 'error';
            p('Could not safely send the DCC CHAT directory request: ' . safe_field($reason // $status));
        });
    unless ($scheduled) {
        $S{listing_active} = 0;
        $S{listing_send_pending} = 0;
        $S{phase} = 'error';
        p('Could not reserve the DCC CHAT directory request in the outbound scheduler.');
    }
}

sub begin_download_verify {
    my ($f) = @_;
    my @parts = grep { length } split m{/+}, ($f->{parent} // '/');
    $S{verify_get_active} = 1;
    $S{verify_get_header_seen} = 0;
    $S{verify_get_found} = 0;
    $S{verify_get_send_pending} = 1;
    $S{verify_get_path} = \@parts;
    $S{verify_get_files} = [];
    $S{phase} = 'verify_get';
    log_line('VERIFY_GET_EXPECT', $f->{path});
    my $generation = $S{generation};
    my $scheduled = send_chat_now('dir',
        guard => sub { $S{verify_get_active} && ($S{generation} || 0) == $generation },
        before_send => sub {
            return 0 unless $S{verify_get_active} && ($S{generation} || 0) == $generation;
            $S{verify_get_send_pending} = 0;
            return 1;
        },
        on_done => sub {
            my ($status, $reason) = @_;
            return unless $S{active} && ($S{generation} || 0) == $generation;
            return if $status eq 'sent';
            $S{verify_get_active} = 0;
            $S{verify_get_send_pending} = 0;
            $S{phase} = 'error';
            p('Could not safely send the verified-parent DCC CHAT listing: ' . safe_field($reason // $status));
            fail_queued_crawl_preflight($S{pending_download},
                'crawl_parent_listing_dispatch_failed', $reason // $status);
        });
    unless ($scheduled) {
        $S{verify_get_active} = 0;
        $S{verify_get_send_pending} = 0;
        $S{phase} = 'error';
        p('Could not reserve the verified-parent DCC CHAT listing in the outbound scheduler.');
        fail_queued_crawl_preflight($S{pending_download},
            'crawl_parent_listing_not_scheduled', 'verified-parent listing could not be scheduled');
    }
}

sub begin_direct_fetch_navigation {
    my $f = $S{pending_download};
    unless ($f && defined($f->{parent})) {
        nav_fail('direct fetch has no verified target path');
        return;
    }
    my @parts = grep { length } split m{/+}, $f->{parent};
    navigate_to(\@parts, sub { begin_download_verify($f) });
}

sub settle_queued_preflight_refusal {
    my ($file, $outcome, $reason) = @_;
    my $job_id = $file->{phase6_job_id};
    my $run = $JOBS{run_batch};
    return unless defined($job_id) && $run &&
        ($run->{current_job_id} // '') eq $job_id;
    $run->{waiting_crawl} = undef
        if ($run->{waiting_crawl} // '') eq $job_id;

    my $job = $JOBS{coordinator}->job($job_id);
    my $recorded = $job && ($job->{state} eq 'held' || $job->{state} eq 'preparing')
        ? job_transition($job_id, 'stale',
            outcome => $outcome, reason => $reason)
        : 0;
    unless ($recorded || !$job || FServe::Transfer::Job::is_terminal($job->{state})) {
        $run->{current_job_id} = undef;
        $run->{waiting_manifest} = undef;
        $run->{dispatching} = 0;
        $run->{paused_for_attention} = 1;
        $JOBS{paused} = 1;
        p("The job batch paused because the preflight refusal for $job_id could not be recorded.");
    }
}

sub fail_queued_crawl_preflight {
    my ($file, $outcome, $reason) = @_;
    return 0 unless $file && defined($file->{phase6_job_id});
    my $job_id = $file->{phase6_job_id};
    my $run = $JOBS{run_batch};
    return 0 unless $run && ($run->{current_job_id} // '') eq $job_id &&
        ($run->{waiting_crawl} // '') eq $job_id;
    $run->{waiting_crawl} = undef;
    if ($S{pending_download} &&
            ($S{pending_download}{phase6_job_id} // '') eq $job_id) {
        delete $S{pending_download};
        restore_download_path_to_base();
    }
    settle_queued_preflight_refusal($file, $outcome, $reason);
    return 1;
}

sub finish_download_verify {
    return unless $S{verify_get_active};
    my $f = $S{pending_download};
    $S{verify_get_active} = 0;
    $S{verified_parent_files} = $S{verify_get_files} || [];
    $S{verified_parent_path} = FServeParser::join_path(@{$S{verify_get_path} || []});
    if (!$f) {
        nav_fail('download verification completed with no pending download');
        return;
    }
    unless ($S{verify_get_found}) {
        my $msg = "target file was not present after verified navigation: $f->{path}";
        finish_pre_dispatch_recovery_for_job(
            $f->{phase6_job_id}, 'fresh live-parent listing did not contain the selected file',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_parent_missing');
        p("Refusing GET: $msg");
        log_line('GET_VERIFY_FAILED', $msg);
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        restore_download_path_to_base();
        $S{phase} = 'complete';
        settle_queued_preflight_refusal($f, 'live_parent_file_missing',
            'selected file was absent from the fresh live-parent listing');
        web_bridge_settle_refused_fetch($f, 'live_parent_file_missing',
            'selected file was absent from the fresh live-parent listing');
        return;
    }
    if (my $conflict = legacy_dcc_alias_conflict($f)) {
        my $legacy = $f->{name} // '';
        $legacy =~ s/ /_/g;
        finish_pre_dispatch_recovery_for_job(
            $f->{phase6_job_id}, 'fresh live-parent listing contained an ambiguous DCC filename alias',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_alias_conflict');
        p("Refusing GET after verified parent listing: [$f->{name}] would be offered as [$legacy], which is also a distinct file in that directory.");
        log_line('DOWNLOAD_PREFLIGHT_REFUSED', "reason=verified-parent-alias-collision requested=[$f->{path}] conflict=[" . ($conflict->{path} // $conflict->{name} // '') . "]");
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        restore_download_path_to_base();
        $S{phase} = 'complete';
        settle_queued_preflight_refusal($f,
            'live_parent_alias_collision',
            'fresh live-parent listing contains a distinct file matching the requested legacy DCC filename alias');
        web_bridge_settle_refused_fetch($f, 'live_parent_alias_collision',
            'fresh live-parent listing contains a distinct file matching the requested legacy DCC filename alias');
        return;
    }
    if (defined($f->{fetch_lease})) {
        verify_manifest_snapshot_before_get($f);
        return;
    }
    send_verified_get($f);
}

sub send_verified_get {
    my ($f) = @_;
    return unless $f && $S{pending_download} &&
        ($S{pending_download}{request_token} || 0) == ($f->{request_token} || 0);
    my $queued_job_id = $f->{phase6_job_id};
    my $recovery = $JOBS{pre_dispatch_recovery};
    my $recovery_deadline = $recovery && defined($queued_job_id) &&
        ($recovery->{job_id} // '') eq $queued_job_id
            ? $recovery->{deadline_monotonic} : undef;
    if (defined($recovery_deadline) &&
            !recovery_deadline_allows_dispatch(
                $queued_job_id, $recovery_deadline)) {
        stop_session(1);
        return;
    }
    if (queue_job_is_paused($queued_job_id)) {
        pause_active_queued_get($queued_job_id);
        return;
    }
    unless (prepare_download_staging($f)) {
        finish_pre_dispatch_recovery_for_job(
            $f->{phase6_job_id}, 'fresh staging could not be prepared after live-parent verification',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_staging_failed');
        fail_queued_crawl_preflight($f,
            'crawl_staging_preparation_failed', 'fresh staging could not be prepared after live-parent verification');
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        $S{phase} = 'error';
        web_bridge_settle_refused_fetch($f, 'staging_preparation_failed',
            'fresh staging could not be prepared after live-parent verification');
        return;
    }
    my $job_id = fserve_job($f, $S{server}, $f->{phase6_job_id}, $S{nick});
    unless ($job_id && jobs_ready()) {
        finish_pre_dispatch_recovery_for_job(
            $f->{phase6_job_id}, 'durable job context was unavailable after live-parent verification',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_job_unavailable');
        fail_queued_crawl_preflight($f,
            'crawl_job_context_unavailable', 'durable queued job context was unavailable after live-parent verification');
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        $S{phase} = 'error';
        restore_download_path_to_base();
        web_bridge_settle_refused_fetch($f, 'job_context_unavailable',
            'durable job context was unavailable after live-parent verification');
        return;
    }
    my $job = $JOBS{coordinator}->job($job_id);
    my $current_offer_ms = bounded_timeout_setting(
        'fscrawl_offer_timeout_ms', 120000, 1000, 300000);
    my $offer_ms = effective_job_limit($job, 'offer_timeout_ms', $current_offer_ms);
    unless ($offer_ms) {
        finish_pre_dispatch_recovery_for_job(
            $job_id, 'captured offer timeout was missing or invalid',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_offer_timeout_invalid');
        retire_job($job_id, 'preflight_failed',
            'job has no validated offer timeout captured before dispatch');
        p('Refusing GET because its captured offer timeout is missing or invalid.');
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        $S{phase} = 'error';
        restore_download_path_to_base();
        web_bridge_settle_refused_fetch($f, 'preflight_failed',
            'job has no validated offer timeout captured before dispatch');
        return;
    }
    my $intent = eval {
        $JOBS{coordinator}->begin_dispatch($job_id,
            casemapping => job_casemapping($job, $S{server}),
            effective_limits => { offer_timeout_ms => $offer_ms });
    };
    unless ($intent) {
        my $error = $@ || 'durable dispatch intent could not be created';
        $error =~ s/[\r\n]+/ /g;
        finish_pre_dispatch_recovery_for_job(
            $job_id, 'durable content dispatch intent could not be created',
            needs_attention => 1, release_lease => 1,
            outcome => 'pre_dispatch_recovery_dispatch_intent_failed');
        p("Refusing GET because its DCC identity or durable intent is unavailable: $error");
        my $job = $JOBS{coordinator}->job($job_id);
        job_transition($job_id, 'stale', reason => 'dispatch tuple or selection preflight refused')
            if $job && $job->{state} eq 'held';
        delete $S{pending_download};
        release_pending_manifest_lease($f);
        $S{phase} = 'error';
        restore_download_path_to_base();
        web_bridge_settle_refused_fetch($f, 'dispatch_preflight_refused',
            'dispatch tuple or selection preflight refused');
        return;
    }
    finish_pre_dispatch_recovery_for_job(
        $job_id, 'durable GET dispatch intent was recorded',
        outcome => 'content_dispatch_started');
    $f->{phase6_job_id} = $job_id;
    $JOBS{active_job_id} = $job_id;
    delete $JOBS{run_batch}{waiting_manifest}
        if $JOBS{run_batch} &&
            ($JOBS{run_batch}{current_job_id} // '') eq $job_id;
    delete $JOBS{run_batch}{waiting_crawl}
        if $JOBS{run_batch} &&
            ($JOBS{run_batch}{current_job_id} // '') eq $job_id;
    my $generation = $S{generation};
    my $chat_key = $S{chat_identity_key};
    my $request_token = $f->{request_token};
    $S{phase} = 'get_dispatch_pending';
    $f->{request_sent} = 0;
    my $verified_now = sub {
        return 0 unless $S{active} && $S{chat_connected} &&
            ($S{generation} || 0) == ($generation || 0) &&
            ($S{chat_identity_key} // '') eq ($chat_key // '') &&
            $S{pending_download} &&
            ($S{pending_download}{request_token} || 0) == ($request_token || 0);
        return 0 if queue_job_is_paused($job_id);
        my $wanted_parent = lc($f->{parent} // '');
        return 0 unless lc($S{verified_parent_path} // '') eq $wanted_parent;
        return scalar grep {
            ($_->{type} // '') eq 'file' &&
                lc($_->{parent} // '') eq $wanted_parent &&
                lc($_->{name} // '') eq lc($f->{name} // '')
        } @{$S{verified_parent_files} || []};
    };
    my $recovery_deadline_ok = sub {
        recovery_deadline_allows_dispatch(
            $job_id, $recovery_deadline);
    };
    my $scheduled = send_chat_now('get ' . $f->{name},
        job_id => $job_id,
        guard => sub { $recovery_deadline_ok->() && $verified_now->() },
        before_send => sub {
            return 0 unless $recovery_deadline_ok->() &&
                $verified_now->() &&
                !queue_job_is_paused($job_id);
            $f->{request_sent} = 1;
            $S{phase} = 'requesting_file';
            return 1;
        },
        on_done => sub {
            my ($status, $reason) = @_;
            my $dispatch_result = $status eq 'sent' ? 'sent'
                : $status eq 'paused_before_send' ? 'cancelled_before_transport'
                : 'unknown';
            my $recorded = eval {
                $JOBS{coordinator}->record_dispatch_result($job_id,
                    $dispatch_result,
                    outcome => $status eq 'sent' ? 'content_request_sent'
                        : $status eq 'paused_before_send' ? 'content_request_paused_before_send'
                        : 'dispatch_outcome_unknown',
                    reason => $status eq 'sent' ? undef : safe_field($reason // $status));
                1;
            };
            my $current = $JOBS{coordinator}->job($job_id);
            if ($status eq 'paused_before_send') {
                if ($S{active} && ($S{generation} || 0) == ($generation || 0) &&
                        $S{pending_download} &&
                        ($S{pending_download}{request_token} || 0) == ($request_token || 0)) {
                    $S{phase} = 'get_cancelled_before_get';
                    my $saved = $recorded && $current && $current->{state} eq 'held'
                        ? pause_active_queued_get($job_id) : 0;
                    unless ($saved) {
                        $S{pending_download} = undef;
                        restore_download_path_to_base();
                    }
                }
                release_pending_manifest_lease($f) unless paused_get_context_for($job_id);
                p('Queue pause withdrew the unsent GET; the durable job remains held for a later explicit run.')
                    if $recorded && $current && $current->{state} eq 'held' &&
                        paused_get_context_for($job_id);
                p('The unsent GET was withdrawn, but its durable state could not be restored safely.')
                    unless $recorded;
                return;
            }
            if ($status eq 'sent') {
                if ($current && $current->{state} eq 'awaiting_offer') {
                    unless (arm_wait_timer($job_id, $offer_ms, 'offer')) {
                        job_transition($job_id, 'needs_attention',
                            outcome => 'offer_deadline_unavailable',
                            reason => 'content request was sent but a bounded offer timer could not be armed');
                        p('GET was sent, but its offer timer could not be armed; no automatic retry will occur.');
                    }
                }
                if ($S{active} && ($S{generation} || 0) == ($generation || 0) &&
                        $S{pending_download} &&
                        ($S{pending_download}{request_token} || 0) == ($request_token || 0)) {
                    log_line('STATE', 'requested file ' . $f->{path});
                }
            } else {
                if ($S{active} && ($S{generation} || 0) == ($generation || 0) &&
                        $S{pending_download} &&
                        ($S{pending_download}{request_token} || 0) == ($request_token || 0)) {
                    $S{phase} = 'error';
                    $S{pending_download} = undef;
                    restore_download_path_to_base();
                }
                p('GET dispatch did not complete safely; it will not be repeated automatically: ' .
                    safe_field($reason // $status));
            }
            release_pending_manifest_lease($f);
            p('GET dispatch result could not be recorded durably; this job requires inspection.')
                unless $recorded;
        });
    unless ($scheduled) {
        eval { $JOBS{coordinator}->record_dispatch_result($job_id, 'unknown',
            outcome => 'content_scheduler_unavailable'); };
        $S{phase} = 'error';
        $S{pending_download} = undef;
        release_pending_manifest_lease($f);
        restore_download_path_to_base();
        p('GET intent is durable, but no outbound scheduler reservation was available; no GET was sent.');
    }
}

sub finish_crawl {
    $S{phase} = 'complete';
    write_catalog();
    my $files = FServe::Catalog::count_type($S{catalog}, 'file');
    my $dirs  = FServe::Catalog::count_type($S{catalog}, 'dir');
    p("Crawl complete: $dirs directories, $files files.");
    p("Catalog: $S{catalog_tsv}");
    p("Use /fscrawl list [text] and /fscrawl get <index> while the DCC chat remains open.");
    log_line('STATE', "crawl complete dirs=$dirs files=$files");
}

# A crawl lists the root first; a browse from a folder (2026-10-21) goes
# there first and lists it, and reads as deep below it as below the root.
sub crawl_begin {
    my $from = $S{crawl_from} || [];
    return begin_listing([]) unless @$from;
    $S{visited}{path_key($from)} = 1;
    navigate_to($from, sub { begin_listing($from) });
}

sub crawl_next {
    if ($S{folder_limit} && ($S{folders_listed} || 0) >= $S{folder_limit} && @{$S{queue}}) {
        $S{browse_truncated} = 1;
        @{$S{queue}} = ();
    }
    while (@{$S{queue}}) {
        my $next = shift @{$S{queue}};
        my $k = path_key($next);
        next if $S{visited}{$k}++;
        navigate_to($next, sub { begin_listing($next) });
        return;
    }
    finish_crawl();
}

sub finish_listing {
    return unless $S{listing_active};
    my @path = @{$S{listing_path}};
    my $depth = scalar @path;
    my $max_depth = $S{max_depth};

    for my $d (@{$S{listing_dirs}}) {
        next if !defined($d->{name}) || $d->{name} eq '..';
        my @child = (@path, $d->{name});
        push @{$S{catalog}}, {
            type => 'dir',
            path => FServeParser::join_path(@child),
            name => $d->{name},
        };
        push @{$S{queue}}, \@child if $depth < $max_depth;
    }

    my @catalog_observations;
    my $source_timestamp = now_iso();
    for my $f (@{$S{listing_files}}) {
        my @full = (@path, $f->{name});
        my $remote_path = FServeParser::join_path(@full);
        push @{$S{catalog}}, {
            type       => 'file',
            path       => $remote_path,
            name       => $f->{name},
            parent     => FServeParser::join_path(@path),
            size_raw   => $f->{size_raw},
            size_bytes => $f->{size_bytes},
        };
        push @catalog_observations, {
            type               => 'file',
            network_id         => $S{network_id},
            server_tag         => $S{server_tag},
            server_nick        => $S{nick},
            trigger_raw        => $S{catalog_trigger_raw},
            trigger_mode       => $S{catalog_trigger_mode},
            discovery_channel  => $S{catalog_trigger_channel},
            remote_path        => $remote_path,
            size_raw           => $f->{size_raw},
            size_bytes         => $f->{size_bytes},
            source             => 'crawl',
            source_timestamp   => $source_timestamp,
        };
    }
    record_catalog_observations(\@catalog_observations);

    $S{listing_active} = 0;
    log_line('STATE', 'finished listing ' . FServeParser::join_path(@path));
    crawl_next();
}

sub handle_chat_line {
    my ($line) = @_;
    log_line('IN', $line);
    $S{chat_line_kind} = undef;
    return if handle_queue_status($line);
    return if consume_paused_chat_response($line);
    my $ev = FServeParser::parse_line($line);
    $S{chat_line_kind} = $ev->{type};   # for chat_backlog_after_line

    if ($ev->{type} eq 'more_prompt') {
        # Mirroring XDCC Browser 4.52: stop the welcome/disclaimer pagination,
        # then ask for a machine-friendly one-entry-per-line DIR listing.
        send_sequence(['S'], sub { begin_listing($S{current_path} || []) });
        return;
    }

    if ($ev->{type} eq 'prompt') {
        my ($actual, $is_listing_header) = prompt_path_info($ev->{path});
        log_line('PROMPT', ($is_listing_header ? 'listing ' : 'dir ') . FServeParser::join_path(@$actual));

        # A non-wildcard path prompt is SysReset's acknowledgement of CD/CD...
        if ($S{nav_active} && !$S{nav_send_pending} && !$is_listing_header) {
            my $want = $S{nav_expected} || [];
            if (path_eq($actual, $want)) {
                cancel_session_timer($S{nav_timer});
                $S{nav_timer} = undef;
                $S{current_path} = [@$actual];
                $S{nav_seq} = ($S{nav_seq} || 0) + 1; # invalidate timeout
                log_line('NAV_ACK', FServeParser::join_path(@$actual));
                nav_send_next();
            } else {
                log_line('NAV_STALE_PROMPT', 'got=' . FServeParser::join_path(@$actual) . ' want=' . FServeParser::join_path(@$want));
            }
            return;
        }

        if ($S{phase} eq 'await_prompt' && !$is_listing_header) {
            cancel_session_timer($S{initial_prompt_timer});
            $S{initial_prompt_timer} = undef;
            $S{initial_prompt_token} = ($S{initial_prompt_token} || 0) + 1;
            $S{saw_initial_prompt} = 1;
            $S{current_path} = [@$actual];
            if (@$actual) {
                nav_fail('initial FServe prompt was not root: ' . FServeParser::join_path(@$actual));
            } elsif ($S{direct_fetch}) {
                begin_direct_fetch_navigation();
            } else {
                crawl_begin();
            }
            return;
        }

        # DIR emits a wildcard path header. Do not trust any following file
        # lines or End-of-list until the header matches the directory we asked
        # to list. This prevents stale/slow output from being attributed to a
        # later directory.
        if ($is_listing_header && $S{listing_active} && !$S{listing_send_pending}) {
            if (path_eq($actual, $S{listing_path} || [])) {
                $S{listing_header_seen} = 1;
                $S{listing_dirs} = [];
                $S{listing_files} = [];
                $S{current_path} = [@$actual];
                log_line('LIST_ACK', FServeParser::join_path(@$actual));
            } else {
                $S{listing_header_seen} = 0;
                log_line('LIST_STALE_HEADER', 'got=' . FServeParser::join_path(@$actual) . ' want=' . FServeParser::join_path(@{$S{listing_path} || []}));
            }
            return;
        }

        if ($is_listing_header && $S{verify_get_active} && !$S{verify_get_send_pending}) {
            if (path_eq($actual, $S{verify_get_path} || [])) {
                $S{verify_get_header_seen} = 1;
                $S{verify_get_found} = 0;
                $S{current_path} = [@$actual];
                log_line('VERIFY_GET_ACK', FServeParser::join_path(@$actual));
            } else {
                $S{verify_get_header_seen} = 0;
                log_line('VERIFY_GET_STALE_HEADER', 'got=' . FServeParser::join_path(@$actual) . ' want=' . FServeParser::join_path(@{$S{verify_get_path} || []}));
            }
            return;
        }

        return;
    }

    if ($S{verify_get_active}) {
        return if $S{verify_get_send_pending};
        return unless $S{verify_get_header_seen};
        if ($ev->{type} eq 'file') {
            my $parent = FServeParser::join_path(@{$S{verify_get_path} || []});
            push @{$S{verify_get_files}}, {
                type   => 'file',
                name   => $ev->{name},
                parent => $parent,
                path   => FServeParser::join_path(@{$S{verify_get_path} || []}, $ev->{name}),
            };
            if ($S{pending_download} && lc($ev->{name} // '') eq lc($S{pending_download}{name} // '')) {
                $S{verify_get_found} = 1;
            }
        } elsif ($ev->{type} eq 'end') {
            finish_download_verify();
        }
        return;
    }

    return unless $S{listing_active} && !$S{listing_send_pending};
    return unless $S{listing_header_seen};

    if ($ev->{type} eq 'dir') {
        push @{$S{listing_dirs}}, $ev;
    } elsif ($ev->{type} eq 'file') {
        push @{$S{listing_files}}, $ev;
    } elsif ($ev->{type} eq 'end') {
        finish_listing();
    }
}

sub initial_prompt_fallback {
    my ($generation, $token, $chat_key) = @_;
    return unless chat_session_is_current($generation, $chat_key);
    return unless ($S{initial_prompt_token} || 0) == $token;
    $S{initial_prompt_timer} = undef;
    return unless $S{active} && $S{chat_connected};
    return unless $S{phase} eq 'await_prompt';
    return if $S{saw_initial_prompt};
    if ($S{direct_fetch} || @{$S{crawl_from} || []}) {
        nav_fail('root prompt was not observed; refusing to guess the current directory for a ' .
            ($S{direct_fetch} ? 'direct fetch' : 'browse from a folder'));
        return;
    }
    p('No root prompt seen before timeout; probing with DIR.');
    log_line('STATE', 'root prompt timeout; sending dir');
    begin_listing([]);
}

# What an FServe types is text. Anything else means this CHAT is not an FServe
# session, and reading on can stall the engine: the lab's file server once
# sent a whole file down it. Formatting codes and tabs are allowed.
sub chat_line_is_text {
    my ($line) = @_;
    return 0 unless defined $line;
    return 0 if length($line) > 2048;
    return $line =~ /[\x00\x01\x05-\x08\x0a-\x0e\x10\x12-\x15\x17-\x1c\x7f]/ ? 0 : 1;
}

# Every socket this process holds: descriptor => the kernel's number for it.
sub process_sockets {
    my %number;
    opendir(my $dir, '/proc/self/fd') or return \%number;
    for my $fd (grep { /\A\d+\z/ } readdir $dir) {
        my $link = readlink("/proc/self/fd/$fd") // next;
        $number{$fd} = $1 if $link =~ /\Asocket:\[(\d+)\]\z/;
    }
    closedir $dir;
    return \%number;
}

# The descriptor of a CHAT's own socket, or nothing unless it is certain.
# Irssi does not show a script its descriptors. The socket that appeared
# while this CHAT was being connected is its own, and is used whenever it
# was seen, as long as it leads to the CHAT's address and port or, once the
# other side has reset it, nowhere at all. A file server that uses one port
# for every DCC can have a file transfer open to the same place, and after
# a reset that transfer would be the only socket still leading there. Only
# when that socket was not seen is the CHAT's found by where it leads, if
# that leaves exactly one socket and no file is being received.
sub chat_socket_descriptor {
    my ($dcc) = @_;
    my ($address, $port) = ($dcc->{addr} // '', $dcc->{port} // 0);
    return unless length($address) && $port =~ /\A[1-9]\d{0,4}\z/;
    my $family = index($address, ':') >= 0 ? AF_INET6 : AF_INET;
    my $wanted = eval { inet_pton($family, $address) } // return;
    my $number = process_sockets();
    my $seen = $S{chat_socket};
    my (@found, @seen);
    for my $fd (keys %$number) {
        # A duplicate is asked, so that closing it leaves Irssi's own open.
        open(my $copy, '<&', $fd) or next;
        my $peer = getpeername($copy);
        close $copy;
        my ($peer_port, $peer_address) = defined($peer) ? eval {
            return unless sockaddr_family($peer) == $family;
            $family == AF_INET6 ? (unpack_sockaddr_in6($peer))[0, 1]
                : unpack_sockaddr_in($peer);
        } : ();
        my $leads_there = defined($peer_port) && $peer_port == $port &&
            $peer_address eq $wanted;
        push @found, $fd if $leads_there;
        push @seen, $fd if defined($seen) && $number->{$fd} eq $seen &&
            ($leads_there || !defined $peer);
    }
    return (@seen == 1 ? $seen[0] : undef) if defined $seen;
    return if @found != 1 || session_transfer_count();
    return $found[0];
}

# End Irssi's reading of a CHAT that is being abandoned. Irssi reads a CHAT
# for as long as data is waiting, one line at a time, and a script cannot
# close the CHAT from inside the handler for a line. Against a sender faster
# than Irssi works through the lines, the timer below therefore waited its
# turn for minutes, and the whole engine with it. So the CHAT's socket is
# shut down here and its descriptor pointed at /dev/null: Irssi's next read
# finds the end of the stream and Irssi closes the CHAT itself, exactly as
# when the other side hangs up. Nothing is done unless the socket is certain.
sub cut_chat_socket {
    my ($dcc) = @_;
    my $fd = chat_socket_descriptor($dcc) // return 0;
    open(my $copy, '+<&', $fd) or return 0;
    my $cut = shutdown($copy, 2) ? 1 : 0;
    close $copy;
    # Without this Irssi would first read all the kernel already holds.
    my $null = POSIX::open('/dev/null', O_RDWR);
    if (defined $null) {
        $cut = 1 if defined POSIX::dup2($null, $fd);
        POSIX::close($null);
    }
    return $cut;
}

# Irssi 1.4.5 reads a CHAT up to 2,048 bytes at a time but hands out one
# line per read, and goes on until it holds no whole line (dcc_chat_input,
# line_split). Text that comes faster than its lines are handled piles up in
# Irssi's own buffer, where the kernel no longer counts it, and Irssi works
# through all of it before the engine can do anything else; the cost grows
# with the number of lines and with the size of the pile. So after each line
# the adapter peeks at what the kernel holds for the session, which is what
# Irssi reads next, and keeps count of the bytes and lines Irssi holds but
# has not handed out. The count can fall short, which only makes a limit act
# later. A session past a limit is given up like one that sends data that is
# not text, and its socket is cut while what Irssi holds is still small. A
# folder listing the engine asked for may hold more for as long as its lines
# read as entries: a large folder is then read, at the cost of a longer
# pause, rather than missed.
our %CHAT_BACKLOG_LIMITS = (
    session => { bytes => 1024 * 1024, lines => 20_000, busy_seconds => 3 },
    listing => { bytes => 8 * 1024 * 1024, lines => 100_000, busy_seconds => 15 },
);
# A listing is taken as one after this many entries, with no more than one
# other line in 20 among them.
our $CHAT_LISTING_ENTRIES = 32;
# No more than this of the engine's own time over one line counts as busy.
# A flood's lines take well under a millisecond each; a line that takes
# longer is the engine's own doing, such as journal work, and must not give
# an honest session up.
our $CHAT_LINE_BUSY_SECONDS = 0.5;

# Idle time is time on the clock. Busy time is the engine's own work: the CPU
# time of Irssi's process, which the engine runs in. On a host busy with
# other work the engine is slowed by what is not the file server's doing,
# and counted on the clock a large listing on such a host was given up as
# keeping the engine busy (2026-11-03). Where the CPU time cannot be read,
# the clock counts for both.
sub chat_clock { return monotonic_now() }

sub chat_work_clock {
    require Time::HiRes;
    my $cpu = eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_PROCESS_CPUTIME_ID()) };
    return defined($cpu) ? $cpu : chat_clock();
}

# The front of what the kernel holds for a socket, left where it is.
sub chat_socket_front {
    my ($fd) = @_;
    open(my $copy, '<&', $fd) or return '';
    my $front = '';
    $front = '' unless defined recv($copy, $front, 2048, MSG_PEEK | MSG_DONTWAIT);
    close $copy;
    return $front;
}

sub chat_listing_open {
    return ($S{listing_active} && $S{listing_header_seen} && !$S{listing_send_pending}) ||
        ($S{verify_get_active} && $S{verify_get_header_seen} && !$S{verify_get_send_pending})
        ? 1 : 0;
}

# Irssi has handed out a line. If it was already in Irssi's buffer when the
# last line was handled, the engine has not run in between, and the work done
# since counts as busy; otherwise the time since counts against it.
sub chat_backlog_before_line {
    my ($dcc, $line) = @_;
    # Found once for each CHAT. Without it nothing is counted, as nothing is cut.
    my $fd = $S{chat_backlog_fd} //= chat_socket_descriptor($dcc) // -1;
    return if $fd < 0;
    my ($now, $work) = (chat_clock(), chat_work_clock());
    my $since = defined($S{chat_left_at}) ? $now - $S{chat_left_at} : 0;
    if (($S{chat_held_lines} // 0) > 0) {
        $S{chat_held_lines}--;
        $S{chat_held_bytes} -= bytes::length($line) + 2;
        $S{chat_held_bytes} = 0 if $S{chat_held_bytes} < 0;
        $S{chat_busy} += defined($S{chat_left_work}) ? $work - $S{chat_left_work} : 0;
    } else {
        $S{chat_held_lines} = $S{chat_held_bytes} = 0;
        $S{chat_busy} = ($S{chat_busy} // 0) - $since;
        $S{chat_busy} = 0 if $S{chat_busy} < 0;
    }
    $S{chat_entered_at} = $now;
    $S{chat_entered_work} = $work;
}

# Why the session must be given up for what it has piled up, or nothing.
sub chat_backlog_exceeded {
    return if ($S{chat_backlog_fd} // -1) < 0;
    my $entries = $S{chat_listing_entries} // 0;
    my $listing = $entries >= $CHAT_LISTING_ENTRIES &&
        ($S{chat_listing_others} // 0) * 20 <= $entries && chat_listing_open();
    my $limit = $CHAT_BACKLOG_LIMITS{$listing ? 'listing' : 'session'};
    my $over = $S{chat_held_bytes} > $limit->{bytes} || $S{chat_held_lines} > $limit->{lines}
        ? 'size' : $S{chat_busy} > $limit->{busy_seconds} ? 'time' : return;
    log_line('CHAT_BACKLOG', sprintf(
        '%s limit%s passed: %d bytes and %d lines waiting in Irssi; engine busy %.1f s more than idle',
        $over, $listing ? ' for a listing' : '', $S{chat_held_bytes}, $S{chat_held_lines},
        $S{chat_busy}));
    (my $files = $limit->{lines}) =~ s/(?<=\d)(?=(?:\d{3})+\z)/,/g;
    return $listing
        ? $over eq 'size'
            ? "the folder listing was too large to read (more than about $files files at once)"
            : "reading the folder listing kept the engine busy for more than $limit->{busy_seconds} seconds"
        : $over eq 'size'
            ? 'the file server sent text over its session far faster than it could be read'
            : "the file server's text kept the engine busy for more than $limit->{busy_seconds} seconds";
}

# Irssi's line has been handled: note whether it was an entry of a listing,
# and what Irssi will read next.
sub chat_backlog_after_line {
    my ($listing_was_open) = @_;
    my $fd = $S{chat_backlog_fd} // -1;
    return if $fd < 0 || !$S{active} || !$S{chat_connected} || $S{chat_not_text} ||
        !defined($S{chat_entered_at});
    my $work = chat_work_clock();
    my $spent = $work - ($S{chat_entered_work} // $work);
    $S{chat_busy} += $spent < $CHAT_LINE_BUSY_SECONDS ? $spent : $CHAT_LINE_BUSY_SECONDS;
    $S{chat_left_at} = chat_clock();
    $S{chat_left_work} = $work;
    if (!$listing_was_open) {
        $S{chat_listing_entries} = $S{chat_listing_others} = 0;
    } elsif (($S{chat_line_kind} // '') =~ /\A(?:file|dir|parent)\z/) {
        $S{chat_listing_entries}++;
    } elsif (!chat_listing_open()) {
        # The listing has ended. The time the engine took to read it is not
        # held against what comes next, such as the reply to the request.
        $S{chat_busy} = 0;
    } else {
        $S{chat_listing_others}++;
    }
    my $front = chat_socket_front($fd);
    $S{chat_held_bytes} += length($front);
    $S{chat_held_lines} += ($front =~ tr/\n//);
}

# Stop a session whose CHAT cannot be trusted, from a timer: this is called
# from inside DCC signal handlers. A transfer already being received is left
# to finish; its bytes do not travel over the CHAT.
sub abandon_untrusted_chat {
    my ($why, $outcome) = @_;
    my $generation = $S{generation};
    nav_fail($why, $outcome) unless session_transfer_count();
    return unless defined $generation;
    my $stop = sub {
        stop_session(1) if session_is_current($generation) && !session_transfer_count();
    };
    $S{stop_due} = $stop;
    $stop->() unless eval { Irssi::timeout_add_once(10, $stop, undef) };
}

# A session ended from inside a CHAT or DCC handler stops from a timer a
# moment later, but its download already shows as ended. A request from the
# web in that moment, such as a disconnect, would find the session still
# open and be refused; the stop is done first instead. Each stop checks for
# itself that its session is still the current one.
sub finish_due_stop {
    my $stop = delete($S{stop_due}) or return;
    $stop->();
}

# A file server that changes its nick while its session is open. The adapter
# knows the session's CHAT by the file server's nick, and Irssi renames a
# CHAT and gives it a new id when its other side changes nick (event_nick in
# src/irc/dcc/dcc-chat.c). The CHAT's lines would then go unread and
# uncounted, so no limit could act on a flood, and closing it by the old
# nick would close nothing. So the session is given up, as one that cannot
# be trusted: its CHAT is cut and closed under the new nick, and a file the
# server offers under that nick is not taken. Nothing is sent to it.
sub sig_event_nick {
    my ($server, $data, $old) = @_;
    return unless $S{active} && ref($server) && defined($old) && defined($data);
    my ($new) = $data =~ /\A:?(\S+)/ or return;
    # Irssi leaves a CHAT alone when only the case of the nick changes.
    return if lc($new) eq lc($old);
    # Irssi renames the CHAT at every change, so the nick it has now is the
    # one followed: a second change before the session has stopped is too.
    return unless defined($S{server_identity}) &&
        server_connection_identity($server) eq $S{server_identity} &&
        server_connection_epoch($server) == ($S{connection_epoch} // -1) &&
        FServe::ConnectionIdentity::same_irc_identity(
            $old, $S{chat_renamed_to} // $S{nick},
            $S{casemapping} // server_casemapping($server));
    $S{chat_renamed_to} = $new;
    my $why = "the file server changed its nick from $old to $new during the session, " .
        'so its session could no longer be told apart';
    log_line('PEER_RENAMED', $why);
    return if $S{chat_not_text};   # already being given up
    $S{chat_not_text} = 1;
    log_line('CHAT_CUT', 'reading of the session was ended at once')
        if $S{chat_connected} && $S{chat_dcc} && cut_chat_socket($S{chat_dcc});
    # A request waiting for its file can no longer be answered: the offer
    # would come from the new nick.
    my $pending = $S{pending_download};
    if ($pending && defined($pending->{phase6_job_id}) &&
            !$pending->{accepted_transfer_key} && jobs_ready()) {
        my $job = $JOBS{coordinator}->job($pending->{phase6_job_id});
        retire_job($pending->{phase6_job_id}, 'file_server_renamed',
            "$why; a file it offers under its new nick will not be taken")
            if $job && $job->{state} =~ /\A(?:awaiting_offer|remote_queued)\z/;
    }
    abandon_untrusted_chat($why . '; the session was closed', 'file_server_renamed');
}

# The session's CHAT after Irssi renamed it for the file server's new nick
# (sig_event_nick): the same record in all else, its server, the time it
# was made, and the address and port it leads to.
sub renamed_chat_matches {
    my ($dcc) = @_;
    my $was = $S{chat_dcc};
    return 0 unless ref($dcc) && ref($was) && uc($dcc->{type} // '') eq 'CHAT';
    return 0 unless FServe::DccPolicy::same_peer($dcc, $S{chat_renamed_to}, $S{server_tag});
    my $server = $dcc->{server};
    return 0 unless $server && defined($S{server_identity}) &&
        server_connection_identity($server) eq $S{server_identity} &&
        server_connection_epoch($server) == ($S{connection_epoch} // -1);
    for my $field (qw(created addr port)) {
        return 0 unless defined($dcc->{$field}) && defined($was->{$field}) &&
            "$dcc->{$field}" eq "$was->{$field}";
    }
    return 1;
}

# A direct fetch waits for the file server to open its session after the
# trigger. A server that is busy, full or restricted answers with a notice
# instead, or with nothing, and the request would otherwise wait for ever
# holding the one download slot. What the server said is kept and shown.
sub arm_session_open_deadline {
    my ($generation) = @_;
    my $ms = bounded_timeout_setting('fscrawl_session_open_ms', 60000, 2000, 600000);
    schedule_session_timer($ms, sub { session_not_opened($generation, 0) },
        sub { session_is_current($generation) && !$S{chat_identity_key} && !$S{chat_connected} });
}

sub session_not_opened {
    my ($generation, $refused) = @_;
    return unless session_is_current($generation) && $S{direct_fetch};
    return if $S{chat_identity_key} || $S{chat_connected} || $S{session_open_failed}++;
    my $said = $S{trigger_notice};
    my $why = $refused ? 'the file server did not open a session'
        : 'the file server did not open a session within ' .
            int(bounded_timeout_setting('fscrawl_session_open_ms', 60000, 2000, 600000) / 1000) .
            ' seconds of being asked';
    $why .= "; it said: $said" if defined($said) && length($said);
    $why .= '. Nothing was asked for, and the trigger was not sent again';
    log_line('SESSION_NOT_OPENED', $why);
    abandon_untrusted_chat($why, 'session_not_opened');
}

sub sig_trigger_notice {
    my ($server, $msg, $nick) = @_;
    return unless $S{active} && $S{direct_fetch} && $S{trigger_dispatched} &&
        !$S{chat_identity_key} && !$S{chat_connected} && ref($server) && ref($S{server});
    return unless server_connection_identity($server) eq ($S{server_identity} // '') &&
        FServe::ConnectionIdentity::same_irc_identity(
            $nick, $S{nick}, $S{casemapping} // server_casemapping($server));
    my $text = $msg // '';
    $text =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $text =~ s/[\x00-\x1f\x7f]//g;
    $text =~ s/\A\s+|\s+\z//g;
    return unless length $text;
    $S{trigger_notice} = substr($text, 0, 200);
    log_line('TRIGGER_NOTICE', $S{trigger_notice});
    # SysReset 2.55 words its refusals of a trigger this way (its script,
    # system/aliases.ini and system/events.ini). Anything else is only kept
    # for the deadline's message.
    return unless $text =~ /\AServer Notice: FileServer is busy\b/ ||
        $text =~ /\ASorry\b.*\b(?:has full queues|is disabled|restricted trigger|is not active in this channel|banned)\b/;
    my $generation = $S{generation};
    eval { Irssi::timeout_add_once(10, sub { session_not_opened($generation, 1) }, undef) }
        if defined $generation;
}

# Under the web bridge nobody reads Irssi's windows, and the transcript keeps
# every line; printing each line of the engine's own session into a query
# window as well cost Irssi more than the engine's handling of it (a 30,000
# line listing ran into the listing's time budget on a slow host).
sub sig_dcc_chat_message {
    my ($dcc) = @_;
    my $ours = $S{active} && $S{chat_connected} && same_chat($dcc);
    handle_dcc_chat_message(@_) if $ours;
    Irssi::signal_stop() if $ours && $WEB_BRIDGE;
}

sub handle_dcc_chat_message {
    my ($dcc, $msg) = @_;
    return if $S{chat_not_text};   # being closed; drop whatever is still buffered
    chat_backlog_before_line($dcc, $msg);
    my $why;
    if (!chat_line_is_text($msg)) {
        $why = 'the file server sent data that is not text over its session';
    } elsif (!$S{saw_initial_prompt} && ++$S{chat_lines_before_prompt} > 500) {
        $why = 'the file server sent more than 500 lines without showing its prompt';
    } else {
        $why = chat_backlog_exceeded();
    }
    if (defined $why) {
        $S{chat_not_text} = 1;
        log_line('CHAT_NOT_FSERVE', $why);
        log_line('CHAT_CUT', 'reading of the session was ended at once')
            if cut_chat_socket($dcc);
        abandon_untrusted_chat($why . '; the session was closed', 'session_not_fserve');
        return;
    }
    my $listing_was_open = chat_listing_open();
    handle_chat_line($msg);
    chat_backlog_after_line($listing_was_open);
}

sub invalidate_session_after_chat_close {
    my ($dcc) = @_;
    my $generation = $S{generation};
    my $pending = $S{pending_download};
    my $keep_queued_offer_wait = 0;
    my $queued_wait_deadline;
    cancel_outbound_owner('session', $generation,
        'owning DCC CHAT closed before delayed message dispatch')
        if defined $generation;
    my $recovery_scheduled = schedule_pre_dispatch_recovery(
        $dcc, $pending);
    if (!$recovery_scheduled && $JOBS{pre_dispatch_recovery} &&
            defined($S{pre_dispatch_recovery_id}) &&
            $JOBS{pre_dispatch_recovery}{id} ==
                $S{pre_dispatch_recovery_id}) {
        finish_pre_dispatch_recovery(
            'CHAT loss was outside the safe pre-dispatch recovery conditions',
            release_lease => 0,
            outcome => 'pre_dispatch_recovery_refused');
    }
    my $paused_get = $S{phase6_paused_get};
    my $closed_preflight_job_id;
    my $closed_preflight_outcome;
    if ($paused_get && defined($paused_get->{job_id}) &&
            ($paused_get->{generation} || 0) == ($generation || 0)) {
        $closed_preflight_job_id = $paused_get->{job_id};
        $closed_preflight_outcome = 'paused_chat_closed';
    } elsif ($pending && defined($pending->{phase6_job_id}) &&
            !$pending->{accepted_transfer_key}) {
        my $run = $JOBS{run_batch};
        my $job_id = $pending->{phase6_job_id};
        my $job = jobs_ready() ? $JOBS{coordinator}->job($job_id) : undef;
        if ($job && $job->{state} eq 'held' && $run &&
                ($run->{current_job_id} // '') eq $job_id) {
            $closed_preflight_job_id = $job_id;
            $closed_preflight_outcome = 'chat_closed_during_preflight';
        }
    }
    if (defined $closed_preflight_job_id) {
        my $job_id = $closed_preflight_job_id;
        my $job = jobs_ready() ? $JOBS{coordinator}->job($job_id) : undef;
        if ($job && $job->{state} eq 'held') {
            my $recorded = job_transition($job_id, 'stale',
                outcome => $closed_preflight_outcome,
                reason => 'the original DCC CHAT closed before fresh parent verification could finish');
            if ($recorded) {
                delete $S{phase6_paused_get}
                    if $S{phase6_paused_get} &&
                        ($S{phase6_paused_get}{job_id} // '') eq $job_id;
                delete $JOBS{active_job_id}
                    if ($JOBS{active_job_id} // '') eq $job_id;
                p("Job $job_id marked stale because its owning CHAT closed before GET.");
            } else {
                # Preserve a non-dispatchable barrier if the journal is
                # unavailable; queue-run must never fall back to a fresh trigger.
                $S{phase6_paused_get} ||= {};
                $S{phase6_paused_get}{job_id} = $job_id;
                $S{phase6_paused_get}{generation} = $generation;
                $S{phase6_paused_get}{drain_response} = 'closed';
                if (my $run = $JOBS{run_batch}) {
                    $run->{paused_for_attention} = 1;
                    $JOBS{paused} = 1;
                }
                p("Job $job_id remains blocked because its closed-CHAT outcome could not be recorded.");
            }
        } elsif ($paused_get &&
                ($paused_get->{job_id} // '') eq $job_id) {
            delete $S{phase6_paused_get};
        }
    }
    if ($pending && defined($pending->{phase6_job_id}) &&
            !$pending->{accepted_transfer_key} && jobs_ready()) {
        my $job_id = $pending->{phase6_job_id};
        my $job = $JOBS{coordinator}->job($job_id);
        if ($job && $job->{state} =~ /\A(?:preparing|dispatch_intent|awaiting_offer|remote_queued)\z/) {
            if ($job->{state} eq 'remote_queued' &&
                    remote_queue_wait_survives_chat_close($job, $S{server})) {
                $keep_queued_offer_wait = 1;
                $queued_wait_deadline = $job->{remote_queue}{absolute_deadline_monotonic};
                p("DCC CHAT closed after a correlated synthetic queue acknowledgement; preserving job ${job_id}'s bounded offer wait on the same IRC connection.");
            } elsif ($recovery_scheduled && $job->{state} eq 'preparing') {
                p("DCC CHAT closed before GET for $job_id; its bounded recovery attempt is scheduled.");
            } else {
                cancel_wait_timer($job_id);
                job_transition($job_id, 'needs_attention',
                    outcome => 'chat_closed_before_offer',
                    reason => 'owning DCC CHAT closed before a file offer was accepted; no retry or remote queue removal was attempted');
                if (my $run = $JOBS{run_batch}) {
                    if (($run->{current_job_id} // '') eq $job_id) {
                        $run->{paused_for_attention} = 1;
                        $run->{current_job_id} = undef;
                        $JOBS{paused} = 1;
                        p("The job batch paused because the owning CHAT closed while job $job_id awaited an offer.");
                    }
                }
                delete $JOBS{active_job_id}
                    if ($JOBS{active_job_id} // '') eq $job_id;
            }
        }
    }
    ++$SESSION_GENERATION;
    cancel_session_timers();
    $S{generation} = $SESSION_GENERATION if $keep_queued_offer_wait;
    $_->{detached} = 1 for grep { ($_->{generation} || 0) == ($generation || 0) } values %TRANSFERS;

    $S{active} = $keep_queued_offer_wait ? 1 : 0;
    # Keep this independent of $S{phase}; successful/error transfer closure
    # changes that phase while the detached request still has no CHAT authority.
    $S{chat_authorization_revoked} = 1 if $keep_queued_offer_wait;
    $S{chat_connected} = 0;
    $S{chat_id} = undef;
    $S{chat_dcc} = undef;
    $S{chat_identity_key} = undef;
    $S{chat_request_identity} = undef;
    $S{nav_active} = 0;
    $S{nav_steps} = [];
    $S{nav_after} = undef;
    $S{listing_active} = 0;
    $S{verify_get_active} = 0;
    $S{current_path} = [] if $keep_queued_offer_wait;
    $S{queue} = [] if $keep_queued_offer_wait;
    $S{sequence_token} = ($S{sequence_token} || 0) + 1;
    $S{initial_prompt_token} = ($S{initial_prompt_token} || 0) + 1;
    $S{pending_download} = undef unless $keep_queued_offer_wait;
    release_untransferred_manifest_lease($pending) unless $recovery_scheduled;
    $S{phase} = $keep_queued_offer_wait ? 'awaiting_queued_offer' : 'disconnected';
    restore_download_path();
    log_to_path($S{log_file}, 'STATE', 'owned DCC CHAT closed; session operations invalidated');
    if ($keep_queued_offer_wait) {
        my $remaining_ms = int(($queued_wait_deadline - monotonic_now()) * 1000);
        $remaining_ms++ if $remaining_ms > 0;
        my $job_id = $pending->{phase6_job_id};
        if ($remaining_ms < 1 || !arm_wait_timer($job_id, $remaining_ms, 'remote_queue')) {
            cancel_wait_timer($job_id);
            my $job = jobs_ready() ? $JOBS{coordinator}->job($job_id) : undef;
            if ($job && $job->{state} eq 'remote_queued') {
                my $target = $remaining_ms < 1 ? 'expired' : 'needs_attention';
                job_transition($job_id, $target,
                    outcome => $remaining_ms < 1 ? 'remote_queue_deadline' : 'chat_closed_wait_timer_unavailable',
                    reason => $remaining_ms < 1
                        ? 'absolute confirmed queue-wait deadline elapsed during CHAT close'
                        : 'bounded confirmed queue wait could not be re-armed after CHAT close');
            }
            delete $JOBS{active_job_id}
                if ($JOBS{active_job_id} // '') eq $job_id;
            $S{active} = 0;
            $S{pending_download} = undef;
            $S{phase} = 'disconnected';
            if (my $run = $JOBS{run_batch}) {
                if (($run->{current_job_id} // '') eq $job_id) {
                    $run->{paused_for_attention} = 1;
                    $run->{current_job_id} = undef;
                    $JOBS{paused} = 1;
                }
            }
            p($remaining_ms < 1
                ? 'The confirmed remote queue deadline elapsed while the CHAT was closing; no request was resent.'
                : 'The confirmed queue wait could not be safely re-armed after CHAT close; the job requires inspection.');
            return;
        }
        p('The confirmed queue wait remains bound to its original IRC connection and absolute deadline; navigation is invalidated, and no request will be resent.');
        return;
    }
    p($recovery_scheduled
        ? 'DCC CHAT closed; the pre-dispatch recovery timer will open a fresh session.'
        : 'DCC CHAT closed; session operations stopped. Start a new session to continue.');
}

sub reset_state {
    my %keep;
    %S = %keep;
}

sub stop_session {
    my ($quiet) = @_;
    finish_pre_dispatch_recovery(
        'FServe session was stopped before GET dispatch',
        needs_attention => 1, release_lease => 1,
        outcome => 'pre_dispatch_recovery_stopped')
        if $JOBS{pre_dispatch_recovery};
    cancel_wait_timer();
    my $chat_id = $S{chat_id};
    # Irssi finds the CHAT to close by its nick: after the file server
    # changed nick, by the new one (sig_event_nick).
    my $chat_close_name = $S{chat_renamed_to} // $chat_id;
    my $chat_connected = $S{chat_connected};
    my $pending_chat = $S{chat_dcc};
    my $generation = $S{generation};
    my $pending = $S{pending_download};
    my $paused_preflight = $S{phase6_paused_get};
    my $stopped_preflight_job_id =
        $pending && defined($pending->{phase6_job_id})
            ? $pending->{phase6_job_id}
            : $paused_preflight &&
                ($paused_preflight->{generation} || 0) == ($generation || 0)
                    ? $paused_preflight->{job_id} : undef;
    if (defined($stopped_preflight_job_id) && jobs_ready()) {
        my $job = $JOBS{coordinator}->job($stopped_preflight_job_id);
        my $run = $JOBS{run_batch};
        my $run_owns_job = $run && (
            ($run->{current_job_id} // '') eq $stopped_preflight_job_id ||
            (($run->{job_ids}[$run->{index}] // '') eq $stopped_preflight_job_id)
        );
        if ($job && $job->{provider} eq 'crawl' &&
                $job->{state} eq 'held' && $run_owns_job) {
            # Establish the stop barrier before cancelling outbound callbacks:
            # a failed pending dir send can settle this job synchronously.
            $JOBS{paused} = 1;
            $run->{paused_for_attention} = 1;
        }
    }
    cancel_outbound_owner('session', $generation,
        'FServe session stopped before delayed message dispatch')
        if defined $generation;
    if (defined($stopped_preflight_job_id) && jobs_ready()) {
        my $job_id = $stopped_preflight_job_id;
        my $run = $JOBS{run_batch};
        my $job = $JOBS{coordinator}->job($job_id);
        my $paused_run_owns_job = $run && $paused_preflight &&
            ($paused_preflight->{job_id} // '') eq $job_id &&
            ($paused_preflight->{generation} || 0) == ($generation || 0) &&
            (($run->{job_ids}[$run->{index}] // '') eq $job_id);
        if ($job && $job->{provider} eq 'crawl' &&
                $job->{state} eq 'held' && $run &&
                ((($run->{current_job_id} // '') eq $job_id &&
                    ($run->{waiting_crawl} // '') eq $job_id) ||
                    $paused_run_owns_job)) {
            # Stopping invalidates the original crawl CHAT, so its held
            # preflight cannot be resumed. Pause the captured batch before
            # the terminal transition so settlement cannot dispatch its next
            # job while this session is being torn down.
            $JOBS{paused} = 1;
            $run->{paused_for_attention} = 1;
            my $recorded = job_transition($job_id, 'stale',
                outcome => 'crawl_preflight_session_stopped',
                reason => 'the original crawl CHAT was stopped before live-parent verification completed');
            unless ($recorded) {
                # The held job remains available for inspection/cancellation,
                # but must no longer masquerade as an active async preflight.
                $run->{waiting_crawl} = undef;
                $run->{current_job_id} = undef;
                $run->{dispatching} = 0;
                delete $JOBS{active_job_id}
                    if ($JOBS{active_job_id} // '') eq $job_id;
                p("The job batch paused because stopped crawl preflight $job_id could not be retired in the journal.");
            }
        }
    }
    if ($pending && defined($pending->{phase6_job_id}) && jobs_ready()) {
        my $job = $JOBS{coordinator}->job($pending->{phase6_job_id});
        if ($job && $job->{state} eq 'preparing') {
            job_transition($pending->{phase6_job_id}, 'needs_attention',
                outcome => 'session_stopped_with_chat_ambiguity',
                reason => 'delayed identical CHAT remains ambiguous after the session stopped');
        } elsif ($job && ($job->{state} eq 'awaiting_offer' ||
                $job->{state} eq 'remote_queued') && !$pending->{accepted_transfer_key}) {
            retire_job($pending->{phase6_job_id}, 'cancelled',
                'local stop cancelled the pending offer or confirmed queue wait; remote queue state is unchanged');
        }
    }
    # Any outstanding manifest selection check must become inert before its
    # asynchronous worker callback can open a new DCC session or send a trigger.
    $MANIFEST{fetch_sequence} = ($MANIFEST{fetch_sequence} || 0) + 1;
    ++$SESSION_GENERATION;
    cancel_session_timers();
    $_->{detached} = 1 for grep {
        defined($generation) && ($_->{generation} || 0) == $generation
    } values %TRANSFERS;

    # Invalidate CHAT ownership before DCC CLOSE can synchronously emit its
    # close signal. Transfer records remain independently bound by lifecycle.
    $S{active} = 0;
    $S{chat_connected} = 0;
    $S{chat_id} = undef;
    $S{chat_dcc} = undef;
    $S{chat_identity_key} = undef;
    $S{chat_request_identity} = undef;
    $S{pending_download} = undef;
    release_untransferred_manifest_lease($pending);
    $S{nav_active} = 0;
    $S{listing_active} = 0;
    $S{verify_get_active} = 0;
    $S{sequence_token} = ($S{sequence_token} || 0) + 1;
    $S{initial_prompt_token} = ($S{initial_prompt_token} || 0) + 1;
    log_line('STATE', 'session stopped') if $S{log_file};
    if ($chat_connected && $chat_id) {
        Irssi::command('DCC CLOSE CHAT ' . $chat_close_name);
    } elsif ($pending_chat) {
        my $closed = eval { $pending_chat->destroy(); 1 };
        Irssi::command('DCC CLOSE CHAT ' . $chat_close_name)
            if !$closed && defined $chat_id;
    }
    restore_download_path();
    reset_state();
    p('Stopped.') unless $quiet;
}

sub find_selection_is_current {
    my ($file, $server) = @_;
    return 1 unless $file && ($file->{source} // '') eq 'find';
    my ($query_id, $ordinal) = ($file->{selection_token} // '') =~
        /\Afind-([1-9][0-9]*)-([1-9][0-9]*)\z/;
    return 0 unless defined($query_id) && defined($ordinal) &&
        ($file->{selection_generation} || 0) == $query_id &&
        !$FIND{active} && ($FIND{state} // '') eq 'complete' &&
        ($FIND{query_id} || 0) == $query_id &&
        ref($FIND{results}) eq 'ARRAY' &&
        $ordinal <= @{$FIND{results}};
    return 0 unless ref($server) &&
        server_connection_identity($server) eq ($FIND{server_identity} // '') &&
        server_connection_epoch($server) == ($FIND{connection_epoch} || 0);
    my $result = $FIND{results}[$ordinal - 1] or return 0;
    return ($result->{remote_path} // '') eq ($file->{path} // '') &&
        ($result->{trigger_raw} // '') eq ($file->{trigger_raw} // '') &&
        ($result->{server_nick} // '') eq ($file->{server_nick} // '') &&
        ($result->{server_tag} // '') eq ($file->{server_tag} // '') &&
        ($result->{network_id} // '') eq ($file->{network_id} // '') &&
        ($FIND{channel} // '') eq ($file->{discovery_channel} // '') ? 1 : 0;
}

sub start_fserve_session {
    my ($nick, $server, $trigger_cmd, $direct_fetch, $recovery_id) = @_;
    finish_pre_dispatch_recovery(
        'a new FServe session superseded the pending recovery',
        needs_attention => 1, release_lease => 1,
        outcome => 'pre_dispatch_recovery_superseded')
        if $JOBS{pre_dispatch_recovery} && !defined($recovery_id);
    if ($SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving' || searchbot_direct_active()) {
        p('A SearchBot result collection owns the discovery/DCC slot; finish or cancel it before starting an FServe session.');
        return;
    }
    if ($DOWNLOAD_PATH_OWNER) {
        p('A previously accepted DCC GET has not connected and selected its staging file yet; wait for it to connect before starting another session.');
        return;
    }
    if ($direct_fetch && has_active_download_transfer() && !$direct_fetch->{web_parallel}) {
        p('A previous DCC GET is still active; let it close before starting another direct fetch.');
        return;
    }
    return unless load_fserve_parser() && load_dcc_policy() && load_catalog_module();
    if ($direct_fetch) {
        my $job_id = fserve_job($direct_fetch, $server,
            $direct_fetch->{phase6_job_id}, $nick);
        return unless $job_id;
        $direct_fetch->{phase6_job_id} = $job_id;
        my $job = $JOBS{coordinator}->job($job_id);
        my $tuple_check = eval {
            $JOBS{coordinator}->preflight_tuples($job_id,
                casemapping => job_casemapping($job, $server));
        };
        unless ($tuple_check && $tuple_check->{available}) {
            my $reason = $tuple_check ? $tuple_check->{reason}
                : ($@ || 'offer tuple preflight failed');
            $reason =~ s/[\r\n]+/ /g;
            job_transition($job_id, 'stale', outcome => 'tuple_preflight_refused',
                reason => $reason) if $job && $job->{state} eq 'held';
            p("Direct fetch refused before trigger dispatch: $reason");
            return;
        }
        if ($job && $job->{state} eq 'held') {
            my $prepared = eval {
                $JOBS{coordinator}->transition($job_id, 'ready', reason => 'explicit direct retrieval selected');
                $JOBS{coordinator}->transition($job_id, 'preparing');
                1;
            };
            unless ($prepared) {
                my $error = $@ || 'could not persist preflight state';
                $error =~ s/[\r\n]+/ /g;
                p("Direct fetch stopped before trigger dispatch: $error");
                return;
            }
        } elsif (!$job || $job->{state} ne 'preparing') {
            p('Direct fetch job is no longer in a safe preflight state; no trigger was sent.');
            return;
        }
    }
    # Starting another crawl/fetch supersedes any selection check still pending.
    $MANIFEST{fetch_sequence} = ($MANIFEST{fetch_sequence} || 0) + 1;
    stop_session() if defined $S{generation};
    reset_state();
    my $generation = ++$SESSION_GENERATION;
    $S{generation} = $generation;
    $S{session_timers} = {};
    $S{active} = 1;
    $S{nick} = $nick;
    $S{server_tag} = $server->{tag} // '';
    $S{network_id} = $server->{chatnet} // $S{server_tag};
    $S{server} = $server;
    $S{server_identity} = server_connection_identity($server);
    $S{connection_epoch} = server_connection_epoch($server);
    $S{casemapping} = server_casemapping($server);
    $S{trigger_raw} = $direct_fetch ? $direct_fetch->{trigger_raw} : 'crawl';
    $S{trigger_cmd} = $trigger_cmd;
    my $trigger_context = $direct_fetch
        ? $direct_fetch
        : catalog_trigger_context($trigger_cmd);
    $S{catalog_trigger_raw} = $trigger_context->{trigger_raw} // 'crawl';
    $S{catalog_trigger_mode} = $trigger_context->{trigger_mode} // 'unknown';
    $S{catalog_trigger_channel} = $trigger_context->{discovery_channel};
    $S{direct_fetch} = $direct_fetch ? 1 : 0;
    $S{web_parallel} = ref($direct_fetch) eq 'HASH' && $direct_fetch->{web_parallel} ? 1 : 0;
    $S{trigger_dispatching} = 0;
    $S{trigger_dispatched} = 0;
    $S{trigger_dispatch_pending} = 1;
    $S{trigger_attempted} = 0;
    $S{max_depth} = Irssi::settings_get_int('fscrawl_max_depth');
    $S{queue} = [];
    $S{catalog} = [];
    $S{visited} = {};
    $S{current_path} = [];
    $S{phase} = 'waiting_for_chat';
    $S{pre_dispatch_recovery_id} = $recovery_id if defined $recovery_id;

    ensure_dirs();
    my $stamp = strftime('%Y%m%d-%H%M%S', localtime());
    $S{log_file} = File::Spec->catfile($S{output_dir}, "transcript-$stamp.tsv");
    $S{catalog_tsv} = File::Spec->catfile($S{output_dir}, "catalog-$stamp.tsv");
    $S{catalog_jsonl} = File::Spec->catfile($S{output_dir}, "catalog-$stamp.jsonl");
    $S{pending_download} = $direct_fetch ? new_pending_download($direct_fetch) : undef;
    $S{phase6_job_id} = $direct_fetch ? $direct_fetch->{phase6_job_id} : undef;

    $old_dcc_download_path = Irssi::settings_get_str('dcc_download_path');
    Irssi::settings_set_str('dcc_download_path', $S{download_dir});

    log_line('STATE', "start nick=$nick server=$S{server_tag} max_depth=$S{max_depth}");
    log_line('TRIGGER', $trigger_cmd);
    if ($direct_fetch) {
        log_line('FETCH_SELECTED', $direct_fetch->{path});
        p("Starting direct fetch for $direct_fetch->{path} from $nick via $direct_fetch->{trigger_raw}.");
    } else {
        p("Starting crawl for expected FServe nick $nick (max depth $S{max_depth}).");
    }
    p("Only DCC CHAT from that nick on $S{server_tag} is accepted; DCC SEND is accepted only for the pending file.");
    if ($direct_fetch) {
        my $recorded = eval {
            $JOBS{coordinator}->record_event('trigger_dispatch_intent', {
                job_id => $direct_fetch->{phase6_job_id},
                connection_identity => $S{server_identity},
                connection_epoch => $S{connection_epoch},
                trigger_digest => sha256_hex($trigger_cmd),
            });
            1;
        };
        unless ($recorded) {
            p('Direct fetch stopped because trigger intent could not be durably recorded.');
            stop_session(1);
            job_transition($direct_fetch->{phase6_job_id}, 'failed', reason => 'trigger was not sent because journal write failed');
            return;
        }
    }
    my $target = $trigger_cmd =~ /^\s*(?:MSG|PRIVMSG)\s+(\S+)/i ? $1
        : $trigger_cmd =~ /^\s*CTCP\s+(\S+)/i ? $1
        : undef;
    my $route = defined($target)
        ? outbound_route_key($server, $target, $nick, 'fserve') : undef;
    my $server_identity = $S{server_identity};
    my $connection_epoch = $S{connection_epoch};
    my $find_selection_is_current = sub {
        find_selection_is_current($direct_fetch, $server);
    };
    my $recovery = $JOBS{pre_dispatch_recovery};
    my $recovery_deadline = defined($recovery_id) && $recovery &&
        $recovery->{id} == $recovery_id && $direct_fetch &&
        ($recovery->{job_id} // '') eq ($direct_fetch->{phase6_job_id} // '')
            ? $recovery->{deadline_monotonic} : undef;
    my $recovery_deadline_ok = sub {
        return 1 unless defined $recovery_id;
        return 0 unless defined $recovery_deadline;
        return recovery_deadline_allows_dispatch(
            $direct_fetch->{phase6_job_id}, $recovery_deadline);
    };
    unless (defined($route) && length($route)) {
        if ($direct_fetch) {
            eval { $JOBS{coordinator}->record_event('trigger_dispatch_not_sent', {
                job_id => $direct_fetch->{phase6_job_id},
                connection_identity => $server_identity,
                connection_epoch => $connection_epoch,
                reason => 'trigger command did not identify a rate-limitable IRC route',
            }); };
            job_transition($direct_fetch->{phase6_job_id}, 'needs_attention',
                outcome => 'trigger_route_unavailable');
        }
        p('FServe trigger refused because its channel/peer route could not be identified for safe pacing.');
        stop_session(1);
        return;
    }
    my $scheduled = schedule_irc_message(
        server => $server, kind => 'trigger', route => $route,
        owner_kind => 'session', owner_id => "$generation",
        owner_job_id => $direct_fetch ? $direct_fetch->{phase6_job_id} : undef,
        guard => sub {
            $S{active} && ($S{generation} || 0) == ($generation || 0) &&
                ($S{server_identity} // '') eq ($server_identity // '') &&
                ($S{connection_epoch} || 0) == ($connection_epoch || 0) &&
                $recovery_deadline_ok->() &&
                $find_selection_is_current->()
        },
        before_send => sub {
            return 0 unless $S{active} && ($S{generation} || 0) == ($generation || 0) &&
                $recovery_deadline_ok->() &&
                $find_selection_is_current->();
            $S{trigger_dispatching} = 1;
            $S{trigger_attempted} = 1;
            return 1;
        },
        send => sub { $server->command($trigger_cmd) },
        on_done => sub {
            my ($status, $reason) = @_;
            return unless $S{active} && ($S{generation} || 0) == ($generation || 0);
            $S{trigger_dispatch_pending} = 0;
            $S{trigger_dispatching} = 0;
            if ($status eq 'sent') {
                $S{trigger_dispatched} = 1;
                delete @S{qw(trigger_notice session_open_failed)};
                arm_session_open_deadline($generation) if $direct_fetch;
                if ($direct_fetch) {
                    my $acknowledged = eval {
                        $JOBS{coordinator}->record_event('trigger_dispatched', {
                            job_id => $direct_fetch->{phase6_job_id},
                            connection_identity => $server_identity,
                            connection_epoch => $connection_epoch,
                        });
                        1;
                    };
                    unless ($acknowledged) {
                        job_transition($direct_fetch->{phase6_job_id}, 'needs_attention',
                            outcome => 'trigger_acknowledgment_failed');
                        p('The trigger was sent, but durable acknowledgment failed; this job requires manual attention.');
                        stop_session(1);
                        return;
                    }
                }
                return;
            }
            if ($status eq 'paused_before_send') {
                if ($direct_fetch) {
                    eval { $JOBS{coordinator}->record_event('trigger_dispatch_paused', {
                        job_id => $direct_fetch->{phase6_job_id},
                        connection_identity => $server_identity,
                        connection_epoch => $connection_epoch,
                    }); };
                    my $job = $JOBS{coordinator}->job($direct_fetch->{phase6_job_id});
                    eval { $JOBS{coordinator}->transition(
                        $direct_fetch->{phase6_job_id}, 'held',
                        outcome => 'trigger_paused_before_send',
                        reason => 'queue pause withdrew the scheduled trigger before transport invocation'); }
                        if $job && $job->{state} eq 'preparing';
                }
                $S{trigger_dispatched} = 0;
                p('Queue pause withdrew the FServe trigger before it was sent.');
                stop_session(1);
                return;
            }
            if ($direct_fetch) {
                my $event = $S{trigger_attempted}
                    ? 'trigger_dispatch_unknown' : 'trigger_dispatch_not_sent';
                eval { $JOBS{coordinator}->record_event($event, {
                    job_id => $direct_fetch->{phase6_job_id},
                    connection_identity => $server_identity,
                    connection_epoch => $connection_epoch,
                    reason => safe_field($reason // $status),
                }); };
                job_transition($direct_fetch->{phase6_job_id}, 'needs_attention',
                    outcome => $S{trigger_attempted} ? 'trigger_dispatch_unknown' : 'trigger_not_dispatched',
                    reason => safe_field($reason // $status));
            }
            p('FServe trigger was not safely dispatched; it will not be repeated automatically: ' .
                safe_field($reason // $status));
            stop_session(1);
        },
    );
    unless ($scheduled) {
        $S{trigger_dispatch_pending} = 0;
        if ($direct_fetch) {
            eval { $JOBS{coordinator}->record_event('trigger_dispatch_not_sent', {
                job_id => $direct_fetch->{phase6_job_id},
                connection_identity => $server_identity,
                connection_epoch => $connection_epoch,
                reason => 'outbound scheduler reservation unavailable',
            }); };
            job_transition($direct_fetch->{phase6_job_id}, 'needs_attention',
                outcome => 'trigger_scheduler_unavailable');
        }
        p('Could not reserve the FServe trigger in the outbound scheduler; no trigger was sent.');
        stop_session(1);
        return;
    }
    return 1;
}

sub cmd_get {
    my ($arg) = @_;
    unless ($S{active} && $S{chat_connected}) {
        p('No active FServe DCC CHAT.');
        return;
    }
    unless ($arg =~ /^\s*([0-9]+)\s*$/) {
        p('Usage: /fscrawl get <file-index>');
        return;
    }

    my $files = FServe::Catalog::files($S{catalog});
    my $index_text = $1;
    $index_text =~ s/^0+//;
    my $file_count = scalar @$files;
    my $count_text = "$file_count";
    if (!length($index_text) ||
        length($index_text) > length($count_text) ||
        (length($index_text) == length($count_text) && $index_text gt $count_text)) {
        p('No such file index. Use /fscrawl list first.');
        return;
    }
    my $index = 0 + $index_text;
    my $f = $files->[$index - 1];
    unless ($f) {
        p('No such file index. Use /fscrawl list first.');
        return;
    }

    my $queued_job_id = delete $JOBS{executing_job_id};
    if (defined $queued_job_id) {
        my $job = jobs_ready() ? $JOBS{coordinator}->job($queued_job_id) : undef;
        my $selection = $job ? $job->{selection} : {};
        unless ($job && $job->{provider} eq 'crawl' && $job->{state} eq 'held' &&
                job_is_on_connection($job, $S{server}) &&
                ($selection->{selection_token} // '') eq
                    ('crawl-' . ($S{generation} || 0) . '-' . $index) &&
                ($selection->{remote_path} // '') eq ($f->{path} // '') &&
                ($selection->{name} // '') eq ($f->{name} // '')) {
            job_transition($queued_job_id, 'stale', outcome => 'queued_crawl_selection_stale',
                reason => 'the queued crawl selection no longer matches the live session generation and file')
                if $job && $job->{state} eq 'held';
            p('Queued crawl selection is stale or belongs to another DCC CHAT; no GET was sent.');
            return;
        }
        $f = { %$f, phase6_job_id => $queued_job_id };
    }

    my @parts = grep { length } split m{/+}, $f->{parent};
    if ($S{pending_download}) {
        p('A download request is already pending. Wait for it to finish or restart the crawl session.');
        return;
    }
    if (session_transfer_count()) {
        p('A previous DCC GET is still active. Wait for it to close before requesting another file.');
        return;
    }

    # Preflight the known mIRC/SysReset "Fill Spaces" transformation. If the
    # requested filename would be advertised over DCC with spaces changed to
    # underscores and that transformed name is also a distinct real file in
    # the same directory, there is no safe way to know which file the DCC
    # offer represents. Refuse before telling the FServe to send anything so
    # we do not consume one of the provider's send slots.
    if (my $conflict = legacy_dcc_alias_conflict($f)) {
        my $legacy = $f->{name};
        $legacy =~ s/ /_/g;
        p("Refusing request before DCC: [$f->{name}] would be advertised as [$legacy], but [$conflict->{name}] also exists in the same directory.");
        p("No GET was sent to the FServe, so no remote send slot was consumed.");
        log_line(
            'DOWNLOAD_PREFLIGHT_REFUSED',
            "reason=ambiguous-space-to-underscore requested=[$f->{path}] conflict=[$conflict->{path}]"
        );
        return;
    }

    $S{pending_download} = new_pending_download($f);
    if (defined($queued_job_id) && $JOBS{run_batch} &&
            ($JOBS{run_batch}{current_job_id} // '') eq $queued_job_id) {
        # Parent navigation/listing is asynchronous. Keep the finite batch
        # attached to this held crawl job until verification either refuses
        # the selection or durable GET intent advances it out of preflight.
        $JOBS{run_batch}{waiting_crawl} = $queued_job_id;
    }
    p("Requesting $f->{path}");
    navigate_to(\@parts, sub {
        begin_download_verify($S{pending_download});
    });
}

sub cmd_fetch {
    if (searchbot_direct_active()) {
        p('A direct SearchBot request owns the retrieval slot; wait for it to finish or cancel it before fetching an @Find result.');
        return;
    }
    my ($arg, $server) = @_;
    if (any_find_active()) {
        p('Wait for the active @Find collection to finish before selecting a result.');
        return;
    }
    if ($S{active}) {
        p('An FServe session is already active. Use /fscrawl stop before fetching a @Find result.');
        return;
    }
    unless ($arg =~ /^\s*(\d+)(?:\s+(channel|ctcp))?\s*$/i) {
        p('Usage: /fscrawl fetch <find-result-index> [channel|ctcp]');
        return;
    }

    my $index = $1;
    my $mode_override = defined($2) ? lc($2) : undef;
    $mode_override = 'channel_text' if defined($mode_override) && $mode_override eq 'channel';
    my $result = $FIND{results}[$index - 1];
    unless ($index > 0 && $result) {
        p('No such @Find result index. Use /fscrawl findlist first.');
        return;
    }
    my $trigger_mode = $mode_override || $result->{trigger_mode} || 'channel_text';
    unless (($trigger_mode eq 'channel_text' || $trigger_mode eq 'ctcp') &&
            defined($result->{trigger_raw}) &&
            $result->{trigger_raw} =~ /^[^\s\x00-\x1f\x7f]{1,128}$/) {
        p('This result does not contain a safe trigger for the selected mode; refusing to fetch it.');
        return;
    }
    unless (($result->{server_tag} // '') eq ($FIND{server_tag} // '') &&
            ($result->{network_id} // '') eq ($FIND{network_id} // '')) {
        p('The result network identity does not match the active @Find search; refusing to fetch it.');
        return;
    }
    my $server_network = $server ? ($server->{chatnet} // $server->{tag} // '') : '';
    unless ($server && $server->{connected} &&
            lc($server->{tag} // '') eq lc($FIND{server_tag} // '') &&
            lc($server_network) eq lc($FIND{network_id} // '')) {
        p('Run /fscrawl fetch from the same connected IRC network used for @Find.');
        return;
    }

    my $remote_path = $result->{remote_path} // '';
    my ($path, $parent, $basename) = FServe::Model::split_remote_path($remote_path);
    unless (defined $path && defined $parent && defined $basename) {
        p('The selected result has an invalid remote path; refusing to fetch it.');
        return;
    }

    my %download = (
        type          => 'file',
        path          => $path,
        parent        => $parent,
        name          => $basename,
        size_raw      => $result->{size_raw},
        size_bytes    => $result->{size_bytes},
        trigger_raw   => $result->{trigger_raw},
        trigger_mode  => $trigger_mode,
        discovery_channel => $FIND{channel},
        server_nick   => $result->{server_nick},
        network_id    => $result->{network_id},
        server_tag    => $result->{server_tag},
        source        => 'find',
        selection_token => 'find-' . ($FIND{query_id} || 0) . '-' . $index,
        selection_generation => $FIND{query_id} || 0,
        (defined($WEB_BRIDGE{download_operation_id})
            ? (web_operation_id => $WEB_BRIDGE{download_operation_id},
               web_auto_recovery => $WEB_BRIDGE{download_auto_recovery} ? 1 : 0,
               web_parallel => $WEB_BRIDGE{download_parallel} ? 1 : 0) : ()),
        (defined($WEB_BRIDGE{download_network_dir})
            ? (destination_network => $WEB_BRIDGE{download_network_dir}) : ()),
    );
    my $queued_job_id = delete $JOBS{executing_job_id};
    if (defined $queued_job_id) {
        my $job = jobs_ready() ? $JOBS{coordinator}->job($queued_job_id) : undef;
        my $selection = $job ? $job->{selection} : {};
        unless ($job && $job->{provider} eq 'find' && $job->{state} eq 'held' &&
                job_is_on_connection($job, $server) &&
                ($selection->{selection_token} // '') eq $download{selection_token} &&
                ($selection->{remote_path} // '') eq $download{path} &&
                ($selection->{name} // '') eq $download{name} &&
                ($selection->{trigger_raw} // '') eq $download{trigger_raw} &&
                ($selection->{expected_peer} // '') eq $download{server_nick}) {
            job_transition($queued_job_id, 'stale', outcome => 'queued_find_selection_stale',
                reason => 'the queued Find selection no longer matches the active completed result view')
                if $job && $job->{state} eq 'held';
            p('Queued Find selection is stale or belongs to another IRC connection; no trigger was sent.');
            return;
        }
        $download{phase6_job_id} = $queued_job_id;
    }
    my $trigger_command = $trigger_mode eq 'ctcp'
        ? 'CTCP ' . $result->{server_nick} . ' ' . $result->{trigger_raw}
        : 'MSG ' . $FIND{channel} . ' ' . $result->{trigger_raw};
    start_fserve_session($result->{server_nick}, $server, $trigger_command, \%download);
}

1;
