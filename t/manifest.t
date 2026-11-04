use strict;
use warnings;
use utf8;

use Encode qw(encode);
use File::Temp qw(tempdir);
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use FServe::Discovery::Manifest qw(new_provider);

my $temp_dir = tempdir(CLEANUP => 1);
my $manifest_path = "$temp_dir/TicTocTome-FullFiles-List.txt";
my $manifest = <<'LIST';
├── [   0]  Favorites
│   ├── [ 70K]  Favorites\7th Sea\New Player Guide.pdf
│   ├── [1.6M]  Favorites\Unicode – Résumé.pdf
└── [   0]  Unsorted
    └── [  42]  Unsorted\Small file.txt
LIST

sub write_utf8 {
    my ($path, $text) = @_;
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} encode('UTF-8', $text) or die "write $path: $!";
    close $fh or die "close $path: $!";
}

write_utf8($manifest_path, $manifest);

my $provider = new_provider(known_paths => ['/Pinned/manifest.data']);
my $candidates = $provider->discover_candidates([
    { type => 'file', remote_path => 'TicTocTome-FullFiles-List.txt', source => 'find', network_id => 'N1', server_tag => 's1', server_nick => 'Alpha', trigger_raw => '!one', trigger_mode => 'ctcp' },
    { type => 'file', remote_path => '/Archive/Inventory.csv' },
    { type => 'file', remote_path => '/Archive/FullFiles-List.7z' },
    { type => 'dir',  remote_path => '/NotAFile/FullFiles-List.txt' },
    { type => 'file', remote_path => '/Pinned/manifest.data' },
    { type => 'file', remote_path => '/misc/Catalog.csv' },
    { type => 'file', remote_path => '/tictoctome-FullFiles-List.TXT', network_id => 'N2', server_tag => 's2', server_nick => 'Beta', trigger_raw => '!two', trigger_mode => 'ctcp' },
]);
is scalar(@$candidates), 5, 'candidate discovery filters directories and unsupported archive extensions while preserving distinct routes';
is $candidates->[0]{remote_path}, '/Pinned/manifest.data',
    'configured exact path ranks above filename heuristics';
is $candidates->[1]{remote_path}, '/TicTocTome-FullFiles-List.txt',
    'full file-list names are recognized and normalized';
is $candidates->[1]{score}, 120, 'specific full-files-list pattern receives the strongest heuristic score';
is $candidates->[3]{remote_path}, '/Archive/Inventory.csv',
    'inventory name is included as a lower-confidence candidate';
is $candidates->[4]{remote_path}, '/misc/Catalog.csv',
    'catalog name is included as a lower-confidence candidate';
is scalar(@{$provider->discover_candidates([
    { type => 'file', remote_path => '/A/FullFiles-List.txt', network_id => 'n', server_nick => 'bot', trigger_raw => '!files' },
    { type => 'file', remote_path => '/A/FullFiles-List.txt', network_id => 'n', server_nick => 'bot', trigger_raw => '!files' },
])}), 1, 'exact duplicate candidates within one route are collapsed';
is scalar(@{$provider->discover_candidates([
    { type => 'file', remote_path => '/A/FullFiles-List.txt', network_id => 'n1', server_nick => 'bot', trigger_raw => '!files' },
    { type => 'file', remote_path => '/A/FullFiles-List.txt', network_id => 'n2', server_nick => 'bot', trigger_raw => '!files' },
    { type => 'file', remote_path => '/A/FullFiles-List.txt', network_id => 'n1', server_nick => 'bot', trigger_raw => '!other' },
])}), 3, 'same path from distinct network or trigger contexts remains separately selectable';
is scalar(@{$provider->discover_candidates([
    { type => 'file', remote_path => '/A/FullFiles-List.txt' },
    { type => 'file', remote_path => '/a/fullfiles-list.TXT' },
])}), 2, 'case-distinct remote paths are preserved absent a route-specific path policy';
my $scoped_provider = new_provider(known_paths => [{
    path => '/List/FullFiles-List.txt', network_id => 'net-a', server_tag => 'a',
    server_nick => 'BotA', trigger_raw => '!one', trigger_mode => 'ctcp',
}]);
my $scoped = $scoped_provider->discover_candidates([
    { type => 'file', remote_path => '/List/FullFiles-List.txt', network_id => 'net-a', server_tag => 'a', server_nick => 'BotA', trigger_raw => '!one', trigger_mode => 'ctcp' },
    { type => 'file', remote_path => '/List/FullFiles-List.txt', network_id => 'net-b', server_tag => 'b', server_nick => 'BotB', trigger_raw => '!two', trigger_mode => 'ctcp' },
]);
is $scoped->[0]{score}, 1000, 'configured manifest paths rank exactly for their configured route';
is $scoped->[1]{score}, 120, 'a scoped known path does not leak to another server route';
is scalar(@{$provider->discover_candidates([
    { type => 'file', remote_path => '/A/one.txt' },
    { type => 'file', remote_path => '/B/Inventory.txt' },
], limit => 1)}), 1, 'candidate result limit is applied after ranking';
is scalar(@{$provider->discover_candidates([
    { type => 'file', remote_path => 'C:\\FullFiles-List.txt' },
    { type => 'file', remote_path => '\\\\server\\FullFiles-List.txt' },
])}), 0, 'drive and UNC paths are not treated as remote-root candidates';

