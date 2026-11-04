use strict;
use warnings;
use Errno ();
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM SOL_SOCKET SO_SNDBUF);
use Test::More;

use lib "$Bin/fixtures/bridge_irssi_stub";
use lib "$Bin/../lib";
use FServe::Bridge::Unix;
use JSON::PP ();

my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/engine.sock";

sub new_bridge {
    my (%args) = @_;
    return FServe::Bridge::Unix->new(
        path => $path,
        on_request => sub { return {} },
        input_add => $args{input_add},
        input_remove => sub { return 1 },
        timeout_add_once => sub { return 100 + int(rand(1000)) },
        timeout_remove => sub { return 1 },
    );
}

my $bridge = new_bridge(input_add => sub { return undef });
like $bridge->instance_id(), qr/\A[a-f0-9]{32}\z/,
    'constructor creates a nonempty engine identity';
is $bridge->event_sequence(), 0, 'constructor initializes event cursor to zero';
is_deeply $bridge->{request_cache}, {}, 'constructor initializes empty request cache';
is_deeply $bridge->{request_order}, [], 'constructor initializes empty request order';
is $bridge->{closed}, 0, 'constructor leaves bridge open';

my $failed = eval { $bridge->start(); 1 };
ok !$failed, 'failed listener callback registration aborts startup';
like $@, qr/refused the bridge listener callback/,
    'registration failure reports a clear startup error';
ok !-e $path, 'failed listener registration removes its owned socket';

my @registrations;
my $input_count = 0;
$bridge = new_bridge(input_add => sub {
    my ($fd, $condition, $callback, $data) = @_;
    $input_count++;
    return undef if $input_count == 2;
    push @registrations, [$fd, $condition, $callback, $data];
    return $input_count;
});
ok $bridge->start(), 'listener starts when callback registration succeeds';
my $client = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path);
ok $client, 'test controller connects to listener';
$registrations[0][2]->();
ok !defined($bridge->{client}), 'failed client read registration closes controller';
ok -S $path, 'read registration failure leaves listener available';
close $client;

my $competitor = new_bridge(input_add => sub { return 300 + int(rand(1000)) });
my $competing_start = eval { $competitor->start(); 1 };
ok !$competing_start, 'a second bridge cannot acquire an owned socket';
like $@, qr/another engine bridge already owns/,
    'second bridge receives the lock ownership refusal';
$bridge->stop();
ok !-e $path, 'stop removes the socket owned by the first bridge';

my $recovery = new_bridge(input_add => sub { return 200 + int(rand(1000)) });
ok $recovery->start(), 'another bridge can acquire the released socket lock';
ok -S $path, 'recovered bridge owns a live socket';
$recovery->stop();
ok !-e $path, 'recovered bridge removes its owned socket on stop';

sub observed_bridge {
    my (%args) = @_;
    my (@inputs, @timers);
    my ($input_id, $timer_id, $timer_calls) = (0, 0, 0);
    my $bridge = FServe::Bridge::Unix->new(
        path => $args{path},
        on_request => $args{on_request} || sub { return {} },
        input_add => sub {
            my ($fd, $condition, $callback) = @_;
            my $handle = ++$input_id;
            push @inputs, { handle => $handle, condition => $condition,
                callback => $callback, active => 1 };
            return $handle;
        },
        input_remove => sub {
            my ($handle) = @_;
            $_->{active} = 0 for grep { $_->{handle} == $handle } @inputs;
            return 1;
        },
        timeout_add_once => sub {
            my ($delay, $callback) = @_;
            $timer_calls++;
            return undef if defined($args{fail_timer_call}) &&
                $timer_calls == $args{fail_timer_call};
            my $handle = ++$timer_id;
            push @timers, { handle => $handle, callback => $callback, active => 1 };
            return $handle;
        },
        timeout_remove => sub {
            my ($handle) = @_;
            $_->{active} = 0 for grep { $_->{handle} == $handle } @timers;
            return 1;
        },
    );
    return ($bridge, \@inputs, \@timers);
}

