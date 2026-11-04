#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $server = MockServer->new();
$server->{nick} = 'LocalNick';
$Irssi::SETTINGS{fscrawl_find_quiet_ms} = 250;

Irssi::run_command('fscrawl', 'find #files pause-query', $server, undef);
for my $line (
    '[@Find Results] -=SysReset 2.55=-',
    'Found [1] file on Trigger:[!pausebot] - Sends:[0/1] - Queues:[0/1]',
    'File: [pause.txt] - Size [4B]',
    'End of @Find.',
) {
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, $line, 'PauseBot', 'bot@localhost', '#files');
}
my $quiet_timer = $Irssi::TIMERS[-1];
ok $quiet_timer && !$quiet_timer->[3], 'Find response has a live bounded quiet timer';
ok Irssi::fire_timer($quiet_timer->[2]), 'short fake-clock quiet window completes the result collection';

Irssi::run_command('fscrawl', 'queue-add find find-1-1 channel', $server, undef);
my ($job_id) = map { /Added held job (job-[a-f0-9]{32})/ ? $1 : () } @Irssi::PRINTS;
ok $job_id, 'offline Find result is converted into one durable held job';

$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
Irssi::run_command('fscrawl', "queue-run $job_id", $server, undef);
my $trigger_before_pause = scalar grep { /^MSG #files !pausebot$/ } @{$server->{commands}};
is $trigger_before_pause, 0, 'route-rate-limited FServe trigger remains pending before pause';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 1,
    'queued trigger owns one scheduler reservation before pause';

Irssi::run_command('fscrawl', 'queue-pause', $server, undef);
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 0,
    'queue pause removes the unsent trigger reservation';
is scalar(grep { /^MSG #files !pausebot$/ } @{$server->{commands}}), 0,
    'queue pause sends no late trigger';
Irssi::run_command('fscrawl', "job-show $job_id", $server, undef);
like join("\n", @Irssi::PRINTS), qr/job=\Q$job_id\E provider=find state=held/,
    'queue pause durably restores the unattempted job to held';

Irssi::run_command('fscrawl', "queue-run $job_id", $server, undef);
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 1,
    'resuming the same finite queue set reserves the trigger again';
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 1;
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG #files !pausebot$/ } @{$server->{commands}}), 1,
    'explicit queue resume dispatches the captured trigger exactly once';

my $chat = bless {
    type => 'CHAT', nick => 'PauseBot', id => 'PauseBot', server => $server,
    servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
Irssi::emit('dcc request', $chat, '127.0.0.1');
Irssi::emit('dcc connected', $chat);
Irssi::emit('dcc chat message', $chat, '[\\]');
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG =PauseBot dir$/ } @Irssi::GLOBAL_COMMANDS), 1,
    'live queued Find session requests its initial parent listing';

Irssi::run_command('fscrawl', 'queue-pause', $server, undef);
Irssi::run_command('fscrawl', "job-show $job_id", $server, undef);
like join("\n", @Irssi::PRINTS), qr/job=\Q$job_id\E provider=find state=held/,
    'pause while awaiting the parent listing returns the pre-GET job to held';
for my $line ('[\\*.*]', 'pause.txt 4B', 'End of list.') {
    Irssi::emit('dcc chat message', $chat, $line);
}
is scalar(grep { /^MSG =PauseBot get pause\.txt$/ } @Irssi::GLOBAL_COMMANDS), 0,
    'late listing lines after pause cannot advance to GET';
Irssi::run_command('fscrawl', "queue-run $job_id", $server, undef);
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG =PauseBot dir$/ } @Irssi::GLOBAL_COMMANDS), 2,
    'resuming from a paused listing restarts verification with a fresh parent request';

for my $line ('[\\*.*]', 'pause.txt 4B', 'End of list.') {
    Irssi::emit('dcc chat message', $chat, $line);
}
is scalar(grep { /^MSG =PauseBot get pause\.txt$/ } @Irssi::GLOBAL_COMMANDS), 0,
    'GET remains pending behind the bounded per-connection command interval';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 1,
    'pending GET owns one durable job-bound outbound reservation';

Irssi::run_command('fscrawl', 'queue-pause', $server, undef);
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 0,
    'queue pause withdraws the pending content GET';
is scalar(grep { /^MSG =PauseBot get pause\.txt$/ } @Irssi::GLOBAL_COMMANDS), 0,
    'paused content request never reaches the DCC CHAT transport';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'status', $server, undef);
like join("\n", @Irssi::PRINTS), qr/active=yes phase=paused_before_get/,
    'the original live DCC CHAT remains available as the paused session checkpoint';
Irssi::run_command('fscrawl', "job-show $job_id", $server, undef);
like join("\n", @Irssi::PRINTS), qr/job=\Q$job_id\E provider=find state=held/,
    'paused GET is durably restored to the held state';

Irssi::run_command('fscrawl', "queue-run $job_id", $server, undef);
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG =PauseBot dir$/ } @Irssi::GLOBAL_COMMANDS), 3,
    'same finite queue set resumes on the original CHAT and sends another fresh parent listing';
is scalar(grep { /^MSG =PauseBot get pause\.txt$/ } @Irssi::GLOBAL_COMMANDS), 0,
    'resumed GET is still withheld until the fresh parent listing arrives';
for my $line ('[\\*.*]', 'pause.txt 4B', 'End of list.') {
    Irssi::emit('dcc chat message', $chat, $line);
}
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG =PauseBot get pause\.txt$/ } @Irssi::GLOBAL_COMMANDS), 1,
    'exactly one GET is sent only after the resumed live parent re-verification';
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 1;

done_testing();
