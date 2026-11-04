use strict;
use warnings;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

use lib "$Bin/../lib";
use FServe::Discovery::SearchBot;
use FServe::Catalog ();
use FServe::Model qw(new_remote_file);

my $provider = FServe::Discovery::SearchBot->new(
    network_id => 'ExampleNet', server_tag => 'example-tag',
    discovery_channel => '#books', query => 'Example title',
    collection_id => 'provider-test-collection',
);
$provider->feed_line('!BookBot Example.epub ::INFO:: 10 KB');
my $complete = $provider->finish();
is $complete->{type}, 'complete', 'bounded SearchBot provider completes one row';

my $candidate = $complete->{results}[0];
is $candidate->{request_line}, '!BookBot Example.epub ::INFO:: 10 KB',
    'candidate retains the exact source request line, including metadata';
is $candidate->{direct_requestable}, 1,
    'a printable, bounded, safe result line is eligible for direct request';
is $candidate->{result_ordinal}, 1,
    'selection ordinal is separate from the archive source-line number';
like $candidate->{request_line_digest}, qr/\A[0-9a-f]{64}\z/,
    'candidate stores a digest of the original request bytes';
my $record = new_remote_file(
    type => 'file', network_id => 'ExampleNet', server_tag => 'example-tag',
    server_nick => 'BookBot', trigger_raw => '!BookBot',
    trigger_mode => 'channel_text', remote_path => '/Books/Example.epub',
    discovery_channel => '#books', source => 'find',
);
$record->{discovery_channels} = ['#books'];

my $normalized = $provider->normalize_candidate_from_catalog(
    $candidate->{candidate_id}, [$record]
);
is $normalized->{remote_path}, '/Books/Example.epub',
    'unique exact catalog evidence supplies the missing parent path';
is $normalized->{searchbot_collection_id}, 'provider-test-collection',
    'normalized record retains collection provenance';
is $normalized->{trigger_mode}, 'channel_text',
    'trigger mode is inherited from the unique catalog record rather than guessed';

my $other_parent = new_remote_file(
    type => 'file', network_id => 'ExampleNet', server_tag => 'example-tag',
    server_nick => 'BookBot', trigger_raw => '!BookBot',
    trigger_mode => 'channel_text', remote_path => '/Archive/Example.epub',
    discovery_channel => '#books', source => 'find',
);
$other_parent->{discovery_channels} = ['#books'];
my $ok = eval {
    $provider->normalize_candidate_from_catalog(
        $candidate->{candidate_id}, [$record, $other_parent]
    );
    1;
};
ok !$ok, 'multiple matching catalog paths refuse normalization';
like $@, qr/multiple catalog paths/, 'ambiguous path refusal is explicit';

my $wrong_channel = {
    %$record,
    discovery_channel => '#other',
    discovery_channels => ['#other'],
};
$ok = eval {
    $provider->normalize_candidate_from_catalog(
        $candidate->{candidate_id}, [$wrong_channel]
    );
    1;
};
ok !$ok, 'a catalog record from a different discovery channel does not resolve the row';
like $@, qr/no exact route\/path match/, 'missing exact route/channel evidence is explicit';

my $case_path = new_remote_file(
    type => 'file', network_id => 'ExampleNet', server_tag => 'example-tag',
    server_nick => 'BookBot', trigger_raw => '!BookBot',
    trigger_mode => 'channel_text', remote_path => '/books/Example.epub',
    discovery_channel => '#books', source => 'find',
);
$case_path->{discovery_channels} = ['#books'];
$ok = eval {
    $provider->normalize_candidate_from_catalog(
        $candidate->{candidate_id}, [$record, $case_path]
    );
    1;
};
ok !$ok, 'case-distinct parent paths are not treated as one unique match';
like $@, qr/multiple catalog paths/, 'case-distinct path ambiguity is explicit';

my $case_store = FServe::Catalog::new_store();
FServe::Catalog::add_record($case_store, $record);
FServe::Catalog::add_record($case_store, $case_path);
is FServe::Catalog::record_count($case_store), 2,
    'catalog identity preserves case-distinct remote paths';

my $ctcp_route = {
    %$record,
    trigger_mode => 'ctcp',
};
my $mode_temp = tempdir(CLEANUP => 1);
for my $order (0, 1) {
    my @routes = $order
        ? ($ctcp_route, $record)
        : ($record, $ctcp_route);
    $ok = eval {
        $provider->normalize_candidate_from_catalog(
            $candidate->{candidate_id}, \@routes
        );
        1;
    };
    ok !$ok, "conflicting channel-text/CTCP modes refuse directly in order $order";
    like $@, qr/multiple catalog paths/,
        "direct route-mode ambiguity is explicit in order $order";

    my $mode_store = FServe::Catalog::new_store();
    FServe::Catalog::add_record($mode_store, $_) for @routes;
    is FServe::Catalog::record_count($mode_store), 2,
        "catalog identity retains both route modes in order $order";

    my $mode_jsonl = "$mode_temp/routes-$order.jsonl";
    FServe::Catalog::append_observations($mode_jsonl, \@routes);
    my ($loaded_modes, $invalid_modes) = FServe::Catalog::load_jsonl($mode_jsonl);
    is $invalid_modes, 0, "both route-mode observations reload cleanly in order $order";
    $ok = eval {
        $provider->normalize_candidate_from_catalog(
            $candidate->{candidate_id}, $loaded_modes
        );
        1;
    };
    ok !$ok, "JSONL replay preserves mode ambiguity in order $order";
}

done_testing();