my @records;
my $parsed = $provider->parse_file(
    $manifest_path,
    network_id          => 'irc.gamenet.example',
    server_tag          => 'GameNet',
    server_nick         => 'TNW',
    trigger_raw         => '!TNW',
    trigger_mode        => 'ctcp',
    discovery_channel   => '#rpg-library',
    source_timestamp    => '2026-09-26T10:00:00Z',
    manifest_remote_path => '/TicTocTome-FullFiles-List.txt',
    on_record           => sub { push @records, $_[0] },
);
ok $parsed->{ok}, 'the tree-size full-list dialect parses successfully';
is $parsed->{format}, 'box-tree-size-v1', 'the detected format has a stable parser identifier';
is $parsed->{lines}, 5, 'all inventory lines are streamed';
is $parsed->{rows}, 5, 'all rows are counted';
is $parsed->{directories}, 2, 'zero-size rows are classified as directory rows';
is $parsed->{files}, 3, 'nonzero rows are classified as files';
is $parsed->{estimated_sizes}, 2, 'human-readable K/M sizes are marked as estimates';
is $parsed->{records_emitted}, 3, 'validated file records are emitted through the callback';
is scalar(@records), 3, 'the parser does not retain a complete result array';
is $records[0]{remote_path}, '/Favorites/7th Sea/New Player Guide.pdf',
    'Windows-style paths become normalized root-relative paths';
is $records[0]{server_nick}, 'TNW', 'server provenance is attached to each file';
is $records[0]{trigger_raw}, '!TNW', 'trigger provenance is attached to each file';
is $records[0]{trigger_mode}, 'ctcp', 'the caller-selected retrieval mode is preserved';
is $records[0]{discovery_channel}, '#rpg-library', 'channel context is preserved';
is $records[0]{source}, 'manifest', 'manifest provenance is assigned';
is $records[0]{manifest_format}, 'box-tree-size-v1', 'format provenance is assigned';
is $records[0]{manifest_remote_path}, '/TicTocTome-FullFiles-List.txt',
    'the manifest remote path is retained separately from each indexed file path';
is $records[0]{size_raw}, '70K', 'the source size text is preserved';
is $records[0]{size_bytes}, 71680, 'the K unit is converted using the existing 1024-byte convention';
ok $records[0]{size_is_estimate}, 'rounded K size is not represented as exact';
is $records[1]{size_bytes}, 1677722, 'decimal M size converts to an advisory byte estimate';
ok $records[1]{size_is_estimate}, 'decimal M size is marked approximate';
is $records[2]{size_bytes}, 42, 'unitless small sizes are interpreted as exact bytes';
ok !$records[2]{size_is_estimate}, 'unitless byte size remains exact';
like $parsed->{sha256}, qr/\A[0-9a-f]{64}\z/, 'the validated source snapshot is fingerprinted';

my $stats_only = $provider->parse_file(
    $manifest_path,
    server_nick => 'TNW', trigger_raw => '!TNW',
);
ok $stats_only->{ok}, 'stats-only parsing does not require record collection';
is $stats_only->{records_emitted}, 0, 'stats-only mode emits no records';
is $stats_only->{bytes_read}, -s $manifest_path, 'stream byte accounting matches the source file';

