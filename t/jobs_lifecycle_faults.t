use strict;
use warnings;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Test::More;

use lib "$Bin/../lib";
use FServe::Transfer::Coordinator qw(open_coordinator);

my $tmp = tempdir(CLEANUP => 1);

sub make_held_job {
    my ($path, $profile) = @_;
    my $coordinator = open_coordinator(path => $path);
    my $job = $coordinator->create_job(
        provider => 'searchbot', network_profile => $profile,
        selection => {
            collection_id => "collection-$profile", source_row => 1,
            exact_payload => "!$profile One.epub", expected_peer => $profile,
            basename => 'One.epub',
        },
        context => { channel => '#phase6-faults' }, limits => {},
    );
    return ($coordinator, $job->{id});
}

sub make_receiving_job {
    my ($path, $profile) = @_;
    my $coordinator = open_coordinator(path => $path);
    my $job = $coordinator->create_job(
        provider => 'find', network_profile => $profile,
        selection => {
            remote_path => '/Phase6/One.epub', name => 'One.epub',
            expected_peer => $profile,
        },
        context => { channel => '#phase6-faults', casemapping => 'ascii' },
        limits => {},
    );
    my $id = $job->{id};
    $coordinator->begin_dispatch($id, casemapping => 'ascii');
    $coordinator->record_dispatch_result($id, 'sent');
    $coordinator->accept_offer($id,
        offered_basename => 'One.epub', accepted_lifecycle => "life-$profile");
    return ($coordinator, $id);
}

my @dispatch_boundaries = (
    { name => 'tuple reservation', event => 'tuple_reserved',
        expected_state => 'held', expected_tuples => 0 },
    { name => 'ready transition', state => 'ready',
        expected_state => 'held', expected_tuples => 1 },
    { name => 'preparing transition', state => 'preparing',
        expected_state => 'needs_attention', expected_tuples => 1 },
    { name => 'dispatch-intent transition', state => 'dispatch_intent',
        expected_state => 'needs_attention', expected_tuples => 1 },
);

my $real_append = \&FServe::Transfer::Journal::append;
for my $boundary (@dispatch_boundaries) {
    my $name = "dispatch-$boundary->{name}";
    my $path = "$tmp/$name.jsonl";
    my ($coordinator, $id) = make_held_job($path, "Peer-$name");
    my $failures = 0;
    my $dispatch_returned = 0;
    my $ok;
    my $error;
    {
        no warnings 'redefine';
        local *FServe::Transfer::Journal::append = sub {
            my ($journal, $event, $data) = @_;
            my $matches = defined($boundary->{event})
                ? $event eq $boundary->{event}
                : $event eq 'job_transition' &&
                    ref($data->{job}) eq 'HASH' &&
                    $data->{job}{state} eq $boundary->{state};
            if ($matches) {
                $failures++;
                die "injected $name append failure\n";
            }
            return $real_append->(@_);
        };
        $ok = eval {
            $coordinator->begin_dispatch($id, casemapping => 'ascii');
            # The caller may invoke transport only after begin_dispatch returns.
            $dispatch_returned++;
            1;
        };
        $error = $@;
    }
    ok(!$ok, "$name prevents dispatch setup from succeeding");
    like($error, qr/injected \Q$name\E append failure/,
        "$name reports its persistence failure");
    is($failures, 1, "$name injects exactly one failure");
    is($dispatch_returned, 0, "$name never reaches the transport-call boundary");
    $coordinator->close();

    my $recovered = open_coordinator(path => $path);
    is($recovered->job($id)->{state}, $boundary->{expected_state},
        "$name restart remains non-dispatched and conservative");
    is($recovered->tuple_count, $boundary->{expected_tuples},
        "$name restart retains only successfully persisted tuple ownership");
    my $retried = eval { $recovered->begin_dispatch($id, casemapping => 'ascii'); 1 };
    if ($boundary->{expected_state} eq 'held') {
        ok($retried, "$name may be explicitly retried because no transport intent was recorded");
    } else {
        ok(!$retried, "${name}'s ambiguous recovery cannot be automatically retried");
    }
    $recovered->close();
}

