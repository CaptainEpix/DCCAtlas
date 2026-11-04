#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

# A file server that changes its nick while its session is open. Irssi then
# renames the session's CHAT and gives it a new id (event_nick in
# src/irc/dcc/dcc-chat.c), so the adapter, which knows the CHAT by the
# nick, would no longer read or count its lines and could not close it. The
# session must be given up, its CHAT cut or closed under the new nick, and a
# request waiting for its file settled. Nothing may be sent to the server.

use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

plan skip_all => 'needs /proc/self/fd, as on Linux' unless -d '/proc/self/fd';

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";
Irssi::settings_set_str('fscrawl_library_dir', "$FindBin::Bin/../../lib");
Irssi::settings_set_str('fscrawl_output_dir', "$test_root/output");
Irssi::settings_set_str('fscrawl_download_dir', "$test_root/downloads");
mkdir "$test_root/downloads" or die "could not create download test root: $!";
Irssi::settings_set_str('dcc_download_path', "$test_root/downloads");

my $server = MockServer->new();
$server->{nick} = 'LocalNick';

sub listener {
    return IO::Socket::INET->new(
        Listen => 8, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
        || die "listen: $!";
}

sub dial {
    my ($listener) = @_;
    return IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $listener->sockport()) || die "connect: $!";
}

sub carries_data {
    my ($ours, $theirs) = @_;
    my ($there, $back) = ('', '');
    return 0 unless defined(syswrite($ours, 'ping')) && sysread($theirs, $there, 4);
    return 0 unless defined(syswrite($theirs, 'pong')) && sysread($ours, $back, 4);
    return $there eq 'ping' && $back eq 'pong' ? 1 : 0;
}

sub reads_as_ended {
    my ($ours) = @_;
    my $ready = '';
    vec($ready, fileno($ours), 1) = 1;
    return 0 unless select($ready, undef, undef, 0);
    my $read = sysread($ours, my $data, 16);
    return defined($read) && $read == 0 ? 1 : 0;
}

# A session whose CHAT Irssi connects to $listener while the adapter's DCC
# CHAT command runs, unless the far end was dialled beforehand.
sub open_session {
    my ($nick, $listener, %options) = @_;
    my $ours = $options{earlier};
    Irssi::Script::dccatlas::start_fserve_session($nick, $server, "MSG #files !$nick", undef);
    my $chat = bless {
        type => 'CHAT', nick => $nick, id => $nick, server => $server,
        servertag => 'mocknet', Irssi::new_dcc_identity(),
        addr => '127.0.0.1', port => $listener->sockport(),
    }, 'MockDcc';
    local $server->{on_command} = sub {
        $ours = dial($listener) if $_[0] eq "DCC CHAT $nick" && !$options{earlier};
    };
    Irssi::emit('dcc request', $chat, '127.0.0.1');
    my $theirs = $listener->accept() || die "accept: $!";
    Irssi::emit('dcc connected', $chat) unless $options{unconnected};
    return ($chat, $ours, $theirs);
}

# What Irssi does first: the same CHAT, under the new nick and a new id.
sub renamed {
    my ($chat, $nick) = @_;
    return bless { %$chat, nick => $nick, id => $nick }, 'MockDcc';
}

sub rename_peer {
    my ($old, $new) = @_;
    Irssi::emit('event nick', $server, ":$new", $old, 'fserve@localhost');
}

sub close_commands { return grep { /\ADCC CLOSE CHAT / } @Irssi::GLOBAL_COMMANDS }
sub said { return join "\n", @Irssi::PRINTS }
sub sent_to {
    my ($nick) = @_;
    return scalar grep { /\Q$nick\E/ } @{$server->{commands}}, @{$server->{raw_lines}};
}

# The CHAT is open and its socket known: it is cut at once, and once Irssi
# has closed it there is nothing left to close.
{
    my $files = listener();
    my ($chat, $ours, $theirs) = open_session('Alpha', $files);
    Irssi::emit('dcc chat message', $chat, '[\\]');
    ok carries_data($ours, $theirs), 'the session is open';
    @Irssi::PRINTS = ();
    @Irssi::GLOBAL_COMMANDS = ();
    rename_peer('Alpha', 'Alpha|away');
    ok reads_as_ended($ours) && -c $ours, 'the CHAT is cut when its file server changes nick';
    like said(), qr/changed its nick from Alpha to Alpha\|away/, 'the reason names both nicks';
    my $now = renamed($chat, 'Alpha|away');
    Irssi::emit('dcc chat message', $now, "\x7fELF\x02\x01\x01");
    Irssi::emit('dcc closed', $now);
    Irssi::run_timers();
    is scalar(close_commands()), 0, 'Irssi closed it; nothing is left for the timer to close';
    is sent_to('Alpha|away'), 0, 'nothing is sent under the new nick';
}