my $too_long_path = "$temp_dir/long-line.txt";
write_utf8($too_long_path, "├── [ 12]  Safe\\ok.pdf\n" . ('x' x 128) . "\n");
my $too_long = $provider->parse_file(
    $too_long_path, server_nick => 'TNW', trigger_raw => '!TNW',
    max_line_bytes => 64,
);
ok !$too_long->{ok}, 'an overlong trailing line refuses the source before emission';
like $too_long->{reason}, qr/line exceeds/, 'overlong-line refusal explains its bound';

my $too_many = $provider->parse_file(
    $manifest_path, server_nick => 'TNW', trigger_raw => '!TNW', max_rows => 2,
);
ok !$too_many->{ok}, 'row limits are enforced during validation';
like $too_many->{reason}, qr/row limit/, 'row-limit refusal is explicit';
my $cancelled = $provider->parse_file(
    $manifest_path, server_nick => 'TNW', trigger_raw => '!TNW',
    should_cancel => sub { 1 },
);
ok !$cancelled->{ok}, 'cancellation is checked while reading the source';
like $cancelled->{reason}, qr/cancelled/, 'cancelled parse has an explicit refusal result';

my $bad_path = "$temp_dir/malformed.txt";
write_utf8($bad_path, "├── [ 12]  Safe\\ok.pdf\nnot a tree row\n");
my $callback_count = 0;
my $malformed = $provider->parse_file(
    $bad_path,
    server_nick => 'TNW', trigger_raw => '!TNW',
    on_record => sub { $callback_count++ },
);
ok !$malformed->{ok}, 'a malformed trailing row refuses the whole manifest';
like $malformed->{reason}, qr/malformed|unrecognized/, 'failure explains the rejected row';
is $callback_count, 0, 'no records are emitted until a full validation pass succeeds';

my $traversal_path = "$temp_dir/traversal.txt";
write_utf8($traversal_path, "├── [ 12]  Favorites\\..\\outside.pdf\n");
my $traversal = $provider->parse_file(
    $traversal_path,
    server_nick => 'TNW', trigger_raw => '!TNW',
);
ok !$traversal->{ok}, 'parent traversal in a listed path is rejected';
like $traversal->{reason}, qr/unrecognized|malformed|unsafe path/,
    'unsafe path rejection remains a fail-closed parse result';

my $unknown_path = "$temp_dir/unknown.txt";
write_utf8($unknown_path, "A headline rather than an inventory\n");
my $unknown = $provider->parse_file(
    $unknown_path,
    server_nick => 'TNW', trigger_raw => '!TNW',
);
ok !$unknown->{ok}, 'an unknown format is refused instead of producing an empty catalog';
like $unknown->{reason}, qr/unrecognized manifest format/, 'unknown format identifies a safe fallback condition';

my $custom_provider = new_provider(parsers => [{
    name => 'pipe-list-v1',
    detect => sub { $_[0] =~ /^FILE\|/ },
    parse_line => sub {
        my ($line) = @_;
        my ($path, $bytes) = $line =~ /^FILE\|([^|]+)\|(\d+)$/;
        return unless defined $path;
        return {
            remote_path      => $path,
            size_raw         => "$bytes B",
            size_bytes       => 0 + $bytes,
            size_is_estimate => 0,
            is_directory     => 0,
        };
    },
}]);
my $custom_path = "$temp_dir/custom.txt";
write_utf8($custom_path, "FILE|Custom\\Report.txt|99\n");
my @custom_records;
my $custom = $custom_provider->parse_file(
    $custom_path,
    server_nick => 'TNW', trigger_raw => '!TNW',
    on_record => sub { push @custom_records, $_[0] },
);
ok $custom->{ok}, 'additional manifest dialects can be registered without changing the provider';
is $custom->{format}, 'pipe-list-v1', 'the registered dialect is detected';
is $custom_records[0]{remote_path}, '/Custom/Report.txt', 'registered parsers normalize to the common record model';

