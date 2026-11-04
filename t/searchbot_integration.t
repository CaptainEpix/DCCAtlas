use strict;
use warnings;

use FindBin qw($Bin);
use File::Find qw(find);
use File::Temp qw(tempdir);
use IO::Compress::Zip qw($ZipError ZIP_CM_STORE);
use JSON::PP qw(decode_json encode_json);
use Test::More;

use lib "$Bin/lib";
use lib "$Bin/../lib";

use Irssi;

my $temp = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $temp;
my $script = "$Bin/../engine/dccatlas.pl";
do $script or die "could not load $script: $@ $!";
my @later_dcc_request_handlers;
Irssi::signal_add('dcc request', sub { push @later_dcc_request_handlers, $_[0]; });
Irssi::settings_set_str('fscrawl_library_dir', "$Bin/../lib");
Irssi::settings_set_str('fscrawl_output_dir', "$temp/output");
Irssi::settings_set_str('fscrawl_download_dir', "$temp/downloads");
Irssi::settings_set_str('fscrawl_lists_dir', "$temp/lists");
Irssi::settings_set_str('dcc_download_path', "$temp/original-dcc-path");
@Irssi::GLOBAL_COMMANDS = ();
@Irssi::PRINTS = ();

sub make_zip {
    my ($row) = @_;
    my $bytes = '';
    my $zip = IO::Compress::Zip->new(\$bytes,
        Name => 'SearchBot_results.txt', Method => ZIP_CM_STORE)
        or die "could not create fixture ZIP: $ZipError";
    $zip->print($row) or die "could not write fixture ZIP: $ZipError";
    $zip->close or die "could not close fixture ZIP: $ZipError";
    return $bytes;
}

my $server = MockServer->new();
$server->{chatnet} = 'MockNet';
$server->{nick} = 'LocalUser';
$server->{joined_channels}{'#books'} = 1;

sub run_search {
    my ($query) = @_;
    Irssi::run_command('fscrawl', "searchbot #books Search $query", $server, undef);
}

sub run_search_on {
    my ($target_server, $sender, $query) = @_;
    Irssi::run_command('fscrawl', "searchbot #books $sender $query", $target_server, undef);
}

sub new_result_offer {
    my ($nick, $tag, $filename, $bytes, $offer_server) = @_;
    my %identity = Irssi::new_dcc_identity();
    return bless {
        type      => 'GET',
        nick      => $nick,
        servertag => $tag,
        arg       => $filename,
        size      => length($bytes),
        transfd   => 0,
        server    => ($offer_server || $server),
        %identity,
    }, 'MockDcc';
}

sub drain_parse_steps {
    my $guard = 0;
    while (1) {
        my ($handle) = grep {
            my $timer = Irssi::timer_record($_);
            $timer && $timer->[5] == 10;
        } Irssi::timer_handles();
        last unless defined $handle;
        die 'too many cooperative archive steps' if ++$guard > 100000;
        Irssi::fire_timer($handle);
    }
}

sub current_selection_id {
    my ($id) = join("\n", @Irssi::PRINTS) =~
        /(searchbot-[1-9][0-9]*-[a-f0-9]{32}:[1-9][0-9]*)/i;
    return $id;
}

