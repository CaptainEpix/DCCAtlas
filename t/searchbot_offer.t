use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;

use lib "$Bin/../lib";
use FServe::Discovery::SearchBotOffer qw(
    expected_archive_filename
    match_result_offer
);

is expected_archive_filename('Jane Example'),
    'SearchBot_results_for__Jane_Example.txt.zip',
    'spaces become underscores in the observed result filename';
is expected_archive_filename('Jane Example!'),
    'SearchBot_results_for__Jane_Example.txt.zip',
    'a terminal exclamation mark is stripped as observed';
is expected_archive_filename('Honey! Watson'),
    'SearchBot_results_for__Honey__Watson.txt.zip',
    'an internal exclamation mark and a space each become underscores';
is expected_archive_filename('Honey? Watson'), undef,
    'unknown special-character mappings fail closed';
is expected_archive_filename('Honey-Watson'), undef,
    'unconfirmed punctuation mappings fail closed';
is expected_archive_filename('Jane_Example'), undef,
    'preexisting underscore mapping is not guessed';
is expected_archive_filename('   '), undef,
    'empty normalized query cannot produce an expected archive name';

my %context = (
    state        => 'awaiting_result',
    collection_id => 'search-42',
    query        => 'Jane Example',
    expected_nick => 'Search',
    server_tag   => 'BookNet',
    expires_at   => 500,
    now          => 400,
);
my $offer = {
    type      => 'GET',
    nick      => 'Search',
    servertag => 'BookNet',
    arg       => 'SearchBot_results_for__Jane_Example.txt.zip',
    size      => 2245,
};

is_deeply match_result_offer($offer, %context), {
    type          => 'matched',
    collection_id => 'search-42',
    filename      => 'SearchBot_results_for__Jane_Example.txt.zip',
    size_bytes    => 2245,
}, 'the exact expected result offer from the configured SearchBot is matched';

my $result = match_result_offer({ %$offer, nick => 'SearchOok' }, %context);
is $result->{type}, 'refusal', 'unconfigured sender nick is refused';
like $result->{reason}, qr/sender or IRC server/, 'sender refusal is explained';

$result = match_result_offer({ %$offer, servertag => 'OtherNetwork' }, %context);
is $result->{type}, 'refusal', 'offer on a different IRC server is refused';

$result = match_result_offer({ %$offer, arg => 'SearchBot_results_for__Other.txt.zip' }, %context);
is $result->{type}, 'refusal', 'a different query result filename is refused';

$result = match_result_offer({ %$offer, arg => 'searchbot_results_for__Jane_Example.txt.zip' }, %context);
is $result->{type}, 'refusal', 'a case-changed result filename is refused rather than treated as the exact offer';

$result = match_result_offer({ %$offer, arg => '..\\SearchBot_results_for__Jane_Example.txt.zip' }, %context);
is $result->{type}, 'refusal', 'path-bearing DCC filenames are refused';

$result = match_result_offer({ %$offer, size => 32 * 1024 * 1024 + 1 }, %context);
is $result->{type}, 'refusal', 'an archive over the hard size limit is refused';

$result = match_result_offer({ %$offer, size => undef }, %context);
is $result->{type}, 'refusal', 'an offer without a declared size is refused';

$result = match_result_offer({ %$offer, type => 'CHAT' }, %context);
is $result->{type}, 'refusal', 'DCC CHAT cannot match a result-file offer';

$result = match_result_offer($offer, %context, now => 501);
is $result->{type}, 'refusal', 'an offer after the active query deadline is stale';
like $result->{reason}, qr/expired/, 'stale offer refusal is explained';
$result = match_result_offer($offer, %context, now => 500);
is $result->{type}, 'refusal', 'an offer at the query deadline is stale as well';
$result = match_result_offer($offer, %context, now => 'not-a-time');
is $result->{type}, 'refusal', 'invalid current time fails closed';

$result = match_result_offer($offer, %context, state => 'complete');
is $result->{type}, 'refusal', 'a completed or superseded query cannot accept offers';

$result = match_result_offer($offer, %context, expected_nick => 'SearchOok');
is $result->{type}, 'refusal', 'the Search nick is not accepted when SearchOok is configured';

done_testing();
