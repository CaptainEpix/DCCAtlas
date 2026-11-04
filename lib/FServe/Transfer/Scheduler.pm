package FServe::Transfer::Scheduler;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(default_limits);

sub default_limits {
    return {
        connection_message_ms => 2000,
        route_query_ms => 30000,
        chat_command_ms => 400,
        max_recovery_attempts => 2,
        recovery_backoff_ms => [5000, 15000],
        recovery_jitter_percent => 20,
        recovery_total_ms => 120000,
        transfer_stall_ms => 120000,
    };
}

sub new {
    my ($class, %args) = @_;
    return bless {
        now => $args{now} || sub { require Time::HiRes; Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) },
        limits => { %{default_limits()}, %{$args{limits} || {}} },
        last => {},
        reservations => {},
        generation => 0,
    }, $class;
}

sub _interval_for {
    my ($self, $kind) = @_;
    return $self->{limits}{chat_command_ms} / 1000 if $kind eq 'chat';
    return $self->{limits}{connection_message_ms} / 1000;
}

sub reserve {
    my ($self, %args) = @_;
    die 'connection identity is required' unless defined($args{connection}) && length($args{connection});
    my $kind = $args{kind} // 'message';
    my $now = $self->{now}->();
    my @scopes = (['connection:' . $args{connection}, _interval_for($self, $kind)]);
    if (($kind eq 'query' || $kind eq 'trigger') && defined($args{route}) && length($args{route})) {
        push @scopes, ['route:' . $args{route}, $self->{limits}{route_query_ms} / 1000];
    }
    my $due = $now;
    for my $scope (@scopes) {
        my $last = $self->{last}{$scope->[0]} // -1e30;
        for my $pending (values %{$self->{reservations}}) {
            for my $pending_scope (@{$pending->{scopes}}) {
                $last = $pending->{due} if $pending_scope->[0] eq $scope->[0] && $pending->{due} > $last;
            }
        }
        my $ready = $last + $scope->[1];
        $due = $ready if $ready > $due;
    }
    my $token = 'sched-' . ++$self->{generation};
    $self->{reservations}{$token} = { token => $token, due => $due, scopes => \@scopes, generation => $self->{generation} };
    return { token => $token, due => $due, delay => ($due > $now ? $due - $now : 0) };
}

sub commit {
    my ($self, $token) = @_;
    my $reservation = $self->{reservations}{$token};
    die 'unknown or cancelled scheduler reservation' unless $reservation;
    my $now = $self->{now}->();
    die 'scheduler reservation fired before its rate deadline' if $now + 1e-6 < $reservation->{due};
    my $actual_due = $reservation->{due};
    for my $scope (@{$reservation->{scopes}}) {
        my $last = $self->{last}{$scope->[0]};
        my $budget_due = defined($last) ? $last + $scope->[1] : -1e30;
        $actual_due = $budget_due if $budget_due > $actual_due;
    }
    if ($now + 1e-6 < $actual_due) {
        $reservation->{due} = $actual_due;
        return { committed => 0, token => $token, due => $actual_due,
            delay => $actual_due - $now };
    }
    delete $self->{reservations}{$token};
    $self->{last}{$_->[0]} = $now for @{$reservation->{scopes}};
    return { committed => 1, token => $token, at => $now, due => $now, delay => 0 };
}

sub cancel {
    my ($self, $token) = @_;
    return delete($self->{reservations}{$token}) ? 1 : 0;
}

sub pending_count { return scalar keys %{$_[0]{reservations}}; }
sub limits { return { %{$_[0]{limits}} }; }

1;