sub latest_job_for_partial_name {
    my ($offered_name) = @_;
    local $/ = "\n";
    open my $fh, '<', "$temp/fserve-poc/phase6/requests.jsonl"
        or die "could not read Phase 6 journal: $!";
    my $found;
    while (my $line = <$fh>) {
        my $record = eval { decode_json($line) };
        die "invalid Phase 6 journal row [$@]: " . substr($line, 0, 1100)
            unless ref($record) eq 'HASH';
        my $job = $record->{data}{job};
        $found = $job if $job && ref($job->{partial}) eq 'HASH' &&
            ($job->{partial}{offered_basename} // '') eq $offered_name;
    }
    close $fh;
    return $found;
}

sub latest_job_for_exact_payload {
    my ($payload) = @_;
    local $/ = "\n";
    open my $fh, '<', "$temp/fserve-poc/phase6/requests.jsonl"
        or die "could not read Phase 6 journal: $!";
    my $found;
    while (my $line = <$fh>) {
        my $record = eval { decode_json($line) };
        die "invalid Phase 6 journal row [$@]" unless ref($record) eq 'HASH';
        my $job = $record->{data}{job};
        $found = $job if $job && $job->{provider} eq 'searchbot' &&
            ($job->{selection}{exact_payload} // '') eq $payload;
    }
    close $fh;
    return $found;
}

sub count_job_state_transitions {
    my ($job_id, $state) = @_;
    local $/ = "\n";
    open my $fh, '<', "$temp/fserve-poc/phase6/requests.jsonl"
        or die "could not read Phase 6 journal: $!";
    my $count = 0;
    while (my $line = <$fh>) {
        my $record = decode_json($line);
        my $job = $record->{data}{job};
        $count++ if $record->{event} eq 'job_transition' && $job &&
            $job->{id} eq $job_id && $job->{state} eq $state;
    }
    close $fh;
    return $count;
}

sub receive_interrupted_direct_fixture {
    my (%args) = @_;
    my $selection = complete_query($args{query}, "!$args{nick} $args{name}\n");
    Irssi::run_command('fscrawl', "searchbot-get $selection --sender $args{nick}", $server, undef);
    my $stage = Irssi::settings_get_str('dcc_download_path');
    my $bytes = 'received-prefix';
    my $dcc = new_result_offer($args{nick}, 'mocknet', $args{name}, 'x' x 100);
    Irssi::emit('dcc request', $dcc);
    my $path = "$stage/$args{name}";
    $dcc->{file} = $path;
    open my $fh, '>:raw', $path or die "could not create partial fixture: $!";
    print {$fh} $bytes or die "could not write partial fixture: $!";
    close $fh or die "could not close partial fixture: $!";
    my @received_stat = stat($path);
    $dcc->{transfd} = length($bytes);
    Irssi::emit('dcc get receive', $dcc);
    if ($args{replace}) {
        rename($path, "$path.original") or die "could not preserve original partial: $!";
        open my $replacement, '>:raw', $path or die "could not create replacement partial: $!";
        print {$replacement} ('R' x length($bytes))
            or die "could not write replacement partial: $!";
        close $replacement or die "could not close replacement partial: $!";
        my @replacement_stat = stat($path);
        isnt $replacement_stat[1], $received_stat[1],
            "$args{name} fixture uses a replacement inode";
        Irssi::emit('dcc get receive', $dcc) if $args{invalidate};
    }
    Irssi::emit('dcc closed', $dcc);
    my $job = latest_job_for_partial_name($args{name});
    ok $job, "$args{name} interrupted transfer is journaled";
    return ($job, \@received_stat);
}

sub complete_query {
    my ($query, $row) = @_;
    run_search($query);
    my $name = FServe::Discovery::SearchBotOffer::expected_archive_filename($query);
    my $bytes = make_zip($row);
    my $dcc = new_result_offer('Search', 'mocknet', $name, $bytes);
    Irssi::emit('dcc request', $dcc);
    die 'query fixture offer was not accepted' if $dcc->{destroyed};
    my $path = Irssi::settings_get_str('dcc_download_path') . "/$name";
    open my $fh, '>:raw', $path or die "could not write result fixture: $!";
    print {$fh} $bytes or die "could not write result fixture: $!";
    close $fh or die "could not close result fixture: $!";
    $dcc->{file} = $path;
    $dcc->{transfd} = length($bytes);
    Irssi::emit('dcc get receive', $dcc);
    Irssi::emit('dcc closed', $dcc);
    drain_parse_steps();
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
    return current_selection_id();
}

Irssi::settings_set_bool('dcc_autoget', 1);
my $autoget_commands_before = scalar @{$server->{commands}};
my $autoget_path_before = Irssi::settings_get_str('dcc_download_path');
run_search('Must refuse while auto-accept is enabled');
is scalar(@{$server->{commands}}), $autoget_commands_before,
    'boolean DCC auto-accept setting blocks SearchBot query dispatch';
is Irssi::settings_get_str('dcc_download_path'), $autoget_path_before,
    'auto-accept refusal does not change the DCC download path';
like join("\n", @Irssi::PRINTS), qr/Disable Irssi DCC auto-accept/,
    'auto-accept refusal explains the setting requirement';
Irssi::settings_set_bool('dcc_autoget', 0);

run_search('Jane Example');
is $server->{commands}[-1], 'MSG #books @search Jane Example',
    'query is sent once as plain trailing IRC text without literal quotes';
like join("\n", @Irssi::PRINTS), qr/expecting one ZIP from Search named SearchBot_results_for__Jane_Example\.txt\.zip/,
    'query is bound to the configured sender and observed result filename';

my $bad_offer = new_result_offer('SomeoneElse', 'mocknet',
    'SearchBot_results_for__Jane_Example.txt.zip', make_zip("!BookBot Example.epub ::INFO:: 10 KB\n"));
Irssi::emit('dcc request', $bad_offer);
ok !$bad_offer->{destroyed}, 'unrelated DCC offer is not taken over or closed';
unlike join(' ', @{$server->{commands}}), qr/DCC GET/,
    'unrelated offer does not trigger DCC GET';

my $wrong_name = new_result_offer('Search', 'mocknet',
    'SearchBot_results_for__Other.txt.zip', make_zip("!BookBot Example.epub ::INFO:: 10 KB\n"));
my $later_handlers_before_wrong_name = scalar @later_dcc_request_handlers;
Irssi::emit('dcc request', $wrong_name);
ok $wrong_name->{destroyed}, 'wrong-name offer from the configured sender is closed locally';
is scalar(@later_dcc_request_handlers), $later_handlers_before_wrong_name,
    'archive rejection stops later handlers from seeing the destroyed DCC request';
my $fallback_archive_name = 'SearchBot_results_for__Fallback_archive.txt.zip';
my $fallback_archive = new_result_offer('Search', 'mocknet',
    $fallback_archive_name, make_zip("!BookBot Example.epub ::INFO:: 10 KB\n"));
my $fallback_archive_commands_before = scalar @{$server->{commands}};
my $later_handlers_before_fallback_archive = scalar @later_dcc_request_handlers;
{
    no warnings qw(redefine once);
    local *MockDcc::destroy = sub {
        my ($self) = @_;
        delete @{$self}{qw(arg nick server)};
        die 'injected archive DCC destroy failure';
    };
    Irssi::emit('dcc request', $fallback_archive);
}
is $server->{commands}[-1], 'DCC CLOSE GET Search "' . $fallback_archive_name . '"',
    'archive fallback close uses offer fields captured before the DCC destroy attempt';
is scalar(@{$server->{commands}}), $fallback_archive_commands_before + 1,
    'archive rejection fallback closes exactly one DCC GET';
is scalar(@later_dcc_request_handlers), $later_handlers_before_fallback_archive,
    'archive fallback close also stops later DCC request handlers';

my $first_zip_bytes = make_zip("!BookBot Example.epub ::INFO:: 10 KB\n");
my $first_offer = new_result_offer('Search', 'mocknet',
    'SearchBot_results_for__Jane_Example.txt.zip', $first_zip_bytes);
Irssi::emit('dcc request', $first_offer);
is $server->{commands}[-1], 'DCC GET Search "SearchBot_results_for__Jane_Example.txt.zip"',
    'the current query accepts only its exact result ZIP';
my $first_stage = Irssi::settings_get_str('dcc_download_path');
my $first_received = "$first_stage/SearchBot_results_for__Jane_Example.txt.zip";
open my $first_fh, '>:raw', $first_received or die "could not write first DCC payload: $!";
print {$first_fh} $first_zip_bytes or die "could not write first DCC payload: $!";
close $first_fh or die "could not close first DCC payload: $!";
$first_offer->{file} = $first_received;
$first_offer->{transfd} = length($first_zip_bytes);
Irssi::emit('dcc get receive', $first_offer);
Irssi::emit('dcc closed', $first_offer);
drain_parse_steps();
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
my $first_selection_id = current_selection_id();
ok $first_selection_id, 'completed result rows display a collection-bound selection ID';
my $late_first_offer = new_result_offer('Search', 'mocknet',
    'SearchBot_results_for__Jane_Example.txt.zip', $first_zip_bytes);
my $later_handlers_before_late_archive = scalar @later_dcc_request_handlers;
Irssi::emit('dcc request', $late_first_offer);
ok $late_first_offer->{destroyed},
    'a late offer for a completed SearchBot query is closed when no collection is active';
is scalar(@later_dcc_request_handlers), $later_handlers_before_late_archive,
    'stale archive rejection stops propagation of the destroyed DCC request';
my $unrelated_from_sender = new_result_offer('Search', 'mocknet',
    'Unrelated.zip', $first_zip_bytes);
Irssi::emit('dcc request', $unrelated_from_sender);
ok !$unrelated_from_sender->{destroyed},
    'stale-offer protection does not close unrelated filenames from the same nick';

# A repeated sanitized basename is refused during this script session because
# DCC SEND has no nonce with which to disambiguate a late same-name offer.
my $before_repeat = scalar @{$server->{commands}};
run_search('Jane Example!');
is scalar(@{$server->{commands}}), $before_repeat,
    'a colliding sanitized result filename is not reused in the same script session';
like join("\n", @Irssi::PRINTS), qr/reusing it could accept a stale same-name offer/,
    'the no-nonce stale-offer limitation is surfaced to the user';

# Starting a newer collection after completion invalidates the prior rows and IDs.
run_search('Another title');
is $server->{commands}[-1], 'MSG #books @search Another title',
    'a later serialized query can start after the prior collection completes';
my $late_wrong_collection = new_result_offer('Search', 'mocknet',
    'SearchBot_results_for__Jane_Example.txt.zip', $first_zip_bytes);
Irssi::emit('dcc request', $late_wrong_collection);
ok $late_wrong_collection->{destroyed},
    'an old result basename is refused while a different query is active';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-get $first_selection_id --sender BookBot", $server, undef);
like join("\n", @Irssi::PRINTS), qr/incomplete, stale, or unavailable/,
    'a row from the superseded collection cannot be selected';
unlike join(' ', @{$server->{commands}}), qr/MSG #books !BookBot/,
    'stale selection sends no FServe trigger';

my $zip_bytes = make_zip("!BookBot Example.epub ::INFO:: 10 KB\n");
my $expected_name = 'SearchBot_results_for__Another_title.txt.zip';
my $offer = new_result_offer('Search', 'mocknet', $expected_name, $zip_bytes);
Irssi::emit('dcc request', $offer);
is $server->{commands}[-1], 'DCC GET Search "' . $expected_name . '"',
    'only the exact sender/server/name offer is accepted';
is Irssi::settings_get_str('dcc_download_path') =~ /\.incoming/ ? 1 : 0, 1,
    'the result ZIP is directed into request-specific staging';

my $staging = Irssi::settings_get_str('dcc_download_path');
my $received_path = "$staging/$expected_name";
open my $fh, '>:raw', $received_path or die "could not write mock DCC payload: $!";
print {$fh} $zip_bytes or die "could not write mock DCC payload: $!";
close $fh or die "could not close mock DCC payload: $!";
$offer->{file} = $received_path;
$offer->{transfd} = length($zip_bytes);
Irssi::emit('dcc get receive', $offer);
Irssi::emit('dcc closed', $offer);
drain_parse_steps();

like join("\n", @Irssi::PRINTS), qr/result collection complete: 1 candidate/,
    'fully received and checksum-validated archive publishes one candidate';
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'download-path setting is restored after result processing';
my @result_archives;
find(sub {
    push @result_archives, $File::Find::name
        if -f $_ && $_ eq $expected_name;
}, "$temp/lists");
is scalar @result_archives, 1, 'validated ZIP is retained outside the staging directory';
my @in_downloads;
find(sub { push @in_downloads, $File::Find::name if -f $_ && $_ eq $expected_name },
    "$temp/downloads") if -d "$temp/downloads";
is scalar @in_downloads, 0, 'in the lists folder, not with the downloads';
unlike $result_archives[0] // '', qr/\.incoming[\\\/]/,
    'retained result archive is not left in the temporary staging tree';

@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
like join("\n", @Irssi::PRINTS), qr/Example\.epub/,
    'completed rows appear only through the SearchBot result list';
my $second_selection_id = current_selection_id();
ok $second_selection_id && $second_selection_id ne $first_selection_id,
    'a newer collection displays a distinct selection ID';

# Queue execution is exercised entirely against the mock IRC/DCC endpoints.
# The content sender is explicit and is not inferred from the !BookBot trigger.
@Irssi::PRINTS = ();
my $queued_raw_before = scalar @{$server->{raw_lines}};
Irssi::run_command('fscrawl', "queue-add searchbot $second_selection_id --sender QueueBot", $server, undef);
my ($queued_job_id) = join("\n", @Irssi::PRINTS) =~ /(job-[a-f0-9]{32})/;
ok $queued_job_id, 'queue-add creates an opaque held SearchBot job';
is scalar(@{$server->{raw_lines}}), $queued_raw_before,
    'adding an exact SearchBot selection to the local queue emits no IRC message';
like join("\n", @Irssi::PRINTS), qr/queue-add sent no network traffic/,
    'queue-add reports its local-only behavior';

@Irssi::PRINTS = ();
my $queued_row = '!BookBot Example.epub ::INFO:: 10 KB';
Irssi::run_command('fscrawl', "queue-run $queued_job_id", $server, undef);
is $server->{raw_lines}[-1], "PRIVMSG #books :$queued_row",
    'queue-run sends the exact frozen result row once through the SearchBot adapter';
like join("\n", @Irssi::PRINTS), qr/Captured a finite 1-job set/,
    'queue-run snapshots a finite explicit job set';
Irssi::run_command('fscrawl', "job-show $queued_job_id", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=awaiting_offer/,
    'queued SearchBot dispatch is durably visible as awaiting_offer';

my $queued_collection_id = $second_selection_id;
$queued_collection_id =~ s/:\d+\z//;
my $queued_stage = Irssi::settings_get_str('dcc_download_path');
my $queued_bytes = "queued synthetic bytes\x00for SearchBot\n";
my $queued_offer = new_result_offer('QueueBot', 'mocknet', 'Example.epub',
    $queued_bytes, $server->new_wrapper());
Irssi::emit('dcc request', $queued_offer);
is $server->{commands}[-1], 'DCC GET QueueBot "Example.epub"',
    'the queued job accepts only the explicit sender and expected basename';
my $queued_source = "$queued_stage/Example.epub";
$queued_offer->{file} = $queued_source;
Irssi::emit('dcc get receive', $queued_offer);
open my $queued_fh, '>:raw', $queued_source or die "could not create queued receive fixture: $!";
print {$queued_fh} $queued_bytes or die "could not write queued receive fixture: $!";
close $queued_fh or die "could not close queued receive fixture: $!";
$queued_offer->{transfd} = length($queued_bytes);
Irssi::emit('dcc closed', $queued_offer);
my $queued_destination = "$temp/downloads/MockNet/QueueBot/SearchBot/$queued_collection_id/Example.epub";
ok -f $queued_destination, 'queued synthetic DCC bytes pass through the existing validated finalizer';
open my $queued_saved_fh, '<:raw', $queued_destination or die "could not read queued finalized fixture: $!";
local $/;
is <$queued_saved_fh>, $queued_bytes, 'queued transfer publishes the exact fixture bytes';
close $queued_saved_fh;

# Irssi rejects timer intervals below 10 ms. Positive scheduler deadlines must
# round upward and use that minimum; zero may dispatch immediately.
is Irssi::Script::dccatlas::timer_delay_ms(0), 0,
    'zero scheduler delay does not create a timer';
is Irssi::Script::dccatlas::timer_delay_ms(0.0001), 10,
    'positive sub-millisecond delay rounds up to Irssi minimum';
is Irssi::Script::dccatlas::timer_delay_ms(0.009999), 10,
    'positive delay below 10 ms uses Irssi minimum';
is Irssi::Script::dccatlas::timer_delay_ms(0.010001), 11,
    'positive delay above 10 ms rounds upward';

# Verify a batch snapshots only its explicit IDs and routes later dispatches
# through the injected scheduler clock without real sleeping.
my $batch_rows = "!BookBot FirstQueued.epub ::INFO:: 10 KB\n" .
    "!BookBot SecondQueued.epub ::INFO:: 10 KB\n" .
    "!BookBot AddedLater.epub ::INFO:: 10 KB\n";
my $batch_first_selection = complete_query('Queue finite batch', $batch_rows);
my @batch_selections = join("\n", @Irssi::PRINTS) =~
    /(searchbot-[1-9][0-9]*-[a-f0-9]{32}:[1-9][0-9]*)/g;
is scalar(@batch_selections), 3, 'three exact rows are exposed for a finite queue-batch fixture';
my @batch_job_ids;
for my $selection (@batch_selections[0, 1]) {
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', "queue-add searchbot $selection --sender BookBot", $server, undef);
    my ($id) = join("\n", @Irssi::PRINTS) =~ /(job-[a-f0-9]{32})/;
    push @batch_job_ids, $id if $id;
}
is scalar(@batch_job_ids), 2, 'two selected rows create two distinct held jobs';
@Irssi::PRINTS = ();
{
    no warnings qw(redefine once);
    local $Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
    local *FServe::Transfer::Scheduler::_interval_for = sub { return 0 };
    my $actual_scheduler_reserve = \&FServe::Transfer::Scheduler::reserve;
    my $scheduler_reserve_calls = 0;
    local *FServe::Transfer::Scheduler::reserve = sub {
        my ($scheduler, %args) = @_;
        my $reservation = $actual_scheduler_reserve->($scheduler, %args);
        $reservation->{delay} = 0.005 if ++$scheduler_reserve_calls == 1;
        return $reservation;
    };
    my $actual_scheduler_commit = \&FServe::Transfer::Scheduler::commit;
    my $scheduler_commit_calls = 0;
    local *FServe::Transfer::Scheduler::commit = sub {
        my ($scheduler, $token) = @_;
        return { committed => 0, token => $token, delay => 0.005 }
            if ++$scheduler_commit_calls == 1;
        return $actual_scheduler_commit->($scheduler, $token);
    };
    my $first_dispatch_raw_count = scalar @{$server->{raw_lines}};
    Irssi::run_command('fscrawl', 'queue-run ' . join(' ', @batch_job_ids), $server, undef);
    is scalar(@{$server->{raw_lines}}), $first_dispatch_raw_count,
        'late scheduler commit defers the selected request';
    my @initial_handles = Irssi::timer_handles();
    my $initial_handle = $initial_handles[-1];
    ok defined($initial_handle), 'short initial reservation registers a timer';
    is Irssi::timer_record($initial_handle)->[5], 10,
        '5 ms initial reservation is scheduled at Irssi minimum';
    ok Irssi::fire_timer($initial_handle), 'initial scheduler callback runs';
    is scalar(@{$server->{raw_lines}}), $first_dispatch_raw_count,
        'deferred scheduler commit still sends nothing before its retry';
    my @retry_handles = Irssi::timer_handles();
    my $retry_handle = $retry_handles[-1];
    ok defined($retry_handle), 'late scheduler commit registers a retry timer';
    is Irssi::timer_record($retry_handle)->[5], 10,
        '5 ms retry is scheduled at Irssi minimum';
    ok Irssi::fire_timer($retry_handle), 'named scheduler callback runs on retry';
    is $server->{raw_lines}[-1], 'PRIVMSG #books :!BookBot FirstQueued.epub ::INFO:: 10 KB',
        'retry dispatches the oldest exact queued row once after scheduler commit';
    my $later_raw_before = scalar @{$server->{raw_lines}};
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', "queue-add searchbot $batch_selections[2] --sender BookBot", $server, undef);
    my ($later_job_id) = join("\n", @Irssi::PRINTS) =~ /(job-[a-f0-9]{32})/;
    ok $later_job_id, 'queue additions remain available while a run is active';
    is scalar(@{$server->{raw_lines}}), $later_raw_before,
        'adding a later job during an active run sends no network message';

    my $first_batch_stage = Irssi::settings_get_str('dcc_download_path');
    my $first_batch_bytes = 'first finite batch fixture';
    my $first_batch_offer = new_result_offer('BookBot', 'mocknet', 'FirstQueued.epub',
        $first_batch_bytes, $server->new_wrapper());
    Irssi::emit('dcc request', $first_batch_offer);
    my $first_batch_source = "$first_batch_stage/FirstQueued.epub";
    $first_batch_offer->{file} = $first_batch_source;
    Irssi::emit('dcc get receive', $first_batch_offer);
    open my $first_batch_fh, '>:raw', $first_batch_source or die "create first batch fixture: $!";
    print {$first_batch_fh} $first_batch_bytes or die "write first batch fixture: $!";
    close $first_batch_fh or die "close first batch fixture: $!";
    $first_batch_offer->{transfd} = length($first_batch_bytes);
    Irssi::emit('dcc closed', $first_batch_offer);
    my ($advance_handle) = grep {
        my $timer = Irssi::timer_record($_);
        $timer && $timer->[5] == 10;
    } Irssi::timer_handles();
    ok defined($advance_handle), 'first completed job schedules the next job asynchronously';
    Irssi::fire_timer($advance_handle);
    is scalar(@{$server->{raw_lines}}), $later_raw_before,
        'the same-route second job waits behind its 30-second cooldown';
    my ($route_timer) = grep {
        my $timer = Irssi::timer_record($_);
        $timer && $timer->[5] >= 29_000;
    } Irssi::timer_handles();
    ok defined($route_timer), 'route cooldown is an absolute cancellable timer';
    Irssi::run_command('fscrawl', 'queue-pause', $server, undef);
    my $route_timer_still_scheduled = grep { $_ == $route_timer } Irssi::timer_handles();
    ok !$route_timer_still_scheduled,
        'queue-pause cancels the not-yet-dispatched pacing callback';
    my $set_replacement_raw_count = scalar @{$server->{raw_lines}};
    Irssi::run_command('fscrawl', 'queue-run ' . join(' ', @batch_job_ids, $later_job_id), $server, undef);
    is scalar(@{$server->{raw_lines}}), $set_replacement_raw_count,
        'an active paused finite set cannot be expanded by a later queue addition';
    Irssi::run_command('fscrawl', "queue-cancel $batch_job_ids[1]", $server, undef);
    Irssi::run_command('fscrawl', 'queue-run ' . join(' ', @batch_job_ids), $server, undef);
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', "job-show $later_job_id", $server, undef);
    like join("\n", @Irssi::PRINTS), qr/state=held/,
        'a job added after queue-run began remains held outside the finite run set';
}

@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-get $first_selection_id --sender BookBot", $server, undef);
like join("\n", @Irssi::PRINTS), qr/older or different collection/,
    'an old displayed selection is refused after the newer collection completes';

@Irssi::PRINTS = ();
my $example_row = '!BookBot Example.epub ::INFO:: 10 KB';
my $example_selection = complete_query('Another title fresh', "$example_row\n");
ok $example_selection, 'current result selection is available for direct request';
@Irssi::PRINTS = ();
my $raw_count_before_preview = scalar @{$server->{raw_lines}};
Irssi::run_command('fscrawl', "searchbot-preview $example_selection --sender BookBot", $server, undef);
like join("\n", @Irssi::PRINTS), qr/outgoing channel text: \Q$example_row\E/,
    'preview shows the exact full outgoing result line';
is scalar(@{$server->{raw_lines}}), $raw_count_before_preview,
    'preview is local and emits no IRC traffic';

@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-get $example_selection", $server, undef);
like join("\n", @Irssi::PRINTS), qr/--sender <nick>/,
    'content sender is mandatory and missing sender emits no request';
is scalar(@{$server->{raw_lines}}), $raw_count_before_preview,
    'missing sender cannot produce a channel message';

@Irssi::PRINTS = ();
my $catalog_lookup_was_called = 0;
Irssi::settings_set_bool('dcc_autoget', 1);
my $direct_autoget_raw_count = scalar @{$server->{raw_lines}};
my $direct_autoget_path = Irssi::settings_get_str('dcc_download_path');
Irssi::run_command('fscrawl', "searchbot-get $example_selection --sender BookBot", $server, undef);
like join("\n", @Irssi::PRINTS), qr/Disable Irssi DCC auto-accept/,
    'direct content request refuses when native DCC auto-accept is on';
is scalar(@{$server->{raw_lines}}), $direct_autoget_raw_count,
    'auto-accept refusal sends no SearchBot result row';
is Irssi::settings_get_str('dcc_download_path'), $direct_autoget_path,
    'auto-accept refusal does not reserve or change the download path';
Irssi::settings_set_bool('dcc_autoget', 0);
@Irssi::PRINTS = ();
{
    no warnings qw(redefine once);
    local *Irssi::Script::dccatlas::load_catalog_module = sub {
        $catalog_lookup_was_called++;
        die 'direct SearchBot path must not load the catalog';
    };
    my $wrapper_for_get = $server->new_wrapper();
    Irssi::run_command('fscrawl', "searchbot-get $example_selection --sender BookBot", $wrapper_for_get, undef);
}
is $catalog_lookup_was_called, 0, 'direct request has no local catalog/path prerequisite';
is $server->{raw_lines}[-1], "PRIVMSG #books :$example_row",
    'exact original result row is sent once as the channel trailing payload';
like join(' ', @{$server->{commands}}), qr/DCC GET Search "/,
    'only result ZIP intake used DCC GET before the content offer';
unlike join(' ', @{$server->{commands}}), qr/DCC CHAT|MSG #books !BookBot/,
    'direct SearchBot retrieval does not start CHAT or a reconstructed trigger';
is Irssi::settings_get_str('dcc_download_path') =~ /\.incoming/ ? 1 : 0, 1,
    'pending direct request reserves request-specific staging before the offer';

my $content_stage = Irssi::settings_get_str('dcc_download_path');
my $content_filename = 'Example.epub';
my $content_bytes = "synthetic content fixture\x00with bytes\n";
my $wrong_sender = new_result_offer('SomeoneElse', 'mocknet', $content_filename, $content_bytes);
my $later_handlers_before_wrong_sender = scalar @later_dcc_request_handlers;
Irssi::emit('dcc request', $wrong_sender);
ok $wrong_sender->{destroyed}, 'wrong content sender is refused locally';
is scalar(@later_dcc_request_handlers), $later_handlers_before_wrong_sender,
    'content rejection stops later handlers from seeing the destroyed DCC request';
is Irssi::settings_get_str('dcc_download_path'), $content_stage,
    'wrong sender does not consume or release the pending request';
my $fallback_content = new_result_offer('SomeoneElse', 'mocknet', $content_filename, $content_bytes);
my $fallback_content_commands_before = scalar @{$server->{commands}};
my $later_handlers_before_fallback_content = scalar @later_dcc_request_handlers;
{
    no warnings qw(redefine once);
    local *MockDcc::destroy = sub {
        my ($self) = @_;
        delete @{$self}{qw(arg nick server)};
        die 'injected content DCC destroy failure';
    };
    Irssi::emit('dcc request', $fallback_content);
}
is $server->{commands}[-1], 'DCC CLOSE GET SomeoneElse "' . $content_filename . '"',
    'content fallback close uses offer fields captured before the DCC destroy attempt';
is scalar(@{$server->{commands}}), $fallback_content_commands_before + 1,
    'content rejection fallback closes exactly one DCC GET';
is scalar(@later_dcc_request_handlers), $later_handlers_before_fallback_content,
    'content fallback close also stops later DCC request handlers';
my $wrong_filename = new_result_offer('BookBot', 'mocknet', 'Different.epub', $content_bytes);
Irssi::emit('dcc request', $wrong_filename);
ok $wrong_filename->{destroyed}, 'wrong content filename is refused locally';
my $oversized_offer = new_result_offer('BookBot', 'mocknet', $content_filename, $content_bytes);
$oversized_offer->{size} = 268435457;
Irssi::emit('dcc request', $oversized_offer);
ok $oversized_offer->{destroyed}, 'content offer above the 256 MiB default cap is refused';

my $content_offer = new_result_offer('BookBot', 'mocknet', $content_filename,
    $content_bytes, $server->new_wrapper());
Irssi::emit('dcc request', $content_offer);
is $server->{commands}[-1], 'DCC GET BookBot "Example.epub"',
    'exact peer/name offer is accepted directly without DCC CHAT';
my $content_source = "$content_stage/$content_filename";
$content_offer->{file} = $content_source;
Irssi::emit('dcc get receive', $content_offer);
unlike join("\n", @Irssi::PRINTS), qr/CONTENT_SOURCE_REFUSED/,
    'native DCC receive callback may precede creation of its destination file';
open my $content_fh, '>:raw', $content_source or die "could not write content fixture: $!";
print {$content_fh} $content_bytes or die "could not write content fixture: $!";
close $content_fh or die "could not close content fixture: $!";
$content_offer->{transfd} = length($content_bytes);
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'original DCC download path is restored when the accepted transfer selects its staged file';
Irssi::emit('dcc closed', $content_offer);
my $direct_collection_id = $example_selection;
$direct_collection_id =~ s/:\d+\z//;
my $content_destination = "$temp/downloads/MockNet/BookBot/SearchBot/$direct_collection_id/$content_filename";
ok -f $content_destination, 'verified direct-send bytes finalize into the SearchBot namespace';
open my $saved_content_fh, '<:raw', $content_destination or die "could not read saved fixture: $!";
local $/;
is <$saved_content_fh>, $content_bytes, 'finalized file is byte-for-byte the synthetic DCC fixture';
close $saved_content_fh;
like join("\n", @Irssi::PRINTS), qr/local SHA-256 [0-9a-f]{64}/,
    'completion reports a locally computed hash without treating SearchBot hash metadata as authoritative';
my @direct_logs = glob "$temp/output/searchbot-direct-*.tsv";
ok @direct_logs, 'request evidence log was created before dispatch';
open my $direct_log_fh, '<', $direct_logs[-1] or die "could not read request log: $!";
my $direct_log = do { local $/; <$direct_log_fh> };
close $direct_log_fh;
like $direct_log, qr/REQUEST_DISPATCHED.*CONTENT_OFFER_ACCEPTED.*CONTENT_TRANSFER_COMPLETE/s,
    'request, offer, and completion evidence are correlated in order';

my ($stable_partial_job, $stable_partial_stat) = receive_interrupted_direct_fixture(
    query => 'Direct stable partial', nick => 'StablePartialBot', name => 'StablePartial.epub');
is $stable_partial_job->{partial}{ownership_status}, 'captured',
    'unchanged DCC receive keeps verified partial ownership';
is $stable_partial_job->{partial}{file_identity}{inode}, $stable_partial_stat->[1],
    'unchanged partial records the inode first observed during receive';

my ($replaced_partial_job, $replaced_partial_stat) = receive_interrupted_direct_fixture(
    query => 'Direct replaced partial', nick => 'ReplacedPartialBot',
    name => 'ReplacedPartial.epub', replace => 1);
is $replaced_partial_job->{partial}{ownership_status}, 'unverified',
    'replacement at the original receive path is refused as owned data';
is $replaced_partial_job->{partial}{receive_identity}{inode}, $replaced_partial_stat->[1],
    'replacement refusal preserves the original receive-time inode evidence';
ok !exists($replaced_partial_job->{partial}{file_identity}),
    'replacement inode is not stored as authoritative file ownership';

my ($invalidated_partial_job) = receive_interrupted_direct_fixture(
    query => 'Direct invalidated partial', nick => 'InvalidatedPartialBot',
    name => 'InvalidatedPartial.epub', replace => 1, invalidate => 1);
is $invalidated_partial_job->{partial}{ownership_status}, 'unverified',
    'a source already marked changed remains unverified at interruption';
like $invalidated_partial_job->{partial}{ownership_refusal}, qr/marked changed/,
    'journal records the sticky receive-source invalidation reason';

my $changed_path_selection = complete_query('Direct changed path', "!ChangedPathBot Changed.epub\n");
Irssi::run_command('fscrawl',
    "searchbot-get $changed_path_selection --sender ChangedPathBot", $server, undef);
my $changed_path_stage = Irssi::settings_get_str('dcc_download_path');
my $changed_path_bytes = 'original DCC bytes, exact size';
my $changed_path_offer = new_result_offer('ChangedPathBot', 'mocknet', 'Changed.epub', $changed_path_bytes);
Irssi::emit('dcc request', $changed_path_offer);
my $frozen_source = "$changed_path_stage/Changed.epub";
$changed_path_offer->{file} = $frozen_source;
Irssi::emit('dcc get receive', $changed_path_offer);
open my $frozen_fh, '>:raw', $frozen_source or die "could not create direct receive fixture [$frozen_source]: $!; prints=" . join(' | ', @Irssi::PRINTS);
print {$frozen_fh} $changed_path_bytes or die "could not write direct receive fixture: $!";
close $frozen_fh or die "could not close direct receive fixture: $!";
$changed_path_offer->{transfd} = length($changed_path_bytes);
Irssi::emit('dcc get receive', $changed_path_offer);
my $substitute_source = "$changed_path_stage/substituted.epub";
open my $substitute_fh, '>:raw', $substitute_source or die "could not create substituted fixture: $!";
print {$substitute_fh} ('X' x length($changed_path_bytes)) or die "could not write substituted fixture: $!";
close $substitute_fh or die "could not close substituted fixture: $!";
$changed_path_offer->{file} = $substitute_source;
Irssi::emit('dcc closed', $changed_path_offer);
my $changed_collection = $changed_path_selection;
$changed_collection =~ s/:\d+\z//;
my $changed_destination = "$temp/downloads/MockNet/ChangedPathBot/SearchBot/$changed_collection/Changed.epub";
ok !-f $changed_destination,
    'same-sized replacement staged path cannot be published as the selected transfer';
open my $frozen_check_fh, '<:raw', $frozen_source or die "could not read frozen receive fixture: $!";
is <$frozen_check_fh>, $changed_path_bytes,
    'changed close callback leaves the original receive file recoverable';
close $frozen_check_fh;
like join("\n", @Irssi::PRINTS), qr/CONTENT_SOURCE_CHANGED|not an exact regular file/,
    'changed staged source is logged and refused';

my $outside_selection = complete_query('Direct outside staging', "!OutsideBot Outside.epub\n");
Irssi::run_command('fscrawl',
    "searchbot-get $outside_selection --sender OutsideBot", $server, undef);
my $outside_dir = "$temp/outside-stage";
mkdir $outside_dir or die "could not create outside-stage fixture directory: $!";
my $outside_source = "$outside_dir/Outside.epub";
my $outside_bytes = 'outside bytes of the exact advertised size';
my $outside_offer = new_result_offer('OutsideBot', 'mocknet', 'Outside.epub', $outside_bytes);
Irssi::emit('dcc request', $outside_offer);
$outside_offer->{file} = $outside_source;
Irssi::emit('dcc get receive', $outside_offer);
open my $outside_fh, '>:raw', $outside_source or die "could not create outside-stage fixture: $!";
print {$outside_fh} $outside_bytes or die "could not write outside-stage fixture: $!";
close $outside_fh or die "could not close outside-stage fixture: $!";
$outside_offer->{transfd} = length($outside_bytes);
Irssi::emit('dcc closed', $outside_offer);
my $outside_collection = $outside_selection;
$outside_collection =~ s/:\d+\z//;
ok !-f "$temp/downloads/MockNet/OutsideBot/SearchBot/$outside_collection/Outside.epub",
    'an exact-sized file outside request staging is never published';
like join("\n", @Irssi::PRINTS), qr/not an exact regular file inside request staging/,
    'outside-staging receive target does not report success';
my @outside_logs = sort glob "$temp/output/searchbot-direct-*.tsv";
open my $outside_log_fh, '<', $outside_logs[-1] or die "could not read outside-stage evidence: $!";
my $outside_log = do { local $/; <$outside_log_fh> };
close $outside_log_fh;
like $outside_log, qr/CONTENT_FILE_REFUSED/,
    'outside-staging receive target refusal is written to request evidence';

my $symlink_selection = complete_query('Direct symlink staging', "!SymlinkBot Linked.epub\n");
Irssi::run_command('fscrawl',
    "searchbot-get $symlink_selection --sender SymlinkBot", $server, undef);
my $symlink_stage = Irssi::settings_get_str('dcc_download_path');
my $symlink_path = "$symlink_stage/Linked.epub";
my $symlink_target = "$outside_dir/Linked.epub";
my $symlink_bytes = 'symlink target bytes of exact size';
open my $symlink_target_fh, '>:raw', $symlink_target or die "could not create symlink target fixture: $!";
print {$symlink_target_fh} $symlink_bytes or die "could not write symlink target fixture: $!";
close $symlink_target_fh or die "could not close symlink target fixture: $!";
my $symlink_offer = new_result_offer('SymlinkBot', 'mocknet', 'Linked.epub', $symlink_bytes);
Irssi::emit('dcc request', $symlink_offer);
SKIP: {
    my $linked = symlink($symlink_target, $symlink_path);
    unless ($linked) {
        Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
        skip 'host does not permit symlink fixtures; the isolated Linux runtime covers this case', 4;
    }
    ok $linked, 'symlink fault fixture is created inside request staging';
    $symlink_offer->{file} = $symlink_path;
    $symlink_offer->{transfd} = length($symlink_bytes);
    Irssi::emit('dcc get receive', $symlink_offer);
    Irssi::emit('dcc closed', $symlink_offer);
    my $symlink_collection = $symlink_selection;
    $symlink_collection =~ s/:\d+\z//;
    ok !-f "$temp/downloads/MockNet/SymlinkBot/SearchBot/$symlink_collection/Linked.epub",
        'a staged symlink cannot publish bytes from outside the request directory';
    like join("\n", @Irssi::PRINTS), qr/not an exact regular file inside request staging/,
        'symlinked receive target does not report success';
    my @symlink_logs = sort glob "$temp/output/searchbot-direct-*.tsv";
    open my $symlink_log_fh, '<', $symlink_logs[-1] or die "could not read symlink evidence: $!";
    my $symlink_log = do { local $/; <$symlink_log_fh> };
    close $symlink_log_fh;
    like $symlink_log, qr/CONTENT_SOURCE_REFUSED|CONTENT_FILE_REFUSED/,
        'symlinked receive target refusal is written to request evidence';
}

my $alias_first_selection = complete_query('RFC alias first', "!AnyTrigger Shared.epub\n");
Irssi::run_command('fscrawl',
    "searchbot-get $alias_first_selection --sender Book[bot]", $server, undef);
Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
my $alias_second_selection = complete_query('RFC alias second', "!AnyTrigger Shared.epub\n");
my $alias_raw_before = scalar @{$server->{raw_lines}};
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl',
    "searchbot-get $alias_second_selection --sender Book{bot}", $server, undef);
is scalar(@{$server->{raw_lines}}), $alias_raw_before,
    'RFC1459-equivalent sender spelling cannot reuse a tombstoned content tuple';
like join("\n", @Irssi::PRINTS), qr/already used or overlaps/,
    'equivalent-nick stale tuple refusal is reported locally';

my $archive_collision_selection = complete_query('Archive content collision',
    "!Search SearchBot_results_for__Archive_content_collision.txt.zip ::INFO:: 10B\n");
my $archive_collision_before = scalar @{$server->{raw_lines}};
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl',
    "searchbot-get $archive_collision_selection --sender Search", $server, undef);
is scalar(@{$server->{raw_lines}}), $archive_collision_before,
    'a content request cannot reuse the current archive sender/name tuple';
like join("\n", @Irssi::PRINTS), qr/already used or overlaps/,
    'archive-to-content tuple overlap is refused locally';

my $content_collision_selection = complete_query('Content to archive collision',
    "!LaterBot SearchBot_results_for__Future_archive.txt.zip ::INFO:: 10B\n");
my $content_collision_before = scalar @{$server->{raw_lines}};
Irssi::run_command('fscrawl',
    "searchbot-get $content_collision_selection --sender LaterBot", $server, undef);
is scalar(@{$server->{raw_lines}}), $content_collision_before + 1,
    'the distinct content tuple can be reserved before its future archive query';
Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
my $archive_query_commands_before = scalar @{$server->{commands}};
@Irssi::PRINTS = ();
run_search_on($server, 'LaterBot', 'Future archive');
is scalar(@{$server->{commands}}), $archive_query_commands_before,
    'a later archive collection cannot reuse a content sender/name tombstone';
like join("\n", @Irssi::PRINTS), qr/already used/,
    'content-to-archive tuple overlap is refused locally';

my $case_upper_selection = complete_query('CaseProbe',
    "!CaseProbeBot Upper.epub\n");
my $case_upper_name = 'SearchBot_results_for__CaseProbe.txt.zip';
my $case_lower_selection = complete_query('caseprobe',
    "!CaseProbeBot Lower.epub\n");
my $case_lower_name = 'SearchBot_results_for__caseprobe.txt.zip';
is FServe::Discovery::SearchBotOffer::expected_archive_filename('CaseProbe'),
    $case_upper_name, 'upper-case archive basename is retained exactly';
is FServe::Discovery::SearchBotOffer::expected_archive_filename('caseprobe'),
    $case_lower_name, 'lower-case archive basename is a distinct exact tuple';
ok $case_upper_selection && $case_lower_selection,
    'case-distinct archive queries both complete successfully';

my $late_case_upper = new_result_offer('Search', 'mocknet',
    $case_upper_name, make_zip("!CaseProbeBot Upper.epub\n"));
my $late_archive_commands = scalar @{$server->{commands}};
Irssi::emit('dcc request', $late_case_upper);
ok $late_case_upper->{destroyed},
    'late offer for the first case-distinct archive remains tombstoned';
is scalar(@{$server->{commands}}), $late_archive_commands,
    'late case-distinct archive offer cannot start DCC GET';

my $case_content_selection = complete_query('Case probe content overlap',
    "!Search $case_upper_name ::INFO:: 10B\n");
my $case_content_requests = scalar @{$server->{raw_lines}};
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl',
    "searchbot-get $case_content_selection --sender Search", $server, undef);