sub latest_input {
    my ($inputs, $condition) = @_;
    for my $entry (reverse @$inputs) {
        return $entry if $entry->{active} && $entry->{condition} == $condition;
    }
    die "no active input callback for condition $condition";
}

sub fire_drain_timer {
    my ($bridge, $timers) = @_;
    my $handle = $bridge->{drain_timer};
    my ($entry) = grep { $_->{active} && $_->{handle} == $handle } @$timers;
    die 'no active callback for pending drain timer' unless $entry;
    $entry->{active} = 0;
    $entry->{callback}->();
}

sub wire_request {
    my ($id, $operation, $arguments) = @_;
    return JSON::PP->new->canonical(1)->encode({
        protocol_version => 1, request_id => $id,
        operation => $operation, arguments => $arguments || {},
    }) . "\n";
}

sub send_wire {
    my ($socket, $payload) = @_;
    my $written = syswrite($socket, $payload);
    die "short controller write: " . (defined($written) ? $written : $!)
        unless defined($written) && $written == length($payload);
}

# Drive the production callbacks explicitly so the callback budget and timer
# continuation are assertions rather than conclusions drawn from elapsed time.
my $drain_path = "$directory/drain.sock";
my $drained = 0;
my ($drain_bridge, $drain_inputs, $drain_timers) = observed_bridge(
    path => $drain_path,
    on_request => sub { $drained++; return {} },
);
ok $drain_bridge->start(), 'bounded-drain listener starts';
my $drain_peer = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $drain_path);
ok $drain_peer, 'bounded-drain controller connects';
latest_input($drain_inputs, Irssi::INPUT_READ)->{callback}->();
send_wire($drain_peer, wire_request('hello-drain', 'hello', {}));
latest_input($drain_inputs, Irssi::INPUT_READ)->{callback}->();
send_wire($drain_peer,
    join '', map { wire_request("drain-$_", 'status', {}) } 1 .. 9);
latest_input($drain_inputs, Irssi::INPUT_READ)->{callback}->();
is $drained, 4, 'one read callback handles no more than four buffered requests';
ok defined($drain_bridge->{drain_timer}),
    'remaining buffered requests schedule a drain continuation';
if (defined $drain_bridge->{drain_timer}) {
    fire_drain_timer($drain_bridge, $drain_timers);
    is $drained, 8, 'one drain callback handles at most four more requests';
    ok defined($drain_bridge->{drain_timer}),
        'drain continuation remains scheduled while requests remain';
    if (defined $drain_bridge->{drain_timer}) {
        fire_drain_timer($drain_bridge, $drain_timers);
        is $drained, 9, 'later drain callback completes the remaining request';
        ok !defined($drain_bridge->{drain_timer}),
            'drain timer is cleared after buffered requests are exhausted';
    } else {
        diag 'drain stopped before the remaining request was handled';
    }
} else {
    diag 'all buffered requests were handled in the first callback';
}
$drain_bridge->stop();
close $drain_peer;

# If a drain continuation cannot be registered, clear client state and retain
# the listener so a later controller can still connect.
my $failed_drain_path = "$directory/failed-drain.sock";
my $failed_drain_calls = 0;
my ($failed_drain_bridge, $failed_drain_inputs) = observed_bridge(
    path => $failed_drain_path,
    fail_timer_call => 2, # handshake timer succeeds; the drain timer fails
    on_request => sub { $failed_drain_calls++; return {} },
);
ok $failed_drain_bridge->start(), 'failed-drain listener starts';
my $failed_drain_peer = IO::Socket::UNIX->new(
    Type => SOCK_STREAM, Peer => $failed_drain_path);
ok $failed_drain_peer, 'failed-drain controller connects';
latest_input($failed_drain_inputs, Irssi::INPUT_READ)->{callback}->();
send_wire($failed_drain_peer,
    wire_request('hello-failed-drain', 'hello', {}));
