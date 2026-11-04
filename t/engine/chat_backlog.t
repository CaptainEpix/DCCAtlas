#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

# Text that comes down a session faster than Irssi hands its lines out piles
# up in Irssi's own buffer, and Irssi works through all of it before the
# engine can do anything else. The adapter counts what Irssi holds from what
# it peeks at on the session's socket, and gives the session up when that
# passes a limit; a folder listing it asked for may hold more while every
# line reads as an entry. Irssi's reading is played here as Irssi 1.4.5 does
# it, against real sockets.

use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

plan skip_all => 'needs /proc/self/fd, as on Linux' unless -d '/proc/self/fd';
$SIG{PIPE} = 'IGNORE';   # the file server goes on sending after the cut

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

# The clocks the adapter reads, which move only when told to: the time on
# the clock, and the engine's own (its CPU time). They move together, except
# by $starved: time on the clock in which the host ran other work.
my ($clock, $starved) = (1000, 0);
{
    no warnings 'redefine';
    *Irssi::Script::dccatlas::chat_clock = sub { $clock };
    *Irssi::Script::dccatlas::chat_work_clock = sub { $clock - $starved };
}

# How long the adapter takes over a line, by the line: the clock moves on by
# that much while the line is handled.
my %handling;
{
    no warnings 'redefine';
    my $handle = \&Irssi::Script::dccatlas::handle_chat_line;
    *Irssi::Script::dccatlas::handle_chat_line = sub {
        $clock += $handling{$_[0]} // 0;
        goto &$handle;
    };
}

my $server = MockServer->new();
$server->{nick} = 'LocalNick';
my $file_server = IO::Socket::INET->new(
    Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
    or die "listen: $!";
my $port = $file_server->sockport();

# A crawl session whose CHAT is connected as Irssi connects one: its socket
# is opened while the adapter's DCC CHAT command runs, unless one is passed
# in. Returns the CHAT and Irssi's and the file server's ends.
sub open_session {
    my ($nick, $earlier) = @_;
    my $ours = $earlier;
    Irssi::Script::dccatlas::start_fserve_session($nick, $server, "MSG #files !$nick", undef);
    my $chat = bless {
        type => 'CHAT', nick => $nick, id => $nick, server => $server,
        servertag => 'mocknet', Irssi::new_dcc_identity(),
        addr => '127.0.0.1', port => $port,
    }, 'MockDcc';
    local $server->{on_command} = sub {
        $ours = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port)
            || die "connect: $!" if $_[0] eq "DCC CHAT $nick" && !$earlier;
    };
    Irssi::emit('dcc request', $chat, '127.0.0.1');
    my $theirs = $file_server->accept() || die "accept: $!";
    $_->blocking(0) for $ours, $theirs;
    Irssi::emit('dcc connected', $chat);
    return ($chat, $ours, $theirs);
}

# Irssi's dcc_chat_input: read up to 2,048 bytes, hand out one line, and go
# on while a line was handed out. At the end of the stream the lines still
# held are handed out before the CHAT closes. $sending is called before each
# read, as a file server goes on sending. Returns how many lines were handed
# out (in all, and before the stream ended), how many bytes Irssi held at
# the most, and whether the stream ended.
sub irssi_reads {
    my ($chat, $ours, $held, $sending) = @_;
    my %seen = (lines => 0, read => 0, most => 0, ended => 0);
    while (1) {
        $sending->() if $sending;
        my $got = sysread($ours, my $data, 2048);
        if (defined($got) && $got == 0) {
            $seen{ended} = 1;
        } elsif ($got) {
            $$held .= $data;
        }
        $seen{most} = length($$held) if length($$held) > $seen{most};
        my $end = index($$held, "\n");
        if ($end < 0) {
            last unless $seen{ended} && length $$held;
            $$held .= "\n";
            $end = length($$held) - 1;
        }
        my $line = substr($$held, 0, $end + 1, '');
        $line =~ s/\r?\n\z//;
        Irssi::emit('dcc chat message', $chat, $line);
        $seen{lines}++;
        $seen{read}++ unless $seen{ended};
    }
    return \%seen;
}

# A file server that sends $text, as much at a time as the socket takes.
sub sender {
    my ($theirs, $text, %options) = @_;
    my $at = 0;
    return sub {
        $clock += $options{seconds_a_read} if $options{seconds_a_read};
        if ($options{starved_a_read}) {
            $clock += $options{starved_a_read};
            $starved += $options{starved_a_read};
        }
        while ($at < length $text) {
            my $sent = syswrite($theirs, $text, 65536, $at);
            last unless $sent;
            $at += $sent;
        }
    };
}

sub record {
    return join '', map { local (@ARGV, $/) = $_; <> }
        sort glob("$test_root/fserve-poc/transcript-*.tsv");
}

sub count { my ($pattern) = @_; return scalar(() = record() =~ /$pattern/g) }