is scalar(@{$server->{raw_lines}}), $case_content_requests,
    'case-only archive query cannot erase archive-to-content overlap protection';
like join("\n", @Irssi::PRINTS), qr/already used or overlaps/,
    'case-only archive/content tuple collision is refused locally';
my $late_case_content = new_result_offer('Search', 'mocknet',
    $case_upper_name, make_zip("!CaseProbeBot Stale.epub\n"));
my $late_content_commands = scalar @{$server->{commands}};
Irssi::emit('dcc request', $late_case_content);
ok $late_case_content->{destroyed},
    'old case-distinct archive cannot be accepted for a direct-content request';
is scalar(@{$server->{commands}}), $late_content_commands,
    'old case-distinct archive cannot start content DCC GET';

sub assert_archive_query_tuple_refused {
    my ($query, $label) = @_;
    my $commands_before = scalar @{$server->{commands}};
    @Irssi::PRINTS = ();
    run_search($query);
    is scalar(@{$server->{commands}}), $commands_before,
        "$label basename cannot be reused in this script session";
    like join("\n", @Irssi::PRINTS), qr/already used by an earlier query/,
        "$label reuse is refused before query dispatch";
    Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
}

assert_archive_query_tuple_refused('CaseProbe', 'upper-case archive');
assert_archive_query_tuple_refused('caseprobe', 'lower-case archive');

