#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# File servers seen in a source's channel (web M3, Y1): the engine reads
# SysReset 2.55's and FServe.pl 2.0.0's adverts in the source's channel, keeps a bounded list, and
# lists it over the bridge. Nothing is ever sent because of an advert.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $engine = 'Irssi::Script::dccatlas';
my $dispatch = \&Irssi::Script::dccatlas::web_bridge_dispatch;

my $server = MockServer->new();
$server->{nick} = 'DCCAtlasLab';
$server->{joined_channels}{'#fserve-test'} = 1;
my $other_server = MockServer->new();
$other_server->{tag} = 'othernet';
$other_server->{joined_channels}{'#fserve-test'} = 1;
*Irssi::server_find_tag = sub { my ($tag) = @_; return $tag eq 'mocknet' ? $server : undef };

my $configured = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#fserve-test' });
ok(!$configured->{__bridge_error}, 'a source on the mock server') or diag explain $configured;

my ($c1, $c2) = ("\x0304", "\x0314");
sub advert {
    my ($triggers, %extra) = @_;
    my $key = $triggers =~ /&/ ? 'Triggers' : 'Trigger';
    return "$c1\[${c2}Fserve Active$c1] - $key:[$c2$triggers$c1]" .
        " - Users:[${c2}0/5$c1]" .
        (defined $extra{message} ? " - Message:[$c2$extra{message}$c1]" : '') . ' - SysReset 2.55';
}
sub say_in {
    my ($srv, $channel, $nick, $text) = @_;
    Irssi::emit('message public', $srv, $text, $nick, "$nick\@lab.example", $channel);
}
sub listing {
    my (%args) = @_;
    return $dispatch->('adverts.list', { source_id => 'lab', %args });
}

Irssi::clear_capture();
say_in($server, '#fserve-test', 'CaptainEpix', advert("!fserve$c1(0/10)$c1 & $c2/ctcp CaptainEpix !fserve2",
    message => 'FServe test server'));
my $list = listing();
is($list->{total}, 1, 'one file server seen');
my $seen = $list->{adverts}[0];
is($seen->{nick}, 'CaptainEpix', 'its nick');
is($seen->{version}, '2.55', 'its version');
is($seen->{message}, 'FServe test server', 'its message');
is_deeply($seen->{users}, { in_use => 0, limit => 5 }, 'its users');
is(scalar @{$seen->{triggers}}, 2, 'both triggers');
is($seen->{triggers}[0]{trigger}, '!fserve', 'the channel trigger');
is($seen->{triggers}[0]{queue_limit}, 10, 'with its queue');
is($seen->{triggers}[1]{kind}, 'ctcp', 'the CTCP trigger');
ok($seen->{triggers}[1]{ctcp_nick_is_sender}, 'naming the nick that sent the advert');
is($seen->{seen_count}, 1, 'seen once');
ok($seen->{last_seen} >= $seen->{first_seen}, 'with its times');
is($list->{unrecognised}, 0, 'nothing unrecognised');
is_deeply([@{$server->{commands}}, @{$server->{raw_lines}}, @Irssi::GLOBAL_COMMANDS], [],
    'nothing was sent');

say_in($server, '#fserve-test', 'captainepix', advert('!fserve'));
$list = listing();
is($list->{total}, 1, 'the same server again, in other case, is one entry');
is($list->{adverts}[0]{seen_count}, 2, 'seen twice');
is(scalar @{$list->{adverts}[0]{triggers}}, 1, 'and its latest advert replaces the first');

say_in($server, '#fserve-test', 'Mallory', advert('/ctcp CaptainEpix !fserve'));
$list = listing();
is($list->{adverts}[0]{nick}, 'Mallory', 'the most recently seen comes first');
ok(!$list->{adverts}[0]{triggers}[0]{ctcp_nick_is_sender},
    'a CTCP trigger naming someone else is marked');

say_in($server, '#elsewhere', 'Other', advert('!other'));
say_in($other_server, '#fserve-test', 'Other', advert('!other'));
say_in($server, '#fserve-test', 'Chatter', 'I like SysReset 2.55 a lot');
is(listing()->{total}, 2, 'adverts in another channel, on another server, or chat are not taken');
say_in($server, '#fserve-test', 'Odd', "[Fserve Active] - Trigger:[!x] - Mood:[good] - SysReset 2.55");
is(listing()->{unrecognised}, 1, 'an advert that does not read as SysReset is counted, not kept');


# A split advert: the first line is held until the second comes.
say_in($server, '#fserve-test', 'Splitter', "$c1\[${c2}Fserve Active$c1] - Trigger:[$c2!split$c1]");
is(listing()->{total}, 2, 'the first line alone is not listed');
say_in($server, '#fserve-test', 'Splitter', "${c1}Users:[${c2}2/5$c1] - SysReset 2.55");
$list = listing();
is($list->{total}, 3, 'with the second line it is');
is($list->{adverts}[0]{triggers}[0]{trigger}, '!split', 'trigger from the first line');
is_deeply($list->{adverts}[0]{users}, { in_use => 2, limit => 5 }, 'users from the second');
say_in($server, '#fserve-test', 'Lonely', "${c1}Users:[${c2}2/5$c1] - SysReset 2.55");
is(listing()->{total}, 3, 'a second line with no first is dropped');
{
    local $Irssi::Script::dccatlas::ADVERT_HEAD_WAIT_SECONDS = -1;
    say_in($server, '#fserve-test', 'Late', "$c1\[${c2}Fserve Active$c1] - Trigger:[$c2!late$c1]");
    say_in($server, '#fserve-test', 'Late', "${c1}Users:[${c2}2/5$c1] - SysReset 2.55");
}
is(listing()->{total}, 3, 'a second line after the wait is dropped');

