#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Get list after a restart (2026-10-28): the engine forgets the adverts it saw,
# and the page, which keeps them a day, says so with "advertised". Without
# that word, or seeing the advert itself, the engine still asks nobody.

use FindBin;
use File::Temp qw(tempdir);
use JSON::PP;
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

my $configured = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#files' });
is($configured->{source}{state}, 'ready', 'a source on a joined channel') or diag explain $configured;

my $unseen = $dispatch->('list.request', { source_id => 'lab', sender => 'Shelf' }, 'r1',
    'web-download-' . ('a' x 64));
is($unseen->{code}, 'not_a_list_server', 'a nick never seen offering a list is not asked');
my $odd = $dispatch->('list.request', { source_id => 'lab', sender => 'Shelf', advertised => 'yes' },
    'r2', 'web-download-' . ('b' x 64));
is($odd->{code}, 'invalid_arguments', 'the word must be a JSON boolean');
my $no = $dispatch->('list.request', { source_id => 'lab', sender => 'Shelf',
    advertised => JSON::PP::false }, 'r3', 'web-download-' . ('c' x 64));
is($no->{code}, 'not_a_list_server', 'nor is it asked when the page says it was not seen');
is_deeply([grep { /\@Shelf/ } @{$server->{raw_lines}}], [], 'nothing was sent');

my $vouched = $dispatch->('list.request', { source_id => 'lab', sender => 'Shelf',
    advertised => JSON::PP::true }, 'r4', 'web-download-' . ('d' x 64));
ok(defined($vouched->{job_id}), 'seen by the page, it is asked') or diag explain $vouched;
drain();
is_deeply([grep { /\@Shelf/ } @{$server->{raw_lines}}], ['PRIVMSG #files :@Shelf'],
    'once, in the channel');

done_testing();
