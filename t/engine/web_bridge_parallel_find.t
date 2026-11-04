#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Searches on several sources at once (2026-10-27). Each source's search runs
# on its own connection with a record of its own: one started while another
# runs leaves the other going, replies and timers each reach their own
# search, a source may still run only one search, and everything that waits
# for searches (a browse, a download) waits for all of them.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $dispatch = \&Irssi::Script::dccatlas::web_bridge_dispatch;
# The bridge, as far as searches use it: its name, and events dropped.
{
    package StandInBridge;
    sub instance_id { 'e' x 32 }
    sub publish_event { 1 }
}
$Irssi::Script::dccatlas::WEB_BRIDGE = bless {}, 'StandInBridge';
my %servers;
for my $tag (qw(neta netb)) {
    my $server = MockServer->new();
    @{$server}{qw(tag chatnet nick)} = ($tag, uc($tag), 'LocalNick');
    $server->{joined_channels}{'#files'} = 1;
    $servers{$tag} = $server;
}
*Irssi::server_find_tag = sub { $servers{lc($_[0] // '')} };
*Irssi::servers = sub { values %servers };
*Irssi::reconnects = sub { () };

sub drain { Irssi::test_run_outbound_timers() for 1 .. 3 }
sub reply {
    my ($tag, $nick, @lines) = @_;
    Irssi::emit('message public', $servers{$tag}, $_, $nick, 'bot@host', '#files') for @lines;
}
sub answer {
    my ($tag, $nick, $file) = @_;
    reply($tag, $nick, '[@Find Results] -=SysReset 2.55=-',
        'Found [1] file on Trigger:[!' . $nick . '] - Sends:[0/1] - Queues:[0/1]',
        "File: [$file] - Size [10B]", 'End of @Find.');
}
sub find { my ($source, $terms) = @_;
    return $dispatch->('search.find', { source_id => $source, terms => $terms }) }
sub status { my ($source, $search) = @_;
    return $dispatch->('search.status', { source_id => $source, search_id => $search->{search_id},
                                          limit => 10 }) }
sub sent { my ($tag) = @_; return grep { /\AMSG #files \@find / } @{$servers{$tag}{commands}} }
sub quiet_timers { grep { my $timer = Irssi::timer_record($_); $timer && $timer->[5] == 30000 }
    Irssi::timer_handles() }
sub code_of { my ($reply) = @_; return $reply->{__bridge_error} ? $reply->{code} : 'ok' }

for my $source (qw(a b)) {
    my $configured = $dispatch->('source.configure', { source_id => $source,
        server_tag => "net$source", channel => '#files' });
    is($configured->{source}{state}, 'ready', "source $source is ready") or diag explain $configured;
}

my $first = find('a', 'old maps');
is(code_of($first), 'ok', 'a search on the first source starts') or diag explain $first;
drain();
my $second = find('b', 'old maps');
is(code_of($second), 'ok', 'and one on the second while the first runs') or diag explain $second;
drain();
is_deeply([sent('neta')], ['MSG #files @find old maps'], 'each is sent once, on its own connection');
is_deeply([sent('netb')], ['MSG #files @find old maps'], 'the second too');

is(code_of(find('a', 'other words')), 'search_active', 'a source still runs one search at a time');
is(code_of($dispatch->('browse.start', { source_id => 'a', sender => 'BotA', trigger => '!BotA',
    trigger_mode => 'channel_text' }, 'r1', 'op-browse-1')), 'search_active',
    'a browse waits for every search');

# Replies are told apart by connection, also for the search set aside.
answer('neta', 'BotA', 'atlas.txt');
answer('netb', 'BotB', 'bestiary.txt');
reply('netb', 'BotA', 'File: [stray.txt] - Size [1B]');
is_deeply([map { "$_->{sender} $_->{path}" } @{status('a', $first)->{results}}],
          ['BotA /atlas.txt'], 'the first search has its own reply');
is_deeply([map { "$_->{sender} $_->{path}" } @{status('b', $second)->{results}}],
          ['BotB /bestiary.txt'], 'and the second its own');
is(status('a', $first)->{state}, 'collecting', 'both are still collecting');

# Each search's quiet window ends it, whichever search is current.
Irssi::fire_timer($_) for quiet_timers();
is(status('a', $first)->{state}, 'complete', 'the first ends at its quiet window');
is(status('b', $second)->{state}, 'complete', 'so does the second');
ok(status('a', $first)->{results}[0]{selection_id}, 'and its result can be fetched');
Irssi::run_command('fscrawl', 'status', $servers{neta}, undef);
ok((grep { /find_active=no/ } @Irssi::PRINTS), 'no search is running any more');

# A dropped connection ends only its own search; Cancel reaches either.
my $third = find('a', 'star charts');
drain();
my $fourth = find('b', 'star charts');
drain();
is(code_of($third) . code_of($fourth), 'okok', 'two more searches start');
Irssi::emit('server disconnected', $servers{neta});
is(status('a', $third)->{state}, 'disconnected', 'the first connection dropped: its search ended');
is(status('b', $fourth)->{state}, 'collecting', 'the other goes on');
my $cancelled = $dispatch->('search.cancel', { source_id => 'b', search_id => $fourth->{search_id} });
is($cancelled->{state}, 'cancelled', 'Cancel reaches it') or diag explain $cancelled;
Irssi::run_command('fscrawl', 'status', $servers{netb}, undef);
like($Irssi::PRINTS[-3] // '', qr/find_active=no/, 'and then nothing is running');

done_testing();
