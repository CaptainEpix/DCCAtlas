# List servers: adverts seen, "!list", and Get list.
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

our (%JOBS, %S, %SEARCHBOT, %SEARCHBOT_CONTENT_TOMBSTONES, %SEARCHBOT_DIRECT,
     %SEARCHBOT_USED_OFFERS, %TRANSFERS, %USED_TRANSFER_IDENTITIES, %WEB_BRIDGE,
     %WEB_BRIDGE_ADVERTS, %WEB_BRIDGE_SOURCES, $ADVERT_HEAD_WAIT_SECONDS,
     $ADVERT_MAX_PENDING, $ADVERT_MAX_SERVERS, $DOWNLOAD_PATH_OWNER,
     $SEARCHBOT_DIRECT_SEQUENCE, $SEARCHBOT_SEQUENCE, $WEB_BRIDGE_SAID);

# A list server's whole list, asked for with "@Nick" (2026-10-27): the one
# line goes to the channel once, through the scheduler's spacing, and the one
# file taken is a .txt, .zip, .rar or .7z list offered by that nick before the deadline.
# Its name is not known in advance (shelfbot sent
# "shelfbot-newlist-25-Oct-2026-FW.zip"), so the job reserves the sender's list
# rather than a name: an offer is taken only while that is this job's, and
# never under a name another job reserved. A nick is asked once a connection,
# and only one seen advertising a list in the source's channel. The file is
# received, checked and kept as a posted row's is, under
# <network>/<Nick>/@list/.
# 128 MB since 2026-10-28 (was 64), for the file as offered, usually zipped.
our $LIST_MAX_BYTES = 128 * 1024 * 1024;
my %LIST_ASKED;   # connection identity, epoch and folded nick => time asked
# A list whose offer was taken but whose transfer then failed may be asked for
# once more on the same connection (2026-10-29): the sender answered, so no
# late answer to the first request can be mistaken for one to the second.
our %LIST_RETRY_OK;
# How many times each was asked, on its connection: a second ask reserves a
# list name of its own, as the first one's reservation is kept for good.
my %LIST_ATTEMPTS;