complete_query('reversecaseprobe', "!ReverseBot Lower.epub\n");
complete_query('ReverseCaseProbe', "!ReverseBot Upper.epub\n");
assert_archive_query_tuple_refused('reversecaseprobe', 'reverse lower-case archive');
assert_archive_query_tuple_refused('ReverseCaseProbe', 'reverse upper-case archive');

@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
Irssi::run_command('fscrawl', "searchbot-preview $example_selection", $server, undef);
like join("\n", @Irssi::PRINTS), qr/No completed SearchBot result matches/,
    'explicit cancellation invalidates even a completed result selection';

Irssi::run_command('fscrawl', 'stop', $server, undef);
run_search('Partial transfer');
my $partial_bytes = make_zip("!BookBot Example.epub ::INFO:: 10 KB\n");
my $partial_name = 'SearchBot_results_for__Partial_transfer.txt.zip';
my $partial_offer = new_result_offer('Search', 'mocknet', $partial_name, $partial_bytes);
Irssi::emit('dcc request', $partial_offer);
my $partial_stage = Irssi::settings_get_str('dcc_download_path');
my $partial_received = "$partial_stage/$partial_name";
open my $partial_fh, '>:raw', $partial_received or die "could not write partial DCC payload: $!";
print {$partial_fh} substr($partial_bytes, 0, 12) or die "could not write partial DCC payload: $!";
close $partial_fh or die "could not close partial DCC payload: $!";
$partial_offer->{file} = $partial_received;
$partial_offer->{transfd} = 12;
Irssi::emit('dcc get receive', $partial_offer);
Irssi::emit('dcc closed', $partial_offer);
like join("\n", @Irssi::PRINTS), qr/transfer was incomplete \(12\//,
    'a short result transfer is rejected without publishing candidates';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-get $second_selection_id --sender BookBot", $server, undef);
like join("\n", @Irssi::PRINTS), qr/incomplete, stale, or unavailable/,
    'no result index is available after an incomplete transfer';

run_search('Timeout query');
my @searchbot_timers = Irssi::timer_handles();
ok @searchbot_timers, 'active SearchBot query has a bounded response deadline';
Irssi::fire_timer($searchbot_timers[-1]);
like join("\n", @Irssi::PRINTS), qr/result window expired/,
    'expired query becomes inactive and restores its DCC path';
my $late_timeout_offer = new_result_offer('Search', 'mocknet',
    'SearchBot_results_for__Timeout_query.txt.zip', $partial_bytes);
Irssi::emit('dcc request', $late_timeout_offer);
ok $late_timeout_offer->{destroyed},
    'a result arriving after the query deadline is closed as stale';

my $other_server = bless {
    connected => 1,
    tag       => 'othernet',
    chatnet   => 'OtherNet',
    nick      => 'LocalUser',
    commands  => [],
}, 'MockServer';
run_search_on($other_server, 'SearchOok', 'Jane Example');
is $other_server->{commands}[-1], 'MSG #books @search Jane Example',
    'the same basename may be queried through a distinct configured sender/server tuple';
my $old_sender_offer = new_result_offer('Search', 'mocknet',
    'SearchBot_results_for__Jane_Example.txt.zip', $first_zip_bytes);
Irssi::emit('dcc request', $old_sender_offer);
ok $old_sender_offer->{destroyed},
    'a stale offer from a prior sender/server is rejected while another SearchBot query is active';
Irssi::run_command('fscrawl', 'searchbot-cancel', $other_server, undef);

run_search('Unconnected transfer');
my $unconnected_bytes = make_zip("!BookBot Example.epub\n");
my $unconnected_name = 'SearchBot_results_for__Unconnected_transfer.txt.zip';
my $unconnected_offer = new_result_offer('Search', 'mocknet',
    $unconnected_name, $unconnected_bytes);
Irssi::emit('dcc request', $unconnected_offer);
ok !$unconnected_offer->{destroyed},
    'an exact result offer is accepted before its DCC connection begins';
my @unconnected_timers = Irssi::timer_handles();
ok @unconnected_timers,
    'the transfer deadline is active while an accepted offer is not yet connected';
Irssi::fire_timer($unconnected_timers[-1]);
ok $unconnected_offer->{destroyed},
    'an accepted offer that never begins receiving is closed on timeout';
Irssi::emit('dcc get receive', $unconnected_offer);
Irssi::emit('dcc closed', $unconnected_offer);
ok !Irssi::Script::dccatlas::has_active_download_transfer(),
    'a successfully closed timed-out archive releases its exact transfer binding';
Irssi::run_command('fscrawl', 'status', $server, undef);
like join("\n", @Irssi::PRINTS), qr/searchbot_state=transfer_expired/,
    'late receive and close callbacks cannot revive the never-connected collection';

run_search('Slow transfer');
my $slow_bytes = make_zip("!BookBot Example.epub\n");
my $slow_name = 'SearchBot_results_for__Slow_transfer.txt.zip';
my $slow_offer = new_result_offer('Search', 'mocknet', $slow_name, $slow_bytes);
Irssi::emit('dcc request', $slow_offer);
my $slow_path = Irssi::settings_get_str('dcc_download_path') . "/$slow_name";
open my $slow_fh, '>:raw', $slow_path or die "could not create stalled receive file: $!";
close $slow_fh or die "could not close stalled receive file: $!";
$slow_offer->{file} = $slow_path;
Irssi::emit('dcc get receive', $slow_offer);
my @transfer_timers = Irssi::timer_handles();
ok @transfer_timers, 'accepting a result offer installs a transfer deadline';
Irssi::fire_timer($transfer_timers[-1]);
ok $slow_offer->{destroyed}, 'a stalled accepted DCC result transfer is closed on timeout';
like join("\n", @Irssi::PRINTS), qr/transfer exceeded its configured time limit/,
    'transfer expiry is reported and leaves no rows publishable';
Irssi::emit('dcc closed', $slow_offer);
ok !Irssi::Script::dccatlas::has_active_download_transfer(),
    'a timed-out received archive releases its transfer after confirmed closure';
my $slow_timeout_job = latest_job_for_partial_name($slow_name);
is $slow_timeout_job->{state}, 'interrupted',
    'received archive timeout is recorded as interrupted';
is $slow_timeout_job->{outcome}, 'transfer_expired',
    'received archive timeout keeps its expiry outcome';
ok $slow_timeout_job->{partial}{writer_closed},
    'received archive timeout records writer closure only after destruction';
Irssi::run_command('fscrawl', 'status', $server, undef);
like join("\n", @Irssi::PRINTS), qr/searchbot_state=transfer_expired/,
    'a late close callback cannot revive an expired result collection';

run_search('Parse cancellation');
my $many_headers = ("plain header data\n" x 5000) . "!BookBot Example.epub\n";
my $many_header_bytes = make_zip($many_headers);
my $many_header_name = 'SearchBot_results_for__Parse_cancellation.txt.zip';
my $many_header_offer = new_result_offer('Search', 'mocknet',
    $many_header_name, $many_header_bytes);
Irssi::emit('dcc request', $many_header_offer);
my $many_header_path = Irssi::settings_get_str('dcc_download_path') . "/$many_header_name";
open my $many_header_fh, '>:raw', $many_header_path or die "could not write parser fixture: $!";
print {$many_header_fh} $many_header_bytes or die "could not write parser fixture: $!";
close $many_header_fh or die "could not close parser fixture: $!";
$many_header_offer->{file} = $many_header_path;
$many_header_offer->{transfd} = length($many_header_bytes);
Irssi::emit('dcc get receive', $many_header_offer);
Irssi::emit('dcc closed', $many_header_offer);
my ($parse_step_timer) = grep {
    my $timer = Irssi::timer_record($_);
    $timer && $timer->[5] == 10;
} Irssi::timer_handles();
ok defined($parse_step_timer), 'archive parsing is queued on an Irssi-supported timer';
Irssi::fire_timer($parse_step_timer);
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
like join("\n", @Irssi::PRINTS), qr/No completed SearchBot result collection/,
    'partial parser work does not publish any rows';
Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
@Irssi::PRINTS = ();
drain_parse_steps();
Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
like join("\n", @Irssi::PRINTS), qr/No completed SearchBot result collection/,
    'cancellation makes all remaining archive work inert';

run_search('Schedule failure');
my $schedule_failure_bytes = make_zip("!BookBot Example.epub\n");
my $schedule_failure_name = 'SearchBot_results_for__Schedule_failure.txt.zip';
my $schedule_failure_offer = new_result_offer(
    'Search', 'mocknet', $schedule_failure_name, $schedule_failure_bytes
);
Irssi::emit('dcc request', $schedule_failure_offer);
my $schedule_failure_path = Irssi::settings_get_str('dcc_download_path') . "/$schedule_failure_name";
open my $schedule_failure_fh, '>:raw', $schedule_failure_path
    or die "could not write scheduler-failure fixture: $!";
print {$schedule_failure_fh} $schedule_failure_bytes
    or die "could not write scheduler-failure fixture: $!";
close $schedule_failure_fh or die "could not close scheduler-failure fixture: $!";
$schedule_failure_offer->{file} = $schedule_failure_path;
$schedule_failure_offer->{transfd} = length($schedule_failure_bytes);
my $real_timeout_add_once = \&Irssi::timeout_add_once;
{
    no warnings 'redefine';
    local *Irssi::timeout_add_once = sub {
        die 'injected archive-step scheduling failure' if $_[0] == 10;
        return $real_timeout_add_once->(@_);
    };
    Irssi::emit('dcc get receive', $schedule_failure_offer);
    Irssi::emit('dcc closed', $schedule_failure_offer);
}
like join("\n", @Irssi::PRINTS), qr/archive processing could not be scheduled/,
    'archive-step timer failure is reported instead of escaping the callback';
Irssi::run_command('fscrawl', 'status', $server, undef);
like join("\n", @Irssi::PRINTS), qr/searchbot_state=refused searchbot_results=0/,
    'timer registration failure retires the collection without publishing rows';
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'timer registration failure restores the original DCC download path';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
like join("\n", @Irssi::PRINTS), qr/No completed SearchBot result collection/,
    'a collection whose parser could not be scheduled remains unavailable';

# A validated result archive remains recoverable if moving it out of staging
# fails. Keep finalization failure injected through the cooperative parse step.
run_search('Failed finalization');
my $failed_finalization_name = 'SearchBot_results_for__Failed_finalization.txt.zip';
my $failed_finalization_bytes = make_zip("!BookBot Recoverable.epub ::INFO:: 10 KB\n");
my $failed_finalization_offer = new_result_offer(
    'Search', 'mocknet', $failed_finalization_name, $failed_finalization_bytes
);
Irssi::emit('dcc request', $failed_finalization_offer);
my $failed_finalization_staging = Irssi::settings_get_str('dcc_download_path');
my $failed_finalization_source = "$failed_finalization_staging/$failed_finalization_name";
open my $failed_finalization_fh, '>:raw', $failed_finalization_source
    or die "could not write finalization-failure fixture: $!";
print {$failed_finalization_fh} $failed_finalization_bytes
    or die "could not write finalization-failure fixture: $!";
close $failed_finalization_fh
    or die "could not close finalization-failure fixture: $!";
$failed_finalization_offer->{file} = $failed_finalization_source;
$failed_finalization_offer->{transfd} = length($failed_finalization_bytes);
my @failed_finalization_warnings;
{
    no warnings qw(redefine once);
    local *Irssi::Script::dccatlas::finalize_download = sub { return; };
    local $SIG{__WARN__} = sub { push @failed_finalization_warnings, @_ };
    Irssi::emit('dcc get receive', $failed_finalization_offer);
    Irssi::emit('dcc closed', $failed_finalization_offer);
    drain_parse_steps();
}
my $failed_finalization_output = join("\n", @Irssi::PRINTS);
my $normalized_failed_finalization_output = $failed_finalization_output;
my $normalized_failed_finalization_source = $failed_finalization_source;
$normalized_failed_finalization_output =~ s{\\}{/}g;
$normalized_failed_finalization_source =~ s{\\}{/}g;
like $normalized_failed_finalization_output,
    qr/Validated result ZIP remains in staging at \Q$normalized_failed_finalization_source\E because it could not be moved safely/,
    'failed archive finalization reports the retained staging path';
ok -f $failed_finalization_source,
    'the validated result ZIP remains at the reported recovery path';
is scalar(@failed_finalization_warnings), 0,
    'failed finalization does not interpolate an undefined staging path';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
like join("\n", @Irssi::PRINTS), qr/Recoverable\.epub/,
    'a storage-finalization failure does not discard validated result rows';
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'failed archive finalization restores the original DCC download path';

my $first_refresh_id = complete_query('Refresh first', "!FirstBot First.epub\n");
ok $first_refresh_id, 'first refreshed collection exposes its own selection ID';
my $second_refresh_id = complete_query('Refresh second', "!SecondBot Second.epub\n");
ok $second_refresh_id && $second_refresh_id ne $first_refresh_id,
    'second refreshed collection uses a different selection ID';
my $command_count_before_old_token = scalar @{$server->{commands}};
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-get $first_refresh_id --sender FirstBot", $server, undef);
is scalar(@{$server->{commands}}), $command_count_before_old_token,
    'an old selection ID cannot trigger the later collection row';
like join("\n", @Irssi::PRINTS), qr/older or different collection/,
    'refusal identifies the old collection token';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-preview $second_refresh_id --sender SecondBot", $server, undef);
like join("\n", @Irssi::PRINTS), qr/outgoing channel text: !SecondBot Second\.epub/,
    'the current displayed selection previews its own direct request payload';

my $header_selection = complete_query('Header rows',
    "SearchBot report\n\n!FirstBot First.epub\n\n!SecondBot Second.epub\n");
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot-list', $server, undef);
my @header_selection_ids = join("\n", @Irssi::PRINTS) =~
    /(searchbot-[1-9][0-9]*-[a-f0-9]{32}:[1-9][0-9]*)/ig;
is scalar(@header_selection_ids), 2,
    'header and blank lines do not alter the number of selectable results';
like $header_selection_ids[0], qr/:1\z/,
    'the first collection selection uses result ordinal one, not source line';
like $header_selection_ids[1], qr/:2\z/,
    'the second collection selection uses result ordinal two, not source line';
Irssi::run_command('fscrawl', "searchbot-preview $header_selection_ids[0]", $server, undef);
like join("\n", @Irssi::PRINTS), qr/outgoing channel text: !FirstBot First\.epub/,
    'the first collection token previews its own row after header lines';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-preview $header_selection_ids[1]", $server, undef);
like join("\n", @Irssi::PRINTS), qr/outgoing channel text: !SecondBot Second\.epub/,
    'the second collection token previews its own row after header lines';

$Irssi::SETTINGS{fscrawl_searchbot_content_timeout_ms} = 1000;
my $timeout_selection = complete_query('Direct offer timeout', "!ExpireBot Expire.epub\n");
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "searchbot-get $timeout_selection --sender ExpireBot", $server, undef);
is $server->{raw_lines}[-1], 'PRIVMSG #books :!ExpireBot Expire.epub',
    'an eligible direct selection emits exactly its original result row';
