use strict;
use warnings;

use FindBin qw($Bin);
use File::Copy qw(copy);
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Test::More;

use lib "$Bin/../lib";
use FServe::ConnectionIdentity qw(irc_casefold tuple_key);
use FServe::Transfer::Job qw(new_job transition_job resume_binding_fingerprint job_identity_key tuple_keys_for_job is_terminal unfinished_count);
use FServe::Transfer::Journal;
use FServe::Transfer::Coordinator qw(open_coordinator);
use FServe::Transfer::Scheduler;
use FServe::Protocol::SysResetStatus qw(parse_status);
use FServe::Transfer::Resume qw(capture_partial begin_partial_seal step_partial_seal
    cancel_partial_seal begin_partial_validation step_partial_validation
    cancel_partial_validation discard_partial_snapshot validate_partial
    begin_resumed_file_verification step_resumed_file_verification
    cancel_resumed_file_verification consume_resumed_file_verification
    resume_decision capability_profile);

is irc_casefold('Bot[One]\\^', 'rfc1459'), 'bot{one}|~', 'RFC1459 casemapping folds all special pairs';
is irc_casefold('Bot[One]\\^', 'strict-rfc1459'), 'bot{one}|^', 'strict RFC1459 leaves caret and tilde distinct';
is irc_casefold('Bot[One]\\^', 'ascii'), 'bot[one]\\^', 'ASCII casemapping folds ASCII letters only';

my $selection = { remote_path => '/Case/Name.txt', expected_peer => 'Book[Bot]', name => 'Name.txt' };
my $job = new_job(provider => 'find', network_profile => 'HomeNet', selection => $selection,
    context => { casemapping => 'rfc1459' }, limits => { content_bytes => 4096 });
ok !exists($job->{trusted_content_digest}),
    'ordinary job without a caller assertion keeps trusted digest absent';
$selection->{remote_path} = '/mutated';
is $job->{selection}{remote_path}, '/Case/Name.txt', 'job deep-copies its selected identity';
like $job->{id}, qr/^job-[a-f0-9]{32}$/, 'job receives an opaque stable identifier';
is job_identity_key($job), job_identity_key({ %$job, id => 'job-' . ('a' x 32) }),
    'provider identity does not depend on display row or generated job id';
is_deeply [tuple_keys_for_job($job, 'rfc1459')],
    [tuple_key(network_profile => 'HomeNet', peer => 'Book[Bot]', basename => 'Name.txt', casemapping => 'rfc1459')],
    'DCC reservation tuple uses IRC casemapping and preserves basename bytes';
my $ready = transition_job($job, 'ready', at => 1);
my $preparing = transition_job($ready, 'preparing', at => 2);
my $intent = transition_job($preparing, 'dispatch_intent', at => 3);
my $awaiting = transition_job($intent, 'awaiting_offer', at => 4);
is $awaiting->{state}, 'awaiting_offer', 'dispatch state progresses through durable intent';
my $bad_transition = eval { transition_job($awaiting, 'ready'); 1 };
ok !$bad_transition, 'post-dispatch job cannot return to a retryable ready state';
is unfinished_count({ $job->{id} => $job }), 1, 'held jobs count toward unfinished bound';
ok !is_terminal('needs_attention') && is_terminal('cancelled'), 'terminal states preserve ambiguity separately';

my $trusted_record_input = {
    sha256 => uc('a' x 64),
    provenance => {
        kind => 'pre_dispatch_operator_attestation',
        asserted_by => 'CaptainEpix',
        asserted_at => 1791100109,
    },
};
my $trusted_record = {
    sha256 => 'a' x 64,
    provenance => {
        kind => 'pre_dispatch_operator_attestation',
        asserted_by => 'CaptainEpix',
        asserted_at => 1791100109,
    },
};
my $trusted_job = new_job(provider => 'find', network_profile => 'DigestNet',
    selection => { remote_path => '/Digest/Book.epub', name => 'Book.epub',
        expected_peer => 'DigestBot' }, context => {}, limits => {},
    trusted_content_digest => $trusted_record_input);
is $trusted_job->{trusted_content_digest}{sha256}, 'a' x 64,
    'creation normalizes a valid mixed-case SHA-256 digest to lowercase';
is_deeply $trusted_job->{trusted_content_digest}{provenance}, $trusted_record->{provenance},
    'creation retains the explicitly named caller-assertion provenance';
$trusted_record_input->{sha256} = 'b' x 64;
$trusted_record_input->{provenance}{asserted_by} = 'mutated after creation';
is_deeply $trusted_job->{trusted_content_digest}, $trusted_record,
    'creation deep-copies the digest and bounded provenance record';

my $bad_digest = eval { new_job(provider => 'find', network_profile => 'DigestNet',
    selection => {}, context => {}, limits => {}, trusted_content_digest => {
        sha256 => 'a' x 63, provenance => $trusted_record->{provenance} }); 1 };
ok !$bad_digest, 'job creation rejects a SHA-256 value with the wrong length';
my $bad_digest_chars = eval { new_job(provider => 'find', network_profile => 'DigestNet',
    selection => {}, context => {}, limits => {}, trusted_content_digest => {
        sha256 => 'g' x 64, provenance => $trusted_record->{provenance} }); 1 };
ok !$bad_digest_chars, 'job creation rejects non-hex digest characters';
my $bad_provenance = eval { new_job(provider => 'find', network_profile => 'DigestNet',
    selection => {}, context => {}, limits => {}, trusted_content_digest => {
        sha256 => 'a' x 64, provenance => { kind => 'post_receive_hash',
            asserted_by => 'test', asserted_at => 1 } }); 1 };
ok !$bad_provenance, 'job creation rejects provenance that is not an allowed pre-dispatch assertion';
my $oversized_provenance = eval { new_job(provider => 'find', network_profile => 'DigestNet',
    selection => {}, context => {}, limits => {}, trusted_content_digest => {
        sha256 => 'a' x 64, provenance => { kind => 'test_fixture',
            asserted_by => 'x' x 129, asserted_at => 1 } }); 1 };
ok !$oversized_provenance, 'job creation bounds caller-declared provenance fields';
my $unicode_attester = eval { new_job(provider => 'find', network_profile => 'DigestNet',
    selection => {}, context => {}, limits => {}, trusted_content_digest => {
        sha256 => 'a' x 64, provenance => { kind => 'test_fixture',
            asserted_by => 'Operator' . chr(0x100), asserted_at => '1' } }); 1 };
my $unicode_attester_error = $@;
ok !$unicode_attester,
    'job creation rejects non-ASCII attester text before journal serialization';
like $unicode_attester_error, qr/printable ASCII characters/,
    'attester character-set refusal explains the persistence-compatible limit';
my $unicode_timestamp = eval { new_job(provider => 'find', network_profile => 'DigestNet',
    selection => {}, context => {}, limits => {}, trusted_content_digest => {
        sha256 => 'a' x 64, provenance => { kind => 'test_fixture',
            asserted_by => 'Operator', asserted_at => chr(0x660) } }); 1 };
my $unicode_timestamp_error = $@;
ok !$unicode_timestamp, 'job creation rejects non-ASCII timestamp digits';
like $unicode_timestamp_error, qr/asserted_at is invalid/,
    'timestamp character-set refusal identifies the invalid field';

my $trusted_ready = transition_job($trusted_job, 'ready', at => 1);
is_deeply $trusted_ready->{trusted_content_digest}, $trusted_record,
    'ordinary job transition preserves the exact trusted-digest record';
my $retrofit_digest = eval {
    transition_job($job, 'ready', at => 1,
        data => { trusted_content_digest => $trusted_record });
    1;
};
ok !$retrofit_digest,
    'transition refuses to add a trusted digest after ordinary job creation';
like $@, qr/creation-only and immutable/,
    'retroactive digest refusal explains the creation-time requirement';
my $trusted_preparing = transition_job($trusted_ready, 'preparing', at => 2);
my $trusted_intent = transition_job($trusted_preparing, 'dispatch_intent', at => 3);
my $trusted_offer = transition_job($trusted_intent, 'awaiting_offer', at => 4);
my $trusted_receiving = transition_job($trusted_offer, 'receiving', at => 5);
my $trusted_interrupted = transition_job($trusted_receiving, 'interrupted', at => 6);
my $replace_after_interruption = eval {
    transition_job($trusted_interrupted, 'needs_attention', at => 7,
        data => { trusted_content_digest => { %$trusted_record,
            sha256 => 'b' x 64 } });
    1;
};
ok !$replace_after_interruption,
    'interrupted job transition refuses to replace its creation-time digest';
like $@, qr/creation-only and immutable/,
    'digest mutation refusal explains its creation-only contract';

my $tmp = tempdir(CLEANUP => 1);
my $trusted_digest_journal_path = "$tmp/trusted-digest-coordinator.jsonl";
my $trusted_digest_coordinator = open_coordinator(path => $trusted_digest_journal_path);
my $durable_digest_job = $trusted_digest_coordinator->create_job(
    provider => 'find', network_profile => 'DigestJournalNet',
    selection => { remote_path => '/Digest/Book.epub', name => 'Book.epub',
        expected_peer => 'DigestBot' },
    context => { casemapping => 'rfc1459' }, limits => {},
    trusted_content_digest => $trusted_record);
is_deeply $durable_digest_job->{trusted_content_digest}, $trusted_record,
    'coordinator persists the caller assertion in the creation-time job record';
my $generic_lifecycle_create = eval {
    $trusted_digest_coordinator->record_event('job_created', { job => $durable_digest_job });
    1;
};
my $generic_lifecycle_create_error = $@;
ok !$generic_lifecycle_create,
    'generic audit-event API refuses reserved job-created lifecycle records';
like $generic_lifecycle_create_error, qr/validated coordinator methods/,
    'generic lifecycle refusal directs callers through validated coordinator methods';
my $generic_lifecycle_transition = eval {
    $trusted_digest_coordinator->record_event('job_transition', { job => $durable_digest_job });
    1;
};
ok !$generic_lifecycle_transition,
    'generic audit-event API refuses reserved job-transition lifecycle records';
my $durable_digest_ready = $trusted_digest_coordinator->transition(
    $durable_digest_job->{id}, 'ready');
my $durable_digest_preparing = $trusted_digest_coordinator->transition(
    $durable_digest_job->{id}, 'preparing');
is_deeply $durable_digest_preparing->{trusted_content_digest}, $trusted_record,
    'pre-dispatch transitions preserve the pinned digest and provenance';
$trusted_digest_coordinator->close();
my $trusted_digest_restart = open_coordinator(path => $trusted_digest_journal_path);
my $restarted_digest_job = $trusted_digest_restart->job($durable_digest_job->{id});
is_deeply $restarted_digest_job->{trusted_content_digest}, $trusted_record,
    'ordinary journal restart preserves the exact digest and provenance';
ok $trusted_digest_restart->compact_journal(),
    'trusted-digest job can be compacted without losing its creation record';
$trusted_digest_restart->close();
my $trusted_digest_replay = open_coordinator(path => $trusted_digest_journal_path);
my $replayed_digest_job = $trusted_digest_replay->job($durable_digest_job->{id});
is_deeply $replayed_digest_job->{trusted_content_digest}, $trusted_record,
    'compacted journal replay preserves the exact digest and provenance';
$trusted_digest_replay->close();

my $boundary_provenance = {
    kind => 'test_fixture', asserted_by => 'A' x 128, asserted_at => '9' x 12,
};
my $boundary_digest = { sha256 => 'c' x 64, provenance => $boundary_provenance };
my $digest_boundary_path = "$tmp/boundary-provenance.jsonl";
my $boundary_coordinator = open_coordinator(path => $digest_boundary_path);
my $boundary_job = $boundary_coordinator->create_job(
    provider => 'find', network_profile => 'DigestBoundaryNet',
    selection => { name => 'Boundary.epub' }, context => {}, limits => {},
    trusted_content_digest => $boundary_digest);
$boundary_coordinator->close();
my $boundary_restart = open_coordinator(path => $digest_boundary_path);
is_deeply $boundary_restart->job($boundary_job->{id})->{trusted_content_digest},
    $boundary_digest, 'maximum-length ASCII provenance survives journal reopen';
ok $boundary_restart->compact_journal(),
    'maximum-length accepted ASCII provenance can be compacted';
$boundary_restart->close();
my $boundary_compact_restart = open_coordinator(path => $digest_boundary_path);
is_deeply $boundary_compact_restart->job($boundary_job->{id})->{trusted_content_digest},
    $boundary_digest, 'maximum-length ASCII provenance survives compacted replay';
$boundary_compact_restart->close();

my $read_raw_file = sub {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read test journal $path: $!";
    local $/;
    my $contents = <$fh>;
    close $fh or die "cannot close test journal $path: $!";
    return defined($contents) ? $contents : '';
};
my $check_digest_compaction_refusal = sub {
    my ($case, $initial_digest, $mutate) = @_;
    my $path = "$tmp/compaction-digest-$case.jsonl";
    my $coordinator = open_coordinator(path => $path);
    my %create = (
        provider => 'find', network_profile => "DigestMutation-$case",
        selection => { name => "$case.epub" }, context => {}, limits => {},
    );
    $create{trusted_content_digest} = $initial_digest if defined $initial_digest;
    my $created = $coordinator->create_job(%create);
    my $ready = $coordinator->transition($created->{id}, 'ready');
    my $transition = transition_job($ready, 'preparing');
    $mutate->($transition);
    $coordinator->journal->append('job_transition', { job => $transition });
    my $source_bytes = $read_raw_file->($path);
    my $compacted = eval { $coordinator->compact_journal(); 1 };
    my $compaction_error = $@;
    ok !$compacted, "$case digest mutation is refused during compaction";
    like $compaction_error, qr/mutates immutable trusted content digest/,
        "$case compaction refusal identifies the immutable digest violation";
    is $read_raw_file->($path), $source_bytes,
        "$case digest refusal preserves the original journal bytes";
    $coordinator->close();
};
$check_digest_compaction_refusal->('replacement', $trusted_record, sub {
    $_[0]{trusted_content_digest}{sha256} = 'b' x 64;
});
$check_digest_compaction_refusal->('addition', undef, sub {
    $_[0]{trusted_content_digest} = $trusted_record;
});
$check_digest_compaction_refusal->('removal', $trusted_record, sub {
    delete $_[0]{trusted_content_digest};
});
$check_digest_compaction_refusal->('provenance', $trusted_record, sub {
    $_[0]{trusted_content_digest}{provenance}{asserted_by} = 'DifferentOperator';
});

my $tampered_digest_path = "$tmp/tampered-trusted-digest.jsonl";
my $tampered_digest_job = new_job(id => 'job-' . ('c' x 32),
    provider => 'find', network_profile => 'TamperedDigestNet',
    selection => { name => 'Tampered.epub' }, context => {}, limits => {},
    trusted_content_digest => $trusted_record);
my $tampered_digest_transition = transition_job($tampered_digest_job, 'ready', at => 2);
$tampered_digest_transition->{trusted_content_digest}{sha256} = 'b' x 64;
my $tampered_digest_store = FServe::Transfer::Journal->open_store(
    path => $tampered_digest_path);
$tampered_digest_store->append('job_created', { job => $tampered_digest_job });
$tampered_digest_store->append('job_transition', { job => $tampered_digest_transition });
$tampered_digest_store->close();
my $tampered_digest_replay = eval {
    open_coordinator(path => $tampered_digest_path);
    1;
};
ok !$tampered_digest_replay,
    'coordinator replay rejects a journal transition that changes the pinned digest';
like $@, qr/mutates immutable trusted content digest/,
    'digest replay refusal identifies the immutable-field violation';

my $forged_resume_path = "$tmp/forged-resume-pending.jsonl";
my $forged_resume_created = new_job(id => 'job-' . ('d' x 32),
    provider => 'find', network_profile => 'ForgedResumeNet',
    selection => { name => 'Forged.epub' }, context => {}, limits => {});
my $forged_resume_ready = transition_job($forged_resume_created, 'ready', at => 2);
my $forged_resume_pending = { %$forged_resume_ready,
    state => 'resume_pending', transition_sequence => 2,
    outcome => 'resume_intent_durable', updated_at => 3 };
my $forged_resume_store = FServe::Transfer::Journal->open_store(
    path => $forged_resume_path);
$forged_resume_store->append('job_created', { job => $forged_resume_created });
$forged_resume_store->append('job_transition', { job => $forged_resume_ready });
$forged_resume_store->append('job_transition', { job => $forged_resume_pending });
$forged_resume_store->close();
my $forged_resume_replay = eval {
    open_coordinator(path => $forged_resume_path);
    1;
};
ok !$forged_resume_replay,
    'journal replay rejects resume_pending without an admitted durable intent';
like $@, qr/resume_pending requires a durable resume intent/,
    'missing-intent replay refusal identifies the invalid lifecycle state';

my $journal_path = "$tmp/requests.jsonl";
my $replayed = 0;
my $store = FServe::Transfer::Journal->open_store(path => $journal_path,
    on_event => sub { $replayed++ });
ok $store->healthy, 'new journal owns an exclusive process-lifetime lock';
$store->append('job_created', { job => $job });
$store->append('job_transition', { job => $ready });
my $page = $store->page(0, 1);
is scalar(@$page), 1, 'journal history can be paginated';
is $page->[0]{event}, 'job_created', 'first journal page preserves sequence';
my $lock_contended = eval { FServe::Transfer::Journal->open_store(path => $journal_path); 1 };
ok !$lock_contended, 'a second writer is refused while the journal lock is held';
$store->close();

my $store2 = FServe::Transfer::Journal->open_store(path => $journal_path,
    on_event => sub { $replayed++ });
is $replayed, 2, 'restart replay streams validated records to a callback';
is $store2->page(1, 5)->[0]{event}, 'job_transition', 'replay retains event order';
$store2->close();

my $short_write_path = "$tmp/short-write.jsonl";
my $short_write_calls = 0;
my $short_write_store;
{
    no warnings 'redefine';
    no warnings 'once';
    local *FServe::Transfer::Journal::_write_chunk = sub {
        my ($self, $fh, $line, $length, $offset) = @_;
        $short_write_calls++;
        my $chunk = $length > 7 ? 7 : $length;
        return syswrite($fh, $line, $chunk, $offset);
    };
    $short_write_store = FServe::Transfer::Journal->open_store(path => $short_write_path);
    $short_write_store->append('short_write', { verified => 1 });
}
cmp_ok $short_write_calls, '>', 1,
    'journal append loops until a valid short-write tail is complete';
$short_write_store->close();
my $short_write_replay = FServe::Transfer::Journal->open_store(path => $short_write_path);
is $short_write_replay->page(0, 1)->[0]{event}, 'short_write',
    'a sequence of positive short writes produces one valid replayable record';
$short_write_replay->close();

my $write_fault_path = "$tmp/write-fault.jsonl";
my $fault_write_calls = 0;
my $write_fault_store;
{
    no warnings 'redefine';
    local *FServe::Transfer::Journal::_write_chunk = sub {
        my ($self, $fh, $line, $length, $offset) = @_;
        return syswrite($fh, $line, $length > 9 ? 9 : $length, $offset)
            if ++$fault_write_calls == 1;
        $! = 0;
        return 0;
    };
    $write_fault_store = FServe::Transfer::Journal->open_store(path => $write_fault_path);
    my $write_fault_ok = eval {
        $write_fault_store->append('partial_write', { unsafe => 1 });
        1;
    };
    ok !$write_fault_ok, 'zero-progress journal write fails closed after a partial append';
    like $@, qr/request journal write failed: short journal write/,
        'short-write failure is reported distinctly from a successful append';
}
ok !$write_fault_store->healthy,
    'partial append poisons the journal writer and blocks further dispatch';
my $post_fault_append = eval { $write_fault_store->append('must_not_write', {}); 1 };
ok !$post_fault_append, 'unhealthy journal refuses a later append';
like $@, qr/journal is not healthy/,
    'post-fault refusal reports that durable state is unavailable';
$write_fault_store->close();

my $sync_fault_path = "$tmp/sync-fault.jsonl";
my $sync_fault_store;
{
    no warnings 'redefine';
    local *FServe::Transfer::Journal::_sync_handle = sub { return 0 };
    $sync_fault_store = FServe::Transfer::Journal->open_store(path => $sync_fault_path);
    my $sync_fault_ok = eval {
        $sync_fault_store->append('unsynced', { unsafe => 1 });
        1;
    };
    ok !$sync_fault_ok, 'durable-sync failure prevents append from being acknowledged';
    like $@, qr/request journal durable sync failed: durable sync failed/,
        'sync failure is surfaced as a durability error';
}
ok !$sync_fault_store->healthy,
    'sync failure poisons journal health and blocks subsequent dispatch';
$sync_fault_store->close();

my $journal_cap_path = "$tmp/journal-cap.jsonl";
my $journal_cap_seed = FServe::Transfer::Journal->open_store(path => $journal_cap_path);
$journal_cap_seed->append('cap_seed', { retained => 1 });
my $journal_cap_prefix_size = -s $journal_cap_path;
$journal_cap_seed->close();
my $journal_cap_callback = 0;
my $journal_cap_store = FServe::Transfer::Journal->open_store(
    path => $journal_cap_path,
    max_journal_bytes => $journal_cap_prefix_size + 1,
);
$journal_cap_store->set_unhealthy_callback(sub { $journal_cap_callback++ });
my $journal_cap_append_ok = eval {
    $journal_cap_store->append('over_cap', { retained => 2 });
    1;
};
ok !$journal_cap_append_ok, 'journal byte ceiling refuses an append that would exceed its bound';
like $@, qr/request journal reached its configured byte limit/,
    'journal ceiling reports a capacity refusal';
