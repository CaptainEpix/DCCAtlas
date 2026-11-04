# @find: a search of the file servers in a channel, and its answers.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;

our (%FIND, %WEB_BRIDGE);

# Searches on several sources at once (2026-10-27). A search still running
# when another source's search starts is set aside whole, by reference, in
# $WEB_BRIDGE{aside}{source_id} = { find => \%its_find, search => ... }, and
# the new one gets a record of its own. Whatever acts on one set aside (a
# reply from its connection, one of its timers or scheduled sends, a status
# or a cancel) runs with %FIND made to be it, so the Find code below reads
# and writes the search it belongs to, as it did when there was only one.
sub any_find_active {
    return 1 if $FIND{active};
    return (grep { $_->{find}{active} } values %{$WEB_BRIDGE{aside} || {}}) ? 1 : 0;
}

sub find_with {
    my ($find, $search, $code) = @_;
    my @result;
    {
        local *FIND = $find;
        local $WEB_BRIDGE{search} = $search;
        @result = $code->();
    }
    web_bridge_settle_aside();
    return wantarray ? @result : $result[0];
}

# A timer or scheduled send made for the search in %FIND acts on that search
# when it fires, wherever it has been set aside since.
sub find_bound {
    my ($code) = @_;
    my $find = \%FIND;
    return sub {
        my @args = @_;
        return $code->(@args) if \%FIND == $find;
        my ($entry) = grep { $_->{find} == $find } values %{$WEB_BRIDGE{aside} || {}};
        return find_with($find, $entry ? $entry->{search} : undef, sub { $code->(@args) });
    };
}

sub finish_find {
    my ($reason, $query_id) = @_;
    return unless $FIND{active};
    return if defined($query_id) && ($FIND{query_id} || 0) != $query_id;

    $FIND{active} = 0;
    $FIND{state} = 'complete';
    $FIND{quiet_token} = ($FIND{quiet_token} || 0) + 1;
    Irssi::timeout_remove($FIND{deadline_timer}) if defined $FIND{deadline_timer};
    Irssi::timeout_remove($FIND{quiet_timer}) if defined $FIND{quiet_timer};
    delete @FIND{qw(deadline_timer quiet_timer)};
    my $seconds = int(($FIND{first_reply_ms} || 0) / 1000);
    $FIND{note} = "Nothing answered within $seconds seconds." if $reason eq 'silent';
    web_bridge_find_direct_list();
    web_bridge_publish_search_state($query_id);
    my $parser = $FIND{parser};
    my $incomplete = 0;
    if ($parser) {
        for my $sender (@{$parser->active_senders}) {
            my $events = $parser->timeout($sender);
            $incomplete++ if grep { $_->{type} eq 'timeout' && $_->{had_block} } @$events;
        }
    }

    my $count = scalar @{$FIND{results} || []};
    if ($reason eq 'silent') {
        p("\@Find collection closed: nothing answered within $seconds seconds.");
    } elsif ($reason eq 'quiet') {
        p("\@Find collection closed after the quiet window ($count results).");
    } else {
        p("\@Find collection reached its time limit ($count results).");
    }
    p("$incomplete sender block(s) ended without an explicit End of \@Find marker.")
        if $incomplete;

    if ($count) {
        show_find_results('');
    } elsif ($FIND{saw_status}) {
        p('No file results were parsed; the server reported a status response above.');
    } else {
        p('No file results were observed. Silence can mean no matches or a silent/disabled @Find response.');
    }
    p('Use /fscrawl findlist [text] to review indexed results.') if $count;
}

# The quiet window restarts at each reply. Before the first, it is the longer
# first-reply window, and a search it closes is one nothing answered.
sub schedule_find_quiet_timer {
    my ($first) = @_;
    return unless $FIND{active};
    my $quiet_ms = Irssi::settings_get_int('fscrawl_find_quiet_ms') || 30000;
    my $absolute_ms = Irssi::settings_get_int('fscrawl_find_timeout_ms') || 150000;
    $quiet_ms = 250 if $quiet_ms < 250;
    if ($first) {
        my $first_ms = Irssi::settings_get_int('fscrawl_find_first_reply_ms') || 60000;
        $quiet_ms = $first_ms if $first_ms > $quiet_ms;
        $FIND{first_reply_ms} = $quiet_ms;
    }
    $FIND{replied} = 1 unless $first;
    $quiet_ms = $absolute_ms if $quiet_ms > $absolute_ms;
    my $reason = $first ? 'silent' : 'quiet';

    my $query_id = $FIND{query_id};
    my $token = ++$FIND{quiet_token};
    Irssi::timeout_remove($FIND{quiet_timer}) if defined $FIND{quiet_timer};
    $FIND{quiet_timer} = Irssi::timeout_add_once($quiet_ms, find_bound(sub {
        $FIND{quiet_timer} = undef
            if ($FIND{query_id} || 0) == $query_id && ($FIND{quiet_token} || 0) == $token;
        return unless $FIND{active};
        return unless ($FIND{query_id} || 0) == $query_id;
        return unless ($FIND{quiet_token} || 0) == $token;
        finish_find($reason, $query_id);
    }), undef);
}

