use strict;
use warnings;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IO::Compress::Zip qw($ZipError ZIP_CM_STORE);
use Test::More;

use lib "$Bin/../lib";
use FServe::Discovery::SearchBotArchive qw();

my $temp = tempdir(CLEANUP => 1);
my $path = "$temp/results.zip";

sub make_zip {
    my ($members, $method) = @_;
    my $bytes = '';
    my $zip = IO::Compress::Zip->new(\$bytes,
        Name => $members->[0][0],
        Method => defined($method) ? $method : ZIP_CM_STORE,
    ) or die "could not create ZIP: $ZipError";
    $zip->print($members->[0][1]) or die "could not write ZIP member: $ZipError";
    for my $member (@$members[1 .. $#$members]) {
        $zip->newStream(Name => $member->[0]) or die "could not add ZIP member: $ZipError";
        $zip->print($member->[1]) or die "could not write ZIP member: $ZipError";
    }
    $zip->close or die "could not finish ZIP: $ZipError";
    return $bytes;
}

sub write_zip {
    my ($bytes) = @_;
    open my $fh, '>:raw', $path or die "could not write test archive: $!";
    print {$fh} $bytes or die "could not write test archive: $!";
    close $fh or die "could not close test archive: $!";
}

sub parse {
    return FServe::Discovery::SearchBotArchive::parse_archive($path,
        network_id        => 'ExampleNet',
        server_tag        => 'ExampleNet',
        discovery_channel => '#books',
        query             => 'Example title',
        collection_id     => 'archive-test-collection',
        @_);
}

my $row = "!BookBot Example title.epub ::INFO:: 4 KB\n";
write_zip(make_zip([['SearchBot_results.txt', $row]]));
my $result = parse();
is $result->{type}, 'complete', 'one intact text member publishes a completed collection';
is $result->{result_count}, 1, 'the bounded archive parser stages the recognized row';
is $result->{results}[0]{filename}, 'Example title.epub', 'parsed filename is preserved';
ok ref($result->{parser}), 'completed collection retains its provider for collection-scoped selection';
is $result->{archive_member}, 'SearchBot_results.txt', 'member provenance is retained';
is $result->{decompressed_bytes}, length($row), 'decompressed byte count is reported';

my $started = FServe::Discovery::SearchBotArchive::begin_archive($path,
    network_id => 'ExampleNet', server_tag => 'ExampleNet',
    discovery_channel => '#books', query => 'Example title',
    collection_id => 'incremental-collection');
is $started->{type}, 'pending', 'archive intake can start as a resumable job';
my $incremental = $started;
my $steps = 0;
while ($incremental->{type} eq 'pending') {
    $incremental = FServe::Discovery::SearchBotArchive::step_archive(
        $started->{job}, max_lines => 1, max_read_bytes => 32);
    ++$steps;
}
is $incremental->{type}, 'complete', 'bounded archive steps publish after full validation';
ok $steps > 1, 'archive work yields between byte/line budgets';

write_zip(make_zip([
    ['SearchBot_results.txt', $row],
    ['extra.txt', $row],
]));
$result = parse();
is $result->{type}, 'refusal', 'archives with additional members are refused';
like $result->{reason}, qr/additional members/, 'multi-member refusal is explained';

write_zip(make_zip([['folder/SearchBot_results.txt', $row]]));
$result = parse();
is $result->{type}, 'refusal', 'member paths are refused instead of extracted';

write_zip(make_zip([['SearchBot_results.bin', $row]]));
$result = parse();
is $result->{type}, 'refusal', 'non-text result members are refused';

my $corrupt = make_zip([['SearchBot_results.txt', $row]]);
my $row_at = index($corrupt, $row);
die 'test ZIP writer did not store the expected text payload' if $row_at < 0;
substr($corrupt, $row_at, 1, '?');
write_zip($corrupt);
$result = parse();
is $result->{type}, 'refusal', 'a payload with an invalid CRC is not published';
like $result->{reason}, qr/(?:checksum|trailer)/i,
    'ZIP integrity refusal is explicit';

write_zip(make_zip([['SearchBot_results.txt', $row]]));
$result = parse(max_archive_bytes => 1);
is $result->{type}, 'refusal', 'compressed-byte limit is enforced';
$result = parse(max_input_bytes => 8);
is $result->{type}, 'refusal', 'decompressed-byte limit is enforced';
$result = parse(max_line_length => 8);
is $result->{type}, 'refusal', 'line-length limit is enforced';

write_zip(make_zip([['SearchBot_results.txt',
    "header one\nheader two\n!BookBot Example title.epub\n"]]));
$result = parse(max_physical_lines => 2);
is $result->{type}, 'refusal', 'physical header and row line count is bounded';
like $result->{reason}, qr/physical-line limit/,
    'line-count refusal explains the exhausted work bound';

write_zip(make_zip([['SearchBot_results.txt', "!BookBot First.epub\n!bad row ::INFO::\n"]]));
$result = parse();
is $result->{type}, 'refusal', 'malformed rows refuse the entire staged collection';
ok !exists($result->{results}), 'refusal does not expose previously staged partial rows';

write_zip(make_zip([['SearchBot_results.txt', "$row$row"]]));
$result = parse(max_results => 1);
is $result->{type}, 'refusal', 'result-count limit is enforced before publication';

write_zip("not a ZIP archive\n");
$result = parse();
is $result->{type}, 'refusal', 'invalid archive bytes become a refusal instead of an exception';

done_testing();