# A file named by a list server's list that the web service stored
# (2026-10-27). The web supplies the sender, the name and the size the list
# gave; the engine builds the row as such lists write it,
# "!Nick name  ::INFO:: size", reads it as any posted row, and fetches it
# through the same path and checks: posted once, only that name taken from
# that nick, never twice on one connection.
sub web_bridge_list_download {
    my ($source, $source_id, $sender, $name, $size_raw, $operation_id, $list_name) = @_;
    return web_bridge_refusal('search_active', 'wait for the running search to finish first')
        if any_find_active() || $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
    return web_bridge_refusal('transfer_busy', 'finish or cancel the current transfer first')
        if $S{active} || searchbot_direct_active() || $DOWNLOAD_PATH_OWNER ||
            has_active_download_transfer();
    return web_bridge_refusal('download_not_started', 'the SearchBot modules could not be loaded')
        unless load_searchbot_provider();
    return web_bridge_refusal('invalid_arguments', 'that is not a safe IRC nick')
        unless searchbot_nick_is_safe($sender) && $sender =~ /\A[A-Za-z0-9\-\[\]\\`_^{}|]{1,64}\z/;
    # An OmenServe list's rows may start with a word of their own, not the
    # nick: the list's name, "!Nick-Ebooks2" (2026-11-02), or the server's
    # trigger, "!Tome" (2026-11-03). The row is posted with that word, as
    # one IRC token, and the file is still expected from the nick.
    my $word = defined($list_name) ? $list_name : $sender;
    return web_bridge_refusal('invalid_arguments', 'a list name is one word, as its rows write it')
        unless $word =~ /\A[A-Za-z0-9\-\[\]\`_^{}|]{1,64}\z/;
    return web_bridge_refusal('invalid_arguments', 'the size must be as the list wrote it')
        if defined($size_raw) && $size_raw !~ /\A[0-9][0-9.,]{0,15} ?[A-Za-z]{1,5}\z/;
    return web_bridge_refusal('invalid_arguments', 'the file name must be one printable name')
        unless defined($name) && $name =~ /\A[\x20-\x7e]{1,255}\z/ && $name !~ m{[/\\]} &&
            $name !~ /::INFO::/i;
    my $source_view = web_bridge_source_view($source);
    return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
        unless $source_view && $source_view->{state} eq 'ready';
    my $server = web_bridge_source_server($source);
    return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
        unless $server && $server->{connected};
    my $channel = $source->{channel};
    my $line = "!$word $name" . (defined($size_raw) ? "  ::INFO:: $size_raw" : '');
    my $server_tag = $server->{tag} // '';
    my $network_id = $server->{chatnet} // $server_tag;
    my $query_id = ++$SEARCHBOT_SEQUENCE;
    my $collection_id = 'searchbot-' . $query_id . '-' . substr(sha256_hex(join("\0",
        $server_tag, $network_id, $channel, $sender, $name, $$, time, rand())), 0, 32);
    my $stamp = now_iso();
    my $reader = FServe::Discovery::SearchBot->new(
        collection_id => $collection_id, network_id => $network_id, server_tag => $server_tag,
        discovery_channel => $channel, query => "list of $sender", source_timestamp => $stamp);
    $reader->feed_line($line);
    my $done = $reader->finish;
    my $row = ref($done) eq 'HASH' && ref($done->{results}) eq 'ARRAY' ? $done->{results}[0] : undef;
    return web_bridge_refusal('invalid_arguments', 'that row could not be read as a list row')
        unless ($done->{type} // '') eq 'complete' && @{$done->{results}} == 1 &&
            ($row->{filename} // '') eq $name &&
            lc($row->{route_trigger} // '') eq lc("!$word") && $row->{direct_requestable};
    my $tag = $server->{tag} // '';
    return web_bridge_refusal('repeat_refused',
        'this file was already requested from this sender on this connection; ' .
        'a repeat is refused because a late offer for the first request could not be told from an offer for the second')
        if searchbot_tombstone_used(\%SEARCHBOT_CONTENT_TOMBSTONES, $server, $tag, $sender, $name) ||
            searchbot_tombstone_used(\%SEARCHBOT_USED_OFFERS, $server, $tag, $sender, $name);
    # The list that was current is set aside, as for a held row.
    my $current = $WEB_BRIDGE{sb};
    $WEB_BRIDGE{sb_parked}{$current->{source_id}} =
        { searchbot => { %SEARCHBOT }, search => $current }
        if $current && !$current->{invalidated} && web_bridge_searchbot_is_live();
    delete $WEB_BRIDGE{sb};
    %SEARCHBOT = (
        query_id => $query_id, collection_id => $collection_id, active => 0,
        state => 'complete', from_list => 1, server_tag => $server_tag,
        network_id => $network_id, channel => $channel, query => "list of $sender",
        source_timestamp => $stamp, results => $done->{results}, server => $server,
        server_identity => server_connection_identity($server),
        connection_epoch => server_connection_epoch($server),
        casemapping => server_casemapping($server),
    );
    local $WEB_BRIDGE{download_operation_id} = $operation_id;
    local $WEB_BRIDGE{download_network_dir} = $source->{host}
        if $source->{managed_endpoint};
    local $WEB_BRIDGE_SAID = [];
    cmd_searchbot_get("$collection_id:1 --sender $sender", $server);
    my $job = $JOBS{coordinator}->job_by_web_operation($operation_id);
    unless ($job) {
        my $why = @$WEB_BRIDGE_SAID ? safe_field($WEB_BRIDGE_SAID->[-1])
            : 'the SearchBot safety checks did not start a download';
        return web_bridge_refusal('download_not_started', substr($why, 0, 400));
    }
    $WEB_BRIDGE{last_job_id} = $job->{id};
    return { job_id => $job->{id}, state => $job->{state}, job => web_bridge_job_view($job) };
}

sub web_bridge_list_request {
    my ($source, $source_id, $sender, $operation_id, %options) = @_;
    # A list a server offered unasked after "!list" (2026-10-28): taken as an
    # asked one is, but nothing is sent; the offer it takes is still pending.
    my $held = $options{held};
    return web_bridge_refusal('search_active', 'wait for the running search to finish first')
        if any_find_active() || $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
    return web_bridge_refusal('transfer_busy', 'finish or cancel the current transfer first')
        if $S{active} || searchbot_direct_active() || $DOWNLOAD_PATH_OWNER ||
            has_active_download_transfer();
    return web_bridge_refusal('download_not_started', 'the list modules could not be loaded')
        unless load_searchbot_provider() && load_dcc_policy() && load_advert_reader();
    return web_bridge_refusal('invalid_arguments', 'that is not a safe IRC nick')
        unless searchbot_nick_is_safe($sender) && $sender =~ /\A[A-Za-z0-9\-\[\]\\`_^{}|]{1,64}\z/;
    my $source_view = web_bridge_source_view($source);
    return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
        unless $source_view && $source_view->{state} eq 'ready';
    my $server = web_bridge_source_server($source);
    my $channel = $source->{channel};
    return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
        unless $server && $server->{connected} && server_has_joined_channel($server, $channel) &&
            eval { $server->can('send_raw') };
    return web_bridge_refusal('download_not_started',
        'Irssi DCC auto-accept is on; turn it off before asking for a list')
        if Irssi::settings_get_bool('dcc_autoget');
    my $mapping = server_casemapping($server);
    my $who = FServe::ConnectionIdentity::irc_casefold($sender, $mapping);
    my $seen = web_bridge_adverts_for($source)->{servers}{$who};
    return web_bridge_refusal('not_a_list_server',
        "$sender has not been seen offering a list in $channel")
        unless $held || $options{advertised} ||
            ($seen && grep { $_->{kind} eq 'list' } @{$seen->{advert}{triggers} || []});
    return web_bridge_refusal('offer_gone', "$sender is not offering that list now")
        if $held && !servers_noted_offer($source_id, $server, $sender, $held->{name});
    my $identity = server_connection_identity($server);
    my $epoch = server_connection_epoch($server);
    my $asked_key = join("\x1f", $identity, $epoch, $who);
    return web_bridge_refusal('repeat_refused',
        "a list was already asked of $sender on this connection; a late answer to that " .
        'request could not be told from an answer to a second one')
        if $LIST_ASKED{$asked_key} && !$LIST_RETRY_OK{$asked_key};
    my $request_line = '@' . $sender;
    my $attempt = $LIST_ASKED{$asked_key} ? ($LIST_ATTEMPTS{$asked_key} // 1) + 1 : 1;
    my $list_tuple = $FServe::Discovery::SearchBotRequest::LIST_TUPLE_NAME .
        ($attempt > 1 ? "\x1f$attempt" : '');
    my $wire = "PRIVMSG $channel :$request_line";
    return web_bridge_refusal('invalid_arguments', 'the request would be longer than an IRC line')
        if length($wire) + 2 > 512;

    my $offer_timeout_ms = bounded_timeout_setting(
        'fscrawl_list_offer_timeout_ms', 300000, 1000, 900000);
    my $transfer_timeout_ms = bounded_timeout_setting(
        'fscrawl_searchbot_content_transfer_timeout_ms', 300000, 1000, 1800000);
    my $download_dir = lists_dir();
    my $output_dir = resolve_irssi_path(Irssi::settings_get_str('fscrawl_output_dir'));
    my $request_id = 'lsreq-' . ++$SEARCHBOT_DIRECT_SEQUENCE . '-' .
        substr(sha256_hex(join("\0", $sender, $identity, $epoch, $$, time, rand())), 0, 24);
    my $log_path = File::Spec->catfile($output_dir, "list-request-$request_id.tsv");
    my $ready = eval {
        make_path($output_dir) unless -d $output_dir;
        make_path($download_dir) unless -d $download_dir;
        open my $fh, '>>', $log_path or die "cannot create request evidence log: $!";
        close $fh or die "cannot close request evidence log: $!";
        1;
    };
    return web_bridge_refusal('download_not_started',
        'the lists folder or request log could not be prepared') unless $ready;
    my $server_tag = $server->{tag} // '';
    my $network_id = $server->{chatnet} // $server_tag;
    my $file = {
        type => 'file', name => undef, network_id => $network_id, server_nick => $sender,
        expected_sender => $sender, download_dir => $download_dir, log_file => $log_path,
        retrieval_protocol => 'searchbot_direct_send', list_request => 1,
        replace_same_name => 1,
        ($source->{managed_endpoint} ? (destination_network => $source->{host}) : ()),
    };
    my $job_id = new_job(
        provider => 'list', server => $server,
        selection => {
            expected_peer => $sender, sender => $sender,
            basename => $list_tuple,
            exact_payload => $request_line, originating_channel => $channel,
            asked_at => time(),
        },
        context => { channel => $channel, server_tag => $server_tag,
            web_operation_id => $operation_id },
        limits => { offer_timeout_ms => $offer_timeout_ms,
            transfer_timeout_ms => $transfer_timeout_ms, content_bytes => $LIST_MAX_BYTES },
    ) or return web_bridge_refusal('download_not_started',
        'the durable job record could not be created');
    $file->{phase6_job_id} = $job_id;
    my $restore_to = Irssi::settings_get_str('dcc_download_path');
    unless (prepare_download_staging($file)) {
        Irssi::settings_set_str('dcc_download_path', $restore_to);
        job_transition($job_id, 'stale', reason => 'staging could not be prepared');
        return web_bridge_refusal('download_not_started', 'a staging folder could not be prepared');
    }
    %SEARCHBOT_DIRECT = (
        request_id => $request_id, list_request => 1, request_line => $request_line,
        asked_key => $asked_key, attempt => $attempt,
        any_sender => ($options{typed} && !$held ? 1 : 0),
        network_id => $network_id, server_tag => $server_tag, server => $server,
        server_identity => $identity, connection_epoch => $epoch, casemapping => $mapping,
        channel => $channel, expected_sender => $sender, expected_basename => undef,
        state => 'preflight', requested_at => undef, offer_deadline => undef,
        transfer_timeout_ms => $transfer_timeout_ms, offer_timeout_ms => $offer_timeout_ms,
        max_content_bytes => $LIST_MAX_BYTES, staging_dir => $file->{staging_dir},
        log_path => $log_path, file => $file, phase6_job_id => $job_id,
        path_owner_key => $request_id, restore_path => $restore_to,
    );
    $DOWNLOAD_PATH_OWNER = {
        key => $request_id, request_id => $request_id,
        restore_to => $restore_to, path_selected => 0, kind => 'list_request',
    };
    log_to_path($log_path, 'LIST_REQUEST_SELECTED',
        'id=' . $request_id . ' sender=' . $sender . ' channel=' . $channel .
        ($SEARCHBOT_DIRECT{any_sender} ? ' from=any' : ''));
    my $intent = eval {
        $JOBS{coordinator}->begin_dispatch($job_id,
            casemapping => job_casemapping($JOBS{coordinator}->job($job_id), $server),
            effective_limits => { offer_timeout_ms => $offer_timeout_ms,
                transfer_timeout_ms => $transfer_timeout_ms, content_bytes => $LIST_MAX_BYTES });
    };
    unless ($intent) {
        my $why = $@ || 'the list reservation could not be recorded';
        $why =~ s/[\r\n]+/ /g;
        $SEARCHBOT_DIRECT{state} = 'preflight_failed';
        searchbot_direct_release_path_owner(\%SEARCHBOT_DIRECT);
        job_transition($job_id, 'stale', reason => 'durable list reservation refused')
            if ($JOBS{coordinator}->job($job_id) || {})->{state} eq 'held';
        return web_bridge_refusal('download_not_started', substr(safe_field($why), 0, 400));
    }
    $SEARCHBOT_DIRECT{state} = 'dispatch_pending';
    return web_bridge_list_take_held($server, $source_id, $sender, $held->{name}, $job_id,
        $request_id, $asked_key) if $held;
    my $route = outbound_route_key($server, $channel, $sender, 'searchbot');
    my $scheduled = schedule_irc_message(
        server => $server, kind => 'query', route => $route,
        owner_kind => 'searchbot_direct', owner_id => $request_id, owner_job_id => $job_id,
        guard => sub {
            ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id &&
                ($SEARCHBOT_DIRECT{state} // '') eq 'dispatch_pending' &&
                $server->{connected} && server_connection_identity($server) eq $identity &&
                server_connection_epoch($server) == $epoch &&
                server_has_joined_channel($server, $channel)
        },
        before_send => sub {
            return 0 unless ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id &&
                ($SEARCHBOT_DIRECT{state} // '') eq 'dispatch_pending';
            $SEARCHBOT_DIRECT{state} = 'dispatching';
            $SEARCHBOT_DIRECT{dispatch_attempted} = 1;
            $SEARCHBOT_DIRECT{requested_at} = time();
            $SEARCHBOT_DIRECT{offer_deadline} = time() + $offer_timeout_ms / 1000;
            $LIST_ASKED{$asked_key} = time();
            $LIST_ATTEMPTS{$asked_key} = $attempt;
            delete $LIST_RETRY_OK{$asked_key};
            my $timer = Irssi::timeout_add_once($offer_timeout_ms, sub {
                expire_searchbot_direct($request_id, 'awaiting_offer');
            }, undef);
            die 'offer timer registration failed' unless defined $timer;
            $SEARCHBOT_DIRECT{timer} = $timer;
            log_to_path($log_path, 'LIST_REQUEST_DISPATCH_ATTEMPT',
                'request=' . $request_id . ' marked asked before transport invocation');
            return 1;
        },
        send => sub {
            $server->send_raw($wire);
            engine_log_sent_raw($server, $wire);
        },
        on_done => sub {
            my ($status, $reason) = @_;
            return unless ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id;
            delete $SEARCHBOT_DIRECT{outbound_token};
            return if $SEARCHBOT_DIRECT{retiring};
            if ($status eq 'sent') {
                eval { $JOBS{coordinator}->record_dispatch_result($job_id,
                    'sent', outcome => 'list_request_sent'); };
                $SEARCHBOT_DIRECT{state} = 'awaiting_offer'
                    if ($SEARCHBOT_DIRECT{state} // '') eq 'dispatching';
                p("Asked $sender for its list in $channel once; taking one .txt, .zip, .rar or .7z list " .
                    "of at most $LIST_MAX_BYTES bytes from $sender within ${offer_timeout_ms}ms.");
                return;
            }
            my $why = safe_field($reason // $status);
            if ($status eq 'refused' || $status eq 'paused_before_send') {
                delete $LIST_ASKED{$asked_key};
                eval { $JOBS{coordinator}->record_dispatch_result($job_id,
                    'cancelled_before_transport', outcome => 'pre_dispatch_refused',
                    reason => $why); };
                retire_searchbot_direct('preflight_failed', $why);
                return;
            }
            eval { $JOBS{coordinator}->record_dispatch_result($job_id,
                'unknown', outcome => 'dispatch_outcome_unknown', reason => $why); };
            retire_searchbot_direct('dispatch_uncertain', $why);
            p("The list request's dispatch outcome is uncertain; it was not resent: $why.");
        },
    );
    unless ($scheduled) {
        eval { $JOBS{coordinator}->record_dispatch_result($job_id,
            'unknown', outcome => 'searchbot_scheduler_unavailable'); };
        retire_searchbot_direct('dispatch_uncertain',
            'outbound scheduler could not reserve the list request');
        return web_bridge_refusal('download_not_started',
            'the outbound scheduler could not reserve the request; it was not sent');
    }
    $SEARCHBOT_DIRECT{outbound_token} = $scheduled->{token}
        if ($scheduled->{status} // '') eq 'pending' &&
            ($SEARCHBOT_DIRECT{request_id} // '') eq $request_id;
    my $job = $JOBS{coordinator}->job($job_id);
    $WEB_BRIDGE{last_job_id} = $job_id;
    return { job_id => $job_id, state => $job->{state}, job => web_bridge_job_view($job) };
}

# The adverts belong to one server and channel: pointing the source elsewhere
# starts afresh.
sub web_bridge_adverts_for {
    my ($source) = @_;
    my $key = join("\x1f", lc($source->{host} // $source->{server_tag} // ''),
        $source->{port} || 0, lc($source->{channel} // ''));
    my $book = $WEB_BRIDGE_ADVERTS{$source->{source_id}};
    unless ($book && $book->{key} eq $key) {
        $book = $WEB_BRIDGE_ADVERTS{$source->{source_id}} =
            { key => $key, servers => {}, pending => {}, unrecognised => 0 };
    }
    return $book;
}

sub sig_advert_public {
    my ($server, $message, $nick, $address, $target) = @_;
    return unless ref($server) && defined($message) && defined($nick) && defined($target);
    # Most channel text is none of these; this keeps the cost of a busy
    # channel low. A list server names "@" and its own nick.
    return unless index($message, 'Fserve Active') >= 0 || index($message, 'SysReset') >= 0 ||
        index($message, 'FServe Online') >= 0 || index(lc($message), '@' . lc($nick)) >= 0;
    # A search bot's channel has file and list servers of its own, so every
    # source listens, whatever it searches with (2026-10-28).
    my @sources = grep {
        $_->{desired_joined} && lc($_->{server_tag} // '') eq lc($server->{tag} // '')
    } values %WEB_BRIDGE_SOURCES;
    return unless @sources && load_advert_reader();
    my $mapping = server_casemapping($server);
    my $channel = FServe::ConnectionIdentity::irc_casefold($target, $mapping);
    for my $source (@sources) {
        next unless FServe::ConnectionIdentity::irc_casefold($source->{channel}, $mapping) eq $channel;
        web_bridge_record_advert($source, $mapping, $nick, $message);
    }
}

# "!list" (2026-10-28): asked of a source's channel at most once a minute,
# through the scheduler's spacing. For two minutes after it is sent, what
# servers answer to us (notices such as "List trigger(s): @Nick OmenServe
# 2.74", or "I have the following lists: @Nick, @Nick-New") is read as their
# adverts are: the sender naming "@" and its own nick, so "-New" lists fall
# away. A list file a server offers unasked in that time, by DCC, is noted,
# and the page takes it as Get list takes one (list.accept): one at a time, a
# .txt, .zip, .rar or .7z of at most $LIST_MAX_BYTES, from a nick that answered
# or is in the channel. Every other offer is left as before, untaken.
our $SERVERS_ASK_SECONDS = 60;
our $SERVERS_LISTEN_SECONDS = 120;
our $SERVERS_OFFER_SECONDS = 300;
my $SERVERS_MAX_OFFERS = 16;
my $SERVERS_MAX_ANSWERS = 200;
my %SERVERS_ASKED;   # source_id => the last "!list" and what came of it

sub web_bridge_servers_ask {
    my ($source, $source_id) = @_;
    my $source_view = web_bridge_source_view($source);
    my $server = web_bridge_source_server($source);
    my $channel = $source->{channel};
    return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
        unless $source_view && $source_view->{state} eq 'ready' && $server &&
            $server->{connected} && server_has_joined_channel($server, $channel) &&
            eval { $server->can('send_raw') };
    my $now = time();
    my $last = $SERVERS_ASKED{$source_id};
    if ($last && $now - $last->{asked_at} < $SERVERS_ASK_SECONDS) {
        my $wait = $SERVERS_ASK_SECONDS - int($now - $last->{asked_at});
        return web_bridge_refusal('too_soon',
            "the servers were asked less than a minute ago; ask again in ${wait} s");
    }
    return web_bridge_refusal('download_not_started', 'the advert reader could not be loaded')
        unless load_advert_reader();
    my $identity = server_connection_identity($server);
    my $epoch = server_connection_epoch($server);
    my $wire = "PRIVMSG $channel :!list";
    my $route = outbound_route_key($server, $channel, $channel, 'serverlist');
    my $entry = {
        asked_at => $now, state => 'pending', until => undef, identity => $identity,
        epoch => $epoch, server_tag => $server->{tag}, answered => {}, offers => {},
    };
    $SERVERS_ASKED{$source_id} = $entry;
    my $current = sub { ($SERVERS_ASKED{$source_id} // 0) == $entry };
    my $scheduled = schedule_irc_message(
        server => $server, kind => 'query', route => $route,
        owner_kind => 'servers_ask', owner_id => $source_id,
        guard => sub {
            $current->() && $server->{connected} &&
                server_connection_identity($server) eq $identity &&
                server_connection_epoch($server) == $epoch &&
                server_has_joined_channel($server, $channel)
        },
        before_send => sub {
            return 0 unless $current->() && $entry->{state} eq 'pending';
            $entry->{state} = 'sending';
            return 1;
        },
        send => sub {
            $server->send_raw($wire);
            engine_log_sent_raw($server, $wire);
        },
        on_done => sub {
            my ($status, $reason) = @_;
            return unless $current->();
            if ($status eq 'sent') {
                $entry->{state} = 'listening';
                $entry->{until} = time() + $SERVERS_LISTEN_SECONDS;
                engine_log_add('engine', $server, "Asked the servers in $channel for their " .
                    'lists (!list); reading their answers for two minutes');
                return;
            }
            $entry->{reason} = safe_field($reason // $status);
            # Not sent: it may be asked again at once. Sent or not, unknown: not.
            if ($status eq 'refused' || $status eq 'paused_before_send') {
                delete $SERVERS_ASKED{$source_id};
            } else {
                $entry->{state} = 'failed';
            }
        },
    );
    unless ($scheduled) {
        delete $SERVERS_ASKED{$source_id};
        return web_bridge_refusal('download_not_started',
            'the outbound scheduler could not take the request; it was not sent');
    }
    return web_bridge_servers_view($source_id);
}

sub web_bridge_servers_view {
    my ($source_id) = @_;
    my $now = time();
    my $entry = $SERVERS_ASKED{$source_id};
    return { source_id => $source_id, now => $now, state => 'idle', next_ask_at => $now,
             answered => [], offers => [] } unless $entry;
    servers_prune_offers($entry, $now);
    my $state = $entry->{state};
    $state = 'done' if $state eq 'listening' && $now > ($entry->{until} // 0);
    return {
        source_id => $source_id, now => $now, state => $state,
        asked_at => $entry->{asked_at}, listening_until => $entry->{until},
        next_ask_at => $entry->{asked_at} + $SERVERS_ASK_SECONDS,
        (defined($entry->{reason}) ? (reason => $entry->{reason}) : ()),
        answered => [sort { lc($a) cmp lc($b) } values %{$entry->{answered}}],
        offers => [map { +{ sender => $_->{sender}, name => $_->{name}, size => $_->{size} } }
            sort { $a->{at} <=> $b->{at} || $a->{name} cmp $b->{name} }
            values %{$entry->{offers}}],
    };
}

sub servers_prune_offers {
    my ($entry, $now) = @_;
    for my $key (keys %{$entry->{offers}}) {
        delete $entry->{offers}{$key}
            if $now - $entry->{offers}{$key}{at} > $SERVERS_OFFER_SECONDS;
    }
}

sub servers_listening_on {
    my ($server, $now) = @_;
    return () unless keys(%SERVERS_ASKED) && ref($server);
    my $identity = server_connection_identity($server);
    my $epoch = server_connection_epoch($server);
    return grep {
        my $entry = $SERVERS_ASKED{$_};
        # An answer may come in before the send is reported done.
        ($entry->{state} eq 'sending' ||
            ($entry->{state} eq 'listening' && $now <= ($entry->{until} // 0))) &&
            $entry->{identity} eq $identity && $entry->{epoch} == $epoch &&
            $WEB_BRIDGE_SOURCES{$_}
    } keys %SERVERS_ASKED;
}

# What a server says to us after "!list", read as its advert.
sub sig_servers_answer {
    my ($server, $message, $nick, $address, $target) = @_;
    return unless keys(%SERVERS_ASKED) && ref($server) && defined($message) && defined($nick);
    return if defined($target) && $target =~ /\A[#&+!]/;
    my @listening = servers_listening_on($server, time()) or return;
    return unless load_advert_reader();
    my $mapping = server_casemapping($server);
    my $who = FServe::ConnectionIdentity::irc_casefold($nick, $mapping);
    for my $source_id (@listening) {
        my $entry = $SERVERS_ASKED{$source_id};
        next unless web_bridge_record_advert($WEB_BRIDGE_SOURCES{$source_id}, $mapping,
            $nick, $message);
        $entry->{answered}{$who} = $nick
            if exists($entry->{answered}{$who}) ||
                keys(%{$entry->{answered}}) < $SERVERS_MAX_ANSWERS;
    }
}

# A DCC offer nothing asked for, while a source listens: noted when it is a
# list from a server that answered or is in the channel.
sub servers_note_offer {
    my ($dcc) = @_;
    return unless keys(%SERVERS_ASKED) && ref($dcc) && uc($dcc->{type} // '') eq 'GET';
    my $server = $dcc->{server};
    my $now = time();
    my @listening = servers_listening_on($server, $now) or return;
    my ($nick, $name, $size) = ($dcc->{nick} // '', $dcc->{arg} // '', $dcc->{size});
    return unless $name =~ /\A[^\/\\\x00-\x1f\x7f]{1,200}\.(?:txt|zip|rar|7z)\z/i &&
        $name !~ /\A[. ]/ && $name !~ /[. ]\z/;
    return unless defined($size) && !ref($size) && $size =~ /\A\d+\z/ &&
        $size > 0 && $size <= $LIST_MAX_BYTES;
    return unless load_advert_reader();
    my $mapping = server_casemapping($server);
    my $who = FServe::ConnectionIdentity::irc_casefold($nick, $mapping);
    for my $source_id (@listening) {
        my $entry = $SERVERS_ASKED{$source_id};
        my $in_channel = eval {
            my $channel = $server->channel_find($WEB_BRIDGE_SOURCES{$source_id}{channel});
            $channel && $channel->nick_find($nick);
        };
        next unless exists($entry->{answered}{$who}) || $in_channel;
        my $key = $who . "\x1f" . $name;
        next if !exists($entry->{offers}{$key}) &&
            keys(%{$entry->{offers}}) >= $SERVERS_MAX_OFFERS;
        $entry->{offers}{$key} = { sender => $nick, name => $name, size => 0 + $size, at => $now };
        engine_log_add('engine', $server, "$nick offered its list \"" . safe_field($name) .
            '" after !list; it is taken in turn');
    }
}

sub servers_noted_offer {
    my ($source_id, $server, $sender, $name) = @_;
    my $entry = $SERVERS_ASKED{$source_id} or return 0;
    servers_prune_offers($entry, time());
    my $mapping = server_casemapping($server);
    my $key = FServe::ConnectionIdentity::irc_casefold($sender, $mapping) . "\x1f" . ($name // '');
    return $entry->{offers}{$key} && $entry->{identity} eq server_connection_identity($server) ? 1 : 0;
}

sub servers_forget_offer {
    my ($source_id, $server, $sender, $name) = @_;
    my $entry = $SERVERS_ASKED{$source_id} or return;
    my $mapping = server_casemapping($server);
    delete $entry->{offers}{FServe::ConnectionIdentity::irc_casefold($sender, $mapping) .
        "\x1f" . $name};
}

# The pending, untaken offer of $name from $sender on this connection.
sub servers_pending_dcc {
    my ($server, $sender, $name) = @_;
    my @native = eval { require Irssi::Irc; Irssi::Irc::dccs() };
    my $mapping = server_casemapping($server);
    my $who = FServe::ConnectionIdentity::irc_casefold($sender, $mapping);
    my $identity = server_connection_identity($server);
    for my $dcc (@native) {
        next unless ref($dcc) && uc($dcc->{type} // '') eq 'GET' && ($dcc->{arg} // '') eq $name;
        next unless FServe::ConnectionIdentity::irc_casefold($dcc->{nick} // '', $mapping) eq $who;
        next unless $dcc->{server} && server_connection_identity($dcc->{server}) eq $identity;
        my $key = dcc_transfer_identity_key($dcc);
        next if !$key || $TRANSFERS{$key} || $USED_TRANSFER_IDENTITIES{$key} ||
            ($dcc->{starttime} // 0);
        return $dcc;
    }
    return;
}

sub web_bridge_list_take_held {
    my ($server, $source_id, $sender, $name, $job_id, $request_id, $asked_key) = @_;
    $SEARCHBOT_DIRECT{state} = 'dispatching';
    $SEARCHBOT_DIRECT{dispatch_attempted} = 1;
    $SEARCHBOT_DIRECT{requested_at} = time();
    $SEARCHBOT_DIRECT{offer_deadline} = time() + 30;
    $LIST_ASKED{$asked_key} = time();
    $LIST_ATTEMPTS{$asked_key} = $SEARCHBOT_DIRECT{attempt} // 1;
    delete $LIST_RETRY_OK{$asked_key};
    servers_forget_offer($source_id, $server, $sender, $name);
    eval { $JOBS{coordinator}->record_dispatch_result($job_id, 'sent',
        outcome => 'unasked_list_taken'); };
    $SEARCHBOT_DIRECT{state} = 'awaiting_offer';
    my $timer = eval { Irssi::timeout_add_once(30000, sub {
        expire_searchbot_direct($request_id, 'awaiting_offer');
    }, undef) };
    $SEARCHBOT_DIRECT{timer} = $timer if defined $timer;
    log_to_path($SEARCHBOT_DIRECT{log_path}, 'LIST_OFFER_TAKEN_UNASKED',
        'request=' . $request_id . ' sender=' . safe_field($sender) .
        ' filename=[' . safe_field($name) . ']');
    my $dcc = servers_pending_dcc($server, $sender, $name);
    if ($dcc) {
        handle_searchbot_content_offer($dcc);
    } else {
        retire_searchbot_direct('expired', 'the list is no longer offered');
    }
    my $job = $JOBS{coordinator}->job($job_id);
    $WEB_BRIDGE{last_job_id} = $job_id;
    return { job_id => $job_id, state => $job->{state}, job => web_bridge_job_view($job) };
}

sub web_bridge_record_advert {
    my ($source, $mapping, $nick, $message) = @_;
    my $book = web_bridge_adverts_for($source);
    my $now = time();
    my $pending = $book->{pending};
    for my $who (keys %$pending) {
        delete $pending->{$who} if $now - $pending->{$who}{at} > $ADVERT_HEAD_WAIT_SECONDS;
    }
    my $advert = index($message, 'FServe Online') >= 0
        ? FServe::Discovery::FservePlAdvert::parse_advert_line($message) : undef;
    $advert ||= FServe::Discovery::SysResetAdvert::parse_advert_line($message);
    # A file server whose advert also names "@" and its own nick, as one
    # FServe.pl server's "@Nick for my file list" (2026-10-29), offers a list
    # too: the same rule as a list server's advert.
    my $offers_list = $advert && FServe::Discovery::ListAdvert::parse_advert_line($message, $nick)
        ? 1 : 0;
    $advert ||= FServe::Discovery::ListAdvert::parse_advert_line($message, $nick);
    unless ($advert) {
        $book->{unrecognised}++
            if index($message, 'Fserve Active') >= 0 || index($message, 'FServe Online') >= 0;
        return;
    }
    my $who = FServe::ConnectionIdentity::irc_casefold($nick, $mapping);
    if ($advert->{part} eq 'head') {
        $pending->{$who} = { at => $now, advert => $advert, offers_list => $offers_list }
            if exists($pending->{$who}) || keys(%$pending) < $ADVERT_MAX_PENDING;
        return;
    }
    if ($advert->{part} eq 'tail') {
        my $head = delete $pending->{$who} or return;
        $offers_list ||= $head->{offers_list};
        $advert = FServe::Discovery::SysResetAdvert::merge_advert_parts($head->{advert}, $advert);
        unless ($advert) {
            $book->{unrecognised}++;
            return;
        }
    }
    if ($offers_list && ($advert->{script} // '') ne 'list' &&
            !grep { $_->{kind} eq 'list' } @{$advert->{triggers} || []}) {
        $advert = { %$advert,
            triggers => [@{$advert->{triggers} || []}, { trigger => '@' . $nick, kind => 'list' }] };
    }
    delete $pending->{$who};
    my $servers = $book->{servers};
    my $entry = $servers->{$who};
    unless ($entry) {
        if (keys(%$servers) >= $ADVERT_MAX_SERVERS) {
            my $oldest;
            for my $other (keys %$servers) {
                $oldest = $other if !defined($oldest) ||
                    $servers->{$other}{order} < $servers->{$oldest}{order};
            }
            delete $servers->{$oldest};
        }
        $entry = $servers->{$who} = { first_seen => $now, seen_count => 0 };
    }
    for my $trigger (@{$advert->{triggers} || []}) {
        next unless $trigger->{kind} eq 'ctcp';
        $trigger->{ctcp_nick_is_sender} = FServe::ConnectionIdentity::same_irc_identity(
            $trigger->{ctcp_nick}, $nick, $mapping);
    }
    # The clock ties within a second; this keeps "most recently seen" exact.
    @{$entry}{qw(nick last_seen advert order)} = ($nick, $now, $advert, ++$book->{sequence});
    $entry->{seen_count}++;
    return 1;
}

sub web_bridge_adverts_page {
    my ($source, $offset, $limit) = @_;
    my $book = web_bridge_adverts_for($source);
    my $servers = $book->{servers};
    my @order = sort { $servers->{$b}{order} <=> $servers->{$a}{order} } keys %$servers;
    my $end = $offset + $limit;
    $end = @order if $end > @order;
    my @page = $offset < @order ? @order[$offset .. $end - 1] : ();
    return {
        source_id => $source->{source_id},
        now => time(),
        total => scalar(@order),
        offset => $offset,
        unrecognised => $book->{unrecognised},
        adverts => [map { web_bridge_advert_view($servers->{$_}) } @page],
    };
}

sub web_bridge_advert_view {
    my ($entry) = @_;
    my $advert = $entry->{advert};
    my %view = (
        nick => $entry->{nick},
        first_seen => $entry->{first_seen},
        last_seen => $entry->{last_seen},
        seen_count => $entry->{seen_count},
        script => $advert->{script} // 'sysreset',
        triggers => [map {
            my $trigger = $_;
            +{
                trigger => $trigger->{trigger},
                kind => $trigger->{kind},
                (map { exists($trigger->{$_}) ? ($_ => $trigger->{$_}) : () }
                    qw(ctcp_nick pool queued queue_limit)),
                ($trigger->{kind} eq 'ctcp' ? (ctcp_nick_is_sender =>
                    $trigger->{ctcp_nick_is_sender} ? JSON::PP::true : JSON::PP::false) : ()),
                voice_only => $trigger->{voice_only} ? JSON::PP::true : JSON::PP::false,
            }
        } @{$advert->{triggers} || []}],
    );
    for my $key (qw(restricted version message notice content users sends queues stats)) {
        $view{$key} = $advert->{$key} if exists $advert->{$key};
    }
    return \%view;
}

1;