sub cmd_find {
    my ($args, $server) = @_;
    unless ($server && $server->{connected}) {
        p('Run /fscrawl find from a window on an already-connected IRC network.');
        return;
    }
    if ($FIND{active} || (any_find_active() && !$WEB_BRIDGE{find_alongside})) {
        p('An @Find collection is already active. Wait for it to finish before starting another.');
        return;
    }
    if (searchbot_direct_active()) {
        p('A direct SearchBot request owns the network/DCC slot; wait or cancel it before starting @Find.');
        return;
    }

    my ($channel, $terms) = $args =~ /^\s*(\S+)\s+(.+?)\s*$/s;
    unless (defined($channel) && defined($terms) && length($terms)) {
        p('Usage: /fscrawl find <channel> <search terms>');
        return;
    }
    unless ($channel =~ /^[#&+!][^\s,\x00-\x1f\x7f]{0,199}$/) {
        p('Use one IRC channel name, such as #files.');
        return;
    }
    if ($terms =~ /[\x00-\x1f\x7f]/ || length($terms) > 350) {
        p('Search terms contain control characters or exceed 350 characters.');
        return;
    }
    return unless load_find_parser() && load_catalog_module();

    my $server_tag = $server->{tag} // '';
    my $network_id = $server->{chatnet} // $server_tag;
    my $query_id = ($FIND{query_id} || 0) + 1;
    %FIND = (
        query_id      => $query_id,
        active        => 1,
        server_tag    => $server_tag,
        network_id    => $network_id,
        server_identity => server_connection_identity($server),
        connection_epoch => server_connection_epoch($server),
        channel       => $channel,
        terms         => $terms,
        results       => [],
        state         => 'dispatch_pending',
        saw_status    => 0,
        quiet_token   => 0,
        parser_loaded => 1,
        parser        => FServe::Discovery::SysResetFind->new(
            network_id       => $network_id,
            server_tag       => $server_tag,
            discovery_channel => $channel,
            trigger_mode     => 'channel_text',
            source_timestamp => now_iso(),
        ),
    );

    my $timeout_ms = Irssi::settings_get_int('fscrawl_find_timeout_ms') || 150000;
    $timeout_ms = 1000 if $timeout_ms < 1000;

    my $message = '@find ' . $terms;
    # Irssi::Server::command preserves quotes in the outgoing message body.
    # MSG already treats the remainder of the command as one trailing payload,
    # so do not quote it or servers expecting @find receive literal quotes.
    my $command = 'MSG ' . $channel . ' ' . $message;
    my $server_identity = $FIND{server_identity};
    my $connection_epoch = $FIND{connection_epoch};
    my $route = outbound_route_key($server, $channel, '@find', 'find');
    my $scheduled = schedule_irc_message(
        server => $server, kind => 'query', route => $route,
        owner_kind => 'find', owner_id => "$query_id",
        guard => find_bound(sub {
            $FIND{active} && ($FIND{query_id} || 0) == $query_id &&
                ($FIND{server_identity} // '') eq ($server_identity // '') &&
                ($FIND{connection_epoch} || 0) == ($connection_epoch || 0) &&
                ($FIND{state} // '') eq 'dispatch_pending'
        }),
        before_send => find_bound(sub {
            return 0 unless $FIND{active} && ($FIND{query_id} || 0) == $query_id;
            $FIND{state} = 'dispatching';
            return 1;
        }),
        send => sub { $server->command($command) },
        on_done => find_bound(sub {
            my ($status, $reason) = @_;
            return unless ($FIND{query_id} || 0) == $query_id;
            if ($status eq 'sent') {
                return unless $FIND{active};
                $FIND{state} = 'collecting';
                my $timer = eval {
                    Irssi::timeout_add_once($timeout_ms, find_bound(sub {
                        $FIND{deadline_timer} = undef
                            if ($FIND{query_id} || 0) == $query_id;
                        finish_find('deadline', $query_id);
                    }), undef);
                };
                if (defined $timer) {
                    $FIND{deadline_timer} = $timer;
                    schedule_find_quiet_timer(1) unless $FIND{replied};
                    p("Searching $channel for [$terms]; collection limit ${timeout_ms}ms.");
                    web_bridge_publish_search_state($query_id);
                } else {
                    $FIND{active} = 0;
                    $FIND{state} = 'timeout_unavailable';
                    p('The @Find query was sent, but its bounded collection timer could not be armed; results were discarded.');
                    web_bridge_publish_search_state($query_id, 'collection timer unavailable; results discarded');
                }
            } else {
                $FIND{active} = 0;
                $FIND{state} = $status;
                $FIND{results} = [];
                p("Could not send or safely schedule \@Find query: " . safe_field($reason // $status));
                web_bridge_publish_search_state($query_id, 'search was not dispatched');
            }
        }),
    );
    unless ($scheduled) {
        $FIND{active} = 0;
        $FIND{state} = 'schedule_failed';
        p('Could not reserve the @Find query in the outbound scheduler; no query was sent.');
        web_bridge_publish_search_state($query_id, 'search was not scheduled');
    }
}

sub find_server_matches {
    my ($server) = @_;
    return 0 unless $FIND{active} &&
        ($FIND{state} // '') =~ /\A(?:dispatching|collecting)\z/ && $server;
    my $tag = $server->{tag} // '';
    return 0 unless length $tag && length($FIND{server_tag} // '');
    return lc($tag) eq lc($FIND{server_tag} // '');
}

sub find_target_matches {
    my ($kind, $server, $target) = @_;
    my $target_key = lc($target // '');
    my $channel_key = lc($FIND{channel} // '');
    return 0 unless length $target_key;

    return $target_key eq $channel_key if $kind eq 'public';
    return $target_key eq $channel_key ||
        $target_key eq lc($server->{nick} // '') if $kind eq 'notice';
    return $target_key eq lc($server->{nick} // '') if $kind eq 'private';
    return 0;
}

# Other file-server scripts answer @find with rows to post back to the
# channel, "!Nick file ::INFO:: size", sent to this client by Nick itself
# (seen on 2026-10-20). Such a row is kept as it came and, when the search
# ends, read with the SearchBot list reader, so that it is fetched exactly as
# a search bot's row is: posted once, and only that file taken from Nick.
our $FIND_DIRECT_ROW_LIMIT = 1000;

sub find_direct_row_text {
    my ($server, $nick, $message) = @_;
    my $line = $message // '';
    $line =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $line =~ s/[\x02\x0F\x11\x16\x1D\x1E\x1F]//g;
    $line =~ s/\A\s+|\s+\z//g;
    return unless $line =~ /\A!([^\s\x00-\x1f\x7f]{1,127})[\t ]+\S.*?[\t ]::INFO::[\t ]*\S/;
    my $named = $1;
    return unless eval { require FServe::ConnectionIdentity; 1 };
    my $mapping = server_casemapping($server);
    return unless FServe::ConnectionIdentity::irc_casefold($named, $mapping) eq
        FServe::ConnectionIdentity::irc_casefold($nick, $mapping);
    return $line;
}

sub handle_find_message {
    my ($kind, $server, $message, $nick, $address, $target) = @_;
    unless (find_server_matches($server)) {
        my $entry = web_bridge_aside_for_server($server) or return;
        return find_with($entry->{find}, $entry->{search}, sub {
            handle_find_message($kind, $server, $message, $nick, $address, $target) });
    }
    return unless find_target_matches($kind, $server, $target);
    return unless defined($nick) && length($nick);

    my $direct = $kind eq 'public' ? undef : find_direct_row_text($server, $nick, $message);
    if (defined $direct) {
        my $rows = $FIND{direct_rows} ||= [];
        push @$rows, $direct if @$rows < $FIND_DIRECT_ROW_LIMIT;
        schedule_find_quiet_timer();
        return;
    }

    my $events = $FIND{parser}->feed_line($nick, $message);
    return unless @$events;
    my $relevant = 0;
    my @catalog_observations;
    for my $event (@$events) {
        if ($event->{type} eq 'result') {
            push @{$FIND{results}}, { %{$event->{result}} };
            push @catalog_observations, { %{$event->{result}} };
            $relevant = 1;
            my $ordinal = scalar @{$FIND{results}};
            if ($WEB_BRIDGE{search} &&
                    ($WEB_BRIDGE{search}{query_id} || 0) == ($FIND{query_id} || 0)) {
                my $result = web_bridge_selection_view($ordinal);
                web_bridge_publish('search.result', {
                    search_id => web_bridge_search_id($FIND{query_id}),
                    result => $result,
                }) if $result;
            }
        } elsif ($event->{type} eq 'status') {
            $FIND{saw_status} = 1;
            p("\@Find status from $nick: " . safe_field($event->{text}));
            $relevant = 1;
        } elsif ($event->{type} eq 'parse_error') {
            p("Malformed \@Find response from $nick: " . safe_field($event->{reason}));
            $relevant = 1;
        } elsif ($event->{type} eq 'header' || $event->{type} eq 'section' || $event->{type} eq 'end') {
            $relevant = 1;
        }
    }
    record_catalog_observations(\@catalog_observations);
    schedule_find_quiet_timer() if $relevant;
    web_bridge_publish_search_state($FIND{query_id}) if $relevant;
}

sub sig_find_public {
    handle_find_message('public', @_);
}

sub sig_find_private {
    my ($server, $message, $nick, $address, $target) = @_;
    # Irssi's private-message signal may omit a target argument: a private
    # message is, by definition, addressed to our current nick.
    $target = $server->{nick}
        unless defined($target) && length($target);
    handle_find_message('private', $server, $message, $nick, $address, $target);
}

sub sig_find_notice {
    handle_find_message('notice', @_);
}

1;
