use strict;
use warnings;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib "$Bin/../lib";

use FServe::Catalog qw(
    add_record append_observation append_observations count_type files load_jsonl matching_files
    new_store record_count records search_records write_catalog
);

my $catalog = [
    { type => 'dir', path => '/Movies' },
    { type => 'file', path => '/Movies/One.txt', size_raw => '12 B', size_bytes => 12 },
    { type => 'dir', path => '/Other' },
    { type => 'file', path => "/Other/a\tb.txt", size_raw => "2\nKB" },
    'not-a-record',
];

is_deeply [map { $_->{path} } @{files($catalog)}],
    ['/Movies/One.txt', "/Other/a\tb.txt"],
    'file selection excludes directories and malformed entries';
is count_type($catalog, 'file'), 2, 'type count includes matching catalog records';
is count_type($catalog, 'dir'), 2, 'directory count includes matching catalog records';
is count_type($catalog, 'missing'), 0, 'unknown type count is zero';

my $all_matches = matching_files($catalog, '');
is_deeply [map { $_->{index} } @$all_matches], [1, 2],
    'unfiltered search keeps the stable file index';
is_deeply [map { $_->{file}{path} } @$all_matches],
    ['/Movies/One.txt', "/Other/a\tb.txt"],
    'search results retain references to the catalog records';
my $filtered = matching_files($catalog, 'MOVIES/one', 30);
is_deeply [map { [$_->{index}, $_->{file}{path}] } @$filtered],
    [[1, '/Movies/One.txt']], 'path filtering is case-insensitive';
my $limited = matching_files($catalog, '', 1);
is_deeply [map { $_->{index} } @$limited], [1],
    'result limit applies after file filtering';
is_deeply matching_files(undef, 'anything'), [],
    'malformed catalog input yields no matches';

my $out_dir = tempdir(CLEANUP => 1);
my $jsonl_path = "$out_dir/catalog.jsonl";
my $tsv_path = "$out_dir/catalog.tsv";
ok write_catalog($catalog, $jsonl_path, $tsv_path),
    'catalog export succeeds';

open my $json_fh, '<', $jsonl_path or die "open $jsonl_path: $!";
my @json_lines = <$json_fh>;
close $json_fh;
is scalar(@json_lines), 4, 'JSONL export writes each hash record once';
my @rows = map { decode_json($_) } @json_lines;
is_deeply [map { $_->{index} } @rows], [1, 2, 3, 4],
    'JSONL export assigns sequential row indexes';
is $rows[1]{path}, '/Movies/One.txt',
    'JSONL export preserves catalog data';

open my $tsv_fh, '<', $tsv_path or die "open $tsv_path: $!";
my @tsv_lines = <$tsv_fh>;
close $tsv_fh;
is $tsv_lines[0], "index\ttype\tpath\tsize_bytes\tsize_raw\n",
    'TSV export retains its existing header';
is $tsv_lines[2], "2\tfile\t/Movies/One.txt\t12\t12 B\n",
    'TSV export preserves index, path, and size columns';
like $tsv_lines[4], qr{^4\tfile\t/Other/a b.txt\t\t2 KB\n$},
    'TSV export sanitizes embedded tabs and newlines';

my $estimate_jsonl = "$out_dir/estimate.jsonl";
my $estimate_tsv = "$out_dir/estimate.tsv";
ok write_catalog([{
    type => 'file', path => '/Movies/Rounded.pdf',
    size_raw => '70K', size_bytes => 71680, size_is_estimate => 1,
}], $estimate_jsonl, $estimate_tsv), 'estimate export succeeds';
open my $estimate_tsv_fh, '<', $estimate_tsv
    or die "open $estimate_tsv: $!";
my @estimate_tsv_lines = <$estimate_tsv_fh>;
close $estimate_tsv_fh;
is $estimate_tsv_lines[1], "1\tfile\t/Movies/Rounded.pdf\t\t70K\n",
    'TSV does not present a rounded manifest size as an exact byte count';
open my $estimate_jsonl_fh, '<', $estimate_jsonl
    or die "open $estimate_jsonl: $!";
