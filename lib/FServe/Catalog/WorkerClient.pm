package FServe::Catalog::WorkerClient;

use strict;
use warnings;

use Exporter qw(import);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IPC::Open3 qw(open3);
use IO::Select;
use POSIX qw(WNOHANG);
use Symbol qw(gensym);
use Time::HiRes qw(time);

our @EXPORT_OK = qw(run_async cancel_job active_jobs wait_for_job shutdown);

my %JOBS;
my $NEXT_ID = 0;
my $MAX_LINE = 1_048_576;
my $MAX_STDERR = 65_536;

sub active_jobs { return scalar keys %JOBS; }

sub wait_for_job {
    my ($id, $timeout_ms) = @_;
    die 'worker wait timeout must be positive'
        unless defined($timeout_ms) && $timeout_ms =~ /^\d+$/ && $timeout_ms > 0;
    my $deadline = time + $timeout_ms / 1000;
    while (my $job = $JOBS{$id}) {
        _cancel_timer($job);
        _poll($job, 0);
        return 1 unless $JOBS{$id};
        if (time >= $deadline) {
            _stop_jobs([$job], 'catalog worker drain timed out', 1);
            return 0;
        }
        select undef, undef, undef, 0.01;
    }
    return 1;
}

sub run_async {
    my (%args) = @_;
    die 'worker command must be a non-empty argument list'
        unless ref($args{command}) eq 'ARRAY' && @{$args{command}};
    die 'worker completion callback is required'
        unless ref($args{on_done}) eq 'CODE';
    die 'worker timer scheduler and cancellation callbacks are required'
        unless ref($args{schedule_timer}) eq 'CODE' && ref($args{cancel_timer}) eq 'CODE';
    my $timeout_ms = $args{timeout_ms} // 10_000;
    die 'worker timeout must be positive' unless $timeout_ms =~ /^\d+$/ && $timeout_ms > 0;

    my ($child_in, $child_out);
    my $child_err = gensym();
    my $pid = eval { open3($child_in, $child_out, $child_err, @{$args{command}}) };
    die "could not start catalog worker: $@" unless $pid;
    close $child_in or do {
        kill 'TERM', $pid;
        waitpid($pid, 0);
        die "could not close catalog worker input: $!";
    };
    binmode $child_out, ':raw';
    binmode $child_err, ':raw';
    for my $fh ($child_out, $child_err) {
        my $flags = fcntl($fh, F_GETFL, 0);
        unless (defined($flags) && fcntl($fh, F_SETFL, $flags | O_NONBLOCK)) {
            kill 'TERM', $pid;
            waitpid($pid, 0);
            close $child_out;
            close $child_err;
            die "could not make catalog worker pipe nonblocking: $!";
        }
    }

    my $id = ++$NEXT_ID;
    my $job = {
        id => $id,
        pid => $pid,
        out => $child_out,
        err => $child_err,
        select => IO::Select->new($child_out, $child_err),
        stdout_buffer => '',
        stderr => '',
        on_event => $args{on_event},
        on_done => $args{on_done},
        schedule_timer => $args{schedule_timer},
        cancel_timer => $args{cancel_timer},
        started => time,
        timeout_seconds => $timeout_ms / 1000,
        cancelled => 0,
        reaped => 0,
        status => undef,
    };
    $JOBS{$id} = $job;
    my $scheduled = eval {
        _schedule_poll($job, 10);
        1;
    };
    unless ($scheduled) {
        my $error = $@ || 'could not schedule catalog worker polling';
        _stop_jobs([$job], $error, 0);
        die "could not schedule catalog worker polling: $error";
    }
    return $id;
}

sub _schedule_poll {
    my ($job, $delay) = @_;
    return unless $JOBS{$job->{id}};
    $delay = 10 if !defined($delay) || $delay < 10;
    my $timer = $job->{schedule_timer}->($delay, sub {
        delete $job->{timer};
        _poll($job);
    });
    die 'Irssi did not register the catalog worker timer' unless
        defined($timer) && !ref($timer) && $timer =~ /\A[1-9][0-9]*\z/;
    $job->{timer} = $timer;
}

sub _cancel_timer {
    my ($job) = @_;
    my $timer = delete $job->{timer};
    return unless defined $timer;
    eval { $job->{cancel_timer}->($timer); };
}