is -s $journal_cap_path, $journal_cap_prefix_size,
    'capacity refusal writes no partial or over-limit record';
ok !$journal_cap_store->healthy && $journal_cap_callback == 1,
    'capacity refusal poisons the writer and invokes the fail-closed callback';
$journal_cap_store->close();
my $journal_cap_reopen = FServe::Transfer::Journal->open_store(
    path => $journal_cap_path,
    max_journal_bytes => $journal_cap_prefix_size + 4096,
);
is scalar(@{$journal_cap_reopen->page(0, 10)}), 1,
    'raising the configured ceiling replays all retained history without repair';
$journal_cap_reopen->append('after_capacity_increase', { retained => 3 });
is scalar(@{$journal_cap_reopen->page(0, 10)}), 2,
    'writer resumes only after reopening with a sufficient explicit ceiling';
$journal_cap_reopen->close();

my $boundary_path = "$tmp/boundary.jsonl";
my $record_limit = $FServe::Transfer::Journal::MAX_RECORD_BYTES;
my $canonical_json = JSON::PP->new->canonical(1);
my $serialized_boundary_record = sub {
    my ($sequence, $payload) = @_;
    my $record = {
        version => $FServe::Transfer::Journal::VERSION,
        sequence => $sequence,
        event => 'boundary',
        data => { payload => $payload },
        previous_digest => '0' x 64,
    };
    $record->{digest} = sha256_hex($canonical_json->encode($record));
    return $canonical_json->encode($record) . "\n";
};
my $empty_boundary_size = length($serialized_boundary_record->(1, ''));
my $boundary_payload = 'x' x ($record_limit - $empty_boundary_size);
is length($serialized_boundary_record->(1, $boundary_payload)), $record_limit,
    'fixture constructs a journal record exactly at the configured byte limit';
my $bounded_store = FServe::Transfer::Journal->open_store(path => $boundary_path,
    max_record_bytes => $record_limit);
$bounded_store->append('boundary', { payload => $boundary_payload });
is -s $boundary_path, $record_limit, 'record exactly at the byte limit is durably accepted';
my $oversize_payload = $boundary_payload . 'x';
my $oversize_line = $serialized_boundary_record->(2, $oversize_payload);
is length($oversize_line), $record_limit + 1,
    'oversize fixture exceeds the limit by exactly one byte';
my $size_before_oversize = -s $boundary_path;
my $oversize_ok = eval { $bounded_store->append('boundary', { payload => $oversize_payload }); 1 };
ok !$oversize_ok, 'record one byte over the limit is refused';
like $@, qr/journal event exceeds configured record limit/,
    'over-limit refusal identifies the record-size policy';
is -s $boundary_path, $size_before_oversize,
    'rejected over-limit record writes no partial journal bytes';
ok $bounded_store->healthy, 'pre-write record-size refusal preserves journal health';
$bounded_store->append('marker', { ok => 1 });
is scalar(@{$bounded_store->page(1, 5)}), 1,
    'healthy journal accepts a later small record after the over-limit refusal';
$bounded_store->close();

my $oversized_line_path = "$tmp/oversized-line.jsonl";
open my $oversized_line_fh, '>:raw', $oversized_line_path or die $!;
print {$oversized_line_fh} ('x' x 8192) for 1 .. 128;
close $oversized_line_fh or die $!;
my $oversized_line_ok = eval {
    FServe::Transfer::Journal->open_store(path => $oversized_line_path,
        max_record_bytes => $record_limit);
    1;
};
ok !$oversized_line_ok, 'oversized unterminated input is refused during bounded replay';
like $@, qr/journal line exceeds configured record limit/,
    'oversized input refusal reports the record bound';

my $page_tamper_path = "$tmp/page-tamper.jsonl";
my $page_tamper_store = FServe::Transfer::Journal->open_store(path => $page_tamper_path);
$page_tamper_store->append('page_event', { value => 'origin' });
open my $page_tamper_read, '<:raw', $page_tamper_path or die $!;
my $page_tamper_line = <$page_tamper_read>;
close $page_tamper_read or die $!;
$page_tamper_line =~ s/origin/Origin/;
open my $page_tamper_write, '+<:raw', $page_tamper_path or die $!;
seek($page_tamper_write, 0, 0) or die $!;
print {$page_tamper_write} $page_tamper_line or die $!;
close $page_tamper_write or die $!;
my $tampered_page_ok = eval { $page_tamper_store->page(0, 10); 1 };
ok !$tampered_page_ok, 'history paging revalidates records changed after the initial replay';
like $@, qr/integrity check failed/,
    'history-page corruption refusal reports the journal digest failure';
ok !$page_tamper_store->healthy,
    'page validation failure disables further durable dispatch through this writer';
$page_tamper_store->close();

my $corrupt_path = "$tmp/corrupt.jsonl";
open my $corrupt_fh, '>:raw', $corrupt_path or die $!;
print {$corrupt_fh} "{\"version\":1}";
close $corrupt_fh;
my $corrupt_ok = eval { FServe::Transfer::Journal->open_store(path => $corrupt_path); 1 };
ok !$corrupt_ok, 'unterminated journal record blocks recovery and dispatch';

my $tamper_path = "$tmp/tamper.jsonl";
my $tamper_store = FServe::Transfer::Journal->open_store(path => $tamper_path);
$tamper_store->append('tuple_reserved', { tuple => 'Net/Peer/File.bin' });
$tamper_store->close();
open my $tamper_read, '<:raw', $tamper_path or die $!;
my $line = <$tamper_read>;
close $tamper_read;
$line =~ s/File\.bin/Other.bin/;
open my $tamper_write, '>:raw', $tamper_path or die $!;
print {$tamper_write} $line;
close $tamper_write;
my $tampered_ok = eval { FServe::Transfer::Journal->open_store(path => $tamper_path); 1 };
ok !$tampered_ok, 'journal integrity digest detects edited records';

my $web_operation_path = "$tmp/web-operation.jsonl";
my $web_operation_id = 'web-download-' . ('a' x 64);
my $web_operation_coordinator = open_coordinator(path => $web_operation_path);
my %web_operation_job = (
    provider => 'find', network_profile => 'MockNet',
    selection => { remote_path => '/books/Web.epub', expected_peer => 'Bot',
        basename => 'Web.epub', trigger_raw => '!bot', selection_token => 'find-1-1' },
    limits => {},
);
my $web_job = $web_operation_coordinator->create_job(%web_operation_job,
    context => { web_operation_id => $web_operation_id });
is $web_operation_coordinator->job_by_web_operation($web_operation_id)->{id}, $web_job->{id},
    'a running coordinator finds a job by its web operation without a restart';
my $web_duplicate = eval { $web_operation_coordinator->create_job(%web_operation_job,
    selection => { %{$web_operation_job{selection}}, selection_token => 'find-2-1' },
    context => { web_operation_id => $web_operation_id }); 1 };
ok !$web_duplicate, 'a running coordinator refuses a second job for one web operation';
$web_operation_coordinator->close();
my $web_operation_replay = open_coordinator(path => $web_operation_path);
is $web_operation_replay->job_by_web_operation($web_operation_id)->{id}, $web_job->{id},
    'journal replay preserves the web operation lookup';
$web_operation_replay->close();

my $coordinator_path = "$tmp/coordinator.jsonl";
my $coordinator = open_coordinator(path => $coordinator_path);
my $queued_job = $coordinator->create_job(
    provider => 'searchbot', network_profile => 'MockNet',
    selection => { collection_id => 'collection-1', source_row => 2,
        exact_payload => '!Bot Book.epub ::INFO:: 10B', expected_peer => 'Bot',
        basename => 'Book.epub' },
    context => { channel => '#books', connection_identity => 'connection-1', connection_epoch => 7 },
    limits => { content_bytes => 1024 },
);
is $queued_job->{state}, 'held', 'new coordinator job is held without transport activity';
my $duplicate_job = eval { $coordinator->create_job(
    provider => 'searchbot', network_profile => 'MockNet',
    selection => $queued_job->{selection}, context => $queued_job->{context}, limits => $queued_job->{limits}); 1 };
ok !$duplicate_job, 'full provider identity prevents duplicate queued selections';
my $dispatching = $coordinator->begin_dispatch($queued_job->{id}, casemapping => 'rfc1459');
is $dispatching->{state}, 'dispatch_intent', 'dispatch intent and tuple reservation persist before transport';
is $coordinator->tuple_count, 1, 'DCC tuple is durably reserved with its job';
my $second = $coordinator->create_job(provider => 'searchbot', network_profile => 'MockNet',
    selection => { collection_id => 'collection-2', source_row => 1,
        exact_payload => '!Bot Different.epub', expected_peer => 'Bot', basename => 'Book.epub' },
    context => { channel => '#books' }, limits => {});
my $preflight_collision = $coordinator->preflight_tuples($second->{id}, casemapping => 'rfc1459');
ok !$preflight_collision->{available}, 'known DCC tuple conflicts can be refused before provider trigger traffic';
like $preflight_collision->{reason}, qr/already reserved/, 'tuple preflight identifies the durable reservation owner';
my $collision = eval { $coordinator->begin_dispatch($second->{id}); 1 };
ok !$collision, 'different remote selection cannot reuse an indistinguishable DCC tuple';
$coordinator->record_dispatch_result($queued_job->{id}, 'sent');
$coordinator->close();
my $coordinator2 = open_coordinator(path => $coordinator_path);
is $coordinator2->job($queued_job->{id})->{state}, 'needs_attention',
    'restart converts an awaiting request into needs_attention without resending it';
is $coordinator2->job($second->{id})->{state}, 'held', 'unstarted jobs remain held after restart';
is $coordinator2->tuple_count, 1, 'ambiguous offer tuple survives restart';
is scalar(@{$coordinator2->recovery_events}), 1, 'restart recovery is recorded as evidence';
$coordinator2->close();

my $bounded_history_path = "$tmp/bounded-history.jsonl";
my @bounded_history_ids;
{
    local $FServe::Transfer::Coordinator::MAX_RECENT_TERMINAL_JOBS = 2;
    local $FServe::Transfer::Coordinator::MAX_JOB_IDENTITIES = 4;
    my $bounded_history = open_coordinator(path => $bounded_history_path);
    my $first_selection;
    for my $index (1 .. 4) {
        my $selection = { remote_path => "/History/Book-$index.epub",
            name => "Book-$index.epub", expected_peer => 'HistoryBot' };
        $first_selection = $selection if $index == 1;
        my $created = $bounded_history->create_job(provider => 'find',
            network_profile => 'HistoryNet', selection => $selection,
            context => { channel => '#history' }, limits => {});
        push @bounded_history_ids, $created->{id};
        $bounded_history->transition($created->{id}, 'cancelled',
            outcome => 'history_bound_fixture');
    }
    is scalar(keys %{$bounded_history->jobs}), 2,
        'coordinator retains only the configured recent terminal-job cache';
    is $bounded_history->job($bounded_history_ids[0])->{state}, 'cancelled',
        'an evicted terminal job remains retrievable by streaming its journal history';
    my $history_duplicate = eval {
        $bounded_history->create_job(provider => 'find', network_profile => 'HistoryNet',
            selection => $first_selection, context => { channel => '#history' }, limits => {});
        1;
    };
    ok !$history_duplicate,
        'provider-identity duplicate checks survive terminal metadata eviction';
    like $@, qr/identical provider selection/,
        'retained identity guard explains duplicate refusal after eviction';
    my $capacity_job = eval {
        $bounded_history->create_job(provider => 'find', network_profile => 'HistoryNet',
            selection => { remote_path => '/History/Book-5.epub', name => 'Book-5.epub',
                expected_peer => 'HistoryBot' }, context => { channel => '#history' }, limits => {});
        1;
    };
    ok !$capacity_job, 'job creation stops when the bounded identity history reaches its cap';
    like $@, qr/job identity history capacity reached/,
        'identity-cap refusal preserves prior duplicate guards';
    $bounded_history->close();

    my $bounded_history_reopened = open_coordinator(path => $bounded_history_path);
    is scalar(keys %{$bounded_history_reopened->jobs}), 2,
        'restart replay retains only the bounded recent terminal metadata';
    is $bounded_history_reopened->job($bounded_history_ids[0])->{state}, 'cancelled',
        'journal lookup can inspect older terminal history after restart';
    $bounded_history_reopened->close();
}

my $journal_compaction_path = "$tmp/journal-compaction.jsonl";
my $journal_compaction = open_coordinator(
    path => $journal_compaction_path, max_journal_bytes => 24 * 1024);
my $compact_selection = {
    remote_path => '/Compaction/Keep.epub', name => 'Keep.epub',
    expected_peer => 'CompactBot',
};
my $compact_job = $journal_compaction->create_job(provider => 'find',
    network_profile => 'CompactNet', selection => $compact_selection,
    context => { channel => '#compact' }, limits => {});
my $compact_job_id = $compact_job->{id};
$journal_compaction->begin_dispatch($compact_job_id, casemapping => 'ascii');
my $compact_final_selection = {
    remote_path => '/Compaction/Published.epub', name => 'Published.epub',
    expected_peer => 'CompactBot',
};
my $compact_final_job = $journal_compaction->create_job(provider => 'find',
    network_profile => 'CompactNet', selection => $compact_final_selection,
    context => { channel => '#compact' }, limits => {});
my $compact_final_id = $compact_final_job->{id};
$journal_compaction->begin_dispatch($compact_final_id, casemapping => 'ascii');
$journal_compaction->record_dispatch_result($compact_final_id, 'sent');
$journal_compaction->accept_offer($compact_final_id,
    offered_basename => 'Published.epub', accepted_lifecycle => 'compact-final');
my $compact_final_bytes = 'saved bytes';
my $compact_final_sha = sha256_hex($compact_final_bytes);
$journal_compaction->reserve_finalization($compact_final_id,
    staging_path => "$tmp/compact-staging", destination_path => "$tmp/compact-final",
    expected_size => length($compact_final_bytes), expected_sha256 => $compact_final_sha);
$journal_compaction->complete_finalization($compact_final_id, success => 1,
    destination_path => "$tmp/compact-final", observed_size => length($compact_final_bytes),
    observed_sha256 => $compact_final_sha);
my $compact_capacity_refused = 0;
for (1 .. 100) {
    my $ok = eval {
        $journal_compaction->record_event('audit_noise', {
            job_id => $compact_job_id, payload => 'x' x 512,
        });
        1;
    };
    unless ($ok) {
        $compact_capacity_refused = $@ =~ /reached its configured byte limit/ ? 1 : 0;
        last;
    }
}
ok $compact_capacity_refused,
    'journal ceiling blocks additional records before any compaction is attempted';
my $compact_old_size = -s $journal_compaction_path;
ok !$journal_compaction->journal->healthy,
    'byte-cap refusal keeps the coordinator fail-closed until local compaction';
my $compact_result = $journal_compaction->compact_journal();
ok $journal_compaction->journal->healthy,
    'validated local compaction reopens the journal writer after capacity refusal';
cmp_ok $compact_result->{new_bytes}, '<', $compact_old_size,
    'compaction collapses superseded transitions and repeated audit observations';
cmp_ok $compact_result->{new_bytes}, '<=', 24 * 1024,
    'compacted snapshot remains within the configured active-journal ceiling';
is $journal_compaction->tuple_count, 2,
    'compaction retains every DCC tuple reservation in coordinator memory';
my $compact_tuple = (tuple_keys_for_job($compact_job, 'ascii'))[0];
is $journal_compaction->tuple_owner($compact_tuple), $compact_job_id,
    'compaction preserves the reserved tuple owner';
my $compact_final_tuple = (tuple_keys_for_job($compact_final_job, 'ascii'))[0];
is $journal_compaction->tuple_owner($compact_final_tuple), $compact_final_id,
    'compaction preserves a second job and its independent tuple guard';
my $compact_noise_count = scalar grep {
    $_->{event} eq 'audit_noise'
} @{$journal_compaction->journal->page(0, 500)};
is $compact_noise_count, 1,
    'compacted history retains the latest audit observation for each job and event';
$journal_compaction->record_event('post_compaction', { job_id => $compact_job_id });
$journal_compaction->close();

my $journal_compaction_reopened = open_coordinator(
    path => $journal_compaction_path, max_journal_bytes => 64 * 1024);
is $journal_compaction_reopened->job($compact_job_id)->{state}, 'needs_attention',
    'compacted dispatch intent recovers to needs_attention without resending';
is $journal_compaction_reopened->job($compact_final_id)->{state}, 'complete',
    'compaction preserves the completed job state';
is $journal_compaction_reopened->job($compact_final_id)->{finalization}{result}{observed_sha256},
    $compact_final_sha, 'compaction retains published-file finalization evidence';
is $journal_compaction_reopened->tuple_count, 2,
    'compacted DCC tuple reservation survives restart';
is $journal_compaction_reopened->tuple_owner($compact_tuple), $compact_job_id,
    'replayed compacted tuple still blocks an ambiguous duplicate offer';
is $journal_compaction_reopened->tuple_owner($compact_final_tuple), $compact_final_id,
    'replayed terminal job still owns its reserved DCC tuple';
my $compact_duplicate = eval {
    $journal_compaction_reopened->create_job(provider => 'find',
        network_profile => 'CompactNet', selection => $compact_selection,
        context => { channel => '#compact' }, limits => {});
    1;
};
ok !$compact_duplicate,
    'provider identity duplicate refusal survives journal compaction and restart';
like $@, qr/identical provider selection/,
    'compacted duplicate identity reports the normal refusal';
$journal_compaction_reopened->close();

my $journal_recovery_path = "$tmp/journal-compaction-recovery.jsonl";
my $journal_recovery_seed = open_coordinator(path => $journal_recovery_path);
my $journal_recovery_job = $journal_recovery_seed->create_job(provider => 'find',
    network_profile => 'RecoveryNet', selection => {
        remote_path => '/Recovery/Keep.epub', name => 'Keep.epub',
        expected_peer => 'RecoveryBot',
    }, context => { channel => '#recovery' }, limits => {});
$journal_recovery_seed->close();
ok copy($journal_recovery_path, "$journal_recovery_path.compact.ready"),
    'fixture prepares a complete snapshot at the compaction publication boundary';
ok rename($journal_recovery_path, "$journal_recovery_path.compact.archive"),
    'fixture models a crash after the original journal was staged';
my $journal_recovery = open_coordinator(path => $journal_recovery_path);
is $journal_recovery->job($journal_recovery_job->{id})->{state}, 'held',
    'restart promotes a validated prepared snapshot after an interrupted publication';
ok !-e "$journal_recovery_path.compact.archive",
    'successful compaction recovery removes only the obsolete staged journal';
$journal_recovery->close();

my $journal_rejected_path = "$tmp/journal-compaction-rejected.jsonl";
my $journal_rejected_seed = open_coordinator(path => $journal_rejected_path);
my $journal_rejected_job = $journal_rejected_seed->create_job(provider => 'find',
    network_profile => 'RejectedNet', selection => {
        remote_path => '/Rejected/Keep.epub', name => 'Keep.epub',
        expected_peer => 'RejectedBot',
    }, context => { channel => '#rejected' }, limits => {});
$journal_rejected_seed->close();
open my $rejected_snapshot, '>:raw', "$journal_rejected_path.compact.ready" or die $!;
print {$rejected_snapshot} "not a valid journal\n" or die $!;
close $rejected_snapshot or die $!;
ok rename($journal_rejected_path, "$journal_rejected_path.compact.archive"),
    'fixture leaves the verified archive as the recovery source after a missing canonical path';
my $journal_rejected = open_coordinator(path => $journal_rejected_path);
is $journal_rejected->job($journal_rejected_job->{id})->{state}, 'held',
    'invalid prepared snapshot falls back to the validated original journal';
ok -f "$journal_rejected_path.compact.rejected",
    'invalid prepared snapshot is preserved for inspection';
$journal_rejected->close();

my $intent_crash_path = "$tmp/dispatch-intent-crash.jsonl";
my $intent_crash = open_coordinator(path => $intent_crash_path);
my $intent_crash_job = $intent_crash->create_job(
    provider => 'searchbot', network_profile => 'IntentCrashNet',
    selection => { collection_id => 'intent-crash-collection', source_row => 1,
        exact_payload => '!IntentBot NeverRepeat.epub', expected_peer => 'IntentBot',
        basename => 'NeverRepeat.epub' }, context => { channel => '#books' }, limits => {},
);
my $durable_intent = $intent_crash->begin_dispatch($intent_crash_job->{id}, casemapping => 'ascii');
is $durable_intent->{state}, 'dispatch_intent', 'dispatch intent is durable before transport invocation';
$intent_crash->close();
my $recovered_intent = open_coordinator(path => $intent_crash_path);
is $recovered_intent->job($intent_crash_job->{id})->{state}, 'needs_attention',
    'restart after intent but before a recorded send fails closed as ambiguous';
is $recovered_intent->recovery_events->[0]{previous_state}, 'dispatch_intent',
    'pre-transport crash point is retained in recovery evidence';
is $recovered_intent->tuple_count, 1, 'pre-transport crash retains its DCC tuple reservation';
my $repeat_intent = eval { $recovered_intent->begin_dispatch($intent_crash_job->{id}); 1 };
ok !$repeat_intent, 'recovered ambiguous intent cannot be dispatched again';
$recovered_intent->close();