my $estimate_row = decode_json(<$estimate_jsonl_fh>);
close $estimate_jsonl_fh;
is_deeply [@$estimate_row{qw(size_bytes size_is_estimate)}], [71680, 1],
    'JSONL preserves the estimate and its precision flag';

my $store = new_store();
my $find_observation = {
    type => 'file', network_id => 'LabNet', server_tag => 'lab-tag',
    server_nick => 'FileBot', trigger_raw => '!files', trigger_mode => 'channel_text',
    remote_path => '/Movies/Example.txt', size_raw => '8 B', size_bytes => 8,
    source => 'find', source_timestamp => '2026-09-26T10:00:00Z',
    discovery_channel => '#files', discovery_block_id => 3,
};
my $first_record = add_record($store, $find_observation);
is record_count($store), 1, 'first discovery creates one normalized catalog record';
is_deeply $first_record->{sources}, ['find'],
    'source provenance is initialized';
is $first_record->{discovery_channel}, '#files',
    'the @Find channel remains available as provenance';
is_deeply $first_record->{discovery_channels}, ['#files'],
    'channel provenance begins as a list';
is_deeply $first_record->{source_channels}{find}, ['#files'],
    'channel provenance is grouped by discovery source';

my $crawl_observation = {
    %$find_observation,
    network_id => 'labnet', server_nick => 'filebot',
    source => 'crawl', source_timestamp => '2026-09-26T10:05:00Z',
    discovery_channel => '#archive',
    discovery_block_id => undef,
};
my $merged_record = add_record($store, $crawl_observation);
is $merged_record, $first_record,
    'case-insensitive identity merges crawl and @Find observations';
is record_count($store), 1, 'cross-source duplicate does not create a second row';
is_deeply $merged_record->{sources}, ['find', 'crawl'],
    'merged record retains both discovery sources';
is $merged_record->{source}, 'multiple',
    'merged record marks its multi-source provenance';
is $merged_record->{source_timestamps}{find}, '2026-09-26T10:00:00Z',
    'per-source observation time is retained';
is $merged_record->{source_timestamps}{crawl}, '2026-09-26T10:05:00Z',
    'new source observation time is retained';
is_deeply $merged_record->{discovery_channels}, ['#files', '#archive'],
    'records retain all channels across source observations';
is_deeply $merged_record->{source_channels}{crawl}, ['#archive'],
    'channel provenance identifies its source';

my $other_trigger = add_record($store, {
    %$find_observation,
    trigger_raw => '!files2', remote_path => '/Movies/Example.txt',
    source_timestamp => '2026-09-26T10:06:00Z',
});
is record_count($store), 2,
    'same remote path under a different trigger remains a distinct record';

my $estimated_size = add_record($store, {
    %$find_observation,
    remote_path => '/Movies/Rounded.pdf',
    size_raw => '70K', size_bytes => 71680, size_is_estimate => 1,
    source => 'manifest', source_timestamp => '2026-09-26T10:07:00Z',
    manifest_format => 'box-tree-size-v1',
    manifest_remote_path => '/TicTocTome-FullFiles-List.txt',
});
is $estimated_size->{size_is_estimate}, 1,
    'catalog normalization preserves rounded manifest-size provenance';
is $estimated_size->{manifest_format}, 'box-tree-size-v1',
    'catalog normalization preserves the manifest parser identifier';
is $estimated_size->{manifest_remote_path}, '/TicTocTome-FullFiles-List.txt',
    'catalog normalization preserves the manifest source path';
my $exact_size = add_record($store, {
    %$find_observation,
    remote_path => '/Movies/Rounded.pdf',
    size_raw => '70123 B', size_bytes => 70123, size_is_estimate => 0,
    source => 'find', source_timestamp => '2026-09-26T10:08:00Z',
});
is $exact_size->{size_bytes}, 70123,
    'an exact observation replaces an earlier manifest estimate';
ok !$exact_size->{size_is_estimate},
    'exact size precision is retained after merging';
my $late_estimate = add_record($store, {
    %$find_observation,
    remote_path => '/Movies/Rounded.pdf',
    size_raw => '70K', size_bytes => 71680, size_is_estimate => 1,
    source => 'manifest', source_timestamp => '2026-09-26T10:09:00Z',
});
is $late_estimate->{size_bytes}, 70123,
    'a later rounded manifest observation cannot downgrade an exact size';
