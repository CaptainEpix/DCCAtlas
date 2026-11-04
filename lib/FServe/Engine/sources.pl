# Sources: the IRC connections the page manages, their logins, joins and losses.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use Digest::SHA qw(sha256_hex);
use File::Spec ();
use JSON::PP ();
use Scalar::Util qw(refaddr);
use Socket qw(AF_INET6 inet_pton);

our (%FIND, %JOBS, %S, %SEARCHBOT, %SEARCHBOT_DIRECT, %TRANSFERS, %WEB_BRIDGE,
     %WEB_BRIDGE_SOURCES, $PROCESS_INCARNATION, $WEB_BRIDGE);

my $CONNECTION_EPOCH_SEQUENCE = 0;
my %SERVER_CONNECTION_EPOCH;
my $WEB_BRIDGE_CONNECT_SEQUENCE = 0;

sub server_casemapping {
    my ($server) = @_;
    return 'rfc1459' unless ref($server);
    my $mapping = eval {
        $server->can('isupport') ? $server->isupport('CASEMAPPING') : undef;
    };
    $mapping = eval { $server->{casemapping} }
        unless defined($mapping) && length($mapping);
    $mapping = eval { $server->{isupport}{CASEMAPPING} }
        unless defined($mapping) && length($mapping);
    $mapping = lc($mapping // 'rfc1459');
    return $mapping =~ /\A(?:ascii|strict-rfc1459|rfc1459)\z/ ? $mapping : 'rfc1459';
}

sub job_casemapping {
    my ($job, $server) = @_;
    my $mapping = lc(($job && $job->{context}{casemapping}) // '');
    return $mapping if $mapping =~ /\A(?:ascii|strict-rfc1459|rfc1459)\z/;
    return server_casemapping($server);
}

sub server_context {
    my ($server) = @_;
    return {} unless ref($server);
    my $network = $server->{chatnet} // $server->{tag} // '';
    return {
        network_profile => $network,
        server_tag => $server->{tag} // '',
        connection_identity => server_connection_identity($server),
        connection_epoch => server_connection_epoch($server),
        process_incarnation => $PROCESS_INCARNATION,
        casemapping => server_casemapping($server),
    };
}

sub remember_live_server {
    my ($server, %args) = @_;
    return unless ref($server) && ($server->{connected} || $args{connecting});
    my $identity = server_connection_identity($server);
    my $epoch = server_connection_epoch($server);
    return unless defined($identity) && defined($epoch);
    $JOBS{live_servers}{$identity}{$epoch} = $server;
    return $server;
}

sub sig_server_connected {
    my ($server) = @_;
    return unless ref($server);
    # A server object can reconnect with the same native pointer. The
    # disconnect handler advances that pointer's epoch. Irssi emits this
    # signal before its connected flag is set, so record the object now while
    # keeping the normal dispatch-time connected check authoritative.
    remember_live_server($server, connecting => 1);
    for my $source (values %WEB_BRIDGE_SOURCES) {
        next unless web_bridge_bind_source_server($source, $server);
        unless ($source->{desired_joined}) {
            web_bridge_schedule_managed_disconnect($source->{source_id}, $server);
            next;
        }
        web_bridge_schedule_source_join($source->{source_id}, $server);
    }
}

sub web_bridge_schedule_managed_disconnect {
    my ($source_id, $server) = @_;
    my $source = $WEB_BRIDGE_SOURCES{$source_id} or return;
    return unless $source->{managed_endpoint} && !$source->{desired_joined};
    Irssi::timeout_remove(delete $source->{disconnect_timer})
        if defined $source->{disconnect_timer};
    my $generation = ++$source->{disconnect_generation};
    my $server_tag = $server->{tag};
    my $server_identity = server_connection_identity($server);
    my $server_epoch = server_connection_epoch($server);
    web_bridge_set_source_state($source, 'leaving');
    my $timer = eval { Irssi::timeout_add_once(100, sub {
        my $current = $WEB_BRIDGE_SOURCES{$source_id} or return;
        return unless !$current->{desired_joined} &&
            ($current->{disconnect_generation} || 0) == $generation &&
            defined($current->{server_tag}) &&
            lc($current->{server_tag}) eq lc($server_tag // '');
        delete $current->{disconnect_timer};
        if (web_bridge_cancel_source_reconnects($current) < 0) {
            web_bridge_set_source_state($current, 'failed',
                'Irssi could not cancel the managed reconnect');
            return;
        }
        my $live = web_bridge_source_server($current);
        return unless $live && defined($server_identity) && defined($server_epoch);
        my $live_identity = server_connection_identity($live);
        my $live_epoch = server_connection_epoch($live);
        return unless defined($live_identity) && defined($live_epoch) &&
            $live_identity eq $server_identity && $live_epoch == $server_epoch;
        $current->{disconnect_inflight} = 1;
        my $ok = web_bridge_disconnect_managed_server($live);
        unless ($ok) {
            delete $current->{disconnect_inflight};
            web_bridge_set_source_state($current, 'failed',
                'Irssi could not cancel the late managed connection');
            return;
        }
        delete $current->{connect_cancelled};
    }, undef) };
    if (defined $timer) {
        $source->{disconnect_timer} = $timer;
    } else {
        web_bridge_set_source_state($source, 'failed',
            'Irssi could not schedule managed connection cancellation');
    }
}

# A managed connection gets exactly one attempt per explicit Connect. When a
# connection fails or closes, Irssi queues a reconnect of its own; left alone
# it would try again every server_reconnect_time, unasked and unseen by the
# browser. Cancel that owned record once Irssi has finished with the closure.
# The endpoint is captured now: a newer Connect may already have a fresh tag.
sub web_bridge_schedule_reconnect_cancel {
    my ($source) = @_;
    return unless ref($source) eq 'HASH' && $source->{managed_endpoint} &&
        defined($source->{server_tag}) && length($source->{server_tag});
    my $source_id = $source->{source_id};
    my %owned = (managed_endpoint => 1,
        map { $_ => $source->{$_} } qw(host port nickname server_tag));
    eval { Irssi::timeout_add_once(10, sub {
        return unless web_bridge_cancel_source_reconnects(\%owned) < 0;
        my $current = $WEB_BRIDGE_SOURCES{$source_id} or return;
        web_bridge_set_source_state($current, 'failed',
            'Irssi could not cancel its automatic reconnect')
            if lc($current->{server_tag} // '') eq lc($owned{server_tag});
    }, undef) };
}

# Keep what the server said when it turned the connection away, so the
# browser can show more than "connection closed".
sub web_bridge_note_server_refusal {
    my ($server, $text, $key) = @_;
    return unless ref($server) && defined($text);
    $text =~ s/\A[^:]*://;
    $text = substr(safe_field($text), 0, 200);
    return unless length $text;
    for my $source (values %WEB_BRIDGE_SOURCES) {
        # Not after an explicit Disconnect: the server's goodbye is no refusal.
        next unless $source->{managed_endpoint} && $source->{desired_joined} &&
            (web_bridge_source_matches_server($source, $server) ||
                lc($source->{server_tag} // '') eq lc($server->{tag} // ''));
        $source->{$key} = $text;
    }
}

sub sig_event_error { web_bridge_note_server_refusal($_[0], $_[1], 'server_error'); }
sub sig_event_464 { web_bridge_note_server_refusal($_[0], $_[1], 'server_refusal'); }
# Irssi passes the reason as text, the server's own for a refused login
# (sasl.c, sasl_fail); without the account it ends the connection.
sub sig_server_sasl_failure {
    my ($server, $reason) = @_;
    web_bridge_note_server_refusal($server, ':login refused: ' . ($reason // 'no reason given'),
        'server_refusal');
}

sub web_bridge_closed_reason {
    my ($source, $base) = @_;
    my $said = delete $source->{server_refusal};
    my $error = delete $source->{server_error};
    $said //= $error;
    return defined($said) ? "$base: $said" : $base;
}

# The server's welcome: from here the connection is registered. A source
# with a NickServ login identifies now, as a raw line: neither the log, which
# sees only Irssi's own messages, nor Irssi's window shows it. Its JOIN then
# waits up to ten seconds for NickServ's answer, as a channel may admit only
# identified nicks.
our $WEB_BRIDGE_IDENTIFY_WAIT_SECONDS = 10;

sub sig_web_bridge_welcome {
    my ($server) = @_;
    return unless ref($server);
    for my $source (values %WEB_BRIDGE_SOURCES) {
        next unless lc($source->{server_tag} // '') eq lc($server->{tag} // '');
        $source->{welcomed} = 1;
        my $login = web_bridge_login_for($source);
        next unless $login && $login->{kind} eq 'nickserv';
        my $sent = eval {
            $server->send_raw('PRIVMSG NickServ :IDENTIFY ' .
                (defined($login->{username}) ? $login->{username} . ' ' : '') .
                $login->{password});
            1;
        };
        $source->{identify_until} = time() + $WEB_BRIDGE_IDENTIFY_WAIT_SECONDS if $sent;
        engine_log_add('engine', $server, $sent
            ? 'Identifying to NickServ' . (defined($login->{username})
                ? ' as ' . $login->{username} : '')
            : 'Could not identify to NickServ', [$source->{source_id}]);
    }
}

# NickServ's first notice after IDENTIFY ends the wait, whatever it says: its
# words are in the log.
sub sig_web_bridge_nickserv_notice {
    my ($server, $message, $nick) = @_;
    return unless ref($server) && lc($nick // '') eq 'nickserv';
    for my $source (values %WEB_BRIDGE_SOURCES) {
        delete $source->{identify_until}
            if lc($source->{server_tag} // '') eq lc($server->{tag} // '');
    }
}

sub sig_server_connect_failed {
    my ($server) = @_;
    return unless ref($server);
    # This handler runs last, after Irssi's own has printed the reason
    # (fe-server.c, sig_connect_failed); the reason itself is not passed to
    # scripts. Without signal_add_last it ran first on the lab.
    my $why = engine_log_recent_error($server);
    for my $source (values %WEB_BRIDGE_SOURCES) {
        next unless web_bridge_bind_source_server($source, $server);
        $source->{server_error} //= $why if defined $why;
        web_bridge_schedule_reconnect_cancel($source);
        my $reconnect_after_disconnect = delete $source->{reconnect_after_disconnect};
        delete $source->{disconnect_inflight};
        web_bridge_cancel_source_join_timer($source);
        if ($source->{desired_joined} && !$source->{connect_cancelled}) {
            web_bridge_set_source_state($source, 'failed',
                web_bridge_closed_reason($source, 'IRC connection failed'));
        } elsif ($source->{managed_endpoint}) {
            web_bridge_set_source_state($source, 'disconnected');
        } else {
            web_bridge_set_source_state($source, 'configured');
        }
        delete @{$source}{qw(connect_cancelled connect_pending)};
        if ($reconnect_after_disconnect && $source->{desired_joined}) {
            unless (web_bridge_start_managed_connection($source)) {
                web_bridge_set_source_state($source, 'failed',
                    delete($source->{start_failure}) //
                    'Irssi could not restart the managed connection after disconnect');
            }
        }
    }
}

sub server_connection_epoch {
    my ($server) = @_;
    return unless ref($server);
    my $identity = server_connection_identity($server);
    return unless defined($identity) && length($identity);
    $SERVER_CONNECTION_EPOCH{$identity} ||= ++$CONNECTION_EPOCH_SEQUENCE;
    return $SERVER_CONNECTION_EPOCH{$identity};
}

sub server_connection_identity {
    my ($server) = @_;
    return unless ref($server);
    my $native = eval { $server->{_irssi} };
    return 'irssi:' . $native if defined($native) && !ref($native) && length("$native");
    my $wrapper = refaddr($server);
    return defined($wrapper) ? 'wrapper:' . $wrapper : undef;
}

sub server_has_joined_channel {
    my ($server, $channel) = @_;
    return 0 unless ref($server) && defined($channel) &&
        eval { $server->can('channel_find') };
    my $item = eval { $server->channel_find($channel) };
    return 0 unless $item;
    my $joined = eval { $item->{joined} };
    return $joined ? 1 : 0 if defined $joined;
    return 1;
}

sub web_bridge_source_server {
    my ($source) = @_;
    return unless ref($source) eq 'HASH';
    my $server = defined($source->{server_tag}) && length($source->{server_tag})
        ? eval { Irssi::server_find_tag($source->{server_tag}) } : undef;
    return $server if $server;
    my ($retained) = grep {
        ref($_) && defined($source->{server_tag}) &&
            lc($_->{tag} // '') eq lc($source->{server_tag})
    } Irssi::servers();
    return $retained if $retained;
    return unless $source->{managed_endpoint} && $source->{connect_pending};
    my ($pending) = grep {
        ref($_) && lc($_->{address} // '') eq lc($source->{host} // '') &&
            ($_->{port} || 0) == ($source->{port} || 0) &&
            (!defined($source->{pending_server_tag}) ||
                lc($_->{tag} // '') eq lc($source->{pending_server_tag}))
    } Irssi::servers();
    return $pending;
}

sub web_bridge_cancel_source_reconnects {
    my ($source) = @_;
    return 0 unless ref($source) eq 'HASH' && $source->{managed_endpoint};
    my $host = lc($source->{host} // '');
    my $port = $source->{port} || 0;
    my $wanted_nick = lc($source->{nickname} // '');
    my $network_tag = lc($source->{server_tag} // '');
    return 0 unless length($network_tag);
    my @owned = grep {
        ref($_) && lc($_->{address} // '') eq $host &&
            ($_->{port} || 0) == $port &&
            lc($_->{wanted_nick} // $_->{nick} // '') eq $wanted_nick &&
            lc($_->{chatnet} // '') eq $network_tag
    } Irssi::reconnects();
    for my $reconnect (@owned) {
        my $tag = $reconnect->{tag};
        next unless defined($tag) && !ref($tag) && $tag =~ /\A\d+\z/;
        # DISCONNECT accepts Irssi's per-reconnect RECON-n tag. RMRECONNS is
        # global and could cancel an unrelated manually configured server.
        eval { Irssi::command('DISCONNECT recon-' . $tag); 1 };
    }
    my @remaining = grep {
        ref($_) && lc($_->{address} // '') eq $host &&
            ($_->{port} || 0) == $port &&
            lc($_->{wanted_nick} // $_->{nick} // '') eq $wanted_nick &&
            lc($_->{chatnet} // '') eq $network_tag
    } Irssi::reconnects();
    return @remaining ? -1 : scalar @owned;
}

sub web_bridge_disconnect_managed_server {
    my ($server) = @_;
    return 0 unless ref($server) && defined($server->{tag}) &&
        $server->{tag} =~ /\A[A-Za-z0-9_.-]{1,128}\z/;
    return eval { Irssi::command('DISCONNECT ' . $server->{tag}); 1 } ? 1 : 0;
}

sub web_bridge_source_matches_server {
    my ($source, $server) = @_;
    return 0 unless ref($source) eq 'HASH' && ref($server);
    return 1 if defined($source->{server_tag}) && length($source->{server_tag}) &&
        lc($source->{server_tag}) eq lc($server->{tag} // '');
    return 0 unless $source->{managed_endpoint} && $source->{connect_pending};
    return 0 unless lc($source->{host} // '') eq lc($server->{address} // '') &&
        ($source->{port} || 0) == ($server->{port} || 0);
    return !defined($source->{pending_server_tag}) ||
        lc($source->{pending_server_tag}) eq lc($server->{tag} // '');
}

sub web_bridge_bind_source_server {
    my ($source, $server) = @_;
    return 0 unless web_bridge_source_matches_server($source, $server);
    $source->{server_tag} = $server->{tag};
    delete @{$source}{qw(connect_pending pending_server_tag)};
    return 1;
}

sub web_bridge_start_managed_connection {
    my ($source) = @_;
    return 0 unless ref($source) eq 'HASH' && $source->{managed_endpoint};
    if (web_bridge_cancel_source_reconnects($source) < 0) {
        web_bridge_set_source_state($source, 'failed',
            'Irssi still has a pending reconnect for this managed endpoint');
        return 0;
    }
    my $tag = 'fserve-web-' . substr(sha256_hex($source->{source_id} // ''), 0, 12) .
        '-' . substr($PROCESS_INCARNATION, 0, 8) .
        '-' . ++$WEB_BRIDGE_CONNECT_SEQUENCE;
    # Without TLS the connection stays plain text, as the setting says:
    # Irssi would otherwise switch to STARTTLS whenever a server offers it.
    my $login = web_bridge_login_for($source);
    my $certificate = $login && $login->{kind} eq 'certificate';
    my $sasl = !$login ? undef : $login->{kind} eq 'sasl_plain' ? 'PLAIN'
        : $certificate ? 'EXTERNAL' : undef;
    # The caller says why the connection did not start, with these words.
    if ($certificate && (-l $login->{certificate_file} || !-f $login->{certificate_file})) {
        $source->{start_failure} =
            'the client certificate is missing from the engine; save the login again';
        return 0;
    }
    my $command = 'CONNECT -! -noautosendcmd -network ' . $tag . ' ' .
        ($source->{tls} ? '-tls -tls_verify ' .
            ($certificate ? '-tls_cert ' . irssi_quoted($login->{certificate_file}) . ' ' : '')
            : '-notls -disallow_starttls ') .
        ($source->{host} =~ /:/ ? '-6 ' : '') .
        $source->{host} . ' ' . $source->{port} . ' ' .
        irssi_quoted($login && $login->{kind} eq 'server_password' ? $login->{password} : '') .
        ' ' . $source->{nickname};
    $source->{server_tag} = $tag;
    $source->{pending_server_tag} = $tag;
    $source->{connect_pending} = 1;
    delete @{$source}{qw(server_refusal server_error welcomed identify_until)};
    # Irssi copies a network's SASL account into a connection as it creates
    # it (irc-servers-setup.c, sig_server_setup_fill_chatnet), so the network
    # holding it is removed again as soon as CONNECT returns.
    my $started = eval {
        # EXTERNAL takes no account: the server finds it by the certificate.
        Irssi::command('NETWORK ADD -sasl_mechanism ' . $sasl .
            ($sasl eq 'PLAIN' ? ' -sasl_username ' . irssi_quoted($login->{username}) .
                ' -sasl_password ' . irssi_quoted($login->{password}) : '') .
            ' ' . $tag) if $sasl;
        Irssi::command($command);
        1;
    };
    eval { Irssi::command('NETWORK REMOVE ' . $tag) } if $sasl;
    unless ($started) {
        delete @{$source}{qw(connect_pending pending_server_tag)};
        web_bridge_set_source_state($source, 'failed',
            'Irssi could not start the configured server connection');
        return 0;
    }
    engine_log_add('engine', $tag, 'Connecting to ' . $source->{host} . ' port ' .
        $source->{port} . ', TLS ' . ($source->{tls} ? 'on' : 'off') . ', as ' .
        $source->{nickname} . (!$login ? ''
            : $certificate ? ', with a client certificate (SASL EXTERNAL)'
            : $sasl ? ', with an account (SASL)'
            : $login->{kind} eq 'nickserv' ? ', to identify to NickServ'
            : ', with a server password'), [$source->{source_id}]);
    web_bridge_set_source_state($source, 'connecting');
    return 1;
}

sub web_bridge_source_view {
    my ($source) = @_;
    return unless ref($source) eq 'HASH';
    my $server = web_bridge_source_server($source);
    my $connected = $server && $server->{connected} ? 1 : 0;
    my $joined = $connected && server_has_joined_channel($server, $source->{channel}) ? 1 : 0;
    my $state = $source->{state} // 'configured';
    $state = 'disconnected'
        if !$connected && $state !~ /\A(?:connecting|failed|leaving)\z/;
    if ($joined) {
        if (!$source->{desired_joined}) {
            $state = 'leaving' unless $state eq 'failed';
        } else {
            $state = 'ready' if $state ne 'leaving';
        }
    }
    return {
        source_id => $source->{source_id},
        revision => $source->{revision},
        label => $source->{label},
        provider => $source->{provider},
        (($source->{provider} // '') eq 'searchbot'
            ? (search_bot => $source->{search_bot}) : ()),
        host => $source->{host},
        port => $source->{port},
        tls => $source->{tls} ? JSON::PP::true : JSON::PP::false,
        nickname => $source->{nickname},
        # The nick Irssi has on the server. It differs from the configured
        # one when that was in use and Irssi picked another.
        current_nick => $connected ? safe_field($server->{nick}) : undef,
        login => web_bridge_login_view($source),
        server_tag => $source->{server_tag},
        network_id => $connected ? ($server->{chatnet} // $server->{tag}) : undef,
        # Which connection this is: a new number after every reconnect, so
        # the web's download queue can tell one connection from the next.
        connection_epoch => $connected ? server_connection_epoch($server) : undef,
        channel => $source->{channel},
        state => $state,
        reason => $source->{reason},
        connected => $connected ? JSON::PP::true : JSON::PP::false,
        joined => $joined ? JSON::PP::true : JSON::PP::false,
    };
}

# True while a source is connected, joined, or part-way through a connect,
# join, part or disconnect. Its settings must not change, and it must not be
# removed, until it is at rest.
sub web_bridge_source_in_use {
    my ($previous) = @_;
    return 0 unless ref($previous) eq 'HASH';
    my $previous_server = web_bridge_source_server($previous);
    return 1
                if $previous->{join_pending} || $previous->{part_pending} ||
                    defined($previous->{disconnect_timer}) ||
                    $previous->{disconnect_inflight} ||
                    (($previous->{state} // '') eq 'leaving' &&
                        $previous->{managed_endpoint}) ||
                    $previous->{connect_pending} ||
                    defined($previous->{join_timer}) ||
                    ($previous->{desired_joined} &&
                        ($previous->{state} // '') eq 'connecting') ||
                    ($previous_server && $previous_server->{connected} &&
                        ($previous->{managed_endpoint} ||
                            server_has_joined_channel($previous_server, $previous->{channel})));
    return 0;
}

sub web_bridge_set_source_state {
    my ($source, $state, $reason) = @_;
    return unless ref($source) eq 'HASH';
    my $was = $source->{state} // '';
    $source->{state} = $state;
    $source->{reason} = safe_field($reason) if defined $reason;
    delete $source->{reason} if !defined($reason) && $state ne 'failed';
    engine_log_add('state', $source->{server_tag},
        ($source->{label} // $source->{source_id}) . ": $state" .
            (defined($source->{reason}) ? " ($source->{reason})" : ''),
        [$source->{source_id}])
        if $state ne $was || defined $reason;
    web_bridge_publish('source.state', {
        source => web_bridge_source_view($source),
        reason => $source->{reason},
    });
}

sub web_bridge_cancel_source_join_timer {
    my ($source) = @_;
    return unless ref($source) eq 'HASH';
    $source->{join_generation} = ($source->{join_generation} || 0) + 1;
    Irssi::timeout_remove(delete $source->{join_timer})
        if defined $source->{join_timer};
}

sub web_bridge_source_join_poll {
    my ($source_id, $revision, $generation, $identity, $epoch, $deadline) = @_;
    my $source = $WEB_BRIDGE_SOURCES{$source_id} or return;
    return unless ($source->{revision} || 0) == $revision &&
        ($source->{join_generation} || 0) == $generation &&
        $source->{desired_joined};
    delete $source->{join_timer};
    my $server = web_bridge_source_server($source);
    my $live_identity = $server ? server_connection_identity($server) : undef;
    my $live_epoch = $server ? server_connection_epoch($server) : undef;
    if ($server && ( ($live_identity // '') ne ($identity // '') ||
            !defined($live_epoch) || $live_epoch != $epoch)) {
        web_bridge_set_source_state($source, 'disconnected',
            'IRC connection changed before channel join');
        return;
    }
    # Irssi counts a connection as made before the server's welcome; a JOIN
    # sent then is refused (451), so a managed source waits for the 001.
    my $identifying = $source->{identify_until} && time() < $source->{identify_until};
    unless ($server && $server->{connected} && !$identifying &&
            (!$source->{managed_endpoint} || $source->{welcomed})) {
        if (time() < $deadline) {
            my $timer = eval { Irssi::timeout_add_once(100, sub {
                web_bridge_source_join_poll(
                    $source_id, $revision, $generation, $identity, $epoch, $deadline);
            }, undef) };
            unless ($timer) {
                web_bridge_set_source_state($source, 'failed',
                    'Irssi could not schedule confirmation of the server connection');
                return;
            }
            $source->{join_timer} = $timer;
            return;
        }
        web_bridge_set_source_state($source, 'failed',
            'IRC connection was not confirmed before the join timeout');
        return;
    }
    if (server_has_joined_channel($server, $source->{channel})) {
        delete $source->{join_pending};
        web_bridge_set_source_state($source, 'ready');
        return;
    }
    my $joined = eval { $server->command('JOIN ' . $source->{channel}); 1 };
    unless ($joined) {
        web_bridge_set_source_state($source, 'failed',
            'Irssi could not send the channel join command');
        return;
    }
    $source->{join_pending} = 1;
    web_bridge_set_source_state($source, 'joining');
}

sub web_bridge_schedule_source_join {
    my ($source_id, $server) = @_;
    my $source = $WEB_BRIDGE_SOURCES{$source_id} or return;
    return unless $source->{desired_joined};
    web_bridge_cancel_source_join_timer($source);
    my $revision = $source->{revision};
    my $generation = ++$source->{join_generation};
    my $identity = server_connection_identity($server);
    my $epoch = server_connection_epoch($server);
    # Registration, with its hostname and ident lookups, can take a while.
    my $deadline = time() + ($source->{managed_endpoint} ? 90 : 15);
    my $timer = eval { Irssi::timeout_add_once(100, sub {
        web_bridge_source_join_poll(
            $source_id, $revision, $generation, $identity, $epoch, $deadline);
    }, undef) };
    unless ($timer) {
        web_bridge_set_source_state($source, 'failed',
            'Irssi could not schedule the channel join');
        return;
    }
    $source->{join_timer} = $timer;
    web_bridge_set_source_state($source, 'connecting');
}

sub web_bridge_channel_joined {
    my ($channel) = @_;
    return unless ref($channel);
    my $server = eval { $channel->{server} };
    my $name = eval { $channel->{name} } // '';
    return unless $server;
    for my $source (values %WEB_BRIDGE_SOURCES) {
        next unless lc($source->{server_tag} // '') eq lc($server->{tag} // '') &&
            lc($source->{channel} // '') eq lc($name);
        delete $source->{join_pending};
        if ($source->{desired_joined}) {
            delete $source->{part_pending};
            web_bridge_set_source_state($source, 'ready');
            next;
        }
        next if $source->{part_pending};
        my $parted = eval { $server->command('PART ' . $source->{channel}); 1 };
        unless ($parted) {
            web_bridge_set_source_state($source, 'failed',
                'Irssi could not leave a channel joined after disconnect was requested');
            next;
        }
        $source->{part_pending} = 1;
        web_bridge_set_source_state($source, 'leaving');
    }
}

sub web_bridge_channel_destroyed {
    my ($channel) = @_;
    return unless ref($channel);
    my $server = eval { $channel->{server} };
    my $name = eval { $channel->{name} } // '';
    return unless $server;
    for my $source (values %WEB_BRIDGE_SOURCES) {
        next unless lc($source->{server_tag} // '') eq lc($server->{tag} // '') &&
            lc($source->{channel} // '') eq lc($name);
        my $join_was_pending = delete $source->{join_pending};
        my $part_was_pending = delete $source->{part_pending};
        my $reconnect_after_part = delete $source->{reconnect_after_part};
        web_bridge_invalidate_search($source->{source_id}, 'stale',
            'source channel membership changed; run a fresh search before downloading');
        if (!$server->{connected}) {
            web_bridge_set_source_state($source, 'disconnected', 'IRC connection closed');
        } elsif ($part_was_pending && $reconnect_after_part) {
            $source->{desired_joined} = 1;
            web_bridge_schedule_source_join($source->{source_id}, $server);
        } elsif ($source->{desired_joined}) {
            $source->{desired_joined} = 0;
            web_bridge_set_source_state($source, 'failed',
                $join_was_pending
                    ? 'IRC did not confirm the requested channel join; connect to try again'
                    : 'configured channel membership ended; connect to rejoin');
        } else {
            web_bridge_set_source_state($source, 'configured');
        }
    }
}

# A source's login (web M3, Y2): a server password, a SASL PLAIN account, a
# NickServ password or (since 2026-10-27) a client certificate. It is held
# here only, apart from the source, so that no view of a source and no reply
# can carry it. Nothing writes a password anywhere; a certificate and its key
# have to be a file for Irssi to read (CONNECT -tls_cert), which is kept in the
# engine's own folder, readable by its user alone, and removed with the login.
# A login belongs to the server it was given for: pointing the source at
# another host, port or TLS setting drops it.
my %WEB_BRIDGE_LOGINS;
our $WEB_BRIDGE_CERTIFICATE_MAX_BYTES = 16384;

sub web_bridge_certificate_dir { return resolve_irssi_path('fserve-poc/certificates'); }

sub web_bridge_certificate_path {
    my ($source_id) = @_;
    return File::Spec->catfile(web_bridge_certificate_dir(),
        substr(sha256_hex($source_id // ''), 0, 24) . '.pem');
}

sub web_bridge_write_certificate {
    my ($path, $pem) = @_;
    my $dir = web_bridge_certificate_dir();
    for my $folder (resolve_irssi_path('fserve-poc'), $dir) {
        mkdir($folder, 0700) unless -e $folder;
    }
    return 0 if -l $dir || !-d $dir;
    chmod(0700, $dir) or return 0;
    my $temporary = "$path.new";
    unlink($temporary);
    sysopen(my $out, $temporary, O_WRONLY | O_CREAT | O_EXCL, 0600) or return 0;
    my $written = (print {$out} $pem) ? 1 : 0;
    $written = 0 unless close($out);
    return 1 if $written && rename($temporary, $path);
    unlink($temporary);
    return 0;
}

sub web_bridge_forget_login {
    my ($source_id) = @_;
    my $login = delete $WEB_BRIDGE_LOGINS{$source_id // ''};
    unlink($login->{certificate_file}) if $login && defined($login->{certificate_file});
}

# Logins live in memory, so a certificate file left by an earlier run of the
# engine belongs to no login.
sub web_bridge_clear_certificate_files {
    my $dir = web_bridge_certificate_dir();
    return if -l $dir || !-d $dir;
    opendir(my $handle, $dir) or return;
    unlink(map { File::Spec->catfile($dir, $_) }
        grep { /\A[0-9a-f]{24}\.pem(?:\.new)?\z/ } readdir($handle));
    closedir($handle);
}

sub web_bridge_login_endpoint {
    my ($source) = @_;
    return join("\x1f", lc($source->{host} // ''), $source->{port} || 0, $source->{tls} ? 1 : 0);
}

sub web_bridge_login_for {
    my ($source) = @_;
    return unless ref($source) eq 'HASH' && $source->{managed_endpoint};
    my $login = $WEB_BRIDGE_LOGINS{$source->{source_id} // ''} or return;
    return $login->{endpoint} eq web_bridge_login_endpoint($source) ? $login : undef;
}

sub web_bridge_login_view {
    my ($source) = @_;
    my $login = web_bridge_login_for($source) or return undef;
    return { kind => $login->{kind},
        (defined($login->{username}) ? (username => $login->{username}) : ()) };
}

# Irssi reads a quoted argument up to its closing quote, a backslash keeping
# the character after it as it is (commands.c, cmd_get_quoted_param).
sub irssi_quoted {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/([\\"])/\\$1/g;
    return '"' . $value . '"';
}

# A loopback or private-network address: a lab or test server. Only an
# address says so; a host name is a public server, whatever it resolves to,
# except "localhost". The same ranges as the web service's is_local_server:
# loopback, RFC 1918, link-local, and RFC 4193 for IPv6.
sub web_bridge_host_is_local {
    my ($host) = @_;
    return 0 unless defined($host) && length($host);
    return 1 if lc($host) eq 'localhost' || $host =~ /\.localhost\z/i;
    my @v4;
    if ($host =~ /\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/) {
        @v4 = ($1, $2, $3, $4);
        # As Python's ipaddress: no part above 255, no leading zero.
        return 0 if grep { $_ > 255 || /\A0\d/ } @v4;
    } elsif (index($host, ':') >= 0) {
        my $packed = eval { inet_pton(AF_INET6, $host) };
        return 0 unless defined($packed) && length($packed) == 16;
        my @bytes = unpack('C16', $packed);
        my $zeros = sub { !grep { $_ } @bytes[0 .. $_[0] - 1] };
        return 1 if $zeros->(15) && $bytes[15] == 1;                       # ::1
        return 1 if ($bytes[0] & 0xfe) == 0xfc;                            # fc00::/7
        return 1 if $bytes[0] == 0xfe && ($bytes[1] & 0xc0) == 0x80;       # fe80::/10
        return 0 unless $zeros->(10) && $bytes[10] == 0xff && $bytes[11] == 0xff;  # ::ffff:a.b.c.d
        @v4 = @bytes[12 .. 15];
    } else {
        return 0;
    }
    my ($first, $second) = @v4;
    return $first == 127 || $first == 10 || ($first == 172 && $second >= 16 && $second <= 31) ||
        ($first == 192 && $second == 168) || ($first == 169 && $second == 254) ? 1 : 0;
}

# A channel name as IRC compares it: case aside, [ ] \ ~ are the lower case
# of { } | ^.
sub web_bridge_channel_key {
    my ($channel) = @_;
    (my $key = lc($channel // '')) =~ tr/[]\\~/{}|^/;
    return $key;
}

sub web_bridge_set_login {
    my ($source, $args) = @_;
    my $source_id = $source->{source_id};
    return web_bridge_refusal('invalid_arguments', 'only a source with its own server connection can log in')
        unless $source->{managed_endpoint};
    my $kind = $args->{kind};
    return web_bridge_refusal('invalid_arguments',
        'kind must be none, server_password, sasl_plain, nickserv or certificate')
        unless defined($kind) && !ref($kind) &&
            $kind =~ /\A(?:none|server_password|sasl_plain|nickserv|certificate)\z/;
    return web_bridge_refusal('invalid_arguments', 'only a certificate login takes a certificate')
        if exists($args->{certificate}) && $kind ne 'certificate';
    if ($kind eq 'none') {
        return web_bridge_refusal('invalid_arguments', 'clearing a login takes no username or password')
            if exists($args->{username}) || exists($args->{password});
        web_bridge_forget_login($source_id);
        return { source_id => $source_id, login => undef };
    }
    if ($kind eq 'certificate') {
        return web_bridge_refusal('invalid_arguments',
            'a certificate login takes a certificate and no username or password')
            if exists($args->{username}) || exists($args->{password}) ||
                !exists($args->{certificate});
        # A certificate is only presented inside TLS, so a private network is
        # no exception here.
        return web_bridge_refusal('login_needs_tls',
            'a client certificate is only presented over TLS; turn TLS on for this source first')
            unless $source->{tls};
        my $pem = $args->{certificate};
        return web_bridge_refusal('invalid_arguments',
            'the certificate must be one PEM certificate followed by its unencrypted key')
            unless defined($pem) && !ref($pem) &&
                length($pem) <= $WEB_BRIDGE_CERTIFICATE_MAX_BYTES &&
                $pem =~ /\A-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+\/=\n]+-----END CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----\n[A-Za-z0-9+\/=\n]+-----END PRIVATE KEY-----\n\z/;
        web_bridge_forget_login($source_id);
        my $path = web_bridge_certificate_path($source_id);
        return web_bridge_refusal('certificate_not_kept',
            'the engine could not keep the certificate in its own folder')
            unless web_bridge_write_certificate($path, $pem);
        $WEB_BRIDGE_LOGINS{$source_id} = { kind => 'certificate', certificate_file => $path,
            endpoint => web_bridge_login_endpoint($source) };
        return { source_id => $source_id, login => web_bridge_login_view($source) };
    }
    # Over plain text the password would cross the network as it is typed;
    # a private-network server, such as a lab's, is the one exception. The
    # web service refuses this too; the engine does not rely on it.
    return web_bridge_refusal('login_needs_tls',
        'this source does not use TLS, so a password would cross the network in plain text')
        unless $source->{tls} || web_bridge_host_is_local($source->{host});
    my $password = $args->{password};
    return web_bridge_refusal('invalid_arguments',
        'the password must be 1 to 128 printable ASCII characters')
        unless defined($password) && !ref($password) && $password =~ /\A[\x20-\x7e]{1,128}\z/;
    my %login = (kind => $kind, password => $password,
        endpoint => web_bridge_login_endpoint($source));
    if ($kind eq 'server_password') {
        # Irssi sends it as "PASS <password>", unquoted (irc-servers.c,
        # server_init_2), so it has to be a single IRC parameter.
        return web_bridge_refusal('invalid_arguments',
            'a server password cannot contain a space or start with a colon')
            if $password =~ / / || $password =~ /\A:/;
        # CONNECT takes a password of "-" to mean none (chat-commands.c,
        # get_server_connect), so it would be dropped without a word.
        return web_bridge_refusal('invalid_arguments', 'a server password cannot be just "-"')
            if $password eq '-';
        return web_bridge_refusal('invalid_arguments', 'a server password takes no username')
            if exists $args->{username};
    } elsif ($kind eq 'nickserv' && !exists $args->{username}) {
        # NickServ reads "IDENTIFY [account] password" as words.
        return web_bridge_refusal('invalid_arguments', 'a NickServ password cannot contain a space')
            if $password =~ / /;
    } else {
        return web_bridge_refusal('invalid_arguments', 'a NickServ password cannot contain a space')
            if $kind eq 'nickserv' && $password =~ / /;
        my $username = $args->{username};
        return web_bridge_refusal('invalid_arguments',
            'the account name must be 1 to 64 printable ASCII characters without spaces')
            unless defined($username) && !ref($username) && $username =~ /\A[\x21-\x7e]{1,64}\z/;
        $login{username} = $username;
    }
    web_bridge_forget_login($source_id);
    $WEB_BRIDGE_LOGINS{$source_id} = \%login;
    return { source_id => $source_id, login => web_bridge_login_view($source) };
}

sub web_bridge_on_channel_joined {
    web_bridge_channel_joined(@_);
}

sub sig_server_disconnected {
    my ($server) = @_;
    return unless ref($server);
    my $identity = server_connection_identity($server);
    my $disconnected_epoch = defined($identity) ? ($SERVER_CONNECTION_EPOCH{$identity} || 0) : 0;
    for my $source (values %WEB_BRIDGE_SOURCES) {
        next unless web_bridge_source_matches_server($source, $server) ||
            (defined($source->{server_tag}) &&
                lc($source->{server_tag}) eq lc($server->{tag} // ''));
        web_bridge_schedule_reconnect_cancel($source);
        my $reconnect_after_disconnect = delete $source->{reconnect_after_disconnect};
        web_bridge_cancel_source_join_timer($source);
        Irssi::timeout_remove(delete $source->{disconnect_timer})
            if defined $source->{disconnect_timer};
        $source->{disconnect_generation} = ($source->{disconnect_generation} || 0) + 1;
        delete @{$source}{qw(join_pending part_pending reconnect_after_part connect_pending disconnect_inflight
            identify_until)};
        # Closed before the welcome: often a plain connection to a TLS port.
        # Irssi counts a connection as made before that (the join is
        # scheduled then), so the welcome itself is what tells.
        my $closed = $source->{desired_joined} && $source->{managed_endpoint} &&
            !delete($source->{welcomed})
            ? 'IRC connection closed before the server let this client in'
            : 'IRC connection closed';
        web_bridge_set_source_state($source, 'disconnected',
            web_bridge_closed_reason($source, $closed));
        if ($reconnect_after_disconnect && $source->{desired_joined}) {
            unless (web_bridge_start_managed_connection($source)) {
                web_bridge_set_source_state($source, 'failed',
                    delete($source->{start_failure}) //
                    'Irssi could not restart the managed connection after disconnect');
            }
        }
    }
    my $recovery = $JOBS{pre_dispatch_recovery};
    if ($recovery && ($recovery->{connection_identity} // '') eq ($identity // '') &&
            ($recovery->{connection_epoch} || 0) == $disconnected_epoch) {
        my $session_active = $S{active} &&
            ($S{pre_dispatch_recovery_id} || 0) == $recovery->{id};
        finish_pre_dispatch_recovery(
            'captured IRC connection disconnected during recovery',
            needs_attention => $session_active ? 0 : 1,
            release_lease => $session_active ? 0 : 1,
            outcome => 'pre_dispatch_recovery_disconnected');
    }
    cancel_outbound_for_connection($identity, $disconnected_epoch,
        'captured IRC connection disconnected') if defined $identity;
    $SERVER_CONNECTION_EPOCH{$identity} = ++$CONNECTION_EPOCH_SEQUENCE
        if defined $identity;
    if (defined($identity) && defined($disconnected_epoch)) {
        delete $JOBS{live_servers}{$identity}{$disconnected_epoch};
        delete $JOBS{live_servers}{$identity}
            unless keys %{$JOBS{live_servers}{$identity} || {}};
    }

    # Stop only transfers bound to the exact disconnected native connection
    # incarnation. Keep each binding and its stop disposition until native
    # closure is confirmed, so a delayed callback cannot report success.
    my @owned_transfers = grep {
        defined($identity) &&
        ($_->{server_identity} // '') eq $identity &&
        ($_->{connection_epoch} || 0) == $disconnected_epoch
    } values %TRANSFERS;
    for my $transfer (@owned_transfers) {
        next unless $transfer->{dcc};
        request_transfer_stop($transfer, {
            job_state => 'interrupted',
            job_outcome => 'disconnected',
            request_state => 'disconnected',
            reason => 'originating IRC connection disconnected',
        });
    }
    my $archive_transfer_stopped = scalar grep {
        ($_->{kind} // '') eq 'searchbot' &&
            ($_->{collection_id} // '') eq ($SEARCHBOT{collection_id} // '')
    } @owned_transfers;

    if (defined($identity) && $identity eq ($SEARCHBOT{server_identity} // '') &&
            ($SEARCHBOT{connection_epoch} || 0) == $disconnected_epoch) {
        retire_searchbot_direct('disconnected', 'originating IRC connection disconnected')
            if searchbot_direct_active();
        if (defined($SEARCHBOT{phase6_job_id}) && jobs_ready()) {
            my $job = $JOBS{coordinator}->job($SEARCHBOT{phase6_job_id});
        if ($job && $job->{state} !~ /\A(?:interrupted|finalizing|complete|failed|cancelled|expired|stale|needs_attention)\z/ &&
            !transfer_stop_pending($job->{id})) {
                retire_job($SEARCHBOT{phase6_job_id}, 'disconnected',
                    'originating IRC connection disconnected before archive resolution');
            }
        }
        abort_searchbot_collection(1, 'needs_attention',
            'originating IRC connection disconnected while SearchBot archive work was active',
            $archive_transfer_stopped);
        $SEARCHBOT{active} = 0;
        $SEARCHBOT{results} = [];
        $SEARCHBOT{state} = 'disconnected';
        clear_searchbot_timer();
        log_to_path($SEARCHBOT_DIRECT{log_path}, 'CONNECTION_INVALIDATED',
            'server=' . safe_field($server->{tag} // ''))
            if defined $SEARCHBOT_DIRECT{request_id};
    }
    # The search of this connection, the current one or one set aside.
    my $end_find = sub {
    if ($FIND{active} && defined($identity) &&
            ($FIND{server_identity} // '') eq $identity &&
            ($FIND{connection_epoch} || 0) == $disconnected_epoch) {
        my $query_id = $FIND{query_id} || 0;
        $FIND{active} = 0;
        $FIND{state} = 'disconnected';
        $FIND{results} = [];
        $FIND{quiet_token} = ($FIND{quiet_token} || 0) + 1;
        Irssi::timeout_remove($FIND{deadline_timer})
            if defined $FIND{deadline_timer};
        Irssi::timeout_remove($FIND{quiet_timer})
            if defined $FIND{quiet_timer};
        delete @FIND{qw(deadline_timer quiet_timer)};
        if ($WEB_BRIDGE && $WEB_BRIDGE{search} &&
                ($WEB_BRIDGE{search}{query_id} || 0) == $query_id) {
            web_bridge_invalidate_search($WEB_BRIDGE{search}{source_id},
                'disconnected',
                'The IRC connection ended before collection completed; partial results were discarded.',
                1);
        }
        $FIND{query_id} = $query_id + 1;
    } elsif (!$FIND{active} && defined($identity) &&
            ($FIND{server_identity} // '') eq $identity &&
            ($FIND{connection_epoch} || 0) == $disconnected_epoch &&
            $WEB_BRIDGE && $WEB_BRIDGE{search} &&
            ($WEB_BRIDGE{search}{query_id} || 0) == ($FIND{query_id} || 0) &&
            ($FIND{state} // '') eq 'complete') {
        web_bridge_invalidate_search($WEB_BRIDGE{search}{source_id}, 'stale',
            'IRC connection changed; run a fresh search before downloading');
    }
    };
    $end_find->();
    for my $aside (values %{$WEB_BRIDGE{aside} || {}}) {
        find_with($aside->{find}, $aside->{search}, $end_find);
    }
    if ($WEB_BRIDGE && defined($identity)) {
        for my $parked_source (keys %{$WEB_BRIDGE{parked} || {}}) {
            my $find = $WEB_BRIDGE{parked}{$parked_source}{find} || {};
            web_bridge_invalidate_search($parked_source, 'stale',
                'IRC connection changed; run a fresh search before downloading')
                if ($find->{server_identity} // '') eq $identity &&
                    ($find->{connection_epoch} || 0) == $disconnected_epoch;
        }
        for my $parked_source (keys %{$WEB_BRIDGE{sb_parked} || {}}) {
            my $parked = $WEB_BRIDGE{sb_parked}{$parked_source}{searchbot} || {};
            web_bridge_invalidate_searchbot($parked_source, 'stale',
                'IRC connection changed; run a fresh search before downloading')
                if ($parked->{server_identity} // '') eq $identity &&
                    ($parked->{connection_epoch} || 0) == $disconnected_epoch;
        }
        my $holds = $WEB_BRIDGE{sb_holds} || {};
        delete @$holds{grep {
            ($holds->{$_}{server_identity} // '') eq $identity &&
                ($holds->{$_}{connection_epoch} || 0) == $disconnected_epoch } keys %$holds};
    }

    if (defined($identity) && ($S{server_identity} // '') eq $identity &&
            ($S{connection_epoch} || 0) == $disconnected_epoch) {
        my $pending = $S{pending_download};
        if ($pending && defined($pending->{phase6_job_id})) {
            my $job = jobs_ready() ? $JOBS{coordinator}->job($pending->{phase6_job_id}) : undef;
            if ($job && $job->{state} !~ /\A(?:interrupted|finalizing|complete|failed|cancelled|expired|stale)\z/ &&
                !transfer_stop_pending($pending->{phase6_job_id})) {
                retire_job($pending->{phase6_job_id}, 'disconnected',
                    'originating IRC connection disconnected before request resolution');
            }
        }
        my $chat_dcc = $S{chat_dcc};
        $S{active} = 0;
        $S{chat_connected} = 0;
        $S{chat_id} = undef;
        $S{chat_dcc} = undef;
        eval { $chat_dcc->destroy() } if $chat_dcc;
        stop_session(1);
    }

    if (defined($identity) && jobs_ready()) {
        for my $job (values %{$JOBS{coordinator}->jobs}) {
            next unless ($job->{context}{connection_identity} // '') eq $identity &&
                ($job->{context}{connection_epoch} || 0) == $disconnected_epoch;
            next unless $job->{state} eq 'held';
            job_transition($job->{id}, 'stale', outcome => 'connection_epoch_ended',
                reason => 'saved selection cannot be rebound after IRC disconnect');
        }
    }
}

1;