my $raw_after_dispatch = scalar @{$server->{raw_lines}};
@Irssi::PRINTS = ();
run_search('Must not overlap direct request');
is scalar(@{$server->{raw_lines}}), $raw_after_dispatch,
    'a pending direct request reserves the slot against a new SearchBot query';
like join("\n", @Irssi::PRINTS), qr/wait for any DCC GET to close/,
    'the blocked competing query reports the shared transfer ownership';
my ($direct_offer_timer) = grep {
    my $timer = Irssi::timer_record($_);
    $timer && $timer->[5] == 1000;
} Irssi::timer_handles();
ok defined($direct_offer_timer), 'direct request registers its bounded offer deadline before dispatch';
Irssi::fire_timer($direct_offer_timer);
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'status', $server, undef);
like join("\n", @Irssi::PRINTS), qr/searchbot_direct_state=expired/,
    'offer timeout retires the direct request without retry';
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'offer timeout restores the original DCC path';
my $late_direct_offer = new_result_offer('ExpireBot', 'mocknet', 'Expire.epub', 'late bytes');
Irssi::emit('dcc request', $late_direct_offer);
ok $late_direct_offer->{destroyed}, 'offer matching an expired direct tuple is refused as stale';
is scalar(@{$server->{raw_lines}}), $raw_after_dispatch,
    'stale offer handling emits no retry or follow-up message';