sub _stop_jobs {
    my ($jobs, $reason, $notify) = @_;
    for my $job (@$jobs) {
        _cancel_timer($job);
        $job->{cancelled} = 1;
        $job->{failure} ||= $reason;
        kill 'TERM', $job->{pid} unless $job->{reaped};
    }

    my %remaining = map { $_->{pid} => $_ } grep { !$_->{reaped} } @$jobs;
    my $deadline = time + 3;
    while (%remaining && time < $deadline) {
        for my $pid (keys %remaining) {
            my $result = waitpid($pid, WNOHANG);
            if ($result == $pid || $result == -1) {
                my $job = delete $remaining{$pid};
                $job->{reaped} = 1;
                $job->{status} = $result == $pid ? $? : (255 << 8);
            }
        }
        select undef, undef, undef, 0.025 if %remaining;
    }
    for my $pid (keys %remaining) {
        my $job = delete $remaining{$pid};
        kill 'KILL', $pid;
        waitpid($pid, 0);
        $job->{reaped} = 1;
        $job->{status} = $?;
    }

    for my $job (@$jobs) {
        delete $JOBS{$job->{id}};
        close $job->{out} if defined fileno($job->{out});
        close $job->{err} if defined fileno($job->{err});
        if ($notify && $job->{on_done}) {
            $job->{on_done}->($job->{status} // (255 << 8), $job->{stderr},
                              $job->{failure}, $job->{cancelled});
        }
    }
    return scalar @$jobs;
}

sub shutdown {
    my @jobs = values %JOBS;
    return _stop_jobs(\@jobs, 'catalog worker client is shutting down', 0);
}

sub _read_pipe {
    my ($job, $fh) = @_;
    while (1) {
        my $read = sysread($fh, my $chunk, 65_536);
        if (!defined $read) {
            next if $!{EINTR};
            return if $!{EAGAIN} || $!{EWOULDBLOCK};
            return "catalog worker pipe read failed: $!";
        }
        if ($read == 0) {
            my $fd = fileno($fh);
            my $is_out = defined($fd) && defined(fileno($job->{out})) &&
                $fd == fileno($job->{out});
            $job->{select}->remove($fh);
            close $fh;
            $job->{out_eof} = 1 if $is_out;
            $job->{err_eof} = 1 unless $is_out;
            return;
        }
        my $fd = fileno($fh);
        my $out_fd = fileno($job->{out});
        if (defined($fd) && defined($out_fd) && $fd == $out_fd) {
            $job->{stdout_buffer} .= $chunk;
            while ((my $newline = index($job->{stdout_buffer}, "\n")) >= 0) {
                my $line = substr($job->{stdout_buffer}, 0, $newline, '');
                substr($job->{stdout_buffer}, 0, 1, '');
                if (length($line) > $MAX_LINE) {
                    return 'catalog worker sent an oversized response line';
                }
                if (my $callback = $job->{on_event}) {
                    my $ok = eval { $callback->($line); 1 };
                    return "catalog worker response callback failed: $@" unless $ok;
                }
            }
            return 'catalog worker response line exceeded the size limit'
                if length($job->{stdout_buffer}) > $MAX_LINE;
        } else {
            $job->{stderr} .= $chunk;
            return 'catalog worker diagnostic exceeded the size limit'
                if length($job->{stderr}) > $MAX_STDERR;
        }
    }
}

sub _poll {
    my ($job, $reschedule) = @_;
    return unless $JOBS{$job->{id}};
    if (!$job->{cancelled} && time - $job->{started} > $job->{timeout_seconds}) {
        $job->{cancelled} = 1;
        $job->{failure} = 'catalog worker timed out';
        kill 'TERM', $job->{pid};
    }
    for my $fh ($job->{select}->can_read(0)) {
        if (my $error = _read_pipe($job, $fh)) {
            $job->{failure} = $error;
            kill 'TERM', $job->{pid};
        }
    }
    if (!$job->{reaped}) {
        my $result = waitpid($job->{pid}, WNOHANG);
        if ($result == $job->{pid}) {
            $job->{reaped} = 1;
            $job->{status} = $?;
        } elsif ($result == -1) {
            $job->{reaped} = 1;
            $job->{status} = 255 << 8;
        }
    }
    if ($job->{reaped} && $job->{out_eof} && $job->{err_eof}) {
        delete $JOBS{$job->{id}};
        my $status = $job->{status};
        $status = 255 << 8 if $job->{failure};
        $job->{on_done}->($status, $job->{stderr}, $job->{failure}, $job->{cancelled});
        return;
    }
    return if defined($reschedule) && !$reschedule;
    my $scheduled = eval { _schedule_poll($job, 50); 1 };
    _stop_jobs([$job], $@ || 'could not schedule catalog worker polling', 1)
        unless $scheduled;
}

sub cancel_job {
    my ($id) = @_;
    my $job = $JOBS{$id} or return 0;
    $job->{cancelled} = 1;
    $job->{failure} = 'catalog worker was cancelled';
    kill 'TERM', $job->{pid};
    return 1;
}

1;
