#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Get list (2026-10-27): "@Nick" goes once, only to a nick seen advertising a
# list, and the one file taken is a .zip or .txt from that nick under a name
# no other request on the connection reserved: here a posted row's a.zip,
# never answered. (Its in-memory tombstone refuses that late offer first; the
# durable reservation check in list_offer_belongs_to_job is the second
# line, for a name a session request reserved, and no test isolates it.)

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
@{$server}{qw(tag chatnet nick)} = ('mocknet', 'FServeLab', 'LocalNick');
$server->{joined_channels}{'#files'} = 1;
*Irssi::server_find_tag = sub { lc($_[0] // '') eq 'mocknet' ? $server : undef };
*Irssi::servers = sub { ($server) };
*Irssi::reconnects = sub { () };

sub drain { Irssi::test_run_outbound_timers() for 1 .. 3 }
sub timers_of { my ($ms) = @_; grep {
    my $timer = Irssi::timer_record($_); $timer && $timer->[5] == $ms } Irssi::timer_handles() }
sub offer {
    my ($nick, $name) = @_;
    my $dcc = bless { type => 'GET', nick => $nick, arg => $name, size => 100,
        server => $server, servertag => 'mocknet', Irssi::new_dcc_identity() }, 'MockDcc';
    Irssi::Script::dccatlas::sig_dcc_request($dcc, '127.0.0.1');
    return $dcc;
}
sub gets { grep { /\ADCC GET / } @{$server->{commands}} }

my $configured = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#files' });
is($configured->{source}{state}, 'ready', 'a source on a joined channel') or diag explain $configured;

# A list whose rows start with a word of their own, not the nick: the list's
# name, "!Bot-Ebooks2" (OmenServe, 2026-11-02), or the server's trigger,
# "!Tome" (2026-11-03). The row is posted with that word, and the file is
# still Bot's to send.
my $wrong = $dispatch->('list.download', { source_id => 'lab', sender => 'Bot',
    name => 'b.rar', list_name => 'Tome Two' }, 'r0', 'web-download-' . ('e' x 64));
is($wrong->{code}, 'invalid_arguments', 'a list name of two words is refused')
    or diag explain $wrong;
my $bang = $dispatch->('list.download', { source_id => 'lab', sender => 'Bot',
    name => 'b.rar', list_name => '!Tome' }, 'r0', 'web-download-' . ('f' x 64));
is($bang->{code}, 'invalid_arguments', 'as is one with its "!"');
my $named = $dispatch->('list.download', { source_id => 'lab', sender => 'Bot',
    name => 'b.rar', size_raw => '37KB', list_name => 'Tome' }, 'r0',
    'web-download-' . ('0' x 64));
ok(defined($named->{job_id}), "a named list's file is asked for") or diag explain $named;
drain();
is_deeply([grep { /!Tome/ } @{$server->{raw_lines}}],
    ['PRIVMSG #files :!Tome b.rar  ::INFO:: 37KB'], 'its row is posted as written');
is($named->{job}{sender}, 'Bot', 'and the file is expected from Bot') or diag explain $named;
Irssi::fire_timer($_) for timers_of(120000);
@{$server->{raw_lines}} = ();

# A row of Bot's list asks for a.zip, and is never answered.
my $row = $dispatch->('list.download', { source_id => 'lab', sender => 'Bot',
    name => 'a.zip', size_raw => '1.2MB' }, 'r1', 'web-download-' . ('a' x 64));
ok(defined($row->{job_id}), 'a listed file is asked for') or diag explain $row;
drain();
is_deeply([grep { /!Bot/ } @{$server->{raw_lines}}], ['PRIVMSG #files :!Bot a.zip  ::INFO:: 1.2MB'],
    'its row is posted once, as such lists write it');
Irssi::fire_timer($_) for timers_of(120000);
my $ended = $dispatch->('job.status', { job_id => $row->{job_id} });
is($ended->{job}{state} // $ended->{state}, 'expired', 'nothing came; it ended')
    or diag explain $ended;

my $list_operation = 'web-download-' . ('b' x 64);
my $unseen = $dispatch->('list.request', { source_id => 'lab', sender => 'Bot' }, 'r2',
    $list_operation);
is($unseen->{code}, 'not_a_list_server', 'a nick not seen advertising a list is not asked')
    or diag explain $unseen;
is_deeply([grep { /\@Bot/ } @{$server->{raw_lines}}], [], 'nothing was sent');

Irssi::Script::dccatlas::sig_advert_public($server, '@Bot please', 'Reader',
    'r@example', '#files');
Irssi::Script::dccatlas::sig_advert_public($server,
    'Type: @Bot For My List Of: 12 Files', 'Bot', 'b@example', '#files');
my $adverts = $dispatch->('adverts.list', { source_id => 'lab' });
is_deeply([map { [$_->{nick}, $_->{script}] } @{$adverts->{adverts}}], [['Bot', 'list']],
    'only Bot, naming itself, is a list server') or diag explain $adverts;

my $asked = $dispatch->('list.request', { source_id => 'lab', sender => 'Bot' }, 'r3',
    'web-download-' . ('c' x 64));
ok(defined($asked->{job_id}), 'Get list starts') or diag explain $asked;
is($asked->{job}{name}, "Bot's list", 'named for its server until the list is offered');
drain();
is_deeply([grep { /\@Bot/ } @{$server->{raw_lines}}], ['PRIVMSG #files :@Bot'],
    '"@Bot" is sent once');

my $again = $dispatch->('list.request', { source_id => 'lab', sender => 'Bot' }, 'r4',
    'web-download-' . ('d' x 64));
ok($again->{code}, 'a second Get list meanwhile is refused') or diag explain $again;

offer('Other', 'Bot-list.zip');
offer('Bot', 'setup.exe');
offer('Bot', 'a.zip');
is_deeply([gets()], [], 'no list from another nick, no .exe, no name another request reserved');
offer('Bot', 'Bot-newlist-27-Oct-2026.zip');
is_deeply([gets()], ['DCC GET Bot "Bot-newlist-27-Oct-2026.zip"'], 'the list is taken')
    or diag explain [gets()];
my $view = $dispatch->('job.status', { job_id => $asked->{job_id} });
is($view->{job}{name}, 'Bot-newlist-27-Oct-2026.zip', 'and named as offered')
    or diag explain $view;
offer('Bot', 'Bot-other.zip');
is(scalar(gets()), 1, 'only one list is taken');

done_testing();