sub far_end_closed {
    my ($theirs) = @_;
    my $ready = '';
    vec($ready, fileno($theirs), 1) = 1;
    return 0 unless select($ready, undef, undef, 2);
    my $read = sysread($theirs, my $data, 65536);
    return 0 if defined($read) && $read > 0 && !far_end_closed($theirs);
    return 1;
}

sub listing_of {
    my ($files) = @_;
    return "[\\*.*]\r\n..\r\n" .
        join('', map { sprintf "another-file-in-the-folder-%06d.bin 1048576B\r\n", $_ } 1 .. $files) .
        "End of list.\r\n";
}

my $line = "A line of ordinary text, as a plain text file would have many of.\r\n";
my $given_up = qr/\tCHAT_NOT_FSERVE\t/;

# An ordinary session: its prompt, then a listing of 300 files that arrives
# all at once. Nothing is given up.
{
    my ($chat, $ours, $theirs) = open_session('One');
    my $held = '';
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    is $seen->{lines}, 1, 'the prompt is handed out';
    ok((grep { $_ eq 'MSG =One dir' } @Irssi::GLOBAL_COMMANDS), 'the folder is asked for');
    $seen = irssi_reads($chat, $ours, \$held, sender($theirs, listing_of(300)));
    is $seen->{lines}, 303, 'the whole listing is handed out';
    ok $seen->{most} > 2048, 'Irssi held more than one read of it at a time';
    is count($given_up), 0, 'an ordinary listing is not given up';
    is count(qr/\tSTATE\tfinished listing \//), 1, 'the listing is read to its end';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

# Empty lines before any prompt: given up for the number of lines Irssi
# holds, long before the 500-line rule, with little left in Irssi's buffer.
{
    my ($chat, $ours, $theirs) = open_session('Two');
    my $held = '';
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, "\r\n" x 400_000));
    is count($given_up), 1, 'empty lines are given up';
    like record(), qr/\tCHAT_NOT_FSERVE\tthe file server sent text over its session far faster than it could be read\n/,
        'for text sent faster than it could be read';
    like record(), qr/\tCHAT_BACKLOG\tsize limit passed: \d+ bytes and 2\d{4} lines waiting/,
        'when Irssi held just over 20,000 lines';
    ok $seen->{read} < 40, "Irssi was stopped within a few dozen reads ($seen->{read})";
    ok $seen->{lines} < 25_000, 'and handed out little more than what it held';
    ok $seen->{ended}, 'the session reads as ended';
    ok far_end_closed($theirs), 'the file server sees it closed';
    Irssi::run_timers();
}

# Ordinary text once the prompt has been shown: the 500-line rule no longer
# counts it, and it is given up when Irssi holds more than a megabyte.
{
    my ($chat, $ours, $theirs) = open_session('Three');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, $line x 60_000));
    is count($given_up), $before + 1, 'text after the prompt is given up';
    like record(), qr/\tCHAT_BACKLOG\tsize limit passed: 10\d{5} bytes/,
        'when Irssi held just over a megabyte';
    ok $seen->{read} > 500 && $seen->{read} < 600,
        "after about 530 lines rather than all 60,000 ($seen->{read})";
    ok $seen->{most} < 1024 * 1024 + 4096, 'Irssi never held much more than the limit';
    ok far_end_closed($theirs), 'the file server sees the session closed';
    Irssi::run_timers();
}

