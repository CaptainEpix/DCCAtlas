# Search bots: their result lists, and files asked for by posting a row.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();

our (%LIST_RETRY_OK, %JOBS, %S, %SEARCHBOT, %SEARCHBOT_CONTENT_TOMBSTONES,
     %SEARCHBOT_DIRECT, %SEARCHBOT_MODULES, %SEARCHBOT_USED_OFFERS, %TRANSFERS,
     %USED_TRANSFER_IDENTITIES, %WEB_BRIDGE, $DOWNLOAD_PATH_OWNER,
     $SEARCHBOT_DIRECT_SEQUENCE, $SEARCHBOT_SEQUENCE, $SESSION_GENERATION,
     $old_dcc_download_path);

my $SEARCHBOT_TOMBSTONE_LIMIT = 1000;
my $SEARCHBOT_CONTENT_TOMBSTONE_LIMIT = 1000;

sub searchbot_direct_active {
    return 0 unless %SEARCHBOT_DIRECT;
    return ($SEARCHBOT_DIRECT{state} // '') =~
        /\A(?:dispatch_pending|dispatching|awaiting_offer|accepting|receiving)\z/ ? 1 : 0;
}

sub searchbot_nick_is_safe {
    my ($nick) = @_;
    return defined($nick) &&
        $nick =~ /\A[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,63}\z/;
}

sub configured_searchbot_content_limit {
    my $value = Irssi::settings_get_int('fscrawl_searchbot_max_content_bytes');
    return unless defined($value) && $value > 0 && $value <= 1024 * 1024 * 1024;
    return 0 + $value;
}

sub searchbot_offer_tombstone_key {
    my ($server_tag, $nick, $filename) = @_;
    return unless defined($server_tag) && length($server_tag) &&
        defined($nick) && length($nick) &&
        defined($filename) && length($filename);
    # Peer identity follows IRC casemapping in searchbot_tombstone_used();
    # preserve filename case because archive offer matching is exact.
    return join("\0", lc($server_tag), lc($nick), $filename);
}

sub searchbot_tombstone_used {
    my ($map, $server, $server_tag, $nick, $filename) = @_;
    return 0 unless ref($map) eq 'HASH';
    for my $entry (values %$map) {
        return 1 if FServe::Discovery::SearchBotRequest::tombstone_matches(
            $server, $server_tag, $nick, $filename, $entry);
    }
    return 0;
}

sub searchbot_tombstone_record {
    my ($server_tag, $sender, $filename, $identity, $casemapping) = @_;
    return {
        identity => $identity, server_tag => $server_tag,
        sender => $sender, filename => $filename, casemapping => $casemapping,
    };
}

sub reject_searchbot_offer {
    my ($dcc, $reason) = @_;
    my ($offered, $nick, $server) = ref($dcc)
        ? ($dcc->{arg} // '', $dcc->{nick} // '', $dcc->{server})
        : ('', '', undef);
    my $closed = ref($dcc) && eval { $dcc->destroy(); 1 };
    unless ($closed) {
        $closed = eval {
            $server->command('DCC CLOSE GET ' . $nick . ' ' . quote_irssi_arg($offered));
            1;
        } if $server && length($nick) && length($offered);
    }
    p("Rejected SearchBot DCC result offer: $reason") if $closed;
    p("Could not close rejected SearchBot DCC result offer: $reason") unless $closed;
    # The DCC record has been destroyed (or explicitly closed). Prevent later
    # native handlers from continuing dispatch with that same request object.
    Irssi::signal_stop();
}

sub handle_searchbot_result_offer {
    my ($dcc) = @_;
    return 0 unless ref($dcc) && uc($dcc->{type} // '') eq 'GET';
    return 0 unless $SEARCHBOT{active};

    my $expected_peer = FServe::DccPolicy::same_peer(
        $dcc, $SEARCHBOT{expected_nick}, $SEARCHBOT{server_tag}
    );
    return 0 unless $expected_peer;

    my $offer = FServe::Discovery::SearchBotOffer::match_result_offer(
        $dcc,
        state              => $SEARCHBOT{state},
        collection_id      => $SEARCHBOT{collection_id},
        expected_nick      => $SEARCHBOT{expected_nick},
        server_tag         => $SEARCHBOT{server_tag},
        expected_filename  => $SEARCHBOT{expected_filename},
        query              => $SEARCHBOT{query},
        expires_at         => $SEARCHBOT{expires_at},
    );
    if (($offer->{type} // '') ne 'matched') {
        reject_searchbot_offer($dcc, $offer->{reason} // 'offer did not match the active result request');
        return 1;
    }

    if ($DOWNLOAD_PATH_OWNER || has_active_download_transfer() || $S{active}) {
        reject_searchbot_offer($dcc, 'another transfer or FServe session owns the DCC download path');
        return 1;
    }
    my $key = dcc_transfer_identity_key($dcc);
    unless ($key) {
        reject_searchbot_offer($dcc, 'missing DCC lifecycle identity');
        return 1;
    }
    if ($USED_TRANSFER_IDENTITIES{$key}++ || $TRANSFERS{$key}) {
        $TRANSFERS{$key}{ambiguous_identity} = 1 if $TRANSFERS{$key};
        reject_searchbot_offer($dcc, 'reused DCC lifecycle identity');
        return 1;
    }
    my $server = $dcc->{server};
    unless ($server) {
        reject_searchbot_offer($dcc, 'missing originating IRC server context');
        return 1;
    }
    unless (server_connection_identity($server) eq ($SEARCHBOT{server_identity} // '') &&
            server_connection_epoch($server) == ($SEARCHBOT{connection_epoch} || 0)) {
        reject_searchbot_offer($dcc, 'result offer is from a different IRC connection epoch');
        return 1;
    }
    unless (offer_belongs_to_job($SEARCHBOT{phase6_job_id}, $server,
            $dcc->{nick}, $offer->{filename})) {
        reject_searchbot_offer($dcc, 'persistent result ZIP tuple is not owned by this query');
        return 1;
    }
    my $bound = eval {
        $JOBS{coordinator}->accept_offer($SEARCHBOT{phase6_job_id},
            accepted_lifecycle => $key, offered_basename => $offer->{filename});
        1;
    };
    unless ($bound) {
        reject_searchbot_offer($dcc, 'durable job could not bind this result ZIP DCC lifecycle');
        return 1;
    }

    my $file = {
        type => 'file',
        path => '/SearchBot results/' . $offer->{filename},
        parent => '/SearchBot results',
        name => $offer->{filename},
        network_id => $SEARCHBOT{network_id},
        (defined($SEARCHBOT{web_destination_network})
            ? (destination_network => $SEARCHBOT{web_destination_network}) : ()),
        server_nick => $SEARCHBOT{expected_nick},
        trigger_raw => '@search',
        trigger_mode => 'channel_text',
        download_dir => lists_dir(),
        replace_same_name => 1,
        request_token => $SEARCHBOT{query_id},
        searchbot_collection_id => $SEARCHBOT{collection_id},
        phase6_job_id => $SEARCHBOT{phase6_job_id},
    };
    unless (prepare_download_staging($file)) {
        reject_searchbot_offer($dcc, 'could not create a dedicated staging directory');
        return 1;
    }

    my $transfer = {
        kind          => 'searchbot',
        phase6_job_id => $SEARCHBOT{phase6_job_id},
        server_identity => server_connection_identity($server),
        connection_epoch => server_connection_epoch($server),
        key           => $key,
        generation    => $SESSION_GENERATION,
        request_token => $SEARCHBOT{query_id},
        collection_id => $SEARCHBOT{collection_id},
        expected_size => $offer->{size_bytes},
        file          => $file,
        dcc           => $dcc,
        server        => $server,
        nick          => $dcc->{nick},
        tag           => dcc_tag($dcc),
        offered_name  => $offer->{filename},
        state         => 'accepting',
    };
    $file->{accepted_transfer_key} = $key;
    $TRANSFERS{$key} = $transfer;
    $DOWNLOAD_PATH_OWNER = {
        key           => $key,
        generation    => $SESSION_GENERATION,
        request_token => $SEARCHBOT{query_id},
        restore_to    => $S{download_dir},
        path_selected => 0,
    };
    $SEARCHBOT{state} = 'receiving';
    $SEARCHBOT{result_transfer_key} = $key;

    my $transfer_timeout_ms = Irssi::settings_get_int('fscrawl_searchbot_transfer_timeout_ms') || 300000;
    $transfer_timeout_ms = 1000 if $transfer_timeout_ms < 1000;
    $transfer_timeout_ms = 1800000 if $transfer_timeout_ms > 1800000;
    clear_searchbot_timer();
    my $collection_id = $SEARCHBOT{collection_id};
    $SEARCHBOT{timer} = Irssi::timeout_add_once($transfer_timeout_ms, sub {
        expire_searchbot_transfer($collection_id, $key);
    }, undef);

    my $accepted = eval {
        $server->command('DCC GET ' . $dcc->{nick} . ' ' . quote_irssi_arg($offer->{filename}));
        1;
    };
    unless ($accepted) {
        job_transition($SEARCHBOT{phase6_job_id}, 'needs_attention',
            outcome => 'archive_acceptance_outcome_unknown');
        delete $TRANSFERS{$key};
        delete $file->{accepted_transfer_key};
        $SEARCHBOT{state} = 'awaiting_result';
        delete $SEARCHBOT{result_transfer_key};
        release_download_path_owner($transfer);
        my $remaining_ms = int((($SEARCHBOT{expires_at} // time()) - time()) * 1000);
        if ($remaining_ms > 0) {
            arm_searchbot_response_timeout($SEARCHBOT{collection_id}, $remaining_ms);
        } else {
            clear_searchbot_timer();
            expire_searchbot_query($SEARCHBOT{collection_id});
        }
        reject_searchbot_offer($dcc, 'could not issue DCC GET acceptance');
        return 1;
    }

    p("Accepting the one expected SearchBot result ZIP from $SEARCHBOT{expected_nick}; it will be parsed in bounded staging.");
    return 1;
}

sub reject_searchbot_content_offer {
    my ($dcc, $reason) = @_;
    my ($server, $nick, $offered) = ref($dcc)
        ? ($dcc->{server}, $dcc->{nick} // '', $dcc->{arg} // '')
        : (undef, '', '');
    my $safe_name = safe_field($offered);
    my $closed = ref($dcc) && eval { $dcc->destroy(); 1 };
    unless ($closed) {
        $closed = eval {
            $server->command('DCC CLOSE GET ' . $nick . ' ' . quote_irssi_arg($offered));
            1;
        } if $server && length($nick) && length($offered);
    }
    log_to_path($SEARCHBOT_DIRECT{log_path}, 'CONTENT_OFFER_REFUSED',
        'reason=' . escaped_searchbot_payload($reason) .
        ' sender=' . escaped_searchbot_payload($nick) .
        ' filename=[' . escaped_searchbot_payload($safe_name) . '] close=' . ($closed ? 'yes' : 'failed'));
    # Said in the page's Log too, so a file that never arrives says why.
    engine_log_add('engine', $server, "Turned down ${nick}'s offer of \"$safe_name\": $reason")
        if $server;
    p("Rejected SearchBot content DCC offer: $reason") if $closed;
    p("Could not close rejected SearchBot content DCC offer: $reason") unless $closed;
    # Do not let native signal handlers inspect the DCC object after close.
    Irssi::signal_stop();
}

sub expire_searchbot_direct_transfer {
    my ($request_id, $transfer_key) = @_;
    return unless ($SEARCHBOT_DIRECT{request_id} // '') eq ($request_id // '') &&
        ($SEARCHBOT_DIRECT{accepted_dcc_identity} // '') eq ($transfer_key // '') &&
        ($SEARCHBOT_DIRECT{state} // '') =~ /\A(?:accepting|receiving)\z/;
    my $transfer = $TRANSFERS{$transfer_key};
    clear_searchbot_direct_timer(\%SEARCHBOT_DIRECT);
    $SEARCHBOT_DIRECT{state} = 'transfer_expired';
    $SEARCHBOT_DIRECT{terminal_reason} = 'configured transfer deadline elapsed';
    list_transfer_failed(\%SEARCHBOT_DIRECT);
    log_to_path($SEARCHBOT_DIRECT{log_path}, 'CONTENT_TRANSFER_TIMEOUT',
        'request=' . $request_id . ' staging=[' . ($SEARCHBOT_DIRECT{staging_dir} // '') . ']');
    if ($transfer) {
        request_transfer_stop($transfer, {
            job_state => 'interrupted',
            job_outcome => 'transfer_expired',
            request_state => 'transfer_expired',
            reason => 'configured transfer deadline elapsed',
        });
    } else {
        searchbot_direct_release_path_owner(\%SEARCHBOT_DIRECT);
    }
    p('SearchBot content transfer deadline elapsed; any partial bytes remain in request staging.');
}

sub handle_searchbot_content_offer {
    my ($dcc) = @_;
    return 0 unless ref($dcc) && uc($dcc->{type} // '') eq 'GET' && searchbot_direct_active();
    my $request = \%SEARCHBOT_DIRECT;
    unless (($request->{state} // '') =~ /\A(?:dispatching|awaiting_offer)\z/ &&
            $request->{dispatch_attempted}) {
        reject_searchbot_content_offer($dcc, 'no direct request is currently awaiting an offer');
        return 1;
    }
    if (time() >= ($request->{offer_deadline} // 0)) {
        retire_searchbot_direct('expired', 'offer arrived after the deadline');
        reject_searchbot_content_offer($dcc, 'offer arrived after the request deadline');
        return 1;
    }
    my $decision = FServe::Discovery::SearchBotRequest::validate_content_offer(
        $dcc, $request, max_content_bytes => $request->{max_content_bytes});
    unless (($decision->{type} // '') eq 'matched') {
        reject_searchbot_content_offer($dcc, $decision->{reason} // 'offer did not match this request');
        return 1;
    }
    unless ($DOWNLOAD_PATH_OWNER &&
            ($DOWNLOAD_PATH_OWNER->{key} // '') eq ($request->{path_owner_key} // '') &&
            ($DOWNLOAD_PATH_OWNER->{request_id} // '') eq ($request->{request_id} // '') &&
            !has_active_download_transfer() && !$S{active}) {
        reject_searchbot_content_offer($dcc, 'shared DCC path/resource ownership changed');
        return 1;
    }
    unless ($request->{list_request}
            ? list_offer_belongs_to_job($request->{phase6_job_id}, $dcc->{server},
                $request->{any_sender} ? $request->{expected_sender} : $dcc->{nick},
                $decision->{filename}, $request->{any_sender} ? $dcc->{nick} : undef)
            : offer_belongs_to_job($request->{phase6_job_id}, $dcc->{server},
                $dcc->{nick}, $decision->{filename})) {
        reject_searchbot_content_offer($dcc, 'persistent DCC tuple reservation does not belong to this request');
        return 1;
    }
    # A list's name is known only now; from here it is checked and kept as a
    # posted row's file is (2026-10-27).
    if ($request->{list_request}) {
        $request->{expected_basename} = $decision->{filename};
        $request->{file}{name} = $decision->{filename};
    }
    my $key = dcc_transfer_identity_key($dcc);
    unless ($key && !$USED_TRANSFER_IDENTITIES{$key} && !$TRANSFERS{$key}) {
        reject_searchbot_content_offer($dcc, 'missing, reused, or already-bound DCC lifecycle identity');
        return 1;
    }
    my $server = $dcc->{server};
    unless ($server && server_connection_identity($server) eq ($request->{server_identity} // '')) {
        reject_searchbot_content_offer($dcc, 'offer lacks the original IRC server object');
        return 1;
    }
    my $bound = eval {
        $JOBS{coordinator}->accept_offer($request->{phase6_job_id},
            accepted_lifecycle => $key, offered_basename => $decision->{filename});
        1;
    };
    unless ($bound) {
        reject_searchbot_content_offer($dcc, 'durable job could not bind this DCC lifecycle');
        return 1;
    }

    my $transfer_ms = $request->{transfer_timeout_ms};
    clear_searchbot_direct_timer($request);
    my $request_id = $request->{request_id};
    my $timer;
    my $timer_ok = eval {
        $timer = Irssi::timeout_add_once($transfer_ms, sub {
            expire_searchbot_direct_transfer($request_id, $key);
        }, undef);
        defined $timer;
    };
    unless ($timer_ok) {
        retire_searchbot_direct('failed', 'transfer timer registration failed');
        reject_searchbot_content_offer($dcc, 'could not register a bounded transfer deadline');
        return 1;
    }
    $USED_TRANSFER_IDENTITIES{$key}++;
    my $file = $request->{file};
    $file->{expected_size} = $decision->{size_bytes};
    $file->{expected_sender} = $request->{expected_sender};
    $file->{actual_sender} = $dcc->{nick};
    $file->{actual_filename} = $decision->{filename};
    # Offered with underscores for its spaces: staged under that name, and
    # published under the one the row gave, as an FServe alias is.
    $file->{dcc_match_mode} = 'space-to-underscore'
        if $decision->{filename} ne ($request->{expected_basename} // '');
    my $transfer = {
        kind => 'searchbot_content', key => $key, request_id => $request_id,
        phase6_job_id => $request->{phase6_job_id},
        server_identity => server_connection_identity($server),
        connection_epoch => server_connection_epoch($server),
        collection_id => $request->{collection_id}, candidate_id => $request->{candidate_id},
        request_line_digest => $request->{request_line_digest},
        generation => undef, request_token => $request_id,
        expected_size => $decision->{size_bytes}, file => $file,
        dcc => $dcc, server => $server, nick => $dcc->{nick},
        tag => dcc_tag($dcc), offered_name => $decision->{filename},
        state => 'accepting', log_file => $request->{log_path},
    };
    $request->{accepted_dcc_identity} = $key;
    $request->{advertised_size} = $decision->{size_bytes};
    $request->{state} = 'accepting';
    $request->{timer} = $timer;
    $request->{path_owner_key} = $key;
    $DOWNLOAD_PATH_OWNER->{key} = $key;
    $DOWNLOAD_PATH_OWNER->{kind} = 'searchbot_content';
    $TRANSFERS{$key} = $transfer;
    log_to_path($request->{log_path}, 'CONTENT_OFFER_ACCEPTED',
        'request=' . $request_id . ' sender=' . safe_field($dcc->{nick}) .
        ' filename=[' . $decision->{filename} . '] advertised_bytes=' . $decision->{size_bytes});
    my $accepted = eval {
        $server->command('DCC GET ' . $dcc->{nick} . ' ' . quote_irssi_arg($decision->{filename}));
        1;
    };
    unless ($accepted) {
        delete $TRANSFERS{$key};
        release_download_path_owner($transfer);
        clear_searchbot_direct_timer($request);
        $request->{state} = 'failed';
        $request->{terminal_reason} = 'Irssi DCC acceptance command failed';
        reject_searchbot_content_offer($dcc, 'Irssi could not accept the matched DCC SEND');
        return 1;
    }
    p("Accepted exact SearchBot content DCC SEND from $dcc->{nick}" .
        (lc($dcc->{nick}) eq lc($request->{expected_sender}) ? ''
            : " for $request->{expected_sender}") .
        ": $decision->{filename} ($decision->{size_bytes} bytes advertised; result size hint is not authoritative).");
    return 1;
}

# What a search bot, or the nick a result row names, says in a notice while
# its reply is awaited. It is only kept, to be shown if nothing arrives:
# nothing is decided from it and no deadline changes.
sub sig_searchbot_notice {
    my ($server, $msg, $nick) = @_;
    return unless ref($server) && defined($nick);
    my $awaiting_list = $SEARCHBOT{active} &&
        ($SEARCHBOT{state} // '') eq 'awaiting_result';
    my $awaiting_file = ($SEARCHBOT_DIRECT{state} // '') =~ /\A(?:dispatching|awaiting_offer)\z/;
    return unless $awaiting_list || $awaiting_file;
    my $identity = server_connection_identity($server) // '';
    my $text = $msg // '';
    $text =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $text =~ s/[\x00-\x1f\x7f]//g;
    $text =~ s/\A\s+|\s+\z//g;
    return unless length $text;
    $text = substr($text, 0, 200);
    if ($awaiting_list && $identity eq ($SEARCHBOT{server_identity} // '') &&
            FServe::ConnectionIdentity::same_irc_identity(
                $nick, $SEARCHBOT{expected_nick},
                $SEARCHBOT{casemapping} // server_casemapping($server))) {
        $SEARCHBOT{bot_said} = $text;
    }
    if ($awaiting_file && $identity eq ($SEARCHBOT_DIRECT{server_identity} // '') &&
            FServe::ConnectionIdentity::same_irc_identity(
                $nick, $SEARCHBOT_DIRECT{expected_sender},
                $SEARCHBOT_DIRECT{casemapping} // server_casemapping($server))) {
        $SEARCHBOT_DIRECT{sender_said} = $text;
        searchbot_direct_note_queued($text);
    }
}

# A file server that queues a posted row says so in a notice naming the file,
# as XarShare and QRSN do: "I have added <file> as 1 in my queue". The wait
# for its offer then becomes that of a queued FServe request,
# fscrawl_queue_max_wait_ms (15 minutes), counted from the notice, and the
# job shows as queued on the server (2026-10-20). Nothing is sent because of
# it, and it happens once a request.
sub searchbot_direct_note_queued {
    my ($text) = @_;
    my $request = \%SEARCHBOT_DIRECT;
    return if $request->{remote_queued};
    return unless ($request->{state} // '') eq 'awaiting_offer' && defined $request->{timer};
    my $lower = lc($text // '');
    return unless $lower =~ /queue/ &&
        $lower !~ /\b(?:full|not|no longer|refused|denied|cannot|can't|unable|removed|cancel\w*)\b/;
    my @names = grep { defined && length } ($request->{expected_basename}, $request->{expected_alias});
    return unless grep { index($lower, lc $_) >= 0 } @names;
    return unless jobs_ready();
    my $job_id = $request->{phase6_job_id};
    my $job = $JOBS{coordinator}->job($job_id);
    return unless $job && ($job->{state} // '') eq 'awaiting_offer';
    my $wait_ms = bounded_timeout_setting('fscrawl_queue_max_wait_ms', 900000, 30000, 3600000);
    my $request_id = $request->{request_id};
    my $timer = eval { Irssi::timeout_add_once($wait_ms, sub {
        expire_searchbot_direct($request_id, 'awaiting_offer');
    }, undef) };
    return unless defined $timer;
    my $moved = eval {
        $JOBS{coordinator}->transition($job_id, 'remote_queued',
            outcome => 'correlated_remote_queue_ack',
            reason => 'file server queued the request: ' . safe_field($text),
            data => { remote_queue => { dialect => 'posted-row-notice', wait_ms => $wait_ms,
                absolute_deadline_monotonic => monotonic_now() + $wait_ms / 1000 } });
        1;
    };
    unless ($moved) {
        Irssi::timeout_remove($timer);
        return;
    }
    clear_searchbot_direct_timer($request);
    $request->{timer} = $timer;
    $request->{offer_deadline} = time() + $wait_ms / 1000;
    $request->{remote_queued} = 1;
    log_to_path($request->{log_path}, 'REQUEST_REMOTE_QUEUED',
        'request=' . $request_id . ' wait_ms=' . $wait_ms);
}

sub finish_searchbot_transfer {
    my ($transfer, $dcc, $reason, $transport_complete, $writer_closed) = @_;
    my $collection_id = $transfer->{collection_id};
    my $is_current = ($SEARCHBOT{collection_id} // '') eq ($collection_id // '') &&
        ($SEARCHBOT{state} // '') eq 'receiving';
    unless ($is_current) {
        p('Discarded a SearchBot transfer whose collection is no longer current; no rows were published.');
        restore_download_path();
        return;
    }

    my $expected_size = $transfer->{expected_size};
    my $declared_size = $dcc->{size} // 0;
    my $received_size = $dcc->{transfd} // 0;
    unless ($transport_complete && defined($expected_size) &&
            $declared_size == $expected_size && $received_size == $expected_size) {
        $SEARCHBOT{active} = 0;
        $SEARCHBOT{state} = 'incomplete';
        $SEARCHBOT{results} = [];
        clear_searchbot_timer();
        my $partial_path = $transfer->{dcc_file} // $dcc->{file} // '';
        my $partial_size = length($partial_path) && -f $partial_path ? -s $partial_path : $received_size;
        mark_interrupted($transfer->{phase6_job_id},
            path => $partial_path, size => $partial_size,
            partial_receive_metadata($transfer),
            staging_root => (($transfer->{file} && $transfer->{file}{staging_dir}) //
                $SEARCHBOT{staging_dir}), total_size => $expected_size,
            writer_closed => $writer_closed ? 1 : 0,
            offered_basename => $transfer->{offered_name}, reason => 'SearchBot ZIP transfer incomplete');
        p("SearchBot result transfer was incomplete ($received_size/$expected_size bytes); no candidates were published.");
        restore_download_path();
        return;
    }

    $SEARCHBOT{archive_source} = $transfer->{receive_source} //
        $transfer->{dcc_file} // $dcc->{file} // '';
    $SEARCHBOT{archive_file} = $transfer->{file};
    $SEARCHBOT{archive_dcc} = {
        file => $dcc->{file}, arg => $dcc->{arg}, size => $dcc->{size},
        transfd => $dcc->{transfd},
    };
    my $source = staged_download_source($transfer->{file}, $dcc);
    unless ($source && -f $source && !-l $source &&
            defined(-s $source) && -s $source == $expected_size) {
        $SEARCHBOT{active} = 0;
        $SEARCHBOT{state} = 'refused';
        $SEARCHBOT{results} = [];
        clear_searchbot_timer();
        retire_searchbot_archive_job('failed',
            'archive_source_verification_failed', 'completed archive failed exact staging verification');
        p('Completed SearchBot transfer was not the exact staged regular file; no candidates were published.');
        restore_download_path();
        return;
    }

    my $started = FServe::Discovery::SearchBotArchive::begin_archive(
        $source,
        network_id        => $SEARCHBOT{network_id},
        server_tag        => $SEARCHBOT{server_tag},
        discovery_channel => $SEARCHBOT{channel},
        query             => $SEARCHBOT{query},
        collection_id     => $collection_id,
        source_timestamp  => $SEARCHBOT{source_timestamp},
    );
    unless (($started->{type} // '') eq 'pending' && ref($started->{job}) eq 'HASH') {
        my $reason_text = $started->{reason} // 'archive validation could not start';
        $reason_text =~ s/[\r\n]+/ /g;
        $SEARCHBOT{active} = 0;
        $SEARCHBOT{state} = 'refused';
        $SEARCHBOT{results} = [];
        clear_searchbot_timer();
        retire_searchbot_archive_job('failed',
            'archive_parse_initialization_failed', $reason_text);
        p("SearchBot result archive refused: $reason_text. No candidates were published.");
        restore_download_path();
        return;
    }

    clear_searchbot_timer();
    $SEARCHBOT{active} = 1;
    $SEARCHBOT{state} = 'parsing';
    $SEARCHBOT{archive_job} = $started->{job};
    $SEARCHBOT{archive_source} = $source;
    $SEARCHBOT{archive_file} = $transfer->{file};
    $SEARCHBOT{archive_dcc} = {
        file => $dcc->{file}, arg => $dcc->{arg}, size => $dcc->{size},
        transfd => $dcc->{transfd},
    };
    my $parse_timeout_ms = Irssi::settings_get_int('fscrawl_searchbot_parse_timeout_ms') || 300000;
    $parse_timeout_ms = 10000 if $parse_timeout_ms < 10000;
    $parse_timeout_ms = 600000 if $parse_timeout_ms > 600000;
    $SEARCHBOT{timer} = Irssi::timeout_add_once($parse_timeout_ms, sub {
        expire_searchbot_parse($collection_id);
    }, undef);
    schedule_searchbot_archive_step($collection_id);
    restore_download_path();
}

sub clear_searchbot_parse_step_timer {
    my $timer = delete $SEARCHBOT{parse_step_timer};
    Irssi::timeout_remove($timer) if defined $timer;
}

sub schedule_searchbot_archive_step {
    my ($collection_id) = @_;
    clear_searchbot_parse_step_timer();
    my $timer;
    my $scheduled = eval {
        $timer = Irssi::timeout_add_once(10, sub {
            delete $SEARCHBOT{parse_step_timer};
            step_searchbot_archive($collection_id);
        }, undef);
        die 'timer API returned no handle' unless defined $timer;
        1;
    };
    unless ($scheduled) {
        my $error = $@ || 'timer API rejected the archive step';
        $error =~ s/[\r\n]+/ /g;
        abort_searchbot_collection(1);
        $SEARCHBOT{state} = 'refused';
        p("SearchBot archive processing could not be scheduled: $error. No rows were published.");
        return 0;
    }
    $SEARCHBOT{parse_step_timer} = $timer;
    return 1;
}

sub step_searchbot_archive {
    my ($collection_id) = @_;
    return unless ($SEARCHBOT{collection_id} // '') eq ($collection_id // '') &&
        ($SEARCHBOT{state} // '') eq 'parsing' && ref($SEARCHBOT{archive_job}) eq 'HASH';

    my $parsed = FServe::Discovery::SearchBotArchive::step_archive(
        $SEARCHBOT{archive_job}, max_lines => 128, max_read_bytes => 65536,
    );
    if (($parsed->{type} // '') eq 'pending') {
        schedule_searchbot_archive_step($collection_id);
        return;
    }
    clear_searchbot_timer();
    clear_searchbot_parse_step_timer();
    delete $SEARCHBOT{archive_job};
    unless (($parsed->{type} // '') eq 'complete' &&
            ($parsed->{collection_id} // '') eq $collection_id &&
            ref($parsed->{results}) eq 'ARRAY' && @{$parsed->{results}} &&
            ref($parsed->{parser})) {
        my $reason_text = $parsed->{reason} // 'archive validation did not complete';
        $reason_text =~ s/[\r\n]+/ /g;
        $SEARCHBOT{active} = 0;
        $SEARCHBOT{state} = 'refused';
        $SEARCHBOT{results} = [];
        delete @SEARCHBOT{qw(archive_source archive_file archive_dcc)};
        retire_searchbot_archive_job('failed',
            'archive_validation_refused', $reason_text);
        p("SearchBot result archive refused: $reason_text. No candidates were published.");
        restore_download_path();
        return;
    }

    $SEARCHBOT{active} = 0;
    $SEARCHBOT{state} = 'complete';
    $SEARCHBOT{parser} = $parsed->{parser};
    $SEARCHBOT{results} = $parsed->{results};
    my $archive_source = $SEARCHBOT{archive_source};
    my $archive_file = $SEARCHBOT{archive_file};
    my $destination = finalize_download(
        $archive_file, $SEARCHBOT{archive_dcc}
    );
    delete @SEARCHBOT{qw(archive_source archive_file archive_dcc)};
    p(sprintf('SearchBot result collection complete: %d candidate(s); no content file was fetched.',
        scalar @{$SEARCHBOT{results}}));
    p("Validated result ZIP saved to $destination.") if $destination;
    if (!$destination && ref($archive_file) eq 'HASH' &&
            $archive_file->{phase6_published_unrecorded}) {
        my $evidence = $archive_file->{phase6_published_unrecorded};
        p('Validated result ZIP was published to ' . $evidence->{destination_path} .
            ', but its durable completion record failed; the staging copy remains at ' .
            ($evidence->{staging_path} // '(unknown path)') . '. the job queue is paused for recovery.');
    } elsif (!$destination) {
        my $staging_path = defined($archive_source) && length($archive_source)
            ? safe_field($archive_source) : '(unknown path)';
        p("Validated result ZIP remains in staging at $staging_path because it could not be moved safely.");
    }
    p('The ZIP passed bounds, member, length, and checksum checks before rows became selectable.');
    restore_download_path();
}

sub list_transfer_failed {
    my ($request) = @_;
    return unless $request->{list_request} && defined $request->{asked_key};
    $LIST_RETRY_OK{$request->{asked_key}} = 1;
}

sub finish_searchbot_content_transfer {
    my ($transfer, $dcc, $reason) = @_;
    my $request_id = $transfer->{request_id};
    unless (($SEARCHBOT_DIRECT{request_id} // '') eq ($request_id // '') &&
            ($SEARCHBOT_DIRECT{accepted_dcc_identity} // '') eq ($transfer->{key} // '')) {
        log_to_path($transfer->{log_file}, 'STALE_DIRECT_TRANSFER_CLOSE', dcc_desc($dcc));
        return;
    }
    my $request = \%SEARCHBOT_DIRECT;
    clear_searchbot_direct_timer($request);
    my $expected_size = $transfer->{expected_size};
    my $declared_size = $dcc->{size};
    my $received_size = $dcc->{transfd} // 0;
    my $transport_ok = $reason ne 'error' && $transfer->{receive_seen} &&
        defined($expected_size) && defined($declared_size) &&
        $declared_size == $expected_size && $received_size == $expected_size &&
        ($dcc->{arg} // '') eq ($transfer->{offered_name} // '') &&
        (($dcc->{arg} // '') eq ($request->{expected_basename} // '') ||
            (defined($request->{expected_alias}) &&
                ($dcc->{arg} // '') eq $request->{expected_alias}));
    unless ($transport_ok) {
        $request->{state} = $reason eq 'error' ? 'failed' : 'incomplete';
        $request->{terminal_reason} = 'DCC did not close with the exact advertised byte count';
        list_transfer_failed($request);
        log_to_path($request->{log_path}, 'CONTENT_TRANSFER_INCOMPLETE',
            'request=' . $request_id . ' received=' . $received_size .
            ' advertised=' . ($declared_size // 'unknown') .
            ' expected=' . ($expected_size // 'unknown') . ' reason=' . $reason);
        my $partial_path = $transfer->{receive_source} // $transfer->{dcc}{file} // '';
        my $partial_size = length($partial_path) && -f $partial_path ? -s $partial_path : $received_size;
        mark_interrupted($transfer->{phase6_job_id},
            path => $partial_path, size => $partial_size,
            partial_receive_metadata($transfer),
            staging_root => (($transfer->{file} && $transfer->{file}{staging_dir}) //
                $SEARCHBOT_DIRECT{staging_dir}),
            total_size => $expected_size,
            writer_closed => $transfer->{writer_closed} ? 1 : 0,
            offered_basename => $transfer->{offered_name},
            reason => dcc_unreached_reason($transfer, $received_size) //
                'SearchBot DCC did not complete with the exact byte count');
        p("SearchBot content transfer was not an exact successful receive ($received_size/" .
            ($expected_size // 'unknown') . ' bytes); it remains staged and was not published.');
        return;
    }
    my $file = $transfer->{file};
    my $source = staged_download_source($file, $dcc);
    my @source_stat = defined($source) ? stat($source) : ();
    unless (!$transfer->{direct_source_invalid} && defined($source) &&
            defined($transfer->{receive_source}) &&
            File::Spec->canonpath($source) eq File::Spec->canonpath($transfer->{receive_source}) &&
            @source_stat && -f $source && !-l $source &&
            (!defined($transfer->{receive_dev}) ||
             ($source_stat[0] == $transfer->{receive_dev} &&
              $source_stat[1] == $transfer->{receive_ino})) &&
            defined(-s $source) && -s $source == $expected_size) {
        $request->{state} = 'incomplete';
        $request->{terminal_reason} = 'received file was absent, changed, non-regular, or outside staging';
        job_transition($transfer->{phase6_job_id}, 'needs_attention',
            outcome => 'completed_stream_failed_staging_identity');
        log_to_path($request->{log_path}, 'CONTENT_FILE_REFUSED',
            'request=' . $request_id . ' received file failed exact staging/size verification');
        p('SearchBot DCC closed, but its file was not an exact regular file inside request staging; no success was reported.');
        return;
    }
    my $digest;
    my $hash_ok = eval {
        open my $fh, '<:raw', $source or die "cannot open staged file for hashing: $!";
        my $sha = Digest::SHA->new(256);
        $sha->addfile($fh);
        close $fh or die "cannot close staged file after hashing: $!";
        $digest = $sha->hexdigest;
        1;
    };
    unless ($hash_ok && defined $digest) {
        $request->{state} = 'finalization_failed';
        $request->{terminal_reason} = 'local SHA-256 evidence could not be computed';
        job_transition($transfer->{phase6_job_id}, 'needs_attention',
            outcome => 'complete_stream_hash_failure');
        log_to_path($request->{log_path}, 'CONTENT_HASH_FAILED',
            'request=' . $request_id . ' staging=[' . $source . '] error=' . ($@ || 'unknown error'));
        p("SearchBot content transfer completed, but local hash evidence failed; file remains staged at $source.");
        return;
    }
    $request->{received_size} = $received_size;
    $request->{local_sha256} = $digest;
    $file->{local_sha256} = $digest;
    my $destination = finalize_download($file, $dcc);
    unless ($destination) {
        if ($file->{phase6_published_unrecorded}) {
            $request->{state} = 'finalization_unrecorded';
            $request->{destination} = $file->{phase6_published_unrecorded}{destination_path};
            $request->{staged_file} = $source;
            $request->{terminal_reason} = 'published but durable completion requires restart reconciliation';
            p('SearchBot content was published to ' . $request->{destination} .
                ', but durable completion could not be recorded. The staging copy remains at ' .
                $source . '; do not retry this file before the job journal is recovered.');
            return;
        }
        $request->{state} = 'finalization_failed';
        $request->{terminal_reason} = 'safe final destination could not be created';
        $request->{staged_file} = $source;
        log_to_path($request->{log_path}, 'CONTENT_FINALIZATION_FAILED',
            'request=' . $request_id . ' bytes=' . $received_size .
            ' sha256=' . $digest . ' retained_staging=[' . $source . ']');
        p("SearchBot content received and hashed, but finalization failed; recover the staged file at $source.");
        return;
    }
    $request->{state} = 'complete';
    $request->{destination} = $destination;
    $request->{terminal_reason} = 'completed and finalized';
    $request->{actual_sender} = $dcc->{nick};
    $request->{actual_filename} = $dcc->{arg};
    log_to_path($request->{log_path}, 'CONTENT_TRANSFER_COMPLETE',
        'request=' . $request_id . ' expected_sender=' . safe_field($request->{expected_sender}) .
        ' actual_sender=' . safe_field($dcc->{nick}) . ' expected_filename=[' .
        safe_field($request->{expected_basename}) . '] actual_filename=[' . safe_field($dcc->{arg}) .
        '] advertised=' . $expected_size . ' received=' . $received_size .
        ' sha256=' . $digest . ' destination=[' . $destination . ']');
    p("SearchBot content download completed: $destination ($received_size bytes; local SHA-256 $digest).");
}

sub clear_searchbot_timer {
    my $timer = delete $SEARCHBOT{timer};
    Irssi::timeout_remove($timer) if defined $timer;
}

sub arm_searchbot_response_timeout {
    my ($collection_id, $timeout_ms) = @_;
    clear_searchbot_timer();
    $SEARCHBOT{timer} = Irssi::timeout_add_once($timeout_ms, sub {
        expire_searchbot_query($collection_id);
    }, undef);
}

sub expire_searchbot_query {
    my ($collection_id) = @_;
    return unless ($SEARCHBOT{collection_id} // '') eq ($collection_id // '');
    return unless ($SEARCHBOT{state} // '') eq 'awaiting_result';

    $SEARCHBOT{active} = 0;
    $SEARCHBOT{state} = 'expired';
    retire_searchbot_archive_job('expired', 'result_window_expired',
        'SearchBot result window expired before an archive arrived');
    clear_searchbot_timer();
    restore_download_path();
    p('SearchBot result window expired; no result archive was accepted. Start a new explicit query if needed.');
}

sub expire_searchbot_transfer {
    my ($collection_id, $transfer_key) = @_;
    return unless ($SEARCHBOT{collection_id} // '') eq ($collection_id // '');
    return unless ($SEARCHBOT{state} // '') eq 'receiving';
    return unless ($SEARCHBOT{result_transfer_key} // '') eq ($transfer_key // '');

    my $reason = 'SearchBot result transfer exceeded its configured deadline';
    my $transfer = $TRANSFERS{$transfer_key};
    abort_searchbot_collection(1, 'interrupted', $reason,
        $transfer ? 1 : 0,
        $transfer ? {
            job_state => 'interrupted',
            job_outcome => 'transfer_expired',
            request_state => 'transfer_expired',
            reason => $reason,
        } : undef);
    $SEARCHBOT{state} = 'transfer_expired';
    p('SearchBot result transfer exceeded its configured time limit; it was closed and no rows were published.');
}

sub expire_searchbot_parse {
    my ($collection_id) = @_;
    return unless ($SEARCHBOT{collection_id} // '') eq ($collection_id // '');
    return unless ($SEARCHBOT{state} // '') eq 'parsing';

    abort_searchbot_collection(1, 'failed',
        'SearchBot archive parsing exceeded its configured deadline');
    $SEARCHBOT{state} = 'parse_expired';
    p('SearchBot archive parsing exceeded its configured time limit; no rows were published.');
}

sub retire_searchbot_archive_job {
    my ($requested_state, $outcome, $reason) = @_;
    my $job_id = $SEARCHBOT{phase6_job_id};
    return 1 unless defined($job_id) && jobs_ready();
    my $job = $JOBS{coordinator}->job($job_id) or return 0;
    return 1 if FServe::Transfer::Job::is_terminal($job->{state});
    my $target = $requested_state;
    if ($target eq 'expired' && $job->{state} eq 'receiving') {
        $target = 'failed';
    }
    if ($target eq 'interrupted' && $job->{state} ne 'receiving') {
        $target = 'needs_attention';
    }
    if ($target eq 'failed' && $job->{state} eq 'finalizing') {
        $target = 'needs_attention';
    }
    return 1 if $target eq $job->{state};
    my %meta = (outcome => $outcome, reason => $reason);
    if ($job->{state} eq 'receiving') {
        my ($transfer) = grep {
            ($_->{kind} // '') eq 'searchbot' &&
            ($_->{collection_id} // '') eq ($SEARCHBOT{collection_id} // '')
        } values %TRANSFERS;
        my $path = $transfer
            ? ($transfer->{receive_source} // $transfer->{dcc_file} //
                ($transfer->{dcc} ? $transfer->{dcc}{file} : undef) // '')
            : ($SEARCHBOT{archive_source} // '');
        if (length($path)) {
            my $archive_size = $transfer
                ? $transfer->{expected_size}
                : (($SEARCHBOT{archive_dcc} ? $SEARCHBOT{archive_dcc}{size} : undef) //
                    ($SEARCHBOT{archive_file} ? $SEARCHBOT{archive_file}{size_bytes} : undef));
            $meta{data} = { partial => {
                path => $path,
                size => length($path) && -f $path ? -s $path : 0,
                partial_receive_metadata($transfer),
                staging_root => $transfer
                    ? (($transfer->{file} && $transfer->{file}{staging_dir}) //
                        $SEARCHBOT{staging_dir})
                    : $SEARCHBOT{staging_dir},
                total_size => $archive_size,
                offered_basename => $transfer ? $transfer->{offered_name} :
                    ($SEARCHBOT{expected_filename} // ''),
                captured_at => time(), resume_supported => JSON::PP::false,
            } };
        }
    }
    return job_transition($job_id, $target, %meta);
}

sub abort_searchbot_collection {
    my ($quiet, $job_terminal_state, $job_reason, $defer_archive_job_retirement,
        $archive_transfer_stop_intent) = @_;
    $job_terminal_state //= 'cancelled';
    $job_reason //= 'operator cancelled SearchBot collection';
    my $archive_active = $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
    my $direct_active = searchbot_direct_active();
    my $archive_job = defined($SEARCHBOT{phase6_job_id}) && jobs_ready()
        ? $JOBS{coordinator}->job($SEARCHBOT{phase6_job_id}) : undef;
    my $archive_job_open = $archive_job && !FServe::Transfer::Job::is_terminal($archive_job->{state});
    my $has_completed_rows = ref($SEARCHBOT{results}) eq 'ARRAY' && @{$SEARCHBOT{results}};
    unless ($archive_active || $direct_active || $archive_job_open || $has_completed_rows ||
            ($SEARCHBOT{state} // '') eq 'complete') {
        p('No active SearchBot collection to cancel.') unless $quiet;
        return;
    }

    if (defined($SEARCHBOT{collection_id}) && $SEARCHBOT{outbound_token}) {
        $SEARCHBOT{cancel_pending} = 1;
        cancel_outbound_message($SEARCHBOT{outbound_token},
            'SearchBot collection cancelled before query dispatch');
        delete $SEARCHBOT{cancel_pending};
        delete $SEARCHBOT{outbound_token};
    }

    retire_searchbot_direct('cancelled', 'operator cancelled SearchBot retrieval')
        if $direct_active;

    retire_searchbot_archive_job($job_terminal_state,
        $job_terminal_state eq 'cancelled' ? 'archive_collection_cancelled' : 'archive_collection_aborted',
        $job_reason) unless $defer_archive_job_retirement;

    my $collection_id = $SEARCHBOT{collection_id};
    $SEARCHBOT{active} = 0;
    $SEARCHBOT{state} = 'cancelled';
    $SEARCHBOT{results} = [];
    FServe::Discovery::SearchBotArchive::abort_archive(
        $SEARCHBOT{archive_job}, 'SearchBot collection cancelled'
    ) if $SEARCHBOT{archive_job} && $SEARCHBOT_MODULES{loaded};
    delete $SEARCHBOT{archive_job};
    clear_searchbot_parse_step_timer();
    delete @SEARCHBOT{qw(archive_source archive_file archive_dcc)};
    $SEARCHBOT{parser}->abort('SearchBot collection cancelled')
        if $SEARCHBOT{parser} && $SEARCHBOT{parser}->can('abort');
    clear_searchbot_timer();

    for my $key (keys %TRANSFERS) {
        my $transfer = $TRANSFERS{$key};
        next unless ($transfer->{kind} // '') eq 'searchbot' &&
            ($transfer->{collection_id} // '') eq ($collection_id // '');
        request_transfer_stop($transfer, $archive_transfer_stop_intent || {
            job_state => 'cancelled',
            job_outcome => 'archive_collection_cancelled',
            request_state => 'cancelled',
            reason => $job_reason,
        });
    }

    restore_download_path();
    p('SearchBot collection cancelled; no candidates remain selectable.') unless $quiet;
}

sub cmd_searchbot {
    my ($args, $server) = @_;
    unless ($server && $server->{connected}) {
        p('Run /fscrawl searchbot from a window on an already-connected IRC network.');
        return;
    }
    my ($channel, $expected_nick, $terms) = $args =~ /^\s*(\S+)\s+(\S+)\s+(.+?)\s*$/s;
    unless (defined($channel) && defined($expected_nick) && defined($terms) && length($terms)) {
        p('Usage: /fscrawl searchbot <channel> <result-sender-nick> <search terms>');
        return;
    }
    unless ($channel =~ /^[#&+!][^\s,\x00-\x1f\x7f]{0,199}$/ &&
            $expected_nick =~ /^[^\s,\x00-\x1f\x7f]{1,64}$/) {
        p('Use one safe IRC channel and the exact expected SearchBot result-sender nick.');
        return;
    }
    if ($terms =~ /[\x00-\x1f\x7f]/ || length($terms) > 350) {
        p('Search terms contain control characters or exceed 350 characters.');
        return;
    }
    if ($SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving') {
        p('A SearchBot collection is already active. Wait for it to finish or use /fscrawl searchbot-cancel.');
        return;
    }
    if ($S{active} || searchbot_direct_active() || $DOWNLOAD_PATH_OWNER || has_active_download_transfer()) {
        p('Stop the active FServe session and wait for any DCC GET to close before starting SearchBot.');
        return;
    }
    if (Irssi::settings_get_bool('dcc_autoget')) {
        p('Disable Irssi DCC auto-accept before SearchBot collection; no query was sent.');
        return;
    }
    return unless load_searchbot_provider() && load_dcc_policy();

    my $expected_filename = FServe::Discovery::SearchBotOffer::expected_archive_filename($terms);
    unless (defined $expected_filename) {
        p('The query contains punctuation whose SearchBot ZIP filename mapping is not confirmed; no query was sent.');
        return;
    }
    my $server_tag = $server->{tag} // '';
    my $network_id = $server->{chatnet} // $server_tag;
    unless (length($server_tag) && length($network_id)) {
        p('The connected IRC server did not provide a stable server/network identity; no query was sent.');
        return;
    }
    my $tombstone_key = searchbot_offer_tombstone_key(
        $server_tag, $expected_nick, $expected_filename
    );
    if (searchbot_tombstone_used(\%SEARCHBOT_USED_OFFERS, $server,
            $server_tag, $expected_nick, $expected_filename) ||
        searchbot_tombstone_used(\%SEARCHBOT_CONTENT_TOMBSTONES, $server,
            $server_tag, $expected_nick, $expected_filename)) {
        p('This sender/server result ZIP basename was already used by an earlier query in this Irssi script session. Because DCC SEND has no query nonce, reusing it could accept a stale same-name offer; no query was sent.');
        return;
    }
    if (keys(%SEARCHBOT_USED_OFFERS) >= $SEARCHBOT_TOMBSTONE_LIMIT) {
        p('The bounded stale-offer guard is full; no additional SearchBot query will be sent in this script session.');
        return;
    }

    ensure_dirs();
    my $timeout_ms = Irssi::settings_get_int('fscrawl_searchbot_timeout_ms') || 30000;
    $timeout_ms = 1000 if $timeout_ms < 1000;
    $timeout_ms = 120000 if $timeout_ms > 120000;
    my $query_id = ++$SEARCHBOT_SEQUENCE;
    my $collection_id = 'searchbot-' . $query_id . '-' .
        substr(sha256_hex(join("\0", $server_tag, $network_id, $channel,
            $expected_nick, $terms, $$, time, rand())), 0, 32);
    my $source_timestamp = now_iso();
    my $archive_job_id = new_job(
        provider => 'searchbot_archive', server => $server,
        selection => { query => $terms, channel => $channel,
            expected_peer => $expected_nick, basename => $expected_filename,
            offered_basename => $expected_filename, legacy_aliases => [],
            collection_id => $collection_id },
        context => { server_tag => $server_tag },
        limits => { offer_timeout_ms => $timeout_ms,
            archive_bytes => 64 * 1024 * 1024 },
    );
    return unless $archive_job_id;

    $old_dcc_download_path = Irssi::settings_get_str('dcc_download_path');
    Irssi::settings_set_str('dcc_download_path', $S{download_dir});
    %SEARCHBOT = (
        query_id       => $query_id,
        collection_id  => $collection_id,
        active         => 1,
        state          => 'dispatch_pending',
        server_tag     => $server_tag,
        network_id     => $network_id,
        channel        => $channel,
        expected_nick  => $expected_nick,
        query          => $terms,
        phase6_job_id  => $archive_job_id,
        expected_filename => $expected_filename,
        tombstone_key  => $tombstone_key,
        expires_at     => undef,
        source_timestamp => $source_timestamp,
        results        => [],
        parser         => undef,
        server         => $server,
        server_identity => server_connection_identity($server),
        connection_epoch => server_connection_epoch($server),
        casemapping    => server_casemapping($server),
    );

    # MSG treats its trailing text as one payload. Do not quote it: quotes
    # would become literal search characters and change the expected filename.
    my $intent = eval {
        my $archive_job = $JOBS{coordinator}->job($archive_job_id);
        $JOBS{coordinator}->begin_dispatch($archive_job_id,
            casemapping => job_casemapping($archive_job, $server),
            effective_limits => { offer_timeout_ms => $timeout_ms,
                archive_bytes => 64 * 1024 * 1024 });
        1;
    };
    unless ($intent) {
        my $why = $@ || 'persistent archive tuple could not be reserved';
        $why =~ s/[\r\n]+/ /g;
        # Nothing was sent and no timer is armed, so nothing else would end
        # this collection: left active it would refuse every later search.
        $SEARCHBOT{active} = 0;
        $SEARCHBOT{state} = 'dispatch_refused';
        clear_searchbot_timer();
        restore_download_path();
        job_transition($archive_job_id, 'stale', reason => 'archive tuple or dispatch preflight refused')
            if ($JOBS{coordinator}->job($archive_job_id) || {})->{state} eq 'held';
        p("SearchBot query refused before dispatch: $why");
        return;
    }
    my $server_identity = $SEARCHBOT{server_identity};
    my $connection_epoch = $SEARCHBOT{connection_epoch};
    my $route = outbound_route_key($server, $channel, $expected_nick, 'searchbot');
    my $scheduled = schedule_irc_message(
        server => $server, kind => 'query', route => $route,
        owner_kind => 'searchbot', owner_id => $collection_id,
        owner_job_id => $archive_job_id,
        guard => sub {
            $SEARCHBOT{active} &&
                ($SEARCHBOT{collection_id} // '') eq $collection_id &&
                ($SEARCHBOT{state} // '') eq 'dispatch_pending' &&
                ($SEARCHBOT{server_identity} // '') eq ($server_identity // '') &&
                ($SEARCHBOT{connection_epoch} || 0) == ($connection_epoch || 0)
        },
        before_send => sub {
            return 0 unless $SEARCHBOT{active} &&
                ($SEARCHBOT{collection_id} // '') eq $collection_id &&
                ($SEARCHBOT{state} // '') eq 'dispatch_pending';
            $SEARCHBOT_USED_OFFERS{$tombstone_key} = searchbot_tombstone_record(
                $server_tag, $expected_nick, $expected_filename, $collection_id,
                $SEARCHBOT{casemapping});
            $SEARCHBOT{state} = 'awaiting_result';
            $SEARCHBOT{expires_at} = time() + ($timeout_ms / 1000);
            my $armed = eval {
                arm_searchbot_response_timeout($collection_id, $timeout_ms);
                defined $SEARCHBOT{timer};
            };
            unless ($armed) {
                clear_searchbot_timer();
                $SEARCHBOT{state} = 'dispatch_timer_unavailable';
                return 0;
            }
            return 1;
        },
        send => sub { $server->command('MSG ' . $channel . ' @search ' . $terms) },
        on_done => sub {
            my ($status, $reason) = @_;
            return unless ($SEARCHBOT{collection_id} // '') eq $collection_id;
            delete $SEARCHBOT{outbound_token};
            return if $SEARCHBOT{cancel_pending};
            if ($status eq 'sent') {
                eval { $JOBS{coordinator}->record_dispatch_result($archive_job_id,
                    'sent', outcome => 'search_query_sent'); };
                p("Searching $channel for [$terms] via \@search; expecting one ZIP from $expected_nick named $expected_filename within ${timeout_ms}ms.");
                p('DCC SEND has no query nonce; same-name late offers cannot be distinguished perfectly. Queries are serialized and stale selections are invalidated.');
                return;
            }
            my $why = safe_field($reason // $status);
            $SEARCHBOT{active} = 0;
            $SEARCHBOT{state} = 'send_failed';
            $SEARCHBOT{results} = [];
            clear_searchbot_timer();
            restore_download_path();
            eval { $JOBS{coordinator}->record_dispatch_result($archive_job_id,
                'unknown', outcome => 'search_dispatch_unknown', reason => $why); };
            p("SearchBot dispatch did not complete safely ($status): $why; no automatic retry will occur.");
        },
    );
    unless ($scheduled) {
        $SEARCHBOT{active} = 0;
        $SEARCHBOT{state} = 'scheduler_failed';
        restore_download_path();
        eval { $JOBS{coordinator}->record_dispatch_result($archive_job_id,
            'unknown', outcome => 'search_scheduler_unavailable'); };
        p('SearchBot dispatch intent was recorded, but no outbound scheduler reservation was available; inspect this job before retrying.');
        return;
    }
    $SEARCHBOT{outbound_token} = $scheduled->{token}
        if $scheduled->{status} eq 'pending';
}

sub searchbot_selection_candidate {
    my ($selection_id) = @_;
    return ('unavailable', undef) unless ($SEARCHBOT{state} // '') eq 'complete' &&
        ref($SEARCHBOT{results}) eq 'ARRAY';
    return unless defined($selection_id) &&
        $selection_id =~ /\A(searchbot-[1-9][0-9]*-[a-f0-9]{32}):([1-9][0-9]*)\z/i;
    my ($collection, $ordinal) = ($1, $2);
    return ('stale', undef) unless lc($collection) eq lc($SEARCHBOT{collection_id} // '');
    return ('missing', undef) if length($ordinal) > 5 || $ordinal > @{$SEARCHBOT{results}};
    my $candidate = $SEARCHBOT{results}[$ordinal - 1];
    return ('missing', undef) unless $candidate &&
        ($candidate->{collection_id} // '') eq ($SEARCHBOT{collection_id} // '') &&
        ($candidate->{result_ordinal} || 0) == $ordinal;
    return ('ok', $candidate);
}

sub escaped_searchbot_payload {
    my ($payload) = @_;
    $payload //= '';
    $payload =~ s/([^\x20-\x7e])/sprintf('\\x%02X', ord($1))/ge;
    return $payload;
}

sub parse_searchbot_selection_args {
    my ($args, $mode) = @_;
    my ($selection, $tail) = $args =~ /^\s*(\S+)(?:\s+(.*?))?\s*$/s;
    return unless defined $selection;
    $tail //= '';
    my $sender;
    if ($mode eq 'preview' && !length($tail)) {
        return ($selection, undef);
    }
    return unless $tail =~ /^--sender\s+(\S+)\s*$/;
    $sender = $1;
    return ($selection, $sender);
}

sub searchbot_direct_release_path_owner {
    my ($request) = @_;
    return unless ref($request) eq 'HASH' && $DOWNLOAD_PATH_OWNER;
    return unless ($DOWNLOAD_PATH_OWNER->{request_id} // '') eq ($request->{request_id} // '');
    return unless ($DOWNLOAD_PATH_OWNER->{key} // '') eq ($request->{path_owner_key} // '');
    Irssi::settings_set_str('dcc_download_path', $DOWNLOAD_PATH_OWNER->{restore_to})
        if defined $DOWNLOAD_PATH_OWNER->{restore_to};
    $request->{path_owner_key} = undef;
    $request->{path_restored} = 1;
    undef $DOWNLOAD_PATH_OWNER;
}

sub clear_searchbot_direct_timer {
    my ($request) = @_;
    return unless ref($request) eq 'HASH';
    my $timer = delete $request->{timer};
    Irssi::timeout_remove($timer) if defined $timer;
}

sub retire_searchbot_direct {
    my ($terminal_state, $reason) = @_;
    my $request = \%SEARCHBOT_DIRECT;
    return unless defined($request->{request_id}) &&
        ($request->{state} // '') !~ /\A(?:complete|failed|cancelled|expired|transfer_expired|dispatch_uncertain|preflight_failed|disconnected|finalization_failed|close_pending)\z/;
    my $request_id = $request->{request_id};
    $request->{retiring} = 1;
    cancel_outbound_owner('job', $request->{phase6_job_id},
        'SearchBot direct request retired before outbound dispatch')
        if defined $request->{phase6_job_id};
    my $transfer_key = $request->{accepted_dcc_identity};
    my $transfer = defined($transfer_key) ? $TRANSFERS{$transfer_key} : undef;
    clear_searchbot_direct_timer($request);
    my %outcome_for_state = (
        cancelled => 'cancelled', expired => 'expired', disconnected => 'disconnected',
        dispatch_uncertain => 'dispatch_uncertain', failed => 'failed',
        preflight_failed => 'preflight_failed',
    );
    if ($transfer) {
        return request_transfer_stop($transfer, {
            job_state => $terminal_state eq 'cancelled' ||
                $terminal_state eq 'preflight_failed' ? 'cancelled' : 'interrupted',
            job_outcome => $outcome_for_state{$terminal_state} // $terminal_state,
            request_state => $terminal_state,
            reason => $reason,
        });
    } elsif (exists $outcome_for_state{$terminal_state}) {
        retire_job($request->{phase6_job_id}, $outcome_for_state{$terminal_state}, $reason);
    }
    $request->{state} = $terminal_state;
    $request->{terminal_reason} = $reason;
    log_to_path($request->{log_path}, 'REQUEST_TERMINAL',
        'request=' . safe_field($request_id) . ' state=' . safe_field($terminal_state) .
        ' reason=' . safe_field($reason));
    searchbot_direct_release_path_owner($request);
    remove_empty_staging($request->{staging_dir});
    return 1;
}

sub expire_searchbot_direct {
    my ($request_id, $expected_state) = @_;
    return unless ($SEARCHBOT_DIRECT{request_id} // '') eq ($request_id // '') &&
        ($SEARCHBOT_DIRECT{state} // '') eq ($expected_state // '');
    my $label = $expected_state eq 'awaiting_offer'
        ? 'expired' : 'transfer_expired';
    my $said = $SEARCHBOT_DIRECT{sender_said};
    retire_searchbot_direct($label, $expected_state eq 'awaiting_offer'
        ? 'no matching file was offered before the deadline; the request is not sent again' .
            (length($said // '') ? '. The sender said: ' . safe_field($said) : '')
        : 'the transfer did not finish before its deadline');
    p($expected_state eq 'awaiting_offer'
        ? 'SearchBot direct-send offer window expired; no automatic retry was made.'
        : 'SearchBot direct transfer deadline elapsed; partial data, if any, remains staged.');
}

sub cmd_searchbot_get {
    my ($args, $server) = @_;
    my ($selection, $sender) = parse_searchbot_selection_args($args, 'get');
    unless (defined($selection) && defined($sender)) {
        p('Usage: /fscrawl searchbot-get <collection-id:row-number> --sender <nick>');
        return;
    }
    my $queued_job_id = $JOBS{executing_job_id};
    my $queued_job;
    if (defined $queued_job_id) {
        $queued_job = jobs_ready() ? $JOBS{coordinator}->job($queued_job_id) : undef;
        unless ($queued_job && $queued_job->{provider} eq 'searchbot' &&
                $queued_job->{state} eq 'held') {
            p('Queued SearchBot job is unavailable or no longer held; no request was sent.');
            return;
        }
    }
    unless (($SEARCHBOT{state} // '') eq 'complete') {
        p('SearchBot results are incomplete, stale, or unavailable; no request was sent.');
        return;
    }
    my ($status, $candidate) = searchbot_selection_candidate($selection);
    unless ($candidate) {
        p($status eq 'stale'
            ? 'That SearchBot selection belongs to an older or different collection; list the current rows again.'
            : 'No row at that index in the latest completed SearchBot collection.');
        return;
    }
    unless (searchbot_nick_is_safe($sender)) {
        p('Expected content sender is not a safe IRC nick; no request was sent.');
        return;
    }
    if (searchbot_direct_active() || $S{active} || $DOWNLOAD_PATH_OWNER || has_active_download_transfer()) {
        p('Another SearchBot request, FServe session, or DCC transfer owns the retrieval slot.');
        return;
    }
    if (Irssi::settings_get_bool('dcc_autoget')) {
        p('Disable Irssi DCC auto-accept before direct SearchBot retrieval; no request was sent.');
        return;
    }
    my $server_network = $server ? ($server->{chatnet} // $server->{tag} // '') : '';
    unless ($server && $server->{connected} &&
            server_connection_identity($server) eq ($SEARCHBOT{server_identity} // '') &&
            lc($server->{tag} // '') eq lc($SEARCHBOT{server_tag} // '') &&
            lc($server_network) eq lc($SEARCHBOT{network_id} // '') &&
            server_connection_epoch($server) == ($SEARCHBOT{connection_epoch} || 0)) {
        p('Run searchbot-get on the same live IRC connection used for this result collection.');
        return;
    }
    unless (server_has_joined_channel($server, $SEARCHBOT{channel})) {
        p('The originating SearchBot channel is no longer joined; no request was sent.');
        return;
    }
    unless (eval { $server->can('send_raw') }) {
        p('This Irssi server object has no safe raw-line sender; no request was sent.');
        return;
    }
    my $validated = FServe::Discovery::SearchBotRequest::validate_candidate(
        $candidate, channel => $SEARCHBOT{channel});
    unless (($validated->{type} // '') eq 'valid' &&
            ($validated->{request_line_digest} // '') eq ($candidate->{request_line_digest} // '')) {
        p('SearchBot selection refused: ' . safe_field($validated->{reason} // 'request payload changed') . '.');
        return;
    }
    my $max_content_bytes = configured_searchbot_content_limit();
    $max_content_bytes = effective_job_limit(
        $queued_job, 'content_bytes', $max_content_bytes) if $queued_job;
    unless ($max_content_bytes) {
        p('SearchBot content cap is invalid or exceeds the queued job\'s captured scope; no request was sent.');
        return;
    }
    return unless load_searchbot_provider() && load_dcc_policy();

    my $current_offer_timeout_ms = bounded_timeout_setting(
        'fscrawl_searchbot_content_timeout_ms', 120000, 1000, 300000);
    my $current_transfer_timeout_ms = bounded_timeout_setting(
        'fscrawl_searchbot_content_transfer_timeout_ms', 300000, 1000, 1800000);
    my $offer_timeout_ms = effective_job_limit(
        $queued_job, 'offer_timeout_ms', $current_offer_timeout_ms);
    my $transfer_timeout_ms = effective_job_limit(
        $queued_job, 'transfer_timeout_ms', $current_transfer_timeout_ms);
    unless ($offer_timeout_ms && $transfer_timeout_ms) {
        p('Queued SearchBot job is missing a validated captured offer or transfer timeout; no request was sent.');
        return;
    }
    my $download_dir = resolve_irssi_path(Irssi::settings_get_str('fscrawl_download_dir'));
    my $output_dir = resolve_irssi_path(Irssi::settings_get_str('fscrawl_output_dir'));
    my $request_id = 'sbreq-' . ++$SEARCHBOT_DIRECT_SEQUENCE . '-' .
        substr(sha256_hex(join("\0", $candidate->{candidate_id}, $sender,
            $SEARCHBOT{connection_epoch}, $$, time, rand())), 0, 24);
    my $log_path = File::Spec->catfile($output_dir, "searchbot-direct-$request_id.tsv");
    my $log_ready = eval {
        make_path($output_dir) unless -d $output_dir;
        open my $fh, '>>', $log_path or die "cannot create request evidence log: $!";
        close $fh or die "cannot close request evidence log: $!";
        1;
    };
    unless ($log_ready) {
        my $why = $@ || 'request evidence log is unavailable';
        $why =~ s/[\r\n]+/ /g;
        p("SearchBot request refused before dispatch: $why");
        return;
    }
    eval { make_path($download_dir) unless -d $download_dir; 1 } or do {
        p('SearchBot request refused: download directory could not be prepared.');
        return;
    };
    my $file = {
        type => 'file', name => $candidate->{filename},
        network_id => $SEARCHBOT{network_id}, server_nick => $sender,
        expected_sender => $sender, download_dir => $download_dir,
        log_file => $log_path, retrieval_protocol => 'searchbot_direct_send',
        searchbot_collection_id => $candidate->{collection_id},
        searchbot_candidate_id => $candidate->{candidate_id},
        searchbot_result_row => $candidate->{result_row},
        searchbot_request_line_digest => $validated->{request_line_digest},
        ($SEARCHBOT{from_find} ? (from_find => 1) : ()),
        ($SEARCHBOT{from_list} ? (from_list => 1) : ()),
        (defined($WEB_BRIDGE{download_network_dir})
            ? (destination_network => $WEB_BRIDGE{download_network_dir}) : ()),
    };
    my $tombstone = FServe::Discovery::SearchBotRequest::tombstone_key(
        $SEARCHBOT{server_tag}, $sender, $candidate->{filename});
    # The name with underscores for its spaces, as mIRC-based senders offer
    # it, is also taken; not when that is itself another row of this sender's.
    my $alias = $candidate->{filename};
    $alias =~ s/ /_/g;
    $alias = undef if $alias eq $candidate->{filename} || grep {
        ($_->{filename} // '') eq $alias &&
            lc($_->{route_trigger} // '') eq lc($candidate->{route_trigger} // '')
    } @{$SEARCHBOT{results} || []};
    if (searchbot_tombstone_used(\%SEARCHBOT_CONTENT_TOMBSTONES, $server,
            $SEARCHBOT{server_tag}, $sender, $candidate->{filename}) ||
        searchbot_tombstone_used(\%SEARCHBOT_USED_OFFERS, $server,
            $SEARCHBOT{server_tag}, $sender, $candidate->{filename})) {
        p('This content sender/server/filename tuple was already used or overlaps a SearchBot archive tuple; no request was sent.');
        return;
    }
    if (keys(%SEARCHBOT_CONTENT_TOMBSTONES) >= $SEARCHBOT_CONTENT_TOMBSTONE_LIMIT) {
        p('The bounded SearchBot content stale-offer guard is full; no request was sent.');
        return;
    }
    delete $JOBS{executing_job_id} if defined $queued_job_id;
    my $phase6_job_id;
    if (defined $queued_job_id) {
        my $job = jobs_ready() ? $JOBS{coordinator}->job($queued_job_id) : undef;
        my $selection_data = $job ? $job->{selection} : {};
        my $same_selection = $job && $job->{provider} eq 'searchbot' &&
            $job->{state} eq 'held' && job_is_on_connection($job, $server) &&
            ($selection_data->{collection_id} // '') eq ($candidate->{collection_id} // '') &&
            ($selection_data->{physical_source_row} || 0) == ($candidate->{result_row} || 0) &&
            ($selection_data->{result_ordinal} || 0) == ($candidate->{result_ordinal} || 0) &&
            ($selection_data->{exact_payload} // '') eq ($candidate->{request_line} // '') &&
            ($selection_data->{payload_sha256} // '') eq ($validated->{request_line_digest} // '') &&
            ($selection_data->{basename} // '') eq ($candidate->{filename} // '') &&
            ($selection_data->{expected_peer} // '') eq $sender &&
            ($selection_data->{originating_channel} // '') eq ($SEARCHBOT{channel} // '');
        unless ($same_selection) {
            job_transition($queued_job_id, 'stale', outcome => 'queued_searchbot_selection_stale',
                reason => 'the queued exact row, sender, or originating connection is no longer current')
                if $job && $job->{state} eq 'held';
            p('Queued SearchBot selection is stale or differs from the current exact row; no request was sent.');
            return;
        }
        $phase6_job_id = $queued_job_id;
    } else {
        $phase6_job_id = new_job(
        provider => 'searchbot', server => $server,
        selection => {
            collection_id => $candidate->{collection_id},
            physical_source_row => $candidate->{result_row},
            result_ordinal => $candidate->{result_ordinal},
            exact_payload => $candidate->{request_line},
            payload_sha256 => $validated->{request_line_digest},
            basename => $candidate->{filename}, offered_basename => $candidate->{filename},
            originating_channel => $SEARCHBOT{channel}, expected_peer => $sender,
            sender => $sender, legacy_aliases => [defined($alias) ? ($alias) : ()],
        },
        context => { channel => $SEARCHBOT{channel}, server_tag => $SEARCHBOT{server_tag},
            (defined($WEB_BRIDGE{download_operation_id})
                ? (web_operation_id => $WEB_BRIDGE{download_operation_id}) : ()) },
        limits => { offer_timeout_ms => $offer_timeout_ms,
            transfer_timeout_ms => $transfer_timeout_ms, content_bytes => $max_content_bytes },
        duplicate_message => 'This content sender/server/filename tuple was already used or overlaps a SearchBot archive tuple; the selection also has durable history, so no request was sent.',
        );
    }
    unless ($phase6_job_id) {
        p('SearchBot retrieval stopped because the durable job record could not be created.');
        return;
    }
    $file->{phase6_job_id} = $phase6_job_id;
    my $restore_to = Irssi::settings_get_str('dcc_download_path');
    unless (prepare_download_staging($file)) {
        Irssi::settings_set_str('dcc_download_path', $restore_to);
        p('SearchBot request refused: dedicated staging directory could not be prepared.');
        return;
    }
    my $request = {
        request_id => $request_id, collection_id => $candidate->{collection_id},
        candidate_id => $candidate->{candidate_id}, result_ordinal => $candidate->{result_ordinal},
        source_row => $candidate->{result_row}, request_line => $candidate->{request_line},
        request_line_digest => $validated->{request_line_digest},
        network_id => $SEARCHBOT{network_id}, server_tag => $SEARCHBOT{server_tag},
        server => $server, server_identity => $SEARCHBOT{server_identity},
        connection_epoch => $SEARCHBOT{connection_epoch},
        casemapping => $SEARCHBOT{casemapping},
        channel => $SEARCHBOT{channel}, route_trigger => $candidate->{route_trigger},
        expected_sender => $sender, expected_basename => $candidate->{filename},
        expected_alias => $alias,
        display_size_raw => $candidate->{info_raw},
        display_size_precision => defined($candidate->{size_bytes}) ? 'estimated' : 'unknown',
        opaque_hash_raw => $candidate->{hash_raw}, state => 'preflight',
        requested_at => undef, offer_deadline => undef,
        transfer_timeout_ms => $transfer_timeout_ms, offer_timeout_ms => $offer_timeout_ms,
        max_content_bytes => $max_content_bytes, staging_dir => $file->{staging_dir},
        log_path => $log_path, file => $file, tombstone_key => $tombstone,
        phase6_job_id => $phase6_job_id,
        path_owner_key => $request_id, restore_path => $restore_to,
        serialized_line => $validated->{serialized_line},
    };
    $DOWNLOAD_PATH_OWNER = {
        key => $request_id, request_id => $request_id,
        restore_to => $restore_to, path_selected => 0,
        kind => 'searchbot_content_request',
    };
    %SEARCHBOT_DIRECT = %$request;
    log_to_path($log_path, 'REQUEST_SELECTED',
        'id=' . $request_id . ' collection=' . $candidate->{collection_id} .
        ' row=' . $candidate->{result_row} . ' expected_sender=' . $sender .
        ' filename=[' . $candidate->{filename} . '] digest=' . $validated->{request_line_digest});
    my $intent = eval {
        my $dispatch_job = $JOBS{coordinator}->job($phase6_job_id);
        $JOBS{coordinator}->begin_dispatch($phase6_job_id,
            casemapping => job_casemapping($dispatch_job, $server),
            effective_limits => { offer_timeout_ms => $offer_timeout_ms,
                transfer_timeout_ms => $transfer_timeout_ms,
                content_bytes => $max_content_bytes });
    };
    unless ($intent) {
        my $why = $@ || 'persistent DCC tuple could not be reserved';
        $why =~ s/[\r\n]+/ /g;
        clear_searchbot_direct_timer(\%SEARCHBOT_DIRECT);
        $SEARCHBOT_DIRECT{state} = 'preflight_failed';
        searchbot_direct_release_path_owner(\%SEARCHBOT_DIRECT);
        job_transition($phase6_job_id, 'stale', reason => 'durable tuple or dispatch preflight refused')
            if ($JOBS{coordinator}->job($phase6_job_id) || {})->{state} eq 'held';
        p("SearchBot request refused before dispatch: $why");
        return;
    }

    $SEARCHBOT_DIRECT{state} = 'dispatch_pending';
    my $wire = $validated->{serialized_line};
    $wire =~ s/\r\n\z//;
    my $request_collection_id = $SEARCHBOT{collection_id};
    my $connection_identity = $SEARCHBOT{server_identity};
    my $connection_epoch = $SEARCHBOT{connection_epoch};
    my $route = outbound_route_key($server, $SEARCHBOT{channel}, $sender, 'searchbot');
    my $scheduled = schedule_irc_message(
        server => $server, kind => 'query', route => $route,
        owner_kind => 'searchbot_direct', owner_id => $request_id,
        owner_job_id => $phase6_job_id,
        guard => sub {
            ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id &&
                ($SEARCHBOT_DIRECT{state} // '') eq 'dispatch_pending' &&
                ($SEARCHBOT{collection_id} // '') eq ($request_collection_id // '') &&
                ($SEARCHBOT{state} // '') eq 'complete' &&
                ($SEARCHBOT_DIRECT{server_identity} // '') eq ($connection_identity // '') &&
                ($SEARCHBOT_DIRECT{connection_epoch} || 0) == ($connection_epoch || 0) &&
                $server->{connected} &&
                server_connection_identity($server) eq ($connection_identity // '') &&
                server_connection_epoch($server) == ($connection_epoch || 0) &&
                server_has_joined_channel($server, $SEARCHBOT_DIRECT{channel})
        },
        before_send => sub {
            return 0 unless ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id &&
                ($SEARCHBOT_DIRECT{state} // '') eq 'dispatch_pending' &&
                ($SEARCHBOT{collection_id} // '') eq ($request_collection_id // '') &&
                ($SEARCHBOT{state} // '') eq 'complete';
            $SEARCHBOT_DIRECT{state} = 'dispatching';
            $SEARCHBOT_DIRECT{dispatch_attempted} = 1;
            $SEARCHBOT_DIRECT{requested_at} = time();
            $SEARCHBOT_DIRECT{offer_deadline} = time() + $offer_timeout_ms / 1000;
            $SEARCHBOT_CONTENT_TOMBSTONES{$tombstone} = searchbot_tombstone_record(
                $SEARCHBOT{server_tag}, $sender, $candidate->{filename}, $request_id,
                $SEARCHBOT{casemapping});
            my $timer_ok = eval {
                my $timer = Irssi::timeout_add_once($offer_timeout_ms, sub {
                    expire_searchbot_direct($request_id, 'awaiting_offer');
                }, undef);
                $SEARCHBOT_DIRECT{timer} = $timer if defined $timer;
                defined $timer;
            };
            unless ($timer_ok) {
                delete $SEARCHBOT_DIRECT{timer};
                die 'offer timer registration failed';
            }
            log_to_path($log_path, 'REQUEST_DISPATCH_ATTEMPT',
                'request=' . $request_id . ' tuple tombstoned before transport invocation');
            return 1;
        },
        send => sub {
            $server->send_raw($wire);
            engine_log_sent_raw($server, $wire);
        },
        on_done => sub {
            my ($send_status, $reason) = @_;
            return unless ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id;
            delete $SEARCHBOT_DIRECT{outbound_token};
            return if $SEARCHBOT_DIRECT{retiring};
            if ($send_status eq 'paused_before_send') {
                my $recorded = eval {
                    $JOBS{coordinator}->record_dispatch_result($phase6_job_id,
                        'cancelled_before_transport',
                        outcome => 'searchbot_request_paused_before_send',
                        reason => 'queue pause withdrew the exact-row message before transport invocation');
                    1;
                };
                clear_searchbot_direct_timer(\%SEARCHBOT_DIRECT);
                $SEARCHBOT_DIRECT{state} = 'paused_before_send';
                searchbot_direct_release_path_owner(\%SEARCHBOT_DIRECT);
                log_to_path($log_path, 'REQUEST_PAUSED_BEFORE_SEND',
                    'request=' . $request_id . ' durable_state_held=' . ($recorded ? 'yes' : 'no'));
                p('Queue pause withdrew the SearchBot row before it was sent; the durable job remains held for a later explicit run.')
                    if $recorded;
                p('The unsent SearchBot row was withdrawn, but its durable state could not be restored safely.')
                    unless $recorded;
                return;
            }
            if ($send_status eq 'sent') {
                eval { $JOBS{coordinator}->record_dispatch_result($phase6_job_id,
                    'sent', outcome => 'exact_row_sent'); };
                $SEARCHBOT_DIRECT{state} = 'awaiting_offer'
                    if ($SEARCHBOT_DIRECT{state} // '') eq 'dispatching';
                log_to_path($log_path, 'REQUEST_DISPATCHED',
                    'request=' . $request_id . ' serialized_bytes=' . length($validated->{serialized_line}));
                p("Posted the exact selected SearchBot row once to $SEARCHBOT{channel}; expecting DCC SEND from $sender named $candidate->{filename} (cap $max_content_bytes bytes, offer deadline ${offer_timeout_ms}ms).")
                    if ($SEARCHBOT_DIRECT{state} // '') eq 'awaiting_offer';
                return;
            }
            my $why = safe_field($reason // $send_status);
            if ($send_status eq 'refused') {
                my $entry = $SEARCHBOT_CONTENT_TOMBSTONES{$tombstone};
                delete $SEARCHBOT_CONTENT_TOMBSTONES{$tombstone}
                    if ref($entry) eq 'HASH' &&
                        ($entry->{identity} // '') eq $request_id;
                eval { $JOBS{coordinator}->record_dispatch_result($phase6_job_id,
                    'cancelled_before_transport', outcome => 'pre_dispatch_refused',
                    reason => $why); };
                retire_searchbot_direct('preflight_failed', $why);
                p("SearchBot request was not sent because pre-dispatch setup failed: $why");
                return;
            }
            eval { $JOBS{coordinator}->record_dispatch_result($phase6_job_id,
                'unknown', outcome => 'dispatch_outcome_unknown', reason => $why); };
            retire_searchbot_direct('dispatch_uncertain', $why);
            p("SearchBot request dispatch outcome is uncertain; it was not resent: $why. See the request evidence log.");
        },
    );
    unless ($scheduled) {
        eval { $JOBS{coordinator}->record_dispatch_result($phase6_job_id,
            'unknown', outcome => 'searchbot_scheduler_unavailable'); };
        retire_searchbot_direct('dispatch_uncertain',
            'outbound scheduler could not reserve the exact-row message');
        p('SearchBot request stopped because the outbound scheduler could not reserve the message; it was not sent.');
        return;
    }
    $SEARCHBOT_DIRECT{outbound_token} = $scheduled->{token}
        if ($scheduled->{status} // '') eq 'pending' &&
            ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id;
    log_to_path($log_path, 'REQUEST_DISPATCH_PENDING',
        'request=' . $request_id . ' pending=' . ($scheduled->{status} // 'unknown'));
}

1;
