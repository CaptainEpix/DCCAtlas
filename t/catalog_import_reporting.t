use strict;
use warnings;

use FindBin qw($Bin);
use JSON::PP qw(encode_json);
use Test::More;
use lib "$Bin/lib";
use lib "$Bin/../lib";

use Irssi;
use FServe::Catalog::WorkerClient ();

my $script = "$Bin/../engine/dccatlas.pl";
do $script or die "could not load $script: $@ $!";
Irssi::settings_set_str('fscrawl_library_dir', "$Bin/../lib");
@Irssi::PRINTS = ();

my $result_event = {
    event => 'result', status => 'published', route_key => 'a' x 64,
    snapshot_id => 'b' x 64, sha256 => 'c' x 64,
    generation => 7, records => 2_303_068,
};
my %pending;
{
    no warnings 'redefine';
    local *FServe::Catalog::WorkerClient::run_async = sub {
        %pending = @_;
        return 7001;
    };
    my $job = Irssi::Script::dccatlas::start_catalog_worker(
        'import', [], on_done => sub {
            Irssi::Script::dccatlas::report_manifest_import_completion(@_);
        });
    is $job, 7001, 'import job is started through the application worker wrapper';
    $pending{on_event}->(encode_json($result_event));
    $pending{on_done}->(255 << 8, '', 'catalog worker was cancelled', 1);
}

my $published_message = join "\n", @Irssi::PRINTS;
like $published_message, qr/Manifest snapshot published: 2303068 files, generation 7/,
    'application reports the generation confirmed by the result event';
like $published_message, qr/interruption after this publication result.*generation 7/,
    'application explains that cancellation arrived after publication';
unlike $published_message, qr/left unchanged|outcome is unconfirmed/,
    'application does not describe a committed import as unchanged or uncertain';

@Irssi::PRINTS = ();
{
    no warnings 'redefine';
    local *FServe::Catalog::WorkerClient::run_async = sub {
        %pending = @_;
        return 7002;
    };
    my $job = Irssi::Script::dccatlas::start_catalog_worker(
        'import', [], on_done => sub {
            Irssi::Script::dccatlas::report_manifest_import_completion(@_);
        });
    is $job, 7002, 'second import job is started through the application worker wrapper';
    $pending{on_done}->(255 << 8, '', 'catalog worker was cancelled', 1);
}

my $unconfirmed_message = join "\n", @Irssi::PRINTS;
like $unconfirmed_message, qr/active snapshot outcome is unconfirmed/,
    'application marks cancellation without a result as unconfirmed';
unlike $unconfirmed_message, qr/previous active snapshot was left unchanged/,
    'application makes no unsupported unchanged-snapshot promise';

done_testing();