{
    my $path = "$tmp/sent-result-persistence-failure.jsonl";
    my ($coordinator, $id) = make_held_job($path, 'SentResultBot');
    my $intent = $coordinator->begin_dispatch($id, casemapping => 'ascii');
    is($intent->{state}, 'dispatch_intent',
        'outbound-failure case begins with durable dispatch intent');
    my @outbound_lines;
    my $mock_transport = sub {
        push @outbound_lines, $_[0];
        return 'sent';
    };
    my $dispatch_result = $mock_transport->('!SentResultBot One.epub');
    is($dispatch_result, 'sent', 'mock transport records one sent outcome');
    my $failures = 0;
    my $ok;
    my $error;
    {
        no warnings 'redefine';
        local *FServe::Transfer::Journal::append = sub {
            my ($journal, $event, $data) = @_;
            if ($event eq 'job_transition' &&
                    $data->{job}{state} eq 'awaiting_offer') {
                $failures++;
                die "injected sent-result append failure\n";
            }
            return $real_append->(@_);
        };
        $ok = eval { $coordinator->record_dispatch_result($id, 'sent'); 1 };
        $error = $@;
    }
    ok(!$ok, 'sent-result persistence failure is surfaced after the one send');
    like($error, qr/injected sent-result append failure/,
        'sent-result append error is preserved');
    is($failures, 1, 'sent-result append failure is injected once');
    is_deeply(\@outbound_lines, ['!SentResultBot One.epub'],
        'the mocked transport was invoked once with the selected request');
    is($coordinator->job($id)->{state}, 'dispatch_intent',
        'failed sent-result write does not claim an acknowledged offer wait');
    $coordinator->close();

    my $recovered = open_coordinator(path => $path);
    is($recovered->job($id)->{state}, 'needs_attention',
        'restart marks the possibly sent request ambiguous');
    is($recovered->tuple_count, 1,
        'restart retains the DCC tuple after the possibly sent request');
    my $retried = eval { $recovered->begin_dispatch($id, casemapping => 'ascii'); 1 };
    ok(!$retried, 'possibly sent request cannot be repeated after restart');
    $recovered->close();
}

{
    my $path = "$tmp/incoming-offer-binding-failure.jsonl";
    my ($coordinator, $id) = make_held_job($path, 'OfferBindBot');
    $coordinator->begin_dispatch($id, casemapping => 'ascii');
    $coordinator->record_dispatch_result($id, 'sent');
    my $dcc_acceptances = 0;
    my $failures = 0;
    my $ok;
    my $error;
    {
        no warnings 'redefine';
        local *FServe::Transfer::Journal::append = sub {
            my ($journal, $event, $data) = @_;
            if ($event eq 'job_transition' &&
                    $data->{job}{state} eq 'receiving') {
                $failures++;
                die "injected incoming-offer binding failure\n";
            }
            return $real_append->(@_);
        };
        $ok = eval {
            $coordinator->accept_offer($id,
                offered_basename => 'One.epub',
                accepted_lifecycle => 'offline-dcc-lifecycle');
            # The native adapter may accept the DCC only after durable binding.
            $dcc_acceptances++;
            1;
        };
        $error = $@;
    }
    ok(!$ok, 'incoming offer is not accepted when durable binding fails');
    like($error, qr/injected incoming-offer binding failure/,
        'incoming-offer binding error is preserved');
    is($failures, 1, 'incoming-offer binding failure is injected once');
    is($dcc_acceptances, 0, 'failed binding never crosses the DCC acceptance boundary');
    is($coordinator->job($id)->{state}, 'awaiting_offer',
        'failed offer binding leaves the live job awaiting an offer');
    $coordinator->close();

    my $recovered = open_coordinator(path => $path);
    is($recovered->job($id)->{state}, 'needs_attention',
        'restart refuses the request after an unjournaled offer binding');
    is($recovered->tuple_count, 1,
        'restart retains tuple ownership after offer-binding failure');
    my $retried = eval { $recovered->begin_dispatch($id, casemapping => 'ascii'); 1 };
    ok(!$retried, 'failed offer binding cannot cause a duplicate request');
    $recovered->close();
}

my $bytes = "phase6 finalization fault fixture\0bytes";
my $digest = sha256_hex($bytes);

{
    my $path = "$tmp/finalization-reservation-failure.jsonl";
    my ($coordinator, $id) = make_receiving_job($path, 'ReserveFailBot');
    my $failures = 0;
    my $ok;
    my $error;
    {
        no warnings 'redefine';
        local *FServe::Transfer::Journal::append = sub {
            my ($journal, $event) = @_;
            if ($event eq 'finalization_reservation') {
                $failures++;
                die "injected finalization reservation append failure\n";
            }
            return $real_append->(@_);
        };
        $ok = eval {
            $coordinator->reserve_finalization($id,
                staging_path => "$tmp/reserve-stage.bin",
                destination_path => "$tmp/reserve-destination.bin",
                expected_size => length($bytes), expected_sha256 => $digest);
            1;
        };
        $error = $@;
    }
    ok(!$ok, 'failed finalization reservation does not proceed');
    like($error, qr/injected finalization reservation append failure/,
        'reservation failure is surfaced');
    is($failures, 1, 'reservation failure is injected once');
    is($coordinator->job($id)->{state}, 'receiving',
        'reservation failure leaves the live job in receiving');
    ok(!exists($coordinator->{finalizations}{$id}),
        'reservation failure does not expose undurable finalization state');
    $coordinator->close();

    my $recovered = open_coordinator(path => $path);
    is($recovered->job($id)->{state}, 'interrupted',
        'restart treats the receive as interrupted without a durable reservation');
    ok(!exists($recovered->{finalizations}{$id}),
        'restart has no phantom finalization reservation');
    ok(!-e "$tmp/reserve-destination.bin",
        'failed reservation cannot create a destination');
    $recovered->close();
}

