use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

use lib File::Spec->catdir($Bin, '..', 'lib');

use FServe::Model qw(identity_key size_to_bytes);
use FServe::Discovery::SysResetFind;

sub fixture_path {
    my ($name) = @_;
    return File::Spec->catfile($Bin, '..', 'protocol-fixtures', $name);
}

sub read_fixture_events {
    my ($name, $parser, $sender) = @_;
    open my $fh, '<', fixture_path($name) or die "Cannot read fixture $name: $!";
    my @events;
    while (my $line = <$fh>) {
        push @events, @{$parser->feed_line($sender, $line)};
    }
    close $fh;
    return \@events;
}

sub result_events {
    my ($events) = @_;
    return map { $_->{result} } grep { $_->{type} eq 'result' } @{$events};
}

my $single = FServe::Discovery::SysResetFind->new(
    network_id       => 'fserve-lab',
    server_tag       => 'FServeLab',
    discovery_channel => '#fserve-test',
    source_timestamp => '2026-09-23T06:38:41Z',
);
my $single_events = read_fixture_events('find-single.txt', $single, 'CaptainEpix');
my @single_results = result_events($single_events);
is scalar(@single_results), 1, 'single-result fixture yields one normalized result';
is $single_results[0]{remote_path}, '/Movies/normal-file.txt', 'backslash path is normalized';
is $single_results[0]{parent_path}, '/Movies', 'parent path is derived';
is $single_results[0]{basename}, 'normal-file.txt', 'basename is derived';
is $single_results[0]{size_bytes}, 27, 'byte size is parsed';
is $single_results[0]{trigger_raw}, '!fserve', 'trigger is retained';
is $single_results[0]{source}, 'find', 'source provenance is retained';
is $single_results[0]{source_timestamp}, '2026-09-23T06:38:41Z', 'source timestamp is retained';
is $single_results[0]{discovery_channel}, '#fserve-test', 'source channel is retained for future catalog retrieval';
is $single_results[0]{server_nick}, 'CaptainEpix', 'sender identity is retained';
is $single_results[0]{trigger_mode}, 'channel_text', 'trigger mode is retained';
is $single_results[0]{section_found_count}, 1, 'declared section count is retained';
is scalar(grep { $_->{type} eq 'end' && $_->{complete} } @{$single_events}), 1,
    'explicit End of @Find closes the block';

my $multiple = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my @multiple_results = result_events(
    read_fixture_events('find-multiple-results.txt', $multiple, 'CaptainEpix')
);
is scalar(@multiple_results), 3, 'multiple-result fixture yields all files';
is_deeply [ map { $_->{basename} } @multiple_results ],
    [ '21.txt', '11.txt', '1.txt' ],
    'server result order is preserved';
is $multiple_results[0]{remote_path}, '/Pagination/21.txt', 'nested path is normalized';

my $multiterm = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my @multiterm_results = result_events(
    read_fixture_events('find-multiterm.txt', $multiterm, 'CaptainEpix')
);
is scalar(@multiterm_results), 1, 'multi-term fixture yields its server result';
is $multiterm_results[0]{basename}, 'filename with spaces.txt',
    'spaces in a returned filename are preserved';
is $multiterm_results[0]{size_bytes}, 32, 'multi-term result size is parsed';

my $second = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my @second_results = result_events(
    read_fixture_events('find-second-trigger-only.txt', $second, 'CaptainEpix')
);
is scalar(@second_results), 1, 'second-trigger fixture yields one result';
is $second_results[0]{trigger_raw}, '!fserve2', 'second trigger is retained';
is $second_results[0]{remote_path}, '/SecondOnly/second-trigger-only.txt',
    'second-trigger path is normalized';
is $second_results[0]{sends_used}, 0, 'send usage is parsed';
is $second_results[0]{sends_max}, 1, 'send limit is parsed';
is $second_results[0]{queues_used}, 0, 'queue usage is parsed';
is $second_results[0]{queues_max}, 1, 'queue limit is parsed';

my $ctcp = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my @ctcp_results = result_events(
    read_fixture_events('find-ctcp-trigger.txt', $ctcp, 'CaptainEpix')
);
is scalar(@ctcp_results), 1, 'serialized CTCP trigger fixture yields one result';
is $ctcp_results[0]{trigger_raw}, '!fserve2', 'CTCP command is normalized to its payload';
is $ctcp_results[0]{trigger_mode}, 'ctcp', 'serialized CTCP command selects CTCP fetch mode';

