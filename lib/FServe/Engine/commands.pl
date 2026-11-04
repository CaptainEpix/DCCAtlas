# The /fscrawl commands, kept for debugging; the page does not use them.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use File::Basename qw(basename);
use File::Spec ();
use JSON::PP ();

our (%CATALOG, %CATALOG_WORKER, %FIND, %MANIFEST, %JOBS, %S, %SEARCHBOT,
     %SEARCHBOT_DIRECT);

sub cmd_start {
    my ($args, $server) = @_;
    unless ($server && $server->{connected}) {
        p('Start from a window on the already-connected IRC network.');
        return;
    }

    my ($nick, $trigger_cmd) = $args =~ /^\s*(\S+)\s+(.+?)\s*$/;
    unless ($nick && $trigger_cmd) {
        p('Usage: /fscrawl start <expected-nick> <Irssi trigger command>');
        p('Example: /fscrawl start SomeBot msg #channel !some-trigger');
        return;
    }

    start_fserve_session($nick, $server, $trigger_cmd, undef);
}

sub cmd_list {
    my ($filter) = @_;
    return unless load_catalog_module();
    $filter //= '';
    my $matches = FServe::Catalog::matching_files($S{catalog}, $filter, 30);
    for my $match (@$matches) {
        my $file = $match->{file};
        p(sprintf('%4d  %10s  %s  selection=crawl-%d-%d',
            $match->{index}, ($file->{size_raw} // ''), $file->{path},
            $S{generation} || 0, $match->{index}));
    }
    p('No matching files.') unless @$matches;
    p('Showing first 30 matches; refine with /fscrawl list <text>.') if @$matches >= 30;
}

sub find_result_text {
    my ($result) = @_;
    return join(' ', grep { defined($_) && length($_) } (
        $result->{server_nick},
        $result->{trigger_raw},
        $result->{remote_path},
    ));
}

sub show_find_results {
    my ($filter) = @_;
    $filter //= '';
    my $needle = lc($filter);
    my $shown = 0;
    my $results = $FIND{results} || [];

    for my $index (0 .. $#$results) {
        my $result = $results->[$index];
        next if length($needle) && index(lc(find_result_text($result)), $needle) < 0;

        p(sprintf('%4d  %-16s %-12s %10s  %s  selection=find-%d-%d',
            $index + 1,
            safe_field($result->{server_nick}),
            safe_field($result->{trigger_raw}),
            safe_field($result->{size_raw}),
            safe_field($result->{remote_path}),
            $FIND{query_id} || 0, $index + 1,
        ));
        $shown++;
        last if $shown >= 50;
    }

    p('No matching @Find results.') unless $shown;
    p('Showing the first 50 matches; refine with /fscrawl findlist <text>.')
        if $shown >= 50;
}

sub cmd_searchbot_list {
    my ($filter) = @_;
    unless (($SEARCHBOT{state} // '') eq 'complete' &&
            ref($SEARCHBOT{results}) eq 'ARRAY' && @{$SEARCHBOT{results}}) {
        p('No completed SearchBot result collection is available. Run /fscrawl searchbot first.');
        return;
    }

    $filter //= '';
    my $needle = lc($filter);
    my $shown = 0;
    for my $index (0 .. $#{$SEARCHBOT{results}}) {
        my $candidate = $SEARCHBOT{results}[$index];
        next if ($candidate->{collection_id} // '') ne ($SEARCHBOT{collection_id} // '');
        my $selection_id = ($candidate->{collection_id} // '') . ':' .
            ($index + 1);
        my $text = join(' ', grep { defined($_) && length($_) }
            ($candidate->{route_trigger}, $candidate->{filename}, $candidate->{info_raw}, $candidate->{hash_raw}));
        next if length($needle) && index(lc($text), $needle) < 0;
        p(sprintf('%4d  %-54s %-16s %-10s %10s  %s  direct=%s',
            $index + 1,
            safe_field($selection_id),
            escaped_searchbot_payload($candidate->{route_trigger}),
            escaped_searchbot_payload($candidate->{hash_raw}),
            escaped_searchbot_payload($candidate->{info_raw}),
            escaped_searchbot_payload($candidate->{filename}),
            $candidate->{direct_requestable} ? 'yes' : 'no',
        ));
        $shown++;
        last if $shown >= 50;
    }
    p('No matching SearchBot results.') unless $shown;
    p('Use /fscrawl searchbot-preview <selection-id> [--sender <nick>] before /fscrawl searchbot-get <selection-id> --sender <nick>.')
        if $shown;
    p('Showing the first 50 matches; refine with /fscrawl searchbot-list <text>.') if $shown >= 50;
}

sub cmd_searchbot_preview {
    my ($args) = @_;
    my ($selection, $sender) = parse_searchbot_selection_args($args, 'preview');
    unless (defined $selection) {
        p('Usage: /fscrawl searchbot-preview <collection-id:row-number> [--sender <nick>]');
        return;
    }
    my ($status, $candidate) = searchbot_selection_candidate($selection);
    unless ($candidate) {
        p($status eq 'stale'
            ? 'That SearchBot selection belongs to an older or different collection.'
            : 'No completed SearchBot result matches that selection.');
        return;
    }
    my $checked = FServe::Discovery::SearchBotRequest::validate_candidate(
        $candidate, channel => $SEARCHBOT{channel});
    p('SearchBot local preview (no IRC/DCC traffic):');
    p('selection=' . safe_field($selection) . ' network=' . safe_field($SEARCHBOT{network_id}) .
      ' server=' . safe_field($SEARCHBOT{server_tag}) . ' channel=' . safe_field($SEARCHBOT{channel}));
    p('expected filename=' . escaped_searchbot_payload($candidate->{filename}) .
      ' sender=' . (defined($sender) ? escaped_searchbot_payload($sender) : '(must be supplied on get)'));
    p('payload bytes=' . length($candidate->{request_line} // '') .
      ' size hint=' . safe_field($candidate->{info_raw} // 'unknown (DCC size will govern)') .
      ' content cap=' . (configured_searchbot_content_limit() // 'invalid setting'));
    p('outgoing channel text: ' . escaped_searchbot_payload($candidate->{request_line}));
    if (($checked->{type} // '') ne 'valid') {
        p('not requestable: ' . safe_field($checked->{reason}));
    } elsif (defined($sender) && !searchbot_nick_is_safe($sender)) {
        p('not requestable with this sender: invalid IRC nick syntax.');
    } else {
        p('requestable: yes; /fscrawl searchbot-get ' . safe_field($selection) .
          (defined($sender) ? ' --sender ' . safe_field($sender) : ' --sender <nick>'));
    }
}

sub cmd_findlist {
    my ($filter) = @_;
    show_find_results($filter);
}

sub cmd_manifest_candidates {
    my $results = $FIND{results} || [];
    unless (@$results) {
        p('No completed @Find results are available. Run /fscrawl find first.');
        return;
    }
    return unless load_manifest_provider();

    my $candidates = $MANIFEST{provider}->discover_candidates($results);
    $MANIFEST{candidates} = [map { { %$_ } } @$candidates];
    unless (@$candidates) {
        p('No likely text manifest candidates were found in the latest @Find results.');
        p('No IRC or DCC command was sent. Try a more specific /fscrawl find query.');
        return;
    }

    for my $candidate (@$candidates) {
        my $item = $candidate->{item} || {};
        p(sprintf('%4d  score=%-4d %-16s %-12s %s  (%s)',
            $candidate->{index},
            $candidate->{score},
            safe_field($item->{server_nick}),
            safe_field($item->{trigger_raw}),
            safe_field($candidate->{remote_path}),
            safe_field($candidate->{reason}),
        ));
    }
    p('These are discovery hints only. Fetch only a result you explicitly select; the live parent listing must still verify it before GET.');
}

sub unquote_command_value {
    my ($value) = @_;
    $value //= '';
    $value =~ s/^\s+|\s+$//g;
    if ($value =~ /^"(.*)"$/s) {
        $value = $1;
        $value =~ s/\\([\\"])/$1/g;
    } elsif ($value =~ /^'(.*)'$/s) {
        $value = $1;
        $value =~ s/\\([\\'])/$1/g;
    }
    return $value;
}

sub cmd_manifest_import {
    my ($args) = @_;
    if (any_find_active()) {
        p('Wait for @Find collection to finish before importing one of its manifest candidates.');
        return;
    }
    my ($index, $tail) = $args =~ /^\s*(\d+)\s+(.+?)\s*$/s;
    unless (defined($index) && defined($tail)) {
        p('Usage: /fscrawl manifest-import <find-result-index> <local-manifest-file> [--root-profile=name]');
        return;
    }
    my $root_profile;
    $root_profile = $1 if $tail =~ s/\s+--root-profile=([^\s]+)\s*$//;
    my $source = unquote_command_value($tail);
    unless (length($source) && -f $source && -r $source) {
        p("The selected local manifest file is not readable: [$source]");
        return;
    }
    my ($candidate) = grep { ($_->{index} || 0) == $index } @{$MANIFEST{candidates} || []};
    unless ($candidate) {
        p('That index is not a manifest candidate from the latest /fscrawl manifest-candidates output.');
        return;
    }
    my $item = $candidate->{item} || {};
    my $mode = $item->{trigger_mode} // 'unknown';
    my $channel = $item->{discovery_channel} // $FIND{channel} // '';
    unless (($mode eq 'channel_text' || $mode eq 'ctcp') &&
            ($mode ne 'channel_text' || $channel =~ /^[#&+!][^\s,\x00-\x1f\x7f]{0,199}$/)) {
        p('The candidate has no safe, known trigger endpoint; refusing catalog import.');
        return;
    }
    my $network_id = $item->{network_id} // $FIND{network_id} // '';
    my $server_tag = $item->{server_tag} // $FIND{server_tag} // '';
    my $server_nick = $item->{server_nick} // '';
    my $trigger_raw = $item->{trigger_raw} // '';
    unless (length($network_id) && length($server_tag) &&
            $server_nick =~ /^[^\s\x00-\x1f\x7f]{1,64}$/ &&
            $trigger_raw =~ /^[^\s\x00-\x1f\x7f]{1,128}$/) {
        p('The candidate is missing a safe network/server/trigger identity; refusing catalog import.');
        return;
    }
    my $perl = Irssi::settings_get_str('fscrawl_perl_executable') || 'perl';
    unless (length($perl) <= 1024 && $perl !~ /[\x00-\x1f\x7f]/) {
        p('Set fscrawl_perl_executable to a valid external Perl executable; refusing catalog import.');
        return;
    }
    if (!defined($root_profile) || !length($root_profile)) {
        $root_profile = $mode eq 'ctcp' ? 'ctcp' : 'channel:' . $channel;
    }
    if (length($root_profile) > 256 || $root_profile =~ /[\x00-\x1f\x7f]/) {
        p('Root profile must be at most 256 characters and contain no control characters.');
        return;
    }
    my ($library_dir, $worker, $helper, $root) = catalog_worker_paths();
    my $context = {
        network_id => $network_id,
        server_tag => $server_tag,
        server_nick => $server_nick,
        trigger_raw => $trigger_raw,
        trigger_mode => $mode,
        discovery_channel => ($mode eq 'channel_text' ? $channel : ''),
        manifest_remote_path => $candidate->{remote_path},
    };
    my $context_json = JSON::PP->new->canonical(1)->encode($context);
    p("Starting local-only manifest import for candidate $index from [$source]; root profile [$root_profile].");
    p('No IRC or DCC command will be sent. Import runs in the background and can be stopped with /fscrawl manifest-cancel.');
    my $job_id = start_catalog_worker('import', [
        '--source', $source,
        '--context-json', $context_json,
        '--perl', $perl,
        '--library', $library_dir,
        '--helper', $helper,
        '--root-profile', $root_profile,
    ], timeout_ms => 3_700_000, on_progress => sub {
        my ($event) = @_;
        p(sprintf('Manifest import: %d rows staged (%.0fs).',
            $event->{rows} || 0, $event->{elapsed_seconds} || 0));
    }, on_done => sub {
        report_manifest_import_completion(@_);
    });
    p("Manifest worker job $job_id started.") if defined $job_id;
}

sub cmd_manifest_cancel {
    my ($args) = @_;
    return unless load_catalog_worker_client();
    my ($id) = $args =~ /^\s*(\d+)\s*$/;
    my @ids = defined($id) ? ($id) : sort { $a <=> $b } keys %{$CATALOG_WORKER{jobs} || {}};
    unless (@ids) {
        p('No catalog worker jobs are running.');
        return;
    }
    my $cancelled = 0;
    $cancelled += FServe::Catalog::WorkerClient::cancel_job($_) for @ids;
    p($cancelled ? "Cancellation requested for $cancelled catalog worker job(s)." : 'No matching worker job was running.');
}

sub display_manifest_page {
    my ($result) = @_;
    my $rows = $result->{rows};
    unless (ref($rows) eq 'ARRAY') {
        p('Catalog worker returned an invalid page.');
        return;
    }
    $MANIFEST{page_items} = [map { { %$_ } } @$rows];
    $MANIFEST{page_endpoints} = [map { { %$_ } } @{$result->{endpoint_modes} || []}];
    $MANIFEST{page_route_key} = $result->{route_key};
    $MANIFEST{page_snapshot_id} = $result->{snapshot_id};
    $MANIFEST{page_generation} = $result->{generation};
    for my $i (0 .. $#$rows) {
        my $row = $rows->[$i];
        my $size = defined($row->{size_raw}) ? $row->{size_raw} : '?';
        $size .= ' approx' if ($row->{size_precision} // '') eq 'estimated';
        p(sprintf('%3d  %-14s %s  selection=manifest-%d-%d-%d',
            $i + 1, $size, safe_field($row->{path}),
            $MANIFEST{query_sequence} || 0,
            $result->{generation} || 0, $i + 1));
    }
    p(sprintf('%d result(s), snapshot generation %s. Selection numbers are for this page only.',
        scalar(@$rows), $result->{generation} // '?'));
    p('Substring results are in snapshot row order; prefix and parent results are filename order.')
        if ($MANIFEST{last_query}{mode} // '') eq 'search';
    p('No results.') unless @$rows;
    p('Use /fscrawl manifest-get <page-index> [channel|ctcp] to fetch; the live parent listing and snapshot are checked again before GET.')
        if @$rows;
    p('Use /fscrawl manifest-next for the next page.') if $result->{has_more};
}

sub cmd_manifest_query {
    my ($mode, $route_key, $value, $cursor) = @_;
    if (defined($route_key) && $route_key !~ /^[0-9a-f]{64}$/i) {
        p('Route key must be 64 hexadecimal characters. Use /fscrawl manifest-routes.');
        return;
    }
    $value = unquote_command_value($value);
    unless (length($value) || $mode eq 'parent') {
        p("A value is required for manifest $mode.");
        return;
    }
    my $query_id = ++$MANIFEST{query_sequence};
    $MANIFEST{page_items} = [];
    my $last_query = { mode => $mode, route_key => $route_key, value => $value };
    $MANIFEST{last_query} = $last_query;
    my @worker_args;
    my $operation;
    if ($mode eq 'search') {
        $operation = 'search';
        @worker_args = ('--query', $value);
    } else {
        $operation = 'browse';
        @worker_args = ('--mode', $mode, '--value', $value);
    }
    push @worker_args, ('--route-key', $route_key) if defined($route_key) && length($route_key);
    push @worker_args, ('--cursor', $cursor) if defined($cursor) && length($cursor);
    my $job_id = start_catalog_worker($operation, \@worker_args, timeout_ms => 15_000,
        on_done => sub {
            my ($result, $error) = @_;
            return unless ($MANIFEST{query_sequence} || 0) == $query_id;
            if ($error) {
                $MANIFEST{page_items} = [];
                p("Manifest query failed: $error");
                return;
            }
            $last_query->{route_key} = $result->{route_key};
            $last_query->{cursor} = $result->{next_cursor};
            $last_query->{has_more} = $result->{has_more} ? 1 : 0;
            $last_query->{snapshot_id} = $result->{snapshot_id};
            $last_query->{generation} = $result->{generation};
            display_manifest_page($result);
        });
    p("Catalog query job $job_id started.") if defined $job_id;
}

sub manifest_query_arguments {
    my ($rest, $allow_empty) = @_;
    $rest //= '';
    $rest =~ s/^\s+|\s+$//g;
    my ($route_key, $value);
    if ($rest =~ /^([0-9a-f]{64})\s*(.*)$/i) {
        ($route_key, $value) = (lc($1), $2);
    } else {
        $value = $rest;
    }
    $value = '/' if $allow_empty && !length($value);
    return ($route_key, $value);
}

sub cmd_manifest_routes {
    my $job_id = start_catalog_worker('routes', [], timeout_ms => 10_000, on_done => sub {
        my ($result, $error) = @_;
        if ($error) {
            p("Could not list manifest routes: $error");
            return;
        }
        my $routes = $result->{routes} || [];
        for my $route (@$routes) {
            p(sprintf('%s  %-16s %-12s %s  generation=%d files=%d',
                $route->{route_key}, safe_field($route->{server_nick}),
                safe_field($route->{trigger_raw}), safe_field($route->{root_profile}),
                $route->{generation} || 0, $route->{row_count} || 0));
        }
        p('No active manifest snapshots are available.') unless @$routes;
    });
    p("Manifest route query job $job_id started.") if defined $job_id;
}

sub cmd_manifest_gc {
    my ($args) = @_;
    my ($retention) = $args =~ /(?:^|\s)--retention-days=(\d+)(?:\s|$)/;
    $retention //= 30;
    my $apply = $args =~ /(?:^|\s)--apply(?:\s|$)/ ? 1 : 0;
    my @worker_args = ('--retention-days', $retention);
    push @worker_args, '--apply' if $apply;
    my $job_id = start_catalog_worker('gc', \@worker_args, timeout_ms => 30_000,
        on_done => sub {
            my ($result, $error) = @_;
            if ($error) {
                p("Manifest snapshot cleanup failed: $error");
                return;
            }
            if ($result->{dry_run}) {
                p(sprintf('Cleanup preview: %d expired snapshots (%d bytes), %d orphan snapshots, %d abandoned builds. Use /fscrawl manifest-gc --retention-days=%d --apply to remove eligible files.',
                    $result->{retired_candidates} || 0, $result->{candidate_bytes} || 0,
                    $result->{orphan_candidates} || 0, $result->{building_candidates} || 0,
                    $result->{retention_days} || $retention));
            } else {
                p(sprintf('Removed %d old catalog files (%d bytes); active snapshots and fetch leases were preserved.',
                    $result->{removed_files} || 0, $result->{removed_bytes} || 0));
            }
        });
    p("Manifest cleanup job $job_id started.") if defined $job_id;
}

sub cmd_manifest_search {
    my ($route_key, $value) = manifest_query_arguments($_[0], 0);
    cmd_manifest_query('search', $route_key, $value);
}

sub cmd_manifest_prefix {
    my ($route_key, $value) = manifest_query_arguments($_[0], 0);
    cmd_manifest_query('prefix', $route_key, $value);
}

sub cmd_manifest_parent {
    my ($route_key, $value) = manifest_query_arguments($_[0], 1);
    cmd_manifest_query('parent', $route_key, $value);
}

sub cmd_manifest_exact {
    my ($route_key, $value) = manifest_query_arguments($_[0], 0);
    cmd_manifest_query('exact', $route_key, $value);
}

sub cmd_manifest_next {
    my $query = $MANIFEST{last_query};
    unless ($query && $query->{has_more} && defined($query->{cursor})) {
        p('There is no next manifest page. Run a manifest search or browse query first.');
        return;
    }
    cmd_manifest_query($query->{mode}, $query->{route_key}, $query->{value}, $query->{cursor});
}

sub cmd_catalog {
    my ($filter) = @_;
    return unless load_catalog_module();

    my $matches = FServe::Catalog::search_records(
        $CATALOG{store}, $filter, 50
    );
    for my $match (@$matches) {
        my $record = $match->{record};
        my $sources = join(',', @{$record->{sources} || []});
        p(sprintf('%4d  %-16s %-12s %-10s %10s  %s',
            $match->{index},
            safe_field($record->{server_nick}),
            safe_field($record->{trigger_raw}),
            safe_field($sources),
            safe_field($record->{size_raw}),
            safe_field($record->{remote_path}),
        ));
    }
    p('No matching durable catalog records.') unless @$matches;
    p('Showing the first 50 durable catalog records; refine with /fscrawl catalog <text>.')
        if @$matches >= 50;
}

sub cmd_queue_run {
    my ($args, $server) = @_;
    return unless jobs_ready();
    unless ($server && $server->{connected}) {
        p('Run queue-run from an already-connected IRC window; every job will use its captured live connection.');
        return;
    }
    remember_live_server($server);
    my @ids = grep { length } split /\s+/, ($args // '');
    unless (@ids && @ids <= 100 && !grep { !/\Ajob-[a-f0-9]{32}\z/ } @ids) {
        p('Usage: /fscrawl queue-run <job-id> [<job-id> ...] (maximum 100 explicit IDs)');
        return;
    }
    my %unique;
    if (grep { $unique{$_}++ } @ids) {
        p('A queue-run set cannot contain duplicate job IDs.');
        return;
    }
    my $run = $JOBS{run_batch};
    if ($run) {
        my @requested = sort @ids;
        my @captured = sort @{$run->{requested_ids}};
        unless ($JOBS{paused} && @requested == @captured &&
                join("\0", @requested) eq join("\0", @captured)) {
            p('A finite queue run already exists. To resume it after pause, provide the same complete job-ID set; a different set cannot replace it.');
            return;
        }
        my $resume_id = defined($run->{current_job_id})
            ? $run->{current_job_id} : $run->{job_ids}[$run->{index}];
        my $paused_get = defined($resume_id)
            ? paused_get_context_for($resume_id) : undef;
        if ($paused_get && $paused_get->{drain_response}) {
            p('Cannot resume this held job until the outstanding CHAT reply finishes; wait for its prompt or End of list, then rerun the same queue-run set.');
            return;
        }
        $JOBS{paused} = 0;
        $run->{paused_for_attention} = 0;
        p('Resuming the previously captured finite job set.');
        queue_run_next() unless defined($run->{current_job_id}) ||
            $run->{waiting_manifest} || $run->{waiting_crawl};
        return;
    }
    my @jobs;
    my %servers_by_job;
    for my $id (@ids) {
        my $job = $JOBS{coordinator}->job($id);
        my $job_server = server_for_job($job, $server);
        unless ($job && $job->{state} eq 'held' && $job_server) {
            p("Queue run refused: $id is missing, no longer held, or its captured connection is unavailable in this process.");
            return;
        }
        $servers_by_job{$id} = $job_server;
        push @jobs, $job;
    }
    my %requested_order = map { $ids[$_] => $_ } 0 .. $#ids;
    @jobs = sort {
        ($a->{created_at} || 0) <=> ($b->{created_at} || 0) ||
        $requested_order{$a->{id}} <=> $requested_order{$b->{id}}
    } @jobs;
    $JOBS{paused} = 0;
    $JOBS{run_batch} = {
        requested_ids => [@ids],
        job_ids => [map { $_->{id} } @jobs],
        servers_by_job => \%servers_by_job,
        index => 0,
    };
    p('Captured a finite ' . scalar(@jobs) . '-job set in FIFO order across its live IRC connections; later queue additions are excluded.');
    queue_run_next();
}

sub cmd_queue_list {
    return unless jobs_ready();
    my @jobs = sort { ($a->{created_at} || 0) <=> ($b->{created_at} || 0) }
        grep { $_->{state} eq 'held' } values %{$JOBS{coordinator}->jobs};
    p('The local job queue is paused.') if $JOBS{paused};
    p('Held jobs:');
    for my $job (@jobs) {
        p(join(' ', $job->{id}, $job->{provider}, safe_field($job->{network_profile}),
            safe_field($job->{selection}{expected_peer} // $job->{selection}{sender} // '-'),
            '[' . safe_field($job->{selection}{basename} // $job->{selection}{name} // '-') . ']'));
    }
    p('No held jobs.') unless @jobs;
}

sub cmd_job_show {
    my ($id) = @_;
    return unless jobs_ready();
    $id =~ s/^\s+|\s+$//g if defined $id;
    my $job = defined($id) && $id =~ /\Ajob-[a-f0-9]{32}\z/
        ? $JOBS{coordinator}->job($id) : undef;
    unless ($job) { p('Unknown job ID. Use /fscrawl queue-list.'); return; }
    p('job=' . $job->{id} . ' provider=' . $job->{provider} .
      ' state=' . $job->{state} . ' network=' . safe_field($job->{network_profile}));
    p('peer=' . safe_field($job->{selection}{expected_peer} // $job->{selection}{sender} // '-') .
      ' basename=' . safe_field($job->{selection}{basename} // $job->{selection}{name} // '-') .
      ' path=' . safe_field($job->{selection}{remote_path} // '-'));
    p('reason=' . safe_field($job->{reason} // '-') . ' outcome=' . safe_field($job->{outcome} // '-'));
    p('created=' . safe_field($job->{created_at}) .
      ' transition_sequence=' . ($job->{transition_sequence} || 0) .
      ' reserved_tuples=' . $JOBS{coordinator}->tuple_count);
}

sub cmd_queue_pause {
    $JOBS{paused} = 1;
    queue_cancel_dispatch_timer();
    if (my $run = $JOBS{run_batch}) {
        my $current_id = $run->{current_job_id};
        my $current_job = defined($current_id)
            ? $JOBS{coordinator}->job($current_id) : undef;
        my $crawl_pending_match = $current_job && $current_job->{provider} eq 'crawl' &&
            $S{pending_download} &&
            ($S{pending_download}{phase6_job_id} // '') eq $current_id;
        pause_active_queued_get($current_id)
            if defined($current_id) && $S{active} &&
                (($S{phase6_job_id} // '') eq $current_id || $crawl_pending_match) &&
                ($S{phase} // '') ne 'get_dispatch_pending';
        my $withdrawn = defined($current_id)
            ? cancel_outbound_owner('job', $current_id,
                'job queue paused before message dispatch') : 0;
        my $paused_context = defined($current_id)
            ? paused_get_context_for($current_id) : undef;
        $current_job = defined($current_id)
            ? $JOBS{coordinator}->job($current_id) : undef;
        if (($paused_context || ($withdrawn && $current_job &&
                $current_job->{state} eq 'held'))) {
            $run->{current_job_id} = undef;
            $run->{dispatching} = 0;
            $run->{waiting_manifest} = undef;
            $run->{waiting_crawl} = undef;
        }
        Irssi::timeout_remove($run->{advance_timer}) if defined $run->{advance_timer};
        delete $run->{advance_timer};
    }
    p('Local job queue paused; pending unsent application messages were withdrawn. Already dispatched requests and owned transfers are unchanged.');
}

sub cmd_job_retry {
    p('Automatic retry is disabled after any possibly-dispatched request. Refresh/reselect the provider result; the existing tuple guard remains reserved.');
}

sub cmd_job_resume {
    p('Native DCC resume is not enabled: Irssi 1.4.5 offer binding, correlated continuation, and trusted whole-file digest have not passed the isolated capability gate.');
}

sub cmd_status {
    return unless load_fserve_parser();
    my $catalog_available = load_catalog_module();
    my $durable_catalog_count = $catalog_available
        ? FServe::Catalog::record_count($CATALOG{store}) : 0;
    p('active=' . ($S{active} ? 'yes' : 'no') .
      ' phase=' . ($S{phase} // '-') .
      ' nick=' . ($S{nick} // '-') .
      ' chat=' . ($S{chat_connected} ? ($S{chat_id} || 'yes') : 'no') .
      ' catalog_items=' . scalar(@{$S{catalog} || []}) .
      ' durable_catalog_items=' . $durable_catalog_count .
      ' queued_dirs=' . scalar(@{$S{queue} || []}) .
      ' current=' . FServeParser::join_path(@{$S{current_path} || []}) .
      ' nav=' . ($S{nav_active} ? 'yes' : 'no'));
    p('log=' . ($S{log_file} // '-')) if $S{active};
    p('find_active=' . (any_find_active() ? 'yes' : 'no') .
      ' find_results=' . scalar(@{$FIND{results} || []}) .
      ' find_channel=' . ($FIND{channel} // '-'));
    p('searchbot_state=' . ($SEARCHBOT{state} // 'idle') .
      ' searchbot_results=' . scalar(@{$SEARCHBOT{results} || []}) .
      ' searchbot_channel=' . ($SEARCHBOT{channel} // '-'));
    p('searchbot_direct_state=' . ($SEARCHBOT_DIRECT{state} // 'idle') .
      ' request=' . ($SEARCHBOT_DIRECT{request_id} // '-') .
      ' sender=' . ($SEARCHBOT_DIRECT{expected_sender} // '-') .
      ' filename=' . ($SEARCHBOT_DIRECT{expected_basename} // '-'));
    my $session_job_id = $S{phase6_job_id} //
        ($S{pending_download} ? $S{pending_download}{phase6_job_id} : undef);
    my $status_job_id = defined($session_job_id)
        ? $session_job_id : $JOBS{active_job_id};
    if (defined($status_job_id) && jobs_ready()) {
        my $job = $JOBS{coordinator}->job($status_job_id);
        p('active_job=' . $status_job_id .
          ' state=' . ($job->{state} // 'unknown') .
          ' provider=' . ($job->{provider} // 'unknown')) if $job;
    }
}

sub cmd_journal_compact {
    my $coordinator = $JOBS{coordinator};
    unless ($coordinator) {
        unless (jobs_ready()) {
            p('The job journal is unavailable; compaction was not attempted.');
            return;
        }
        $coordinator = $JOBS{coordinator};
    }
    unless (compaction_is_quiet()) {
        p('Journal compaction requires an idle client: finish or pause active transfers and queue work first.');
        return;
    }
    my $library_dir = add_library_dir_to_inc();
    my $worker = File::Spec->catfile($library_dir, 'FServe', 'Transfer', 'compact_journal_worker.pl');
    unless (-f $worker) {
        p("Journal compaction worker is missing from [$worker]; no compaction was attempted.");
        return;
    }
    my $jobs = $coordinator->jobs();
    for my $job (values %$jobs) {
        next if $job->{state} eq 'held' || $job->{state} eq 'needs_attention' ||
            FServe::Transfer::Job::is_terminal($job->{state});
        p('Journal compaction refused because a durable job is still active.');
        return;
    }
    my $maximum = $coordinator->journal->max_journal_bytes();
    $JOBS{compaction_source_identity} = $coordinator->journal->snapshot_identity();
    delete $JOBS{compaction_failed};
    my $timer_api = catalog_worker_timer_api();
    $CATALOG_WORKER{loaded} = 1;
    $JOBS{compaction_active} = 1;
    $JOBS{coordinator} = undef;
    my $closed = eval { $coordinator->close(); 1 };
    unless ($closed) {
        $JOBS{compaction_active} = 0;
        $JOBS{coordinator} = $coordinator;
        delete $JOBS{compaction_source_identity};
        delete $JOBS{compaction_failed};
        my $error = $@ || 'could not release the journal before compaction';
        $error =~ s/[\r\n]+/ /g;
        p("Journal compaction could not start; the existing coordinator remains in memory. $error");
        return;
    }
    $JOBS{compaction_coordinator} = $coordinator;
    my $perl = Irssi::settings_get_str('fscrawl_perl_executable') || $^X;
    my $started = eval {
        $JOBS{compaction_worker_id} = FServe::Catalog::WorkerClient::run_async(
            command => [$perl, $worker, $coordinator->journal->path(), $maximum],
            timeout_ms => 1_800_000,
            schedule_timer => $timer_api->{schedule},
            cancel_timer => $timer_api->{cancel},
            on_event => sub {
                my ($line) = @_;
                my $event = eval { JSON::PP::decode_json($line) };
                die 'journal compaction worker returned invalid JSON' unless ref($event) eq 'HASH';
                if (($event->{event} // '') eq 'result' || ($event->{event} // '') eq 'error') {
                    $JOBS{compaction_result} = $event;
                } else {
                    die 'journal compaction worker returned an unknown event';
                }
            },
            on_done => sub {
                my ($status, $stderr, $failure, $cancelled) = @_;
                my $result = delete $JOBS{compaction_result};
                finish_journal_compaction($status, $stderr, $failure, $cancelled, $result);
            },
        );
        1;
    };
    unless ($started) {
        my $error = $@ || 'could not start asynchronous compaction worker';
        finish_journal_compaction(undef, '', $error, 0, undef);
        return;
    }
    p('Local journal compaction started in a background worker. job queue commands are paused until the verified coordinator is resumed.');
}

sub cmd_fscrawl {
    my ($data, $server, $witem) = @_;
    my ($sub, $rest) = $data =~ /^\s*(\S+)?\s*(.*?)\s*$/;
    $sub = lc($sub // 'help');

    if ($JOBS{compaction_active} && $sub ne 'status' && $sub ne 'help') {
        p('The job queue is paused: ' . compaction_pause_reason() . '.');
        return;
    }

    if ($sub eq 'start')      { cmd_start($rest, $server); }
    elsif ($sub eq 'list')    { cmd_list($rest); }
    elsif ($sub eq 'get')     { cmd_get($rest); }
    elsif ($sub eq 'fetch')   { cmd_fetch($rest, $server); }
    elsif ($sub eq 'find')    { cmd_find($rest, $server); }
    elsif ($sub eq 'findlist'){ cmd_findlist($rest); }
    elsif ($sub eq 'searchbot') { cmd_searchbot($rest, $server); }
    elsif ($sub eq 'searchbot-list') { cmd_searchbot_list($rest); }
    elsif ($sub eq 'searchbot-preview') { cmd_searchbot_preview($rest); }
    elsif ($sub eq 'searchbot-get') { cmd_searchbot_get($rest, $server); }
    elsif ($sub eq 'searchbot-cancel') { abort_searchbot_collection(0); }
    elsif ($sub eq 'manifest-candidates') { cmd_manifest_candidates(); }
    elsif ($sub eq 'manifest-import') { cmd_manifest_import($rest); }
    elsif ($sub eq 'manifest-cancel') { cmd_manifest_cancel($rest); }
    elsif ($sub eq 'manifest-routes') { cmd_manifest_routes(); }
    elsif ($sub eq 'manifest-gc') { cmd_manifest_gc($rest); }
    elsif ($sub eq 'manifest-search') { cmd_manifest_search($rest); }
    elsif ($sub eq 'manifest-prefix') { cmd_manifest_prefix($rest); }
    elsif ($sub eq 'manifest-parent') { cmd_manifest_parent($rest); }
    elsif ($sub eq 'manifest-exact') { cmd_manifest_exact($rest); }
    elsif ($sub eq 'manifest-next') { cmd_manifest_next(); }
    elsif ($sub eq 'manifest-get') { cmd_manifest_get($rest, $server); }
    elsif ($sub eq 'catalog') { cmd_catalog($rest); }
    elsif ($sub eq 'journal-compact') { cmd_journal_compact(); }
    elsif ($sub eq 'queue-add') { queue_add($rest, $server); }
    elsif ($sub eq 'queue-list') { cmd_queue_list(); }
    elsif ($sub eq 'queue-run') { cmd_queue_run($rest, $server); }
    elsif ($sub eq 'queue-pause') { cmd_queue_pause(); }
    elsif ($sub eq 'queue-cancel') { cmd_queue_cancel($rest); }
    elsif ($sub eq 'job-show') { cmd_job_show($rest); }
    elsif ($sub eq 'job-retry') { cmd_job_retry($rest); }
    elsif ($sub eq 'job-resume') { cmd_job_resume($rest); }
    elsif ($sub eq 'status')  { cmd_status(); }
    elsif ($sub eq 'stop')    { abort_searchbot_collection(1); stop_session(); }
    else {
        p('Commands:');
        p('/fscrawl start <nick> <Irssi trigger command>');
        p('/fscrawl status');
        p('/fscrawl list [text]');
        p('/fscrawl get <index>');
        p('/fscrawl fetch <find-result-index> [channel|ctcp]');
        p('/fscrawl find <channel> <search terms>');
        p('/fscrawl findlist [text]');
        p('/fscrawl searchbot <channel> <result-sender-nick> <search terms>');
        p('/fscrawl searchbot-list [text]');
        p('/fscrawl searchbot-preview <collection-id:row-number> [--sender <nick>]');
        p('/fscrawl searchbot-get <collection-id:row-number> --sender <content-nick>');
        p('/fscrawl searchbot-cancel');
        p('/fscrawl manifest-candidates');
        p('/fscrawl manifest-import <find-result-index> <local-file> [--root-profile=name]');
        p('/fscrawl manifest-cancel [job-id]');
        p('/fscrawl manifest-routes');
        p('/fscrawl manifest-gc [--retention-days=N] [--apply]');
        p('/fscrawl manifest-search [route-key] <filename substring, 3+ characters>');
        p('/fscrawl manifest-prefix [route-key] <filename prefix>');
        p('/fscrawl manifest-parent [route-key] [remote-parent-path]');
        p('/fscrawl manifest-exact [route-key] <remote-path>');
        p('/fscrawl manifest-next');
        p('/fscrawl manifest-get <page-index> [channel|ctcp]');
        p('/fscrawl catalog [path|server|trigger text]');
        p('/fscrawl journal-compact');
        p('/fscrawl queue-add <find|manifest|crawl|searchbot> <selection-token> [channel|ctcp|--sender <nick>]');
        p('/fscrawl queue-list');
        p('/fscrawl queue-run <job-id> [<job-id> ...]');
        p('/fscrawl queue-pause');
        p('/fscrawl queue-cancel <job-id>');
        p('/fscrawl job-show <job-id>');
        p('/fscrawl job-retry <job-id>');
        p('/fscrawl job-resume <job-id>');
        p('/fscrawl stop');
    }
}

1;
