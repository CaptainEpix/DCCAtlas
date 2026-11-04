#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# A session ended from inside a CHAT or DCC handler stops from a timer a
# moment later, while its download already shows as ended (2026-10-23). A
# disconnect asked for in that moment must not be refused as busy: the stop
# is done first. The native suite met this once in about thirty runs.

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

my $configured = $dispatch->('source.configure',
    { source_id => 'lab', server_tag => 'mocknet', channel => '#files' });
is($configured->{source}{state}, 'ready', 'a source on a joined channel') or diag explain $configured;

my $started = $dispatch->('manifest.download', { source_id => 'lab', sender => 'Bot',
    trigger => '!Bot', trigger_mode => 'channel_text', path => '/books/a.txt' }, 'r1',
    'web-download-' . ('a' x 64));
ok(defined($started->{job_id}), 'a download starts') or diag explain $started;
drain();
is_deeply([grep { /!Bot/ } @{$server->{commands}}, @Irssi::GLOBAL_COMMANDS], ['MSG #files !Bot'],
    'the trigger is sent once');

my @deadline = timers_of(60000);
is(scalar(@deadline), 1, 'the session-open deadline is armed');
Irssi::fire_timer($_) for @deadline;
my $job = $dispatch->('job.status', { job_id => $started->{job_id} });
is($job->{job}{state} // $job->{state}, 'stale', 'no session opened: the download has ended')
    or diag explain $job;
ok(scalar(timers_of(10)), 'and the session stops from a timer');

my $left = $dispatch->('source.disconnect', { source_id => 'lab' });
isnt($left->{code} // '', 'source_busy', 'a disconnect in that moment is not refused')
    or diag explain $left;
ok(!$left->{__bridge_error}, 'it goes ahead') or diag explain $left;

done_testing();