latest_input($failed_drain_inputs, Irssi::INPUT_READ)->{callback}->();
send_wire($failed_drain_peer,
    join '', map { wire_request("failed-drain-$_", 'status', {}) } 1 .. 9);
latest_input($failed_drain_inputs, Irssi::INPUT_READ)->{callback}->();
is $failed_drain_calls, 4, 'failed continuation follows the bounded request batch';
ok !defined($failed_drain_bridge->{client}),
    'failed drain-timer registration closes the controller';
ok -S $failed_drain_path,
    'failed drain-timer registration preserves the bridge listener';
ok !exists($failed_drain_bridge->{client_buffer}),
    'failed drain-timer registration clears pending input';
$failed_drain_bridge->stop();
close $failed_drain_peer;

# Keep a controller connected without reading so a write callback has more
# data available than its per-turn budget can send.
my $write_path = "$directory/write-budget.sock";
my ($write_bridge, $write_inputs) = observed_bridge(
    path => $write_path,
    on_request => sub { return { payload => 'x' x 50000 } },
);
ok $write_bridge->start(), 'write-budget listener starts';
my $write_peer = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $write_path);
ok $write_peer, 'write-budget controller connects and does not read';
latest_input($write_inputs, Irssi::INPUT_READ)->{callback}->();
setsockopt($write_bridge->{client}, SOL_SOCKET, SO_SNDBUF, pack('i', 262144))
    or die "cannot enlarge test socket send buffer: $!";
send_wire($write_peer, wire_request('hello-write', 'hello', {}));
latest_input($write_inputs, Irssi::INPUT_READ)->{callback}->();
send_wire($write_peer, join '',
    wire_request('write-1', 'status', {}),
    wire_request('write-2', 'status', {}));
latest_input($write_inputs, Irssi::INPUT_READ)->{callback}->();
my $bytes_before_write = $write_bridge->{output_bytes};
latest_input($write_inputs, Irssi::INPUT_WRITE)->{callback}->();
my $bytes_after_write = $write_bridge->{output_bytes};
cmp_ok $bytes_before_write - $bytes_after_write, '<=', 16 * 1024,
    'one write callback never writes more than its 16-KiB budget';
ok $bytes_after_write > 0,
    'stalled controller leaves output queued after one bounded write callback';
$write_bridge->stop();
close $write_peer;

# Reduce the kernel send buffer to force EAGAIN from a still-connected peer
# that never reads, then fill the bounded user-space output queue.
my $slow_path = "$directory/slow-reader.sock";
my ($slow_bridge, $slow_inputs, $slow_timers) = observed_bridge(
    path => $slow_path,
    on_request => sub { return { payload => 'x' x 50000 } },
);
ok $slow_bridge->start(), 'slow-reader listener starts';
my $slow_peer = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $slow_path);
ok $slow_peer, 'slow-reader controller connects and does not consume output';
latest_input($slow_inputs, Irssi::INPUT_READ)->{callback}->();
setsockopt($slow_bridge->{client}, SOL_SOCKET, SO_SNDBUF, pack('i', 4096))
    or die "cannot constrain test socket send buffer: $!";
send_wire($slow_peer, wire_request('hello-slow', 'hello', {}));
latest_input($slow_inputs, Irssi::INPUT_READ)->{callback}->();
send_wire($slow_peer, wire_request('slow-fill', 'status', {}));
latest_input($slow_inputs, Irssi::INPUT_READ)->{callback}->();
my $stalled_write_observed = 0;
for (1 .. 8) {
    my $before = $slow_bridge->{output_bytes};
    last unless defined $before;
    latest_input($slow_inputs, Irssi::INPUT_WRITE)->{callback}->();
    my $after = $slow_bridge->{output_bytes};
    if (defined($after) && $after == $before) {
        $stalled_write_observed = 1;
        last;
    }
}
ok $stalled_write_observed,
    'nonblocking writes return on a full socket with output still queued';