my $duplicate_parser = eval {
    $custom_provider->register_parser(
        name => 'pipe-list-v1', detect => sub { 1 }, parse_line => sub { {} },
    );
    1;
};
ok !$duplicate_parser, 'duplicate parser identifiers are rejected';

my $unsafe_custom = new_provider(parsers => [{
    name => 'unsafe-v1', detect => sub { $_[0] =~ /^BAD\|/ },
    parse_line => sub { return { remote_path => '../escape.pdf', size_raw => '1 B', size_bytes => 1 } },
}]);
my $unsafe_custom_path = "$temp_dir/unsafe-custom.txt";
write_utf8($unsafe_custom_path, "BAD|row\n");
my $unsafe_custom_result = $unsafe_custom->parse_file(
    $unsafe_custom_path, server_nick => 'TNW', trigger_raw => '!TNW',
);
ok !$unsafe_custom_result->{ok}, 'registered parsers share common path validation in stats-only mode';

{
    package FServe::Test::FailingRead;
    sub TIEHANDLE { bless { reads => 0 }, shift }
    sub READ {
        my ($self, undef, $length) = @_;
        if (!$self->{reads}++) {
            my $row = "[42]  Good.txt\n";
            $_[1] = $row;
            return length($row);
        }
        $! = 5;
        return undef;
    }
    sub READLINE {
        my ($self) = @_;
        return "[42]  Good.txt\n" if !$self->{reads}++;
        $! = 5;
        return undef;
    }
}
tie *READ_ERROR, 'FServe::Test::FailingRead';
local $SIG{__WARN__} = sub {};
my $read_error = FServe::Discovery::Manifest::_scan_handle(
    $provider, \*READ_ERROR, { server_nick => 'TNW', trigger_raw => '!TNW' }, undef,
);
ok !$read_error->{ok}, 'a valid prefix followed by a low-level read failure is not accepted as EOF';
like $read_error->{reason}, qr/read failed/, 'input read failure is reported as a refusal';

# A list sent on "@Nick" by one file server (2026-10-29): a line about the
# server, then "[folder/]" headings ("[]" the top; a name may hold "]") and
# indented "name   (size)" rows.
subtest 'bracketed folders with indented rows' => sub {
    my $path = "$temp_dir/bracket.txt";
    write_utf8($path, join("\n",
        'RPG books, all sorts. Trigger: /ctcp Quill !quill', '',
        '[]', '  .ignore   (0 B)', '',
        '[#Work/]', '  Draft [_oef_].pdf   (9.74 MB)', '  Notes.rtf   (3.3 kB)', '',
        '[#Work/Oath, The (1991-2014])/]', "  R\x{e9}sum\x{e9} - Issue 21.pdf   (6.72 MB)", '',
        '[Empty/]', ''));
    my @rows;
    my $read = $provider->parse_file($path, server_nick => 'Quill', trigger_raw => '!quill',
        trigger_mode => 'ctcp', on_record => sub { push @rows, $_[0] });
    ok($read->{ok}, 'read') or diag explain $read;
    is($read->{format}, 'bracket-folders-v1', 'as bracketed folders');
    is($read->{directories}, 4, 'four folders');
    is_deeply([map { [$_->{remote_path}, $_->{size_raw}] } @rows], [
        ['/.ignore', '0 B'],
        ['/#Work/Draft [_oef_].pdf', '9.74 MB'],
        ['/#Work/Notes.rtf', '3.3 kB'],
        ["/#Work/Oath, The (1991-2014])/R\x{e9}sum\x{e9} - Issue 21.pdf", '6.72 MB'],
    ], 'each file under its folder, the line about the server passed over');
    is($rows[0]{size_bytes}, 0, 'an exact size in bytes');

    for my $bad (['a folder climbing out', '[../]'],
                 ['words under a folder', '[A/]', 'nothing'],
                 ['too many lines before the first folder',
                  'one', 'two', 'three', 'four', 'five', '[]', '  a.txt   (1 B)']) {
        my ($label, @lines) = @$bad;
        write_utf8($path, join("\n", 'Trigger: /ctcp Quill !quill', @lines, ''));
        ok(!$provider->parse_file($path, server_nick => 'Quill', trigger_raw => '!quill')->{ok},
            "refused: $label");
    }
};

done_testing();
