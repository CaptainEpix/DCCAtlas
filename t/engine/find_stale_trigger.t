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

Irssi::run_command('fscrawl', 'find #files pending-selection', $server, undef);
for my $line (
    '[@Find Results] -=SysReset 2.55=-',
    'Found [1] file on Trigger:[!oldselection] - Sends:[0/1] - Queues:[0/1]',
    'File: [old.txt] - Size [7B]',
    'End of @Find.',
) {
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, $line, 'PendingBot', 'bot@localhost', '#files');
}
my $quiet_timer = $Irssi::TIMERS[-1];
ok $quiet_timer && Irssi::fire_timer($quiet_timer->[2]),
    'offline @Find completes before a job is selected';

Irssi::run_command('fscrawl', 'queue-add find find-1-1 channel', $server, undef);
my ($job_id) = map { /Added held job (job-[a-f0-9]{32})/ ? $1 : () } @Irssi::PRINTS;
ok $job_id, 'exact completed @Find result becomes a durable held job';

my $budget_message = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'message', send => sub { push @{$server->{commands}}, 'BUDGET'; },
);
is $budget_message->{status}, 'pending',
    'offline budget message waits for the connection-rate interval';
Irssi::test_run_outbound_timers();
ok scalar(grep { $_ eq 'BUDGET' } @{$server->{commands}}),
    'offline budget message is transported before the selected trigger';

$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
Irssi::run_command('fscrawl', "queue-run $job_id", $server, undef);
is scalar(grep { /^MSG #files !oldselection$/ } @{$server->{commands}}), 0,
    'rate-limited FServe trigger is pending, not yet transported';
my ($trigger_timer) = keys %Irssi::OUTBOUND_TIMERS;
ok defined($trigger_timer), 'pending FServe trigger has a fake-clock callback';

# A replacement query invalidates the completed result generation while the
# selected FServe trigger is still waiting for its connection-rate deadline.
Irssi::run_command('fscrawl', 'find #files replacement-search', $server, undef);
ok Irssi::fire_timer($trigger_timer),
    'old trigger callback can be exercised deterministically after replacement';
is scalar(grep { /^MSG #files !oldselection$/ } @{$server->{commands}}), 0,
    'dispatch-time selection validation suppresses the stale old-result trigger';

done_testing();
