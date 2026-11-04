# Browse: reading a file server's folders for the page.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

our (%S, %SEARCHBOT, %WEB_BRIDGE, %WEB_BRIDGE_SOURCES, $DOWNLOAD_PATH_OWNER,
     $WEB_BRIDGE, $WEB_BRIDGE_BROWSE_ENTRY_LIMIT, $WEB_BRIDGE_BROWSE_FOLDER_LIMIT,
     $WEB_BRIDGE_BROWSE_SECONDS, $WEB_BRIDGE_SAID);

# Browsing a file server from the page (2026-10-21). One walk of its folders
# through the engine's own crawl session: its trigger is sent once, as for a
# download, and then only "cd" and "dir", at the session's usual pacing, at
# most fscrawl_max_depth folders deep and $WEB_BRIDGE_BROWSE_FOLDER_LIMIT
# folders in all. Nothing is requested. When the walk ends, or after
# $WEB_BRIDGE_BROWSE_SECONDS, the session is closed, and what was read is
# kept in $WEB_BRIDGE{browse} for browse.status.

sub web_bridge_browse_id {
    my ($operation_id) = @_;
    return 'browse-' . substr(sha256_hex(join("\0",
        $WEB_BRIDGE ? $WEB_BRIDGE->instance_id() : '', $operation_id)), 0, 32);
}

