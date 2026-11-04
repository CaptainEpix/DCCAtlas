#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

# A SearchBot query that is refused after its collection was set up, because
# the durable offer tuple is already reserved, must not leave a collection
# marked active. Nothing was sent and no timer is armed, so nothing would ever
# clear it, and every later search and download would be refused.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $server = MockServer->new();
$server->{nick} = 'LocalNick';

# Use up the connection's message allowance, so the query that follows has to
# wait for its outbound slot instead of going out at once.
Irssi::Script::dccatlas::schedule_irc_message(
    server => $server, kind => 'message', send => sub { push @{$server->{commands}}, 'BUDGET'; },
);
Irssi::test_run_outbound_timers();
ok scalar(grep { $_ eq 'BUDGET' } @{$server->{commands}}), 'the allowance message went out';
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;

sub printed {
    my ($pattern) = @_;
    return scalar grep { $_ =~ $pattern } @Irssi::PRINTS;
}

sub sent_searches {
    return scalar grep { /^MSG #books \@search / } @{$server->{commands}};
}

# The first query is reserved and scheduled, then cancelled before it is sent:
# its tuple stays reserved, but no stale-offer tombstone was recorded.
Irssi::run_command('fscrawl', 'searchbot #books SearchBot first book', $server, undef);
is sent_searches(), 0, 'the first query is waiting for its outbound slot';
Irssi::run_command('fscrawl', 'searchbot-cancel', $server, undef);
ok printed(qr/SearchBot collection cancelled/), 'the pending query is cancelled';

# The same text again reaches the durable tuple check and is refused there.
Irssi::run_command('fscrawl', 'searchbot #books SearchBot first book', $server, undef);
ok printed(qr/SearchBot query refused before dispatch/),
    'the repeat is refused by the durable tuple reservation';
Irssi::test_run_outbound_timers();
is sent_searches(), 0, 'neither the cancelled nor the refused query was sent';

# The refusal must leave the engine usable.
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'searchbot #books SearchBot second book', $server, undef);
ok !printed(qr/already active/),
    'a refused query does not leave a SearchBot collection marked active';
Irssi::test_run_outbound_timers();
is sent_searches(), 1, 'a different query is accepted and sent afterwards';
ok scalar(grep { $_ eq 'MSG #books @search second book' } @{$server->{commands}}),
    'the query that was sent is the new one';

done_testing();
