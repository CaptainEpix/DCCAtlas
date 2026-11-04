use strict;
use warnings;
no warnings 'once';

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../lib";
use Irssi;

my $temp = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $temp;
do "$FindBin::Bin/../engine/dccatlas.pl"
    or die "could not load dccatlas.pl: $@ $!";
Irssi::settings_set_str('fscrawl_library_dir', "$FindBin::Bin/../lib");
Irssi::settings_set_str('fscrawl_state_dir', "$temp/phase6");

my $server_a = MockServer->new();
$server_a->{tag} = 'NetworkA';
$server_a->{chatnet} = 'NetworkA';
$server_a->{nick} = 'LocalNick';
my $server_b = MockServer->new();
$server_b->{tag} = 'NetworkB';
$server_b->{chatnet} = 'NetworkB';
$server_b->{nick} = 'LocalNick';

my $same_basename = 'Shared.epub';
my $same_sender = 'SameBot';
my %job_for_collection;
my @dispatches;
sub make_job {
    my ($server, $suffix) = @_;
    my $collection = 'searchbot-1-' . ($suffix x 32);
    my $job_id = Irssi::Script::dccatlas::new_job(
        provider => 'searchbot',
        server => $server,
        selection => {
            collection_id => $collection,
            physical_source_row => 1,
            result_ordinal => 1,
            exact_payload => '!SameBot Shared.epub ::INFO:: 1B',
            payload_sha256 => 'b' x 64,
            basename => $same_basename,
            offered_basename => $same_basename,
            expected_peer => $same_sender,
            sender => $same_sender,
            originating_channel => '#files',
            legacy_aliases => [],
        },
        context => { channel => '#files', server_tag => $server->{tag} },
        limits => { offer_timeout_ms => 120000, transfer_timeout_ms => 300000,
            content_bytes => 1024 },
    );
    $job_for_collection{$collection} = $job_id;
    return $job_id;
}

my $job_a = make_job($server_a, 'a');
my $job_b = make_job($server_b, 'b');
ok $job_a && $job_b && $job_a ne $job_b,
    'same sender and offered filename create distinct durable jobs on two networks';
ok Irssi::Script::dccatlas::server_context($server_a)->{process_incarnation},
    'live selections carry a script-load incarnation';

my $old_process_job = Irssi::Script::dccatlas::new_job(
    provider => 'searchbot',
    server => $server_a,
    context => { process_incarnation => 'previous-script-load' },
    selection => {
        collection_id => 'searchbot-1-' . ('c' x 32),
        result_ordinal => 1,
        exact_payload => '!SameBot Prior.epub ::INFO:: 1B',
        payload_sha256 => 'd' x 64,
        basename => 'Prior.epub', offered_basename => 'Prior.epub',
        expected_peer => $same_sender, sender => $same_sender,
        originating_channel => '#files', legacy_aliases => [],
    },
);
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "queue-run $old_process_job", $server_a, undef);
like join("\n", @Irssi::PRINTS), qr/unavailable in this process/,
    'held job from a prior script load cannot bind to a matching native pointer';
is scalar(@dispatches), 0, 'prior-incarnation refusal sends no request';

