use strict;
use warnings;
use FindBin;
use Test::More;
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep);
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../lib";
use FServe::Catalog::WorkerClient qw(run_async cancel_job active_jobs shutdown);

my @timers;
my @delays;
my @cancelled;
my $next_handle = 1;
my $invalid_handle;
my $force_invalid_handle = 0;
my $throw_schedule = 0;

sub schedule_timer {
    my ($delay, $callback) = @_;
    die "timer delay below Irssi minimum" if $delay < 10;
    die "injected timer registration failure" if $throw_schedule;
    return $invalid_handle if $force_invalid_handle;
    push @delays, $delay;
    my $handle = $next_handle++;
    push @timers, [$handle, $callback];
    return $handle;
}

sub cancel_timer {
    my ($handle) = @_;
    push @cancelled, $handle;
    @timers = grep { $_->[0] != $handle } @timers;
}

sub start_child {
    my ($program, $on_done, $on_event) = @_;
    return run_async(
        command => [$^X, '-e', $program],
        timeout_ms => 10_000,
        schedule_timer => \&schedule_timer,
        cancel_timer => \&cancel_timer,
        on_event => $on_event,
        on_done => $on_done || sub {},
    );
}

sub fire_one_timer {
    my $timer = shift @timers or return 0;
    $timer->[1]->();
    return 1;
}

my $completed;
my $job_id = start_child('print qq({"event":"result"}\\n); select undef, undef, undef, 0.2;', sub {
    my ($status, $stderr, $failure) = @_;
    $completed = {status => $status, stderr => $stderr, failure => $failure};
});
is $job_id, 1, 'worker job is registered';
is $delays[0], 10, 'first poll delay meets Irssi minimum';
is active_jobs(), 1, 'job is active while child runs';
sleep 0.05;
fire_one_timer();
cmp_ok scalar(grep { $_ == 50 } @delays), '>', 0,
    'subsequent polls use the injected scheduler';
my $deadline = time + 5;
while (!$completed && time < $deadline) {
    sleep 0.01;
    fire_one_timer();
}
ok $completed, 'real child completes through injected timer callback';
is $completed->{status}, 0, 'worker child exits successfully';
is active_jobs(), 0, 'completed job is removed';

for my $bad_handle (undef, 0, -1) {
    $invalid_handle = $bad_handle;
    $force_invalid_handle = 1;
    my $pid;
    my $done_calls = 0;
    my $original = \&FServe::Catalog::WorkerClient::open3;
    {
        no warnings 'redefine';
        local *FServe::Catalog::WorkerClient::open3 = sub {
            $pid = $original->(@_);
            return $pid;
        };
        my $error;
        eval { start_child('sleep 60;', sub { $done_calls++ }); 1 } or $error = $@;
        like $error, qr/could not schedule catalog worker polling/,
            "invalid timer handle [" . (defined($bad_handle) ? $bad_handle : 'undef') . "] fails closed";
    }
    is active_jobs(), 0, 'failed registration removes its job';
    is waitpid($pid, WNOHANG), -1, 'failed registration reaps its child';
    is $done_calls, 0, 'failed startup does not invoke the completion callback';
}
$invalid_handle = undef;
$force_invalid_handle = 0;

$throw_schedule = 1;
my $throw_pid;
{
    my $original = \&FServe::Catalog::WorkerClient::open3;
    no warnings 'redefine';
    local *FServe::Catalog::WorkerClient::open3 = sub {
        $throw_pid = $original->(@_);
        return $throw_pid;
    };
    my $error;
    eval { start_child('sleep 60;'); 1 } or $error = $@;
    like $error, qr/injected timer registration failure/,
        'thrown scheduler failure is returned to the caller';
}
$throw_schedule = 0;
is active_jobs(), 0, 'thrown scheduler failure removes its job';
is waitpid($throw_pid, WNOHANG), -1, 'thrown scheduler failure reaps its child';