ok !$late_estimate->{size_is_estimate},
    'catalog records remain marked exact after a lower-precision observation';
is $late_estimate->{size_precision}, 'exact', 'size precision is explicit on normalized records';
is $late_estimate->{size_source}, 'find', 'the selected size retains its contributing source';
is $late_estimate->{size_observed_at}, '2026-09-26T10:08:00Z',
    'the exact byte observation retains its own timestamp';

my $unknown_size = add_record($store, {
    %$find_observation, remote_path => '/Movies/Unknown.pdf', source => 'find',
    size_raw => undef, size_bytes => undef, source_timestamp => '2026-09-26T10:10:00Z',
});
is $unknown_size->{size_precision}, 'unknown', 'missing size is represented as unknown, not exact';
my $unknown_then_estimate = add_record($store, {
    %$find_observation, remote_path => '/Movies/Unknown.pdf', source => 'manifest',
    size_raw => '70K', size_bytes => 71680, size_is_estimate => 1,
    source_timestamp => '2026-09-26T10:11:00Z',
});
is $unknown_then_estimate->{size_bytes}, 71680,
    'an available estimate fills an earlier observation with no size';
is $unknown_then_estimate->{size_precision}, 'estimated',
    'the filled-in value remains explicitly approximate';
is $unknown_then_estimate->{size_source}, 'manifest',
    'size provenance follows the observation providing its value';
my $later_unknown = add_record($store, {
    %$find_observation, remote_path => '/Movies/Unknown.pdf', source => 'crawl',
    size_raw => undef, size_bytes => undef, source_timestamp => '2026-09-26T10:12:00Z',
});
is $later_unknown->{size_bytes}, 71680,
    'a later observation without size data does not erase a usable estimate';
my $new_exact = add_record($store, {
    %$find_observation, remote_path => '/Movies/Unknown.pdf', source => 'crawl',
    size_raw => '70123 B', size_bytes => 70123, source_timestamp => '2026-09-26T10:13:00Z',
});
is $new_exact->{size_bytes}, 70123, 'a newer exact observation replaces the estimate';
is $new_exact->{size_precision}, 'exact', 'the newer size value carries exact precision';
is $new_exact->{size_observed_at}, '2026-09-26T10:13:00Z',
    'new size observations retain their timestamp separately from the record';
my $legacy_rounded = add_record($store, {
    %$find_observation, remote_path => '/Movies/Legacy.pdf', source => 'crawl',
    size_raw => '1.6M', size_bytes => 1677722,
    source_timestamp => '2026-09-26T10:14:00Z',
});
is $legacy_rounded->{size_precision}, 'estimated',
    'legacy rounded unit strings are migrated as estimates even without the old boolean flag';
ok $legacy_rounded->{size_is_estimate},
    'the compatibility precision boolean follows the migrated precision';
is_deeply [map { $_->{index} } @{search_records($store, 'filebot', 50)}], [1, 2, 3, 4, 5],
    'catalog search matches server nick and preserves stable indexes';
is_deeply [map { $_->{index} } @{search_records($store, '!files2')}], [2],
    'catalog search matches trigger text';
is_deeply [map { $_->{index} } @{search_records($store, '/movies/example')}], [1, 2],
    'catalog search matches paths case-insensitively';
is_deeply search_records($store, 'no-such-item'), [],
    'catalog search returns no rows for a non-match';
is scalar(@{records($store)}), 5, 'store records are exposed in insertion order';

my $persist_path = "$out_dir/shared-catalog.jsonl";
ok append_observation($persist_path, $find_observation),
    'first discovery observation appends to durable JSONL';
ok append_observation($persist_path, $crawl_observation),
    'second source observation appends to durable JSONL';
open my $bad_fh, '>>', $persist_path or die "open $persist_path: $!";
print {$bad_fh} "{invalid json}\n";
close $bad_fh;
my ($observations, $invalid_lines) = load_jsonl($persist_path);
is scalar(@$observations), 2, 'valid JSONL observations reload independently';
is $invalid_lines, 1, 'malformed JSONL rows are counted and skipped';
my $reloaded = new_store();
add_record($reloaded, $_) for @$observations;
is record_count($reloaded), 1,
    'replaying durable observations reconstructs the deduplicated catalog';
