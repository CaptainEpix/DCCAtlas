#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use File::Find qw(find);
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";
Irssi::settings_set_str('fscrawl_library_dir', "$FindBin::Bin/../../lib");
Irssi::settings_set_str('fscrawl_output_dir', "$test_root/output");
Irssi::settings_set_str('fscrawl_download_dir', "$test_root/downloads");
mkdir "$test_root/downloads" or die "could not create download test root: $!";
Irssi::settings_set_str('dcc_download_path', "$test_root/downloads");

my $server = MockServer->new();
$server->{nick} = 'LocalNick';
$Irssi::SETTINGS{fscrawl_find_quiet_ms} = 250;

Irssi::run_command('fscrawl', 'find #files cancel-query', $server, undef);
for my $line (
    '[@Find Results] -=SysReset 2.55=-',
    'Found [1] file on Trigger:[!cancelbot] - Sends:[0/1] - Queues:[0/1]',
    'File: [cancel.txt] - Size [6B]',
    'End of @Find.',
) {
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, $line, 'CancelBot', 'bot@localhost', '#files');
}
my $quiet_timer = $Irssi::TIMERS[-1];
ok $quiet_timer && Irssi::fire_timer($quiet_timer->[2]),
    'offline Find response completes before queue selection';

Irssi::run_command('fscrawl', 'queue-add find find-1-1 channel', $server, undef);
my ($job_id) = map { /Added held job (job-[a-f0-9]{32})/ ? $1 : () } @Irssi::PRINTS;
ok $job_id, 'one exact Find result becomes a durable held job';

$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
Irssi::run_command('fscrawl', "queue-run $job_id", $server, undef);
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 1,
    'queued FServe trigger is pending before cancellation';
is scalar(grep { /^MSG #files !cancelbot$/ } @{$server->{commands}}), 0,
    'pending trigger has not reached transport';

Irssi::run_command('fscrawl', "queue-cancel $job_id", $server, undef);
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 0,
    'queue-cancel removes the exact job-owned scheduler reservation';
is scalar(grep { /^MSG #files !cancelbot$/ } @{$server->{commands}}), 0,
    'cancelled pending trigger is never sent';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $job_id", $server, undef);
like join("\n", @Irssi::PRINTS), qr/provider=find state=cancelled/,
    'pre-transport cancellation is durable and terminal';
like join("\n", @Irssi::PRINTS), qr/outcome=local_queue_cancelled/,
    'job evidence records local cancellation rather than remote queue removal';

Irssi::run_command('fscrawl', 'find #files cancel-live-query', $server, undef);
Irssi::test_run_outbound_timers();
for my $line (
    '[@Find Results] -=SysReset 2.55=-',
    'Found [1] file on Trigger:[!cancellive] - Sends:[0/1] - Queues:[0/1]',
    'File: [cancel-live.txt] - Size [9B]',
    'End of @Find.',
) {
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, $line, 'CancelLiveBot', 'bot@localhost', '#files');
}
my $live_quiet_timer = $Irssi::TIMERS[-1];
ok $live_quiet_timer && Irssi::fire_timer($live_quiet_timer->[2]),
    'second offline Find response completes for the between-messages cancellation case';
Irssi::run_command('fscrawl', 'queue-add find find-2-1 channel', $server, undef);
my ($live_job_id) = map { /Added held job (job-[a-f0-9]{32})/ ? $1 : () } @Irssi::PRINTS;
ok $live_job_id, 'distinct Find result becomes a second held job';

Irssi::run_command('fscrawl', "queue-run $live_job_id", $server, undef);
Irssi::test_run_outbound_timers();
ok scalar(grep { /^MSG #files !cancellive$/ } @{$server->{commands}}),
    'second exact queued trigger reaches the offline mock transport';
my $live_chat = bless {
    type => 'CHAT', nick => 'CancelLiveBot', id => 'CancelLiveBot', server => $server,
    servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $live_chat, '127.0.0.1');
Irssi::emit('dcc connected', $live_chat);
Irssi::emit('dcc chat message', $live_chat, '[\\]');
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG =CancelLiveBot dir$/ } @Irssi::GLOBAL_COMMANDS), 1,
    'queued session is waiting on its live parent listing after the first CHAT command';
Irssi::run_command('fscrawl', "queue-cancel $live_job_id", $server, undef);
for my $line ('[\\*.*]', 'cancel-live.txt 9B', 'End of list.') {
    Irssi::emit('dcc chat message', $live_chat, $line);
}
is scalar(grep { /^MSG =CancelLiveBot get cancel-live\.txt$/ } @Irssi::GLOBAL_COMMANDS), 0,
    'queue-cancel during the parent-listing wait makes late output unable to issue GET';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $live_job_id", $server, undef);
like join("\n", @Irssi::PRINTS), qr/provider=find state=cancelled/,
    'between-messages cancellation records a terminal local job state';

@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'find #files cancel-owned-transfer', $server, undef);
Irssi::test_run_outbound_timers();
for my $line (
    '[@Find Results] -=SysReset 2.55=-',
    'Found [1] file on Trigger:[!ownedcancelbot] - Sends:[0/1] - Queues:[0/1]',
    'File: [owned-cancel.txt] - Size [9B]',
    'End of @Find.',
) {
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, $line, 'OwnedCancelBot', 'bot@localhost', '#files');
}
my $owned_quiet_timer = $Irssi::TIMERS[-1];
ok $owned_quiet_timer && Irssi::fire_timer($owned_quiet_timer->[2]),
    'a third offline Find response completes for the in-flight DCC cancellation case';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'queue-add find find-3-1 channel', $server, undef);