my ($late_pid, $late_done, $late_failure);
{
    my $original = \&FServe::Catalog::WorkerClient::open3;
    no warnings 'redefine';
    local *FServe::Catalog::WorkerClient::open3 = sub {
        $late_pid = $original->(@_);
        return $late_pid;
    };
    start_child('sleep 60;', sub {
        my ($status, $stderr, $failure) = @_;
        $late_done++;
        $late_failure = $failure;
    });
    $throw_schedule = 1;
    fire_one_timer();
    $throw_schedule = 0;
}
is $late_done, 1, 'later timer failure notifies the completion callback once';
like $late_failure, qr/injected timer registration failure/,
    'later timer failure is reported to the completion callback';
is active_jobs(), 0, 'later timer failure removes its job';
is waitpid($late_pid, WNOHANG), -1, 'later timer failure reaps its child';

my ($cancel_pid, $cancel_done, $cancel_failure, $cancelled_flag);
{
    my $original = \&FServe::Catalog::WorkerClient::open3;
    no warnings 'redefine';
    local *FServe::Catalog::WorkerClient::open3 = sub {
        $cancel_pid = $original->(@_);
        return $cancel_pid;
    };
    my $cancel_job_id = start_child('sleep 60;', sub {
        my ($status, $stderr, $failure, $was_cancelled) = @_;
        $cancel_done++;
        $cancel_failure = $failure;
        $cancelled_flag = $was_cancelled;
    });
    is cancel_job($cancel_job_id), 1, 'cancel_job requests termination of a live worker';
    my $cancel_deadline = time + 5;
    while (!$cancel_done && time < $cancel_deadline) {
        sleep 0.01;
        fire_one_timer();
    }
    FServe::Catalog::WorkerClient::shutdown() unless $cancel_done;
}
is $cancel_done, 1, 'cancelled worker completes through its poll callback';
is $cancel_failure, 'catalog worker was cancelled', 'cancellation reason reaches on_done';
is $cancelled_flag, 1, 'on_done marks the worker as cancelled';
is active_jobs(), 0, 'cancelled worker is removed';
is waitpid($cancel_pid, WNOHANG), -1, 'cancelled worker process is reaped';

my ($published_job_id, $published_done, $published_result,
    $published_failure, $published_cancelled);
$published_job_id = start_child(
    'local $|=1; print qq({"event":"result","status":"published"}\\n); sleep 60;',
    sub {
        my ($status, $stderr, $failure, $was_cancelled) = @_;
        $published_done++;
        $published_failure = $failure;
        $published_cancelled = $was_cancelled;
    },
    sub {
        ($published_result) = @_;
        cancel_job($published_job_id) if defined $published_job_id;
    },
);
my $published_deadline = time + 5;
while (!$published_done && time < $published_deadline) {
    sleep 0.01;
    fire_one_timer();
}
ok $published_done, 'worker completes when cancelled after emitting a result';
is $published_result, '{"event":"result","status":"published"}',
    'the committed result event reaches the application before cancellation';
is $published_failure, 'catalog worker was cancelled',
    'the client still reports cancellation separately from the result event';
is $published_cancelled, 1, 'late-cancel completion remains marked cancelled';
is active_jobs(), 0, 'late-cancelled worker is removed';

my $shutdown_pid;
{
    my $original = \&FServe::Catalog::WorkerClient::open3;
    no warnings 'redefine';
    local *FServe::Catalog::WorkerClient::open3 = sub {
        $shutdown_pid = $original->(@_);
        return $shutdown_pid;
    };
    start_child('sleep 60;');
}
is shutdown(), 1, 'shutdown stops pending jobs during script unload';
is active_jobs(), 0, 'shutdown clears all active jobs';
is waitpid($shutdown_pid, WNOHANG), -1, 'shutdown reaps the child process';
is scalar(@timers), 0, 'shutdown cancels the pending Irssi timer';
is $cancelled[-1], $next_handle - 1, 'shutdown invokes the injected timer cancellation callback';

done_testing();