my $wrong_ctcp = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my @wrong_ctcp_events;
push @wrong_ctcp_events, @{$wrong_ctcp->feed_line('CaptainEpix', '[@Find Results] -=SysReset 2.55=-')};
push @wrong_ctcp_events, @{$wrong_ctcp->feed_line('CaptainEpix', 'Found [1] file on Trigger:[/ctcp OtherNick !fserve2] - Sends:[0/1] - Queues:[0/1]')};
is $wrong_ctcp_events[-1]{type}, 'parse_error', 'CTCP target mismatch is rejected';
like $wrong_ctcp_events[-1]{reason}, qr/target does not match/i,
    'CTCP target mismatch explains why trigger was rejected';
my $wrong_ctcp_file = $wrong_ctcp->feed_line('CaptainEpix', 'File: [unsafe.txt] - Size [8B]')->[0];
is $wrong_ctcp_file->{type}, 'parse_error', 'file after rejected trigger cannot inherit an earlier trigger section';

my $triggers = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my @trigger_results = result_events(
    read_fixture_events('find-multi-trigger.txt', $triggers, 'CaptainEpix')
);
is scalar(@trigger_results), 2, 'one block can contain multiple trigger sections';
isnt identity_key($trigger_results[0]), identity_key($trigger_results[1]),
    'trigger is part of remote-file identity';
is_deeply [ map { $_->{trigger_raw} } @trigger_results ], [ '!fserve', '!fserve2' ],
    'each file belongs to its most recent trigger section';
is $trigger_results[0]{remote_path}, $trigger_results[1]{remote_path},
    'same-path results remain represented separately';

my $interleaved = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my @interleaved_events;
push @interleaved_events, @{$interleaved->feed_line('Alice', '<Alice> [@Find Results] -=SysReset 2.55=-')};
push @interleaved_events, @{$interleaved->feed_line('Alice', '<Alice> Found [1] file on Trigger:[!a] - Sends:[0/1] - Queues:[0/1]')};
push @interleaved_events, @{$interleaved->feed_line('Alice', '<Alice> File: [A.txt] - Size [1B]')};
push @interleaved_events, @{$interleaved->feed_line('Bob', '<Bob> [@Find Results] -=SysReset 2.55=-')};
push @interleaved_events, @{$interleaved->feed_line('Bob', '<Bob> Found [1] file on Trigger:[!b] - Sends:[0/1] - Queues:[0/1]')};
push @interleaved_events, @{$interleaved->feed_line('Bob', '<Bob> File: [B.txt] - Size [2B]')};
push @interleaved_events, @{$interleaved->feed_line('Bob', '<Bob> End of @Find.')};
push @interleaved_events, @{$interleaved->feed_line('Alice', '<Alice> End of @Find.')};
my @interleaved_results = result_events(\@interleaved_events);
is scalar(@interleaved_results), 2, 'sender state remains independent when responses interleave';
is_deeply [ map { $_->{server_nick} . ':' . $_->{basename} } @interleaved_results ],
    [ 'Alice:A.txt', 'Bob:B.txt' ],
    'interleaved results retain their sender';
is scalar(@{$interleaved->active_senders}), 0, 'both interleaved blocks close independently';

# This companion is behavioral documentation: silence is the observed
# zero-result response, so the parser reports zero only at the caller's timeout.
open my $zero_fh, '<', fixture_path('find-zero-result.md')
    or die "Cannot read zero-result fixture: $!";
my $zero_doc = do { local $/; <$zero_fh> };
close $zero_fh;
like $zero_doc, qr/no\s+\@Find\s+response/i, 'zero-result fixture documents silence';
my $silent = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my $silent_timeout = $silent->timeout('CaptainEpix')->[0];
is $silent_timeout->{type}, 'timeout', 'silent query ends through an explicit timeout';
is $silent_timeout->{had_block}, 0, 'silence is not reported as a completed result block';
is_deeply $silent_timeout->{results}, [], 'silent query has zero observed results';

my $partial = FServe::Discovery::SysResetFind->new(network_id => 'lab');
$partial->feed_line('QuietBot', '[@Find Results] -=SysReset 2.55=-');
$partial->feed_line('QuietBot', 'Found [1] file on Trigger:[!quiet] - Sends:[0/1] - Queues:[0/1]');
$partial->feed_line('QuietBot', 'File: [partial.txt] - Size [3B]');
my $partial_timeout = $partial->timeout('QuietBot')->[0];
is $partial_timeout->{had_block}, 1, 'timeout reports an unfinished block';
is scalar(@{$partial_timeout->{results}}), 1, 'timeout preserves results already observed';

