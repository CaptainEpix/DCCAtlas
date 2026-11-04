#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# The connection log (2026-10-20): what a managed connection's server sends
# to this client, what the engine sends, and Irssi's own notices and errors,
# kept in memory and read over the bridge with log.list. Chat, the MOTD and
# anything that could carry a password are left out.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $dispatch = \&Irssi::Script::dccatlas::web_bridge_dispatch;

my $server = MockServer->new();
$server->{nick} = 'Atlas';
$server->{joined_channels}{'#fserve-test'} = 1;
my $other = MockServer->new();
$other->{tag} = 'othernet';
$other->{nick} = 'Atlas';
*Irssi::server_find_tag = sub { my ($tag) = @_; return $tag eq 'mocknet' ? $server : undef };

my $configured = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#fserve-test' });
ok(!$configured->{__bridge_error}, 'a source on the mock server') or diag explain $configured;

sub page { return $dispatch->('log.list', { @_ }) }
sub texts {
    my ($after) = @_;
    return map { $_->{text} } @{page(after => $after // 0)->{lines}};
}
sub incoming { Irssi::emit('server incoming', $_[0], $_[1]) }
sub printed {
    my ($srv, $level, $text) = @_;
    Irssi::emit('print text', { level => $level, server => $srv, target => undef },
        $text, $text);
}

my $start = page()->{last_seq};
ok(defined $start, 'the log names its last line');

# From the server: what is said to this client is kept, chat is not.
incoming($server, ':irc.example NOTICE * :*** Looking up your hostname...');
incoming($server, ':irc.example 001 Atlas :Welcome to the Example network');
incoming($server, ':irc.example 372 Atlas :- message of the day');
incoming($server, ':irc.example 433 * Atlas :Nickname is already in use');
incoming($server, 'PING :irc.example');
incoming($server, ':Chatter!c@host PRIVMSG #fserve-test :hello all');
incoming($server, ':Other!o@host JOIN #fserve-test');
incoming($server, ':Atlas!a@host JOIN #fserve-test');
incoming($server, ':Bot!b@host NOTICE #fserve-test :announcement');
incoming($server, ':Server1!s@host NOTICE Atlas :Found 3 files for "gibson"');
incoming($server, ":Server1!s\@host PRIVMSG Atlas :\x01DCC SEND results.txt 3232235777 5000 1200\x01");
incoming($server, ":Server2!s\@host PRIVMSG Atlas :\x0304coloured\x03 reply");
incoming($server, 'AUTHENTICATE +');
incoming($server, ':irc.example CAP * ACK :sasl');
incoming($server, 'ERROR :Closing Link: Atlas (Banned)');
incoming($other, ':Elsewhere!e@host NOTICE Atlas :not a managed connection');
is_deeply([texts($start)], [
    'Notice from irc.example: *** Looking up your hostname...',
    '001 Welcome to the Example network',
    '433 Atlas Nickname is already in use',
    'JOIN (this client) #fserve-test',
    'Notice from Bot in #fserve-test: announcement',
    'Notice from Server1: Found 3 files for "gibson"',
    'CTCP from Server1: DCC SEND results.txt 3232235777 5000 1200',
    'Message from Server2: coloured reply',
    'CAP ACK sasl',
    'ERROR Closing Link: Atlas (Banned)',
], 'what the server says to this client, not the MOTD, chat, pings or AUTHENTICATE')
    or diag explain [texts($start)];
my $lines = page(after => $start)->{lines};
is_deeply($lines->[0]{source_ids}, ['lab'], 'attributed to the source on that server');
is($lines->[0]{kind}, 'received', 'as received');
is($lines->[0]{server_tag}, 'mocknet', 'with its server');
ok($lines->[1]{seq} == $lines->[0]{seq} + 1, 'in order');

# Sent by the engine.
my $mark = page()->{last_seq};
Irssi::emit('message own_public', $server, '@find gibson', '#fserve-test');
Irssi::emit('message own_private', $server, '!Server1 book.epub', 'Server1', 'Server1');
Irssi::emit('message irc own_ctcp', $server, 'Server1', '!fserve', 'Server1');
Irssi::emit('message own_public', $other, 'not ours', '#elsewhere');
Irssi::Script::dccatlas::engine_log_sent_raw($server, 'PRIVMSG Search :@search gibson');
is_deeply([texts($mark)], [
    'To #fserve-test: @find gibson',
    'To Server1: !Server1 book.epub',
    'To Server1: CTCP Server1 !fserve',
    'To Search: @search gibson',
], 'what the engine sends on a managed connection') or diag explain [texts($mark)];

# Irssi's own words: notices on the server, and errors, even with no server.
$mark = page()->{last_seq};
printed($server, Irssi::MSGLEVEL_CLIENTNOTICE(), '-!- Irssi: Connection to irc.example established');
printed($server, Irssi::MSGLEVEL_CRAP(), 'MOTD and such');
printed(undef, Irssi::MSGLEVEL_CLIENTNOTICE(), 'a notice about nothing in particular');
printed(undef, Irssi::MSGLEVEL_CLIENTERROR(),
    '(default) warning Could not verify TLS servers certificate: self-signed certificate');
my @irssi = @{page(after => $mark)->{lines}};
is_deeply([map { $_->{text} } @irssi], [
    'Connection to irc.example established',
    'Could not verify TLS servers certificate: self-signed certificate',
], 'Irssi notices for the server and errors for anything') or diag explain \@irssi;
is($irssi[1]{kind}, 'error', 'an error is marked');
is_deeply($irssi[1]{source_ids}, [], 'and one with no server belongs to no source');

# A failed connection names Irssi's reason, which scripts are not given.
{
    # No server is connected and none waits to reconnect, as in the login test.
    no warnings 'redefine';
    local *Irssi::servers = sub { () };
    local *Irssi::reconnects = sub { () };
    my %web = (
        source_id => 'web', label => 'Web', provider => 'sysreset_find', host => 'irc.example',
        port => 6697, tls => JSON::PP::true(), nickname => 'Atlas', channel => '#books',
        revision => 1,
    );
    my $managed = $dispatch->('source.configure', { %web });
    ok(!$managed->{__bridge_error}, 'a managed source') or diag explain $managed;
    $mark = page()->{last_seq};
    my $connect = $dispatch->('source.connect', { source_id => 'web' }, 'r1', 'op-connect-1');
    ok(!$connect->{__bridge_error}, 'connect requested') or diag explain $connect;
    my ($connect_line) = grep { $_->{kind} eq 'engine' } @{page(after => $mark)->{lines}};
    is($connect_line->{text}, 'Connecting to irc.example port 6697, TLS on, as Atlas',
        'the log says which settings the connect used');
    my ($connect_command) = grep { /\ACONNECT / } @Irssi::GLOBAL_COMMANDS;
    my ($tag) = $connect_command =~ /-network (\S+)/;
    ok($tag, 'a connection was asked for') or diag explain \@Irssi::GLOBAL_COMMANDS;
    my $failing = bless({ tag => $tag, address => 'irc.example', port => 6697,
        connected => 0 }, 'MockServer');
    printed($failing, Irssi::MSGLEVEL_CLIENTERROR(),
        'Irssi: Unable to connect server irc.example port 6697 [Connection refused: 10.20.30.40]');
    Irssi::emit('server connect failed', $failing);
    # The current revision sent again is answered with the source's view.
    my $web = $dispatch->('source.configure', { %web })->{source};
    is($web->{reason}, 'IRC connection failed: Connection refused: 10.20.30.40',
        'the reason Irssi printed') or diag explain $web;
    my @states = grep { $_->{kind} eq 'state' } @{page(after => $mark)->{lines}};
    is($states[-1]{text}, 'Web: failed (IRC connection failed: Connection refused: 10.20.30.40)',
        'and the state change is logged');
    is_deeply($states[-1]{source_ids}, ['web'], 'for that source');

    # Closed while still connecting: a plain connection to a TLS port looks so.
    Irssi::clear_capture();
    $connect = $dispatch->('source.connect', { source_id => 'web' }, 'r2', 'op-connect-2');
    ok(!$connect->{__bridge_error}, 'connect requested again') or diag explain $connect;
    ($tag) = map { /-network (\S+)/ ? $1 : () } @Irssi::GLOBAL_COMMANDS;
    Irssi::emit('server disconnected', bless({ tag => $tag, address => 'irc.example',
        port => 6697, connected => 0 }, 'MockServer'));
    $web = $dispatch->('source.configure', { %web })->{source};
    is($web->{reason}, 'IRC connection closed before the server let this client in',
        'a connection closed before the welcome says so') or diag explain $web;

    # After the welcome it is an ordinary close.
    Irssi::clear_capture();
    $connect = $dispatch->('source.connect', { source_id => 'web' }, 'r3', 'op-connect-3');
    ok(!$connect->{__bridge_error}, 'connect requested a third time') or diag explain $connect;
    ($tag) = map { /-network (\S+)/ ? $1 : () } @Irssi::GLOBAL_COMMANDS;
    my $welcomed = bless({ tag => $tag, address => 'irc.example', port => 6697,
        connected => 1 }, 'MockServer');
    Irssi::emit('event 001', $welcomed, 'Atlas :Welcome', 'irc.example', '');
    $welcomed->{connected} = 0;
    Irssi::emit('server disconnected', $welcomed);
    $web = $dispatch->('source.configure', { %web })->{source};
    is($web->{reason}, 'IRC connection closed', 'after the welcome, an ordinary close')
        or diag explain $web;
}

# Paging, bounds and refusals.
my $all = page(after => 0, limit => 3);
is(scalar @{$all->{lines}}, 3, 'a page of three');
ok($all->{more}, 'with more to come');
my $next = page(after => $all->{lines}[-1]{seq}, limit => 3);
is($next->{lines}[0]{seq}, $all->{lines}[-1]{seq} + 1, 'the next page carries on');
for my $bad ({ after => -1 }, { limit => 0 }, { limit => 201 }, { after => 'x' }, { limit => [] }) {
    is(page(%$bad)->{code}, 'invalid_arguments', 'refused: ' . join('=', %$bad));
}
{
    local $Irssi::Script::dccatlas::ENGINE_LOG_TEXT_CHARS = 20;
    $mark = page()->{last_seq};
    incoming($server, ':Long!l@host NOTICE Atlas :' . ('x' x 50));
    my ($long) = texts($mark);
    is(length($long), 20, 'a long line is cut') or diag $long;
}
{
    local $Irssi::Script::dccatlas::ENGINE_LOG_LIMIT = 5;
    incoming($server, ":Flood!f\@host NOTICE Atlas :line $_") for 1 .. 8;
    my $kept = page(after => 0);
    is(scalar @{$kept->{lines}}, 5, 'the log keeps only its limit');
    is($kept->{first_seq}, $kept->{lines}[0]{seq}, 'and says where it now starts');
}
{
    local $Irssi::Script::dccatlas::ENGINE_LOG_LINES_PER_SECOND = 3;
    local $Irssi::Script::dccatlas::ENGINE_LOG_TEST_SECOND = 2_000_000_000;
    Irssi::Script::dccatlas::engine_log_flush_dropped();
    $mark = page()->{last_seq};
    incoming($server, ":Flood!f\@host NOTICE Atlas :burst $_") for 1 .. 6;
    is(scalar(texts($mark)), 3, 'past the rate, lines are not kept');
    $mark = page()->{last_seq};
    $Irssi::Script::dccatlas::ENGINE_LOG_TEST_SECOND++;
    my ($dropped) = texts($mark);
    like($dropped // '', qr/\A3 lines were not logged/, 'and the next second says how many');
}

is_deeply([@{$server->{commands}}, @{$server->{raw_lines}}], [], 'nothing was sent because of the log');

done_testing();