is_deeply records($reloaded)->[0]{sources}, ['find', 'crawl'],
    'reloaded catalog retains cross-source provenance';
is_deeply records($reloaded)->[0]{discovery_channels}, ['#files', '#archive'],
    'reloaded catalog retains all observed channels';

sub read_raw_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "open $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh or die "close $path: $!";
    return defined($bytes) ? $bytes : '';
}

my $torn_path = "$out_dir/torn.jsonl";
my $torn_tail = '{"type":"file","remote_path":';
open my $torn_fh, '>:raw', $torn_path or die "create $torn_path: $!";
print {$torn_fh} $torn_tail or die "write $torn_path: $!";
close $torn_fh or die "close $torn_path: $!";
append_observations($torn_path, [$find_observation, $other_trigger]);
my $torn_bytes = read_raw_file($torn_path);
like $torn_bytes, qr/^\Q$torn_tail\E\n/, 'append separates an unterminated malformed tail';
my ($after_torn, $torn_invalid) = load_jsonl($torn_path);
is scalar(@$after_torn), 2, 'one and multiple records survive after a torn tail';
is $torn_invalid, 1, 'the original malformed unterminated row is counted once';

my $valid_no_lf_path = "$out_dir/valid-no-final-lf.jsonl";
my $valid_no_lf = JSON::PP->new->canonical(1)->utf8(1)->encode($find_observation);
open my $valid_no_lf_fh, '>:raw', $valid_no_lf_path
    or die "create $valid_no_lf_path: $!";
print {$valid_no_lf_fh} $valid_no_lf or die "write $valid_no_lf_path: $!";
close $valid_no_lf_fh or die "close $valid_no_lf_path: $!";
append_observation($valid_no_lf_path, $other_trigger);
is substr(read_raw_file($valid_no_lf_path), 0, length($valid_no_lf)), $valid_no_lf,
    'append preserves a valid existing row byte-for-byte';
my ($after_valid_no_lf, $valid_no_lf_invalid) = load_jsonl($valid_no_lf_path);
is scalar(@$after_valid_no_lf), 2, 'valid row without a final newline and new row both reload';
is $valid_no_lf_invalid, 0, 'valid no-final-newline row remains valid';

my $empty_path = "$out_dir/empty.jsonl";
open my $empty_fh, '>:raw', $empty_path or die "create $empty_path: $!";
close $empty_fh or die "close $empty_path: $!";
append_observation($empty_path, $find_observation);
my ($empty_rows) = load_jsonl($empty_path);
is scalar(@$empty_rows), 1, 'append to an empty file writes a valid row';

my $new_path = "$out_dir/new.jsonl";
append_observation($new_path, $find_observation);
my ($new_rows) = load_jsonl($new_path);
is scalar(@$new_rows), 1, 'append creates a missing JSONL file';

my $terminated_path = "$out_dir/terminated.jsonl";
open my $terminated_fh, '>:raw', $terminated_path
    or die "create $terminated_path: $!";
print {$terminated_fh} "{invalid json}\n" or die "write $terminated_path: $!";
close $terminated_fh or die "close $terminated_path: $!";
append_observations($terminated_path, [$find_observation, $other_trigger]);
append_observation($terminated_path, $find_observation);
my ($after_terminated, $terminated_invalid) = load_jsonl($terminated_path);
is scalar(@$after_terminated), 3, 'repeated appends preserve newline-terminated rows';
is $terminated_invalid, 1, 'malformed terminated history remains one invalid row';
is substr(read_raw_file($terminated_path), 0, length("{invalid json}\n")),
    "{invalid json}\n", 'malformed existing bytes are preserved unchanged';

my $before_invalid_append = read_raw_file($torn_path);
my $invalid_append_ok = eval {
    append_observations($torn_path, [$find_observation, 'not-a-hash']);
    1;
};
ok !$invalid_append_ok, 'invalid input batch is rejected';
is read_raw_file($torn_path), $before_invalid_append,
    'invalid input is rejected before any catalog bytes change';

done_testing();