# Paging and bounds.
$list = listing(limit => 2);
is(scalar @{$list->{adverts}}, 2, 'a page of two');
is(listing(offset => 2, limit => 2)->{adverts}[0]{nick}, 'captainepix', 'the next page, with the nick as last seen');
is_deeply(listing(offset => 9)->{adverts}, [], 'past the end');
for my $bad ({ limit => 0 }, { limit => 26 }, { offset => -1 }, { limit => 'x' }) {
    is(listing(%$bad)->{code}, 'invalid_arguments', 'refused: ' . join('=', %$bad));
}
is($dispatch->('adverts.list', { source_id => 'nowhere' })->{code}, 'unknown_source',
    'an unknown source is refused');
{
    local $Irssi::Script::dccatlas::ADVERT_MAX_SERVERS = 3;
    say_in($server, '#fserve-test', 'Newcomer', advert('!new'));
    my @nicks = map { $_->{nick} } @{listing()->{adverts}};
    is_deeply(\@nicks, [qw(Newcomer Splitter Mallory)],
        'at the limit, the server seen longest ago makes way');
}

# FServe.pl 2.0.0's advert, coloured as its show_notice colours it.
my ($hi, $txt) = ("\x0312", "\x0315");
my $before = listing();
say_in($server, '#fserve-test', 'Irssiserve', "$txt\x02($hi\x02FServe Online\x02$txt)\x02" .
    " Trigger:($hi/ctcp Irssiserve !irssi$txt) Sends:(${hi}1/2$txt) Queues:(${hi}0/10$txt)" .
    " Min CPS:(${hi}9.5 kB/s$txt) [FServe.pl 2.0.0]");
$list = listing();
is($list->{total}, $before->{total} + 1, 'an FServe.pl advert is taken');
$seen = $list->{adverts}[0];
is($seen->{script}, 'fserve.pl', "named as FServe.pl's");
is($seen->{version}, '2.0.0', 'with its version');
is_deeply([map { [$_->{trigger}, $_->{kind}] } @{$seen->{triggers}}], [['!irssi', 'ctcp']],
    'its CTCP trigger');
ok($seen->{triggers}[0]{ctcp_nick_is_sender}, 'under the nick that sent it');
is_deeply($seen->{sends}, { in_use => 1, limit => 2 }, 'its sends');
is_deeply($seen->{stats}, { 'Min CPS' => '9.5 kB/s' }, 'its statistics');
is($list->{adverts}[1]{script}, 'sysreset', "a SysReset advert is named as SysReset's");
# An FServe.pl advert that also names "@" and its own nick offers its list
# too (2026-10-29), as one server's "@Nick for my file list" did.
say_in($server, '#fserve-test', 'Quill', "$txt\x02($hi\x02FServe Online\x02$txt)\x02" .
    " Trigger:($hi/ctcp Quill !quill$txt) Sends:(${hi}0/2$txt) Queues:(${hi}0/10$txt)" .
    " On FServe:(${hi}RPG books, \@Quill for my file list$txt) [FServe.pl 2.0.0]");
$list = listing();
$seen = $list->{adverts}[0];
is($seen->{nick}, 'Quill', 'a file server that offers its list is taken');
is($seen->{script}, 'fserve.pl', "still named as FServe.pl's");
is_deeply([map { [$_->{trigger}, $_->{kind}] } @{$seen->{triggers}}],
    [['!quill', 'ctcp'], ['@Quill', 'list']], 'with its trigger and its list');
say_in($server, '#fserve-test', 'Sprout', "$txt\x02($hi\x02FServe Online\x02$txt)\x02" .
    " Trigger:($hi/ctcp Sprout !sprout$txt) Sends:(${hi}0/2$txt) Queues:(${hi}0/10$txt)" .
    " On FServe:(${hi}thanks \@Quill$txt) [FServe.pl 2.0.0]");
is_deeply([map { $_->{kind} } @{listing()->{adverts}[0]{triggers}}], ['ctcp'],
    "another nick's \@ offers no list");
$before = listing();

say_in($server, '#fserve-test', 'Quoter', advert('!quote', message => 'FServe Online soon'));
$list = listing();
is($list->{adverts}[0]{nick}, 'Quoter', 'a SysReset advert whose message names FServe Online is still read');
is($list->{adverts}[0]{script}, 'sysreset', 'as SysReset\'s');
say_in($server, '#fserve-test', 'Odd', '(FServe Online) Trigger:(!x) [FServe.pl 2.0.0]');
is(listing()->{unrecognised}, $before->{unrecognised} + 1,
    'an FServe.pl advert that does not read is counted, not kept');

# Pointing the source at another channel starts afresh.
delete $server->{joined_channels}{'#fserve-test'};
$configured = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#other' });
ok(!$configured->{__bridge_error}, 'reconfigured to another channel') or diag explain $configured;
is(listing()->{total}, 0, 'and the old channel\'s file servers are gone');

is_deeply([@{$server->{commands}}, @{$server->{raw_lines}}], [], 'still nothing sent to the server');

# The source's view names its connection, and another one after a
# reconnect; the web's download queue pauses when it changes (M3 review).
my $view = $configured->{source};
ok(defined $view->{connection_epoch}, 'a connected source names its connection')
    or diag explain $view;
Irssi::emit('server disconnected', $server);
my $after = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#fserve-test' })->{source};
ok(defined $after->{connection_epoch} && $after->{connection_epoch} != $view->{connection_epoch},
    'and another after a reconnect') or diag explain $after;

done_testing();
