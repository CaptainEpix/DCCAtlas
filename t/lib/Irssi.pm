package Irssi;
use strict;
use warnings;
use File::Spec;

our (%SETTINGS, %SETTING_TYPES, %SIGNALS, %COMMANDS, @GLOBAL_COMMANDS, @PRINTS, @TIMERS,
    %ACTIVE_CHAT_BY_NICK);
our $SIGNAL_STOPPED = 0;
our $NEXT_TIMER_HANDLE = 1;
our $NEXT_DCC_LIFECYCLE = 1;
our $NEXT_SERVER_NATIVE_HANDLE = 1;
our $MOCK_MONOTONIC = 0;
our %OUTBOUND_TIMERS;
our $AUTO_DRAIN_OUTBOUND_ON_COMMAND = 1;

sub import {}
# Message levels, as the real module exports them; the values only need to
# be distinct bits here.
sub MSGLEVEL_CRAP { 0x1 }
sub MSGLEVEL_MSGS { 0x2 }
sub MSGLEVEL_PUBLIC { 0x4 }
sub MSGLEVEL_DCC { 0x10000 }
sub MSGLEVEL_CLIENTNOTICE { 0x40000 }
sub MSGLEVEL_CLIENTCRAP { 0x80000 }
sub MSGLEVEL_CLIENTERROR { 0x100000 }
sub settings_add_int { my ($section,$key,$def)=@_; $SETTINGS{$key}=$def unless exists $SETTINGS{$key}; $SETTING_TYPES{$key}='int'; }
sub settings_add_str { my ($section,$key,$def)=@_; $SETTINGS{$key}=$def unless exists $SETTINGS{$key}; $SETTING_TYPES{$key}='str'; }
sub settings_add_bool { my ($section,$key,$def)=@_; $SETTINGS{$key}=$def ? 1 : 0 unless exists $SETTINGS{$key}; $SETTING_TYPES{$key}='bool'; }
sub settings_get_int { my ($key)=@_; return 0 if ($SETTING_TYPES{$key} // '') eq 'bool'; return int($SETTINGS{$key} // 0); }
sub settings_get_bool { my ($key)=@_; return $SETTINGS{$key} ? 1 : 0; }
sub settings_get_str { my ($key)=@_; return defined($SETTINGS{$key}) ? $SETTINGS{$key} : ''; }
sub settings_set_str { my ($key,$v)=@_; $SETTINGS{$key}=$v; }
sub settings_set_bool { my ($key,$v)=@_; $SETTINGS{$key}=$v ? 1 : 0; $SETTING_TYPES{$key}='bool'; }
sub get_irssi_dir {
    return $ENV{IRSSI_TEST_DIR} if defined $ENV{IRSSI_TEST_DIR};
    # Durable Phase 6 state must be isolated per test process; a fixed mock
    # home leaks journal reservations between unrelated prove files.
    return File::Spec->catdir(File::Spec->tmpdir(), 'irssi-fserve-poc-test-' . $$);
}
sub print { push @PRINTS, $_[0]; }
sub command { push @GLOBAL_COMMANDS, $_[0]; }
sub command_bind { my ($name,$cb)=@_; $COMMANDS{$name}=$cb; }
sub signal_add { my ($name,$cb)=@_; push @{$SIGNALS{$name}}, $cb; }
sub signal_add_first { my ($name,$cb)=@_; unshift @{$SIGNALS{$name}}, $cb; }
sub signal_add_last { my ($name,$cb)=@_; push @{$SIGNALS{$name}}, $cb; }
sub signal_stop { $SIGNAL_STOPPED = 1; }
sub timeout_add_once {
    my ($ms,$cb,$data)=@_;
    die "Irssi::timeout_once() : msecs must be >= 10\n" unless defined($ms) && $ms >= 10;
    my $handle = $NEXT_TIMER_HANDLE++;
    push @TIMERS, [$cb,$data,$handle,0,0,$ms,$MOCK_MONOTONIC + $ms / 1000];
    return $handle;
}
sub test_monotonic_now { return $MOCK_MONOTONIC; }
sub test_mark_outbound_timer { $OUTBOUND_TIMERS{$_[0]} = 1 if defined $_[0]; }
sub test_run_outbound_timers {
    my $guard = 0;
    while (++$guard <= 1000) {
        my @due = sort {
            ($a->[6] // 0) <=> ($b->[6] // 0)
        } grep {
            $OUTBOUND_TIMERS{$_->[2]} && !$_->[3] && !$_->[4] &&
                defined($_->[6])
        } @TIMERS;
        last unless @due;
        fire_timer($due[0][2]);
    }
    die "outbound timer loop" if $guard > 1000;
}
sub timeout_remove {
    my ($handle)=@_;
    for my $timer (@TIMERS) {
        next unless $timer->[2] == $handle;
        $timer->[3] = 1;
        delete $OUTBOUND_TIMERS{$handle};
        return 1;
    }
    return 0;
}
sub timer_handles {
    return map { $_->[2] } grep { !$_->[3] && !$_->[4] } @TIMERS;
}
sub timer_record {
    my ($handle)=@_;
    for my $timer (@TIMERS) {
        return $timer if $timer->[2] == $handle;
    }
    return;
}
sub fire_timer {
    my ($handle,$include_cancelled)=@_;
    my $timer = timer_record($handle) or return 0;
    return 0 if $timer->[3] && !$include_cancelled;
    return 0 if $timer->[4] && !$include_cancelled;
    $timer->[4] = 1;
    $MOCK_MONOTONIC = $timer->[6]
        if defined($timer->[6]) && $timer->[6] > $MOCK_MONOTONIC;
    delete $OUTBOUND_TIMERS{$handle};
    $timer->[0]->($timer->[1]);
    return 1;
}
sub new_dcc_identity {
    my $id = $NEXT_DCC_LIFECYCLE++;
    return (
        created => 1_760_000_000 + $id,
        addr    => '127.0.0.1',
        port    => 10_000 + ($id % 50_000),
    );
}
sub server_find_tag { undef }

sub emit {
    my ($name,@args)=@_;
    test_run_outbound_timers() if $AUTO_DRAIN_OUTBOUND_ON_COMMAND;
    local $SIGNAL_STOPPED = 0;
    if ($name eq 'dcc request' && ref($args[0]) && uc($args[0]{type} // '') eq 'CHAT') {
        $ACTIVE_CHAT_BY_NICK{lc($args[0]{nick} // '')} = $args[0];
    }
    if ($name eq 'dcc closed' && ref($args[0]) && uc($args[0]{type} // '') eq 'CHAT') {
        my $key = lc($args[0]{nick} // '');
        delete $ACTIVE_CHAT_BY_NICK{$key}
            if $ACTIVE_CHAT_BY_NICK{$key} && $ACTIVE_CHAT_BY_NICK{$key} == $args[0];
    }
    for my $callback (@{$SIGNALS{$name} || []}) {
        $callback->(@args);
        last if $SIGNAL_STOPPED;
    }
    test_run_outbound_timers() if $AUTO_DRAIN_OUTBOUND_ON_COMMAND;
}
sub run_command {
    my ($name,$data,$server,$witem)=@_;
    die "unknown command $name" unless $COMMANDS{$name};
    $COMMANDS{$name}->($data,$server,$witem);
    test_run_outbound_timers() if $AUTO_DRAIN_OUTBOUND_ON_COMMAND;
}
sub run_timers {
    my $guard=0;
    while (@TIMERS) {
        die "timer loop" if ++$guard > 1000;
        my $timer = shift @TIMERS;
        next if $timer->[3] || $timer->[4];
        $timer->[4] = 1;
        $timer->[0]->($timer->[1]);
    }
}
sub clear_capture { @GLOBAL_COMMANDS=(); @PRINTS=(); @TIMERS=(); %ACTIVE_CHAT_BY_NICK=(); }

package MockDcc;
sub destroy {
    my ($self)=@_;
    $self->{destroyed}=1;
    Irssi::emit('dcc destroyed', $self);
}

package MockServer;
sub new {
    my ($class) = @_;
    return bless { connected=>1, tag=>'mocknet', _irssi=>$NEXT_SERVER_NATIVE_HANDLE++,
        commands=>[], raw_lines=>[], joined_channels=>{} }, $class;
}
sub new_wrapper { my ($self)=@_; return bless { %$self }, ref($self); }
sub command {
    my ($self,$cmd)=@_;
    push @{$self->{commands}}, $cmd;
    $self->{on_command}->($cmd) if ref($self->{on_command}) eq 'CODE';
}
sub send_raw {
    my ($self,$line)=@_;
    push @{$self->{raw_lines}}, $line;
    $self->{on_raw}->($line) if ref($self->{on_raw}) eq 'CODE';
    return 1;
}
sub channel_find {
    my ($self,$name)=@_;
    return unless $self->{joined_channels}{lc($name // '')};
    return { joined=>1, name=>$name };
}
sub nickcmp {
    my ($self,$a,$b)=@_;
    my $mapping = lc($self->{casemapping} // 'rfc1459');
    for ($a,$b) {
        tr/A-Z/a-z/;
        if ($mapping ne 'ascii') {
            s/\[/\{/g; s/\]/\}/g; s/\\/|/g;
            s/\^/~/g if $mapping eq 'rfc1459';
        }
    }
    return $a cmp $b;
}

1;