my $status = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my $status_events = $status->feed_line('CaptainEpix', 'Flood protection: try again later');
is $status_events->[0]{type}, 'status', 'flood notice is surfaced as status';

my $bad = FServe::Discovery::SysResetFind->new(network_id => 'lab');
$bad->feed_line('CaptainEpix', '[@Find Results] -=SysReset 2.55=-');
$bad->feed_line('CaptainEpix', 'Found [1] file on Trigger:[!fserve] - Sends:[0/1] - Queues:[0/1]');
my $bad_events = $bad->feed_line('CaptainEpix', 'File: [../secret.txt] - Size [1B]');
is scalar(grep { $_->{type} eq 'parse_error' } @{$bad_events}), 1,
    'path traversal is rejected by the normalized model';
is_deeply $bad->results_for('CaptainEpix'), [], 'rejected path is not added to results';

my $malformed = FServe::Discovery::SysResetFind->new(network_id => 'lab');
my $orphan = $malformed->feed_line(
    'CaptainEpix', 'File: [orphan.txt] - Size [1B]'
);
is $orphan->[0]{type}, 'parse_error', 'file before trigger section is rejected';

is size_to_bytes('1.5MB'), 1572864, 'model size parser supports decimal units';
is size_to_bytes('42.4MB'), 44459622, 'model size parser rounds byte counts';

# FServe.pl 2.0.0's answer, as a real one sent it on 2026-10-20 (names changed).
my $fservepl = FServe::Discovery::SysResetFind->new(
    network_id => 'net', server_tag => 'net', discovery_channel => '#rpg-library',
    source_timestamp => '2026-10-20T00:00:00Z',
);
my @fp_events = map { @{$fservepl->feed_line('fsnick', $_)} } (
    'Find Results for (Star.*Wars) - [FServe.pl 2.0.0]',
    'Found 3 file(s) on trigger:(/ctcp fsnick !fsnick) Sends:(0/2000) Queues:(0/2000)',
    '1. File: (###Work-in-Progress/Space Saga - Revised, Expanded, and Updated [_oef_].pdf) Size:(75.95 MB)',
    '2. File: (###Work-in-Progress/TriSystem/Space Saga [_oef_].pdf) Size:(1.16 MB)',
    '3. File: (###Work-in-Progress/Space Saga Edition/1 - SAGA EDITION - Space Saga Roleplaying Game [_scan_].pdf) Size:(36.92 MB)',
    'End of Find.',
);
is_deeply [map { $_->{type} } @fp_events], [qw(header section result result result end)],
    'FServe.pl: header, trigger section, three files, end';
my @fp_results = result_events(\@fp_events);
is $fp_results[1]{remote_path}, '/###Work-in-Progress/TriSystem/Space Saga [_oef_].pdf',
    'FServe.pl: the path, from the root';
is $fp_results[1]{trigger_raw}, '!fsnick', 'FServe.pl: the CTCP trigger payload';
is $fp_results[1]{trigger_mode}, 'ctcp', 'FServe.pl: sent as CTCP';
is $fp_results[1]{size_bytes}, size_to_bytes('1.16 MB'), 'FServe.pl: the size';
ok $fp_events[-1]{complete}, 'FServe.pl: the block is complete';
my $fp_other = FServe::Discovery::SysResetFind->new(discovery_channel => '#rpg-library');
my @fp_wrong = map { @{$fp_other->feed_line('fsnick', $_)} } (
    'Find Results for (x) - [FServe.pl 2.0.0]',
    'Found 1 file(s) on trigger:(/ctcp someoneelse !x) Sends:(0/1) Queues:(0/1)',
);
is $fp_wrong[-1]{type}, 'parse_error', 'FServe.pl: a CTCP trigger naming another nick is refused';
my $fp_upstream = FServe::Discovery::SysResetFind->new(discovery_channel => '#rpg-library');
is_deeply [map { $_->{type} } map { @{$fp_upstream->feed_line('fsnick', $_)} } (
    '(@Find Results) - [FServe.pl 2.0.0]',
    'Found 1 file(s) on trigger:(/ctcp fsnick !fsnick) Sends:(0/2) Queues:(0/2)',
    '1. File: (a/b.pdf) Size:(1.0 kB)',
    'End of @Find.',
)], [qw(header section result end)], 'FServe.pl: the upstream script\'s own wording too';

done_testing;