# A listing larger than the session's limits, sent at once, is still read:
# it is the folder the engine asked for and every line is an entry.
{
    my ($chat, $ours, $theirs) = open_session('Four');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, listing_of(30_000)));
    is count($given_up), $before, 'a listing of 30,000 files is not given up';
    is $seen->{lines}, 30_003, 'all of it is handed out';
    ok $seen->{most} > 1024 * 1024, 'though Irssi held more than the session limit';
    is count(qr/\tSTATE\tfinished listing \//), 2, 'and it is read to its end';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

# A listing that keeps the engine busy for over 3 seconds, with a line
# among its files that is not an entry, is read; and the time it took is
# not held against the file server's next line.
{
    my ($chat, $ours, $theirs) = open_session('Ten');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    my $listing = listing_of(2_000);
    $listing =~ s/(folder-000500\.bin 1048576B\r\n)/$1Some Folder\r\nSUBFOLDER\r\n/ or die;
    my $seen = irssi_reads($chat, $ours, \$held,
        sender($theirs, $listing, seconds_a_read => 0.002));
    is count($given_up), $before, 'a listing that keeps the engine busy for 4 seconds is read';
    is $seen->{lines}, 2_005, 'all of it';
    $clock += 0.1;
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\SUBFOLDER]\r\n"));
    is count($given_up), $before, 'and the line that follows it is not given up';
    is count(qr/\tNAV_ACK\t\/SUBFOLDER\n/), 1, 'but handled';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

# On a host busy with other work, a listing that takes long on the clock but
# little of the engine's own time is read: the delay is not the file
# server's doing (2026-11-03).
{
    my ($chat, $ours, $theirs) = open_session('Starved');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my ($before, $listed) = (count($given_up), count(qr/\tSTATE\tfinished listing \//));
    my $seen = irssi_reads($chat, $ours, \$held,
        sender($theirs, listing_of(5_000), starved_a_read => 0.01));
    is count($given_up), $before, 'a listing read over 50 seconds of a busy host is not given up';
    is $seen->{lines}, 5_003, 'all of it is handed out';
    is count(qr/\tSTATE\tfinished listing \//), $listed + 1, 'and read to its end';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

# The same amount of text in place of a listing is not an entry, and is
# given up at the session's limit.
{
    my ($chat, $ours, $theirs) = open_session('Five');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    my $seen = irssi_reads($chat, $ours, \$held,
        sender($theirs, "[\\*.*]\r\n" . ($line x 60_000) . "End of list.\r\n"));
    is count($given_up), $before + 1, 'text in place of a listing is given up';
    ok $seen->{read} < 600, "at the session limit, not the listing one ($seen->{read})";
    Irssi::run_timers();
}

# A listing beyond the listing limit is given up as too large, and says so.
{
    my ($chat, $ours, $theirs) = open_session('Six');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, listing_of(120_000)));
    is count($given_up), $before + 1, 'a listing of 120,000 files at once is given up';
    like record(), qr/\tCHAT_NOT_FSERVE\tthe folder listing was too large to read \(more than about 100,000 files at once\)\n/,
        'as a folder too large to read';
    ok $seen->{read} < 5_000, "long before all of it was handled ($seen->{read})";
    Irssi::run_timers();
}

# Text that keeps the engine busy without piling up: each line is already
# waiting when the last one is handled. The busy time is what gives it up.
{
    my ($chat, $ours, $theirs) = open_session('Seven');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    my $seen = irssi_reads($chat, $ours, \$held,
        sender($theirs, $line x 5_000, seconds_a_read => 0.01));
    is count($given_up), $before + 1, 'reading without a break for over 3 seconds is given up';
    like record(), qr/\tCHAT_NOT_FSERVE\tthe file server's text kept the engine busy for more than 3 seconds\n/,
        'for the time it kept the engine busy';
    ok $seen->{read} > 290 && $seen->{read} < 320,
        "after about 300 lines at 10 ms each ($seen->{read})";
    Irssi::run_timers();
}

# The same lines with a pause between bursts leave the engine time of its
# own, which counts against the busy time.
{
    my ($chat, $ours, $theirs) = open_session('Eight');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    for (1 .. 20) {
        irssi_reads($chat, $ours, \$held, sender($theirs, $line x 200, seconds_a_read => 0.01));
        $clock += 2.5;
    }
    is count($given_up), $before, 'bursts of 2 seconds with pauses between are not given up';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

# The engine's own work on a line, such as a write to a stalled disk, is not
# the file server's doing. A line it takes 4 seconds over, with the lines
# after it already waiting, does not give the session up.
{
    my ($chat, $ours, $theirs) = open_session('Eleven');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my ($before, $listed) = (count($given_up), count(qr/\tSTATE\tfinished listing \//));
    local $handling{'[\\*.*]'} = 4;
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, listing_of(200)));
    is count($given_up), $before, 'a line the engine took 4 seconds over does not give the session up';
    is $seen->{lines}, 203, 'the listing after it is handed out';
    is count(qr/\tSTATE\tfinished listing \//), $listed + 1, 'and read to its end';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

# Lines that each take the engine a little while still add up: text whose
# every line takes 10 ms to handle is given up after about 3 seconds of it.
{
    my ($chat, $ours, $theirs) = open_session('Twelve');
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    (my $text = $line) =~ s/\r\n\z//;
    local $handling{$text} = 0.01;
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, $line x 5_000));
    is count($given_up), $before + 1, 'text that is slow to handle line by line is given up';
    like record(), qr/\tCHAT_NOT_FSERVE\tthe file server's text kept the engine busy for more than 3 seconds\n/,
        'for the time it kept the engine busy';
    ok $seen->{read} > 290 && $seen->{read} < 320,
        "after about 300 lines at 10 ms each ($seen->{read})";
    Irssi::run_timers();
}

# When the session's socket cannot be told from another one to the same
# place, nothing is counted, as nothing would be cut.
{
    my $ours = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) || die;
    my ($chat, undef, $theirs) = open_session('Nine', $ours);
    my $other = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) || die;
    my $other_far = $file_server->accept() || die;
    my $held = '';
    irssi_reads($chat, $ours, \$held, sender($theirs, "[\\]\r\n"));
    my $before = count($given_up);
    my $seen = irssi_reads($chat, $ours, \$held, sender($theirs, $line x 30_000));
    is count($given_up), $before, 'nothing is given up for its size';
    is $seen->{lines}, 30_000, 'and all of it is handed out, as before';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

done_testing();