# Which socket is the CHAT's is not known (another leads to the same place),
# so nothing is cut, and the CHAT is closed under its new nick.
{
    my $files = listener();
    my $earlier = dial($files);
    my ($chat, $ours, $theirs) = open_session('Beta', $files, earlier => $earlier);
    my $other = dial($files);
    my $other_far = $files->accept() || die "accept: $!";
    @Irssi::GLOBAL_COMMANDS = ();
    rename_peer('Beta', 'Beta2');
    rename_peer('Beta2', 'Beta3');
    ok carries_data($ours, $theirs), 'a socket that cannot be told apart is not cut';
    ok carries_data($other, $other_far), 'nor is the other one';
    Irssi::run_timers();
    is_deeply [close_commands()], ['DCC CLOSE CHAT Beta3'],
        'the CHAT is closed by its latest nick, which is how Irssi finds it';
}

# Renamed before Irssi reported the CHAT connected: it is destroyed, not
# closed, which would send the file server a refusal.
{
    my $files = listener();
    my ($chat, $ours, $theirs) = open_session('Gamma', $files, unconnected => 1);
    @Irssi::GLOBAL_COMMANDS = ();
    rename_peer('Gamma', 'Gamma_');
    Irssi::emit('dcc connected', renamed($chat, 'Gamma_'));
    Irssi::run_timers();
    ok $chat->{destroyed}, 'the waiting CHAT is destroyed';
    is scalar(close_commands()), 0, 'and no close command is used for it';
    is sent_to('Gamma_'), 0, 'nothing is sent under the new nick';
}

# Changes that are not the file server's leave the session alone.
{
    my $files = listener();
    my ($chat, $ours, $theirs) = open_session('Delta', $files);
    Irssi::emit('dcc chat message', $chat, '[\\]');
    @Irssi::PRINTS = ();
    rename_peer('Delta', 'delta');
    rename_peer('Somebody', 'Delta2');
    ok carries_data($ours, $theirs), 'a change of case or of another nick cuts nothing';
    unlike said(), qr/changed its nick/, 'and gives nothing up';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
}

# A request waiting for its file: the offer would come from the new nick, so
# the request is settled at once rather than left to expire.
{
    $Irssi::SETTINGS{fscrawl_find_quiet_ms} = 250;
    Irssi::run_command('fscrawl', 'find #files renamed-query', $server, undef);
    Irssi::test_run_outbound_timers();
    for my $line (
        '[@Find Results] -=SysReset 2.55=-',
        'Found [1] file on Trigger:[!renamebot] - Sends:[0/1] - Queues:[0/1]',
        'File: [renamed.txt] - Size [7B]',
        'End of @Find.',
    ) {
        Irssi::Script::dccatlas::handle_find_message(
            'public', $server, $line, 'RenameBot', 'bot@localhost', '#files');
    }
    my $quiet_timer = $Irssi::TIMERS[-1];
    ok $quiet_timer && Irssi::fire_timer($quiet_timer->[2]), 'the Find reply completes';
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', 'queue-add find find-1-1 channel', $server, undef);
    my ($job_id) = map { /Added held job (job-[a-f0-9]{32})/ ? $1 : () } @Irssi::PRINTS;
    ok $job_id, 'the result becomes a job';
    $Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
    Irssi::run_command('fscrawl', "queue-run $job_id", $server, undef);
    Irssi::test_run_outbound_timers();
    my $chat = bless {
        type => 'CHAT', nick => 'RenameBot', id => 'RenameBot', server => $server,
        servertag => 'mocknet', Irssi::new_dcc_identity(),
    }, 'MockDcc';
    Irssi::emit('dcc request', $chat, '127.0.0.1');
    Irssi::emit('dcc connected', $chat);
    Irssi::emit('dcc chat message', $chat, '[\\]');
    Irssi::test_run_outbound_timers();
    Irssi::emit('dcc chat message', $chat, $_) for '[\\*.*]', 'renamed.txt 7B', 'End of list.';
    Irssi::test_run_outbound_timers();
    is scalar(grep { /^MSG =RenameBot get renamed\.txt$/ } @Irssi::GLOBAL_COMMANDS), 1,
        'the file was asked for';
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', "job-show $job_id", $server, undef);
    like said(), qr/state=awaiting_offer/, 'and the request waits for its file';

    rename_peer('RenameBot', 'RenameBot|away');
    Irssi::run_timers();
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', "job-show $job_id", $server, undef);
    like said(), qr/state=failed/, 'the waiting request is settled';
    like said(), qr/outcome=file_server_renamed/, 'as given up for the change of nick';
    my $offer = bless {
        type => 'GET', nick => 'RenameBot|away', arg => 'renamed.txt',
        size => 7, transfd => 0, server => $server, servertag => 'mocknet',
        Irssi::new_dcc_identity(),
    }, 'MockDcc';
    Irssi::emit('dcc request', $offer);
    ok !Irssi::Script::dccatlas::has_active_download_transfer(),
        'the file offered under the new nick is not taken';
    is scalar(grep { /get renamed\.txt/ } @Irssi::GLOBAL_COMMANDS), 1, 'nor asked for again';
    $Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 1;
}

done_testing();