ok $slow_bridge->{client} && $slow_bridge->{output_bytes} > 0,
    'full socket retains the connected slow reader and pending output';
send_wire($slow_peer,
    join '', map { wire_request("slow-$_", 'status', {}) } 1 .. 30);
latest_input($slow_inputs, Irssi::INPUT_READ)->{callback}->();
while ($slow_bridge->{client} && defined $slow_bridge->{drain_timer}) {
    fire_drain_timer($slow_bridge, $slow_timers);
}
ok !defined($slow_bridge->{client}),
    'pending-output limit closes a controller that cannot keep up';
ok !exists($slow_bridge->{output_queue}) &&
    !exists($slow_bridge->{output_bytes}),
    'slow-reader closure clears its output queue and accounting';
ok -S $slow_path, 'slow-reader closure leaves the listener available';
close $slow_peer;
my $slow_recovery = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $slow_path);
ok $slow_recovery, 'listener accepts a replacement after slow-reader closure';
latest_input($slow_inputs, Irssi::INPUT_READ)->{callback}->();
ok $slow_bridge->{client}, 'replacement controller becomes the active client';
$slow_bridge->stop();
close $slow_recovery;

# Status polling must not evict the acknowledgements that protect a mutation
# from a lost reply: only requests carrying an operation ID are remembered.
my $cache_path = "$directory/cache.sock";
my $cache_calls = 0;
my ($cache_bridge, $cache_inputs) = observed_bridge(
    path => $cache_path,
    on_request => sub { $cache_calls++; return {} },
);
ok $cache_bridge->start(), 'reply-cache listener starts';
my $cache_peer = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $cache_path);
ok $cache_peer, 'reply-cache controller connects';
latest_input($cache_inputs, Irssi::INPUT_READ)->{callback}->();
my $mutation = JSON::PP->new->canonical(1)->encode({
    protocol_version => 1, request_id => 'cache-mutation',
    operation => 'job.cancel', operation_id => 'cache-operation',
    arguments => { job_id => 'fixture' },
}) . "
";
for my $payload (wire_request('hello-cache', 'hello', {}), $mutation,
        wire_request('cache-read', 'status', {}),
        wire_request('cache-read', 'status', {}), $mutation) {
    send_wire($cache_peer, $payload);
    latest_input($cache_inputs, Irssi::INPUT_READ)->{callback}->();
}
is $cache_calls, 3, 'read-only requests run again while a repeated operation is replayed';
is_deeply [sort keys %{$cache_bridge->{request_cache}}], ['operation:cache-operation'],
    'only the operation-bearing request is cached';
$cache_bridge->stop();
close $cache_peer;

# Every reply the controller has written so far, decoded.
sub replies {
    my ($bridge, $inputs, $peer) = @_;
    while ($bridge->{client} && @{$bridge->{output_queue} || []}) {
        latest_input($inputs, Irssi::INPUT_WRITE)->{callback}->();
    }
    my $text = '';
    while (1) {
        my $ready = '';
        vec($ready, fileno($peer), 1) = 1;
        last unless select($ready, undef, undef, 0.2);
        my $read = sysread($peer, my $chunk, 65536);
        last unless $read;
        $text .= $chunk;
    }
    return map { JSON::PP->new->decode($_) } split /\n/, $text;
}