my $timer_fault_selection = complete_query('Direct timer fault', "!TimerFaultBot Timer.epub\n");
my $raw_before_timer_fault = scalar @{$server->{raw_lines}};
my $real_direct_timeout_add_once = \&Irssi::timeout_add_once;
@Irssi::PRINTS = ();
{
    no warnings 'redefine';
    local *Irssi::timeout_add_once = sub {
        die 'injected direct offer timer failure' if $_[0] == 1000;
        return $real_direct_timeout_add_once->(@_);
    };
    Irssi::run_command('fscrawl',
        "searchbot-get $timer_fault_selection --sender TimerFaultBot", $server, undef);
}
is scalar(@{$server->{raw_lines}}), $raw_before_timer_fault,
    'failed direct-offer timer registration sends no request';
like join("\n", @Irssi::PRINTS), qr/offer timer registration failed/,
    'direct timer setup failure is reported before dispatch';
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'direct timer setup failure releases staging and restores the DCC path';

# The one-second offer deadline above is explicitly tested by firing its
# synthetic timer. Restore the production default before later transfer tests;
# otherwise a slow host run can expire the unrelated short-receipt fixture.
$Irssi::SETTINGS{fscrawl_searchbot_content_timeout_ms} = 120000;

my $dispatch_fault_selection = complete_query('Direct dispatch fault', "!DispatchFaultBot Fault.epub\n");
my $raw_before_dispatch_fault = scalar @{$server->{raw_lines}};
@Irssi::PRINTS = ();
{
    local $server->{on_raw} = sub { die 'injected uncertain transport failure'; };
    Irssi::run_command('fscrawl',
        "searchbot-get $dispatch_fault_selection --sender DispatchFaultBot", $server, undef);
}
is scalar(@{$server->{raw_lines}}), $raw_before_dispatch_fault + 1,
    'ambiguous dispatch failure represents one attempted raw request';