my $prepare_receiving_job = sub {
    my ($coordinator, $profile, $name, $peer) = @_;
    my $job = $coordinator->create_job(provider => 'searchbot',
        network_profile => $profile, selection => {
            collection_id => "collection-$name", source_row => 1,
            exact_payload => "!$peer $name", expected_peer => $peer,
            basename => $name,
        }, context => { channel => '#books' }, limits => {});
    my $id = $job->{id};
    $coordinator->begin_dispatch($id, casemapping => 'ascii');
    $coordinator->record_dispatch_result($id, 'sent');
    $coordinator->accept_offer($id, offered_basename => $name,
        accepted_lifecycle => "lifecycle-$name");
    return $id;
};

my $resume_fixture_sequence = 0;
my $prepare_resume_pending_job = sub {
    my ($coordinator, $profile, $name, $peer, $stop_intent) = @_;
    my $staging_root = "$tmp/resume-fixture-" . ++$resume_fixture_sequence;
    mkdir $staging_root or die "create resume fixture staging root: $!";
    my $path = "$staging_root/partial.bin";
    my $bytes = "resume-prefix-$name";
    open my $fh, '>:raw', $path or die "create resume fixture partial: $!";
    print {$fh} $bytes;
    close $fh or die "close resume fixture partial: $!";
    my $captured = capture_partial(path => $path, staging_root => $staging_root);
    die 'resume fixture partial could not be captured'
        unless $captured->{type} eq 'captured_partial';
    my $server_tag = "$profile-tag";
    my $connection_identity = "fixture-connection-$profile";
    my $whole_digest = sha256_hex($bytes . '-complete');
    my $job = $coordinator->create_job(
        provider => 'searchbot', network_profile => $profile,
        selection => { collection_id => "collection-$name", source_row => 1,
            exact_payload => "!$peer $name", expected_peer => $peer,
            basename => $name, offered_basename => $name },
        context => { channel => '#books', server_tag => $server_tag,
            process_incarnation => 'offline-resume-fixture-process',
            connection_identity => $connection_identity, connection_epoch => 1,
            casemapping => 'ascii' },
        limits => {},
        trusted_content_digest => { sha256 => $whole_digest,
            provenance => { kind => 'test_fixture', asserted_by => 'offline-test',
                asserted_at => 1791100109 } });
    my $id = $job->{id};
    $coordinator->begin_dispatch($id, casemapping => 'ascii');
    $coordinator->record_dispatch_result($id, 'sent');
    $coordinator->accept_offer($id, offered_basename => $name,
        accepted_lifecycle => "initial-$profile-$name");
    if (ref($stop_intent) eq 'HASH') {
        $coordinator->record_transfer_stop_intent(job_id => $id,
            transfer_key => "native-$profile-$name",
            request_id => "request-$profile-$name", intent => $stop_intent);
    }
    my $interrupted = $coordinator->mark_interrupted($id,
        path => $path, staging_root => $staging_root, receive_path => $path,
        receive_identity => { device => $captured->{identity}{device},
            inode => $captured->{identity}{inode} },
        size => length($bytes), total_size => length($bytes) + 9,
        offered_basename => $name, writer_closed => 1);
    my $sealing = begin_partial_seal(path => $path, staging_root => $staging_root,
        expected_identity => $interrupted->{partial}{file_identity},
        total_size => $interrupted->{partial}{total_size});
    my $sealed;
    while ($sealing->{type} eq 'sealing') {
        $sealed = step_partial_seal($sealing, 64);
        last unless $sealed->{type} eq 'in_progress';
    }
    die 'resume fixture partial could not be sealed'
        unless $sealed->{type} eq 'sealed_partial';
    my $sealed_job = $coordinator->seal_interrupted_partial($id, %$sealed);
    my $validation = begin_partial_validation(path => $path,
        staging_root => $staging_root, total_size => $sealed_job->{partial}{total_size},
        partial_size => $sealed_job->{partial}{size},
        partial_identity => $sealed_job->{partial}{file_identity},
        partial_sha256 => $sealed_job->{partial}{partial_sha256});
    my $validated;
    while ($validation->{type} eq 'validating_partial') {
        $validated = step_partial_validation($validation, 64);
        last unless $validated->{type} eq 'in_progress';
    }
    die 'resume fixture partial could not be incrementally validated'
        unless $validated->{type} eq 'valid_partial';
    my $pending = $coordinator->begin_resume_intent($id,
        profile => { supported => 1, name => 'test-only-lifecycle-fixture' },
        process_incarnation => 'offline-resume-fixture-process',
        connection_identity => $connection_identity, connection_epoch => 1,
        offer => { offer_kind => 'incoming-file-send',
            connection_identity => $connection_identity,
            connection_epoch => 1, server_tag => $server_tag, sender => $peer,
            offered_basename => $name,
            total_size => length($bytes) + 9,
            native_lifecycle_identity => "continuation-$profile-$name" },
        validated_partial => $validated);
    die 'resume fixture did not enter resume_pending'
        unless $pending->{state} eq 'resume_pending';
    return ($id, $validated);
};

my $pending_cancel_path = "$tmp/pending-stop-cancel.jsonl";
my $pending_cancel = open_coordinator(path => $pending_cancel_path);
my $pending_cancel_id = $prepare_receiving_job->(
    $pending_cancel, 'PendingStopNet', 'Cancel.epub', 'PendingBot');
my $pending_cancel_intent = {
    job_state => 'cancelled', job_outcome => 'searchbot_cancelled',
    request_state => 'cancelled', reason => 'operator cancelled while close was pending',
    writer_closed => 0,
};
$pending_cancel->record_transfer_stop_intent(job_id => $pending_cancel_id,
    transfer_key => 'native-lifecycle-cancel', request_id => 'request-cancel',
    intent => $pending_cancel_intent);
is $pending_cancel->transfer_stop_intent($pending_cancel_id)->{intent}{job_state},
    'cancelled', 'coordinator tracks stop intent for the current receive lifecycle';
my $conflicting_stop = eval {
    $pending_cancel->record_transfer_stop_intent(job_id => $pending_cancel_id,
        transfer_key => 'native-lifecycle-cancel', request_id => 'request-cancel',
        intent => { %$pending_cancel_intent, job_state => 'interrupted' });
    1;
};
ok !$conflicting_stop, 'a later stop cannot replace the first lifecycle disposition';
my $pending_cancel_compaction = $pending_cancel->compact_journal();
ok $pending_cancel_compaction->{new_bytes} > 0,
    'pending cancellation compacts before native closure is known';
$pending_cancel->close();
my $pending_cancel_recovered = open_coordinator(path => $pending_cancel_path);
my $pending_cancel_job = $pending_cancel_recovered->job($pending_cancel_id);
is $pending_cancel_job->{state}, 'cancelled',
    'restart applies the persisted cancellation before generic interruption recovery';
is $pending_cancel_job->{outcome}, 'searchbot_cancelled',
    'restart preserves the cancellation outcome';
is $pending_cancel_job->{reason}, 'operator cancelled while close was pending',
    'restart preserves the original stop reason';
is $pending_cancel_job->{stop_intent}{job_state}, 'cancelled',
    'recovered terminal record retains the applied stop disposition';
ok !$pending_cancel_job->{partial} || !$pending_cancel_job->{partial}{writer_closed},
    'recovery does not invent native writer-closure evidence';
$pending_cancel_recovered->close();

my $stop_write_failure_path = "$tmp/stop-intent-write-failure.jsonl";
my $stop_write_failure = open_coordinator(path => $stop_write_failure_path);
my $stop_write_failure_id = $prepare_receiving_job->(
    $stop_write_failure, 'StopWriteFailureNet', 'WriteFailure.epub', 'FailureBot');
my $original_journal_append = \&FServe::Transfer::Journal::append;
my $stop_intent_append = eval {
    no warnings 'redefine';
    local *FServe::Transfer::Journal::append = sub {
        die "injected stop-intent append failure\n" if $_[1] eq 'transfer_stop_intent';
        return $original_journal_append->(@_);
    };
    $stop_write_failure->record_transfer_stop_intent(
        job_id => $stop_write_failure_id,
        transfer_key => 'native-lifecycle-write-failure',
        request_id => 'request-write-failure',
        intent => {
            job_state => 'cancelled', job_outcome => 'write_failure_cancel',
            reason => 'journal failure fixture', writer_closed => 0,
        });
    1;
};
my $stop_intent_error = $@;
ok !$stop_intent_append, 'stop intent append failure is reported to its caller';
like $stop_intent_error, qr/injected stop-intent append failure/,
    'stop intent write failure is not mistaken for durable success';
ok !$stop_write_failure->transfer_stop_intent($stop_write_failure_id),
    'failed stop intent is not exposed as durable coordinator state';
$stop_write_failure->close();
my $stop_write_failure_recovered = open_coordinator(path => $stop_write_failure_path);
my $stop_write_failure_job = $stop_write_failure_recovered->job($stop_write_failure_id);
is $stop_write_failure_job->{state}, 'interrupted',
    'restart falls back to the normal interrupted state when stop intent could not be journaled';
ok !$stop_write_failure_job->{partial} || !$stop_write_failure_job->{partial}{writer_closed},
    'failed stop-intent persistence never fabricates writer-closure evidence';
$stop_write_failure_recovered->close();

my $stale_stop_path = "$tmp/stale-stop-lifecycle.jsonl";
my $stale_stop = open_coordinator(path => $stale_stop_path);
my ($stale_stop_id, $stale_stop_snapshot) = $prepare_resume_pending_job->(
    $stale_stop, 'StaleStopNet', 'Stale.epub', 'StaleBot', {
        job_state => 'cancelled', job_outcome => 'old_cancel',
        request_state => 'cancelled', reason => 'old lifecycle stop',
        writer_closed => 0,
    });
$stale_stop->transition($stale_stop_id, 'receiving',
    outcome => 'new_receive_lifecycle');
ok !$stale_stop->transfer_stop_intent($stale_stop_id),
    'a new receiving lifecycle clears the earlier stop intent';
$stale_stop->close();
my $stale_stop_recovered = open_coordinator(path => $stale_stop_path);
my $stale_stop_job = $stale_stop_recovered->job($stale_stop_id);
is $stale_stop_job->{state}, 'interrupted',
    'restart does not apply an older cancellation to a newer receive lifecycle';
is $stale_stop_job->{outcome}, 'restart_recovery',
    'new lifecycle follows ordinary recovery when it has no stop disposition';
$stale_stop_recovered->close();
is discard_partial_snapshot($stale_stop_snapshot)->{type}, 'discarded_snapshot',
    'stale-stop resume fixture discards its private snapshot after assertions';

my $pending_expiry_path = "$tmp/pending-stop-expiry.jsonl";
my $pending_expiry = open_coordinator(path => $pending_expiry_path);
my $pending_expiry_id = $prepare_receiving_job->(
    $pending_expiry, 'PendingExpiryNet', 'Expiry.epub', 'ExpiryBot');
$pending_expiry->record_transfer_stop_intent(job_id => $pending_expiry_id,
    transfer_key => 'native-lifecycle-expiry', request_id => 'request-expiry',
    intent => {
        job_state => 'interrupted', job_outcome => 'transfer_expired',
        request_state => 'transfer_expired', reason => 'transfer deadline elapsed',
        writer_closed => 0,
    });
my $pending_expiry_compaction = $pending_expiry->compact_journal();
ok $pending_expiry_compaction->{new_bytes} > 0,
    'pending stop intent is retained in the compacted snapshot';
$pending_expiry->close();
my $pending_expiry_recovered = open_coordinator(path => $pending_expiry_path);
my $pending_expiry_job = $pending_expiry_recovered->job($pending_expiry_id);
is $pending_expiry_job->{state}, 'interrupted',
    'compacted timeout intent recovers as interrupted';
is $pending_expiry_job->{outcome}, 'transfer_expired',
    'compacted timeout intent preserves its original outcome';
is $pending_expiry_job->{reason}, 'transfer deadline elapsed',
    'compacted timeout intent preserves its original reason';
ok !$pending_expiry_job->{partial} || !$pending_expiry_job->{partial}{writer_closed},
    'compacted recovery still withholds unproven writer closure';
$pending_expiry_recovered->close();

