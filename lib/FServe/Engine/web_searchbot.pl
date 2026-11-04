# The web bridge's search-bot searches, and rows held for the queue.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode);

our (%JOBS, %S, %SEARCHBOT, %SEARCHBOT_CONTENT_TOMBSTONES, %SEARCHBOT_USED_OFFERS,
     %WEB_BRIDGE, %WEB_BRIDGE_SELECTIONS, %WEB_BRIDGE_SOURCES, $DOWNLOAD_PATH_OWNER,
     $SEARCHBOT_SEQUENCE, $WEB_BRIDGE, $WEB_BRIDGE_SAID);

# Search-bot rows the web download queue holds: twice what it may queue.
my $WEB_BRIDGE_HOLD_LIMIT = 50;
my $WEB_BRIDGE_HOLD_SEQUENCE = 0;

# -- SearchBot sources ----------------------------------------------------
#
# A source whose provider is "searchbot" is searched with "@search": the
# channel's search bot replies with a ZIP holding a text list, and a row of
# that list is fetched by posting the row back to the channel. The engine's
# SearchBot code does all of that and holds exactly one result list, in
# %SEARCHBOT. As with Find, each source keeps its own finished list: one that
# is not current is parked whole and put back before a row is fetched.
#
# $WEB_BRIDGE{sb} describes the list in %SEARCHBOT; $WEB_BRIDGE{sb_parked}
# holds the others by source ID.

