# DCC offers and transfers: which are taken, and how each one ends.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Fcntl qw(S_ISLNK S_ISREG);

our (%JOBS, %S, %SEARCHBOT, %SEARCHBOT_CONTENT_TOMBSTONES, %SEARCHBOT_DIRECT,
     %SEARCHBOT_USED_OFFERS, %TRANSFERS, %USED_TRANSFER_IDENTITIES, $DOWNLOAD_PATH_OWNER);

my %USED_CHAT_IDENTITIES;

sub log_line {
    my ($kind, $text) = @_;
    return log_to_path($S{log_file}, $kind, $text);
}

sub log_to_path {
    my ($path, $kind, $text) = @_;
    return unless $path;
    open my $fh, '>>', $path or return;
    print {$fh} now_iso(), "\t", safe_field($kind), "\t", safe_field($text), "\n";
    close $fh;
}

sub dcc_desc {
    my ($dcc) = @_;
    return join(' ', map { $_ . '=' . safe_field($dcc->{$_}) }
        grep { defined $dcc->{$_} && $dcc->{$_} ne '' }
        qw(type orig_type nick id arg servertag created addr port size transfd file target));
}

sub quote_irssi_arg {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/([\\"])/\\$1/g;
    return '"' . $s . '"';
}

sub same_dcc_peer {
    my ($dcc) = @_;
    return 0 unless $S{active};
    return 0 unless FServe::DccPolicy::same_peer($dcc, $S{nick}, $S{server_tag});
    return 0 unless defined($S{server_identity}) && defined($S{connection_epoch});
    my $server = ref($dcc) ? $dcc->{server} : undef;
    return 0 unless $server && server_connection_identity($server) eq $S{server_identity};
    return server_connection_epoch($server) == $S{connection_epoch} ? 1 : 0;
}

sub capture_transfer_receive_identity {
    my ($transfer, $dcc) = @_;
    return 0 unless ref($transfer) eq 'HASH' && ref($dcc) &&
        uc($dcc->{type} // '') eq 'GET';
    my $file = $transfer->{file};
    # Only an explicitly matched space-to-underscore alias is accepted here,
    # for an FServe file or a posted row; exact-name receives keep the
    # selected name.
    my $accepted_alias = ref($file) eq 'HASH' &&
        ($file->{dcc_match_mode} // '') eq 'space-to-underscore';
    my $accepted_name = $accepted_alias ? $transfer->{offered_name} : undef;
    my $target = staged_download_target($file, $dcc, $accepted_name);
    unless (defined $target) {
        $transfer->{partial_source_invalid} = 1
            if defined($transfer->{receive_source});
        return 0;
    }
    if (defined($transfer->{receive_source}) &&
            $transfer->{receive_source} ne $target) {
        $transfer->{partial_source_invalid} = 1;
        return 0;
    }
    $transfer->{receive_source} //= $target;
    $transfer->{dcc_file} //= $target;

    my @target_stat = lstat($target);
    return 0 unless @target_stat;
    if (!S_ISREG($target_stat[2]) || S_ISLNK($target_stat[2]) ||
            (defined($transfer->{receive_dev}) &&
             ($transfer->{receive_dev} != $target_stat[0] ||
              $transfer->{receive_ino} != $target_stat[1]))) {
        $transfer->{partial_source_invalid} = 1;
        return 0;
    }
    unless (defined($transfer->{receive_dev})) {
        $transfer->{receive_dev} = $target_stat[0];
        $transfer->{receive_ino} = $target_stat[1];
    }
    return 1;
}

sub dcc_tag {
    my ($dcc) = @_;
    my $tag = $dcc->{servertag} // '';
    $tag = $dcc->{server}{tag} // '' if !length($tag) && ref($dcc->{server});
    return $tag;
}

sub identity_key {
    my (@parts) = @_;
    return join('', map { length($_) . ':' . $_ } @parts);
}

sub dcc_chat_identity_key {
    my ($dcc) = @_;
    return unless ref($dcc) && uc($dcc->{type} // '') eq 'CHAT';
    my ($tag, $nick, $id, $created, $addr, $port) = (
        dcc_tag($dcc), $dcc->{nick} // '', $dcc->{id} // '',
        $dcc->{created}, $dcc->{addr}, $dcc->{port},
    );
    return unless length($tag) && length($nick) && length($id);
    return unless defined($created) && defined($addr) && length("$addr") && defined($port);
    return identity_key('CHAT', lc($tag), lc($nick), lc($id), "$created", "$addr", "$port");
}

# Irssi 1.4.5 documents a CHAT id, but DCC::Get lifecycle identity is represented
# by its creation time and peer endpoint rather than a comparable unique id.
# Add the GET offer tuple and fail closed if any required binding field is absent.
sub dcc_transfer_identity_key {
    my ($dcc) = @_;
    return unless ref($dcc) && uc($dcc->{type} // '') eq 'GET';
    my ($tag, $nick, $arg, $created, $addr, $port, $size) = (
        dcc_tag($dcc), $dcc->{nick} // '', $dcc->{arg},
        $dcc->{created}, $dcc->{addr}, $dcc->{port}, $dcc->{size},
    );
    return unless length($tag) && length($nick) && defined($arg) && length($arg);
    return unless defined($created) && defined($addr) && length("$addr") && defined($port) && defined($size);
    return identity_key('GET', lc($tag), lc($nick), "$created", "$addr", "$port", "$size", "$arg");
}

sub dcc_filename_match {
    my ($offered, $want, $parent) = @_;
    return FServe::DccPolicy::match_filename(
        $offered, $want, $parent, $S{catalog}
    );
}

sub legacy_dcc_alias_conflict {
    my ($f) = @_;
    return FServe::DccPolicy::legacy_alias_conflict(
        $f,
        verified_parent_path  => $S{verified_parent_path},
        verified_parent_files => $S{verified_parent_files},
        catalog               => $S{catalog},
    );
}

sub reject_dcc_get {
    my ($dcc, $reason, $clear_pending) = @_;
    my $offered = $dcc->{arg} // '';
    my $nick = $dcc->{nick} // '';
    my $server = $dcc->{server};
    my $cancelled;

    if ($clear_pending && $S{pending_download}) {
        $cancelled = delete $S{pending_download};
        release_untransferred_manifest_lease($cancelled);
        $S{phase} = 'error';
        $S{verify_get_active} = 0;
        $S{nav_active} = 0;
        cancel_session_timer($S{nav_timer});
        p("Canceled pending download request: " . ($cancelled->{name} // '') . ".");
        log_line('DOWNLOAD_CANCELED', "reason=$reason expected=[" . ($cancelled->{name} // '') . "]");
        restore_download_path_to_base() unless $DOWNLOAD_PATH_OWNER;
    }

    # Close the incoming offer locally. Legacy DCC SEND has no reliable,
    # interoperable receiver-side cancellation that guarantees an old sender
    # will immediately release its outgoing send slot. In particular, SysReset
    # on old mIRC may continue waiting until its own timeout even after Irssi
    # closes the GET. Therefore requests that we can predict are unsafe should
    # be blocked *before* sending "get" (see legacy_dcc_alias_conflict()).
    my $same_name_transfer_active = grep {
        lc($_->{tag} // '') eq lc(dcc_tag($dcc)) &&
        lc($_->{nick} // '') eq lc($nick) &&
        lc($_->{offered_name} // '') eq lc($offered)
    } values %TRANSFERS;

    if ($same_name_transfer_active) {
        my $destroyed = eval { $dcc->destroy(); 1 };
        if ($destroyed) {
            p("Closed duplicate DCC SEND offer by lifecycle handle: offered=[$offered] reason=[$reason]");
            log_line('DCC_LOCAL_REJECT', "offered=[$offered] reason=[$reason] method=handle");
        } else {
            p("Could not close duplicate DCC SEND offer safely: offered=[$offered] reason=[$reason]");
            log_line('DCC_LOCAL_REJECT_FAILED', "offered=[$offered] reason=[$reason] method=handle");
        }
    } elsif ($server && length($nick)) {
        $server->command('DCC CLOSE GET ' . $nick . ' ' . quote_irssi_arg($offered));
        p("Closed unsafe DCC SEND locally: offered=[$offered] reason=[$reason]");
        log_line('DCC_LOCAL_REJECT', "offered=[$offered] reason=[$reason]");
    } elsif (ref($dcc)) {
        my $destroyed = eval { $dcc->destroy(); 1 };
        p("Closed unsafe DCC SEND locally: offered=[$offered] reason=[$reason]") if $destroyed;
        log_line($destroyed ? 'DCC_LOCAL_REJECT' : 'DCC_LOCAL_REJECT_FAILED',
            "offered=[$offered] reason=[$reason] method=handle");
    } else {
        p("Could not close unsafe DCC SEND locally (no server context): offered=[$offered] reason=[$reason]");
        log_line('DCC_LOCAL_REJECT_FAILED', "offered=[$offered] reason=[$reason]");
    }
}

# File offers this client has seen and not taken, by server tag, address and
# port. A file server that offers every DCC on one port (the lab's mIRC does)
# treats the next connection to that port as acceptance of such an offer: a
# CHAT opened there was answered with the file itself. So a CHAT is never
# opened on an address and port where an untaken file offer may still be
# waiting. Entries lapse after five minutes, longer than a sender waits.
my %UNTAKEN_SEND_OFFERS;
my $UNTAKEN_SEND_OFFER_SECONDS = 300;

sub send_offer_port_key {
    my ($dcc) = @_;
    return undef unless ref($dcc);
    my ($address, $port) = ($dcc->{addr} // '', $dcc->{port} // 0);
    return undef unless length($address) && $port =~ /\A[1-9]\d{0,4}\z/;
    return join("\0", lc(dcc_tag($dcc) // ''), lc($address), $port);
}

sub note_untaken_send_offer {
    my ($dcc) = @_;
    my $key = send_offer_port_key($dcc) // return;
    my $now = time();
    delete @UNTAKEN_SEND_OFFERS{grep {
        $now - $UNTAKEN_SEND_OFFERS{$_} > $UNTAKEN_SEND_OFFER_SECONDS } keys %UNTAKEN_SEND_OFFERS};
    %UNTAKEN_SEND_OFFERS = () if keys(%UNTAKEN_SEND_OFFERS) >= 256;
    $UNTAKEN_SEND_OFFERS{$key} = $now;
}

sub untaken_send_offer_on_port {
    my ($dcc) = @_;
    my $key = send_offer_port_key($dcc) // return 0;
    my $seen = $UNTAKEN_SEND_OFFERS{$key} // return 0;
    return time() - $seen <= $UNTAKEN_SEND_OFFER_SECONDS ? 1 : 0;
}

sub sig_dcc_request {
    my ($dcc, $sendaddr) = @_;
    note_untaken_send_offer($dcc) if ref($dcc) && uc($dcc->{type} // '') eq 'GET';
    if ($JOBS{compaction_active}) {
        if (ref($dcc) && uc($dcc->{type} // '') eq 'GET') {
            reject_dcc_get($dcc, compaction_pause_reason());
        }
        return;
    }
    if (ref($dcc) && uc($dcc->{type} // '') eq 'GET' &&
            ($SEARCHBOT{active} || searchbot_direct_active() ||
             keys(%SEARCHBOT_USED_OFFERS) || keys(%SEARCHBOT_CONTENT_TOMBSTONES)) &&
            load_searchbot_provider()) {
        my $content_key = FServe::Discovery::SearchBotRequest::tombstone_key(
            dcc_tag($dcc), $dcc->{nick}, $dcc->{arg});
        my $is_current_content_offer = searchbot_direct_active() &&
            FServe::Discovery::SearchBotRequest::tombstone_matches(
                $dcc->{server}, dcc_tag($dcc), $dcc->{nick}, $dcc->{arg},
                { server_tag => $SEARCHBOT_DIRECT{server_tag},
                  sender => $SEARCHBOT_DIRECT{expected_sender},
                  filename => $SEARCHBOT_DIRECT{expected_basename},
                  casemapping => $SEARCHBOT_DIRECT{casemapping} });
        if (defined($content_key) && searchbot_tombstone_used(
                \%SEARCHBOT_CONTENT_TOMBSTONES, $dcc->{server},
                dcc_tag($dcc), $dcc->{nick}, $dcc->{arg}) &&
                !$is_current_content_offer) {
            reject_searchbot_content_offer($dcc,
                'this sender/server/name tuple belongs to an earlier direct SearchBot request');
            return;
        }
        if (searchbot_direct_active() && handle_searchbot_content_offer($dcc)) {
            return;
        }
        my $offer_key = searchbot_offer_tombstone_key(
            dcc_tag($dcc), $dcc->{nick}, $dcc->{arg}
        );
        my $is_current_searchbot_offer = $SEARCHBOT{active} &&
            FServe::Discovery::SearchBotRequest::tombstone_matches(
                $dcc->{server}, dcc_tag($dcc), $dcc->{nick}, $dcc->{arg},
                { server_tag => $SEARCHBOT{server_tag},
                  sender => $SEARCHBOT{expected_nick},
                  filename => $SEARCHBOT{expected_filename},
                  casemapping => $SEARCHBOT{casemapping} });
        if (defined($offer_key) && searchbot_tombstone_used(
                \%SEARCHBOT_USED_OFFERS, $dcc->{server},
                dcc_tag($dcc), $dcc->{nick}, $dcc->{arg}) &&
                !$is_current_searchbot_offer) {
            reject_searchbot_offer($dcc, 'this sender/server/name tuple belongs to an earlier SearchBot query');
            return;
        }
        if ($SEARCHBOT{active} && handle_searchbot_result_offer($dcc)) {
            return;
        }
    }
    return if decline_cancelled_reoffer($dcc);
    servers_note_offer($dcc) unless $S{active} && same_dcc_peer($dcc);
    return unless $S{active};
    return unless $S{trigger_dispatching} || $S{trigger_dispatched};
    log_line('DCC_REQUEST', dcc_desc($dcc));
    return unless same_dcc_peer($dcc);

    my $type = uc($dcc->{type} // '');
    if ($type eq 'CHAT' && $S{chat_authorization_revoked}) {
        p('Refusing a new DCC CHAT after the original CHAT closed; only its already-authorized file offer or transfer may continue.');
        log_line('DCC_CHAT_REFUSED', 'replacement CHAT cannot resume navigation after original CHAT authorization was revoked');
        my $closed = ref($dcc) && eval { $dcc->destroy(); 1 };
        unless ($closed) {
            my $chat_id = $dcc->{id};
            $closed = eval {
                Irssi::command('DCC CLOSE CHAT ' . $chat_id);
                1;
            } if defined($chat_id) && length("$chat_id");
        }
        p('Could not close the refused replacement DCC CHAT locally.') unless $closed;
        Irssi::signal_stop();
        return;
    }
    if ($type eq 'CHAT' && !$S{chat_identity_key} && !$S{chat_connected}) {
        my $key = dcc_chat_identity_key($dcc);
        unless ($key) {
            p('Refusing DCC CHAT: Irssi did not provide enough lifecycle identity to bind this request safely.');
            log_line('DCC_CHAT_REFUSED', 'missing CHAT id, creation time, peer address, or port');
            return;
        }
        if ($USED_CHAT_IDENTITIES{$key}++) {
            p('Refusing DCC CHAT with a previously used lifecycle identity.');
            log_line('DCC_CHAT_REFUSED', 'reused CHAT lifecycle identity');
            return;
        }
        my $server = $dcc->{server};
        unless ($server) {
            p('Refusing DCC CHAT without its originating IRC server context.');
            log_line('DCC_CHAT_REFUSED', 'missing server context');
            return;
        }

        if (untaken_send_offer_on_port($dcc)) {
            p('Refusing DCC CHAT: the file server still has an untaken file offer open on the same address and port.');
            log_line('DCC_CHAT_REFUSED', 'an untaken file offer may still be waiting on this address and port');
            eval { $dcc->destroy(); 1 };
            Irssi::signal_stop();
            abandon_untrusted_chat('the file server is still offering a file on the port it ' .
                'gave for this session, so connecting could start that transfer instead; ' .
                'wait a few minutes and search again', 'session_port_in_use');
            return;
        }
        $S{chat_identity_key} = $key;
        $S{chat_id} = $dcc->{id};
        $S{chat_dcc} = $dcc;
        delete @S{qw(chat_not_text chat_lines_before_prompt chat_socket chat_backlog_fd
            chat_held_bytes chat_held_lines chat_busy chat_entered_at chat_left_at
            chat_entered_work chat_left_work
            chat_listing_entries chat_listing_others chat_line_kind)};
        $S{chat_request_identity} = $key;
        $S{phase} = 'connecting_chat';
        p("Accepting expected DCC CHAT from $S{nick}.");
        my %had = reverse %{ process_sockets() };
        $server->command('DCC CHAT ' . $dcc->{nick});
        # Irssi opened the CHAT's socket in that command. Its number is kept
        # for chat_socket_descriptor.
        my @opened = grep { !exists $had{$_} } values %{ process_sockets() };
        $S{chat_socket} = $opened[0]
            if @opened == 1 && ($S{chat_identity_key} // '') eq $key;
        return;
    }

    # Incoming DCC SEND is represented as GET on our side in Irssi.
    if ($type eq 'GET') {
        my $offered = $dcc->{arg} // '';

        # This is a dedicated crawler client: if we did not explicitly ask for
        # a file, actively reject the offer instead of leaving the sender's
        # pending SEND socket around until timeout.
        unless ($S{pending_download}) {
            reject_dcc_get($dcc, 'unsolicited-no-pending-download', 0);
            return;
        }

        # Once an offer is bound, any later SEND is an extra offer. Reject it
        # without applying the now-consumed offer deadline to the live transfer.
        if ($S{pending_download}{accepted_transfer_key}) {
            reject_dcc_get($dcc, 'transfer-already-bound-to-request', 0);
            return;
        }

        unless ($S{pending_download}{request_sent}) {
            reject_dcc_get($dcc, 'send-arrived-before-verified-get-request', 0);
            return;
        }

        my $phase6_job_id = $S{pending_download}{phase6_job_id};
        if (defined($phase6_job_id)) {
            my $available = jobs_ready();
            my $job = $available ? $JOBS{coordinator}->job($phase6_job_id) : undef;
            my $wait_state = $job
                ? offer_wait_state($job, $dcc->{server}) : 'unbound';
            if ($wait_state eq 'expired' || $wait_state eq 'unbound') {
                cancel_wait_timer($phase6_job_id);
                if ($job && ($job->{state} eq 'awaiting_offer' ||
                        $job->{state} eq 'remote_queued')) {
                    job_transition($phase6_job_id,
                        $wait_state eq 'expired' ? 'expired' : 'needs_attention',
                        outcome => $wait_state eq 'expired'
                            ? 'late_dcc_offer_after_deadline'
                            : 'dcc_offer_wait_binding_unavailable',
                        reason => $wait_state eq 'expired'
                            ? 'matching DCC offer arrived after the absolute offer/queue deadline'
                            : 'matching DCC offer had no current job, connection, or bounded wait binding');
                }
                if ($wait_state eq 'unbound' && $JOBS{run_batch} &&
                        ($JOBS{run_batch}{current_job_id} // '') eq $phase6_job_id) {
                    $JOBS{run_batch}{paused_for_attention} = 1;
                    $JOBS{run_batch}{current_job_id} = undef;
                    $JOBS{paused} = 1;
                }
                reject_dcc_get($dcc,
                    $wait_state eq 'expired'
                        ? 'matching DCC SEND arrived after the captured absolute deadline'
                        : 'the offer wait is not bound to this live job and connection', 1);
                stop_session(1);
                delete $JOBS{active_job_id}
                    if ($JOBS{active_job_id} // '') eq $phase6_job_id;
                return;
            }
        }

        my $want = $S{pending_download}{name} // '';
        my ($match_mode, $matches) = dcc_filename_match(
            $offered,
            $want,
            $S{pending_download}{parent} // ''
        );

        if ($matches) {
            if ($match_mode eq 'space-to-underscore') {
                p("Accepting expected DCC SEND using legacy space->underscore filename mapping: offered=[$offered], expected=[$want]");
                log_line('DCC_FILENAME_ALIAS', "mode=$match_mode offered=[$offered] expected=[$want]");
            } else {
                p("Accepting expected DCC SEND: $offered");
            }

            # Remember the exact DCC-side name so completion can be matched
            # against what Irssi actually received, while retaining the
            # original catalog filename separately.
            my $key = dcc_transfer_identity_key($dcc);
            unless ($key) {
                reject_dcc_get($dcc, 'missing-transfer-lifecycle-identity', 0);
                return;
            }
            if ($USED_TRANSFER_IDENTITIES{$key}++) {
                if (my $existing = $TRANSFERS{$key}) {
                    $existing->{ambiguous_identity} = 1;
                }
                reject_dcc_get($dcc, 'reused-transfer-lifecycle-identity', 0);
                return;
            }
            if ($TRANSFERS{$key}) {
                $TRANSFERS{$key}{ambiguous_identity} = 1;
                reject_dcc_get($dcc, 'duplicate-transfer-lifecycle-identity', 0);
                return;
            }

            my $file = $S{pending_download};
            $file->{dcc_offered_name} = $offered;
            $file->{dcc_match_mode} = $match_mode;

            unless (prepare_download_staging($file)) {
                reject_dcc_get($dcc, 'download-staging-unavailable', 1);
                return;
            }

            my $server = $dcc->{server};
            unless ($server) {
                reject_dcc_get($dcc, 'missing-server-context', 1);
                return;
            }
            my $job_id = $file->{phase6_job_id};
            unless (offer_belongs_to_job($job_id, $server, $dcc->{nick}, $offered)) {
                reject_dcc_get($dcc, 'persistent-dcc-tuple-not-owned-by-pending-job', 0);
                return;
            }
            my $bound = eval {
                $JOBS{coordinator}->accept_offer($job_id,
                    accepted_lifecycle => $key, offered_basename => $offered);
                1;
            };
            unless ($bound) {
                reject_dcc_get($dcc, 'durable-job-could-not-bind-dcc-lifecycle', 0);
                return;
            }
            cancel_wait_timer($job_id);

            my $transfer = {
                key          => $key,
                phase6_job_id => $job_id,
                server_identity => server_connection_identity($server),
                connection_epoch => server_connection_epoch($server),
                generation   => $S{generation},
                request_token=> $file->{request_token},
                file         => $file,
                dcc          => $dcc,
                server       => $server,
                nick         => $dcc->{nick},
                tag          => dcc_tag($dcc),
                offered_name => $offered,
                state        => 'accepting',
                log_file     => $S{log_file},
            };
            $file->{accepted_transfer_key} = $key;
            $TRANSFERS{$key} = $transfer;
            $DOWNLOAD_PATH_OWNER = {
                key        => $key,
                generation => $S{generation},
                request_token => $file->{request_token},
                restore_to => $S{download_dir},
                path_selected => 0,
            };

            my $accepted = eval {
                $server->command('DCC GET ' . $dcc->{nick} . ' ' . quote_irssi_arg($offered));
                1;
            };
            unless ($accepted) {
                job_transition($job_id, 'needs_attention', outcome => 'dcc_acceptance_outcome_unknown',
                    reason => 'native DCC GET acceptance failed after the offer was bound');
                delete $TRANSFERS{$key};
                delete $file->{accepted_transfer_key};
                release_download_path_owner($transfer);
                reject_dcc_get($dcc, 'could-not-issue-acceptance-command', 1);
                return;
            }
            log_line('DCC_GET_BOUND', "request=$file->{request_token} key=$key offered=[$offered]");
        } elsif ($match_mode eq 'ambiguous-space-to-underscore') {
            p("Rejecting ambiguous legacy DCC filename alias: offered=[$offered], expected=[$want]. A distinct file with the offered name exists in the same directory.");
            log_line('DCC_FILENAME_AMBIGUOUS', "offered=[$offered] expected=[$want]");
            # This offer is the server's response to our request, but cannot be
            # mapped safely. Reject it and clear the pending request so the
            # crawler is immediately usable again.
            reject_dcc_get($dcc, 'ambiguous-space-to-underscore', 1);
        } else {
            p("Rejecting DCC SEND from expected nick because filename did not match: offered=[$offered], expected=[$want]");
            # Reject the unrelated offer but retain our pending request in case
            # the legitimate expected SEND follows afterwards.
            reject_dcc_get($dcc, 'filename-mismatch', 0);
        }
    }
}

sub sig_dcc_connected {
    my ($dcc) = @_;
    if (ref($dcc) && uc($dcc->{type} // '') eq 'GET') {
        my $port_key = send_offer_port_key($dcc);
        delete $UNTAKEN_SEND_OFFERS{$port_key} if defined $port_key;
        my $key = dcc_transfer_identity_key($dcc);
        my $transfer = defined($key) ? $TRANSFERS{$key} : undef;
        capture_transfer_receive_identity($transfer, $dcc)
            if $transfer && !$transfer->{ambiguous_identity};
    }
    return unless $S{active} && same_dcc_peer($dcc);
    log_line('DCC_CONNECTED', dcc_desc($dcc));
    my $type = uc($dcc->{type} // '');

    if ($type eq 'CHAT') {
        return unless same_chat($dcc);
        return if $S{chat_connected};
        $S{chat_connected} = 1;
        $S{chat_id} = $dcc->{id};
        $S{chat_dcc} = $dcc;
        $S{phase} = 'await_prompt';
        my $recovery = $JOBS{pre_dispatch_recovery};
        if ($recovery &&
                ($S{pre_dispatch_recovery_id} || 0) == $recovery->{id}) {
            my $recorded = eval {
                $JOBS{coordinator}->record_event(
                    'pre_dispatch_recovery_chat_established', {
                        job_id => $recovery->{job_id},
                        recovery_id => $recovery->{id},
                        attempt => $recovery->{attempts},
                        connection_identity => $recovery->{connection_identity},
                        connection_epoch => $recovery->{connection_epoch},
                        chat_identity => $S{chat_identity_key},
                        established_monotonic => monotonic_now(),
                    });
                1;
            };
            unless ($recorded) {
                finish_pre_dispatch_recovery(
                    'fresh CHAT was not durably recorded',
                    needs_attention => 1, release_lease => 1,
                    outcome => 'pre_dispatch_recovery_journal_failure');
                p('Fresh CHAT recovery stopped because its lifecycle could not be recorded.');
                stop_session(1);
                return;
            }
            $recovery->{attempt_chat_established} = 1;
        }
        p("DCC CHAT connected (id=$S{chat_id}); waiting briefly for FServe root prompt.");
        my $ms = Irssi::settings_get_int('fscrawl_initial_prompt_timeout_ms') || 2500;
        my $generation = $S{generation};
        my $chat_key = $S{chat_identity_key};
        my $token = ++$S{initial_prompt_token};
        $S{initial_prompt_timer} = schedule_session_timer(
            $ms,
            sub { initial_prompt_fallback($generation, $token, $chat_key) },
            sub {
                chat_session_is_current($generation, $chat_key) &&
                    ($S{initial_prompt_token} || 0) == $token &&
                    ($S{phase} // '') eq 'await_prompt'
            },
        );
    }
}

sub sig_dcc_get_receive {
    my ($dcc) = @_;
    my $key = dcc_transfer_identity_key($dcc);
    my $transfer = defined($key) ? $TRANSFERS{$key} : undef;
    return unless $transfer;
    return if $transfer->{ambiguous_identity};
    $transfer->{receive_seen} = 1;
    if (($transfer->{kind} // '') eq 'searchbot_content') {
        return unless ($SEARCHBOT_DIRECT{request_id} // '') eq ($transfer->{request_id} // '') &&
            ($SEARCHBOT_DIRECT{accepted_dcc_identity} // '') eq $key &&
            ($SEARCHBOT_DIRECT{state} // '') =~ /\A(?:accepting|receiving)\z/;
        # An offer matched by its space-to-underscore alias is staged under it.
        my $accepted = ($transfer->{file}{dcc_match_mode} // '') eq 'space-to-underscore'
            ? $transfer->{offered_name} : undef;
        my $target = staged_download_target($transfer->{file}, $dcc, $accepted);
        unless (defined $target) {
            $transfer->{direct_source_invalid} = 1;
            log_to_path($transfer->{log_file}, 'CONTENT_SOURCE_REFUSED',
                'request=' . $transfer->{request_id} . ' receive target has an unsafe name, parent, or file type');
            return;
        }
        my @target_stat = lstat($target);
        if (defined($transfer->{receive_source}) &&
                $transfer->{receive_source} ne $target) {
            $transfer->{direct_source_invalid} = 1;
        } elsif (!defined($transfer->{receive_source})) {
            $transfer->{receive_source} = $target;
            $transfer->{dcc_file} = $target;
        }
        if (@target_stat) {
            if (!-f _ || -l $target ||
                    (defined($transfer->{receive_dev}) &&
                     ($transfer->{receive_dev} != $target_stat[0] ||
                      $transfer->{receive_ino} != $target_stat[1]))) {
                $transfer->{direct_source_invalid} = 1;
            } elsif (!defined($transfer->{receive_dev})) {
                $transfer->{receive_dev} = $target_stat[0];
                $transfer->{receive_ino} = $target_stat[1];
            }
        } elsif (defined $transfer->{receive_dev}) {
            $transfer->{direct_source_invalid} = 1;
        }
        if ($transfer->{direct_source_invalid}) {
            log_to_path($transfer->{log_file}, 'CONTENT_SOURCE_CHANGED',
                'request=' . $transfer->{request_id} . ' DCC source path or file identity changed during receive');
            return;
        }
    } else {
        $transfer->{dcc_file} = $dcc->{file};
        my $target = $dcc->{file};
        if (defined($target) && length($target)) {
            if (defined($transfer->{receive_source}) &&
                    $transfer->{receive_source} ne $target) {
                $transfer->{partial_source_invalid} = 1;
            } else {
                $transfer->{receive_source} //= $target;
            }
            my @target_stat = lstat($target);
            if (@target_stat) {
                if (!S_ISREG($target_stat[2]) || S_ISLNK($target_stat[2]) ||
                        (defined($transfer->{receive_dev}) &&
                         ($transfer->{receive_dev} != $target_stat[0] ||
                          $transfer->{receive_ino} != $target_stat[1]))) {
                    $transfer->{partial_source_invalid} = 1;
                } elsif (!defined($transfer->{receive_dev})) {
                    $transfer->{receive_dev} = $target_stat[0];
                    $transfer->{receive_ino} = $target_stat[1];
                }
            } elsif (defined($transfer->{receive_dev})) {
                $transfer->{partial_source_invalid} = 1;
            }
        }
    }
    $transfer->{state} = 'receiving';
    if (($transfer->{kind} // '') eq 'searchbot_content') {
        $SEARCHBOT_DIRECT{state} = 'receiving';
    }
    log_to_path($transfer->{log_file}, 'DCC_GET_RECEIVE', dcc_desc($dcc));
    p('DCC receive starting: ' . ($dcc->{file} || $dcc->{arg} || 'unknown file'));
    release_download_path_owner($transfer);
}

# A DCC that never connected (2026-10-29): the sender offered an address and
# port that did not answer, so not a byte came. Another IRC client fails the
# same way; asking again gets the same address.
sub dcc_unreached_reason {
    my ($transfer, $received) = @_;
    return undef if $transfer->{receive_seen} || ($received // 0) > 0;
    return 'could not connect to the address the sender offered for the file, so nothing ' .
        'was received; the sender\'s side did not answer';
}

sub finish_transfer {
    my ($dcc, $reason, %finish_meta) = @_;
    my $key = dcc_transfer_identity_key($dcc);
    my $stored_transfer = defined($key) ? $TRANSFERS{$key} : undef;
    return unless $stored_transfer;
    my %transfer_snapshot = (%$stored_transfer, dcc => $dcc);
    my $transfer = \%transfer_snapshot;
    if ($transfer->{ambiguous_identity}) {
        log_to_path($transfer->{log_file}, 'DCC_TRANSFER_AMBIGUOUS', dcc_desc($dcc));
        return;
    }

    if (ref($stored_transfer->{stop_intent}) eq 'HASH') {
        return unless $finish_meta{writer_closed};
        $stored_transfer->{stop_intent}{writer_closed} = 1;
        delete $stored_transfer->{stop_intent}{close_pending};
        my %stopped = (%$stored_transfer, _binding => $stored_transfer,
            dcc => $dcc);
        $stopped{stop_intent} = { %{$stored_transfer->{stop_intent}},
            writer_closed => 1 };
        return finish_stopped_transfer(\%stopped, $dcc);
    }

    if (($transfer->{kind} // '') eq 'searchbot_content') {
        delete $TRANSFERS{$key};
        release_download_path_owner($transfer);
        my %transfer_snapshot = (%$transfer,
            dcc => $dcc,
            writer_closed => $finish_meta{writer_closed} ? 1 : 0);
        finish_searchbot_content_transfer(\%transfer_snapshot, $dcc, $reason);
        return;
    }

    # Remove the binding before any file or setting operation so duplicate or
    # reentrant close/error delivery cannot finalize the same request twice.
    delete $TRANSFERS{$key};
    release_download_path_owner($transfer);

    my $file = $transfer->{file};
    release_pending_manifest_lease($file);
    my $arg = $dcc->{arg} // '';
    my $size = $dcc->{size} // 0;
    my $done = $dcc->{transfd} // 0;
    my $complete = $reason ne 'error' &&
        (($size == 0 && $transfer->{receive_seen}) || ($size > 0 && $done >= $size));
    if (($transfer->{kind} // '') eq 'searchbot') {
        finish_searchbot_transfer($transfer, $dcc, $reason, $complete,
            $finish_meta{writer_closed});
        return;
    }
    my $destination;

    if ($complete) {
        $destination = finalize_download($file, $dcc);
        if ($destination) {
            p("Download completed: $arg ($done bytes) -> $destination");
        } elsif ($file->{phase6_published_unrecorded}) {
            my $evidence = $file->{phase6_published_unrecorded};
            p("File was published to $evidence->{destination_path}, but durable completion could not be recorded. Staging evidence remains at $evidence->{staging_path}; the job queue is paused for recovery.");
        } else {
            job_transition($transfer->{phase6_job_id}, 'needs_attention',
                outcome => 'safe_finalization_failed')
                if $transfer->{phase6_job_id};
            p("Transfer completed: $arg ($done bytes), but safe finalization failed; check staging directory " . ($file->{staging_dir} // '(unknown)') . '.');
        }
        log_to_path(
            $transfer->{log_file},
            'DOWNLOAD_COMPLETE',
            "$arg bytes=$done destination=[" . ($destination // 'staged') . "] requested=[" .
                ($file->{name} // '') . "] match=" . ($file->{dcc_match_mode} // 'unknown'),
        );
    } else {
        my $partial_path = $transfer->{dcc_file} // $dcc->{file} // '';
        my $partial_size = length($partial_path) && -f $partial_path ? -s $partial_path : $done;
        mark_interrupted($transfer->{phase6_job_id},
            path => $partial_path, size => $partial_size,
            partial_receive_metadata($transfer),
            staging_root => $file->{staging_dir}, total_size => $size,
            writer_closed => $finish_meta{writer_closed} ? 1 : 0,
            offered_basename => $transfer->{offered_name},
            reason => dcc_unreached_reason($transfer, $done) //
                ($reason eq 'error' ? 'native DCC transfer error' : 'native DCC transfer closed early'))
            if $transfer->{phase6_job_id};
        p("Download closed before confirmed completion: $arg ($done/$size bytes); partial data remains in " . ($file->{staging_dir} // '(unknown)') . '.');
        log_to_path($transfer->{log_file}, $reason eq 'error' ? 'DOWNLOAD_ERROR' : 'DOWNLOAD_INCOMPLETE', "$arg bytes=$done/$size");
    }

    if (session_is_current($transfer->{generation}) && $S{pending_download} &&
        ($S{pending_download}{request_token} || 0) == $transfer->{request_token}) {
        my $web_operation_id = $S{pending_download}{web_operation_id};
        my $close_web_session = defined($web_operation_id) &&
            $web_operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
        $S{pending_download} = undef;
        $S{phase} = $complete ? 'complete' : 'error';
        restore_download_path_to_base() unless $DOWNLOAD_PATH_OWNER;
        # The browser owns one direct fetch, not an interactive FServe CHAT
        # session. Close the idle session after this DCC transfer settles so
        # the next web search/download or source disconnect is not blocked.
        stop_session(1) if $close_web_session;
    }
}

sub sig_dcc_closed {
    my ($dcc) = @_;
    my $type = uc($dcc->{type} // '');

    if ($type eq 'CHAT') {
        return unless same_chat($dcc);
        log_line('DCC_CLOSED', dcc_desc($dcc));
        if ($S{chat_not_text} && !session_transfer_count()) {
            # The session was given up as not an FServe's, and its CHAT has
            # closed before the timer that stops it (abandon_untrusted_chat)
            # has run: that is what cutting its socket does. It ends as the
            # timer ends it; there is no CHAT left to close.
            $S{chat_connected} = 0;
            $S{chat_dcc} = undef;
            stop_session(1);
            return;
        }
        invalidate_session_after_chat_close($dcc);
    } elsif ($type eq 'GET') {
        # Irssi emits dcc closed immediately before destroying the DCC record.
        # The cooperative sealer runs on a later main-loop tick, after that
        # synchronous native close stack has returned.
        finish_transfer($dcc, 'closed', writer_closed => 1);
    }
}

sub sig_dcc_error {
    my ($dcc) = @_;
    if (ref($dcc) && uc($dcc->{type} // '') eq 'GET') {
        my $key = dcc_transfer_identity_key($dcc);
        if (defined($key) && $TRANSFERS{$key}) {
            # Irssi emits dcc error before dcc_destroy closes the GET file
            # descriptor. Finalize from our later dcc destroyed hook instead.
            $TRANSFERS{$key}{native_error} = 1;
            return;
        }
    }
    if ($S{active} && ref($dcc) && same_dcc_peer($dcc)) {
        log_line('DCC_ERROR', dcc_desc($dcc));
        p('DCC error: ' . dcc_desc($dcc));
    }
    # The session a direct fetch was offered could not be connected to (its
    # address refused, as one file server's did on 2026-10-20). Without this the
    # fetch waited with no end. It is not tried again (the owner's decision
    # of 2026-10-22): the same address would refuse again.
    if (ref($dcc) && uc($dcc->{type} // '') eq 'CHAT' && $S{active} && $S{direct_fetch} &&
            !$S{chat_connected} && same_chat($dcc)) {
        my $why = 'the file server offered a session, but connecting to it failed (its ' .
            'address refused or did not answer); nothing was asked for, and the trigger ' .
            'was not sent again';
        log_line('SESSION_UNREACHABLE', $why);
        abandon_untrusted_chat($why, 'session_unreachable');
    }
}

sub sig_dcc_destroyed {
    my ($dcc) = @_;
    return unless ref($dcc) && uc($dcc->{type} // '') eq 'GET';
    my $key = dcc_transfer_identity_key($dcc);
    my $guard = $JOBS{native_resume_guard};
    my $owner = $guard ? $guard->owner() : undef;
    my $guard_owns_lifecycle = defined($key) && $owner &&
        ($owner->{native_lifecycle_identity} // '') eq $key;
    my $transfer = defined($key) ? $TRANSFERS{$key} : undef;
    return if $transfer && $transfer->{suppress_destroy_finalize};
    if ($transfer) {
        my $reason = $transfer->{native_error} ? 'error' : 'closed';
        # Irssi's DCC GET destruction callback closes fhandle on this native
        # teardown path. Our async digest timer runs after this stack returns.
        finish_transfer($dcc, $reason, writer_closed => 1);
    }
    # A native resume reservation can precede creation of a receive binding.
    # Destruction must settle that owner too; dcc closed is not guaranteed.
    resume_guard_release_if_owned($key, 1)
        if $guard_owns_lifecycle;
}

1;
