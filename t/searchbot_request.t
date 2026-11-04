use strict;
use warnings;

use FindBin qw($Bin);
use Digest::SHA qw(sha256_hex);
use Test::More;

use lib "$Bin/../lib";
use lib "$Bin/lib";
use FServe::Discovery::SearchBot;
use FServe::Discovery::SearchBotRequest qw(
    validate_candidate validate_content_offer tombstone_key tombstone_matches
);
use Irssi;

sub parsed_candidate {
    my ($row, $channel) = @_;
    my $provider = FServe::Discovery::SearchBot->new(
        network_id => 'MockNet', server_tag => 'mocknet',
        discovery_channel => ($channel // '#books'), query => 'fixture',
        collection_id => 'request-policy-test',
    );
    my $events = $provider->feed_line($row);
    return unless @$events && ($events->[0]{type} // '') eq 'row_staged';
    return $events->[0]{candidate};
}

my $sample = '!Bkx Jane Example - Lessons in Testing (retail).epub ::INFO:: 3.25MB';
my $candidate = parsed_candidate($sample);
ok $candidate, 'user-provided SearchBot sample parses as a candidate';
is $candidate->{request_line}, $sample,
    'original row bytes survive without rebuilding the trigger payload';
is $candidate->{direct_requestable}, 1,
    'sample line is eligible for direct request';
my $valid = validate_candidate($candidate);
is $valid->{type}, 'valid', 'safe selected row passes outgoing request validation';
is $valid->{request_line_digest}, sha256_hex($sample),
    'outgoing request digest is over the exact original bytes';
is $valid->{serialized_line}, "PRIVMSG #books :$sample\r\n",
    'wire record retains the full result including the ::INFO:: size';

my $punctuation = '!Bkx Title.epub ::INFO:: 1KB; "quoted" \\ $x';
my $punctuation_candidate = parsed_candidate($punctuation);
ok $punctuation_candidate && $punctuation_candidate->{direct_requestable},
    'command-like but printable punctuation is permitted in trailing text';
is validate_candidate($punctuation_candidate)->{request_line}, $punctuation,
    'punctuation is passed without command parsing or reconstruction';

for my $case (
    ["!Bkx\tName.epub", qr/(?:printable ASCII|not eligible)/],
    ["!Bkx Name.epub ::INFO:: 1\x01KB", qr/(?:printable ASCII|not eligible)/],
    ["!Bkx Bad\x03Name.epub", qr/(?:printable ASCII|not eligible)/],
    ["!Bkx Bad\e[31mName.epub", qr/(?:printable ASCII|not eligible)/],
    ["!Bkx ../escape.epub", qr/(?:basename|not eligible)/],
    ["!Bkx C:\\escape.epub", qr/(?:basename|not eligible)/],
    ["!Bkx CON.txt", qr/(?:basename|not eligible)/],
) {
    my $bad = parsed_candidate($case->[0]);
    ok $bad, 'unsafe/control row remains displayable when parser fields are recognizable';
    ok !$bad->{direct_requestable}, 'unsafe row is marked non-requestable';
    my $result = validate_candidate($bad);
    is $result->{type}, 'refusal', 'unsafe row is refused before sending';
}

my $non_ascii = parsed_candidate("!Bkx T\x{e9}st.epub");
ok $non_ascii && !$non_ascii->{direct_requestable},
    'non-ASCII source text remains display-only in the initial implementation';

my $overlong = parsed_candidate('!Bkx short.epub ::INFO:: ' . ('X' x 600));
ok $overlong && !$overlong->{direct_requestable},
    'row whose serialized IRC line exceeds 512 bytes is display-only';
like validate_candidate($overlong)->{reason}, qr/512-byte/,
    'overlong request explains its protocol-line refusal';

my $bad_channel = validate_candidate($candidate, channel => 'not-a-channel');
is $bad_channel->{type}, 'refusal', 'unsafe originating channel is refused';

my $server = MockServer->new();
my %identity = Irssi::new_dcc_identity();
my $request = {
    state => 'awaiting_offer', dispatch_attempted => 1,
    server => $server, server_tag => 'mocknet', expected_sender => 'Bkx',
    expected_basename => 'Jane Example - Lessons in Testing (retail).epub',
    max_content_bytes => 1024,
};
my $offer = bless {
    type => 'GET', nick => 'bKX', servertag => 'mocknet',
    arg => $request->{expected_basename}, size => 30, server => $server,
    %identity,
}, 'MockDcc';
is validate_content_offer($offer, $request)->{type}, 'matched',
    'content offer matches expected nick with IRC casemapping and exact name';
is validate_content_offer({ %$offer, nick => 'OtherBot' }, $request)->{type}, 'refusal',
    'wrong content sender is refused';
is validate_content_offer({ %$offer, servertag => 'OtherNet' }, $request)->{type}, 'refusal',
    'wrong network tag is refused';
my $other_server = MockServer->new();
is validate_content_offer({ %$offer, server => $other_server }, $request)->{type}, 'refusal',
    'offer from another connection object is refused even if its tag matches';
my $native_wrapper_offer = { %$offer, server => $server->new_wrapper() };
is validate_content_offer($native_wrapper_offer,
    { %$request, server_identity => 'irssi:' . $server->{_irssi} })->{type}, 'matched',
    'a different native Irssi Perl wrapper for the same connection remains bound';
is validate_content_offer({ %$offer, arg => 'Jane_Example.epub' }, $request)->{type}, 'refusal',
    'filename aliases are not accepted';
my $underscored = 'Jane_Example_-_Lessons_in_Testing_(retail).epub';
is validate_content_offer({ %$offer, arg => $underscored }, $request)->{type}, 'refusal',
    'the underscore name is refused when the request does not name it';
my $with_alias = { %$request, expected_alias => $underscored };
my $alias_match = validate_content_offer({ %$offer, arg => $underscored }, $with_alias);
is $alias_match->{type}, 'matched', 'the underscore name the request names is accepted';
is $alias_match->{filename}, $underscored, 'and is reported as the name offered';
is validate_content_offer($offer, $with_alias)->{type}, 'matched',
    'the exact name still is, with an alias named';
is validate_content_offer({ %$offer, arg => 'Jane_Example.epub' }, $with_alias)->{type}, 'refusal',
    'no other alias is accepted';
is validate_content_offer({ %$offer, arg => $underscored, nick => 'OtherBot' }, $with_alias)->{type},
    'refusal', 'nor the alias from another sender';
is validate_content_offer({ %$offer, arg => lc($request->{expected_basename}) }, $request)->{type}, 'refusal',
    'case-changed DCC names are refused';
# A list request ("@Nick", 2026-10-27) names no file: any one safe .zip or
# .txt from the sender is taken, nothing else, and still only from it.
my $list_request = { %$request, list_request => 1, expected_basename => undef };
my $listed = validate_content_offer({ %$offer, arg => 'Bkx-newlist-27-Oct-2026.zip' },
    $list_request);
is $listed->{type}, 'matched', 'a list request takes a .zip of any name';
is $listed->{filename}, 'Bkx-newlist-27-Oct-2026.zip', 'and reports the name offered';
is validate_content_offer({ %$offer, arg => 'Bkx.TXT' }, $list_request)->{type}, 'matched',
    'or a .txt';
# As one real list server sent its list (2026-10-28), and 7-Zip too.
is validate_content_offer({ %$offer, arg => 'share.VPS.2026-10-22-(1801).rar' },
    $list_request)->{type}, 'matched', 'or a .rar';
is validate_content_offer({ %$offer, arg => 'Bkx.7z' }, $list_request)->{type}, 'matched',
    'or a .7z';
for my $name ('Bkx-setup.exe', 'list.zip.exe', '../list.zip', 'list .zip ', "list\x01.txt",
              'list.rar.exe', 'list.tar.gz') {
    is validate_content_offer({ %$offer, arg => $name }, $list_request)->{type}, 'refusal',
        "a list request refuses [$name]";
}
is validate_content_offer({ %$offer, arg => 'Bkx.zip', nick => 'OtherBot' },
    $list_request)->{type}, 'refusal', 'a list from another nick is refused';
# A nick the operator typed (2026-11-02): its list may come from another
# nick, but only on the same connection, as a list, within the size limit.
my $typed_request = { %$list_request, any_sender => 1 };
is validate_content_offer({ %$offer, arg => 'Bkx.zip', nick => 'OtherBot' },
    $typed_request)->{type}, 'matched', "a typed nick's list may come from another nick";
is validate_content_offer({ %$offer, arg => 'Bkx.zip', nick => 'OtherBot', servertag => 'OtherNet' },
    $typed_request)->{type}, 'refusal', '... but not from another server';
is validate_content_offer({ %$offer, arg => 'Bkx.zip', nick => 'OtherBot', server => $other_server },
    $typed_request)->{type}, 'refusal', '... nor another connection';
is validate_content_offer({ %$offer, arg => 'Bkx.epub', nick => 'OtherBot' },
    $typed_request)->{type}, 'refusal', '... and only a list-shaped name';
is validate_content_offer({ %$offer, arg => 'Bkx.zip', nick => 'OtherBot', size => 1025 },
    $typed_request)->{type}, 'refusal', '... within the size limit';
is validate_content_offer({ %$offer, nick => 'OtherBot' }, { %$request, any_sender => 1 })->{type},
    'refusal', 'a file request ignores any_sender';
is validate_content_offer({ %$offer, arg => 'Bkx.zip', size => 1025 },
    $list_request)->{type}, 'refusal', 'a list over the size limit is refused';
like $FServe::Discovery::SearchBotRequest::LIST_TUPLE_NAME, qr/\x1f/,
    'the list reservation can never be a DCC file name';
is validate_content_offer({ %$offer, size => 0 }, $request)->{type}, 'refusal',
    'zero-sized DCC offer is refused';
is validate_content_offer({ %$offer, size => 1025 }, $request)->{type}, 'refusal',
    'offer above configured cap is refused';
is validate_content_offer({ %$offer, type => 'CHAT' }, $request)->{type}, 'refusal',
    'DCC CHAT cannot satisfy a direct content request';
is validate_content_offer($offer, { %$request, state => 'cancelled' })->{type}, 'refusal',
    'retired requests cannot accept an offer';

is tombstone_key('Net', 'Bkx', 'Title.epub'),
    tombstone_key('net', 'bkx', 'Title.epub'),
    'stale-offer tuple uses case-insensitive server and nick identity';
 isnt tombstone_key('Net', 'Bkx', 'Title.epub'),
    tombstone_key('Net', 'Bkx', 'title.epub'),
    'stale-offer tuple keeps basename case-sensitive';
my $nick_tuple = { server_tag => 'Net', sender => 'Book[bot]', filename => 'Shared.epub' };
ok tombstone_matches($server, 'net', 'Book{bot}', 'Shared.epub', $nick_tuple),
    'RFC1459 tombstones equate square and curly brackets';
ok tombstone_matches($server, 'net', 'Book|bot', 'Shared.epub',
        { %$nick_tuple, sender => 'Book\\bot' }),
    'RFC1459 tombstones equate backslash and vertical bar';
ok tombstone_matches($server, 'net', 'Book~bot', 'Shared.epub',
        { %$nick_tuple, sender => 'Book^bot' }),
    'RFC1459 tombstones equate caret and tilde';
ok !tombstone_matches($server, 'net', 'Book{bot}', 'shared.epub', $nick_tuple),
    'casemapped nick matching does not fold the case-sensitive basename';
ok !tombstone_matches($server, 'other', 'Book[bot]', 'Shared.epub', $nick_tuple),
    'stale tuple remains scoped to its IRC server tag';

my $strict_server = MockServer->new();
$strict_server->{casemapping} = 'strict-rfc1459';
ok tombstone_matches($strict_server, 'net', 'Book{bot}', 'Shared.epub', $nick_tuple),
    'strict-RFC1459 still equates square and curly brackets';
ok tombstone_matches($strict_server, 'net', 'Book|bot', 'Shared.epub',
        { %$nick_tuple, sender => 'Book\\bot' }),
    'strict-RFC1459 still equates backslash and vertical bar';
ok !tombstone_matches($strict_server, 'net', 'Book~bot', 'Shared.epub',
        { %$nick_tuple, sender => 'Book^bot' }),
    'strict-RFC1459 does not equate caret and tilde';

my $ascii_server = MockServer->new();
$ascii_server->{casemapping} = 'ascii';
ok !tombstone_matches($ascii_server, 'net', 'Book{bot}', 'Shared.epub', $nick_tuple),
    'ASCII casemapping does not equate square and curly brackets';
ok !tombstone_matches($ascii_server, 'net', 'Book|bot', 'Shared.epub',
        { %$nick_tuple, sender => 'Book\\bot' }),
    'ASCII casemapping does not equate backslash and vertical bar';
ok !tombstone_matches($ascii_server, 'net', 'Book~bot', 'Shared.epub',
        { %$nick_tuple, sender => 'Book^bot' }),
    'ASCII casemapping does not equate caret and tilde';
ok tombstone_matches($ascii_server, 'net', 'book[bot]', 'Shared.epub', $nick_tuple),
    'ASCII casemapping remains case-insensitive for ASCII letters';

done_testing();