for my $stopped_state (qw(cancelled interrupted)) {
    my $path = "$tmp/compacted-stopped-$stopped_state.jsonl";
    my $coordinator = open_coordinator(path => $path);
    my $id = $prepare_receiving_job->($coordinator,
        "CompactedStop-" . $stopped_state, "$stopped_state.epub", 'StopBot');
    my $outcome = "confirmed_$stopped_state";
    my $intent = {
        job_state => $stopped_state,
        job_outcome => $outcome,
        reason => "confirmed $stopped_state after native close",
        writer_closed => 0,
    };
    $coordinator->record_transfer_stop_intent(job_id => $id,
        transfer_key => "confirmed-$stopped_state",
        request_id => "confirmed-$stopped_state-request",
        intent => $intent);
    my %terminal_meta = (
        outcome => $outcome,
        reason => $intent->{reason},
    );
    $terminal_meta{data} = {
        stop_intent => { %$intent, writer_closed => 1 },
    } if $stopped_state eq 'cancelled';
    $coordinator->transition($id, $stopped_state, %terminal_meta);

    my $compacted = $coordinator->compact_journal();
    ok $compacted->{new_bytes} > 0,
        "$stopped_state outcome compacts after its stop-intent record";
    my $snapshot_events = $coordinator->journal->page(0, 100);
    my ($snapshot_record) = grep {
        $_->{event} eq 'job_created' &&
            ($_->{data}{job}{id} // '') eq $id
    } @$snapshot_events;
    ok $snapshot_record, "$stopped_state latest job snapshot is present";
    if ($snapshot_record) {
        is $snapshot_record->{data}{job}{state}, $stopped_state,
            "$stopped_state is retained in the compacted snapshot";
        is $snapshot_record->{data}{job}{outcome}, $outcome,
            "$stopped_state outcome is retained in the compacted snapshot";
        is $snapshot_record->{data}{job}{reason}, $intent->{reason},
            "$stopped_state reason is retained in the compacted snapshot";
    } else {
        fail "$stopped_state is retained in the compacted snapshot";
        fail "$stopped_state outcome is retained in the compacted snapshot";
        fail "$stopped_state reason is retained in the compacted snapshot";
    }
    $coordinator->close();

    my $reopened = eval { open_coordinator(path => $path) };
    ok $reopened, "$stopped_state compacted journal reopens";
    if ($reopened) {
        my $job = $reopened->job($id);
        my $recovered_state = $stopped_state eq 'interrupted'
            ? 'needs_attention' : $stopped_state;
        my $recovered_outcome = $stopped_state eq 'interrupted'
            ? 'restart_recovery' : $outcome;
        is $job->{state}, $recovered_state,
            "$stopped_state follows the ordinary restart recovery policy";
        is $job->{outcome}, $recovered_outcome,
            "$stopped_state recovery outcome matches the ordinary restart policy";
        my $audit = $reopened->journal->page(0, 100);
        is scalar(grep { $_->{event} eq 'transfer_stop_intent' } @$audit), 1,
            "$stopped_state retains its latest stop-intent audit record";
        my $again = $reopened->compact_journal();
        ok $again->{new_bytes} > 0,
            "$stopped_state journal compacts again after replay";
        $reopened->close();

        my $twice_reopened = eval { open_coordinator(path => $path) };
        ok $twice_reopened,
            "$stopped_state journal remains replayable after repeated compaction";
        if ($twice_reopened) {
            is $twice_reopened->job($id)->{outcome}, $recovered_outcome,
                "$stopped_state outcome remains stable after repeated compaction";
            $twice_reopened->close();
        }
    } else {
        fail "$stopped_state compacted journal follows recovery for a second compaction";
        fail "$stopped_state recovery outcome matches the ordinary restart policy";
        fail "$stopped_state retains its stop-intent audit record";
        fail "$stopped_state journal compacts a second time";
        fail "$stopped_state journal reopens after repeated compaction";
        fail "$stopped_state recovery outcome remains stable after repeated compaction";
    }
}

my $stale_compaction_path = "$tmp/compacted-stale-stop.jsonl";
my $stale_compaction = open_coordinator(path => $stale_compaction_path);
my ($stale_compaction_id, $stale_compaction_snapshot) =
    $prepare_resume_pending_job->($stale_compaction,
        'CompactedStaleNet', 'Stale.epub', 'StaleCompactBot',
        { job_state => 'cancelled', job_outcome => 'old_cancel',
            reason => 'old receive lifecycle', writer_closed => 0 });
$stale_compaction->transition($stale_compaction_id, 'receiving',
    outcome => 'new_receive_lifecycle');
$stale_compaction->compact_journal();
$stale_compaction->close();
my $stale_compaction_reopened = open_coordinator(path => $stale_compaction_path);
my $stale_compaction_job = $stale_compaction_reopened->job($stale_compaction_id);
is $stale_compaction_job->{state}, 'interrupted',
    'compaction does not apply an older stop to a newer receive lifecycle';
is $stale_compaction_job->{outcome}, 'restart_recovery',
    'new lifecycle uses ordinary recovery when it has no matching stop intent';
my $stale_compaction_again = $stale_compaction_reopened->compact_journal();
ok $stale_compaction_again->{new_bytes} > 0,
    'stale stop history survives another compaction without becoming active';
$stale_compaction_reopened->close();
my $stale_compaction_twice = open_coordinator(path => $stale_compaction_path);
is $stale_compaction_twice->job($stale_compaction_id)->{state}, 'needs_attention',
    'repeated compaction keeps the newer lifecycle on ordinary recovery';
is $stale_compaction_twice->job($stale_compaction_id)->{outcome}, 'restart_recovery',
    'repeated compaction never reapplies the old cancellation outcome';
$stale_compaction_twice->close();
is discard_partial_snapshot($stale_compaction_snapshot)->{type}, 'discarded_snapshot',
    'stale-compaction fixture discards its private snapshot after assertions';

my $legacy_stop_path = "$tmp/compacted-legacy-stop.jsonl";
my $legacy_stop = open_coordinator(path => $legacy_stop_path);
my $legacy_stop_id = $prepare_receiving_job->(
    $legacy_stop, 'CompactedLegacyNet', 'Legacy.epub', 'LegacyBot');
$legacy_stop->record_event('transfer_stop_intent', {
    job_id => $legacy_stop_id,
    intent => { job_state => 'cancelled', job_outcome => 'legacy_cancel',
        reason => 'legacy stop intent without a sequence', writer_closed => 0 },
});
$legacy_stop->_replay_event({
    event => 'transfer_stop_intent',
    data => {
        job_id => $legacy_stop_id,
        intent => { job_state => 'cancelled', job_outcome => 'legacy_cancel',
            reason => 'legacy stop intent without a sequence', writer_closed => 0 },
    },
});
my $legacy_stop_compacted = $legacy_stop->compact_journal();
ok $legacy_stop_compacted->{new_bytes} > 0,
    'legacy stop intent without lifecycle_sequence compacts';
$legacy_stop->close();
my $legacy_stop_reopened = open_coordinator(path => $legacy_stop_path);
is $legacy_stop_reopened->job($legacy_stop_id)->{state}, 'cancelled',
    'legacy compacted stop remains bound to the receiving lifecycle it followed';
is $legacy_stop_reopened->job($legacy_stop_id)->{outcome}, 'legacy_cancel',
    'legacy compacted stop preserves its requested outcome';
$legacy_stop_reopened->close();

my $terminal_cache_compaction_path = "$tmp/compacted-stop-terminal-cache.jsonl";
my $terminal_cache_compaction = open_coordinator(path => $terminal_cache_compaction_path);
my ($oldest_stopped_id, $newest_stopped_id);
for my $index (1 .. 101) {
    my $name = "CacheStop-$index.epub";
    my $id = $prepare_receiving_job->($terminal_cache_compaction,
        "StopTerminalCache-$index", $name, "CacheBot$index");
    $oldest_stopped_id = $id if $index == 1;
    $newest_stopped_id = $id;
    my $intent = { job_state => 'cancelled',
        job_outcome => "cache_cancel_$index",
        reason => "terminal cache stop $index", writer_closed => 0 };
    $terminal_cache_compaction->record_transfer_stop_intent(
        job_id => $id, transfer_key => "cache-stop-$index",
        request_id => "cache-request-$index", intent => $intent);
    $terminal_cache_compaction->transition($id, 'cancelled',
        outcome => $intent->{job_outcome}, reason => $intent->{reason},
        data => { stop_intent => { %$intent, writer_closed => 1 } });
}
my $terminal_cache_compacted = $terminal_cache_compaction->compact_journal();
ok $terminal_cache_compacted->{new_bytes} > 0,
    'stopped jobs across the retained-terminal cache limit compact';
$terminal_cache_compaction->close();
my $terminal_cache_reopened = eval {
    open_coordinator(path => $terminal_cache_compaction_path);
};
ok $terminal_cache_reopened,
    'compacted stop audits replay when old terminal objects have been evicted';
if ($terminal_cache_reopened) {
    is $terminal_cache_reopened->job($oldest_stopped_id)->{outcome},
        'cache_cancel_1', 'oldest stopped outcome survives terminal cache eviction';
    is $terminal_cache_reopened->job($newest_stopped_id)->{outcome},
        'cache_cancel_101', 'newest stopped outcome survives compacted replay';
    $terminal_cache_reopened->close();
}

my $worker_stop_path = "$tmp/compact-worker-pending-stop.jsonl";
my $worker_stop = open_coordinator(path => $worker_stop_path);
my $worker_stop_id = $prepare_receiving_job->(
    $worker_stop, 'CompactWorkerStopNet', 'WorkerStop.epub', 'WorkerStopBot');
$worker_stop->record_transfer_stop_intent(job_id => $worker_stop_id,
    transfer_key => 'worker-pending-stop', request_id => 'worker-stop-request',
    intent => { job_state => 'cancelled', job_outcome => 'worker_cancel',
        reason => 'worker stop while native closure was pending', writer_closed => 0 });
$worker_stop->close();
my $compact_worker_path = "$Bin/../lib/FServe/Transfer/compact_journal_worker.pl";
open my $compact_worker_output, '-|', $^X, $compact_worker_path,
    $worker_stop_path, 1024 * 1024
    or die "could not launch isolated compaction worker: $!";
my $compact_worker_json;
{
    local $/;
    $compact_worker_json = <$compact_worker_output>;
}
my $compact_worker_closed = close $compact_worker_output;
is($? >> 8, 0, 'offline compaction worker exits successfully');
ok $compact_worker_closed, 'offline compaction worker output stream closes cleanly';
my $compact_worker_result = eval {
    JSON::PP->new->decode($compact_worker_json);
};
is $compact_worker_result->{event}, 'result',
    'offline compaction worker publishes a successful result';
my $worker_stop_reopened = open_coordinator(path => $worker_stop_path);
my $worker_stop_job = $worker_stop_reopened->job($worker_stop_id);
is $worker_stop_job->{state}, 'cancelled',
    'worker compaction retains recovered pending cancellation';
is $worker_stop_job->{outcome}, 'worker_cancel',
    'worker compaction retains the requested cancellation outcome';
ok !$worker_stop_job->{partial} ||
    !$worker_stop_job->{partial}{writer_closed},
    'worker recovery and compaction do not invent writer-closure evidence';
$worker_stop_reopened->close();

my $prepare_finalizing_job = sub {
    my ($coordinator, $profile, $filename) = @_;
    my $created = $coordinator->create_job(provider => 'find', network_profile => $profile,
        selection => { remote_path => "/Crash/$filename", name => $filename,
            expected_peer => 'CrashBot' }, context => { server_tag => $profile }, limits => {});
    my $id = $created->{id};
    $coordinator->transition($id, 'ready');
    $coordinator->transition($id, 'preparing');
    $coordinator->transition($id, 'dispatch_intent');
    $coordinator->transition($id, 'awaiting_offer');
    $coordinator->transition($id, 'receiving');
    return $id;
};

my $reconcile_bytes = "durable finalization fixture\0bytes";
my $reconcile_destination = "$tmp/reconciled.bin";
my $reconcile_path = "$tmp/reconcile.jsonl";
my $reconcile = open_coordinator(path => $reconcile_path);
my $reconcile_job = $prepare_finalizing_job->($reconcile, 'CrashNetGood', 'Good.epub');
$reconcile->reserve_finalization($reconcile_job,
    staging_path => "$tmp/staging-good.bin", destination_path => $reconcile_destination,
    expected_size => length($reconcile_bytes), expected_sha256 => sha256_hex($reconcile_bytes));
open my $reconcile_file, '>:raw', $reconcile_destination or die $!;
print {$reconcile_file} $reconcile_bytes;
close $reconcile_file or die $!;
$reconcile->close();
my $recovered_finalization = open_coordinator(path => $reconcile_path);
is $recovered_finalization->job($reconcile_job)->{state}, 'complete',
    'restart reconciles an already-published exact-size and exact-digest destination';
is $recovered_finalization->job($reconcile_job)->{finalization}{status}, 'reconciled_complete',
    'recovery records verified finalization evidence';
is_deeply $recovered_finalization->recovery_events->[0],
    { id => $reconcile_job, previous_state => 'finalizing', state => 'complete', destination_verified => 1 },
    'successful finalization reconciliation is explicit in recovery events';
open my $reconciled_read, '<:raw', $reconcile_destination or die $!;
my $reconciled_contents = do { local $/; <$reconciled_read> };
is $reconciled_contents, $reconcile_bytes, 'recovery leaves the exact published destination unchanged';
close $reconciled_read;
$recovered_finalization->close();

my $failed_result_destination = "$tmp/result-write-failed.bin";
my $failed_result_path = "$tmp/result-write-failed.jsonl";
my $failed_result = open_coordinator(path => $failed_result_path);
my $failed_result_job = $prepare_finalizing_job->($failed_result, 'CrashNetResultFailure', 'ResultFailure.epub');
$failed_result->reserve_finalization($failed_result_job,
    staging_path => "$tmp/staging-result-failure.bin",
    destination_path => $failed_result_destination,
    expected_size => length($reconcile_bytes), expected_sha256 => sha256_hex($reconcile_bytes));
open my $failed_result_file, '>:raw', $failed_result_destination or die $!;
print {$failed_result_file} $reconcile_bytes;
close $failed_result_file or die $!;
my $real_journal_append = \&FServe::Transfer::Journal::append;
{
    no warnings 'redefine';
    local *FServe::Transfer::Journal::append = sub {
        my ($journal, $event, @rest) = @_;
        die "injected finalization result persistence failure\n"
            if $event eq 'finalization_result';
        return $real_journal_append->($journal, $event, @rest);
    };
    my $completed = eval { $failed_result->complete_finalization($failed_result_job,
        success => 1, destination_path => $failed_result_destination,
        observed_size => length($reconcile_bytes), observed_sha256 => sha256_hex($reconcile_bytes)); 1 };
    ok !$completed, 'failed finalization-result journal append cannot claim success';
    like $@, qr/injected finalization result persistence failure/,
        'finalization-result persistence failure is surfaced';
}
is $failed_result->job($failed_result_job)->{state}, 'finalizing',
    'job remains finalizing when durable completion evidence cannot be written';
$failed_result->close();
my $recovered_result_failure = open_coordinator(path => $failed_result_path);
is $recovered_result_failure->job($failed_result_job)->{state}, 'complete',
    'restart verifies the exact already-published destination after result-write failure';
is $recovered_result_failure->recovery_events->[0]{destination_verified}, 1,
    'result-write failure recovery is based on destination size and digest';
$recovered_result_failure->close();

my $mismatch_bytes = 'X' x length($reconcile_bytes);
my $mismatch_destination = "$tmp/unverified.bin";
my $mismatch_path = "$tmp/unverified.jsonl";
my $mismatch = open_coordinator(path => $mismatch_path);
my $mismatch_job = $prepare_finalizing_job->($mismatch, 'CrashNetMismatch', 'Mismatch.epub');
$mismatch->reserve_finalization($mismatch_job,
    staging_path => "$tmp/staging-mismatch.bin", destination_path => $mismatch_destination,
    expected_size => length($reconcile_bytes), expected_sha256 => sha256_hex($reconcile_bytes));
open my $mismatch_file, '>:raw', $mismatch_destination or die $!;
print {$mismatch_file} $mismatch_bytes;
close $mismatch_file or die $!;
$mismatch->close();
my $recovered_mismatch = open_coordinator(path => $mismatch_path);
is $recovered_mismatch->job($mismatch_job)->{state}, 'needs_attention',
    'same-size destination with a mismatched digest is not reconciled as complete';
is $recovered_mismatch->recovery_events->[0]{destination_verified}, 0,
    'digest mismatch is recorded as unverified recovery evidence';
open my $mismatch_read, '<:raw', $mismatch_destination or die $!;
my $mismatch_contents = do { local $/; <$mismatch_read> };
is $mismatch_contents, $mismatch_bytes, 'unverified destination is preserved without overwrite';
close $mismatch_read;
$recovered_mismatch->close();

my $staging_only = "$tmp/staging-only.bin";
my $staging_destination = "$tmp/not-yet-published.bin";
my $staging_state_path = "$tmp/staging-only.jsonl";
my $staging_coordinator = open_coordinator(path => $staging_state_path);
my $staging_job = $prepare_finalizing_job->($staging_coordinator, 'CrashNetStaging', 'Staging.epub');
$staging_coordinator->reserve_finalization($staging_job,
    staging_path => $staging_only, destination_path => $staging_destination,
    expected_size => length($reconcile_bytes), expected_sha256 => sha256_hex($reconcile_bytes));
open my $staging_file, '>:raw', $staging_only or die $!;
print {$staging_file} $reconcile_bytes;
close $staging_file or die $!;
$staging_coordinator->close();
my $recovered_staging = open_coordinator(path => $staging_state_path);
is $recovered_staging->job($staging_job)->{state}, 'needs_attention',
    'staging-only crash is not silently published during restart';
ok !-e $staging_destination, 'recovery does not create a destination from staging bytes';
ok -f $staging_only && -s $staging_only == length($reconcile_bytes),
    'staging evidence is retained unchanged for inspection';
is $recovered_staging->recovery_events->[0]{destination_verified}, 0,
    'staging-only recovery is explicitly left unverified';
$recovered_staging->close();

my $clock = 100;
my $scheduler = FServe::Transfer::Scheduler->new(now => sub { $clock });
my $first = $scheduler->reserve(connection => 'irc:A', kind => 'query', route => 'irc:A/#x/Bot');
is $first->{delay}, 0, 'first connection message is immediately eligible';
$scheduler->commit($first->{token});
my $same_connection = $scheduler->reserve(connection => 'irc:A', kind => 'message');
is $same_connection->{delay}, 2, 'connection message pacing is at least two seconds';
$scheduler->cancel($same_connection->{token});
my $same_route = $scheduler->reserve(connection => 'irc:A', kind => 'query', route => 'irc:A/#x/Bot');
is $same_route->{delay}, 30, 'query route cooldown is independent and at least thirty seconds';
my $other_network = $scheduler->reserve(connection => 'irc:B', kind => 'message');
is $other_network->{delay}, 0, 'another connection has an independent budget';
my $early = eval { $scheduler->commit($same_route->{token}); 1 };
ok !$early, 'rate reservation cannot be committed before its due time';
$scheduler->cancel($same_route->{token});

my $pause_coordinator = open_coordinator(path => "$tmp/dispatch-pause.jsonl");
my $pause_created = $pause_coordinator->create_job(
    provider => 'searchbot', network_profile => 'PauseNet',
    selection => { basename => 'Paused.epub', offered_basename => 'Paused.epub',
        expected_peer => 'SearchBot', legacy_aliases => [] },
    context => { casemapping => 'rfc1459' }, limits => {});
my $pause_job = $pause_created->{id};
$pause_coordinator->begin_dispatch($pause_job,
    casemapping => 'rfc1459', effective_limits => { offer_timeout_ms => 120000 });
my $paused_held = $pause_coordinator->record_dispatch_result($pause_job,
    'cancelled_before_transport', outcome => 'queue_pause_before_send',
    reason => 'offline fixture withdrew a pending message before transport');
is $paused_held->{state}, 'held',
    'pre-transport queue pause safely restores the job to held';
my $pause_tuple = tuple_key(network_profile => 'PauseNet', peer => 'SearchBot',
    basename => 'Paused.epub', casemapping => 'rfc1459');
is $pause_coordinator->tuple_owner($pause_tuple), $pause_job,
    'held pre-transport job retains its durable stale-offer tuple reservation';
$pause_coordinator->close();
my $recovered_pause = open_coordinator(path => "$tmp/dispatch-pause.jsonl");
is $recovered_pause->job($pause_job)->{state}, 'held',
    'a job restored by a pre-transport pause remains held after journal replay';
is $recovered_pause->tuple_owner($pause_tuple), $pause_job,
    'pre-transport pause tuple reservation survives journal replay';
$recovered_pause->close();

my $job_id = 'job-' . ('b' x 32);
my $synthetic = "[fserve-phase6-test] QUEUED job=$job_id position=3";
my $queued = parse_status($synthetic, peer_matches => 1, connection_matches => 1,
    message_context => 'dcc_chat', job_id => $job_id);
is $queued->{type}, 'queued', 'synthetic fixture queue acknowledgement is correlated';
for my $variant ([ALREADY_QUEUED => 'ALREADY-QUEUED'],
                 [SENDS_FULL => 'SENDS-FULL'],
                 [USER_QUEUE_FULL => 'USER-QUEUE-FULL'],
                 [QUEUE_FULL => 'QUEUE-FULL']) {
    my ($expected_type, $wire) = @$variant;
    is parse_status("[fserve-phase6-test] $wire job=$job_id",
        peer_matches => 1, connection_matches => 1,
        message_context => 'dcc_chat', job_id => $job_id)->{type},
        lc($expected_type), "synthetic $wire status remains distinct and correlated";
}
is parse_status($synthetic, peer_matches => 1, connection_matches => 1,
    message_context => 'dcc_chat', job_id => 'job-' . ('c' x 32))->{type}, 'unknown',
    'same shape for another job cannot authorize a delayed offer';
is parse_status($synthetic, peer_matches => 0, connection_matches => 1,
    message_context => 'dcc_chat', job_id => $job_id)->{type}, 'unknown',
    'foreign peer status is ignored';
is parse_status('Found [1] file - Queues:[0/1]', peer_matches => 1,
    connection_matches => 1, message_context => 'dcc_chat', job_id => $job_id)->{type}, 'unknown',
    'Find queue occupancy is not a selected-file queue acknowledgement';

# SysReset 2.55's real replies to "get", as its script words them.
my %outstanding = (peer_matches => 1, connection_matches => 1,
    message_context => 'dcc_chat', job_id => $job_id, request_outstanding => 1);
for my $case (
    ["\x0304Sorry, all of your queue slots are full.", 'user_queue_full', undef],
    ["\x0304Sorry, all send and queue slots are full.", 'queue_full', undef],
    ["\x0304That file is already sending!", 'already_queued', 'already_sending'],
    ["\x0304Sorry, you already have this file queued in another pool.", 'already_queued', 'other_pool'],
    ["\x0304Sorry, this file is above the maximum sent file size limits.", 'explicit_refusal', 'file_too_large'],
    ["\x0304Invalid file name, please use the form: <\x0314 get filename.ext\x0304 >", 'explicit_refusal', 'invalid_file_name'],
    ["\x0304A Queue Error has occured.  Cannot queue your file at this time.", 'explicit_refusal', 'queue_error'],
    ["\x0fServer Error. Cannot Comply.", 'explicit_refusal', 'server_error'],
) {
    my ($wire, $type, $reason) = @$case;
    my $parsed = parse_status($wire, %outstanding);
    is_deeply [@{$parsed}{qw(type reason correlated dialect job_id)}],
        [$type, $reason, 1, 'sysreset-2.55', $job_id],
        "SysReset reply is recognized: $parsed->{text}";
}
my $real_queued = parse_status(
    "\x0304Adding your file to queue slot\x0314 2\x0304. The file will send when the next send slot is open.",
    %outstanding);
is_deeply [@{$real_queued}{qw(type position dialect)}], ['queued', 2, 'sysreset-2.55'],
    'SysReset queue acknowledgement carries its slot';
is parse_status("\x0304That file has already been queued in slot\x0314 1\x0304!", %outstanding)->{type},
    'already_queued', 'SysReset already-queued reply is recognized';
is parse_status("\x0304Sorry, all of your queue slots are full.",
    %outstanding, request_outstanding => 0)->{type}, 'unknown',
    'a SysReset reply is not attributed to a job with no outstanding request';
is parse_status("\x0304Sorry, all of your queue slots are full.",
    %outstanding, message_context => 'channel')->{type}, 'unknown',
    'a SysReset reply outside the owning CHAT is ignored';
is parse_status("\x0304Sending File.", %outstanding)->{type}, 'unknown',
    'the ordinary send acknowledgement is not a queue status';
is parse_status("Sorry, all of your queue slots are full. Really.", %outstanding)->{type}, 'unknown',
    'text that merely contains a known reply is not recognized';

# FServe.pl 2.0.0's replies to "get", as its queue_file words them (12 and
# 03 are its usual colours).
my $fp_queued = parse_status(
    "\x0312Queued '\x0303artifacts [_oef_].pdf\x0312' (\x0303487.4 kB\x0312) in slot \x0303#3",
    %outstanding);
is_deeply [@{$fp_queued}{qw(type position dialect correlated job_id)}],
    ['queued', 3, 'fservepl-2.0.0', 1, $job_id], 'FServe.pl queue acknowledgement carries its slot';
for my $case (
    ["\x0312You have already queued '\x0303a.pdf\x0312' in slot #\x03032\x0312!", 'already_queued', undef],
    ["\x0312No sends are available and you have used all your queue slots (\x03035\x0312)", 'user_queue_full', undef],
    ["\x0312No send or queue slots are available!", 'queue_full', undef],
    ["\x0312Invalid filename: '\x0303nothing.pdf\x0312'!", 'explicit_refusal', 'invalid_file_name'],
) {
    my ($wire, $type, $reason) = @$case;
    my $parsed = parse_status($wire, %outstanding);
    is_deeply [@{$parsed}{qw(type reason dialect)}], [$type, $reason, 'fservepl-2.0.0'],
        "FServe.pl reply is recognized: $parsed->{text}";
}
is parse_status("\x0312Sending '\x0303a.pdf\x0312'", %outstanding)->{type}, 'unknown',
    'FServe.pl instant-send notice is not a queue status';
is parse_status("\x0312Queued 'a.pdf' (1 kB) in slot #3", %outstanding,
    request_outstanding => 0)->{type}, 'unknown',
    'a FServe.pl reply is not attributed to a job with no outstanding request';

my $staging_root = "$tmp/partial-stage";
mkdir $staging_root or die "create partial staging root: $!";
my $partial_path = "$staging_root/partial.bin";
my $partial_bytes = "prefix\0bytes";
open my $partial_fh, '>:raw', $partial_path or die $!;
print {$partial_fh} $partial_bytes;
close $partial_fh;
my $partial_snapshot = capture_partial(path => $partial_path, staging_root => $staging_root);
is $partial_snapshot->{type}, 'captured_partial',
    'partial ownership snapshot binds the exact regular file to its staging root';
my $seal_session = begin_partial_seal(path => $partial_path, staging_root => $staging_root,
    expected_identity => $partial_snapshot->{identity},
    total_size => length($partial_bytes) + 5);
is $seal_session->{type}, 'sealing',
    'partial digest sealing starts from the captured owned file';
my $seal_step = step_partial_seal($seal_session, 4);
is $seal_step->{type}, 'in_progress', 'large partial hashing yields after its bounded byte step';
is $seal_step->{bytes_hashed}, 4, 'partial sealer observes the requested small processing budget';
$seal_step = step_partial_seal($seal_session, 4);
is $seal_step->{type}, 'in_progress', 'partial hashing remains incremental across steps';
is $seal_step->{bytes_hashed}, 8, 'second sealer step advances by no more than its byte budget';
$seal_step = step_partial_seal($seal_session, 4);
is $seal_step->{type}, 'sealed_partial', 'partial digest is sealed after the final bounded step';
is $seal_step->{size}, length($partial_bytes), 'sealed length matches the captured partial';
is $seal_step->{sha256}, sha256_hex($partial_bytes), 'incremental partial SHA-256 matches exact bytes';
my $cancel_seal = begin_partial_seal(path => $partial_path, staging_root => $staging_root,
    expected_identity => $partial_snapshot->{identity},
    total_size => length($partial_bytes) + 5);
is cancel_partial_seal($cancel_seal)->{type}, 'cancelled',
    'an unfinished partial hash can be cancelled and its handle closed';
is step_partial_seal($cancel_seal, 4)->{type}, 'cancelled',
    'a cancelled partial hash cannot continue';
my $seal_changed_path = "$staging_root/seal-changed.bin";
open my $seal_changed_fh, '>:raw', $seal_changed_path or die $!;
print {$seal_changed_fh} $partial_bytes;
close $seal_changed_fh;
my $seal_changed_snapshot = capture_partial(path => $seal_changed_path,
    staging_root => $staging_root);
my $seal_changed = begin_partial_seal(path => $seal_changed_path,
    staging_root => $staging_root, expected_identity => $seal_changed_snapshot->{identity},
    total_size => length($partial_bytes) + 5);
is step_partial_seal($seal_changed, 4)->{type}, 'in_progress',
    'sealer has an active bounded read before concurrent mutation';
open my $seal_append_fh, '>>:raw', $seal_changed_path or die $!;
print {$seal_append_fh} 'x';
close $seal_append_fh;
my $seal_changed_result;
do {
    $seal_changed_result = step_partial_seal($seal_changed, 4);
} while $seal_changed_result->{type} eq 'in_progress';
is $seal_changed_result->{type}, 'refusal',
    'partial changed while hashing cannot receive a sealed digest';
like $seal_changed_result->{reason}, qr/(?:grew|changed)/,
    'partial mutation during hashing has an explicit refusal reason';
my $partial = validate_partial(path => $partial_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5, partial_size => length($partial_bytes),
    partial_identity => $partial_snapshot->{identity},
    partial_sha256 => sha256_hex($partial_bytes));
is $partial->{type}, 'valid_partial',
    'partial validation rechecks owned file identity, exact length, and digest';
is $partial->{path}, $partial->{snapshot_path},
    'validated path is the private snapshot, not the mutable source';
isnt $partial->{snapshot_path}, $partial_path,
    'validation returns a distinct snapshot path';
is $partial->{source_path}, $partial_path,
    'validated record identifies the original source separately';
is $partial->{staging_root}, $partial_snapshot->{staging_root},
    'validated partial retains the canonical staging root';
is $partial->{sha256}, sha256_hex($partial_bytes),
    'validated partial returns the recomputed SHA-256';
open my $snapshot_read_fh, '<:raw', $partial->{snapshot_path} or die $!;
my $snapshot_read_bytes;
{ local $/; $snapshot_read_bytes = <$snapshot_read_fh>; }
is $snapshot_read_bytes, $partial_bytes,
    'private snapshot contains exactly the bytes covered by its returned digest';
close $snapshot_read_fh or die $!;
is $partial->{identity}{mode} & 0777, 0600,
    'verified snapshot has owner-only mode 0600';
is discard_partial_snapshot($partial)->{type}, 'discarded_snapshot',
    'verified snapshots have an explicit safe cleanup operation';
ok !-e $partial->{snapshot_path},
    'discarding a verified snapshot removes its private path';
my $incremental_validation = begin_partial_validation(
    path => $partial_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5, partial_size => length($partial_bytes),
    partial_identity => $partial_snapshot->{identity},
    partial_sha256 => sha256_hex($partial_bytes));
is $incremental_validation->{type}, 'validating_partial',
    'incremental pre-resume validation opens the exact captured partial';
my ($incremental_result, $incremental_steps);
$incremental_steps = 0;
do {
    my $bytes_before = $incremental_validation->{bytes_hashed};
    $incremental_result = step_partial_validation($incremental_validation, 4);
    $incremental_steps++;
    cmp_ok $incremental_validation->{bytes_hashed} - $bytes_before, '<=', 4,
        "incremental validation step $incremental_steps respects its byte budget";
} while $incremental_result->{type} eq 'in_progress';
is $incremental_result->{type}, 'valid_partial',
    'incremental validation confirms the sealed partial digest';
isnt $incremental_result->{path}, $partial_path,
    'incremental validation returns a snapshot instead of the mutable source';
is $incremental_result->{sha256}, sha256_hex($partial_bytes),
    'incremental validation returns its independently recomputed partial hash';
cmp_ok $incremental_steps, '>', 1,
    'small validation budget yields across multiple event-loop steps';
my $completed_validation_cancel = cancel_partial_validation($incremental_validation);
is $completed_validation_cancel->{type}, 'already_completed',
    'delayed cancellation reports that validation already completed';
ok $completed_validation_cancel->{snapshot_preserved},
    'completed-session cancellation explicitly preserves result ownership';
ok -e $incremental_result->{snapshot_path},
    'delayed cancellation leaves the consumer snapshot present';
open my $completed_snapshot_fh, '<:raw', $incremental_result->{snapshot_path} or die $!;
my $completed_snapshot_bytes;
{ local $/; $completed_snapshot_bytes = <$completed_snapshot_fh>; }
is $completed_snapshot_bytes, $partial_bytes,
    'delayed cancellation leaves the snapshot byte-identical to sealed content';
close $completed_snapshot_fh or die $!;
is discard_partial_snapshot($incremental_result)->{type}, 'discarded_snapshot',
    'consumer can explicitly discard the transferred snapshot';
ok !-e $incremental_result->{snapshot_path},
    'explicit discard removes the transferred snapshot';
my $large_validation_bytes = 'v' x (2 * 64 * 1024 + 17);
my $large_validation_path = "$staging_root/incremental-large.bin";
open my $large_validation_fh, '>:raw', $large_validation_path or die $!;
print {$large_validation_fh} $large_validation_bytes;
close $large_validation_fh;
my $large_validation_snapshot = capture_partial(
    path => $large_validation_path, staging_root => $staging_root);
my $large_validation = begin_partial_validation(
    path => $large_validation_path, staging_root => $staging_root,
    total_size => length($large_validation_bytes) + 5,
    partial_identity => $large_validation_snapshot->{identity},
    partial_sha256 => sha256_hex($large_validation_bytes));
my $large_validation_step = step_partial_validation($large_validation, 1024 * 1024);
is $large_validation_step->{type}, 'in_progress',
    'large partial validation yields instead of hashing the whole file at once';
is $large_validation_step->{bytes_hashed}, 64 * 1024,
    'large validation enforces the 64-KiB per-step ceiling';
$large_validation_step = step_partial_validation($large_validation, 1024 * 1024);
is $large_validation_step->{bytes_hashed}, 2 * 64 * 1024,
    'large validation advances by at most another 64 KiB on the next step';
do {
    $large_validation_step = step_partial_validation($large_validation, 1024 * 1024);
} while $large_validation_step->{type} eq 'in_progress';
is $large_validation_step->{type}, 'valid_partial',
    'large partial digest completes through bounded validation steps';
my $incremental_cancel = begin_partial_validation(
    path => $partial_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5,
    partial_identity => $partial_snapshot->{identity},
    partial_sha256 => sha256_hex($partial_bytes));
is step_partial_validation($incremental_cancel, 4)->{type}, 'in_progress',
    'cancellation fixture first writes a bounded snapshot prefix';
my $cancelled_snapshot_path = $incremental_cancel->{snapshot_path};
is cancel_partial_validation($incremental_cancel)->{type}, 'cancelled',
    'incremental partial validation can be cancelled';
ok !$incremental_cancel->{fh},
    'cancelling incremental validation closes its file handle';
ok !$incremental_cancel->{snapshot_fh},
    'cancelling incremental validation closes the snapshot handle';
ok !-e $cancelled_snapshot_path,
    'cancellation removes the incomplete private snapshot';
my $incremental_after_cancel = step_partial_validation($incremental_cancel, 4);
is $incremental_after_cancel->{type}, 'cancelled',
    'cancelled validation cannot continue reading';
my $incremental_mismatch = begin_partial_validation(
    path => $partial_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5,
    partial_identity => $partial_snapshot->{identity},
    partial_sha256 => 'f' x 64);
my $mismatch_snapshot_path = $incremental_mismatch->{snapshot_path};
my $incremental_mismatch_result;
do {
    $incremental_mismatch_result = step_partial_validation($incremental_mismatch, 4);
} while $incremental_mismatch_result->{type} eq 'in_progress';
is $incremental_mismatch_result->{type}, 'refusal',
    'incremental validation refuses a mismatched sealed digest';
like $incremental_mismatch_result->{reason}, qr/partial digest changed/,
    'incremental digest refusal identifies the mismatch';
ok !-e $mismatch_snapshot_path,
    'digest refusal removes the incomplete private snapshot';
my $incremental_changed_path = "$staging_root/incremental-changed.bin";
open my $incremental_changed_fh, '>:raw', $incremental_changed_path or die $!;
print {$incremental_changed_fh} $partial_bytes;
close $incremental_changed_fh;
my $incremental_changed_snapshot = capture_partial(
    path => $incremental_changed_path, staging_root => $staging_root);
my $incremental_changed = begin_partial_validation(
    path => $incremental_changed_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5,
    partial_identity => $incremental_changed_snapshot->{identity},
    partial_sha256 => sha256_hex($partial_bytes));
is step_partial_validation($incremental_changed, 4)->{type}, 'in_progress',
    'incremental validation has an active bounded read before mutation';
open my $incremental_mutate_fh, '+<:raw', $incremental_changed_path or die $!;
seek($incremental_mutate_fh, -1, 2) or die $!;
my $incremental_changed_final_byte = chr(
    (ord(substr($partial_bytes, -1, 1)) + 1) % 256);
print {$incremental_mutate_fh} $incremental_changed_final_byte or die $!;
close $incremental_mutate_fh;
my $incremental_changed_result;
do {
    $incremental_changed_result = step_partial_validation($incremental_changed, 4);
} while $incremental_changed_result->{type} eq 'in_progress';
is $incremental_changed_result->{type}, 'refusal',
    'same-length content mutation during incremental validation is refused';
like $incremental_changed_result->{reason}, qr/(?:digest|changed)/,
    'concurrent mutation refusal explains changed contents or identity';
my $already_hashed_path = "$staging_root/already-hashed-mutation.bin";
my $already_hashed_bytes = 'abcd' x 32;
open my $already_hashed_fh, '>:raw', $already_hashed_path or die $!;
print {$already_hashed_fh} $already_hashed_bytes;
close $already_hashed_fh;
my $already_hashed_snapshot = capture_partial(
    path => $already_hashed_path, staging_root => $staging_root);
my $already_hashed_validation = begin_partial_validation(
    path => $already_hashed_path, staging_root => $staging_root,
    total_size => length($already_hashed_bytes) + 5,
    partial_identity => $already_hashed_snapshot->{identity},
    partial_sha256 => sha256_hex($already_hashed_bytes));
is step_partial_validation($already_hashed_validation, 4)->{type}, 'in_progress',
    'validation copies an initial prefix before the concurrent prefix mutation';
my $already_hashed_snapshot_path = $already_hashed_validation->{snapshot_path};
open my $already_hashed_mutate_fh, '+<:raw', $already_hashed_path or die $!;
seek($already_hashed_mutate_fh, 0, 0) or die $!;
print {$already_hashed_mutate_fh} 'z' or die $!;
close $already_hashed_mutate_fh;
my $already_hashed_result;
{
    no warnings 'redefine';
    local *Time::HiRes::stat = sub {
        my @stat = CORE::stat($_[0]);
        if (@stat) {
            # Model a filesystem that exposes no timestamp change for this
            # same-length write, including through the open source handle.
            $stat[9] = $already_hashed_validation->{identity}{mtime};
            $stat[10] = $already_hashed_validation->{identity}{ctime};
        }
        return @stat;
    };
    do {
        $already_hashed_result = step_partial_validation($already_hashed_validation, 64);
    } while $already_hashed_result->{type} eq 'in_progress';
}
is $already_hashed_result->{type}, 'valid_partial',
    'coarse unchanged timestamps do not prevent snapshot validation';
isnt $already_hashed_result->{snapshot_path}, $already_hashed_path,
    'coarse-timestamp validation never returns the mutable source path';
is $already_hashed_result->{sha256}, sha256_hex($already_hashed_bytes),
    'coarse-timestamp snapshot digest remains the sealed SHA-256';
open my $already_hashed_snapshot_fh, '<:raw', $already_hashed_result->{snapshot_path}
    or die $!;
my $already_hashed_snapshot_bytes;
{ local $/; $already_hashed_snapshot_bytes = <$already_hashed_snapshot_fh>; }
is $already_hashed_snapshot_bytes, $already_hashed_bytes,
    'snapshot preserves exact sealed bytes despite mutation of the copied source prefix';
close $already_hashed_snapshot_fh or die $!;
ok -e $already_hashed_path && -e $already_hashed_snapshot_path,
    'successful validation retains both original source and verified snapshot';

my $ancestry_parent = "$staging_root/mutable-parent";
mkdir $ancestry_parent or die "create mutable partial parent: $!";
my $ancestry_path = "$ancestry_parent/partial.bin";
my $ancestry_bytes = 'parent-chain-check';
open my $ancestry_fh, '>:raw', $ancestry_path or die $!;
print {$ancestry_fh} $ancestry_bytes;
close $ancestry_fh;
my $ancestry_snapshot = capture_partial(
    path => $ancestry_path, staging_root => $staging_root);
my $ancestry_validation = begin_partial_validation(
    path => $ancestry_path, staging_root => $staging_root,
    total_size => length($ancestry_bytes) + 5,
    partial_identity => $ancestry_snapshot->{identity},
    partial_sha256 => sha256_hex($ancestry_bytes));
is step_partial_validation($ancestry_validation, 4)->{type}, 'in_progress',
    'validation starts before its parent directory is replaced';
my $ancestry_snapshot_path = $ancestry_validation->{snapshot_path};
my $moved_parent = "$tmp/moved-partial-parent";
rename $ancestry_parent, $moved_parent or die "move partial parent outside staging: $!";
symlink($moved_parent, $ancestry_parent) or die "replace partial parent with symlink: $!";
my $ancestry_result;
do {
    $ancestry_result = step_partial_validation($ancestry_validation, 64);
} while $ancestry_result->{type} eq 'in_progress';
is $ancestry_result->{type}, 'refusal',
    'partial validation refuses when a parent becomes a symlink outside staging';
like $ancestry_result->{reason}, qr/(?:path|directory|staging)/,
    'parent replacement refusal identifies the changed owned path';
ok !-e $ancestry_snapshot_path,
    'ancestry refusal removes the incomplete private snapshot under the stable owned root';
unlink $ancestry_parent or die "remove test parent symlink: $!";
rename $moved_parent, $ancestry_parent or die "restore partial parent: $!";

my $cancel_cleanup_path = "$staging_root/cancel-cleanup.bin";
my $cleanup_bytes = 'retry-cleanup-check';
open my $cancel_cleanup_fh, '>:raw', $cancel_cleanup_path or die $!;
print {$cancel_cleanup_fh} $cleanup_bytes;
close $cancel_cleanup_fh;
my $cancel_cleanup_identity = capture_partial(
    path => $cancel_cleanup_path, staging_root => $staging_root);
my $cancel_cleanup_session = begin_partial_validation(
    path => $cancel_cleanup_path, staging_root => $staging_root,
    total_size => length($cleanup_bytes) + 5,
    partial_identity => $cancel_cleanup_identity->{identity},
    partial_sha256 => sha256_hex($cleanup_bytes));
is step_partial_validation($cancel_cleanup_session, 4)->{type}, 'in_progress',
    'cleanup retry validation creates its private snapshot before root movement';
my $cancel_cleanup_snapshot = $cancel_cleanup_session->{snapshot_path};
my $cancel_moved_root = "$tmp/partial-stage-cancel-moved";
rename $staging_root, $cancel_moved_root or die "move staging root before cancellation: $!";
my $cancel_cleanup_first = cancel_partial_validation($cancel_cleanup_session);
is $cancel_cleanup_first->{type}, 'cancelled',
    'first cancellation records a terminal outcome when the staging root is unavailable';
is $cancel_cleanup_first->{snapshot_removed}, 0,
    'failed first cancellation reports that the snapshot was not removed';
like $cancel_cleanup_first->{reason}, qr/could not be safely removed/,
    'failed first cancellation preserves its cleanup failure reason';
rename $cancel_moved_root, $staging_root or die "restore staging root after cancellation: $!";
my $cancel_cleanup_retry = cancel_partial_validation($cancel_cleanup_session);
is $cancel_cleanup_retry->{type}, 'already_cancelled',
    'repeated cancellation retains its terminal state while retrying cleanup';
is $cancel_cleanup_retry->{cleanup_retried}, 1,
    'repeated cancellation identifies the ownership-checked cleanup retry';
is $cancel_cleanup_retry->{snapshot_removed}, 1,
    'repeated cancellation reports removal only after the owned snapshot is deleted';
ok !-e $cancel_cleanup_snapshot,
    'cancellation retry removes the same snapshot after staging-root restoration';

my $refusal_cleanup_path = "$staging_root/refusal-cleanup.bin";
open my $refusal_cleanup_fh, '>:raw', $refusal_cleanup_path or die $!;
print {$refusal_cleanup_fh} $cleanup_bytes;
close $refusal_cleanup_fh;
my $refusal_cleanup_identity = capture_partial(
    path => $refusal_cleanup_path, staging_root => $staging_root);
my $refusal_cleanup_session = begin_partial_validation(
    path => $refusal_cleanup_path, staging_root => $staging_root,
    total_size => length($cleanup_bytes) + 5,
    partial_identity => $refusal_cleanup_identity->{identity},
    partial_sha256 => sha256_hex($cleanup_bytes));
is step_partial_validation($refusal_cleanup_session, 4)->{type}, 'in_progress',
    'refusal retry validation starts with an owned source and snapshot';
my $refusal_cleanup_snapshot = $refusal_cleanup_session->{snapshot_path};
my $refusal_moved_root = "$tmp/partial-stage-refusal-moved";
rename $staging_root, $refusal_moved_root or die "move staging root during validation: $!";
my $refusal_cleanup_result;
do {
    $refusal_cleanup_result = step_partial_validation($refusal_cleanup_session, 64);
} while $refusal_cleanup_result->{type} eq 'in_progress';
is $refusal_cleanup_result->{type}, 'refusal',
    'validation refuses when the staging root moves during hashing';
is $refusal_cleanup_result->{snapshot_removed}, 0,
    'refusal reports incomplete snapshot cleanup when its root is unavailable';
rename $refusal_moved_root, $staging_root or die "restore staging root after refusal: $!";
my $refusal_cleanup_retry = cancel_partial_validation($refusal_cleanup_session);
is $refusal_cleanup_retry->{type}, 'already_refused',
    'repeated cancel preserves the original refusal state';
is $refusal_cleanup_retry->{cleanup_retried}, 1,
    'repeated cancel retries cleanup for a refused session';
is $refusal_cleanup_retry->{snapshot_removed}, 1,
    'refused-session cleanup reports success only after safe removal';
like $refusal_cleanup_retry->{reason}, qr/partial path or a staging directory changed/,
    'refused-session retry retains the original refusal reason';
ok !-e $refusal_cleanup_snapshot,
    'refused-session cleanup retry removes only its captured snapshot';

is validate_partial(path => $partial_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5, partial_size => length($partial_bytes),
    partial_identity => $partial_snapshot->{identity},
    partial_sha256 => 'f' x 64)->{type}, 'refusal',
    'partial with a mismatched saved digest is refused';
my $outside_path = "$tmp/outside-partial.bin";
open my $outside_fh, '>:raw', $outside_path or die $!;
print {$outside_fh} $partial_bytes;
close $outside_fh;
is capture_partial(path => $outside_path, staging_root => $staging_root)->{type}, 'refusal',
    'partial outside the captured staging root is refused';
my $linked_path = "$staging_root/linked.bin";
symlink($partial_path, $linked_path) or die "create partial symlink: $!";
is capture_partial(path => $linked_path, staging_root => $staging_root)->{type}, 'refusal',
    'symbolic-link partial is refused even when its target is inside staging';
unlink $linked_path or die "remove test partial symlink: $!";
my $hardlink_path = "$staging_root/hardlinked.bin";
my $hardlink_source = "$staging_root/hardlink-source.bin";
open my $hardlink_source_fh, '>:raw', $hardlink_source or die $!;
print {$hardlink_source_fh} $partial_bytes;
close $hardlink_source_fh;
link($hardlink_source, $hardlink_path) or die "create partial hard link: $!";
is capture_partial(path => $hardlink_path, staging_root => $staging_root)->{type}, 'refusal',
    'multiply linked partial file is refused';
unlink $hardlink_path or die "remove test partial hard link: $!";
my $changed_path = "$staging_root/changed.bin";
open my $changed_fh, '>:raw', $changed_path or die $!;
print {$changed_fh} $partial_bytes;
close $changed_fh;
my $changed_snapshot = capture_partial(path => $changed_path, staging_root => $staging_root);
open my $append_fh, '>>:raw', $changed_path or die $!;
print {$append_fh} 'x';
close $append_fh;
is validate_partial(path => $changed_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5, partial_size => length($partial_bytes),
    partial_identity => $changed_snapshot->{identity},
    partial_sha256 => sha256_hex($partial_bytes))->{type}, 'refusal',
    'partial changed after capture is refused before resume';
my $resume = resume_decision(path => $partial_path, total_size => length($partial_bytes) + 5,
    staging_root => $staging_root, partial_size => length($partial_bytes),
    partial_identity => $partial_snapshot->{identity},
    partial_sha256 => sha256_hex($partial_bytes),
    expected_sha256 => 'a' x 64, same_process => 1, same_connection => 1,
    same_epoch => 1, correlated_continuation => 1,
    profile => capability_profile());
is $resume->{type}, 'refusal', 'unsupported native profile fails closed even with a partial digest';
like $resume->{reason}, qr/native RESUME/, 'unsupported profile explains the native capability gap';

# A test-only profile exercises decision gates that the real capability profile
# deliberately short-circuits. This does not enable native resume in production.
my $hypothetical_resume_profile = { supported => 1, name => 'test-only-policy-probe' };
my %resume_candidate = (
    path => $partial_path, staging_root => $staging_root,
    total_size => length($partial_bytes) + 5,
    partial_size => length($partial_bytes),
    partial_identity => $partial_snapshot->{identity},
    partial_sha256 => sha256_hex($partial_bytes),
    expected_sha256 => 'A' x 64,
    same_process => 1, same_connection => 1, same_epoch => 1,
    correlated_continuation => 1,
);
my $policy_resume = resume_decision(%resume_candidate,
    profile => $hypothetical_resume_profile);
is $policy_resume->{type}, 'resume_allowed',
    'test-only capability profile reaches the downstream resume policy';
is $policy_resume->{offset}, length($partial_bytes),
    'resume offset is derived from the sealed partial byte length';
is $policy_resume->{expected_sha256}, 'a' x 64,
    'trusted whole-file digest is normalized before the later finalization check';
for my $gate (
    [same_process => 0, qr/prior process or IRC connection/, 'prior process'],
    [same_connection => 0, qr/prior process or IRC connection/, 'connection'],
    [same_epoch => 0, qr/prior process or IRC connection/, 'connection epoch'],
    [correlated_continuation => 0, qr/not been correlated/, 'continuation correlation'],
    [expected_sha256 => undef, qr/trusted full-file SHA-256/, 'missing trusted digest'],
    [expected_sha256 => 'not-a-digest', qr/trusted full-file SHA-256/, 'malformed trusted digest'],
    [tuple_ambiguous => 1, qr/ambiguous DCC tuple/, 'ambiguous DCC tuple'],
) {
    my ($field, $value, $reason, $label) = @$gate;
    my %candidate = (%resume_candidate, $field => $value);
    my $decision = resume_decision(%candidate,
        profile => $hypothetical_resume_profile);
    is $decision->{type}, 'refusal', "resume policy refuses $label";
    like $decision->{reason}, $reason, "resume refusal explains $label";
}
my %changed_resume_candidate = (%resume_candidate,
    path => $changed_path,
    partial_size => length($partial_bytes),
    partial_identity => $changed_snapshot->{identity});
my $changed_resume_decision = resume_decision(%changed_resume_candidate,
    profile => $hypothetical_resume_profile);
is $changed_resume_decision->{type}, 'refusal',
    'resume policy refuses a partial changed after its ownership snapshot';

my $partial_coordinator = open_coordinator(path => "$tmp/partial-coordinator.jsonl");
my $partial_job = $partial_coordinator->create_job(provider => 'find',
    network_profile => 'PartialNet',
    selection => { remote_path => '/Books/Partial.epub', name => 'Partial.epub',
        expected_peer => 'PartialBot', basename => 'Partial.epub' },
    context => { channel => '#partial' }, limits => {});
$partial_coordinator->begin_dispatch($partial_job->{id}, casemapping => 'rfc1459');
$partial_coordinator->record_dispatch_result($partial_job->{id}, 'sent');
$partial_coordinator->accept_offer($partial_job->{id},
    accepted_lifecycle => 'partial-lifecycle', offered_basename => 'Partial.epub');
my $interrupted = $partial_coordinator->mark_interrupted($partial_job->{id},
    path => $partial_path, staging_root => $staging_root,
    receive_path => $partial_path,
    receive_identity => { device => $partial_snapshot->{identity}{device},
        inode => $partial_snapshot->{identity}{inode} },
    size => length($partial_bytes), total_size => length($partial_bytes) + 5,
    offered_basename => 'Partial.epub', writer_closed => 1);
is $interrupted->{partial}{ownership_status}, 'captured',
    'interrupted job persists the staging-root and filesystem ownership snapshot';
is $interrupted->{partial}{file_identity}{size}, length($partial_bytes),
    'interrupted job records the observed partial-file length';
is $interrupted->{partial}{digest_status}, 'not-sealed',
    'ownership capture does not claim an uncomputed partial digest';
ok $interrupted->{partial}{writer_closed},
    'explicit writer-close evidence is durably retained';
ok $interrupted->{partial}{captured_at} && !$interrupted->{partial}{sealed_at},
    'partial ownership timestamp does not claim a digest seal';
my $coordinator_seal = begin_partial_seal(path => $interrupted->{partial}{path},
    staging_root => $interrupted->{partial}{staging_root},
    expected_identity => $interrupted->{partial}{file_identity},
    total_size => $interrupted->{partial}{total_size});
my $coordinator_seal_result;
while ($coordinator_seal->{type} eq 'sealing') {
    $coordinator_seal_result = step_partial_seal($coordinator_seal, 4);
    last unless $coordinator_seal_result->{type} eq 'in_progress';
}
is $coordinator_seal_result->{type}, 'sealed_partial',
    'coordinator receives a complete digest only after incremental file verification';
my $sealed_job = $partial_coordinator->seal_interrupted_partial($partial_job->{id},
    %$coordinator_seal_result);
is $sealed_job->{state}, 'interrupted', 'sealing preserves the interrupted job state';
is $sealed_job->{partial}{digest_status}, 'sealed',
    'coordinator persists the sealed digest status';
is $sealed_job->{partial}{partial_sha256}, sha256_hex($partial_bytes),
    'coordinator persists the exact partial SHA-256';

my $resume_coordinator = open_coordinator(path => "$tmp/resume-intent.jsonl");
my $resume_full_digest = sha256_hex($partial_bytes . 'whole-file-suffix');
my $resume_job = $resume_coordinator->create_job(
    provider => 'find', network_profile => 'ResumeNet',
    selection => { remote_path => '/Books/Resume.epub', name => 'Resume.epub',
        basename => 'Resume.epub', offered_basename => 'Resume.epub',
        expected_peer => 'ResumeBot' },
    context => { channel => '#resume', server_tag => 'ResumeNetTag',
        process_incarnation => 'offline-process-1',
        connection_identity => 'offline-connection-1', connection_epoch => 7,
        casemapping => 'rfc1459' },
    limits => {},
    trusted_content_digest => { sha256 => $resume_full_digest,
        provenance => { kind => 'test_fixture', asserted_by => 'offline-test',
            asserted_at => 1791100109 } });
$resume_coordinator->begin_dispatch($resume_job->{id}, casemapping => 'rfc1459');
$resume_coordinator->record_dispatch_result($resume_job->{id}, 'sent');
$resume_coordinator->accept_offer($resume_job->{id},
    accepted_lifecycle => 'initial-resume-test-lifecycle',
    offered_basename => 'Resume.epub');
my $resume_interrupted = $resume_coordinator->mark_interrupted($resume_job->{id},
    path => $partial_path, staging_root => $staging_root,
    receive_path => $partial_path,
    receive_identity => { device => $partial_snapshot->{identity}{device},
        inode => $partial_snapshot->{identity}{inode} },
    size => length($partial_bytes), total_size => length($partial_bytes) + 5,
    offered_basename => 'Resume.epub', writer_closed => 1);
my $resume_seal_session = begin_partial_seal(
    path => $resume_interrupted->{partial}{path},
    staging_root => $resume_interrupted->{partial}{staging_root},
    expected_identity => $resume_interrupted->{partial}{file_identity},
    total_size => $resume_interrupted->{partial}{total_size});
my $resume_seal_result;
while ($resume_seal_session->{type} eq 'sealing') {
    $resume_seal_result = step_partial_seal($resume_seal_session, 64);
    last unless $resume_seal_result->{type} eq 'in_progress';
}
is $resume_seal_result->{type}, 'sealed_partial',
    'resume gate fixture seals its generated partial offline';
my $resume_sealed_job = $resume_coordinator->seal_interrupted_partial(
    $resume_job->{id}, %$resume_seal_result);
my $resume_validation = begin_partial_validation(
    path => $resume_sealed_job->{partial}{path},
    staging_root => $resume_sealed_job->{partial}{staging_root},
    total_size => $resume_sealed_job->{partial}{total_size},
    partial_size => $resume_sealed_job->{partial}{size},
    partial_identity => $resume_sealed_job->{partial}{file_identity},
    partial_sha256 => $resume_sealed_job->{partial}{partial_sha256});
my $resume_validation_result;
while ($resume_validation->{type} eq 'validating_partial') {
    $resume_validation_result = step_partial_validation($resume_validation, 64);
    last unless $resume_validation_result->{type} eq 'in_progress';
}
is $resume_validation_result->{type}, 'valid_partial',
    'resume gate receives the completed incremental private-snapshot result';
my $unchecked_resume_transition = eval {
    $resume_coordinator->transition($resume_job->{id}, 'resume_pending');
    1;
};
ok !$unchecked_resume_transition,
    'generic coordinator transitions cannot enter resume_pending without checked admission';
like $@, qr/checked durable resume-admission path/,
    'unchecked resume-transition refusal identifies the required gate';
my $state_smuggle = eval {
    $resume_coordinator->transition($resume_job->{id}, 'needs_attention',
        data => { state => 'resume_pending' });
    1;
};
ok !$state_smuggle,
    'transition metadata cannot smuggle resume_pending around checked admission';
like $@, qr/transition data cannot override lifecycle field state/,
    'state-smuggling refusal identifies the protected lifecycle field';
is $resume_coordinator->job($resume_job->{id})->{state}, 'interrupted',
    'rejected state-smuggling leaves the interrupted job unchanged';
my $resume_offer = {
    offer_kind => 'incoming-file-send',
    connection_identity => 'offline-connection-1', connection_epoch => 7,
    server_tag => 'ResumeNetTag', sender => 'ResumeBot',
    offered_basename => 'Resume.epub',
    total_size => length($partial_bytes) + 5,
    native_lifecycle_identity => 'fresh-offer-lifecycle-2',
};
my $unsupported_resume_intent = eval {
    $resume_coordinator->begin_resume_intent($resume_job->{id},
        profile => capability_profile(), process_incarnation => 'offline-process-1',
        connection_identity => 'offline-connection-1', connection_epoch => 7,
        offer => $resume_offer, validated_partial => $resume_validation_result);
    1;
};
ok !$unsupported_resume_intent,
    'durable resume admission remains closed under the production capability profile';
like $@, qr/production native resume capability is unsupported/,
    'unsupported-profile refusal is explicit';
my $spoofed_supported_profile = eval {
    $resume_coordinator->begin_resume_intent($resume_job->{id},
        profile => { supported => 1, name => 'unreviewed-production-profile' },
        process_incarnation => 'offline-process-1',
        connection_identity => 'offline-connection-1', connection_epoch => 7,
        offer => $resume_offer, validated_partial => $resume_validation_result);
    1;
};
ok !$spoofed_supported_profile,
    'arbitrary supported-profile labels cannot enable coordinator resume admission';
like $@, qr/only test-only profiles may exercise admission/,
    'coordinator refuses any purported production profile while native support is disabled';
my $resume_test_profile = { supported => 1, name => 'test-only-resume-intent' };
my %spoofed_snapshot = %$resume_validation_result;
$spoofed_snapshot{identity} = { %{$resume_validation_result->{identity}},
    inode => $resume_validation_result->{identity}{inode} + 1 };
my $spoofed_snapshot_admission = eval {
    $resume_coordinator->begin_resume_intent($resume_job->{id},
        profile => $resume_test_profile, process_incarnation => 'offline-process-1',
        connection_identity => 'offline-connection-1', connection_epoch => 7,
        offer => $resume_offer, validated_partial => \%spoofed_snapshot);
    1;
};
ok !$spoofed_snapshot_admission,
    'resume admission rejects snapshot evidence that does not match the live file identity';
like $@, qr/snapshot ownership changed/,
    'snapshot substitution refusal reports the failed ownership check';
for my $case (
    [wrong_process => { process_incarnation => 'other-process' }, qr/process_incarnation/],
    [wrong_connection => { connection_identity => 'other-connection' }, qr/connection/],
    [wrong_epoch => { connection_epoch => 8 }, qr/connection_epoch/],
    [wrong_sender => { offer => { %$resume_offer, sender => 'OtherBot' } }, qr/reserved DCC identity/],
    [wrong_name => { offer => { %$resume_offer, offered_basename => 'Other.epub' } }, qr/basename/],
    [wrong_size => { offer => { %$resume_offer, total_size => 999 } }, qr/size/],
) {
    my ($label, $overrides, $expected_error) = @$case;
    my %candidate = (process_incarnation => 'offline-process-1',
        connection_identity => 'offline-connection-1', connection_epoch => 7,
        offer => $resume_offer, validated_partial => $resume_validation_result,
        profile => $resume_test_profile, %$overrides);
    my $admitted = eval {
        $resume_coordinator->begin_resume_intent($resume_job->{id}, %candidate);
        1;
    };
    ok !$admitted, "resume admission refuses $label evidence";
    like $@, $expected_error, "resume $label refusal names the mismatched evidence";
    is $resume_coordinator->job($resume_job->{id})->{state}, 'interrupted',
        "resume $label refusal leaves the durable job interrupted";
}
my $resume_intent_job = $resume_coordinator->begin_resume_intent($resume_job->{id},
    profile => $resume_test_profile, process_incarnation => 'offline-process-1',
    connection_identity => 'offline-connection-1', connection_epoch => 7,
    offer => $resume_offer, validated_partial => $resume_validation_result);
is $resume_intent_job->{state}, 'resume_pending',
    'coordinator persists an admitted resume intent before any native resume action';
is $resume_intent_job->{resume_intent}{offset}, length($partial_bytes),
    'durable resume offset is derived from the validated partial length';
is $resume_intent_job->{resume_intent}{expected_sha256}, $resume_full_digest,
    'durable resume intent binds the immutable pre-dispatch whole-file digest';
is $resume_intent_job->{resume_intent}{snapshot_path},
    $resume_validation_result->{snapshot_path},
    'durable intent points the future native receive at the validated private snapshot';
ok $resume_coordinator->compact_journal(),
    'legitimate resume_pending state can be compacted with its checked admission evidence';
my $mutate_resume_intent = eval {
    $resume_coordinator->transition($resume_job->{id}, 'receiving',
        data => { resume_intent => { %{$resume_intent_job->{resume_intent}},
            offset => 1 } });
    1;
};
ok !$mutate_resume_intent, 'a persisted resume attempt cannot be replaced or retargeted';
like $@, qr/immutable once recorded/,
    'resume-attempt mutation refusal identifies the immutable intent';
$resume_coordinator->close();

my $verified_handoff_coordinator = open_coordinator(
    path => "$tmp/verified-resume-handoff.jsonl");
my ($verified_handoff_id) = $prepare_resume_pending_job->(
    $verified_handoff_coordinator, 'VerifiedHandoffNet',
    'VerifiedHandoff.epub', 'VerifiedBot');
my $verified_handoff_job = $verified_handoff_coordinator->job($verified_handoff_id);
my $verified_handoff_receiving = $verified_handoff_coordinator->transition(
    $verified_handoff_id, 'receiving', outcome => 'test_only_native_accept_fixture');
is $verified_handoff_receiving->{state}, 'receiving',
    'offline fixture places the admitted resume job in its simulated receive state';
my $verified_handoff_bypass = eval {
    $verified_handoff_coordinator->reserve_finalization($verified_handoff_id,
        staging_path => $verified_handoff_job->{resume_intent}{snapshot_path},
        destination_path => "$tmp/verified-resume-bypass.bin",
        expected_size => $verified_handoff_job->{resume_intent}{total_size},
        expected_sha256 => $verified_handoff_job->{resume_intent}{expected_sha256});
    1;
};
ok !$verified_handoff_bypass,
    'generic finalization cannot bypass completed-resume-file verification';
like $@, qr/checked whole-file verification handoff/,
    'resume finalization bypass refusal identifies the required checked handoff';
my $verified_handoff_staging = $verified_handoff_job->{resume_intent}{snapshot_path};
open my $verified_handoff_append_fh, '>>:raw', $verified_handoff_staging
    or die "append completed resume fixture: $!";
print {$verified_handoff_append_fh} '-complete'
    or die "write completed resume fixture suffix: $!";
close $verified_handoff_append_fh
    or die "close completed resume fixture suffix: $!";
my $verified_handoff_session = begin_resumed_file_verification(
    path => $verified_handoff_staging,
    staging_root => $verified_handoff_job->{resume_intent}{staging_root},
    resume_intent => $verified_handoff_job->{resume_intent},
    expected_sha256 => $verified_handoff_job->{resume_intent}{expected_sha256},
    writer_closed => 1);
my $verified_handoff_result;
while ($verified_handoff_session->{state} eq 'verifying') {
    $verified_handoff_result = step_resumed_file_verification(
        $verified_handoff_session, 5);
    last unless $verified_handoff_result->{type} eq 'in_progress';
}
is $verified_handoff_result->{type}, 'verified_resumed_file',
    'offline coordinator fixture obtains an exact whole-file verifier receipt';
$verified_handoff_result->{path} = "$tmp/forged-resume-path.bin";
$verified_handoff_result->{attempt_id} = 'resume-' . ('0' x 32);
$verified_handoff_result->{sha256} = 'f' x 64;
my $verified_handoff_finalizing =
    $verified_handoff_coordinator->reserve_verified_resume_finalization(
        $verified_handoff_id, verification => $verified_handoff_result,
        destination_path => "$tmp/verified-resume-output.bin");
is $verified_handoff_finalizing->{state}, 'finalizing',
    'coordinator reserves finalization only after consuming the verified-file receipt';
is $verified_handoff_finalizing->{finalization}{expected_size},
    $verified_handoff_job->{resume_intent}{total_size},
    'resume finalization size is bound to the durable advertised total';
is $verified_handoff_finalizing->{finalization}{expected_sha256},
    $verified_handoff_job->{resume_intent}{expected_sha256},
    'resume finalization digest is bound to the immutable trusted digest';
is $verified_handoff_finalizing->{finalization}{staging_path},
    $verified_handoff_staging,
    'caller edits to the visible result cannot retarget the authoritative receipt';
is $verified_handoff_finalizing->{finalization}{resume_verification}{attempt_id},
    $verified_handoff_job->{resume_intent}{attempt_id},
    'journaled finalization retains the one-shot verified resume attempt evidence';
my $payload_sync_calls = 0;
my $real_payload_sync = \&FServe::Transfer::Coordinator::_sync_payload_handle;
my $verified_handoff_publication;
{
    no warnings 'redefine';
    local *FServe::Transfer::Coordinator::_sync_payload_handle = sub {
        $payload_sync_calls++;
        return $real_payload_sync->(@_);
    };
    $verified_handoff_publication =
        $verified_handoff_coordinator->publish_verified_resume_finalization(
            $verified_handoff_id);
}
is $verified_handoff_publication->{type}, 'published_verified_resume',
    'verified publisher rehashes, syncs, and publishes the resumed payload';
is $payload_sync_calls, 2,
    'successful publication syncs the payload before and after the post-sync digest check';
is $verified_handoff_publication->{job}{state}, 'complete',
    'verified publication reaches complete only after successful file and directory sync';
is $verified_handoff_publication->{job}{finalization}{result}{publication_evidence}{method},
    'exclusive_hard_link', 'completion persists the exact publication method';
ok $verified_handoff_publication->{job}{finalization}{result}{publication_evidence}{payload_synced},
    'completion persists payload-sync evidence';
ok $verified_handoff_publication->{job}{finalization}{result}{publication_evidence}{directory_synced},
    'completion persists destination-directory-sync evidence';
ok $verified_handoff_publication->{staging_removed},
    'staging name is removed only after durable publication completion';
ok -f "$tmp/verified-resume-output.bin",
    'successful publication creates the reserved destination';
ok $verified_handoff_coordinator->compact_journal(),
    'verified publication evidence survives offline compaction';
my $verified_resume_journal_copy = "$tmp/verified-resume-valid-copy.jsonl";
copy("$tmp/verified-resume-handoff.jsonl", $verified_resume_journal_copy)
    or die "copy valid completed journal before forged compaction: $!";
my $forged_compaction_transition = JSON::PP->new->decode(
    JSON::PP->new->canonical(1)->encode($verified_handoff_publication->{job}));
$forged_compaction_transition->{transition_sequence}++;
delete $forged_compaction_transition->{finalization}{result}{publication_evidence};
{
    no warnings 'redefine';
    local *FServe::Transfer::Coordinator::_replay_event = sub { return 1 };
    $verified_handoff_coordinator->journal->append('job_transition', {
        job => $forged_compaction_transition });
}
my $forged_compaction_bytes_before;
open my $forged_compaction_before_fh, '<:raw', "$tmp/verified-resume-handoff.jsonl"
    or die "read completed journal before forged compaction: $!";
$forged_compaction_bytes_before = do { local $/; <$forged_compaction_before_fh> };
close $forged_compaction_before_fh
    or die "close completed journal before forged compaction: $!";
my $forged_publication_compaction_ok = eval {
    $verified_handoff_coordinator->compact_journal();
    1;
};
ok !$forged_publication_compaction_ok,
    'compaction rejects a completed resumed transition with missing publication evidence';
like $@, qr/lacks durable publication evidence/,
    'compaction refusal identifies missing publication evidence';
open my $forged_compaction_after_fh, '<:raw', "$tmp/verified-resume-handoff.jsonl"
    or die "read completed journal after forged compaction: $!";
my $forged_compaction_bytes_after = do { local $/; <$forged_compaction_after_fh> };
close $forged_compaction_after_fh
    or die "close completed journal after forged compaction: $!";
is $forged_compaction_bytes_after, $forged_compaction_bytes_before,
    'rejected completed-job compaction preserves the original journal bytes';
$verified_handoff_coordinator->close();

unlink "$tmp/verified-resume-output.bin"
    or die "remove disposable published fixture before replay: $!";
my $verified_handoff_recovered = open_coordinator(
    path => $verified_resume_journal_copy);
my $verified_handoff_recovered_job =
    $verified_handoff_recovered->job($verified_handoff_id);
is $verified_handoff_recovered_job->{state}, 'complete',
    'compacted completed resume remains complete after the user moves or deletes its destination';
is $verified_handoff_recovered_job->{finalization}{resume_verification}{sha256},
    $verified_handoff_job->{resume_intent}{expected_sha256},
    'restart preserves the completed-file verification audit record';
is $verified_handoff_recovered_job->{finalization}{result}{publication_evidence}{sha256},
    $verified_handoff_job->{resume_intent}{expected_sha256},
    'replay retains publication proof without consulting the destination file';
$verified_handoff_recovered->close();

my $forged_resume_complete_path = "$tmp/forged-resume-complete.jsonl";
my $forged_resume_complete = JSON::PP->new->decode(
    JSON::PP->new->canonical(1)->encode($verified_handoff_publication->{job}));
delete $forged_resume_complete->{finalization}{result}{publication_evidence};
my $forged_resume_complete_store = FServe::Transfer::Journal->open_store(
    path => $forged_resume_complete_path);
$forged_resume_complete_store->append('job_created', {
    job => $forged_resume_complete, compacted_resume_snapshot => 1 });
$forged_resume_complete_store->close();
my $forged_resume_complete_replayed = eval {
    open_coordinator(path => $forged_resume_complete_path);
    1;
};
ok !$forged_resume_complete_replayed,
    'replay rejects a completed resumed snapshot that lacks publication evidence';
like $@, qr/lacks durable publication evidence/,
    'replay refusal identifies missing durable publication evidence';

my $prepare_publishable_resume = sub {
    my ($profile, $name, $destination) = @_;
    my $coordinator = open_coordinator(path => "$tmp/$profile.jsonl");
    my ($id) = $prepare_resume_pending_job->($coordinator, $profile, $name,
        "${profile}Bot");
    my $resume_job = $coordinator->job($id);
    $coordinator->transition($id, 'receiving',
        outcome => 'offline_publication_fixture');
    my $staging_path = $resume_job->{resume_intent}{snapshot_path};
    open my $append_fh, '>>:raw', $staging_path
        or die "append publication fixture payload: $!";
    print {$append_fh} '-complete'
        or die "write publication fixture payload: $!";
    close $append_fh or die "close publication fixture payload: $!";
    my $session = begin_resumed_file_verification(
        path => $staging_path,
        staging_root => $resume_job->{resume_intent}{staging_root},
        resume_intent => $resume_job->{resume_intent},
        expected_sha256 => $resume_job->{resume_intent}{expected_sha256},
        writer_closed => 1);
    my $verification;
    while ($session->{state} eq 'verifying') {
        $verification = step_resumed_file_verification($session, 8);
        last unless $verification->{type} eq 'in_progress';
    }
    die 'publication test fixture failed its whole-file verification'
        unless ref($verification) eq 'HASH' &&
            $verification->{type} eq 'verified_resumed_file';
    $coordinator->reserve_verified_resume_finalization($id,
        verification => $verification, destination_path => $destination);
    return ($coordinator, $id, $staging_path,
        $resume_job->{resume_intent}{expected_sha256},
        $resume_job->{resume_intent}{total_size},
        $verification->{identity});
};

my ($mutated_publication, $mutated_publication_id, $mutated_staging,
    $mutated_digest, $mutated_size, $mutated_receipt_identity) =
    $prepare_publishable_resume->('MutatedResumeNet', 'Mutated.epub',
        "$tmp/mutated-resume-output.bin");
my $real_resume_link = \&FServe::Transfer::Coordinator::_link_resume_staging;
my $mutated_publication_result;
{
    no warnings 'redefine';
    local *FServe::Transfer::Coordinator::_link_resume_staging = sub {
        my ($coordinator, $staging_path, $destination_path) = @_;
        open my $mutate_fh, '+<:raw', $staging_path
            or die "open post-receipt mutation fixture: $!";
        my $bytes = do { local $/; <$mutate_fh> };
        substr($bytes, 0, 1) = substr($bytes, 0, 1) eq 'X' ? 'Y' : 'X';
        seek($mutate_fh, 0, 0) or die "rewind post-receipt mutation fixture: $!";
        print {$mutate_fh} $bytes or die "mutate post-receipt fixture: $!";
        truncate($mutate_fh, length($bytes))
            or die "retain post-receipt fixture size: $!";
        close $mutate_fh or die "close post-receipt mutation fixture: $!";
        Time::HiRes::utime($mutated_receipt_identity->{mtime},
            $mutated_receipt_identity->{mtime}, $staging_path) == 1
            or die "restore post-receipt fixture mtime: $!";
        return $real_resume_link->($coordinator, $staging_path, $destination_path);
    };
    $mutated_publication_result =
        $mutated_publication->publish_verified_resume_finalization(
            $mutated_publication_id);
}
is $mutated_publication_result->{type}, 'publication_refused',
    'publication refuses a same-inode rewrite after verifier receipt creation';
like $mutated_publication_result->{reason}, qr/digest does not match/,
    'post-receipt mutation refusal reports digest mismatch';
is $mutated_publication_result->{job}{state}, 'needs_attention',
    'post-receipt digest mismatch never completes the job';
ok -f $mutated_staging,
    'post-receipt digest mismatch preserves the staging name for inspection';
ok !-e "$tmp/mutated-resume-output.bin",
    'post-receipt digest mismatch removes only the just-created destination link';
is -s $mutated_staging, $mutated_size,
    'post-receipt mutation fixture retained its original size';
isnt sha256_hex(do { open my $read_fh, '<:raw', $mutated_staging or die $!;
    local $/; <$read_fh> }), $mutated_digest,
    'post-receipt mutation fixture digest differs from the trusted digest';
$mutated_publication->close();

my ($window_mutation_coordinator, $window_mutation_id,
    $window_mutation_staging, $window_mutation_digest, $window_mutation_size,
    $window_mutation_identity) =
    $prepare_publishable_resume->('PublicationWindowMutationNet',
        'WindowMutation.epub', "$tmp/window-mutation-output.bin");
my $real_directory_sync =
    \&FServe::Transfer::Journal::sync_parent_directory;
my $window_mutation_result;
{
    no warnings 'redefine';
    local *FServe::Transfer::Journal::sync_parent_directory = sub {
        my ($journal, $path) = @_;
        $real_directory_sync->($journal, $path);
        return 1 unless $path eq "$tmp/window-mutation-output.bin";
        open my $mutate_fh, '+<:raw', $path
            or die "open post-digest mutation fixture: $!";
        my $bytes = do { local $/; <$mutate_fh> };
        substr($bytes, -1, 1) = substr($bytes, -1, 1) eq 'X' ? 'Y' : 'X';
        seek($mutate_fh, 0, 0) or die "rewind post-digest mutation fixture: $!";
        print {$mutate_fh} $bytes or die "mutate post-digest fixture: $!";
        truncate($mutate_fh, length($bytes))
            or die "retain post-digest fixture size: $!";
        close $mutate_fh or die "close post-digest mutation fixture: $!";
        Time::HiRes::utime($window_mutation_identity->{mtime},
            $window_mutation_identity->{mtime}, $path) == 1
            or die "restore post-digest fixture mtime: $!";
        return 1;
    };
    $window_mutation_result =
        $window_mutation_coordinator->publish_verified_resume_finalization(
            $window_mutation_id);
}
is $window_mutation_result->{type}, 'publication_refused',
    'publication refuses same-inode mutation during the post-digest durability window';
like $window_mutation_result->{reason}, qr/changed before durable completion/,
    'post-digest mutation is caught by final path identity revalidation';
is $window_mutation_result->{job}{state}, 'needs_attention',
    'post-digest mutation cannot produce a completed job';
ok -f $window_mutation_staging,
    'post-digest mutation retains the staging path for inspection';
ok !-e "$tmp/window-mutation-output.bin",
    'post-digest mutation does not retain a false successful destination';
$window_mutation_coordinator->close();

my ($sync_failure_coordinator, $sync_failure_id, $sync_failure_staging) =
    $prepare_publishable_resume->('PayloadSyncFailureNet', 'SyncFailure.epub',
        "$tmp/payload-sync-failure.bin");
my $sync_failure_result;
{
    no warnings 'redefine';
    local *FServe::Transfer::Coordinator::_sync_payload_handle = sub { return 0 };
    $sync_failure_result =
        $sync_failure_coordinator->publish_verified_resume_finalization(
            $sync_failure_id);
}
is $sync_failure_result->{type}, 'publication_refused',
    'payload fsync failure refuses publication';
like $sync_failure_result->{reason}, qr/payload durable sync failed/,
    'payload fsync failure is reported precisely';
is $sync_failure_result->{job}{state}, 'needs_attention',
    'payload fsync failure records a non-complete job state';
ok -f $sync_failure_staging,
    'payload fsync failure retains the verified staging name';
ok !-e "$tmp/payload-sync-failure.bin",
    'payload fsync failure removes the newly linked destination name';
$sync_failure_coordinator->close();

my ($recovery_publication, $recovery_publication_id,
    $recovery_publication_staging) =
    $prepare_publishable_resume->('RecoveredResumeNet', 'Recovered.epub',
        "$tmp/recovered-resume-output.bin");
link($recovery_publication_staging, "$tmp/recovered-resume-output.bin")
    or die "model crash after exclusive destination link: $!";
$recovery_publication->close();
my $recovered_resume_publication = open_coordinator(
    path => "$tmp/RecoveredResumeNet.jsonl");
my $recovered_resume_publication_job =
    $recovered_resume_publication->job($recovery_publication_id);
is $recovered_resume_publication_job->{state}, 'complete',
    'restart completes a finalizing resume only after rehashing and syncing the destination';
is $recovered_resume_publication_job->{finalization}{result}{publication_evidence}{method},
    'recovery_verified', 'restart records explicit successful publication-recovery evidence';
ok $recovered_resume_publication_job->{finalization}{result}{publication_evidence}{payload_synced},
    'restart evidence confirms payload sync';
ok $recovered_resume_publication_job->{finalization}{result}{publication_evidence}{directory_synced},
    'restart evidence confirms destination-directory sync';
ok $recovered_resume_publication->compact_journal(),
    'reconciled resumed completion and recovery evidence survive compaction';
$recovered_resume_publication->close();
unlink "$tmp/recovered-resume-output.bin"
    or die "remove disposable recovered destination before replay: $!";
my $recovered_resume_publication_replay = open_coordinator(
    path => "$tmp/RecoveredResumeNet.jsonl");
is $recovered_resume_publication_replay->job($recovery_publication_id)->{state},
    'complete', 'compacted recovery proof remains sufficient after destination removal';
$recovered_resume_publication_replay->close();

my ($durable_result_publication, $durable_result_publication_id) =
    $prepare_publishable_resume->('DurableResultResumeNet', 'Durable.epub',
        "$tmp/durable-result-output.bin");
my $original_coordinator_transition =
    \&FServe::Transfer::Coordinator::transition;
{
    no warnings 'redefine';
    local *FServe::Transfer::Coordinator::transition = sub {
        my ($coordinator, $id, $state, @args) = @_;
        die "simulated restart after durable publication result\n"
            if $id eq $durable_result_publication_id && $state eq 'complete';
        return $original_coordinator_transition->(
            $coordinator, $id, $state, @args);
    };
    my $publication_finished = eval {
        $durable_result_publication->publish_verified_resume_finalization(
            $durable_result_publication_id);
        1;
    };
    ok !$publication_finished,
        'publication fixture stops after its durable success result';
    like $@, qr/simulated restart after durable publication result/,
        'publication fixture stops before the complete transition';
}
is $durable_result_publication->job($durable_result_publication_id)->{state},
    'finalizing', 'interrupted publication remains finalizing before restart';
unlink "$tmp/durable-result-output.bin"
    or die "remove published destination before interrupted-result recovery: $!";
ok !-e "$tmp/durable-result-output.bin",
    'durable success is the restart proof even if the destination is removed';
$durable_result_publication->close();

my $durable_result_recovery = open_coordinator(
    path => "$tmp/DurableResultResumeNet.jsonl");
my $durable_result_recovered_job =
    $durable_result_recovery->job($durable_result_publication_id);
is $durable_result_recovered_job->{state}, 'complete',
    'restart completes from the matching durable publication result';
is $durable_result_recovered_job->{finalization}{status}, 'published',
    'restart preserves the original publication status';
is $durable_result_recovered_job->{finalization}{result}{publication_evidence}{method},
    'exclusive_hard_link',
    'restart preserves the exact durable hard-link publication evidence';
my $durable_result_evidence = JSON::PP->new->decode(
    JSON::PP->new->canonical(1)->encode(
        $durable_result_recovered_job->{finalization}{result}));
ok $durable_result_recovery->compact_journal(),
    'compaction accepts a recovered completion with its matching durable result';
$durable_result_recovery->close();

my $durable_result_replay = open_coordinator(
    path => "$tmp/DurableResultResumeNet.jsonl");
my $durable_result_replayed_job =
    $durable_result_replay->job($durable_result_publication_id);
is $durable_result_replayed_job->{state}, 'complete',
    'compacted durable publication success survives restart after destination removal';
is_deeply $durable_result_replayed_job->{finalization}{result},
    $durable_result_evidence,
    'restart preserves the same publication evidence after destination removal';
ok $durable_result_replay->compact_journal(),
    'repeated compaction succeeds without the published destination';
$durable_result_replay->close();
my $durable_result_second_replay = open_coordinator(
    path => "$tmp/DurableResultResumeNet.jsonl");
is $durable_result_second_replay->job($durable_result_publication_id)->{state},
    'complete', 'repeated restart retains the durable completed result';
$durable_result_second_replay->close();

my ($durable_refusal_publication, $durable_refusal_publication_id,
    $durable_refusal_staging) =
    $prepare_publishable_resume->('DurableRefusalResumeNet', 'Refused.epub',
        "$tmp/durable-refusal-output.bin");
copy($durable_refusal_staging, "$tmp/durable-refusal-output.bin")
    or die "create existing same-content refusal target: $!";
chmod 0600, "$tmp/durable-refusal-output.bin"
    or die "set existing refusal target permissions: $!";
my $original_refusal_transition =
    \&FServe::Transfer::Coordinator::transition;
{
    no warnings 'redefine';
    local *FServe::Transfer::Coordinator::transition = sub {
        my ($coordinator, $id, $state, @args) = @_;
        die "simulated restart after durable publication refusal\n"
            if $id eq $durable_refusal_publication_id &&
                $state eq 'needs_attention';
        return $original_refusal_transition->(
            $coordinator, $id, $state, @args);
    };
    my $refusal_transition_finished = eval {
        $durable_refusal_publication->publish_verified_resume_finalization(
            $durable_refusal_publication_id);
        1;
    };
    ok !$refusal_transition_finished,
        'publication fixture stops after its durable refusal result';
    like $@, qr/simulated restart after durable publication refusal/,
        'publication fixture stops before the needs_attention transition';
}
is $durable_refusal_publication->job($durable_refusal_publication_id)->{state},
    'finalizing', 'durable refusal fixture remains finalizing before restart';
my $durable_refusal_finalizations =
    $durable_refusal_publication->{finalizations};
my $durable_refusal_finalization =
    $durable_refusal_finalizations->{$durable_refusal_publication_id};
is $durable_refusal_finalization->{status}, 'unresolved',
    'publication refusal is durably recorded as unresolved';
my $durable_refusal_result = JSON::PP->new->decode(
    JSON::PP->new->canonical(1)->encode(
        $durable_refusal_finalization->{result}));
$durable_refusal_publication->close();

my $durable_refusal_recovery = open_coordinator(
    path => "$tmp/DurableRefusalResumeNet.jsonl");
my $durable_refusal_recovered_job =
    $durable_refusal_recovery->job($durable_refusal_publication_id);
is $durable_refusal_recovered_job->{state}, 'needs_attention',
    'restart preserves a durable refusal despite an existing matching file';
is $durable_refusal_recovered_job->{finalization}{status}, 'unresolved',
    'restart preserves the unresolved publication status';
is_deeply $durable_refusal_recovered_job->{finalization}{result},
    $durable_refusal_result,
    'restart preserves the exact failed publication result';
ok -f "$tmp/durable-refusal-output.bin",
    'refusal recovery leaves the preexisting destination untouched';
ok $durable_refusal_recovery->compact_journal(),
    'compaction accepts a recovered refusal with its matching durable result';
$durable_refusal_recovery->close();

my $durable_refusal_replay = open_coordinator(
    path => "$tmp/DurableRefusalResumeNet.jsonl");
my $durable_refusal_replayed_job =
    $durable_refusal_replay->job($durable_refusal_publication_id);
is $durable_refusal_replayed_job->{state}, 'needs_attention',
    'compacted refusal survives restart without becoming a success';
is_deeply $durable_refusal_replayed_job->{finalization}{result},
    $durable_refusal_result,
    'compacted restart retains the original refusal result';
ok $durable_refusal_replay->compact_journal(),
    'repeated compaction succeeds for the preserved refusal';
$durable_refusal_replay->close();
my $durable_refusal_second_replay = open_coordinator(
    path => "$tmp/DurableRefusalResumeNet.jsonl");
is $durable_refusal_second_replay->job($durable_refusal_publication_id)->{state},
    'needs_attention', 'repeated restart keeps the refused publication unresolved';
$durable_refusal_second_replay->close();

my $make_inconsistent_compacted_pending = sub {
    my ($source, $id) = @_;
    my $job = JSON::PP->new->decode(
        JSON::PP->new->canonical(1)->encode($source));
    $job->{id} = $id;
    $job->{network_profile} = 'ForgedResumeSnapshotNet';
    $job->{partial}{size}++;
    $job->{resume_intent}{job_binding_sha256} =
        resume_binding_fingerprint($job);
    my $tuple = tuple_key(network_profile => $job->{network_profile},
        peer => $job->{resume_intent}{sender},
        basename => $job->{resume_intent}{offered_basename},
        casemapping => $job->{context}{casemapping});
    return ($job, $tuple);
};

my $forged_pending_replay_path = "$tmp/forged-pending-snapshot-replay.jsonl";
copy("$tmp/resume-intent.jsonl", $forged_pending_replay_path)
    or die "copy pending-snapshot replay fixture: $!";
my ($forged_pending_snapshot, $forged_pending_tuple) =
    $make_inconsistent_compacted_pending->($resume_intent_job,
        'job-' . ('e' x 32));
my $forged_snapshot_replay_store = FServe::Transfer::Journal->open_store(
    path => $forged_pending_replay_path);
$forged_snapshot_replay_store->append('job_created', {
    job => $forged_pending_snapshot, compacted_resume_snapshot => 1 });
$forged_snapshot_replay_store->append('tuple_reserved', {
    tuple => $forged_pending_tuple, job_id => $forged_pending_snapshot->{id} });
$forged_snapshot_replay_store->close();
my $forged_pending_snapshot_replay = eval {
    open_coordinator(path => $forged_pending_replay_path);
    1;
};
ok !$forged_pending_snapshot_replay,
    'replay rejects a marked pending snapshot whose partial advanced after admission';
like $@, qr/compacted resume_pending snapshot lacks consistent admission evidence/,
    'marked-snapshot replay refusal identifies its inconsistent admission binding';

my $forged_pending_compact_path = "$tmp/forged-pending-snapshot-compaction.jsonl";
copy("$tmp/resume-intent.jsonl", $forged_pending_compact_path)
    or die "copy pending-snapshot compaction fixture: $!";
my $forged_pending_snapshot_compactor = open_coordinator(
    path => $forged_pending_compact_path);
my ($forged_compaction_snapshot, $forged_compaction_tuple) =
    $make_inconsistent_compacted_pending->($resume_intent_job,
        'job-' . ('f' x 32));
$forged_pending_snapshot_compactor->journal->append('job_created', {
    job => $forged_compaction_snapshot, compacted_resume_snapshot => 1 });
$forged_pending_snapshot_compactor->journal->append('tuple_reserved', {
    tuple => $forged_compaction_tuple,
    job_id => $forged_compaction_snapshot->{id} });
my $forged_pending_compaction_bytes =
    $read_raw_file->($forged_pending_compact_path);
my $forged_pending_snapshot_compaction = eval {
    $forged_pending_snapshot_compactor->compact_journal();
    1;
};
ok !$forged_pending_snapshot_compaction,
    'compaction rejects a marked pending snapshot whose partial advanced after admission';
like $@, qr/inconsistent compacted resume_pending admission evidence/,
    'marked-snapshot compaction refusal identifies its inconsistent admission binding';
is $read_raw_file->($forged_pending_compact_path),
    $forged_pending_compaction_bytes,
    'marked-snapshot compaction refusal preserves all original journal bytes';
$forged_pending_snapshot_compactor->close();

my $resume_intent_recovered = open_coordinator(path => "$tmp/resume-intent.jsonl");
my $recovered_resume_job = $resume_intent_recovered->job($resume_job->{id});
is $recovered_resume_job->{state}, 'interrupted',
    'restart never revives a durable native resume attempt';
is_deeply $recovered_resume_job->{resume_intent}, $resume_intent_job->{resume_intent},
    'restart retains the exact resume attempt as audit evidence';
my $duplicate_resume_intent = eval {
    $resume_intent_recovered->begin_resume_intent($resume_job->{id},
        profile => $resume_test_profile, process_incarnation => 'offline-process-1',
        connection_identity => 'offline-connection-1', connection_epoch => 7,
        offer => $resume_offer, validated_partial => $resume_validation_result);
    1;
};
ok !$duplicate_resume_intent,
    'recovered intent prevents a second resume attempt for the same job';
like $@, qr/already has a durable resume attempt/,
    'one-shot resume refusal explains why retry needs a separate reviewed policy';
ok $resume_intent_recovered->compact_journal(),
    'resume intent and its immutable binding survive journal compaction';
$resume_intent_recovered->close();
my $resume_intent_compact_replay = open_coordinator(path => "$tmp/resume-intent.jsonl");
is_deeply $resume_intent_compact_replay->job($resume_job->{id})->{resume_intent},
    $resume_intent_job->{resume_intent},
    'compacted replay retains the exact durable resume intent';
$resume_intent_compact_replay->close();

my $forged_pending_source = open_coordinator(path => "$tmp/resume-intent.jsonl");
my $forged_pending_prior = $forged_pending_source->job($resume_job->{id});
$forged_pending_source->close();
my $resume_pending_replay_path = "$tmp/resume-pending-replay.jsonl";
copy("$tmp/resume-intent.jsonl", $resume_pending_replay_path)
    or die "copy resume replay fixture: $!";
my $forged_pending_replay_store = FServe::Transfer::Journal->open_store(
    path => $resume_pending_replay_path);
my $forged_repeat_pending = { %$forged_pending_prior,
    state => 'resume_pending',
    transition_sequence => $forged_pending_prior->{transition_sequence} + 1,
    outcome => 'resume_intent_durable', updated_at => time() };
$forged_pending_replay_store->append('job_transition',
    { job => $forged_repeat_pending });
$forged_pending_replay_store->close();
my $forged_repeat_replay_ok = eval {
    open_coordinator(path => $resume_pending_replay_path);
    1;
};
ok !$forged_repeat_replay_ok,
    'journal replay rejects re-entry into resume_pending with an already-recorded intent';
like $@, qr/enters resume_pending without valid durable admission/,
    'replay refusal identifies the missing one-shot admission evidence';

my $resume_pending_compact_path = "$tmp/resume-pending-compaction.jsonl";
copy("$tmp/resume-intent.jsonl", $resume_pending_compact_path)
    or die "copy resume compaction fixture: $!";
my $forged_pending_compactor = open_coordinator(path => $resume_pending_compact_path);
my $compaction_prior = $forged_pending_compactor->job($resume_job->{id});
my $forged_compaction_pending = { %$compaction_prior,
    state => 'resume_pending',
    transition_sequence => $compaction_prior->{transition_sequence} + 1,
    outcome => 'resume_intent_durable', updated_at => time() };
$forged_pending_compactor->journal->append('job_transition',
    { job => $forged_compaction_pending });
my $resume_pending_compaction_bytes = $read_raw_file->($resume_pending_compact_path);
my $forged_compaction_ok = eval {
    $forged_pending_compactor->compact_journal();
    1;
};
ok !$forged_compaction_ok,
    'journal compaction rejects resume_pending without a fresh one-shot admission';
like $@, qr/resume_pending without valid durable admission/,
    'compaction refusal identifies the missing admission evidence';
is $read_raw_file->($resume_pending_compact_path),
    $resume_pending_compaction_bytes,
    'resume-admission compaction refusal preserves the original journal bytes';
$forged_pending_compactor->close();

my $reinterrupt_coordinator = open_coordinator(
    path => "$tmp/resume-reinterrupt.jsonl");
my ($reinterrupt_id, $reinterrupt_validation) = $prepare_resume_pending_job->(
    $reinterrupt_coordinator, 'ResumeReinterruptNet', 'Reinterrupt.epub',
    'ReinterruptBot');
my $first_resume_state = $reinterrupt_coordinator->job($reinterrupt_id);
my $first_resume_intent = $first_resume_state->{resume_intent};
$reinterrupt_coordinator->transition($reinterrupt_id, 'receiving',
    outcome => 'resume_receive_started',
    data => { accepted_lifecycle => 'resumed-receive-lifecycle' });
my $resumed_partial_path = $first_resume_intent->{snapshot_path};
open my $resumed_partial_fh, '>>:raw', $resumed_partial_path
    or die "append resumed partial fixture: $!";
print {$resumed_partial_fh} '-part'
    or die "write resumed partial fixture: $!";
close $resumed_partial_fh or die "close resumed partial fixture: $!";
my @resumed_partial_stat = stat($resumed_partial_path);
die 'resumed partial fixture stat failed' unless @resumed_partial_stat;
my $reinterrupted = $reinterrupt_coordinator->mark_interrupted($reinterrupt_id,
    path => $resumed_partial_path,
    staging_root => $first_resume_intent->{staging_root},
    receive_path => $resumed_partial_path,
    receive_identity => { device => $resumed_partial_stat[0],
        inode => $resumed_partial_stat[1] },
    size => $first_resume_intent->{offset} + length('-part'),
    total_size => $first_resume_intent->{total_size},
    offered_basename => $first_resume_intent->{offered_basename},
    writer_closed => 1);
is $reinterrupted->{state}, 'interrupted',
    'a resumed receive can be interrupted again without invalidating its admission evidence';
is_deeply $reinterrupted->{resume_intent}, $first_resume_intent,
    're-interruption preserves the exact original immutable resume intent';
is $reinterrupted->{partial}{size},
    $first_resume_intent->{offset} + length('-part'),
    're-interruption records the newer partial offset independently of original evidence';
my $reinterrupt_seal = begin_partial_seal(
    path => $reinterrupted->{partial}{path},
    staging_root => $reinterrupted->{partial}{staging_root},
    expected_identity => $reinterrupted->{partial}{file_identity},
    total_size => $reinterrupted->{partial}{total_size});
my $reinterrupt_seal_result;
while ($reinterrupt_seal->{type} eq 'sealing') {
    $reinterrupt_seal_result = step_partial_seal($reinterrupt_seal, 64);
    last unless $reinterrupt_seal_result->{type} eq 'in_progress';
}
is $reinterrupt_seal_result->{type}, 'sealed_partial',
    'the newer interrupted partial can be incrementally sealed';
my $reinterrupt_sealed = $reinterrupt_coordinator->seal_interrupted_partial(
    $reinterrupt_id, %$reinterrupt_seal_result);
is $reinterrupt_sealed->{partial}{partial_sha256},
    sha256_hex("resume-prefix-Reinterrupt.epub-part"),
    'the new partial digest is stored without rebinding the original admission';
is_deeply $reinterrupt_sealed->{resume_intent}, $first_resume_intent,
    'sealing the later partial leaves the immutable original intent intact';
ok $reinterrupt_coordinator->compact_journal(),
    'compaction accepts later receive state while validating the original admission point';
$reinterrupt_coordinator->close();
my $reinterrupt_replay = open_coordinator(
    path => "$tmp/resume-reinterrupt.jsonl");
my $reinterrupt_recovered = $reinterrupt_replay->job($reinterrupt_id);
is $reinterrupt_recovered->{state}, 'needs_attention',
    'restart after a second interruption remains fail-closed for native resume';
is $reinterrupt_recovered->{partial}{partial_sha256},
    sha256_hex("resume-prefix-Reinterrupt.epub-part"),
    'replay preserves the newly sealed partial after restart';
is_deeply $reinterrupt_recovered->{resume_intent}, $first_resume_intent,
    'replay preserves original admission evidence alongside the newer partial';
$reinterrupt_replay->close();

my $make_resumed_verify_fixture = sub {
    my ($name, $actual_prefix, $actual_suffix, $expected_prefix,
        $expected_suffix) = @_;
    my $root = "$tmp/resumed-verify-$name";
    mkdir $root or die "create resumed verification root: $!";
    my $path = "$root/resumed.bin";
    open my $fh, '>:raw', $path or die "create resumed verification file: $!";
    print {$fh} $actual_prefix or die "write resumed verification prefix: $!";
    close $fh or die "close resumed verification prefix: $!";
    chmod 0600, $path or die "protect resumed verification fixture: $!";
    my $captured = capture_partial(path => $path, staging_root => $root);
    die $captured->{reason} unless $captured->{type} eq 'captured_partial';
    open my $append_fh, '>>:raw', $path or die "append resumed verification suffix: $!";
    print {$append_fh} $actual_suffix or die "write resumed verification suffix: $!";
    close $append_fh or die "close resumed verification suffix: $!";
    my $expected_bytes = $expected_prefix . $expected_suffix;
    my $intent = {
        attempt_id => 'resume-' . ('9' x 32),
        offset => length($expected_prefix),
        total_size => length($expected_bytes),
        partial_sha256 => sha256_hex($expected_prefix),
        expected_sha256 => sha256_hex($expected_bytes),
        snapshot_path => $path, staging_root => $root,
        snapshot_identity => $captured->{identity},
        snapshot_directory_identities => $captured->{directory_identities},
    };
    return ($intent, $expected_bytes);
};
my ($completed_resume_intent, $completed_resume_bytes) =
    $make_resumed_verify_fixture->('valid', 'prefix-data', '-verified-suffix',
        'prefix-data', '-verified-suffix');
my $unclosed_resume_verification = begin_resumed_file_verification(
    path => $completed_resume_intent->{snapshot_path},
    staging_root => $completed_resume_intent->{staging_root},
    resume_intent => $completed_resume_intent,
    expected_sha256 => $completed_resume_intent->{expected_sha256},
    writer_closed => 0);
is $unclosed_resume_verification->{type}, 'refusal',
    'completed resumed-file verification refuses an unconfirmed writer close';
my $truthy_writer_evidence = begin_resumed_file_verification(
    path => $completed_resume_intent->{snapshot_path},
    staging_root => $completed_resume_intent->{staging_root},
    resume_intent => $completed_resume_intent,
    expected_sha256 => $completed_resume_intent->{expected_sha256},
    writer_closed => 'false');
is $truthy_writer_evidence->{type}, 'refusal',
    'completed resumed-file verification refuses truthy non-boolean closure evidence';
my $completed_resume_session = begin_resumed_file_verification(
    path => $completed_resume_intent->{snapshot_path},
    staging_root => $completed_resume_intent->{staging_root},
    resume_intent => $completed_resume_intent,
    expected_sha256 => $completed_resume_intent->{expected_sha256},
    writer_closed => 1);
is $completed_resume_session->{type}, 'verifying_resumed_file',
    'completed-file verifier opens only the durable private resume snapshot';
my ($completed_resume_result, $max_resume_verify_step) = (undef, 0);
while ($completed_resume_session->{state} eq 'verifying') {
    my $before = $completed_resume_session->{bytes_hashed};
    $completed_resume_result = step_resumed_file_verification(
        $completed_resume_session, 4);
    my $consumed = $completed_resume_session->{bytes_hashed} - $before;
    $max_resume_verify_step = $consumed if $consumed > $max_resume_verify_step;
    last unless $completed_resume_result->{type} eq 'in_progress';
}
is $completed_resume_result->{type}, 'verified_resumed_file',
    'incremental resumed-file verification accepts exact prefix, length, and trusted digest';
is $completed_resume_result->{prefix_sha256},
    $completed_resume_intent->{partial_sha256},
    'resumed-file verification reports the verified original prefix digest';
is $completed_resume_result->{sha256},
    $completed_resume_intent->{expected_sha256},
    'resumed-file verification reports the trusted whole-file digest';
my $completed_resume_receipt = consume_resumed_file_verification(
    $completed_resume_result);
is $completed_resume_receipt->{type}, 'consumed_resume_verification',
    'successful resumed-file verification issues a consumable one-shot receipt';
is $completed_resume_receipt->{verification}{attempt_id},
    $completed_resume_intent->{attempt_id},
    'verification receipt retains the authoritative resume attempt identity';
is consume_resumed_file_verification($completed_resume_result)->{type}, 'refusal',
    'a resumed-file verification receipt cannot be consumed twice';
cmp_ok $max_resume_verify_step, '<=', 4,
    'resumed-file verification honors its per-call byte budget';
is cancel_resumed_file_verification($completed_resume_session)->{type},
    'already_completed',
    'late verification cancellation cannot disturb a completed result';
ok -f $completed_resume_intent->{snapshot_path},
    'verified resumed content remains staged for explicit finalization';

my ($active_cancel_intent, $active_cancel_bytes) =
    $make_resumed_verify_fixture->('active-cancel', 'prefix-data', '-cancel-suffix',
        'prefix-data', '-cancel-suffix');
my $active_cancel_session = begin_resumed_file_verification(
    path => $active_cancel_intent->{snapshot_path},
    staging_root => $active_cancel_intent->{staging_root},
    resume_intent => $active_cancel_intent,
    expected_sha256 => $active_cancel_intent->{expected_sha256},
    writer_closed => 1);
is step_resumed_file_verification($active_cancel_session, 3)->{type}, 'in_progress',
    'active resumed-file verification advances by one bounded chunk before cancellation';
my $active_cancel_result = cancel_resumed_file_verification($active_cancel_session);
is $active_cancel_result->{type}, 'cancelled',
    'active resumed-file verification can be cancelled before digest completion';
ok !defined($active_cancel_session->{fh}),
    'active verification cancellation closes its staged-file handle';
open my $active_cancel_read_fh, '<:raw', $active_cancel_intent->{snapshot_path}
    or die "read cancelled resume fixture: $!";
my $active_cancel_preserved_bytes;
{ local $/; $active_cancel_preserved_bytes = <$active_cancel_read_fh>; }
close $active_cancel_read_fh or die "close cancelled resume fixture: $!";
is $active_cancel_preserved_bytes, $active_cancel_bytes,
    'active verification cancellation preserves the complete staged file';

my ($short_resume_intent, $short_resume_bytes) =
    $make_resumed_verify_fixture->('short-file', 'prefix-data', '-short-suffix',
        'prefix-data', '-short-suffix');
my $short_resume_session = begin_resumed_file_verification(
    path => $short_resume_intent->{snapshot_path},
    staging_root => $short_resume_intent->{staging_root},
    resume_intent => $short_resume_intent,
    expected_sha256 => $short_resume_intent->{expected_sha256},
    writer_closed => 1);
open my $short_resume_mutator_fh, '>:raw', $short_resume_intent->{snapshot_path}
    or die "truncate resumed-file fixture: $!";
print {$short_resume_mutator_fh} substr($short_resume_bytes, 0, length($short_resume_bytes) - 1)
    or die "write short resumed-file fixture: $!";
close $short_resume_mutator_fh or die "close short resumed-file fixture: $!";
my $short_resume_result = step_resumed_file_verification($short_resume_session, 64);
is $short_resume_result->{type}, 'refusal',
    'resumed-file verifier refuses a file shortened after opening';
like $short_resume_result->{reason}, qr/ended before its captured total length/,
    'short-file refusal reports premature end of input';
ok -f $short_resume_intent->{snapshot_path},
    'short resumed file remains staged after refusal';

my ($grown_resume_intent, $grown_resume_bytes) =
    $make_resumed_verify_fixture->('grown-file', 'prefix-data', '-grown-suffix',
        'prefix-data', '-grown-suffix');
my $grown_resume_session = begin_resumed_file_verification(
    path => $grown_resume_intent->{snapshot_path},
    staging_root => $grown_resume_intent->{staging_root},
    resume_intent => $grown_resume_intent,
    expected_sha256 => $grown_resume_intent->{expected_sha256},
    writer_closed => 1);
open my $grown_resume_mutator_fh, '>>:raw', $grown_resume_intent->{snapshot_path}
    or die "append resumed-file fixture: $!";
print {$grown_resume_mutator_fh} 'x' or die "grow resumed-file fixture: $!";
close $grown_resume_mutator_fh or die "close grown resumed-file fixture: $!";
my $grown_resume_result = step_resumed_file_verification($grown_resume_session, 64);
is $grown_resume_result->{type}, 'refusal',
    'resumed-file verifier refuses a file grown after opening';
like $grown_resume_result->{reason}, qr/grew beyond its expected total length/,
    'grown-file refusal reports the excess byte';
is -s $grown_resume_intent->{snapshot_path}, length($grown_resume_bytes) + 1,
    'grown resumed file remains staged without truncation or deletion after refusal';

my ($bad_suffix_intent) = $make_resumed_verify_fixture->('bad-suffix',
    'prefix-data', 'x' x length('-verified-suffix'),
    'prefix-data', '-verified-suffix');
my $bad_suffix_session = begin_resumed_file_verification(
    path => $bad_suffix_intent->{snapshot_path},
    staging_root => $bad_suffix_intent->{staging_root},
    resume_intent => $bad_suffix_intent,
    expected_sha256 => $bad_suffix_intent->{expected_sha256},
    writer_closed => 1);
my $bad_suffix_result;
while ($bad_suffix_session->{state} eq 'verifying') {
    $bad_suffix_result = step_resumed_file_verification($bad_suffix_session, 64);
    last unless $bad_suffix_result->{type} eq 'in_progress';
}
is $bad_suffix_result->{type}, 'refusal',
    'whole-file verifier refuses same-length resumed content with a wrong suffix';
like $bad_suffix_result->{reason}, qr/trusted whole-file digest/,
    'wrong-suffix refusal identifies the full-content digest mismatch';
ok -f $bad_suffix_intent->{snapshot_path},
    'wrong resumed content remains staged and is not deleted on refusal';

my ($bad_prefix_intent) = $make_resumed_verify_fixture->('bad-prefix',
    'X' x length('prefix-data'), '-verified-suffix',
    'prefix-data', '-verified-suffix');
my $bad_prefix_session = begin_resumed_file_verification(
    path => $bad_prefix_intent->{snapshot_path},
    staging_root => $bad_prefix_intent->{staging_root},
    resume_intent => $bad_prefix_intent,
    expected_sha256 => $bad_prefix_intent->{expected_sha256},
    writer_closed => 1);
my $bad_prefix_result;
while ($bad_prefix_session->{state} eq 'verifying') {
    $bad_prefix_result = step_resumed_file_verification($bad_prefix_session, 64);
    last unless $bad_prefix_result->{type} eq 'in_progress';
}
is $bad_prefix_result->{type}, 'refusal',
    'whole-file verifier independently refuses a changed original prefix';
like $bad_prefix_result->{reason}, qr/prefix does not match/,
    'changed-prefix refusal identifies the partial digest mismatch';

is discard_partial_snapshot($resume_validation_result)->{type}, 'discarded_snapshot',
    'offline resume-intent fixture releases its validated snapshot after verification';

my $open_writer_job = $partial_coordinator->create_job(provider => 'find',
    network_profile => 'PartialNet',
    selection => { remote_path => '/Books/OpenWriter.epub', name => 'OpenWriter.epub',
        expected_peer => 'PartialBot', basename => 'OpenWriter.epub' },
    context => { channel => '#partial' }, limits => {});
$partial_coordinator->begin_dispatch($open_writer_job->{id}, casemapping => 'rfc1459');
$partial_coordinator->record_dispatch_result($open_writer_job->{id}, 'sent');
$partial_coordinator->accept_offer($open_writer_job->{id},
    accepted_lifecycle => 'open-writer-lifecycle', offered_basename => 'OpenWriter.epub');
my $open_writer_interrupted = $partial_coordinator->mark_interrupted($open_writer_job->{id},
    path => $partial_path, staging_root => $staging_root,
    receive_path => $partial_path,
    receive_identity => { device => $partial_snapshot->{identity}{device},
        inode => $partial_snapshot->{identity}{inode} },
    size => length($partial_bytes), total_size => length($partial_bytes) + 5,
    offered_basename => 'OpenWriter.epub');
ok !$open_writer_interrupted->{partial}{writer_closed},
    'missing writer-close evidence fails closed by default';
my $open_writer_seal = eval {
    $partial_coordinator->seal_interrupted_partial($open_writer_job->{id},
        %$coordinator_seal_result);
};
ok !$open_writer_seal, 'coordinator refuses to seal while native writer closure is unconfirmed';
like $@, qr/writer is not closed/,
    'writer-closure seal refusal is explicit';
$partial_coordinator->close();
my $partial_replay = open_coordinator(path => "$tmp/partial-coordinator.jsonl");
my $replayed_partial = $partial_replay->job($partial_job->{id});
is $replayed_partial->{partial}{ownership_status}, 'captured',
    'partial ownership snapshot survives journal replay';
is $replayed_partial->{partial}{file_identity}{inode},
    $partial_snapshot->{identity}{inode},
    'journal replay preserves the exact captured partial inode';
is $replayed_partial->{partial}{digest_status}, 'sealed',
    'journal replay preserves the partial digest seal';
is $replayed_partial->{partial}{partial_sha256}, sha256_hex($partial_bytes),
    'journal replay preserves the exact sealed partial digest';

my $replacement_path = "$staging_root/replacement.bin";
open my $replacement_fh, '>:raw', $replacement_path or die $!;
print {$replacement_fh} $partial_bytes;
close $replacement_fh;
my @replacement_stat = stat($replacement_path);
my $replacement_job = $partial_replay->create_job(provider => 'find',
    network_profile => 'PartialNet',
    selection => { remote_path => '/Books/Replaced.epub', name => 'Replaced.epub',
        expected_peer => 'PartialBot', basename => 'Replaced.epub' },
    context => { channel => '#partial' }, limits => {});
$partial_replay->begin_dispatch($replacement_job->{id}, casemapping => 'rfc1459');
$partial_replay->record_dispatch_result($replacement_job->{id}, 'sent');
$partial_replay->accept_offer($replacement_job->{id},
    accepted_lifecycle => 'replacement-lifecycle', offered_basename => 'Replaced.epub');
my $replacement_interrupted = $partial_replay->mark_interrupted($replacement_job->{id},
    path => $replacement_path, staging_root => $staging_root,
    receive_path => $replacement_path,
    receive_identity => { device => $replacement_stat[0], inode => $replacement_stat[1] + 1 },
    size => length($partial_bytes), total_size => length($partial_bytes) + 5,
    offered_basename => 'Replaced.epub');
is $replacement_interrupted->{partial}{ownership_status}, 'unverified',
    'replacement inode cannot be adopted as the transfer-owned partial';
ok !exists($replacement_interrupted->{partial}{file_identity}),
    'mismatched replacement identity is not stored as authoritative ownership';
my $unobserved_job = $partial_replay->create_job(provider => 'find',
    network_profile => 'PartialNet',
    selection => { remote_path => '/Books/Unobserved.epub', name => 'Unobserved.epub',
        expected_peer => 'PartialBot', basename => 'Unobserved.epub' },
    context => { channel => '#partial' }, limits => {});
$partial_replay->begin_dispatch($unobserved_job->{id}, casemapping => 'rfc1459');
$partial_replay->record_dispatch_result($unobserved_job->{id}, 'sent');
$partial_replay->accept_offer($unobserved_job->{id},
    accepted_lifecycle => 'unobserved-lifecycle', offered_basename => 'Unobserved.epub');
my $unobserved_interrupted = $partial_replay->mark_interrupted($unobserved_job->{id},
    path => $replacement_path, staging_root => $staging_root,
    size => length($partial_bytes), total_size => length($partial_bytes) + 5,
    offered_basename => 'Unobserved.epub');
is $unobserved_interrupted->{partial}{ownership_status}, 'unverified',
    'close-time path observation without receive identity cannot prove ownership';
like $unobserved_interrupted->{partial}{ownership_refusal},
    qr/receive-time partial identity is unavailable/,
    'missing receive-time identity has an explicit refusal reason';
$partial_replay->close();
$partial_replay = open_coordinator(path => "$tmp/partial-coordinator.jsonl");
my $replayed_replacement = $partial_replay->job($replacement_job->{id});
is $replayed_replacement->{partial}{ownership_status}, 'unverified',
    'journal replay preserves replacement ownership refusal';
like $replayed_replacement->{partial}{ownership_refusal}, qr/receive-time identity/,
    'journal replay explains the receive-time identity mismatch';
my $replayed_unobserved = $partial_replay->job($unobserved_job->{id});
is $replayed_unobserved->{partial}{ownership_status}, 'unverified',
    'journal replay preserves missing receive-time identity refusal';
like $replayed_unobserved->{partial}{ownership_refusal},
    qr/receive-time partial identity is unavailable/,
    'journal replay preserves why receive ownership was unavailable';
$partial_replay->close();

done_testing();
