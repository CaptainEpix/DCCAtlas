#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

# An @find that nothing answers at all ends after the first-reply window
# (60 seconds), not after the full collection limit. Once anything answers,
# the shorter quiet window takes over as before.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $server = bless {
    connected => 1, tag => 'mocknet', chatnet => 'FServeLab',
    nick => 'LocalNick', commands => [],
}, 'MockServer';

sub live_timers {
    my ($ms) = @_;
    return grep { !$_->[3] && !$_->[4] && $_->[5] == $ms } @Irssi::TIMERS;
}

sub status_says {
    my ($pattern) = @_;
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', 'status', $server, undef);
    return scalar grep { /$pattern/ } @Irssi::PRINTS;
}

# Nothing answers.
Irssi::run_command('fscrawl', 'find #files silence', $server, undef);
is_deeply $server->{commands}, ['MSG #files @find silence'], 'one @find is sent';
my ($first) = live_timers(60000);
ok($first, 'a 60-second first-reply window is armed when the search is sent');
ok(scalar(live_timers(150000)), 'and the full limit as before');
@Irssi::PRINTS = ();
Irssi::fire_timer($first->[2]);
ok((grep { /nothing answered within 60 seconds/ } @Irssi::PRINTS),
    'the search ends at the first-reply window and says why');
ok(status_says(qr/find_active=no/), 'the collection is closed');

# Something answers: the quiet window takes over, and the first-reply
# window no longer ends the search.
$Irssi::MOCK_MONOTONIC += 60;   # the engine's spacing between searches
Irssi::run_command('fscrawl', 'find #files answered', $server, undef);
($first) = live_timers(60000);
ok($first, 'the next search has its own first-reply window');
Irssi::emit('message public', $server, '[@Find Results] -=SysReset 2.55=-',
    'Bot', 'user@host', '#files');
my ($quiet) = live_timers(30000);
ok($quiet, 'a reply arms the 30-second quiet window');
ok(!scalar(live_timers(60000)), 'in place of the first-reply window');
@Irssi::PRINTS = ();
Irssi::fire_timer($first->[2], 1);
ok(status_says(qr/find_active=yes/), 'the old first-reply timer does nothing');
@Irssi::PRINTS = ();
Irssi::fire_timer($quiet->[2]);
ok((grep { /closed after the quiet window/ } @Irssi::PRINTS),
    'the quiet window ends it as before');

# The first-reply window is never shorter than the quiet window.
$Irssi::MOCK_MONOTONIC += 60;
$Irssi::SETTINGS{fscrawl_find_first_reply_ms} = 1000;
Irssi::run_command('fscrawl', 'find #files short', $server, undef);
ok(scalar(live_timers(30000)), 'a first-reply setting below the quiet window is raised to it');

done_testing();