like join("\n", @Irssi::PRINTS), qr/uncertain; it was not resent/,
    'ambiguous dispatch failure is surfaced without an automatic resend';
my $raw_after_uncertain = scalar @{$server->{raw_lines}};
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl',
    "searchbot-get $dispatch_fault_selection --sender DispatchFaultBot", $server, undef);
is scalar(@{$server->{raw_lines}}), $raw_after_uncertain,
    'a tuple with uncertain dispatch cannot be retried in the same script session';
like join("\n", @Irssi::PRINTS), qr/already used or overlaps a SearchBot archive tuple/,
    'same-tuple refusal explains the no-nonce guard';

my $cancel_selection = complete_query('Direct cancel', "!CancelBot Cancel.epub\n");
my $raw_before_cancel = scalar @{$server->{raw_lines}};
Irssi::run_command('fscrawl', "searchbot-get $cancel_selection --sender CancelBot", $server, undef);
is scalar(@{$server->{raw_lines}}), $raw_before_cancel + 1,
    'cancellation fixture dispatches one direct request before cancellation';
Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'cancelling a pending direct request restores the original DCC path';
my $cancelled_offer = new_result_offer('CancelBot', 'mocknet', 'Cancel.epub', 'late bytes');
Irssi::emit('dcc request', $cancelled_offer);
ok $cancelled_offer->{destroyed}, 'cancelled direct request cannot accept its late offer';
is scalar(@{$server->{raw_lines}}), $raw_before_cancel + 1,
    'late offer after cancellation does not dispatch another request';

