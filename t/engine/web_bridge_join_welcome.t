#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# A managed source joins its channel only after the server's 001 welcome
# (2026-10-20). Irssi counts the connection as made earlier, and a JOIN sent
# before the welcome is refused with 451, as the lab's log showed.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $dispatch = \&Irssi::Script::dccatlas::web_bridge_dispatch;
my @servers;
*Irssi::servers = sub { @servers };
*Irssi::reconnects = sub { () };
*Irssi::server_find_tag = sub {
    my ($tag) = @_;
    my ($found) = grep { lc($_->{tag}) eq lc($tag // '') } @servers;
    return $found;
};

my %source = (
    source_id => 'net', revision => 1, label => 'Net', provider => 'sysreset_find',
    host => 'irc.example', port => 6667, tls => JSON::PP::false(), nickname => 'Atlas',
    channel => '#books',
);
my $configured = $dispatch->('source.configure', { %source });
ok(!$configured->{__bridge_error}, 'a managed source') or diag explain $configured;

Irssi::clear_capture();
my $connect = $dispatch->('source.connect', { source_id => 'net' }, 'r1', 'op-connect-1');
ok(!$connect->{__bridge_error}, 'connect requested') or diag explain $connect;
my ($tag) = map { /-network (\S+)/ ? $1 : () } @Irssi::GLOBAL_COMMANDS;
ok($tag, 'a connection was asked for');

my $server = MockServer->new();
$server->{tag} = $tag;
$server->{address} = 'irc.example';
$server->{port} = 6667;
$server->{nick} = 'Atlas';
$server->{chatnet} = $tag;
push @servers, $server;
Irssi::emit('server connected', $server);
sub joins { grep { /\AJOIN / } @{$server->{commands}} }
for (1 .. 5) { Irssi::fire_timer($_) for Irssi::timer_handles() }
is(scalar(joins()), 0, 'no JOIN while the server has not welcomed this client')
    or diag explain $server->{commands};
my $view = $dispatch->('source.configure', { %source })->{source};
is($view->{state}, 'connecting', 'and the source is still connecting');

Irssi::emit('event 001', $server, 'Atlas :Welcome', 'irc.example', '');
for (1 .. 5) { Irssi::fire_timer($_) for Irssi::timer_handles() }
is_deeply([joins()], ['JOIN #books'], 'after the welcome, one JOIN')
    or diag explain $server->{commands};

# A NickServ login (2026-10-21): IDENTIFY goes as a raw line at the welcome,
# never into the log, and the JOIN waits for NickServ's answer.
sub nickserv_source {
    my ($id, $nick, %login) = @_;
    my %config = (%source, source_id => $id, nickname => $nick, tls => JSON::PP::true(),
        host => "$id.example", channel => "#$id");
    ok(!$dispatch->('source.configure', { %config })->{__bridge_error}, "source $id");
    my $login = $dispatch->('source.login', { source_id => $id, kind => 'nickserv', %login },
        'r-login', "op-login-$id");
    ok(!$login->{__bridge_error}, 'a NickServ login is kept') or diag explain $login;
    Irssi::clear_capture();
    $dispatch->('source.connect', { source_id => $id }, 'r', "op-connect-$id");
    my ($connect) = grep { /\ACONNECT / } @Irssi::GLOBAL_COMMANDS;
    unlike($connect, qr/hunter2/, 'the NickServ password is not given to CONNECT');
    my ($new_tag) = map { /-network (\S+)/ ? $1 : () } @Irssi::GLOBAL_COMMANDS;
    my $mock = MockServer->new();
    @{$mock}{qw(tag address port nick chatnet)} = ($new_tag, "$id.example", 6667, $nick, $new_tag);
    push @servers, $mock;
    Irssi::emit('server connected', $mock);
    Irssi::emit('event 001', $mock, "$nick :Welcome", "$id.example", '');
    for (1 .. 5) { Irssi::fire_timer($_) for Irssi::timer_handles() }
    return $mock;
}
sub joins_of { my ($mock) = @_; grep { /\AJOIN / } @{$mock->{commands}} }

my $ns = nickserv_source('ns', 'Atlas2', username => 'Account', password => 'hunter2');
is_deeply($ns->{raw_lines}, ['PRIVMSG NickServ :IDENTIFY Account hunter2'],
    'IDENTIFY with the account name is sent once, at the welcome');
is(scalar(joins_of($ns)), 0, 'the JOIN waits for NickServ');
Irssi::emit('message irc notice', $ns, 'You are now identified for Account.',
    'NickServ', 'services@example', 'Atlas2');
for (1 .. 5) { Irssi::fire_timer($_) for Irssi::timer_handles() }
is_deeply([joins_of($ns)], ['JOIN #ns'], 'and goes once NickServ has answered');
my $log = $dispatch->('log.list', { after => 0, limit => 200 });
my $text = join("\n", map { $_->{text} } @{$log->{lines}});
like($text, qr/Identifying to NickServ as Account/, 'the log says it identified');
unlike($text, qr/hunter2/, 'and never shows the password');
is($dispatch->('source.configure', { %source, source_id => 'ns', nickname => 'Atlas2',
    tls => JSON::PP::true(), host => 'ns.example', channel => '#ns' })->{source}{login}{username},
    'Account', 'the view names the account, not the password');

# Without an answer, the JOIN goes after the wait; without an account name,
# IDENTIFY names only the password.
$Irssi::Script::dccatlas::WEB_BRIDGE_IDENTIFY_WAIT_SECONDS = 1;
my $quiet = nickserv_source('quiet', 'Atlas3', password => 'hunter2');
is_deeply($quiet->{raw_lines}, ['PRIVMSG NickServ :IDENTIFY hunter2'], 'IDENTIFY with the nick');
is(scalar(joins_of($quiet)), 0, 'no JOIN at once');
sleep 2;
for (1 .. 5) { Irssi::fire_timer($_) for Irssi::timer_handles() }
is_deeply([joins_of($quiet)], ['JOIN #quiet'], 'the JOIN goes when NickServ stays silent');

done_testing();