{
    no warnings qw(redefine once);
    local *FServe::Transfer::Scheduler::_interval_for = sub { return 0 };
    local *Irssi::Script::dccatlas::cmd_searchbot_get = sub {
        my ($args, $server) = @_;
        my ($collection) = $args =~ /\A(searchbot-[1-9][0-9]*-[a-f0-9]{32}):1 --sender SameBot\z/;
        my $job_id = $job_for_collection{$collection};
        die 'fixture received an unexpected immutable selection' unless $job_id;
        push @dispatches, { network => $server->{tag}, sender => $same_sender,
            basename => $same_basename, collection => $collection };
        push @{$server->{raw_lines}}, "PRIVMSG #files :$collection";
        Irssi::Script::dccatlas::job_transition($job_id, 'ready');
        Irssi::Script::dccatlas::job_transition($job_id, 'preparing');
        Irssi::Script::dccatlas::job_transition($job_id, 'dispatch_intent');
        Irssi::Script::dccatlas::job_transition($job_id, 'awaiting_offer');
    };

    Irssi::run_command('fscrawl', "queue-run $job_a $job_b", $server_a, undef);
    is scalar(@dispatches), 1, 'finite run dispatches only its first job initially';
    is $dispatches[0]{network}, 'NetworkA', 'first job uses its captured NetworkA server';
    is scalar(@{$server_a->{raw_lines}}), 1, 'first request is directed only to NetworkA';
    is scalar(@{$server_b->{raw_lines}}), 0, 'NetworkB receives nothing before its turn';

    Irssi::Script::dccatlas::job_transition($job_a, 'refused_without_queue',
        outcome => 'isolated_fixture_acknowledged');
    my @advance_handles = Irssi::timer_handles();
    my $advance = $advance_handles[-1];
    ok defined($advance), 'settled first job schedules the next finite item';
    ok Irssi::fire_timer($advance), 'next item advances through the event loop';
    is scalar(@dispatches), 2, 'second job dispatches after the first settles';
    is $dispatches[1]{network}, 'NetworkB', 'second job uses its captured NetworkB server';
    is scalar(@{$server_b->{raw_lines}}), 1, 'second request is directed only to NetworkB';

    my $job_for_reuse = make_job($server_a, 'e');
    my $old_connection_identity = Irssi::Script::dccatlas::server_connection_identity($server_a);
    my $old_connection_epoch = Irssi::Script::dccatlas::server_connection_epoch($server_a);
    $server_a->{connected} = 0;
    Irssi::emit('server disconnected', $server_a);
    @Irssi::PRINTS = ();
    Irssi::Script::dccatlas::cmd_job_show($job_b);
    like join("\n", @Irssi::PRINTS), qr/state=awaiting_offer/,
        'disconnecting NetworkA does not mutate NetworkB job state';
    Irssi::Script::dccatlas::job_transition($job_b, 'refused_without_queue',
        outcome => 'isolated_fixture_acknowledged');
    is scalar(Irssi::timer_handles()), 0, 'finite cross-network run leaves no advance timer';

    @Irssi::PRINTS = ();
    Irssi::Script::dccatlas::cmd_job_show($job_for_reuse);
    like join("\n", @Irssi::PRINTS), qr/state=stale/,
        'disconnect retires an unstarted selection from the ended connection epoch';

    my $reconnected_a = MockServer->new();
    $reconnected_a->{_irssi} = $server_a->{_irssi};
    $reconnected_a->{tag} = 'NetworkA';
    $reconnected_a->{chatnet} = 'NetworkA';
    $reconnected_a->{nick} = 'LocalNick';
    is Irssi::Script::dccatlas::server_connection_identity($reconnected_a),
        $old_connection_identity, 'fixture reuses the exact native server pointer on reconnect';
    isnt Irssi::Script::dccatlas::server_connection_epoch($reconnected_a), $old_connection_epoch,
        'reconnected native pointer receives a new connection epoch';
    @Irssi::PRINTS = ();
    Irssi::Script::dccatlas::cmd_queue_run($job_for_reuse, $reconnected_a);
    like join("\n", @Irssi::PRINTS), qr/captured connection is unavailable in this process/,
        'ended-epoch job cannot resolve to a replacement connection with a reused pointer';
    is scalar(@dispatches), 2, 'pointer reuse refusal emits no queued request';
}

is_deeply [map { $_->{network} } @dispatches], ['NetworkA', 'NetworkB'],
    'same-nick, same-name jobs remain isolated and run sequentially by network';
is scalar(@{$server_a->{raw_lines}}), 1, 'NetworkA receives exactly one request';
is scalar(@{$server_b->{raw_lines}}), 1, 'NetworkB receives exactly one request';

done_testing();