sub web_bridge_browse_start {
    my ($source, $source_id, $args, $operation_id) = @_;
    my $browse = $WEB_BRIDGE{browse};
    return web_bridge_browse_view($browse, 0, 0)
        if $browse && $browse->{browse_id} eq web_bridge_browse_id($operation_id);
    my ($sender, $sender_error) = web_bridge_string($args->{sender}, 64, 'sender');
    my ($trigger, $trigger_error) = web_bridge_string($args->{trigger}, 128, 'trigger');
    my ($mode, $mode_error) = web_bridge_string($args->{trigger_mode}, 16, 'trigger_mode');
    return web_bridge_refusal('invalid_arguments', $sender_error || $trigger_error || $mode_error)
        if $sender_error || $trigger_error || $mode_error;
    return web_bridge_refusal('invalid_arguments', 'sender, trigger or trigger mode is not usable')
        unless $sender =~ /\A[A-Za-z\[\]\\`_^{}|][A-Za-z0-9\-\[\]\\`_^{}|]{0,63}\z/ &&
            $trigger =~ /\A[^\s\x00-\x1f\x7f]{1,128}\z/ &&
            $mode =~ /\A(?:channel_text|ctcp)\z/;
    my @from;
    if (defined $args->{path}) {
        my ($path, $path_error) = web_bridge_string($args->{path}, 1024, 'path');
        return web_bridge_refusal('invalid_arguments', $path_error) if $path_error;
        @from = grep { length } split m{/}, $path;
        return web_bridge_refusal('invalid_arguments', 'path is not a usable folder')
            unless $path =~ m{\A/} && !grep { $_ eq '.' || $_ eq '..' } @from;
    }
    my $source_view = web_bridge_source_view($source);
    return web_bridge_refusal('source_not_ready', 'connect and join the configured channel first')
        unless $source_view && $source_view->{state} eq 'ready';
    return web_bridge_refusal('search_active', 'wait for the running search to finish first')
        if any_find_active() || searchbot_direct_active() ||
            $SEARCHBOT{active} || ($SEARCHBOT{state} // '') eq 'receiving';
    return web_bridge_refusal('transfer_busy', 'finish or cancel the current transfer first')
        if $S{active} || $DOWNLOAD_PATH_OWNER || has_active_download_transfer();
    my $server = web_bridge_source_server($source);
    return web_bridge_refusal('connection_changed', 'source connection is no longer available')
        unless $server && $server->{connected};
    my $trigger_command = $mode eq 'ctcp'
        ? 'CTCP ' . $sender . ' ' . $trigger
        : 'MSG ' . $source->{channel} . ' ' . $trigger;
    local $WEB_BRIDGE_SAID = [];
    start_fserve_session($sender, $server, $trigger_command, undef);
    unless ($S{active} && !$S{direct_fetch}) {
        my $why = @$WEB_BRIDGE_SAID ? safe_field($WEB_BRIDGE_SAID->[-1])
            : 'the FServe session checks did not start a browse';
        return web_bridge_refusal('browse_not_started', substr($why, 0, 400));
    }
    $S{folder_limit} = $WEB_BRIDGE_BROWSE_FOLDER_LIMIT;
    $S{crawl_from} = [@from];
    $S{max_depth} += @from;
    $browse = $WEB_BRIDGE{browse} = {
        start_path => '/' . join('/', @from),
        browse_id => web_bridge_browse_id($operation_id), source_id => $source_id,
        source_revision => $source->{revision}, sender => $sender, trigger => $trigger,
        trigger_mode => $mode, state => 'browsing', started_at => time(),
        generation => $S{generation}, entries => [], truncated => 0,
    };
    $S{web_browse} = $browse->{browse_id};
    engine_log_add('engine', $server, "Browsing the folders of $sender through $trigger",
        [$source_id]);
    web_bridge_browse_watch();
    return web_bridge_browse_view($browse, 0, 0);
}

# Checked every second while a browse runs.
sub web_bridge_browse_watch {
    my $browse = $WEB_BRIDGE{browse} or return;
    return unless $browse->{state} eq 'browsing';
    my $mine = ($S{web_browse} // '') eq $browse->{browse_id} &&
        ($S{generation} || 0) == ($browse->{generation} || 0);
    if ($mine) {
        my @entries = grep { ref($_) eq 'HASH' && ($_->{type} // '') =~ /\A(?:dir|file)\z/ }
            @{$S{catalog} || []};
        if (@entries > $WEB_BRIDGE_BROWSE_ENTRY_LIMIT) {
            splice @entries, $WEB_BRIDGE_BROWSE_ENTRY_LIMIT;
            $browse->{truncated} = 1;
        }
        $browse->{entries} = [map { {
            type => $_->{type}, path => $_->{path},
            ($_->{type} eq 'dir' ? (read => $S{visited}{path_key(
                [grep { length } split m{/}, $_->{path} // ''])} ? 1 : 0) : ()),
            (defined($_->{size_raw}) ? (size_raw => $_->{size_raw}) : ()),
            (defined($_->{size_bytes}) ? (size_bytes => $_->{size_bytes}) : ()),
        } } @entries];
        $browse->{folders_read} = $S{folders_listed} || 0;
        $browse->{truncated} = 1 if $S{browse_truncated};
    }
    my $phase = $mine ? ($S{phase} // '') : 'gone';
    my $late = time() - $browse->{started_at} > $WEB_BRIDGE_BROWSE_SECONDS;
    if ($mine && $phase ne 'complete' && $phase ne 'error' && !$late) {
        my $timer = eval { Irssi::timeout_add_once(1000, \&web_bridge_browse_watch, undef) };
        return if $timer;
        $late = 1;
    }
    $browse->{state} = $phase eq 'complete' ? 'complete' : 'failed';
    $browse->{finished_at} = time();
    my $folders = $browse->{folders_read} || 0;
    $browse->{note} = $phase eq 'complete'
        ? ($browse->{truncated} ? "Only the first $folders folders were read." : undef)
        : $late ? "Browsing took more than " . int($WEB_BRIDGE_BROWSE_SECONDS / 60) .
            " minutes and was stopped; $folders folders were read."
        : $phase eq 'error' ? "The file server's session did not answer as expected; " .
            "$folders folders were read."
        : "The session ended before its folders were read; $folders were.";
    stop_session(1) if $mine;
    engine_log_add('engine', $WEB_BRIDGE_SOURCES{$browse->{source_id}}{server_tag} // '',
        "Browsing $browse->{sender} ended: " . scalar(@{$browse->{entries}}) . ' entries' .
        (defined($browse->{note}) ? '. ' . $browse->{note} : ''), [$browse->{source_id}]);
}

sub web_bridge_browse_view {
    my ($browse, $offset, $limit) = @_;
    my $entries = $browse->{entries} || [];
    my $end = $offset + $limit;
    $end = @$entries if $end > @$entries;
    return {
        browse_id => $browse->{browse_id}, source_id => $browse->{source_id},
        source_revision => $browse->{source_revision}, sender => $browse->{sender},
        trigger => $browse->{trigger}, trigger_mode => $browse->{trigger_mode},
        state => $browse->{state}, started_at => $browse->{started_at},
        start_path => $browse->{start_path} // '/',
        (defined($browse->{note}) ? (note => $browse->{note}) : ()),
        truncated => $browse->{truncated} ? JSON::PP::true : JSON::PP::false,
        folders_read => $browse->{folders_read} || 0,
        total => scalar(@$entries), offset => $offset,
        entries => [map { {
            %{$entries->[$_]},
            (exists($entries->[$_]{read})
                ? (read => $entries->[$_]{read} ? JSON::PP::true : JSON::PP::false) : ()),
            path => substr(safe_field($entries->[$_]{path}), 0, 1024),
            (defined($entries->[$_]{size_raw})
                ? (size_raw => substr(safe_field($entries->[$_]{size_raw}), 0, 32)) : ()),
        } } $offset .. $end - 1],
    };
}

1;