# A reply too large for one frame is refused, and the controller stays
# connected; before, the connection was closed and the controller, asking
# for status first on each new connection, could not get back in.
local $SIG{PIPE} = 'IGNORE';   # a closed connection fails the checks, not the script
my $large_path = "$directory/large.sock";
my ($large_bridge, $large_inputs) = observed_bridge(
    path => $large_path,
    on_request => sub { return $_[0] eq 'status' ? { payload => 'x' x 70000 } : { small => 1 } },
);
ok $large_bridge->start(), 'large-reply listener starts';
my $large_peer = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $large_path);
latest_input($large_inputs, Irssi::INPUT_READ)->{callback}->();
for my $payload (wire_request('hello-large', 'hello', {}),
        wire_request('large-1', 'status', {}), wire_request('large-2', 'job.status', {})) {
    send_wire($large_peer, $payload);
    latest_input($large_inputs, Irssi::INPUT_READ)->{callback}->();
}
ok $large_bridge->{client}, 'a reply too large for one frame leaves the controller connected';
my (undef, $refused, $after) = replies($large_bridge, $large_inputs, $large_peer);
is $refused->{request_id}, 'large-1', 'the oversized reply is answered';
ok !$refused->{ok} && $refused->{error}{code} eq 'response_too_large',
    'with a refusal that says why';
ok $after->{ok} && $after->{result}{small}, 'the next request is answered as usual';
$large_bridge->stop();
close $large_peer;

# A request refused because it came before hello did nothing, so the same
# request after hello runs rather than being answered from the cache.
my $early_path = "$directory/early.sock";
my $early_calls = 0;
my ($early_bridge, $early_inputs) = observed_bridge(
    path => $early_path,
    on_request => sub { $early_calls++; return {} },
);
ok $early_bridge->start(), 'early-request listener starts';
my $early_peer = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $early_path);
latest_input($early_inputs, Irssi::INPUT_READ)->{callback}->();
my $early = JSON::PP->new->canonical(1)->encode({
    protocol_version => 1, request_id => 'early-mutation',
    operation => 'job.cancel', operation_id => 'early-operation',
    arguments => { job_id => 'fixture' },
}) . "\n";
for my $payload ($early, wire_request('hello-early', 'hello', {}), $early) {
    send_wire($early_peer, $payload);
    latest_input($early_inputs, Irssi::INPUT_READ)->{callback}->();
}
my ($before_hello, undef, $after_hello) = replies($early_bridge, $early_inputs, $early_peer);
is $before_hello->{error}{code}, 'handshake_required', 'a mutation before hello is refused';
ok $after_hello->{ok} && !$after_hello->{replayed}, 'the same mutation after hello runs';
is $early_calls, 1, 'and reaches the engine once';
$early_bridge->stop();
close $early_peer;

# Accepting can fail for want of a file descriptor. The connection already
# open is not at fault and stays; listening pauses, and resumes later,
# rather than failing again on every turn of the main loop.
{
    package FailingListener;
    sub new { return bless {}, shift }
    sub accept { $! = Errno::EMFILE(); return }
}
my $accept_path = "$directory/accept.sock";
my ($accept_bridge, $accept_inputs, $accept_timers) = observed_bridge(path => $accept_path);
ok $accept_bridge->start(), 'accept-failure listener starts';
my $listening = latest_input($accept_inputs, Irssi::INPUT_READ);
my $accept_peer = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $accept_path);
$listening->{callback}->();
my $connected = $accept_bridge->{client};
ok $connected, 'the first controller is connected';
my $listener = $accept_bridge->{listener};
$accept_bridge->{listener} = FailingListener->new();
my $waiting = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $accept_path);
$listening->{callback}->();
is $accept_bridge->{client}, $connected, 'a failed accept leaves the open controller connected';
ok !$listening->{active}, 'listening pauses';
my ($retry) = grep { $_->{active} && $_->{handle} == ($accept_bridge->{accept_retry_timer} // -1) }
    @$accept_timers;
ok $retry, 'and is resumed from a timer';
$accept_bridge->{listener} = $listener;
if ($retry) {
    $retry->{active} = 0;
    $retry->{callback}->();
}
my $resumed = latest_input($accept_inputs, Irssi::INPUT_READ);
isnt $resumed->{handle}, $listening->{handle}, 'listening resumes';
$accept_bridge->stop();
close $_ for $accept_peer, $waiting;

done_testing();
