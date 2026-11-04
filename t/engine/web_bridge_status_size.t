#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

# The engine's status reply lists the most recent jobs, with each name and
# path cut at 512 characters. Twenty of them, in a script of three bytes a
# character, came to 71 KB: more than one bridge frame of 64 KiB, and a
# reply over that closed the connection, which the web service then opened
# again only to ask for the same status. The oldest jobs are now left out
# until the reply fits.

use FindBin;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

sub job {
    my ($n, $char, $length) = @_;
    return {
        id => sprintf('job-%032x', $n), state => 'stale', provider => 'fserve',
        outcome => 'live_parent_file_missing',
        reason => 'GET_VERIFY_FAILED target file was not present after verified navigation',
        network_profile => 'fserve-web-0123456789ab-0123abcd-1',
        selection => {
            expected_peer => 'SomeFileServer',
            basename => $char x $length,
            remote_path => '/' . ($char x 40) . '/' . ($char x $length),
        },
        created_at => 1792039149 + $n, updated_at => 1792039150 + $n,
        transition_sequence => 7,
        context => { web_operation_id => 'web-download-' . ('a' x 64) },
    };
}

# The status as the bridge sends it, newest job first.
sub status_with {
    my ($char, $length) = @_;
    my @jobs = map { Irssi::Script::dccatlas::web_bridge_job_view(job($_, $char, $length)) }
        reverse 1 .. 20;
    return Irssi::Script::dccatlas::web_bridge_fit_status({
        engine_instance_id => 'e' x 32, event_sequence => 12345,
        servers => [], source => undef, sources => [], search => undef, searches => {},
        jobs => \@jobs, journal_ready => JSON::PP::true,
    });
}

# The whole frame, with the longest request ID the bridge allows.
sub frame_bytes {
    my ($result) = @_;
    return length(JSON::PP->new->canonical(1)->utf8(1)->encode({
        protocol_version => 1, request_id => 'r' x 128, ok => JSON::PP::true,
        result => $result,
    })) + 1;
}

my $ascii = status_with('a', 120);
is scalar(@{$ascii->{jobs}}), 20, 'ordinary names: all twenty jobs are listed';
ok !exists($ascii->{jobs_omitted}), 'and none is said to be left out';

my $long = status_with("\x{65e5}", 512);
cmp_ok frame_bytes($long), '<=', 65536, 'the longest names still make a reply that fits in one frame';
ok $long->{jobs_omitted} > 0, 'some jobs are left out';
is scalar(@{$long->{jobs}}) + $long->{jobs_omitted}, 20, 'and their number is given';
is $long->{jobs}[0]{job_id}, sprintf('job-%032x', 20), 'the newest job is kept';
is $long->{jobs}[-1]{job_id}, sprintf('job-%032x', 21 - @{$long->{jobs}}),
    'and it is the oldest that are left out';

done_testing();