sub web_bridge_source_is_searchbot {
    my ($source_id) = @_;
    my $source = defined($source_id) ? $WEB_BRIDGE_SOURCES{$source_id} : undef;
    return $source && ($source->{provider} // '') eq 'searchbot' ? 1 : 0;
}

sub web_bridge_searchbot_id {
    my ($query_id) = @_;
    return unless $WEB_BRIDGE && defined $query_id;
    return 'sbot-' . $WEB_BRIDGE->instance_id() . '-' . $query_id;
}

# The SearchBot search a source has: its engine state and its web record.
sub web_bridge_searchbot_of {
    my ($source_id) = @_;
    return unless defined $source_id;
    my $current = $WEB_BRIDGE{sb};
    return (\%SEARCHBOT, $current)
        if $current && ($current->{source_id} // '') eq $source_id;
    my $parked = $WEB_BRIDGE{sb_parked}{$source_id} or return;
    return ($parked->{searchbot}, $parked->{search});
}

sub web_bridge_searchbot_is_live {
    my $search = $WEB_BRIDGE{sb};
    return $search && ($search->{collection_id} // '') eq ($SEARCHBOT{collection_id} // '')
        ? 1 : 0;
}

# Only a complete, valid list is parked; a running search never is.
sub web_bridge_park_searchbot {
    my $search = $WEB_BRIDGE{sb} or return;
    return unless web_bridge_searchbot_is_live() && !$search->{invalidated} &&
        !$SEARCHBOT{active} && ($SEARCHBOT{state} // '') eq 'complete';
    $WEB_BRIDGE{sb_parked}{$search->{source_id}} =
        { searchbot => { %SEARCHBOT }, search => $search };
}

# Make a source's list the current one. False when it has none, or when a
# running search or transfer must not be disturbed.
sub web_bridge_activate_searchbot {
    my ($source_id) = @_;
    my $current = $WEB_BRIDGE{sb};
    return 1 if $current && ($current->{source_id} // '') eq $source_id &&
        web_bridge_searchbot_is_live();
    my $parked = $WEB_BRIDGE{sb_parked}{$source_id} or return 0;
    return 0 if $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving' ||
        searchbot_direct_active();
    web_bridge_park_searchbot();
    delete $WEB_BRIDGE{sb_parked}{$source_id};
    %SEARCHBOT = %{$parked->{searchbot}};
    $WEB_BRIDGE{sb} = $parked->{search};
    return 1;
}

sub web_bridge_invalidate_searchbot {
    my ($source_id, $state, $note) = @_;
    my ($sb, $search) = web_bridge_searchbot_of($source_id);
    return unless $search && !$search->{invalidated};
    $search->{invalidated} = 1;
    $search->{terminal_state} = $state;
    $search->{terminal_note} = $note if defined $note;
    web_bridge_forget_selections($source_id);
    my $snapshot = web_bridge_searchbot_snapshot($source_id, 0, 0);
    delete $WEB_BRIDGE{sb_parked}{$source_id};
    web_bridge_publish('search.state', $snapshot) if $snapshot;
}

# Why a search that did not complete ended, in plain words.
sub web_bridge_searchbot_note {
    my ($sb, $raw) = @_;
    my $job = defined($sb->{phase6_job_id}) && jobs_ready()
        ? $JOBS{coordinator}->job($sb->{phase6_job_id}) : undef;
    my $detail = $job ? safe_field($job->{reason}) : '';
    return 'The search bot sent no result list in time. ' .
        (length($sb->{bot_said} // '')
            ? 'It said: ' . safe_field($sb->{bot_said})
            : 'It may have found nothing, or it may be busy.')
        if $raw eq 'expired';
    return 'The result list did not arrive completely.'
        if $raw eq 'incomplete' || $raw eq 'transfer_expired';
    return 'The result list could not be read' . (length($detail) ? ": $detail" : '.')
        if $raw eq 'refused' || $raw eq 'parse_expired';
    return 'The search could not be sent; it was not retried.'
        if $raw =~ /\A(?:send_failed|scheduler_failed|dispatch_timer_unavailable)\z/;
    return 'The search may already have been sent; cancelling only stops waiting for the reply.'
        if $raw eq 'cancelled';
    return;
}

sub web_bridge_searchbot_row {
    my ($sb, $search, $ordinal, $selectable) = @_;
    my $candidate = ref($sb->{results}) eq 'ARRAY' ? $sb->{results}[$ordinal - 1] : undef;
    return unless ref($candidate) eq 'HASH' && $ordinal <= 5000;
    my ($name, $name_error) = web_bridge_string($candidate->{filename}, 4096, 'result file');
    my ($trigger, $trigger_error) =
        web_bridge_string($candidate->{route_trigger}, 128, 'result trigger');
    return if $name_error || $trigger_error;
    # The file is expected from the nick the row's command names: "!Nick".
    (my $sender = $trigger) =~ s/\A!//;
    return unless length($sender) && length($sender) <= 64;
    # A name too long to request is shown shortened; it has no selection.
    $name = substr($name, 0, 512);
    # The list is bytes. Show UTF-8 names as text; anything else as it came.
    my $shown = eval { decode('UTF-8', my $copy = $name, Encode::FB_CROAK) };
    $shown = $name unless defined($shown) && length($shown);
    my $search_id = web_bridge_searchbot_id($search->{query_id});
    my $selection_id;
    if ($selectable && $candidate->{direct_requestable} && searchbot_nick_is_safe($sender)) {
        $selection_id = 'sel-' . substr(sha256_hex(join("\0",
            $WEB_BRIDGE->instance_id(), $search_id, $ordinal,
            $sb->{server_identity} // '', $sb->{connection_epoch} // 0,
            $candidate->{candidate_id} // '')), 0, 40);
        $WEB_BRIDGE_SELECTIONS{$selection_id} ||= {
            searchbot => 1, collection_id => $sb->{collection_id},
            ordinal => $ordinal, candidate_id => $candidate->{candidate_id},
            sender => $sender,
            server_identity => $sb->{server_identity},
            connection_epoch => $sb->{connection_epoch},
            source_id => $search->{source_id},
            source_revision => $search->{source_revision},
        };
    }
    my $size_bytes = defined($candidate->{size_bytes}) && !ref($candidate->{size_bytes}) &&
        $candidate->{size_bytes} =~ /\A\d{1,18}\z/ ? 0 + $candidate->{size_bytes} : undef;
    return {
        (defined($selection_id) ? (selection_id => $selection_id) : ()),
        ordinal => $ordinal,
        source_id => $search->{source_id},
        source_revision => $search->{source_revision},
        sender => $sender,
        trigger => $trigger,
        trigger_mode => 'searchbot',
        path => $shown,
        size_text => safe_field($candidate->{info_raw}),
        size_bytes => $size_bytes,
        size_precision => defined($size_bytes) ? 'estimated' : 'unknown',
    };
}

sub web_bridge_searchbot_snapshot {
    my ($source_id, $offset, $limit) = @_;
    my ($sb, $search) = web_bridge_searchbot_of($source_id);
    return unless $search;
    my $bound = ($search->{collection_id} // '') eq ($sb->{collection_id} // '');
    my $raw = $bound ? ($sb->{state} // 'unknown') : 'stale';
    my %shown_as = (
        dispatch_pending => 'dispatch_pending', awaiting_result => 'collecting',
        receiving => 'collecting', parsing => 'collecting', complete => 'complete',
        cancelled => 'cancelled', disconnected => 'disconnected', stale => 'stale',
    );
    my $state = $search->{invalidated} ? ($search->{terminal_state} // 'stale')
        : ($shown_as{$raw} // 'failed');
    my $note = $search->{terminal_note};
    $note = web_bridge_searchbot_note($sb, $raw)
        if !defined($note) && $state =~ /\A(?:failed|cancelled)\z/;
    $note = 'The search bot said: ' . safe_field($sb->{bot_said})
        if !defined($note) && $state eq 'collecting' && length($sb->{bot_said} // '');
    my $listed = $bound && $raw eq 'complete' && ref($sb->{results}) eq 'ARRAY';
    my $total = $listed ? scalar @{$sb->{results}} : 0;
    my $end = $offset + $limit;
    $end = $total if $end > $total;
    my @results;
    for my $ordinal ($offset + 1 .. $end) {
        my $record = web_bridge_searchbot_row($sb, $search, $ordinal,
            $state eq 'complete' ? 1 : 0);
        push @results, $record if $record;
    }
    return {
        search_id => web_bridge_searchbot_id($search->{query_id}),
        source_id => $source_id,
        provider => 'searchbot',
        state => $state,
        phase => $raw,
        (defined($note) ? (note => $note) : ()),
        terms => $search->{terms},
        channel => $search->{channel},
        started_at => $search->{started_at},
        result_count => $total,
        selectable_result_limit => 5000,
        offset => $offset,
        results => \@results,
    };
}

# Send one "@search" for a SearchBot source. Everything that guards the query
# is the engine's own: one search at a time, the 30-second spacing, and no
# repeat of a search whose late reply could be mistaken for a new one.
sub web_bridge_searchbot_start {
    my ($source, $source_id, $terms, $server) = @_;
    return web_bridge_refusal('search_active', 'wait for or cancel the current search')
        if any_find_active() || $S{active} || $SEARCHBOT{active} ||
            ($SEARCHBOT{state} // '') eq 'receiving';
    return web_bridge_refusal('transfer_busy', 'finish or cancel the current transfer first')
        if searchbot_direct_active() || $DOWNLOAD_PATH_OWNER || has_active_download_transfer();
    return web_bridge_refusal('search_not_started', 'the SearchBot modules could not be loaded')
        unless load_searchbot_provider() && load_dcc_policy();
    my $bot = $source->{search_bot};
    return web_bridge_refusal('source_not_ready', 'this source has no search bot nickname')
        unless searchbot_nick_is_safe($bot);
    my $expected = FServe::Discovery::SearchBotOffer::expected_archive_filename($terms);
    return web_bridge_refusal('invalid_query',
        'a search-bot search may contain only letters, digits and spaces')
        unless defined $expected;
    my $tag = $server->{tag} // '';
    return web_bridge_refusal('repeat_refused',
        'this exact search was already sent to this search bot on this connection; ' .
        'a repeat is refused because a late reply to the first could not be told from a reply to the second')
        if searchbot_tombstone_used(\%SEARCHBOT_USED_OFFERS, $server, $tag, $bot, $expected) ||
            searchbot_tombstone_used(\%SEARCHBOT_CONTENT_TOMBSTONES, $server, $tag, $bot, $expected);
    # This source's earlier list is replaced; another source's finished
    # list is set aside and stays downloadable.
    web_bridge_park_searchbot();
    delete $WEB_BRIDGE{sb_parked}{$source_id};
    web_bridge_forget_selections($source_id);
    my $before = $SEARCHBOT_SEQUENCE;
    local $WEB_BRIDGE_SAID = [];
    cmd_searchbot(join(' ', $source->{channel}, $bot, $terms), $server);
    my $started = $SEARCHBOT_SEQUENCE == $before + 1 && $SEARCHBOT{active} &&
        ($SEARCHBOT{query_id} || 0) == $SEARCHBOT_SEQUENCE;
    unless ($started) {
        # Whatever %SEARCHBOT holds now, it is not a search this source owns.
        if (web_bridge_searchbot_is_live()) {
            delete $WEB_BRIDGE{sb_parked}{$WEB_BRIDGE{sb}{source_id}};
            delete $WEB_BRIDGE{sb} if ($WEB_BRIDGE{sb}{source_id} // '') eq $source_id;
        } else {
            delete $WEB_BRIDGE{sb};
        }
        my $why = @$WEB_BRIDGE_SAID ? safe_field($WEB_BRIDGE_SAID->[-1])
            : 'the SearchBot engine did not accept this search';
        return web_bridge_refusal('search_not_started', substr($why, 0, 400));
    }
    $SEARCHBOT{web_destination_network} = $source->{host} if $source->{managed_endpoint};
    $WEB_BRIDGE{sb} = {
        query_id => $SEARCHBOT{query_id}, collection_id => $SEARCHBOT{collection_id},
        source_id => $source_id, source_revision => $source->{revision},
        terms => $terms, channel => $source->{channel}, started_at => time(),
    };
    my $snapshot = web_bridge_searchbot_snapshot($source_id, 0, 0);
    web_bridge_publish('search.state', $snapshot);
    return $snapshot;
}

# Fetch one row of a SearchBot source's finished list. The row is posted to
# the channel exactly as the list gave it, once, and only a file with the
# row's name from the nick the row names is taken.
sub web_bridge_searchbot_download {
    my ($source, $source_id, $search_id, $selection_id, $operation_id) = @_;
    return web_bridge_refusal('search_active', 'wait for the running search to finish first')
        if any_find_active() || $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
    return web_bridge_refusal('transfer_busy', 'finish or cancel the current transfer first')
        if $S{active} || searchbot_direct_active() || $DOWNLOAD_PATH_OWNER ||
            has_active_download_transfer();
    return web_bridge_refusal('stale_search', 'search is not complete, current or actionable')
        unless web_bridge_activate_searchbot($source_id);
    my $search = $WEB_BRIDGE{sb};
    return web_bridge_refusal('stale_search', 'search is not complete, current or actionable')
        unless $search && !$search->{invalidated} && web_bridge_searchbot_is_live() &&
            ($SEARCHBOT{state} // '') eq 'complete' &&
            $search_id eq web_bridge_searchbot_id($search->{query_id});
    my $source_view = web_bridge_source_view($source);
    return web_bridge_refusal('source_not_ready', 'rejoin the configured channel and run a fresh search')
        unless $source_view && $source_view->{state} eq 'ready';
    my $selected = $WEB_BRIDGE_SELECTIONS{$selection_id};
    return web_bridge_refusal('stale_selection', 'selection is unknown or stale')
        unless $selected && $selected->{searchbot} &&
            ($selected->{collection_id} // '') eq ($SEARCHBOT{collection_id} // '') &&
            $selected->{source_id} eq $source_id &&
            $selected->{source_revision} == ($source->{revision} || 0) &&
            $selected->{source_revision} == ($search->{source_revision} || 0) &&
            ($selected->{connection_epoch} || 0) == ($SEARCHBOT{connection_epoch} || 0) &&
            ($selected->{server_identity} // '') eq ($SEARCHBOT{server_identity} // '');
    my $server = web_bridge_source_server($source);
    return web_bridge_refusal('connection_changed', 'selection belongs to a different IRC connection')
        unless $server && $server->{connected} &&
            server_connection_identity($server) eq ($selected->{server_identity} // '') &&
            server_connection_epoch($server) == ($selected->{connection_epoch} || 0);
    my $row = $SEARCHBOT{results}[$selected->{ordinal} - 1] || {};
    my $tag = $server->{tag} // '';
    return web_bridge_refusal('repeat_refused',
        'this file was already requested from this sender on this connection; ' .
        'a repeat is refused because a late offer for the first request could not be told from an offer for the second')
        if searchbot_tombstone_used(\%SEARCHBOT_CONTENT_TOMBSTONES, $server, $tag,
                $selected->{sender}, $row->{filename}) ||
            searchbot_tombstone_used(\%SEARCHBOT_USED_OFFERS, $server, $tag,
                $selected->{sender}, $row->{filename});
    local $WEB_BRIDGE{download_operation_id} = $operation_id;
    local $WEB_BRIDGE{download_network_dir} = $source->{host}
        if $source->{managed_endpoint};
    local $WEB_BRIDGE_SAID = [];
    cmd_searchbot_get($SEARCHBOT{collection_id} . ':' . $selected->{ordinal} .
        ' --sender ' . $selected->{sender}, $server);
    # The job carries the web operation ID from the moment it is recorded,
    # so the journal says whether this request got as far as a job.
    my $job = $JOBS{coordinator}->job_by_web_operation($operation_id);
    unless ($job) {
        my $why = @$WEB_BRIDGE_SAID ? safe_field($WEB_BRIDGE_SAID->[-1])
            : 'the SearchBot safety checks did not start a download';
        return web_bridge_refusal('download_not_started', substr($why, 0, 400));
    }
    $WEB_BRIDGE{last_job_id} = $job->{id};
    return { job_id => $job->{id}, state => $job->{state}, job => web_bridge_job_view($job) };
}

# A row of a search-bot or @find list that the web download queue holds. The
# queue fetches it later, perhaps after this source has searched again, so the
# engine keeps the list the row came from, as it was. A held row is fetched
# only on the connection it arrived on, and at most once; it is posted exactly
# as the list gave it, through the same checks as a Download press.
# $WEB_BRIDGE{sb_holds} holds them by hold ID.

sub web_bridge_hold_is_live {
    my ($hold) = @_;
    my $source = $WEB_BRIDGE_SOURCES{$hold->{source_id} // ''} or return 0;
    return 0 unless ($source->{revision} || 0) == ($hold->{source_revision} || 0);
    my $server = web_bridge_source_server($source);
    return $server && $server->{connected} &&
        server_connection_identity($server) eq ($hold->{server_identity} // '') &&
        server_connection_epoch($server) == ($hold->{connection_epoch} || 0) ? 1 : 0;
}

sub web_bridge_searchbot_hold {
    my ($source, $source_id, $search_id, $selection_id) = @_;
    my $selected = $WEB_BRIDGE_SELECTIONS{$selection_id};
    my ($sb, $search) = web_bridge_searchbot_of($source_id);
    my $named = !$search ? 0
        : $search_id =~ /\Asbot-/ ? $search_id eq web_bridge_searchbot_id($search->{query_id})
        : $selected && $selected->{find_direct} && defined($search->{find_query_id}) &&
            ($selected->{find_search_id} // '') eq $search_id &&
            $search_id eq web_bridge_search_id($search->{find_query_id});
    return web_bridge_refusal('stale_search', 'search is not complete, current or actionable')
        unless $named && !$search->{invalidated} &&
            ($search->{collection_id} // '') eq ($sb->{collection_id} // '') &&
            ($sb->{state} // '') eq 'complete' && ref($sb->{results}) eq 'ARRAY';
    return web_bridge_refusal('stale_selection', 'selection is unknown or stale')
        unless $selected && $selected->{searchbot} &&
            ($selected->{collection_id} // '') eq ($sb->{collection_id} // '') &&
            $selected->{source_id} eq $source_id &&
            $selected->{source_revision} == ($source->{revision} || 0) &&
            ($selected->{connection_epoch} || 0) == ($sb->{connection_epoch} || 0) &&
            ($selected->{server_identity} // '') eq ($sb->{server_identity} // '');
    my $row = $sb->{results}[$selected->{ordinal} - 1];
    return web_bridge_refusal('stale_selection', 'selection is unknown or stale')
        unless ref($row) eq 'HASH' &&
            ($row->{candidate_id} // '') eq ($selected->{candidate_id} // '');
    my %hold = (
        source_id => $source_id, source_revision => $selected->{source_revision},
        server_identity => $selected->{server_identity},
        connection_epoch => $selected->{connection_epoch},
        ordinal => $selected->{ordinal}, sender => $selected->{sender},
    );
    return web_bridge_refusal('connection_changed', 'selection belongs to a different IRC connection')
        unless web_bridge_hold_is_live(\%hold);
    my $hold_id = 'hold-' . substr(sha256_hex(join("\0",
        $WEB_BRIDGE->instance_id(), $selection_id)), 0, 32);
    my $holds = $WEB_BRIDGE{sb_holds} ||= {};
    unless ($holds->{$hold_id}) {
        # Rows of a connection that has gone are of no use; past the limit,
        # the oldest go.
        delete @$holds{grep { !web_bridge_hold_is_live($holds->{$_}) } keys %$holds};
        my @oldest = sort { $holds->{$a}{sequence} <=> $holds->{$b}{sequence} } keys %$holds;
        delete $holds->{shift @oldest} while @oldest >= $WEB_BRIDGE_HOLD_LIMIT;
        $holds->{$hold_id} = {
            %hold, hold_id => $hold_id, sequence => ++$WEB_BRIDGE_HOLD_SEQUENCE,
            # The list as it is: these are all a fetch reads of it.
            searchbot => { map { exists($sb->{$_}) ? ($_ => $sb->{$_}) : () } qw(
                query_id collection_id from_find server_tag network_id channel query
                source_timestamp results server_identity connection_epoch casemapping
                web_destination_network) },
        };
        $holds->{$hold_id}{searchbot}{state} = 'complete';
        $holds->{$hold_id}{searchbot}{active} = 0;
    }
    my $shown = web_bridge_searchbot_row($sb, $search, $selected->{ordinal}, 0) || {};
    return {
        hold_id => $hold_id, source_id => $source_id, sender => $selected->{sender},
        trigger => $shown->{trigger}, path => $shown->{path},
        size_bytes => $shown->{size_bytes},
    };
}

# Fetch a held row: its list is made the current one for this one request.
# The list that was current is set aside as a parked list, so its rows stay
# downloadable as before.
sub web_bridge_searchbot_held_download {
    my ($source, $source_id, $hold_id, $operation_id) = @_;
    my $holds = $WEB_BRIDGE{sb_holds} || {};
    my $hold = $holds->{$hold_id};
    my $gone = 'this queued row is no longer held (the engine restarted, or the source ' .
        'changed or reconnected); search again and add it again';
    return web_bridge_refusal('stale_hold', $gone)
        unless $hold && $hold->{source_id} eq $source_id;
    return web_bridge_refusal('search_active', 'wait for the running search to finish first')
        if any_find_active() || $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
    return web_bridge_refusal('transfer_busy', 'finish or cancel the current transfer first')
        if $S{active} || searchbot_direct_active() || $DOWNLOAD_PATH_OWNER ||
            has_active_download_transfer();
    my $source_view = web_bridge_source_view($source);
    return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
        unless $source_view && $source_view->{state} eq 'ready';
    unless (web_bridge_hold_is_live($hold)) {
        delete $holds->{$hold_id};
        return web_bridge_refusal('stale_hold', $gone);
    }
    my $server = web_bridge_source_server($source);
    my $list = $hold->{searchbot};
    my $row = $list->{results}[$hold->{ordinal} - 1] || {};
    my $tag = $server->{tag} // '';
    if (searchbot_tombstone_used(\%SEARCHBOT_CONTENT_TOMBSTONES, $server, $tag,
            $hold->{sender}, $row->{filename}) ||
        searchbot_tombstone_used(\%SEARCHBOT_USED_OFFERS, $server, $tag,
            $hold->{sender}, $row->{filename})) {
        delete $holds->{$hold_id};
        return web_bridge_refusal('repeat_refused',
            'this file was already requested from this sender on this connection; ' .
            'a repeat is refused because a late offer for the first request could not be told from an offer for the second');
    }
    unless (($SEARCHBOT{collection_id} // '') eq ($list->{collection_id} // '') &&
            ($SEARCHBOT{state} // '') eq 'complete') {
        my $current = $WEB_BRIDGE{sb};
        $WEB_BRIDGE{sb_parked}{$current->{source_id}} =
            { searchbot => { %SEARCHBOT }, search => $current }
            if $current && !$current->{invalidated} && web_bridge_searchbot_is_live();
        delete $WEB_BRIDGE{sb};
        %SEARCHBOT = (%$list, server => $server);
    }
    local $WEB_BRIDGE{download_operation_id} = $operation_id;
    local $WEB_BRIDGE{download_network_dir} = $source->{host}
        if $source->{managed_endpoint};
    local $WEB_BRIDGE_SAID = [];
    cmd_searchbot_get($list->{collection_id} . ':' . $hold->{ordinal} .
        ' --sender ' . $hold->{sender}, $server);
    my $job = $JOBS{coordinator}->job_by_web_operation($operation_id);
    unless ($job) {
        my $why = @$WEB_BRIDGE_SAID ? safe_field($WEB_BRIDGE_SAID->[-1])
            : 'the SearchBot safety checks did not start a download';
        return web_bridge_refusal('download_not_started', substr($why, 0, 400));
    }
    delete $holds->{$hold_id};
    $WEB_BRIDGE{last_job_id} = $job->{id};
    return { job_id => $job->{id}, state => $job->{state}, job => web_bridge_job_view($job) };
}

1;
