#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use File::Temp qw(tempdir);
use Scalar::Util qw(weaken);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $server = MockServer->new();
my @sent;
my @done;
my $first = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'query', route => 'mocknet/#one/bot-a',
    send => sub { push @sent, 'first' },
    on_done => sub { push @done, [@_] },
);
is $first->{status}, 'complete', 'first application message dispatches immediately';
is_deeply \@sent, ['first'], 'first payload is dispatched exactly once';
is $done[-1][0], 'sent', 'completion callback records an actual send';

my $same_route = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'query', route => 'mocknet/#one/bot-a',
    send => sub { push @sent, 'same-route' },
    on_done => sub { push @done, [@_] },
);
is $same_route->{status}, 'pending', 'same serving route is deferred by the route cooldown';
is scalar(@sent), 1, 'pending message has not reached its transport';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 1,
    'delayed application message owns one cancellable reservation';
my ($route_timer) = keys %Irssi::OUTBOUND_TIMERS;
ok defined($route_timer), 'delayed reservation has a registered timer';
ok Irssi::fire_timer($route_timer), 'fake clock advances through the route cooldown';
is_deeply \@sent, ['first', 'same-route'], 'due message dispatches once after the cooldown';
is $done[-1][0], 'sent', 'delayed completion callback reports sent';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 0,
    'committed delayed reservation is removed';

my $stale = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'query', route => 'mocknet/#one/bot-a',
    send => sub { push @sent, 'stale-connection' },
    on_done => sub { push @done, [@_] },
);
is $stale->{status}, 'pending', 'same-route query is reserved for its next cooldown window';
my $cancelled = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'query', route => 'mocknet/#one/bot-a',
    send => sub { push @sent, 'cancelled' },
    on_done => sub { push @done, [@_] },
);
is $cancelled->{status}, 'pending', 'a later same-route reservation remains independently pending';
ok Irssi::Script::dccatlas::cancel_outbound_message(
    $cancelled->{token}, 'explicit offline test cancellation'),
    'operator cancellation removes the outbound task';
is $done[-1][0], 'cancelled_before_send', 'cancel outcome proves transport was not invoked';
is scalar(@sent), 2, 'canceled payload never reaches its transport';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 1,
    'canceling one reservation preserves the earlier one';
my ($stale_timer) = keys %Irssi::OUTBOUND_TIMERS;
$server->{connected} = 0;
ok Irssi::fire_timer($stale_timer), 'stale connection timer can be exercised deterministically';
isnt $done[-1][0], 'sent', 'dispatch-time liveness revalidation rejects a disconnected server';
is scalar(@sent), 2, 'stale transport callback never runs';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 0,
    'stale reservation is canceled rather than leaked';

$server->{connected} = 1;
my $before_disconnect = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'query', route => 'mocknet/#two/bot-b',
    send => sub { push @sent, 'before-disconnect' },
    on_done => sub { push @done, [@_] },
);
is $before_disconnect->{status}, 'complete', 'a distinct route can use the live connection budget';
is $sent[-1], 'before-disconnect', 'distinct route was sent on its eligible connection';

my $missing_route = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'query',
    send => sub { push @sent, 'missing-route' },
);
ok !defined($missing_route), 'query dispatch fails closed without a serving-route key';
is scalar(@sent), 3, 'missing route cannot bypass rate limiting';

my $disconnect_pending = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'query', route => 'mocknet/#two/bot-b',
    send => sub { push @sent, 'disconnected-pending' },
    on_done => sub { push @done, [@_] },
);
is $disconnect_pending->{status}, 'pending', 'same route observes its independent cooldown';
$server->{connected} = 0;
Irssi::Script::dccatlas::sig_server_disconnected($server);
is $done[-1][0], 'cancelled_before_send', 'disconnect cancels pending message before transport';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 0,
    'disconnect leaves no pending reservation';
is scalar(@sent), 3, 'disconnected pending payload is never dispatched';

$server->{connected} = 1;
Irssi::Script::dccatlas::sig_server_connected($server);
my $reconnected = Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'message',
    send => sub { push @sent, 'reconnected' },
    on_done => sub { push @done, [@_] },
);
is $reconnected->{status}, 'pending', 'reconnected native server receives a fresh captured epoch';
my ($reconnect_timer) = keys %Irssi::OUTBOUND_TIMERS;
ok Irssi::fire_timer($reconnect_timer), 'reconnected message becomes due under the fake clock';
is $done[-1][0], 'sent', 'new epoch may dispatch its own message';
is $sent[-1], 'reconnected', 'only the live reconnected task reaches transport';

