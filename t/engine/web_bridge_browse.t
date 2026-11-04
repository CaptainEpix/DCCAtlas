#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Browsing a file server from the page (2026-10-21): browse.start walks the
# server's folders through the crawl session, sends no "get", stops at the
# folder limit, closes the session, and browse.status pages what it read.

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
sub sent_to_chat { grep { /\AMSG =Bot / } @Irssi::GLOBAL_COMMANDS }
my $chat;
sub chat_line { Irssi::emit('dcc chat message', $chat, $_) for @_; drain() }
sub watch { Irssi::fire_timer($_) for grep {
    my $timer = Irssi::timer_record($_); $timer && $timer->[5] == 1000 } Irssi::timer_handles() }

my $configured = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#files' });
is($configured->{source}{state}, 'ready', 'a source on a joined channel') or diag explain $configured;

my %args = (source_id => 'lab', sender => 'Bot', trigger => '!Bot', trigger_mode => 'channel_text');
is($dispatch->('browse.start', { %args })->{code}, 'invalid_arguments',
    'browsing needs an operation ID');
is($dispatch->('browse.start', { %args, trigger_mode => 'searchbot' }, 'r', 'op-x')->{code},
    'invalid_arguments', 'and a trigger with a session');

$Irssi::Script::dccatlas::WEB_BRIDGE_BROWSE_FOLDER_LIMIT = 2;
my $started = $dispatch->('browse.start', { %args }, 'r1', 'op-browse-1');
like($started->{browse_id} // '', qr/\Abrowse-[0-9a-f]{32}\z/, 'a browse starts')
    or diag explain $started;
is($started->{state}, 'browsing', 'and is browsing');
is($dispatch->('browse.start', { %args }, 'r2', 'op-browse-1')->{browse_id}, $started->{browse_id},
    'the same operation ID gives the same browse');
is($dispatch->('browse.start', { %args }, 'r3', 'op-browse-2')->{code}, 'transfer_busy',
    'a second browse waits for the first');
drain();
is_deeply([grep { /!Bot/ } @{$server->{commands}}, @Irssi::GLOBAL_COMMANDS], ['MSG #files !Bot'],
    'the trigger is sent once');

$chat = bless { type => 'CHAT', nick => 'Bot', id => 'Bot', server => $server,
    servertag => 'mocknet', Irssi::new_dcc_identity() }, 'MockDcc';
Irssi::emit('dcc request', $chat, '127.0.0.1');
Irssi::emit('dcc connected', $chat);
chat_line('[\\]');
chat_line('[\\*.*]', 'ALPHA', 'BETA', 'GAMMA', 'top file.txt 10B', 'End of list');
chat_line('[\\ALPHA\\]');
chat_line('[\\ALPHA\\*.*]', 'inner.pdf 2KB', 'End of list');
watch();
my $done = $dispatch->('browse.status',
    { source_id => 'lab', browse_id => $started->{browse_id}, limit => 100 });
is($done->{state}, 'complete', 'the walk ends at the folder limit') or diag explain $done;
is($done->{folders_read}, 2, 'after two folders');
ok($done->{truncated}, 'and says it stopped early');
like($done->{note}, qr/first 2 folders/, 'in words');
is_deeply([map { "$_->{type} $_->{path}" } @{$done->{entries}}],
    ['dir /ALPHA', 'dir /BETA', 'dir /GAMMA', 'file /top file.txt', 'file /ALPHA/inner.pdf'],
    'every folder and file read is kept');
is_deeply([map { $_->{read} ? 1 : 0 } grep { $_->{type} eq 'dir' } @{$done->{entries}}],
    [1, 0, 0], 'and each folder says whether its contents were read');
is($done->{start_path}, '/', 'from the top');
is($done->{entries}[3]{size_bytes}, 10, 'with its size');
is_deeply([map { s/\AMSG =Bot //r } sent_to_chat()], ['dir', 'cd ALPHA', 'dir'],
    'only cd and dir were typed; nothing was asked for');
ok((grep { /\ADCC CLOSE CHAT Bot/ } @Irssi::GLOBAL_COMMANDS), 'the session was closed');

my $page = $dispatch->('browse.status',
    { source_id => 'lab', browse_id => $started->{browse_id}, offset => 3, limit => 1 });
is_deeply([map { $_->{path} } @{$page->{entries}}], ['/top file.txt'], 'pages are read by offset');
is($page->{total}, 5, 'with the total');
is($dispatch->('browse.status', { source_id => 'lab', browse_id => 'browse-' . ('0' x 32) })->{code},
    'stale_browse', 'an unknown browse is refused');
is($dispatch->('browse.status', { source_id => 'lab', browse_id => $started->{browse_id},
    limit => 101 })->{code}, 'invalid_arguments', 'at most 100 a page');

# A browse from a folder the first did not read goes there, and reads as deep
# below it as a browse reads below the top.
is($dispatch->('browse.start', { %args, path => '/BETA/../x' }, 'r4', 'op-browse-3')->{code},
    'invalid_arguments', 'a path with .. is refused');
@Irssi::GLOBAL_COMMANDS = ();
my $from = $dispatch->('browse.start', { %args, path => '/BETA' }, 'r5', 'op-browse-4');
is($from->{start_path}, '/BETA', 'a browse from /BETA starts') or diag explain $from;
drain();
$chat = bless { type => 'CHAT', nick => 'Bot', id => 'Bot', server => $server,
    servertag => 'mocknet', Irssi::new_dcc_identity() }, 'MockDcc';
Irssi::emit('dcc request', $chat, '127.0.0.1');
Irssi::emit('dcc connected', $chat);
chat_line('[\\]');
chat_line('[\\BETA\\]');
chat_line('[\\BETA\\*.*]', 'DEEP', 'b.txt 3B', 'End of list');
chat_line('[\\BETA\\DEEP\\]');
chat_line('[\\BETA\\DEEP\\*.*]', 'End of list');
watch();
my $beta = $dispatch->('browse.status',
    { source_id => 'lab', browse_id => $from->{browse_id}, limit => 100 });
is($beta->{state}, 'complete', 'it ends') or diag explain $beta;
is_deeply([map { "$_->{type} $_->{path}" . ($_->{read} ? ' read' : '') } @{$beta->{entries}}],
    ['dir /BETA/DEEP read', 'file /BETA/b.txt'], 'with what is below the folder');
is_deeply([map { s/\AMSG =Bot //r } sent_to_chat()], ['cd BETA', 'dir', 'cd DEEP', 'dir'],
    'having gone there first');

done_testing();