{
    my $path = "$tmp/finalizing-transition-failure.jsonl";
    my ($coordinator, $id) = make_receiving_job($path, 'FinalizingFailBot');
    my $failures = 0;
    my $ok;
    {
        no warnings 'redefine';
        local *FServe::Transfer::Journal::append = sub {
            my ($journal, $event, $data) = @_;
            if ($event eq 'job_transition' &&
                    $data->{job}{state} eq 'finalizing') {
                $failures++;
                die "injected finalizing transition append failure\n";
            }
            return $real_append->(@_);
        };
        $ok = eval {
            $coordinator->reserve_finalization($id,
                staging_path => "$tmp/transition-stage.bin",
                destination_path => "$tmp/transition-destination.bin",
                expected_size => length($bytes), expected_sha256 => $digest);
            1;
        };
    }
    ok(!$ok, 'failed finalizing transition stops before publication');
    is($failures, 1, 'finalizing transition failure is injected once');
    is($coordinator->job($id)->{state}, 'receiving',
        'failed finalizing transition does not mutate live lifecycle state');
    is($coordinator->{finalizations}{$id}{status}, 'reserved',
        'durable reservation remains available as evidence');
    $coordinator->close();

    my $recovered = open_coordinator(path => $path);
    is($recovered->job($id)->{state}, 'interrupted',
        'restart refuses to resume a receive interrupted at reservation');
    is($recovered->job($id)->{finalization}{status}, 'reserved',
        'restart retains the durable reservation on the interrupted job');
    is($recovered->{finalizations}{$id}{status}, 'reserved',
        'restart retains finalization lookup evidence');
    $recovered->close();
}

{
    my $path = "$tmp/final-complete-transition-failure.jsonl";
    my ($coordinator, $id) = make_receiving_job($path, 'CompleteTransitionBot');
    my $destination = "$tmp/complete-transition-destination.bin";
    $coordinator->reserve_finalization($id,
        staging_path => "$tmp/complete-transition-stage.bin",
        destination_path => $destination,
        expected_size => length($bytes), expected_sha256 => $digest);
    open my $out, '>:raw', $destination or die "create finalization fixture: $!";
    print {$out} $bytes or die "write finalization fixture: $!";
    close $out or die "close finalization fixture: $!";

    my $failures = 0;
    my $ok;
    my $error;
    {
        no warnings 'redefine';
        local *FServe::Transfer::Journal::append = sub {
            my ($journal, $event, $data) = @_;
            if ($event eq 'job_transition' &&
                    $data->{job}{state} eq 'complete') {
                $failures++;
                die "injected complete transition append failure\n";
            }
            return $real_append->(@_);
        };
        $ok = eval {
            $coordinator->complete_finalization($id,
                success => 1, destination_path => $destination,
                observed_size => length($bytes), observed_sha256 => $digest);
            1;
        };
        $error = $@;
    }
    ok(!$ok, 'failed complete transition leaves finalization pending');
    like($error, qr/injected complete transition append failure/,
        'completion transition failure is reported');
    is($failures, 1, 'completion transition failure is injected once');
    is($coordinator->job($id)->{state}, 'finalizing',
        'live state remains finalizing until the transition is durable');
    is($coordinator->{finalizations}{$id}{status}, 'published',
        'durable result is retained for conservative restart reconciliation');
    $coordinator->close();

    my $recovered = open_coordinator(path => $path);
    is($recovered->job($id)->{state}, 'complete',
        'restart re-verifies the existing destination before completing');
    is($recovered->job($id)->{finalization}{status}, 'reconciled_complete',
        'restart records the verified reconciliation outcome');
    open my $read, '<:raw', $destination or die "read reconciled destination: $!";
    my $observed = do { local $/; <$read> };
    close $read or die "close reconciled destination: $!";
    is($observed, $bytes, 'reconciliation leaves exact destination bytes intact');
    $recovered->close();

    unlink $destination or die "remove completed fixture destination: $!";
    my $replayed = open_coordinator(path => $path);
    is($replayed->job($id)->{state}, 'complete',
        'durable completion remains complete if the destination is later removed');
    $replayed->close();
}

done_testing();
