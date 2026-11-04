# The outbound scheduler: every line the engine sends to IRC, spaced and owned.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;

our (%JOBS, $PROCESS_INCARNATION);

sub outbound_scheduler { return $JOBS{scheduler}; }

sub finish_outbound_message {
    my ($token, $status, $reason) = @_;
    my $task = delete $JOBS{outbound_messages}{$token} or return;
    Irssi::timeout_remove($task->{timer}) if defined $task->{timer};
    my $clear_callbacks = delete $task->{clear_callbacks};
    eval { $clear_callbacks->() } if ref($clear_callbacks) eq 'CODE';
    delete @{$task}{qw(arm_timer fire)};
    my $callback = $task->{on_done};
    eval { $callback->($status, $reason) } if ref($callback) eq 'CODE';
}

sub withdraw_pending_outbound_messages {
    my ($reason) = @_;
    my @tokens = keys %{$JOBS{outbound_messages} || {}};
    for my $token (@tokens) {
        my $task = $JOBS{outbound_messages}{$token} or next;
        $JOBS{scheduler}->cancel($task->{reservation}{token})
            if $JOBS{scheduler} && $task->{reservation};
        my $status = $task->{attempted}
            ? 'dispatch_outcome_unknown' : 'refused';
        finish_outbound_message($token, $status,
            $reason // 'durable journal is unhealthy');
    }
    return scalar @tokens;
}

sub cancel_outbound_message {
    my ($token, $reason) = @_;
    my $task = $JOBS{outbound_messages}{$token} or return 0;
    $JOBS{scheduler}->cancel($task->{reservation}{token})
        if $JOBS{scheduler} && $task->{reservation};
    my $status = $task->{attempted} ? 'dispatch_outcome_unknown'
        : (($reason // '') eq 'job queue paused before message dispatch'
            ? 'paused_before_send' : 'cancelled_before_send');
    finish_outbound_message($token, $status, $reason // 'outbound send cancelled');
    return 1;
}

sub cancel_outbound_for_connection {
    my ($identity, $epoch, $reason) = @_;
    return 0 unless defined $identity;
    my @tokens = grep {
        my $task = $JOBS{outbound_messages}{$_};
        ($task->{connection_identity} // '') eq $identity &&
            ($task->{connection_epoch} || 0) == ($epoch || 0)
    } keys %{$JOBS{outbound_messages} || {}};
    cancel_outbound_message($_, $reason // 'IRC connection ended') for @tokens;
    return scalar @tokens;
}

sub cancel_outbound_owner {
    my ($kind, $id, $reason) = @_;
    return 0 unless defined($kind) && defined($id);
    my @tokens = grep {
        my $task = $JOBS{outbound_messages}{$_};
        (($kind eq 'job' && ($task->{owner_job_id} // '') eq $id) ||
            (($task->{owner_kind} // '') eq $kind &&
                ($task->{owner_id} // '') eq $id))
    } keys %{$JOBS{outbound_messages} || {}};
    cancel_outbound_message($_, $reason // 'owning operation ended') for @tokens;
    return scalar @tokens;
}

sub cancel_all_outbound_messages {
    my ($reason) = @_;
    my @tokens = keys %{$JOBS{outbound_messages} || {}};
    cancel_outbound_message($_, $reason // 'script unloaded') for @tokens;
    return scalar @tokens;
}

sub outbound_route_key {
    my ($server, $target, $peer, $service) = @_;
    return unless ref($server) && defined($target) && length($target) &&
        defined($peer) && length($peer) && defined($service) && length($service);
    return unless load_job_modules();
    my $mapping = server_casemapping($server);
    return join("\x1f", server_connection_identity($server),
        FServe::ConnectionIdentity::irc_casefold($target, $mapping),
        FServe::ConnectionIdentity::irc_casefold($peer, $mapping),
        lc($service));
}

sub schedule_irc_message {
    my (%args) = @_;
    my $server = $args{server};
    my $kind = $args{kind} // 'message';
    return unless ref($server) && $server->{connected} &&
        ref($args{send}) eq 'CODE';
    return if ($kind eq 'query' || $kind eq 'trigger') &&
        (!defined($args{route}) || !length($args{route}));
    return unless jobs_ready();
    if (keys(%{$JOBS{outbound_messages} || {}}) >= 64) {
        p('Outbound scheduler is at its bounded pending-message capacity; refusing to queue another application message.');
        return;
    }

    my $identity = server_connection_identity($server);
    my $epoch = server_connection_epoch($server);
    my $reservation = eval {
        $JOBS{scheduler}->reserve(connection => $identity,
            kind => $kind, route => $args{route});
    };
    return unless $reservation;
    my $token = $reservation->{token};
    my $task = {
        token => $token, reservation => $reservation, server => $server,
        connection_identity => $identity, connection_epoch => $epoch,
        process_incarnation => $PROCESS_INCARNATION,
        owner_kind => $args{owner_kind}, owner_id => $args{owner_id},
        owner_job_id => $args{owner_job_id},
        guard => $args{guard}, before_send => $args{before_send},
        send => $args{send}, on_done => $args{on_done},
    };
    $JOBS{outbound_messages}{$token} = $task;

    my $arm_timer;
    my $fire;
    $arm_timer = sub {
        my ($delay) = @_;
        my $current = $JOBS{outbound_messages}{$token} or return 0;
        my $ms = timer_delay_ms($delay);
        my $handle = eval { Irssi::timeout_add_once($ms, $fire, undef) };
        unless (defined $handle) {
            $JOBS{scheduler}->cancel($reservation->{token});
            finish_outbound_message($token, 'failed',
                'Irssi could not schedule the bounded application-message reservation');
            return 0;
        }
        Irssi::test_mark_outbound_timer($handle)
            if Irssi->can('test_mark_outbound_timer');
        $current->{timer} = $handle;
        return 1;
    };
    $fire = sub {
        my $current = $JOBS{outbound_messages}{$token} or return;
        delete $current->{timer};
        unless ($JOBS{coordinator} &&
                $JOBS{coordinator}->journal->healthy) {
            withdraw_pending_outbound_messages(
                'durable journal ownership or write health failed before dispatch');
            return;
        }
        my $live = $current->{process_incarnation} eq $PROCESS_INCARNATION &&
            $current->{server} && $current->{server}{connected} &&
            server_connection_identity($current->{server}) eq $current->{connection_identity} &&
            server_connection_epoch($current->{server}) == $current->{connection_epoch};
        $live &&= eval { $current->{guard}->($current) ? 1 : 0 }
            if ref($current->{guard}) eq 'CODE';
        unless ($live) {
            $JOBS{scheduler}->cancel($reservation->{token});
            finish_outbound_message($token, 'stale',
                'captured connection or request context changed before message dispatch');
            return;
        }
        my $committed = eval { $JOBS{scheduler}->commit($reservation->{token}) };
        unless ($committed && ref($committed) eq 'HASH') {
            $JOBS{scheduler}->cancel($reservation->{token});
            finish_outbound_message($token, 'failed',
                'application-message rate reservation could not be committed');
            return;
        }
        unless ($committed->{committed}) {
            $arm_timer->($committed->{delay});
            return;
        }
        if (ref($current->{before_send}) eq 'CODE') {
            my $prepared = eval { $current->{before_send}->($current) };
            unless ($prepared) {
                my $why = $@ || 'pre-dispatch validation refused the message';
                $why =~ s/[\r\n]+/ /g;
                finish_outbound_message($token, 'refused', $why);
                return;
            }
        }
        $current->{attempted} = 1;
        my $sent = eval { $current->{send}->($current); 1 };
        my $error = $@;
        if (!$sent) {
            $error ||= 'native application-message send failed';
            $error =~ s/[\r\n]+/ /g;
        }
        finish_outbound_message($token, $sent ? 'sent' : 'failed', $sent ? undef : $error);
    };
    my $clear_callbacks = sub {
        $arm_timer = undef;
        $fire = undef;
    };
    $task->{arm_timer} = $arm_timer;
    $task->{fire} = $fire;
    $task->{clear_callbacks} = $clear_callbacks;

    if (($reservation->{delay} || 0) > 0) {
        $arm_timer->($reservation->{delay});
        return { status => 'pending', token => $token };
    }
    $fire->();
    return { status => exists($JOBS{outbound_messages}{$token}) ? 'pending' : 'complete',
        token => $token };
}

1;