my ($owned_job_id) = map { /Added held job (job-[a-f0-9]{32})/ ? $1 : () } @Irssi::PRINTS;
ok $owned_job_id, 'owned FServe transfer fixture becomes a durable job';
Irssi::run_command('fscrawl', "queue-run $owned_job_id", $server, undef);
Irssi::test_run_outbound_timers();
ok scalar(grep { /^MSG #files !ownedcancelbot$/ } @{$server->{commands}}),
    'the explicit queue run dispatches its one FServe trigger';
my $owned_chat = bless {
    type => 'CHAT', nick => 'OwnedCancelBot', id => 'OwnedCancelBot', server => $server,
    servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
Irssi::emit('dcc request', $owned_chat, '127.0.0.1');
Irssi::emit('dcc connected', $owned_chat);
Irssi::emit('dcc chat message', $owned_chat, '[\\]');
Irssi::test_run_outbound_timers();
for my $line ('[\\*.*]', 'owned-cancel.txt 9B', 'End of list.') {
    Irssi::emit('dcc chat message', $owned_chat, $line);
}
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG =OwnedCancelBot get owned-cancel\.txt$/ } @Irssi::GLOBAL_COMMANDS), 1,
    'the live parent listing authorizes exactly one FServe GET before cancellation';
my $owned_dcc = bless {
    type => 'GET', nick => 'OwnedCancelBot', arg => 'owned-cancel.txt',
    size => 9, transfd => 0, server => $server, servertag => 'mocknet',
    Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $owned_dcc);
my $owned_path = Irssi::settings_get_str('dcc_download_path') . '/owned-cancel.txt';
open my $owned_fh, '>:raw', $owned_path or die "could not write owned DCC fixture: $!";
print {$owned_fh} 'prefix' or die "could not write owned DCC fixture: $!";
close $owned_fh or die "could not close owned DCC fixture: $!";
$owned_dcc->{file} = $owned_path;
$owned_dcc->{transfd} = 6;
Irssi::emit('dcc get receive', $owned_dcc);
{
    no warnings 'redefine';
    local *MockDcc::destroy = sub { die "injected owned FServe destroy failure\n" };
    Irssi::run_command('fscrawl', "queue-cancel $owned_job_id", $server, undef);
}
ok Irssi::Script::dccatlas::has_active_download_transfer(),
    'failed native destruction retains the owned FServe transfer binding';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $owned_job_id", $server, undef);
like join("\n", @Irssi::PRINTS), qr/provider=find state=cancelled/,
    'the durable local cancellation remains terminal while the native close is pending';
open my $owned_append, '>>:raw', $owned_path or die "could not extend owned DCC fixture: $!";
print {$owned_append} 'xxx' or die "could not extend owned DCC fixture: $!";
close $owned_append or die "could not close extended owned DCC fixture: $!";
$owned_dcc->{transfd} = 9;
Irssi::emit('dcc get receive', $owned_dcc);
Irssi::emit('dcc closed', $owned_dcc);
MockDcc::destroy($owned_dcc);
ok !Irssi::Script::dccatlas::has_active_download_transfer(),
    'a delayed native close releases the owned FServe binding';
ok -f $owned_path, 'the cancelled FServe partial remains staged';
my @published_owned_files;
find(sub {
    $File::Find::prune = 1 if $_ eq '.incoming' && -d $_;
    push @published_owned_files, $File::Find::name
        if $_ eq 'owned-cancel.txt';
}, "$test_root/downloads");
is scalar(@published_owned_files), 0,
    'the late full-size FServe callback cannot publish cancelled content';
is scalar(grep { /^MSG =OwnedCancelBot get owned-cancel\.txt$/ } @Irssi::GLOBAL_COMMANDS), 1,
    'closing a cancelled FServe transfer does not replay its GET';

done_testing();