my $short_selection = complete_query('Direct short transfer', "!ShortBot Short.epub\n");
Irssi::run_command('fscrawl', "searchbot-get $short_selection --sender ShortBot", $server, undef);
my $short_stage = Irssi::settings_get_str('dcc_download_path');
my $short_payload = 'short-receive-fixture-bytes';
my $short_offer = new_result_offer('ShortBot', 'mocknet', 'Short.epub', $short_payload);
Irssi::emit('dcc request', $short_offer);
my $short_path = "$short_stage/Short.epub";
open my $short_fh, '>:raw', $short_path or die "could not write short transfer fixture: $!";
print {$short_fh} substr($short_payload, 0, 5) or die "could not write short transfer fixture: $!";
close $short_fh or die "could not close short transfer fixture: $!";
$short_offer->{file} = $short_path;
$short_offer->{transfd} = 5;
Irssi::emit('dcc get receive', $short_offer);
Irssi::emit('dcc closed', $short_offer);
my $short_collection_id = $short_selection;
$short_collection_id =~ s/:\d+\z//;
ok !-f "$temp/downloads/MockNet/ShortBot/SearchBot/$short_collection_id/Short.epub",
    'short direct receipt is never finalized as a successful content file';
ok -f $short_path, 'short receive remains recoverable in its request staging directory';
like join("\n", @Irssi::PRINTS), qr/not an exact successful receive/,
    'short direct receipt reports an incomplete outcome';
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'short direct receipt releases the DCC path owner';

$Irssi::SETTINGS{fscrawl_searchbot_content_transfer_timeout_ms} = 1000;
my $stalled_selection = complete_query('Direct stalled transfer', "!StallBot Stall.epub\n");
Irssi::run_command('fscrawl', "searchbot-get $stalled_selection --sender StallBot", $server, undef);
my $stalled_offer = new_result_offer('StallBot', 'mocknet', 'Stall.epub', 'stall-bytes');
Irssi::emit('dcc request', $stalled_offer);
ok !$stalled_offer->{destroyed}, 'the exact direct offer is accepted before receive begins';
my ($direct_transfer_timer) = grep {
    my $timer = Irssi::timer_record($_);
    $timer && $timer->[5] == 1000;
} Irssi::timer_handles();
ok defined($direct_transfer_timer), 'direct transfer has a separate bounded completion deadline';
Irssi::fire_timer($direct_transfer_timer);
ok $stalled_offer->{destroyed}, 'stalled direct DCC transfer is closed at its deadline';
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'direct transfer expiry restores the original DCC path';
my $stalled_collection_id = $stalled_selection;
$stalled_collection_id =~ s/:\d+\z//;
Irssi::emit('dcc get receive', $stalled_offer);
Irssi::emit('dcc closed', $stalled_offer);
ok !-f "$temp/downloads/MockNet/StallBot/SearchBot/$stalled_collection_id/Stall.epub",
    'late callbacks after direct transfer timeout cannot publish a file';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'status', $server, undef);
like join("\n", @Irssi::PRINTS), qr/searchbot_direct_state=transfer_expired/,
    'direct transfer timeout is a visible terminal state';

my $disconnect_selection = complete_query('Direct disconnect', "!DisconnectBot Disconnect.epub\n");
my $raw_before_disconnect = scalar @{$server->{raw_lines}};
Irssi::run_command('fscrawl',
    "searchbot-get $disconnect_selection --sender DisconnectBot", $server, undef);
$server->{connected} = 0;
Irssi::emit('server disconnected', $server->new_wrapper());
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'disconnect retires a pending direct request and restores the DCC path';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'status', $server, undef);
like join("\n", @Irssi::PRINTS), qr/searchbot_state=disconnected.*searchbot_direct_state=disconnected/s,
    'disconnect invalidates both pending request and collection selection state';
my $disconnected_offer = new_result_offer('DisconnectBot', 'mocknet', 'Disconnect.epub', 'late bytes');
Irssi::emit('dcc request', $disconnected_offer);
ok $disconnected_offer->{destroyed}, 'content offer from the disconnected generation is refused';
is scalar(@{$server->{raw_lines}}), $raw_before_disconnect + 1,
    'disconnect and its stale offer do not emit another channel request';

$server->{connected} = 1;
my $reconnected_selection = complete_query('Direct reconnect generation',
    "!ReconnectedBot New.epub\n");
my $raw_before_old_reconnect_token = scalar @{$server->{raw_lines}};
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl',
    "searchbot-get $disconnect_selection --sender DisconnectBot", $server->new_wrapper(), undef);
is scalar(@{$server->{raw_lines}}), $raw_before_old_reconnect_token,
    'a pre-disconnect selection remains stale after the same native server reconnects';
like join("\n", @Irssi::PRINTS), qr/older or different collection/,
    'reconnected collection rejects the old connection-generation selection';
my $reconnected_raw_before = scalar @{$server->{raw_lines}};
Irssi::run_command('fscrawl',
    "searchbot-get $reconnected_selection --sender ReconnectedBot",
    $server->new_wrapper(), undef);
is scalar(@{$server->{raw_lines}}), $reconnected_raw_before + 1,
    'the new native connection generation accepts a fresh selection through a new wrapper';
Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);

my $reentrant_selection = complete_query('Reentrant stopped callback',
    "!ReentrantBot Reentrant.epub\n");
my $reentrant_payload = '!ReentrantBot Reentrant.epub';
Irssi::run_command('fscrawl',
    "searchbot-get $reentrant_selection --sender ReentrantBot", $server, undef);
my $reentrant_offer = new_result_offer('ReentrantBot', 'mocknet',
    'Reentrant.epub', 'x' x 100);
Irssi::emit('dcc request', $reentrant_offer);
my $reentrant_stage = Irssi::settings_get_str('dcc_download_path');
my $reentrant_path = "$reentrant_stage/Reentrant.epub";
open my $reentrant_fh, '>:raw', $reentrant_path
    or die "could not write reentrant close fixture: $!";
print {$reentrant_fh} 'received-prefix'
    or die "could not write reentrant close fixture: $!";
close $reentrant_fh or die "could not close reentrant fixture: $!";
$reentrant_offer->{file} = $reentrant_path;
$reentrant_offer->{transfd} = 15;
Irssi::emit('dcc get receive', $reentrant_offer);
my $reentrant_original_destroy = \&MockDcc::destroy;
my $reentrant_destroy_calls = 0;
{
    no warnings 'redefine';
    local *MockDcc::destroy = sub {
        my ($dcc) = @_;
        $reentrant_destroy_calls++;
        Irssi::emit('dcc closed', $dcc);
        return $reentrant_original_destroy->($dcc);
    };
    Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
}
my $reentrant_job = latest_job_for_exact_payload($reentrant_payload);
ok $reentrant_job && $reentrant_job->{state} eq 'cancelled',
    'a close callback reentrant with native destruction preserves cancellation';
ok $reentrant_job->{partial}{writer_closed},
    'the reentrant close records closure before sealing or releasing the job';
is count_job_state_transitions($reentrant_job->{id}, 'cancelled'), 1,
    'reentrant close and destroyed callbacks apply the cancellation once';
is $reentrant_destroy_calls, 1, 'native destruction is invoked once';
ok !Irssi::Script::dccatlas::has_active_download_transfer(),
    'the reentrant close releases the exact transfer binding';
my $reentrant_collection_id = $reentrant_selection;
$reentrant_collection_id =~ s/:\d+\z//;
ok !-f "$temp/downloads/MockNet/ReentrantBot/SearchBot/$reentrant_collection_id/Reentrant.epub",
    'reentrant stopped close never publishes partial bytes';
Irssi::emit('dcc closed', $reentrant_offer);
Irssi::emit('dcc destroyed', $reentrant_offer);
is count_job_state_transitions($reentrant_job->{id}, 'cancelled'), 1,
    'duplicate late close notifications do not repeat the durable transition';

Irssi::Script::dccatlas::UNLOAD();
is Irssi::settings_get_str('dcc_download_path'), "$temp/original-dcc-path",
    'unload cancels owned pending work and restores the prior DCC path';
my $journal_probe = eval {
    FServe::Transfer::Journal->open_store(
        path => "$temp/fserve-poc/phase6/requests.jsonl");
};
ok $journal_probe, 'unload releases the process-lifetime request-journal lock';
$journal_probe->close() if $journal_probe;

done_testing();
