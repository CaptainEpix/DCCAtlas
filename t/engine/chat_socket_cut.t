#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

# When a CHAT turns out not to be an FServe session, the adapter ends Irssi's
# reading of it at once by cutting the CHAT's own socket, which it has to
# find among the process's descriptors. It must cut that socket and no
# other, and cut nothing when it cannot tell which one it is.

use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_LINGER);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

plan skip_all => 'needs /proc/self/fd, as on Linux' unless -d '/proc/self/fd';

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $server = MockServer->new();
$server->{nick} = 'LocalNick';

# A file server that takes every DCC on one port, and something else the
# process is connected to (as Irssi is to its IRC server).
my $file_server = IO::Socket::INET->new(
    Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or die "listen: $!";
my $elsewhere = IO::Socket::INET->new(
    Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or die "listen: $!";

sub dial {
    my ($listener) = @_;
    return IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $listener->sockport()) || die "connect: $!";
}

# Both ends of a new connection: [ours, the far end].
sub connect_to {
    my ($listener) = @_;
    my $ours = dial($listener);
    return [$ours, $listener->accept() || die "accept: $!"];
}

sub carries_data {
    my ($pair) = @_;
    my ($ours, $theirs) = @$pair;
    my ($there, $back) = ('', '');
    return 0 unless defined(syswrite($ours, 'ping')) && sysread($theirs, $there, 4);
    return 0 unless defined(syswrite($theirs, 'pong')) && sysread($ours, $back, 4);
    return $there eq 'ping' && $back eq 'pong' ? 1 : 0;
}

sub readable {
    my ($handle, $seconds) = @_;
    my $ready = '';
    vec($ready, fileno($handle), 1) = 1;
    return select($ready, undef, undef, $seconds) ? 1 : 0;
}

# What Irssi would find on its next read of the descriptor.
sub reads_as_ended {
    my ($ours) = @_;
    return 0 unless readable($ours, 0);
    my $read = sysread($ours, my $data, 16);
    return defined($read) && $read == 0 ? 1 : 0;
}

sub far_end_closed {
    my ($theirs) = @_;
    return 0 unless readable($theirs, 2);
    my $read = sysread($theirs, my $data, 16);
    return !defined($read) || $read == 0 ? 1 : 0;
}

# A session whose CHAT is connected as Irssi connects one: the socket is
# opened while the adapter's DCC CHAT command runs, unless one is passed in.
sub open_session {
    my ($nick, $port, $opened_earlier, $listener) = @_;
    $listener //= $file_server;
    my $ours;
    Irssi::Script::dccatlas::start_fserve_session($nick, $server, "MSG #files !$nick", undef);
    my $chat = bless {
        type => 'CHAT', nick => $nick, id => $nick, server => $server,
        servertag => 'mocknet', Irssi::new_dcc_identity(),
        addr => '127.0.0.1', port => $port,
    }, 'MockDcc';
    # Only our end appears during the command, as in Irssi; the far end is
    # this process's too, and is taken afterwards.
    local $server->{on_command} = sub {
        $ours = dial($listener) if $_[0] eq "DCC CHAT $nick" && !$opened_earlier;
    };
    Irssi::emit('dcc request', $chat, '127.0.0.1');
    my $pair = $opened_earlier // [$ours, $listener->accept() || die "accept: $!"];
    Irssi::emit('dcc connected', $chat);
    return ($chat, $pair);
}

sub close_commands { return scalar grep { /\ADCC CLOSE CHAT / } @Irssi::GLOBAL_COMMANDS }

my $not_text = "\x7fELF\x02\x01\x01";
my $port = $file_server->sockport();
my $irc = connect_to($elsewhere);

# One socket leads to the file server: it is the CHAT's.
{
    my ($chat, $pair) = open_session('One', $port);
    ok $pair && carries_data($pair), 'the session is connected';
    Irssi::emit('dcc chat message', $chat, '[\\]');
    ok carries_data($pair), 'a line of text leaves the session alone';
    Irssi::emit('dcc chat message', $chat, $not_text);
    ok reads_as_ended($pair->[0]), 'after a line that is not text, the next read finds the end';
    ok -c $pair->[0], 'the descriptor no longer leads to the network';
    ok far_end_closed($pair->[1]), 'the file server sees the session closed';
    ok carries_data($irc), 'another connection of the process is untouched';
    # Irssi closes the CHAT when its read finds the end; the adapter's timer
    # then has no session left to close.
    @Irssi::GLOBAL_COMMANDS = ();
    Irssi::emit('dcc closed', $chat);
    Irssi::run_timers();
    is close_commands(), 0, 'nothing is left for the timer to close';
}

# A file is being received from the same address and port. The CHAT's socket
# is the one opened when the CHAT was connected.
{
    my ($chat, $pair) = open_session('Two', $port);
    my $transfer = connect_to($file_server);
    Irssi::emit('dcc chat message', $chat, $not_text);
    ok reads_as_ended($pair->[0]) && -c $pair->[0], 'the session is cut';
    ok far_end_closed($pair->[1]), 'the file server sees the session closed';
    ok carries_data($transfer), 'the transfer on the same port still carries data';
    ok !-c $transfer->[0], 'the transfer still has its own socket';
    Irssi::emit('dcc closed', $chat);
    Irssi::run_timers();
}

# The same, but which socket is the CHAT's was never learned. Nothing is cut;
# the session is closed from the timer as before.
{
    my $earlier = connect_to($file_server);
    my ($chat, $pair) = open_session('Three', $port, $earlier);
    my $transfer = connect_to($file_server);
    @Irssi::GLOBAL_COMMANDS = ();
    Irssi::emit('dcc chat message', $chat, $not_text);
    ok carries_data($pair), 'a session that cannot be told from a transfer is not cut';
    ok carries_data($transfer), 'nor is the transfer';
    Irssi::run_timers();
    is close_commands(), 1, 'the session is closed from the timer instead';
}

# No socket leads where the CHAT says it does. Nothing is cut.
{
    my ($chat, $pair) = open_session('Four', $port);
    $chat->{addr} = '127.0.0.2';
    is Irssi::Script::dccatlas::chat_socket_descriptor($chat), undef,
        'no socket is named for an address nothing is connected to';
    $chat->{addr} = '127.0.0.1';
    is Irssi::Script::dccatlas::chat_socket_descriptor($chat), fileno($pair->[0]),
        'the socket is named by its descriptor';
    is Irssi::Script::dccatlas::chat_socket_descriptor(
        { addr => '127.0.0.1', port => $elsewhere->sockport() }), undef,
        'once the CHAT\'s own socket is known, no other is named';
    is Irssi::Script::dccatlas::chat_socket_descriptor({ addr => 'file.example', port => $port }),
        undef, 'an address that is not numeric names nothing';
    ok carries_data($pair) && carries_data($irc), 'looking changes nothing';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
    is Irssi::Script::dccatlas::chat_socket_descriptor(
        { addr => '127.0.0.1', port => $elsewhere->sockport() }), fileno($irc->[0]),
        'with no CHAT socket known, a single socket is found by where it leads';
}

# The file server resets the CHAT while sending a file on the same port.
# The CHAT's socket then leads nowhere, and the transfer is the only socket
# still leading to that address and port. Irssi goes on handing out lines
# it already holds after a reset (line_split in src/core/line-split.c), and
# one that is not text must cut the CHAT's own socket, not the transfer.
{
    my ($chat, $pair) = open_session('Five', $port);
    my $transfer = connect_to($file_server);
    setsockopt($pair->[1], SOL_SOCKET, SO_LINGER, pack('ii', 1, 0)) or die "linger: $!";
    close $pair->[1];
    select(undef, undef, undef, 0.2);
    ok !defined(getpeername($pair->[0])), 'the reset CHAT socket no longer leads anywhere';
    is Irssi::Script::dccatlas::chat_socket_descriptor($chat), fileno($pair->[0]),
        'the CHAT\'s own socket is still the one named';
    Irssi::emit('dcc chat message', $chat, $not_text);
    ok -c $pair->[0], 'the reset session is cut';
    ok carries_data($transfer), 'the transfer on the same port still carries data';
    ok !-c $transfer->[0], 'the transfer still has its own socket';
    Irssi::emit('dcc closed', $chat);
    Irssi::run_timers();
}

# Which socket is the CHAT's was never learned, and one socket leads where it
# does. While a file is being received that could be the transfer, so it is
# not named.
{
    my $lone = IO::Socket::INET->new(
        Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
        or die "listen: $!";
    my $earlier = connect_to($lone);
    my ($chat) = open_session('Six', $lone->sockport(), $earlier, $lone);
    is Irssi::Script::dccatlas::chat_socket_descriptor($chat), fileno($earlier->[0]),
        'with nothing being received, the one socket leading there is named';
    {
        no warnings 'redefine';
        local *Irssi::Script::dccatlas::has_active_download_transfer = sub { 1 };
        is Irssi::Script::dccatlas::chat_socket_descriptor($chat), undef,
            'while a file is being received, it is not';
    }
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

done_testing();