my $budget_server = MockServer->new();
my @budget_sent;
my $budget_first = Irssi::Script::dccatlas::schedule_irc_message(
    server => $budget_server, kind => 'query', route => 'mocknet/#budget/bot',
    send => sub { push @budget_sent, 'first-route-query' },
);
is $budget_first->{status}, 'complete',
    'isolated dispatch-budget fixture starts with an available route';
my $budget_pending = Irssi::Script::dccatlas::schedule_irc_message(
    server => $budget_server, kind => 'query', route => 'mocknet/#budget/bot',
    send => sub { push @budget_sent, 'delayed-route-query' },
);
is $budget_pending->{status}, 'pending',
    'same-route query holds a delayed reservation for dispatch-time revalidation';
my ($budget_timer) = grep {
    $Irssi::OUTBOUND_TIMERS{$_}
} Irssi::timer_handles();
ok defined($budget_timer), 'delayed route query has a pending timer';

# Let another application message consume the connection budget after the
# query timer was armed but before its callback is allowed to dispatch.
$Irssi::MOCK_MONOTONIC = 200;
my $budget_consumer = Irssi::Script::dccatlas::schedule_irc_message(
    server => $budget_server, kind => 'message',
    send => sub { push @budget_sent, 'connection-budget-consumer' },
);
is $budget_consumer->{status}, 'complete',
    'a later eligible message consumes the connection budget immediately';
is_deeply \@budget_sent, ['first-route-query', 'connection-budget-consumer'],
    'the delayed query has not run before its old timer fires';
ok Irssi::fire_timer($budget_timer),
    'old query timer fires after the connection budget was consumed';
is_deeply \@budget_sent, ['first-route-query', 'connection-budget-consumer'],
    'dispatch-time budget revalidation withholds the delayed query';
my ($budget_recheck_timer) = grep {
    $Irssi::OUTBOUND_TIMERS{$_}
} Irssi::timer_handles();
ok defined($budget_recheck_timer),
    'failed budget revalidation rearms the query for the updated deadline';
ok Irssi::fire_timer($budget_recheck_timer),
    'delayed query dispatches after the updated connection deadline';
is_deeply \@budget_sent,
    ['first-route-query', 'connection-budget-consumer', 'delayed-route-query'],
    'route query is sent exactly once after both budgets permit dispatch';

