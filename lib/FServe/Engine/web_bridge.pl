# The web bridge: the page's requests, their checks, and the engine's status.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use File::Basename qw(basename);
use File::Spec ();
use JSON::PP ();
use Socket qw(AF_INET6 inet_pton);

our (%FIND, %JOBS, %S, %SEARCHBOT, %SEARCHBOT_DIRECT, %TRANSFERS, %WEB_BRIDGE,
     %WEB_BRIDGE_ADVERTS, %WEB_BRIDGE_SELECTIONS, %WEB_BRIDGE_SOURCES,
     $ADVERT_LIST_LIMIT, $DOWNLOAD_PATH_OWNER, $ENGINE_LOG_PAGE_LINES,
     $SEARCHBOT_SEQUENCE, $WEB_BRIDGE, $WEB_BRIDGE_STATUS_BYTES);

my $WEB_BRIDGE_SOURCE_LIMIT = 8;

# Whether a web download of a file server's file may start now (2026-10-22).
# With at_once below 2, only when nothing else runs, as always. With 2, also
# alongside one transfer that is already being received from another file
# server: no offer is being accepted, nothing of a search bot's runs, and the
# only session open is the idle one of that transfer. Returns a refusal, or
# undef and whether the download runs alongside another.
sub web_bridge_download_room {
    my ($server, $sender, $at_once) = @_;
    my $busy = web_bridge_refusal('transfer_busy', 'finish or cancel the current transfer first');
    $at_once = 1 unless defined($at_once) && $at_once =~ /\A[12]\z/;
    return ($busy) if searchbot_direct_active() || $DOWNLOAD_PATH_OWNER;
    my @transfers = values %TRANSFERS;
    return (undef, 0) unless @transfers || $S{active};
    return ($busy) if $at_once < 2 || @transfers >= $at_once || !@transfers;
    my $mapping = server_casemapping($server);
    my $identity = server_connection_identity($server) // '';
    for my $transfer (@transfers) {
        return ($busy) unless ($transfer->{state} // '') eq 'receiving' &&
            ($transfer->{kind} // '') ne 'searchbot_content';
        return (web_bridge_refusal('transfer_busy',
                'a file from this file server is still arriving; one at a time from each'))
            if defined($sender) && ($transfer->{server_identity} // '') eq $identity &&
                FServe::ConnectionIdentity::same_irc_identity($transfer->{nick} // '', $sender,
                    $mapping);
    }
    if ($S{active}) {
        my $pending = $S{pending_download};
        my $key = $pending ? $pending->{accepted_transfer_key} : undef;
        return ($busy) unless $S{direct_fetch} && $pending &&
            defined($pending->{web_operation_id}) && defined($key) && $TRANSFERS{$key} &&
            ($TRANSFERS{$key}{state} // '') eq 'receiving';
    }
    return (undef, 1);
}

# Close the idle session of a transfer being received, so another can open;
# the transfer goes on by itself (stop_session leaves it be).
sub web_bridge_make_room {
    return unless $S{active};
    log_line('STATE', 'idle session closed for a download alongside') if $S{log_file};
    stop_session(1);
}

sub web_bridge_refusal {
    my ($code, $message) = @_;
    return { __bridge_error => 1, code => $code, message => $message };
}

sub web_bridge_check_args {
    my ($args, $allowed, $required) = @_;
    return 'arguments must be an object' unless ref($args) eq 'HASH';
    my %allowed = map { $_ => 1 } @$allowed;
    return 'request contains an unsupported argument'
        if grep { !$allowed{$_} } keys %$args;
    return 'request is missing a required argument'
        if grep { !exists($args->{$_}) } @$required;
    return;
}

sub web_bridge_string {
    my ($value, $maximum, $label) = @_;
    return (undef, "$label must be a string")
        unless defined($value) && !ref($value);
    return (undef, "$label is empty or too long")
        unless length($value) && length($value) <= $maximum;
    return (undef, "$label contains a control character")
        if $value =~ /[\x00-\x1f\x7f]/;
    return ($value, undef);
}

# The browser owns one direct fetch, not an interactive FServe CHAT session.
# When the engine refuses that fetch before any GET, an operator at the Irssi
# prompt would read the refusal and carry on in the open session. Nothing does
# that for the browser: the job would stay "preparing" and the open session
# would refuse every later web search, download and disconnect. Record the
# refusal on the job and close the session instead. $file is the refused
# pending download.
sub web_bridge_settle_refused_fetch {
    my ($file, $outcome, $reason) = @_;
    return unless ref($file) eq 'HASH' &&
        ($file->{web_operation_id} // '') =~ /\Aweb-download-[a-f0-9]{64}\z/;
    my $job_id = $file->{phase6_job_id} // $S{phase6_job_id};
    my $job = defined($job_id) && jobs_ready()
        ? $JOBS{coordinator}->job($job_id) : undef;
    job_transition($job_id, 'stale',
        outcome => $outcome, reason => safe_field($reason))
        if $job && $job->{state} =~ /\A(?:held|preparing)\z/;
    # Refusals are reported from inside CHAT line handling, so close that
    # CHAT from a timer rather than from within its own input callback.
    my $generation = $S{generation};
    return unless defined $generation;
    my $stop = sub {
        stop_session(1) if session_is_current($generation) && !$S{pending_download};
    };
    $S{stop_due} = $stop;
    $stop->() unless eval { Irssi::timeout_add_once(10, $stop, undef) };
}

sub web_bridge_publish {
    my ($event, $payload) = @_;
    return unless $WEB_BRIDGE;
    eval { $WEB_BRIDGE->publish_event($event, $payload); 1 };
}

sub web_bridge_publish_search_state {
    my ($query_id, $note) = @_;
    return unless $WEB_BRIDGE && $WEB_BRIDGE{search} &&
        ($WEB_BRIDGE{search}{query_id} || 0) == ($query_id || 0);
    my $snapshot = web_bridge_find_snapshot(0, 0);
    $snapshot->{note} = $note if defined $note;
    web_bridge_publish('search.state', $snapshot);
}

# Each source keeps its own finished search, so results from several sources
# stay downloadable at once. The Find engine holds exactly one search, in
# %FIND, and every safety check reads it there. So a finished search that is
# not the current one is parked whole, and put back before anything acts on
# it. Only a complete, valid search is parked; a running one never is.
sub web_bridge_park_current_search {
    my $search = $WEB_BRIDGE{search} or return;
    return if $FIND{active} || $search->{invalidated};
    return unless ($search->{query_id} || 0) == ($FIND{query_id} || 0) &&
        ($FIND{state} // '') eq 'complete';
    $WEB_BRIDGE{parked}{$search->{source_id}} = { find => { %FIND }, search => $search };
}

sub web_bridge_source_find_active {
    my ($source_id) = @_;
    return 1 if $FIND{active} && !($WEB_BRIDGE{search} &&
        defined($WEB_BRIDGE{search}{source_id}) &&
        $WEB_BRIDGE{search}{source_id} ne $source_id);
    my $aside = $WEB_BRIDGE{aside}{$source_id};
    return $aside && $aside->{find}{active} ? 1 : 0;
}

# The search set aside that a reply from this connection belongs to.
sub web_bridge_aside_for_server {
    my ($server) = @_;
    my $tag = lc(ref($server) ? $server->{tag} // '' : '');
    return unless length $tag;
    my ($entry) = grep {
        $_->{find}{active} && lc($_->{find}{server_tag} // '') eq $tag
    } values %{$WEB_BRIDGE{aside} || {}};
    return $entry;
}

# A search set aside that has finished completely is parked, as any finished
# search that is not the current one is. One that ended otherwise stays aside
# for its status until its source searches again.
sub web_bridge_settle_aside {
    my $aside = $WEB_BRIDGE{aside} or return;
    for my $source_id (keys %$aside) {
        my $entry = $aside->{$source_id};
        next if $entry->{find}{active} || ($entry->{find}{state} // '') ne 'complete' ||
            !$entry->{search} || $entry->{search}{invalidated};
        $WEB_BRIDGE{parked}{$source_id} = { find => { %{$entry->{find}} },
                                            search => $entry->{search} };
        delete $aside->{$source_id};
    }
}

# Make a source's search the current one. False when it has none, or when a
# running search or an open session must not be disturbed.
sub web_bridge_activate_search {
    my ($source_id) = @_;
    my $current = $WEB_BRIDGE{search};
    return 1 if $current && ($current->{source_id} // '') eq $source_id;
    my $parked = $WEB_BRIDGE{parked}{$source_id} or return 0;
    return 0 if any_find_active() || $S{active};
    web_bridge_park_current_search();
    delete $WEB_BRIDGE{parked}{$source_id};
    %FIND = %{$parked->{find}};
    $WEB_BRIDGE{search} = $parked->{search};
    return 1;
}

# Run $code with a source's search loaded, then put back what was there. For
# reading only: nothing is sent and no signal is handled in between.
sub web_bridge_with_search {
    my ($source_id, $code) = @_;
    my $current = $WEB_BRIDGE{search};
    return $code->() if $current && ($current->{source_id} // '') eq $source_id;
    my $aside = $WEB_BRIDGE{aside}{$source_id};
    return find_with($aside->{find}, $aside->{search}, $code) if $aside;
    my $parked = $WEB_BRIDGE{parked}{$source_id} or return undef;
    my %held = %FIND;
    %FIND = %{$parked->{find}};
    $WEB_BRIDGE{search} = $parked->{search};
    my $result = eval { $code->() };
    my $error = $@;
    %FIND = %held;
    $WEB_BRIDGE{search} = $current;
    die $error if $error;
    return $result;
}

sub web_bridge_forget_selections {
    my ($source_id) = @_;
    delete @WEB_BRIDGE_SELECTIONS{grep {
        ($WEB_BRIDGE_SELECTIONS{$_}{source_id} // '') eq $source_id } keys %WEB_BRIDGE_SELECTIONS};
}

sub web_bridge_invalidate_search {
    my ($source_id, $state, $note, $detach) = @_;
    return unless defined $source_id;
    web_bridge_invalidate_searchbot($source_id, $state, $note);
    my $search = $WEB_BRIDGE{search};
    my $is_current = $search && ($search->{source_id} // '') eq $source_id;
    my $parked = $is_current ? undef : $WEB_BRIDGE{parked}{$source_id};
    # A search set aside stays aside, marked, for its status.
    my $aside = $is_current ? undef : $WEB_BRIDGE{aside}{$source_id};
    return unless $is_current || $parked || $aside;
    my $snapshot = web_bridge_with_search($source_id, sub {
        my $mine = $WEB_BRIDGE{search};
        $mine->{invalidated} = 1;
        $mine->{terminal_state} = $state;
        $mine->{terminal_note} = $note if defined $note;
        web_bridge_forget_selections($source_id);
        my $view = web_bridge_find_snapshot(0, 10);
        $view->{note} = $note if defined $note;
        $mine->{terminal_snapshot} = $view if $detach && ($is_current || $aside);
        return $view;
    });
    delete $WEB_BRIDGE{parked}{$source_id};
    web_bridge_publish('search.state', $snapshot) if $snapshot;
}

# A file-servers source's direct rows from its latest @find, as a SearchBot
# list parked under the source. It names the search it came from, and is
# shown after that search's other results. Fetching a row activates it as
# any parked SearchBot list is activated.
sub web_bridge_find_direct_list {
    my $search = $WEB_BRIDGE{search};
    my $rows = $FIND{direct_rows};
    return unless $search && !$search->{invalidated} &&
        ($search->{query_id} || 0) == ($FIND{query_id} || 0) &&
        ref($rows) eq 'ARRAY' && @$rows && load_searchbot_provider();
    my $source_id = $search->{source_id};
    my $query_id = ++$SEARCHBOT_SEQUENCE;
    my $collection_id = 'searchbot-' . $query_id . '-' . substr(sha256_hex(join("\0",
        $FIND{server_tag} // '', $FIND{network_id} // '', $FIND{channel} // '',
        $FIND{terms} // '', $$, time, rand())), 0, 32);
    my $stamp = now_iso();
    my $reader = FServe::Discovery::SearchBot->new(
        collection_id => $collection_id, network_id => $FIND{network_id},
        server_tag => $FIND{server_tag}, discovery_channel => $FIND{channel},
        query => $FIND{terms}, source_timestamp => $stamp);
    for my $line (@$rows) {
        # One row the reader refuses would refuse the whole list, so each
        # is tried alone first and a refused one is left out.
        my $probe = FServe::Discovery::SearchBot->new(
            collection_id => 'probe', discovery_channel => $FIND{channel});
        next if grep { ($_->{type} // '') eq 'refusal' } @{$probe->feed_line($line)};
        $reader->feed_line($line);
    }
    my $done = $reader->finish;
    return unless ref($done) eq 'HASH' && ($done->{type} // '') eq 'complete';
    my $server = eval { Irssi::server_find_tag($FIND{server_tag}) };
    delete $WEB_BRIDGE{sb} if $WEB_BRIDGE{sb} &&
        ($WEB_BRIDGE{sb}{source_id} // '') eq $source_id;
    $WEB_BRIDGE{sb_parked}{$source_id} = {
        searchbot => {
            query_id => $query_id, collection_id => $collection_id, active => 0,
            state => 'complete', from_find => 1, server_tag => $FIND{server_tag},
            network_id => $FIND{network_id}, channel => $FIND{channel},
            query => $FIND{terms}, source_timestamp => $stamp,
            results => $done->{results}, server => $server,
            server_identity => $FIND{server_identity},
            connection_epoch => $FIND{connection_epoch},
            casemapping => server_casemapping($server),
        },
        search => {
            query_id => $query_id, collection_id => $collection_id,
            source_id => $source_id, source_revision => $search->{source_revision},
            terms => $FIND{terms}, channel => $FIND{channel},
            started_at => $search->{started_at}, find_query_id => $FIND{query_id},
        },
    };
}

# The direct-row list belonging to the @find in %FIND, if there is one.
sub web_bridge_find_direct_of {
    my ($source_id) = @_;
    my ($sb, $search) = web_bridge_searchbot_of($source_id);
    return unless $search && defined($search->{find_query_id}) &&
        $search->{find_query_id} == ($FIND{query_id} || 0) &&
        ($search->{collection_id} // '') eq ($sb->{collection_id} // '') &&
        ($sb->{state} // '') eq 'complete' && ref($sb->{results}) eq 'ARRAY';
    return ($sb, $search);
}

# An optional true/false argument: only JSON true counts.
sub web_bridge_flag {
    my ($value) = @_;
    return ref($value) && JSON::PP::is_bool($value) && $value ? 1 : 0;
}

sub web_bridge_search_id {
    my ($query_id) = @_;
    return unless $WEB_BRIDGE && defined $query_id;
    return 'find-' . $WEB_BRIDGE->instance_id() . '-' . $query_id;
}

sub web_bridge_selection_view {
    my ($ordinal) = @_;
    return unless $WEB_BRIDGE && ref($FIND{results}) eq 'ARRAY' &&
        $ordinal >= 1 && $ordinal <= @{$FIND{results}} && $ordinal <= 5000;
    my $result = $FIND{results}[$ordinal - 1];
    return unless ref($result) eq 'HASH';
    my ($path, $path_error) = web_bridge_string($result->{remote_path}, 4096, 'result path');
    my ($nick, $nick_error) = web_bridge_string($result->{server_nick}, 64, 'result sender');
    my ($trigger, $trigger_error) = web_bridge_string($result->{trigger_raw}, 128, 'result trigger');
    return if $path_error || $nick_error || $trigger_error ||
        length(encode_utf8($path)) > 4096;
    my $search_id = web_bridge_search_id($FIND{query_id});
    my $source_id = $WEB_BRIDGE{search} &&
        $WEB_BRIDGE{search}{query_id} == ($FIND{query_id} || 0)
            ? $WEB_BRIDGE{search}{source_id} : undef;
    return unless defined $source_id;
    my $selection_id;
    unless ($WEB_BRIDGE{search}{invalidated}) {
        $selection_id = 'sel-' . substr(sha256_hex(join("\0",
            $WEB_BRIDGE->instance_id(), $search_id, $ordinal,
            $FIND{server_identity} // '', $FIND{connection_epoch} // 0,
            $result->{remote_path} // '', $result->{server_nick} // '',
            $result->{trigger_raw} // '')), 0, 40);
        $WEB_BRIDGE_SELECTIONS{$selection_id} ||= {
            query_id => $FIND{query_id}, ordinal => $ordinal,
            server_identity => $FIND{server_identity},
            connection_epoch => $FIND{connection_epoch},
            source_id => $source_id,
            source_revision => $WEB_BRIDGE{search}{source_revision},
        };
    }
    my $size_bytes = defined($result->{size_bytes}) && !ref($result->{size_bytes}) &&
        $result->{size_bytes} =~ /\A\d{1,18}\z/ ? 0 + $result->{size_bytes} : undef;
    my $size_precision = ($result->{size_precision} // '') =~
        /\A(?:unknown|estimated|exact)\z/ ? $result->{size_precision} : 'unknown';
    return {
        (defined($selection_id) ? (selection_id => $selection_id) : ()),
        ordinal => $ordinal,
        source_id => $source_id,
        source_revision => $WEB_BRIDGE{search}{source_revision},
        sender => $nick,
        trigger => $trigger,
        trigger_mode => $result->{trigger_mode} // 'channel_text',
        path => $path,
        size_text => safe_field($result->{size_raw}),
        size_bytes => $size_bytes,
        size_precision => $size_precision,
    };
}

sub web_bridge_find_snapshot {
    my ($offset, $limit) = @_;
    my $search = $WEB_BRIDGE{search};
    return $search->{terminal_snapshot}
        if $search && ($search->{query_id} || 0) != ($FIND{query_id} || 0) &&
            ref($search->{terminal_snapshot}) eq 'HASH';
    return { state => 'unavailable', results => [], result_count => 0 }
        unless $search && ($search->{query_id} || 0) == ($FIND{query_id} || 0);
    my @results;
    my $listed = scalar @{$FIND{results} || []};
    my ($direct_sb, $direct_search) = web_bridge_find_direct_of($search->{source_id});
    my $direct_total = $direct_sb ? scalar @{$direct_sb->{results}} : 0;
    my $total = $listed + $direct_total;
    my $end = $offset + $limit;
    $end = $total if $end > $total;
    for my $ordinal ($offset + 1 .. $end) {
        if ($ordinal <= $listed) {
            my $record = web_bridge_selection_view($ordinal);
            push @results, $record if $record;
            next;
        }
        my $selectable = !$search->{invalidated} && !$direct_search->{invalidated} ? 1 : 0;
        my $record = web_bridge_searchbot_row($direct_sb, $direct_search,
            $ordinal - $listed, $selectable) or next;
        $record->{ordinal} = $ordinal;
        $record->{trigger_mode} = 'direct';
        $record->{source_revision} = $search->{source_revision};
        if (defined $record->{selection_id}) {
            my $selected = $WEB_BRIDGE_SELECTIONS{$record->{selection_id}};
            $selected->{find_direct} = 1;
            $selected->{find_search_id} = web_bridge_search_id($search->{query_id});
        }
        push @results, $record;
    }
    return {
        search_id => web_bridge_search_id($search->{query_id}),
        source_id => $search->{source_id},
        state => $search->{invalidated} ? ($search->{terminal_state} // 'stale') :
            $FIND{active}
            ? (($FIND{state} // '') eq 'dispatch_pending' ? 'dispatch_pending' : 'collecting')
            : ($FIND{state} // 'unknown'),
        (defined($search->{terminal_note}) ? (note => $search->{terminal_note})
            : defined($FIND{note}) ? (note => $FIND{note}) : ()),
        terms => $FIND{terms},
        channel => $FIND{channel},
        started_at => $search->{started_at},
        result_count => $total,
        selectable_result_limit => 5000,
        offset => $offset,
        results => \@results,
    };
}

sub web_bridge_list_job_name {
    my ($job) = @_;
    my $destination = ref($job->{finalization}) eq 'HASH'
        ? $job->{finalization}{destination_path} : undef;
    return (File::Spec->splitpath($destination))[2] if defined($destination) && length($destination);
    return $SEARCHBOT_DIRECT{expected_basename}
        if ($SEARCHBOT_DIRECT{phase6_job_id} // '') eq ($job->{id} // '');
    return undef;
}

sub web_bridge_job_view {
    my ($job) = @_;
    return unless ref($job) eq 'HASH';
    my $selection = ref($job->{selection}) eq 'HASH' ? $job->{selection} : {};
    my $partial = ref($job->{partial}) eq 'HASH' ? $job->{partial} : {};
    my $finalization = ref($job->{finalization}) eq 'HASH' ? $job->{finalization} : {};
    my $context = ref($job->{context}) eq 'HASH' ? $job->{context} : {};
    # While a posted row waits for its file, what its sender last said is
    # the reason shown (2026-10-20).
    my $reason = $job->{reason};
    $reason = 'The file server said: ' . $SEARCHBOT_DIRECT{sender_said}
        if ($SEARCHBOT_DIRECT{phase6_job_id} // '') eq ($job->{id} // '') &&
            ($job->{state} // '') =~ /\A(?:dispatch_intent|awaiting_offer|remote_queued)\z/ &&
            length($SEARCHBOT_DIRECT{sender_said} // '');
    # While the session is opened afresh before the request (2026-10-22).
    my $recovery = $JOBS{pre_dispatch_recovery};
    $reason = "The file server's session dropped before the file was asked for; " .
        "trying again ($recovery->{attempts} of $recovery->{max_attempts})"
        if $recovery && ($recovery->{job_id} // '') eq ($job->{id} // '') &&
            ($job->{state} // '') eq 'preparing' && $recovery->{attempts};
    my $view = {
        job_id => $job->{id}, state => $job->{state}, provider => $job->{provider},
        outcome => $job->{outcome}, reason => safe_field($reason),
        network => $job->{network_profile},
        sender => $selection->{expected_peer} // $selection->{sender},
        # A list request names no file until its list is offered (2026-10-27).
        name => substr(safe_field(($job->{provider} // '') eq 'list'
            ? (web_bridge_list_job_name($job) // ($selection->{expected_peer} // '') . "'s list")
            : $selection->{basename} // $selection->{name}), 0, 512),
        remote_path => substr(safe_field($selection->{remote_path}), 0, 512),
        created_at => $job->{created_at}, updated_at => $job->{updated_at},
        transition_sequence => $job->{transition_sequence},
        (defined($context->{web_operation_id})
            ? (web_operation_id => $context->{web_operation_id}) : ()),
    };
    $view->{bytes_received} = 0 + $partial->{size}
        if defined($partial->{size}) && $partial->{size} =~ /\A\d+\z/;
    $view->{total_bytes} = 0 + $partial->{total_size}
        if defined($partial->{total_size}) && $partial->{total_size} =~ /\A\d+\z/;
    $view->{total_bytes} = 0 + $finalization->{expected_size}
        if !defined($view->{total_bytes}) && defined($finalization->{expected_size}) &&
            $finalization->{expected_size} =~ /\A\d+\z/;
    # A complete file was checked to be this size before it was kept; the
    # partial record holds only the last count taken while it arrived (seen
    # on 2026-10-21 as 0 or part of the size on finished downloads).
    $view->{bytes_received} = 0 + $finalization->{expected_size}
        if ($job->{state} // '') eq 'complete' && defined($finalization->{expected_size}) &&
            $finalization->{expected_size} =~ /\A\d+\z/;
    # A running transfer has no partial record yet. Report what has reached
    # its staging file, the same measure the partial record uses later, and
    # the size the sender advertised.
    if (($job->{state} // '') eq 'receiving') {
        my ($transfer) = grep { ($_->{phase6_job_id} // '') eq ($job->{id} // '') }
            values %TRANSFERS;
        if ($transfer) {
            my $path = $transfer->{receive_source} // $transfer->{dcc_file};
            $view->{bytes_received} = 0 + ((-s $path) || 0)
                if defined($path) && length($path) && -f $path;
            my $advertised = $transfer->{expected_size} //
                ($transfer->{dcc} ? $transfer->{dcc}{size} : undef);
            $view->{total_bytes} = 0 + $advertised
                if !defined($view->{total_bytes}) && defined($advertised) &&
                    !ref($advertised) && $advertised =~ /\A[1-9]\d*\z/;
        }
    }
    # Session state is cleared once the transfer settles, so resolve the
    # download root from its setting rather than from the finished session.
    my $download_dir = ($job->{provider} // '') eq 'list' ? lists_dir()
        : resolve_irssi_path(Irssi::settings_get_str('fscrawl_download_dir'));
    if (defined($finalization->{destination_path}) && defined($download_dir) &&
            length($download_dir)) {
        my $relative = eval {
            my $root = File::Spec->canonpath(File::Spec->rel2abs($download_dir));
            my $destination = File::Spec->canonpath(
                File::Spec->rel2abs($finalization->{destination_path}));
            File::Spec->abs2rel($destination, $root);
        };
        if (defined($relative) && length($relative) && $relative ne '.' &&
                !File::Spec->file_name_is_absolute($relative) &&
                !(grep { $_ eq '..' } File::Spec->splitdir($relative))) {
            $view->{download_path} = safe_field($relative);
        }
    }
    return $view;
}

sub web_bridge_status {
    my @servers;
    for my $server (Irssi::servers()) {
        next unless ref($server);
        push @servers, {
            tag => safe_field($server->{tag}),
            network_id => safe_field($server->{chatnet} // $server->{tag}),
            nick => safe_field($server->{nick}),
            connected => $server->{connected} ? JSON::PP::true : JSON::PP::false,
        };
        last if @servers >= 100;
    }
    my @sources = map { $WEB_BRIDGE_SOURCES{$_} } sort keys %WEB_BRIDGE_SOURCES;
    my $source = $WEB_BRIDGE_SOURCES{primary} // $sources[0];
    my @jobs;
    my $journal_ready = jobs_ready() ? 1 : 0;
    if ($journal_ready) {
        my $jobs = eval { $JOBS{coordinator}->jobs } || {};
        for my $id (sort { ($jobs->{$b}{created_at} || 0) <=> ($jobs->{$a}{created_at} || 0) } keys %$jobs) {
            my $view = web_bridge_job_view($jobs->{$id});
            push @jobs, $view if $view;
            last if @jobs >= 20;
        }
    }
    my $status = {
        engine_instance_id => $WEB_BRIDGE->instance_id(),
        event_sequence => $WEB_BRIDGE->event_sequence(),
        servers => \@servers,
        source => $source ? web_bridge_source_view($source) : undef,
        sources => [map { web_bridge_source_view($_) } @sources],
        # The search that is running, if one is; otherwise the current Find.
        search => ($SEARCHBOT{active} && web_bridge_searchbot_is_live())
            ? web_bridge_searchbot_snapshot($WEB_BRIDGE{sb}{source_id}, 0, 0)
            : $WEB_BRIDGE{search} ? web_bridge_find_snapshot(0, 0) : undef,
        # The current search of every source that has one, by source ID. A
        # source whose kind was changed may still have a search of its old
        # kind on record; only one of its present kind is its current search.
        searches => {
            (map { my $id = $_; my $view = web_bridge_with_search($id, sub {
                      web_bridge_find_snapshot(0, 0) });
                  $view ? ($id => $view) : () }
                grep { defined && length && !web_bridge_source_is_searchbot($_) }
                    (($WEB_BRIDGE{search} ? $WEB_BRIDGE{search}{source_id} : undef),
                     keys %{$WEB_BRIDGE{aside} || {}},
                     keys %{$WEB_BRIDGE{parked} || {}})),
            (map { my $view = web_bridge_searchbot_snapshot($_, 0, 0);
                   $view ? ($_ => $view) : () }
                grep { defined && length && web_bridge_source_is_searchbot($_) }
                    (($WEB_BRIDGE{sb} ? $WEB_BRIDGE{sb}{source_id} : undef),
                     keys %{$WEB_BRIDGE{sb_parked} || {}})),
        },
        jobs => \@jobs,
        journal_ready => $journal_ready ? JSON::PP::true : JSON::PP::false,
    };
    return web_bridge_fit_status($status);
}

# A reply has to fit in one bridge frame. Twenty jobs whose names are long
# and in a script of several bytes a character do not, so the oldest are
# left out until the status fits; jobs_omitted says how many were.
sub web_bridge_fit_status {
    my ($status) = @_;
    my $jobs = $status->{jobs};
    my $json = JSON::PP->new->canonical(1)->utf8(1);
    my $size = length($json->encode({ %$status, jobs => [] }));
    my @sizes = map { length($json->encode($_)) + 1 } @$jobs;
    $size += $_ for @sizes;
    my $omitted = 0;
    while (@$jobs && $size > $WEB_BRIDGE_STATUS_BYTES) {
        $size -= pop @sizes;
        pop @$jobs;
        $omitted++;
    }
    $status->{jobs_omitted} = $omitted if $omitted;
    return $status;
}

sub web_bridge_dispatch {
    my ($operation, $args, $request_id, $operation_id) = @_;
    my ($allowed, $required);
    my %schemas = (
        status => [[], []],
        'source.configure' => [[qw(source_id server_tag revision label provider search_bot host port tls nickname channel)], [qw(source_id channel)]],
        'source.connect' => [[qw(source_id)], [qw(source_id)]],
        'source.remove' => [[qw(source_id)], [qw(source_id)]],
        'manifest.download' => [[qw(source_id sender trigger trigger_mode path retry_before_request at_once)],
                                [qw(source_id sender trigger trigger_mode path)]],
        'source.disconnect' => [[qw(source_id)], [qw(source_id)]],
        'search.find' => [[qw(source_id terms)], [qw(source_id terms)]],
        'search.status' => [[qw(source_id search_id offset limit)], [qw(source_id search_id)]],
        'search.cancel' => [[qw(source_id search_id)], [qw(source_id search_id)]],
        'search.download' => [[qw(source_id search_id selection_id retry_before_request at_once)],
                              [qw(source_id search_id selection_id)]],
        'browse.start' => [[qw(source_id sender trigger trigger_mode path)],
                           [qw(source_id sender trigger trigger_mode)]],
        'browse.status' => [[qw(source_id browse_id offset limit)], [qw(source_id browse_id)]],
        'searchbot.hold' => [[qw(source_id search_id selection_id)], [qw(source_id search_id selection_id)]],
        'searchbot.held_download' => [[qw(source_id hold_id)], [qw(source_id hold_id)]],
        'list.request' => [[qw(source_id sender advertised typed)], [qw(source_id sender)]],
        'list.download' => [[qw(source_id sender name size_raw list_name)],
                            [qw(source_id sender name)]],
        'job.status' => [[qw(job_id)], [qw(job_id)]],
        'job.find_by_operation' => [[qw(web_operation_id)], [qw(web_operation_id)]],
        'job.cancel' => [[qw(job_id)], [qw(job_id)]],
        'adverts.list' => [[qw(source_id offset limit)], [qw(source_id)]],
        'servers.ask' => [[qw(source_id)], [qw(source_id)]],
        'servers.answers' => [[qw(source_id)], [qw(source_id)]],
        'list.accept' => [[qw(source_id sender name)], [qw(source_id sender name)]],
        'log.list' => [[qw(after limit)], []],
        'source.login' => [[qw(source_id kind username password certificate)], [qw(source_id kind)]],
    );
    return web_bridge_refusal('unsupported_operation', 'operation is not supported')
        unless exists $schemas{$operation};
    ($allowed, $required) = @{$schemas{$operation}};
    my $invalid = web_bridge_check_args($args, $allowed, $required);
    return web_bridge_refusal('invalid_arguments', $invalid) if defined $invalid;
    finish_due_stop();

    if ($operation eq 'status') {
        return web_bridge_status();
    }
    if ($operation eq 'log.list') {
        my $after = defined($args->{after}) ? $args->{after} : 0;
        my $limit = defined($args->{limit}) ? $args->{limit} : $ENGINE_LOG_PAGE_LINES;
        return web_bridge_refusal('invalid_arguments', 'after and limit must be nonnegative integers')
            if ref($after) || ref($limit) || $after !~ /\A\d{1,15}\z/ || $limit !~ /\A\d{1,3}\z/;
        return web_bridge_refusal('invalid_arguments', "limit must be between 1 and $ENGINE_LOG_PAGE_LINES")
            unless $limit >= 1 && $limit <= $ENGINE_LOG_PAGE_LINES;
        return web_bridge_log_page(0 + $after, 0 + $limit);
    }
    if ($operation eq 'source.configure') {
        my ($source_id, $id_error) = web_bridge_string($args->{source_id}, 64, 'source_id');
        my ($channel, $channel_error) = web_bridge_string($args->{channel}, 200, 'channel');
        return web_bridge_refusal('invalid_arguments', $id_error || $channel_error)
            if $id_error || $channel_error;
        return web_bridge_refusal('invalid_arguments', 'source_id has an invalid format')
            unless $source_id =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/;
        return web_bridge_refusal('invalid_arguments', 'channel is not a valid IRC channel name')
            unless $channel =~ /\A[#&+!][^\s,\x00-\x1f\x7f]{0,199}\z/;
        my $managed = exists $args->{host};
        my ($tag, $label, $provider, $host, $port, $tls, $nickname, $revision);
        my $search_bot = '';
        return web_bridge_refusal('invalid_arguments', 'a search bot needs a managed endpoint')
            if exists($args->{search_bot}) && !$managed;
        if ($managed) {
            return web_bridge_refusal('invalid_arguments',
                'server_tag cannot be combined with a managed endpoint')
                if exists $args->{server_tag};
            for my $required_field (qw(label provider port tls nickname revision)) {
                return web_bridge_refusal('invalid_arguments',
                    'managed source configuration is missing ' . $required_field)
                    unless exists $args->{$required_field};
            }
            ($label) = web_bridge_string($args->{label}, 80, 'label');
            ($provider) = web_bridge_string($args->{provider}, 64, 'provider');
            ($host) = web_bridge_string($args->{host}, 253, 'host');
            ($nickname) = web_bridge_string($args->{nickname}, 30, 'nickname');
            return web_bridge_refusal('invalid_arguments', 'label must be printable text')
                unless defined($label) && $label =~ /\A[^\x00-\x1f\x7f]{1,80}\z/;
            return web_bridge_refusal('invalid_arguments', 'provider is not supported')
                unless defined($provider) && $provider =~ /\A(?:sysreset_find|searchbot)\z/;
            if ($provider eq 'searchbot') {
                ($search_bot) = web_bridge_string($args->{search_bot}, 64, 'search_bot');
                return web_bridge_refusal('invalid_arguments',
                    'a search-bot source needs the nickname of its search bot')
                    unless searchbot_nick_is_safe($search_bot);
            } else {
                return web_bridge_refusal('invalid_arguments',
                    'only a search-bot source has a search bot nickname')
                    if exists $args->{search_bot};
            }
            my $hostname_label = qr/[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?/;
            my $hostname_ok = defined($host) &&
                $host =~ /\A(?=.{1,253}\z)$hostname_label(?:\.$hostname_label)*\z/;
            my $ipv6_ok = defined($host) && $host =~ /\A[0-9A-Fa-f:]+\z/ &&
                index($host, ':') >= 0 && defined(eval { inet_pton(AF_INET6, $host) });
            return web_bridge_refusal('invalid_arguments', 'host is not a valid hostname or IP address')
                unless $hostname_ok || $ipv6_ok;
            return web_bridge_refusal('invalid_arguments', 'port must be an integer from 1 through 65535')
                unless defined($args->{port}) && !ref($args->{port}) &&
                    $args->{port} =~ /\A\d{1,5}\z/ && $args->{port} >= 1 && $args->{port} <= 65535;
            return web_bridge_refusal('invalid_arguments', 'tls must be a JSON boolean')
                unless ref($args->{tls}) eq 'JSON::PP::Boolean';
            return web_bridge_refusal('invalid_arguments', 'nickname is not a valid IRC nickname')
                unless defined($nickname) &&
                    $nickname =~ /\A[A-Za-z\[\]\\`_^{}|][A-Za-z0-9\-\[\]\\`_^{}|]{0,29}\z/;
            return web_bridge_refusal('invalid_arguments', 'revision must be a positive integer')
                unless defined($args->{revision}) && !ref($args->{revision}) &&
                    $args->{revision} =~ /\A[1-9]\d{0,8}\z/;
            ($port, $revision) = (0 + $args->{port}, 0 + $args->{revision});
            $tls = $args->{tls} ? 1 : 0;
        } else {
            return web_bridge_refusal('invalid_arguments',
                'managed endpoint fields require host')
                if grep { exists $args->{$_} }
                    qw(revision label provider port tls nickname);
            return web_bridge_refusal('invalid_arguments', 'server_tag is required for an existing Irssi connection')
                unless exists $args->{server_tag};
            ($tag) = web_bridge_string($args->{server_tag}, 64, 'server_tag');
            return web_bridge_refusal('invalid_arguments', 'server_tag has an invalid format')
                unless defined($tag) && $tag =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/;
        }
        return web_bridge_refusal('unsupported_source_limit',
            "at most $WEB_BRIDGE_SOURCE_LIMIT sources can be configured")
            if !$WEB_BRIDGE_SOURCES{$source_id} &&
                keys(%WEB_BRIDGE_SOURCES) >= $WEB_BRIDGE_SOURCE_LIMIT;
        # Each source is one IRC connection. Two sources naming the same
        # server and nickname would claim one connection twice, and the
        # reconnect ownership checks could not tell them apart.
        if ($managed) {
            for my $other (values %WEB_BRIDGE_SOURCES) {
                next if ($other->{source_id} // '') eq $source_id || !$other->{managed_endpoint};
                return web_bridge_refusal('duplicate_source_endpoint',
                    'another source already uses this server and nickname')
                    if lc($other->{host} // '') eq lc($host) &&
                        ($other->{port} || 0) == $port &&
                        lc($other->{nickname} // '') eq lc($nickname);
                # Two sources of one kind on one server and channel would put
                # the same query there twice when both are searched (the
                # owner's rule of 2026-10-13), except on a lab or test
                # server. The port is not compared: a network's plain and TLS
                # ports are one server.
                return web_bridge_refusal('duplicate_source_channel',
                    'another source of the same kind already has this channel on this server')
                    if !web_bridge_host_is_local($host) &&
                        lc($other->{host} // '') eq lc($host) &&
                        ($other->{provider} // '') eq $provider &&
                        web_bridge_channel_key($other->{channel}) eq web_bridge_channel_key($channel);
            }
        }
        my $previous = $WEB_BRIDGE_SOURCES{$source_id};
        # A byte-for-byte replay of the current managed revision is a no-op,
        # even while connected or working. This is needed for service startup
        # reconciliation after the bounded operation cache has evicted a prior
        # successful configure acknowledgement. It must not mutate selections
        # or interrupt the current operation.
        if ($managed && $previous && $previous->{managed_endpoint} &&
                $args->{revision} == $previous->{revision}) {
            my $same =
                ($previous->{label} // '') eq $label &&
                ($previous->{provider} // '') eq $provider &&
                ($previous->{search_bot} // '') eq $search_bot &&
                lc($previous->{host} // '') eq lc($host) &&
                ($previous->{port} || 0) == $port &&
                ($previous->{tls} || 0) == $tls &&
                ($previous->{nickname} // '') eq $nickname &&
                ($previous->{channel} // '') eq $channel;
            return { source => web_bridge_source_view($previous) } if $same;
            return web_bridge_refusal('source_revision_conflict',
                'source revision was already used for different configuration');
        }
        return web_bridge_refusal('source_busy',
            'finish or cancel active work before changing the source')
            if any_find_active() || $S{active} || searchbot_direct_active() ||
                $SEARCHBOT{active} || has_active_download_transfer();
        if ($previous) {
            my $previous_server = web_bridge_source_server($previous);
            return web_bridge_refusal('source_busy',
                'disconnect the current channel before changing its source binding')
                if web_bridge_source_in_use($previous);
        }
        my $server;
        if (!$managed) {
            $server = eval { Irssi::server_find_tag($tag) };
            return web_bridge_refusal('server_not_found',
                'the server tag must already exist in Irssi and be connected')
                unless $server && $server->{connected};
        }
        return web_bridge_refusal('stale_source_revision',
            'source revision is older than the currently applied configuration')
            if $managed && $previous && $previous->{managed_endpoint} &&
                $revision <= ($previous->{revision} || 0);
        if ($managed && $previous && $previous->{managed_endpoint} &&
                web_bridge_cancel_source_reconnects($previous) < 0) {
            return web_bridge_refusal('reconnect_cancel_failed',
                'Irssi still has a pending reconnect for the previous source endpoint');
        }
        web_bridge_invalidate_search($source_id, 'stale',
            'source configuration changed; run a fresh search before downloading');
        web_bridge_cancel_source_join_timer($previous) if $previous;
        $revision = ($previous ? $previous->{revision} || 0 : 0) + 1
            unless $managed;
        my $join_generation = ($previous ? $previous->{join_generation} || 0 : 0) + 1;
        my $already_joined = $server && server_has_joined_channel($server, $channel) ? 1 : 0;
        $WEB_BRIDGE_SOURCES{$source_id} = {
            source_id => $source_id, server_tag => ($server ? $server->{tag} : $tag),
            channel => $channel,
            revision => $revision, join_generation => $join_generation,
            desired_joined => $already_joined,
            ($managed ? (managed_endpoint => 1, label => $label, provider => $provider,
                search_bot => $search_bot, host => $host, port => $port, tls => $tls, nickname => $nickname) : ()),
            ( $already_joined ? (state => 'ready') : (state => 'configured') ),
        };
        # A login is for the server it was given for.
        web_bridge_forget_login($source_id)
            unless web_bridge_login_for($WEB_BRIDGE_SOURCES{$source_id});
        # Selections belong to the current search. One on this source was
        # invalidated above; one on another source keeps its selections.
        web_bridge_forget_selections($source_id);
        web_bridge_publish('source.state', { source => web_bridge_source_view($WEB_BRIDGE_SOURCES{$source_id}) });
        return { source => web_bridge_source_view($WEB_BRIDGE_SOURCES{$source_id}) };
    }
    if ($operation eq 'job.find_by_operation') {
        my ($web_operation_id, $operation_error) =
            web_bridge_string($args->{web_operation_id}, 80, 'web_operation_id');
        return web_bridge_refusal('invalid_arguments', $operation_error)
            if $operation_error;
        return web_bridge_refusal('invalid_arguments', 'web_operation_id has an invalid format')
            unless $web_operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
        return web_bridge_refusal('journal_unavailable', 'durable job journal is unavailable')
            unless jobs_ready();
        my $job = $JOBS{coordinator}->job_by_web_operation($web_operation_id);
        return { job => $job ? web_bridge_job_view($job) : undef };
    }
    if ($operation eq 'job.status' || $operation eq 'job.cancel') {
        my ($job_id, $job_error) = web_bridge_string($args->{job_id}, 64, 'job_id');
        return web_bridge_refusal('invalid_arguments', $job_error) if $job_error;
        return web_bridge_refusal('journal_unavailable', 'durable job journal is unavailable')
            unless jobs_ready();
        my $job = $JOBS{coordinator}->job($job_id);
        return web_bridge_refusal('unknown_job', 'job ID is not present in the durable journal')
            unless $job;
        if ($operation eq 'job.cancel') {
            cmd_queue_cancel($job_id);
            $job = $JOBS{coordinator}->job($job_id) || $job;
        }
        return { job => web_bridge_job_view($job) };
    }
    my ($source_id, $source_id_error) = web_bridge_string($args->{source_id}, 64, 'source_id');
    return web_bridge_refusal('invalid_arguments', $source_id_error) if $source_id_error;
    my $source = $WEB_BRIDGE_SOURCES{$source_id};
    return web_bridge_refusal('unknown_source', 'source is not configured') unless $source;

    return web_bridge_set_login($source, $args) if $operation eq 'source.login';
    if ($operation eq 'adverts.list') {
        my $offset = defined($args->{offset}) ? $args->{offset} : 0;
        my $limit = defined($args->{limit}) ? $args->{limit} : $ADVERT_LIST_LIMIT;
        return web_bridge_refusal('invalid_arguments', 'offset and limit must be nonnegative integers')
            if ref($offset) || ref($limit) || $offset !~ /\A\d{1,8}\z/ || $limit !~ /\A\d{1,3}\z/;
        return web_bridge_refusal('invalid_arguments', "limit must be between 1 and $ADVERT_LIST_LIMIT")
            unless $limit >= 1 && $limit <= $ADVERT_LIST_LIMIT;
        return web_bridge_adverts_page($source, 0 + $offset, 0 + $limit);
    }
    if ($operation eq 'servers.ask') {
        return web_bridge_servers_ask($source, $source_id);
    }
    if ($operation eq 'servers.answers') {
        return web_bridge_servers_view($source_id);
    }
    if ($operation eq 'source.remove') {
        return web_bridge_refusal('source_busy',
            'finish or cancel active work before removing a source')
            if any_find_active() || $S{active} || searchbot_direct_active() ||
                $SEARCHBOT{active} || has_active_download_transfer();
        return web_bridge_refusal('source_busy', 'disconnect the source before removing it')
            if web_bridge_source_in_use($source);
        return web_bridge_refusal('reconnect_cancel_failed',
            'Irssi still has a pending reconnect for this source endpoint')
            if $source->{managed_endpoint} && web_bridge_cancel_source_reconnects($source) < 0;
        web_bridge_invalidate_search($source_id, 'stale',
            'the source was removed; its results can no longer be downloaded');
        web_bridge_cancel_source_join_timer($source);
        delete $WEB_BRIDGE_SOURCES{$source_id};
        delete $WEB_BRIDGE_ADVERTS{$source_id};
        web_bridge_forget_login($source_id);
        web_bridge_publish('source.removed', { source_id => $source_id });
        return { removed => JSON::PP::true, source_id => $source_id };
    }
    if ($operation eq 'source.connect') {
        my $server = web_bridge_source_server($source);
        if ($source->{managed_endpoint} &&
                ($source->{state} // '') eq 'leaving') {
            if (defined($source->{disconnect_timer})) {
                return web_bridge_refusal('source_busy',
                    'wait for the managed connection transition before reconnecting')
                    unless $server;
                $source->{desired_joined} = 1;
                $source->{disconnect_generation} =
                    ($source->{disconnect_generation} || 0) + 1;
                Irssi::timeout_remove(delete $source->{disconnect_timer});
                delete $source->{connect_cancelled};
                # The deferred disconnect has not run yet. Keep the exact
                # native connection and wait for it to become joinable rather
                # than replacing its source tag with a second CONNECT.
                web_bridge_schedule_source_join($source_id, $server);
                return { source => web_bridge_source_view($source) };
            }
            if ($source->{disconnect_inflight}) {
                # Irssi has already received DISCONNECT for this native
                # connection. Let its close signal establish the boundary
                # before opening a fresh managed connection.
                $source->{desired_joined} = 1;
                $source->{reconnect_after_disconnect} = 1;
                delete $source->{connect_cancelled};
                return { source => web_bridge_source_view($source) };
            }
        }
        $source->{desired_joined} = 1;
        $source->{disconnect_generation} = ($source->{disconnect_generation} || 0) + 1;
        Irssi::timeout_remove(delete $source->{disconnect_timer})
            if defined $source->{disconnect_timer};
        delete $source->{connect_cancelled};
        if ($source->{managed_endpoint} && (!$server || !$server->{connected})) {
            if ($source->{connect_pending} || ($source->{state} // '') eq 'connecting') {
                return { source => web_bridge_source_view($source) };
            }
            unless (web_bridge_start_managed_connection($source)) {
                my $why = delete($source->{start_failure}) //
                    'Irssi could not start the configured server connection';
                web_bridge_set_source_state($source, 'failed', $why);
                return web_bridge_refusal('connect_failed', $why);
            }
            return { source => web_bridge_source_view($source) };
        }
        return web_bridge_refusal('server_not_found', 'configured Irssi server tag is unavailable')
            unless $server;
        if ($server->{connected}) {
            if ($source->{part_pending}) {
                $source->{reconnect_after_part} = 1;
                web_bridge_set_source_state($source, 'leaving');
            } elsif (server_has_joined_channel($server, $source->{channel})) {
                delete $source->{join_pending};
                web_bridge_set_source_state($source, 'ready');
            } elsif (defined($source->{join_timer}) || $source->{join_pending} ||
                    ($source->{state} // '') eq 'connecting') {
                # A deferred JOIN is scheduled or server confirmation is pending.
            } else {
                my $ok = eval { $server->command('JOIN ' . $source->{channel}); 1 };
                unless ($ok) {
                    web_bridge_set_source_state($source, 'failed',
                        'Irssi could not send channel join');
                    return web_bridge_refusal('join_failed',
                        'Irssi could not send channel join');
                }
                $source->{join_pending} = 1;
                web_bridge_set_source_state($source, 'joining');
            }
        } elsif (($source->{state} // '') eq 'connecting') {
            # Keep repeated UI requests from starting overlapping connect attempts.
        } else {
            my $ok = eval { $server->connect(); 1 };
            unless ($ok) {
                web_bridge_set_source_state($source, 'failed',
                    'Irssi could not start the configured server connection');
                return web_bridge_refusal('connect_failed',
                    'Irssi could not start the configured server connection');
            }
            web_bridge_set_source_state($source, 'connecting');
        }
        return { source => web_bridge_source_view($source) };
    }
    if ($operation eq 'source.disconnect') {
        return web_bridge_refusal('source_busy',
            'cancel the active search or finish/cancel its transfer before leaving the source channel')
            if web_bridge_source_find_active($source_id) || ($S{active} &&
                ($S{server_tag} // '') eq ($source->{server_tag} // '')) ||
                searchbot_direct_active() || $SEARCHBOT{active} ||
                has_active_download_transfer();
        my $server = web_bridge_source_server($source);
        $source->{desired_joined} = 0;
        delete $source->{reconnect_after_disconnect};
        delete $source->{reconnect_after_part};
        web_bridge_cancel_source_join_timer($source);
        web_bridge_invalidate_search($source_id, 'stale',
            'source membership changed; run a fresh search before downloading');
        if ($source->{managed_endpoint}) {
            # A failed connection is represented by Irssi::Reconnect, not an
            # Irssi::Server. Cancel that owned retry before resolving the
            # runtime server object below.
            if (web_bridge_cancel_source_reconnects($source) < 0) {
                web_bridge_set_source_state($source, 'failed',
                    'Irssi could not cancel the managed endpoint reconnect');
                return web_bridge_refusal('disconnect_failed',
                    'Irssi could not cancel the managed endpoint reconnect');
            }
            if ($source->{disconnect_inflight}) {
                web_bridge_set_source_state($source, 'leaving');
                return { source => web_bridge_source_view($source) };
            }
            if (defined($source->{disconnect_timer})) {
                # A previous Disconnect already owns deferred cleanup for
                # this opening native connection. Keep its tag and timer;
                # the native connected flag may still be false here.
                web_bridge_set_source_state($source, 'leaving');
                return { source => web_bridge_source_view($source) };
            }
            if ($server) {
                my $disconnect_pending = $server->{connected} || $source->{connect_pending} ||
                    (!$server->{connected} &&
                        (($source->{state} // '') eq 'connecting' ||
                            defined($source->{join_timer})));
                $source->{connect_cancelled} = 1 if $source->{connect_pending};
                if ($disconnect_pending || $source->{state} eq 'failed') {
                    web_bridge_set_source_state($source, 'leaving');
                    my $ok = 1;
                    if ($server->{connected} || $source->{connect_pending}) {
                        # Irssi normally reports closure before DISCONNECT
                        # returns, which clears this marker. If the close
                        # signal is still outstanding, a Connect must wait
                        # for it exactly as on the deferred path.
                        $source->{disconnect_inflight} = 1;
                        $ok = web_bridge_disconnect_managed_server($server);
                        delete $source->{disconnect_inflight} unless $ok;
                    } elsif ($disconnect_pending) {
                        web_bridge_schedule_managed_disconnect($source_id, $server);
                        return { source => web_bridge_source_view($source) };
                    }
                    unless ($ok) {
                        web_bridge_set_source_state($source, 'failed',
                            'Irssi could not disconnect from the configured server');
                        return web_bridge_refusal('disconnect_failed',
                            'Irssi could not disconnect from the configured server');
                    }
                    web_bridge_set_source_state($source, 'disconnected')
                        unless $server->{connected} || $source->{connect_pending};
                } else {
                    web_bridge_set_source_state($source, 'disconnected');
                }
            } elsif ($source->{connect_pending}) {
                $source->{connect_cancelled} = 1;
                web_bridge_set_source_state($source, 'leaving');
            } else {
                web_bridge_set_source_state($source, 'disconnected');
            }
            return { source => web_bridge_source_view($source) };
        }
        if ($server && $server->{connected}) {
            if (server_has_joined_channel($server, $source->{channel})) {
                if ($source->{part_pending}) {
                    web_bridge_set_source_state($source, 'leaving');
                    return { source => web_bridge_source_view($source) };
                }
                my $ok = eval { $server->command('PART ' . $source->{channel}); 1 };
                unless ($ok) {
                    web_bridge_set_source_state($source, 'failed',
                        'Irssi could not send channel part');
                    return web_bridge_refusal('part_failed',
                        'Irssi could not send channel part');
                }
                delete $source->{join_pending};
                $source->{part_pending} = 1;
                web_bridge_set_source_state($source, 'leaving');
            } elsif ($source->{join_pending}) {
                # The JOIN is already on the wire. When Irssi confirms it,
                # web_bridge_channel_joined sends the compensating PART.
                web_bridge_set_source_state($source, 'leaving');
            } else {
                web_bridge_set_source_state($source, 'configured');
            }
        } else {
            delete @{$source}{qw(join_pending part_pending)};
            web_bridge_set_source_state($source, 'disconnected');
        }
        return { source => web_bridge_source_view($source) };
    }
    if ($operation eq 'search.find') {
        my ($terms, $terms_error) = web_bridge_string($args->{terms}, 350, 'terms');
        return web_bridge_refusal('invalid_arguments', $terms_error) if $terms_error;
        my $view = web_bridge_source_view($source);
        return web_bridge_refusal('source_not_ready', 'connect and join the configured channel before searching')
            unless $view && $view->{state} eq 'ready';
        # Another source's search may be running; this source's may not.
        return web_bridge_refusal('search_active', 'wait for or cancel the current search')
            if web_bridge_source_find_active($source_id) || $S{active} ||
                searchbot_direct_active() ||
                $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
        my $server = web_bridge_source_server($source);
        return web_bridge_refusal('connection_changed', 'source connection is no longer available')
            unless $server && $server->{connected};
        # The source's type decides what is sent: "@search" to a search bot,
        # "@find" to the channel's file servers.
        return web_bridge_searchbot_start($source, $source_id, $terms, $server)
            if ($source->{provider} // '') eq 'searchbot';
        # This source's earlier search is replaced; another source's
        # finished search is set aside and stays downloadable, and one still
        # running is set aside whole and goes on.
        if ($FIND{active}) {
            $WEB_BRIDGE{aside}{$WEB_BRIDGE{search}{source_id}} =
                { find => \%FIND, search => $WEB_BRIDGE{search} };
            *FIND = {};
            delete $WEB_BRIDGE{search};
        } else {
            web_bridge_park_current_search();
        }
        delete $WEB_BRIDGE{aside}{$source_id};
        delete $WEB_BRIDGE{parked}{$source_id};
        delete $WEB_BRIDGE{sb_parked}{$source_id};
        delete $WEB_BRIDGE{sb} if $WEB_BRIDGE{sb} &&
            ($WEB_BRIDGE{sb}{source_id} // '') eq $source_id;
        web_bridge_forget_selections($source_id);
        # Search IDs never repeat, also after an older search was put back.
        my $previous = $FIND{query_id} || 0;
        $previous = $WEB_BRIDGE{query_high}
            if ($WEB_BRIDGE{query_high} || 0) > $previous;
        $FIND{query_id} = $previous;
        my $next = $previous + 1;
        $WEB_BRIDGE{query_high} = $next;
        $WEB_BRIDGE{search} = {
            query_id => $next, source_id => $source_id,
            source_revision => $source->{revision}, started_at => time(),
        };
        {
            local $WEB_BRIDGE{find_alongside} = 1;
            cmd_find($source->{channel} . ' ' . $terms, $server);
        }
        unless (($FIND{query_id} || 0) == $next && $FIND{active}) {
            delete $WEB_BRIDGE{search};
            return web_bridge_refusal('search_not_started',
                'the existing Find scheduler did not accept this search');
        }
        web_bridge_publish('search.state', web_bridge_find_snapshot(0, 0));
        return web_bridge_find_snapshot(0, 0);
    }
    if ($operation eq 'search.status') {
        my ($search_id, $search_error) = web_bridge_string($args->{search_id}, 128, 'search_id');
        return web_bridge_refusal('invalid_arguments', $search_error) if $search_error;
        if ($search_id =~ /\Asbot-/) {
            my (undef, $mine) = web_bridge_searchbot_of($source_id);
            return web_bridge_refusal('stale_search', 'search is no longer available in this engine instance')
                unless $mine && $search_id eq web_bridge_searchbot_id($mine->{query_id});
            my $offset = defined($args->{offset}) ? $args->{offset} : 0;
            my $limit = defined($args->{limit}) ? $args->{limit} : 10;
            return web_bridge_refusal('invalid_arguments', 'offset and limit must be nonnegative integers')
                if ref($offset) || ref($limit) || $offset !~ /\A\d{1,8}\z/ || $limit !~ /\A\d{1,3}\z/;
            # A result list arrives whole, so its rows are read in larger pages.
            return web_bridge_refusal('invalid_arguments', 'limit must be between 1 and 25')
                unless $limit >= 1 && $limit <= 25;
            return web_bridge_searchbot_snapshot($source_id, 0 + $offset, 0 + $limit);
        }
        my $known = web_bridge_with_search($source_id, sub {
            $search_id eq web_bridge_search_id($WEB_BRIDGE{search}{query_id}) ? 1 : 0 });
        return web_bridge_refusal('stale_search', 'search is no longer available in this engine instance')
            unless $known;
        my $offset = defined($args->{offset}) ? $args->{offset} : 0;
        my $limit = defined($args->{limit}) ? $args->{limit} : 10;
        return web_bridge_refusal('invalid_arguments', 'offset and limit must be nonnegative integers')
            if ref($offset) || ref($limit) || $offset !~ /\A\d{1,8}\z/ || $limit !~ /\A\d{1,3}\z/;
        $offset = 0 + $offset; $limit = 0 + $limit;
        return web_bridge_refusal('invalid_arguments', 'limit must be between 1 and 10')
            unless $limit >= 1 && $limit <= 10;
        return web_bridge_with_search($source_id, sub {
            web_bridge_find_snapshot($offset, $limit) });
    }
    if ($operation eq 'search.cancel') {
        my ($search_id, $search_error) = web_bridge_string($args->{search_id}, 128, 'search_id');
        return web_bridge_refusal('invalid_arguments', $search_error) if $search_error;
        if ($search_id =~ /\Asbot-/) {
            my $mine = $WEB_BRIDGE{sb};
            return web_bridge_refusal('stale_search', 'search is no longer active')
                unless $mine && ($mine->{source_id} // '') eq $source_id &&
                    web_bridge_searchbot_is_live() &&
                    ($SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving') &&
                    $search_id eq web_bridge_searchbot_id($mine->{query_id});
            abort_searchbot_collection(1);
            my $snapshot = web_bridge_searchbot_snapshot($source_id, 0, 0);
            web_bridge_publish('search.state', $snapshot);
            return $snapshot;
        }
        my $cancel = sub {
            return web_bridge_refusal('stale_search', 'search is no longer active')
                unless $FIND{active} && $WEB_BRIDGE{search} &&
                    $search_id eq web_bridge_search_id($FIND{query_id}) &&
                    $WEB_BRIDGE{search}{source_id} eq $source_id;
            $FIND{active} = 0;
            $FIND{state} = 'cancelled';
            $FIND{quiet_token} = ($FIND{quiet_token} || 0) + 1;
            Irssi::timeout_remove($FIND{deadline_timer}) if defined $FIND{deadline_timer};
            Irssi::timeout_remove($FIND{quiet_timer}) if defined $FIND{quiet_timer};
            delete @FIND{qw(deadline_timer quiet_timer)};
            my $snapshot = web_bridge_find_snapshot(0, 0);
            $snapshot->{note} = 'The IRC query may already have been sent; cancellation stops local collection.';
            web_bridge_publish('search.state', $snapshot);
            return $snapshot;
        };
        my $aside = $WEB_BRIDGE{aside}{$source_id};
        return $aside ? find_with($aside->{find}, $aside->{search}, $cancel) : $cancel->();
    }
    if ($operation eq 'search.download') {
        return web_bridge_refusal('invalid_arguments', 'download requires a durable web operation ID')
            unless defined($operation_id) &&
                $operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
        return web_bridge_refusal('journal_unavailable', 'durable job journal is unavailable')
            unless jobs_ready();
        my $existing_job = $JOBS{coordinator}->job_by_web_operation($operation_id);
        return { job_id => $existing_job->{id}, job => web_bridge_job_view($existing_job),
                 state => $existing_job->{state}, replayed => JSON::PP::true }
            if $existing_job;
        my ($search_id, $search_error) = web_bridge_string($args->{search_id}, 128, 'search_id');
        my ($selection_id, $selection_error) = web_bridge_string($args->{selection_id}, 128, 'selection_id');
        return web_bridge_refusal('invalid_arguments', $search_error || $selection_error)
            if $search_error || $selection_error;
        return web_bridge_searchbot_download($source, $source_id, $search_id,
            $selection_id, $operation_id) if $search_id =~ /\Asbot-/;
        my $picked = $WEB_BRIDGE_SELECTIONS{$selection_id};
        if ($picked && $picked->{find_direct}) {
            my (undef, $direct) = web_bridge_searchbot_of($source_id);
            return web_bridge_refusal('stale_selection', 'selection is unknown or stale')
                unless $direct && defined($direct->{find_query_id}) &&
                    ($picked->{find_search_id} // '') eq $search_id &&
                    $search_id eq web_bridge_search_id($direct->{find_query_id});
            return web_bridge_searchbot_download($source, $source_id,
                web_bridge_searchbot_id($direct->{query_id}), $selection_id, $operation_id);
        }
        return web_bridge_refusal('search_active', 'wait for the running search to finish first')
            if any_find_active() || $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
        my ($early_refusal) = web_bridge_download_room(
            web_bridge_source_server($source), undef, $args->{at_once});
        return $early_refusal if $early_refusal;
        # Put this source's finished search back as the current one; the
        # checks below and the fetch itself then read it as they always did.
        return web_bridge_refusal('stale_search', 'search is not complete, current or actionable')
            unless web_bridge_activate_search($source_id);
        return web_bridge_refusal('stale_search', 'search is not complete, current or actionable')
            unless !$FIND{active} && ($FIND{state} // '') eq 'complete' &&
                $WEB_BRIDGE{search} && !$WEB_BRIDGE{search}{invalidated} &&
                $search_id eq web_bridge_search_id($FIND{query_id}) &&
                ($WEB_BRIDGE{search}{source_id} // '') eq $source_id;
        my $source_view = web_bridge_source_view($source);
        return web_bridge_refusal('source_not_ready', 'rejoin the configured channel and run a fresh search')
            unless $source_view && $source_view->{state} eq 'ready';
        my $selected = $WEB_BRIDGE_SELECTIONS{$selection_id};
        return web_bridge_refusal('stale_selection', 'selection is unknown or stale')
            unless $selected && $selected->{query_id} == ($FIND{query_id} || 0) &&
                $selected->{source_id} eq $source_id &&
                $selected->{source_revision} == ($source->{revision} || 0) &&
                $selected->{source_revision} == ($WEB_BRIDGE{search}{source_revision} || 0) &&
                $selected->{connection_epoch} == ($FIND{connection_epoch} || 0) &&
                $selected->{server_identity} eq ($FIND{server_identity} // '');
        my $server = web_bridge_source_server($source);
        return web_bridge_refusal('connection_changed', 'selection belongs to a different IRC connection')
            unless $server && $server->{connected} &&
                server_connection_identity($server) eq $selected->{server_identity} &&
                server_connection_epoch($server) == $selected->{connection_epoch};
        my ($room_refusal, $alongside) = web_bridge_download_room($server,
            ($FIND{results}[$selected->{ordinal} - 1] || {})->{server_nick}, $args->{at_once});
        return $room_refusal if $room_refusal;
        local $WEB_BRIDGE{download_operation_id} = $operation_id;
        local $WEB_BRIDGE{download_auto_recovery} = web_bridge_flag($args->{retry_before_request});
        local $WEB_BRIDGE{download_parallel} = $alongside;
        web_bridge_make_room() if $alongside;
        # A managed connection has a fresh generated tag on every connect.
        # File the download under its configured host instead, so repeated
        # sessions with one server share a directory.
        local $WEB_BRIDGE{download_network_dir} = $source->{host}
            if $source->{managed_endpoint};
        cmd_fetch($selected->{ordinal}, $server);
        my $job_id = $S{active} && $S{direct_fetch}
            ? $S{phase6_job_id} : undef;
        return web_bridge_refusal('download_not_started',
            'the existing FServe safety checks did not start a download')
            unless defined($job_id) && length($job_id);
        $WEB_BRIDGE{last_job_id} = $job_id;
        my $job = $JOBS{coordinator}->job($job_id);
        return { job_id => $job_id, state => 'preparing',
                 ($job ? (job => web_bridge_job_view($job)) : ()) };
    }
    if ($operation eq 'browse.start') {
        return web_bridge_refusal('invalid_arguments', 'browsing requires an operation ID')
            unless defined $operation_id;
        return web_bridge_browse_start($source, $source_id, $args, $operation_id);
    }
    if ($operation eq 'browse.status') {
        my ($browse_id, $browse_error) = web_bridge_string($args->{browse_id}, 64, 'browse_id');
        return web_bridge_refusal('invalid_arguments', $browse_error) if $browse_error;
        my $browse = $WEB_BRIDGE{browse};
        return web_bridge_refusal('stale_browse', 'that browse is no longer held by this engine')
            unless $browse && $browse->{browse_id} eq $browse_id &&
                $browse->{source_id} eq $source_id;
        my $offset = defined($args->{offset}) ? $args->{offset} : 0;
        my $limit = defined($args->{limit}) ? $args->{limit} : 0;
        return web_bridge_refusal('invalid_arguments', 'offset and limit must be nonnegative integers')
            if ref($offset) || ref($limit) || $offset !~ /\A\d{1,8}\z/ || $limit !~ /\A\d{1,3}\z/;
        return web_bridge_refusal('invalid_arguments', 'limit must be at most 100')
            if $limit > 100;
        return web_bridge_browse_view($browse, 0 + $offset, 0 + $limit);
    }
    if ($operation eq 'searchbot.hold') {
        # Nothing is sent: the row is kept for the download queue.
        my ($search_id, $search_error) = web_bridge_string($args->{search_id}, 128, 'search_id');
        my ($selection_id, $selection_error) = web_bridge_string($args->{selection_id}, 128, 'selection_id');
        return web_bridge_refusal('invalid_arguments', $search_error || $selection_error)
            if $search_error || $selection_error;
        return web_bridge_searchbot_hold($source, $source_id, $search_id, $selection_id);
    }
    if ($operation eq 'searchbot.held_download') {
        return web_bridge_refusal('invalid_arguments', 'download requires a durable web operation ID')
            unless defined($operation_id) &&
                $operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
        return web_bridge_refusal('journal_unavailable', 'durable job journal is unavailable')
            unless jobs_ready();
        my $existing_job = $JOBS{coordinator}->job_by_web_operation($operation_id);
        return { job_id => $existing_job->{id}, job => web_bridge_job_view($existing_job),
                 state => $existing_job->{state}, replayed => JSON::PP::true }
            if $existing_job;
        my ($hold_id, $hold_error) = web_bridge_string($args->{hold_id}, 64, 'hold_id');
        return web_bridge_refusal('invalid_arguments', $hold_error) if $hold_error;
        return web_bridge_refusal('invalid_arguments', 'hold_id has an invalid format')
            unless $hold_id =~ /\Ahold-[a-f0-9]{32}\z/;
        return web_bridge_searchbot_held_download($source, $source_id, $hold_id, $operation_id);
    }
    if ($operation eq 'list.request' || $operation eq 'list.download' ||
            $operation eq 'list.accept') {
        # A list server's list, and a file from one (2026-10-27).
        return web_bridge_refusal('invalid_arguments', 'download requires a durable web operation ID')
            unless defined($operation_id) &&
                $operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
        return web_bridge_refusal('journal_unavailable', 'durable job journal is unavailable')
            unless jobs_ready();
        my $existing_job = $JOBS{coordinator}->job_by_web_operation($operation_id);
        return { job_id => $existing_job->{id}, job => web_bridge_job_view($existing_job),
                 state => $existing_job->{state}, replayed => JSON::PP::true }
            if $existing_job;
        my ($sender, $sender_error) = web_bridge_string($args->{sender}, 64, 'sender');
        return web_bridge_refusal('invalid_arguments', $sender_error) if $sender_error;
        # The page's word that it saw the nick offer a list in this channel
        # within the day: this process forgets what it saw when it restarts
        # (2026-10-28).
        return web_bridge_refusal('invalid_arguments', 'advertised must be a JSON boolean')
            if exists($args->{advertised}) && ref($args->{advertised}) ne 'JSON::PP::Boolean';
        # A nick the operator typed (2026-11-02): its list may come from
        # another nick, as a list one nick advertises is sent by another.
        return web_bridge_refusal('invalid_arguments', 'typed must be a JSON boolean')
            if exists($args->{typed}) && ref($args->{typed}) ne 'JSON::PP::Boolean';
        return web_bridge_list_request($source, $source_id, $sender, $operation_id,
            advertised => ($args->{advertised} ? 1 : 0), typed => ($args->{typed} ? 1 : 0))
            if $operation eq 'list.request';
        if ($operation eq 'list.accept') {
            my ($name, $name_error) = web_bridge_string($args->{name}, 255, 'name');
            return web_bridge_refusal('invalid_arguments', $name_error) if $name_error;
            return web_bridge_list_request($source, $source_id, $sender, $operation_id,
                held => { name => $name });
        }
        my ($name, $name_error) = web_bridge_string($args->{name}, 255, 'name');
        return web_bridge_refusal('invalid_arguments', $name_error) if $name_error;
        my $size_raw;
        if (defined $args->{size_raw}) {
            my $size_error;
            ($size_raw, $size_error) = web_bridge_string($args->{size_raw}, 32, 'size_raw');
            return web_bridge_refusal('invalid_arguments', $size_error) if $size_error;
        }
        my $list_name;
        if (defined $args->{list_name}) {
            my $list_name_error;
            ($list_name, $list_name_error) = web_bridge_string($args->{list_name}, 64, 'list_name');
            return web_bridge_refusal('invalid_arguments', $list_name_error) if $list_name_error;
        }
        return web_bridge_list_download($source, $source_id, $sender, $name, $size_raw,
            $operation_id, $list_name);
    }
    if ($operation eq 'manifest.download') {
        # A file named by a stored file list. The list is the web service's,
        # not the engine's: all it supplies is which file to ask which file
        # server for. Whether the file is there is decided as for any direct
        # fetch, by a fresh listing of its folder before the GET.
        return web_bridge_refusal('invalid_arguments', 'download requires a durable web operation ID')
            unless defined($operation_id) &&
                $operation_id =~ /\Aweb-download-[a-f0-9]{64}\z/;
        return web_bridge_refusal('journal_unavailable', 'durable job journal is unavailable')
            unless jobs_ready();
        my $existing_job = $JOBS{coordinator}->job_by_web_operation($operation_id);
        return { job_id => $existing_job->{id}, job => web_bridge_job_view($existing_job),
                 state => $existing_job->{state}, replayed => JSON::PP::true }
            if $existing_job;
        my ($sender, $sender_error) = web_bridge_string($args->{sender}, 64, 'sender');
        my ($trigger, $trigger_error) = web_bridge_string($args->{trigger}, 128, 'trigger');
        my ($mode, $mode_error) = web_bridge_string($args->{trigger_mode}, 16, 'trigger_mode');
        my ($remote, $path_error) = web_bridge_string($args->{path}, 4096, 'path');
        return web_bridge_refusal('invalid_arguments',
            $sender_error || $trigger_error || $mode_error || $path_error)
            if $sender_error || $trigger_error || $mode_error || $path_error;
        # The sender is a nickname and nothing else: a comma would make the
        # CTCP below one message to several users at once.
        return web_bridge_refusal('invalid_arguments', 'sender, trigger or trigger mode is not usable')
            unless $sender =~ /\A[A-Za-z\[\]\\`_^{}|][A-Za-z0-9\-\[\]\\`_^{}|]{0,63}\z/ &&
                $trigger =~ /\A[^\s\x00-\x1f\x7f]{1,128}\z/ &&
                $mode =~ /\A(?:channel_text|ctcp)\z/;
        my $source_view = web_bridge_source_view($source);
        return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
            unless $source_view && $source_view->{state} eq 'ready';
        return web_bridge_refusal('search_active', 'wait for the running search to finish first')
            if any_find_active() || searchbot_direct_active() ||
                $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
        my $server = web_bridge_source_server($source);
        my ($room_refusal, $alongside) = web_bridge_download_room($server, $sender,
            $args->{at_once});
        return $room_refusal if $room_refusal;
        return web_bridge_refusal('connection_changed', 'source connection is no longer available')
            unless $server && $server->{connected};
        return web_bridge_refusal('download_not_started', 'the FServe modules could not be loaded')
            unless load_fserve_parser() && load_dcc_policy() && load_catalog_module();
        my ($path, $parent, $basename) = FServe::Model::split_remote_path($remote);
        return web_bridge_refusal('invalid_arguments', 'path is not a usable remote file path')
            unless defined($path) && defined($parent) && defined($basename) && $path =~ m{\A/};
        my %download = (
            type => 'file', path => $path, parent => $parent, name => $basename,
            trigger_raw => $trigger, trigger_mode => $mode,
            discovery_channel => ($mode eq 'channel_text' ? $source->{channel} : undef),
            server_nick => $sender,
            network_id => ($server->{chatnet} // $server->{tag} // ''),
            server_tag => ($server->{tag} // ''),
            source => 'manifest',
            web_operation_id => $operation_id,
            web_auto_recovery => web_bridge_flag($args->{retry_before_request}),
            web_parallel => $alongside ? 1 : 0,
            ($source->{managed_endpoint} ? (destination_network => $source->{host}) : ()),
        );
        my $trigger_command = $mode eq 'ctcp'
            ? 'CTCP ' . $sender . ' ' . $trigger
            : 'MSG ' . $source->{channel} . ' ' . $trigger;
        web_bridge_make_room() if $alongside;
        start_fserve_session($sender, $server, $trigger_command, \%download);
        my $job_id = $S{active} && $S{direct_fetch} ? $S{phase6_job_id} : undef;
        return web_bridge_refusal('download_not_started',
            'the existing FServe safety checks did not start a download')
            unless defined($job_id) && length($job_id);
        $WEB_BRIDGE{last_job_id} = $job_id;
        my $job = $JOBS{coordinator}->job($job_id);
        return { job_id => $job_id, state => 'preparing',
                 ($job ? (job => web_bridge_job_view($job)) : ()) };
    }
    return web_bridge_refusal('unsupported_operation', 'operation is not supported');
}

1;