my $route_budget_server = MockServer->new();
my @route_budget_sent;
my @route_budget_sent_at;
my $route_budget_first = Irssi::Script::dccatlas::schedule_irc_message(
    server => $route_budget_server, kind => 'query', route => 'mocknet/#route-budget/bot',
    send => sub {
        push @route_budget_sent, 'first-route-query';
        push @route_budget_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
is $route_budget_first->{status}, 'complete',
    'route-budget fixture starts with an available route';
my $route_budget_pending = Irssi::Script::dccatlas::schedule_irc_message(
    server => $route_budget_server, kind => 'trigger', route => 'mocknet/#route-budget/bot',
    send => sub {
        push @route_budget_sent, 'delayed-route-trigger';
        push @route_budget_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
is $route_budget_pending->{status}, 'pending',
    'a same-route trigger waits behind the query route cooldown';
my ($route_budget_timer) = grep {
    $Irssi::OUTBOUND_TIMERS{$_}
} Irssi::timer_handles();
ok defined($route_budget_timer), 'delayed route trigger owns its timer';
$Irssi::MOCK_MONOTONIC = 500;
my $route_budget_consumer = Irssi::Script::dccatlas::schedule_irc_message(
    server => $route_budget_server, kind => 'query', route => 'mocknet/#route-budget/bot',
    send => sub {
        push @route_budget_sent, 'route-budget-consumer';
        push @route_budget_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
is $route_budget_consumer->{status}, 'complete',
    'a later query consumes the route budget before the old trigger timer fires';
is_deeply \@route_budget_sent,
    ['first-route-query', 'route-budget-consumer'],
    'the old delayed trigger has not reached transport';
# Fire the old timer after the connection budget has expired, while the
# query/trigger route budget is still active. This keeps the route assertion
# independent of connection pacing.
my $route_budget_limits = Irssi::Script::dccatlas::outbound_scheduler()->limits;
my $route_budget_connection_deadline = 500 +
    $route_budget_limits->{connection_message_ms} / 1000;
my $route_budget_route_deadline = 500 +
    $route_budget_limits->{route_query_ms} / 1000;
$Irssi::MOCK_MONOTONIC = $route_budget_connection_deadline + 0.001;
cmp_ok $Irssi::MOCK_MONOTONIC, '>', $route_budget_connection_deadline,
    'old route timer is exercised after the connection cooldown expires';
cmp_ok $Irssi::MOCK_MONOTONIC, '<', $route_budget_route_deadline,
    'old route timer is exercised before the route cooldown expires';
ok Irssi::fire_timer($route_budget_timer),
    'old trigger timer fires after the route budget was consumed';
is_deeply \@route_budget_sent,
    ['first-route-query', 'route-budget-consumer'],
    'dispatch-time route-budget revalidation withholds the old trigger';
my ($route_budget_recheck_timer) = grep {
    $Irssi::OUTBOUND_TIMERS{$_}
} Irssi::timer_handles();
ok defined($route_budget_recheck_timer),
    'failed route-budget revalidation rearms for the updated route deadline';
my $route_budget_recheck_record = Irssi::timer_record($route_budget_recheck_timer);
cmp_ok $route_budget_recheck_record->[6], '>=', $route_budget_route_deadline,
    'rearmed trigger deadline does not precede the route cooldown';
cmp_ok $route_budget_recheck_record->[6], '<=', $route_budget_route_deadline + 0.002,
    'rearmed trigger deadline stays within timer-rounding tolerance';
my $route_budget_dispatch_at = $route_budget_recheck_record->[6];
ok Irssi::fire_timer($route_budget_recheck_timer),
    'delayed route trigger becomes eligible after the updated route deadline';
is_deeply \@route_budget_sent,
    ['first-route-query', 'route-budget-consumer', 'delayed-route-trigger'],
    'route-delayed trigger reaches transport exactly once after cooldown';
cmp_ok abs($route_budget_sent_at[-1] - $route_budget_dispatch_at), '<', 0.000001,
    'route-delayed transport runs at its rearmed fake-clock deadline';
is_deeply [@route_budget_sent_at[1, 2]],
    [500, $route_budget_dispatch_at],
    'route-budget consumer and delayed trigger retain their exact transport times';

my $burst_server = MockServer->new();
my (@burst_sent, @burst_sent_at);
my $burst_start = $Irssi::MOCK_MONOTONIC;
my $burst_first = Irssi::Script::dccatlas::schedule_irc_message(
    server => $burst_server, kind => 'message',
    send => sub {
        push @burst_sent, 'burst-first';
        push @burst_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
is $burst_first->{status}, 'complete',
    'fake-clock burst begins with one immediately eligible application message';
my $burst_second = Irssi::Script::dccatlas::schedule_irc_message(
    server => $burst_server, kind => 'message',
    send => sub {
        push @burst_sent, 'burst-second';
        push @burst_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
my $burst_third = Irssi::Script::dccatlas::schedule_irc_message(
    server => $burst_server, kind => 'message',
    send => sub {
        push @burst_sent, 'burst-third';
        push @burst_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
is $burst_second->{status}, 'pending',
    'second burst message reserves its own connection pacing window';
is $burst_third->{status}, 'pending',
    'third burst message reserves the following connection pacing window';
my @burst_timers = sort {
    Irssi::timer_record($a)->[6] <=> Irssi::timer_record($b)->[6]
} grep { $Irssi::OUTBOUND_TIMERS{$_} } Irssi::timer_handles();
is scalar(@burst_timers), 2,
    'both delayed burst messages retain independent timers';
my $burst_interval =
    $route_budget_limits->{connection_message_ms} / 1000;
my $burst_second_due = Irssi::timer_record($burst_timers[0])->[6];
my $burst_third_due = Irssi::timer_record($burst_timers[1])->[6];
cmp_ok abs($burst_second_due - ($burst_start + $burst_interval)), '<', 0.000001,
    'second burst timer is set to the next connection deadline';
cmp_ok abs($burst_third_due - ($burst_start + 2 * $burst_interval)), '<', 0.000001,
    'third burst timer is set to the following connection deadline';
ok Irssi::fire_timer($burst_timers[0]),
    'second burst message dispatches at its connection deadline';
is_deeply \@burst_sent, ['burst-first', 'burst-second'],
    'burst dispatch preserves reservation order through the second message';
cmp_ok abs($burst_sent_at[1] - $burst_second_due), '<', 0.000001,
    'second burst transport runs at its scheduled fake-clock time';
ok Irssi::fire_timer($burst_timers[1]),
    'third burst message dispatches at its connection deadline';
is_deeply \@burst_sent, ['burst-first', 'burst-second', 'burst-third'],
    'all burst messages reach transport exactly once in order';
cmp_ok abs($burst_sent_at[2] - $burst_third_due), '<', 0.000001,
    'third burst transport runs at its scheduled fake-clock time';

my $late_timer_server = MockServer->new();
my (@late_timer_sent, @late_timer_sent_at);
my $late_timer_first = Irssi::Script::dccatlas::schedule_irc_message(
    server => $late_timer_server, kind => 'message',
    send => sub {
        push @late_timer_sent, 'late-first';
        push @late_timer_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
is $late_timer_first->{status}, 'complete',
    'late-timer fixture establishes its connection deadline';
my $late_timer_pending = Irssi::Script::dccatlas::schedule_irc_message(
    server => $late_timer_server, kind => 'message',
    send => sub {
        push @late_timer_sent, 'late-delayed';
        push @late_timer_sent_at, $Irssi::MOCK_MONOTONIC;
    },
);
is $late_timer_pending->{status}, 'pending',
    'late-timer fixture reserves one delayed message';
my ($late_timer_handle) = grep {
    $Irssi::OUTBOUND_TIMERS{$_}
} Irssi::timer_handles();
ok defined($late_timer_handle), 'late-timer fixture owns a timer';
my $late_timer_due = Irssi::timer_record($late_timer_handle)->[6];
$Irssi::MOCK_MONOTONIC = $late_timer_due + 5;
ok Irssi::fire_timer($late_timer_handle),
    'delayed callback can be exercised five seconds after its deadline';
is_deeply \@late_timer_sent, ['late-first', 'late-delayed'],
    'late callback dispatches the overdue message once';
cmp_ok abs($late_timer_sent_at[-1] - $Irssi::MOCK_MONOTONIC), '<', 0.000001,
    'overdue transport runs at the current monotonic time';
ok Irssi::fire_timer($late_timer_handle, 1),
    'a duplicate invocation of the completed timer callback is harmless';
is_deeply \@late_timer_sent, ['late-first', 'late-delayed'],
    'duplicate late callback cannot dispatch the message twice';

my $weak_reservation;
my $leak_server = MockServer->new();
my $completed = Irssi::Script::dccatlas::schedule_irc_message(
    server => $leak_server, kind => 'message',
    send => sub {
        my ($task) = @_;
        $weak_reservation = $task->{reservation};
        weaken($weak_reservation);
    },
);
is $completed->{status}, 'complete', 'immediate task reaches terminal cleanup';
is $weak_reservation, undef,
    'completed scheduler task releases its reservation instead of retaining a closure cycle';

$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
my $persistence_server = MockServer->new();
my $persistence_sends = 0;
my $first_persistence_message = Irssi::Script::dccatlas::schedule_irc_message(
    server => $persistence_server, kind => 'message',
    send => sub { $persistence_sends++ },
);
is $first_persistence_message->{status}, 'complete',
    'persistence-failure fixture establishes a connection budget';
my @completion;
my $pending_before_failure = Irssi::Script::dccatlas::schedule_irc_message(
    server => $persistence_server, kind => 'message',
    send => sub { $persistence_sends++ },
    on_done => sub { push @completion, [@_] },
);
is $pending_before_failure->{status}, 'pending',
    'second message is delayed and awaiting its scheduler timer';
my ($pending_timer) = grep {
    $Irssi::OUTBOUND_TIMERS{$_}
} Irssi::timer_handles();
ok defined($pending_timer), 'pending message owns a cancellable timer before persistence failure';
my $failed_job;
{
    no warnings 'redefine';
    local *FServe::Transfer::Journal::_sync_handle = sub { $! = 5; return 0; };
    $failed_job = Irssi::Script::dccatlas::new_job(
        provider => 'find', server => $persistence_server,
        selection => { expected_peer => 'ProbeBot', remote_path => '/probe.epub',
            basename => 'probe.epub', trigger_raw => '!probe' },
    );
}
ok !defined($failed_job), 'failed durable job creation is refused';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 0,
    'journal sync failure immediately cancels every pending outbound reservation';
is $completion[-1][0], 'refused',
    'pending callback classifies the transport as definitely not invoked';
ok Irssi::fire_timer($pending_timer, 1),
    'even a manually forced cancelled timer callback is inert';
is $persistence_sends, 1,
    'journal failure cannot allow a delayed application message to reach transport';

done_testing();
