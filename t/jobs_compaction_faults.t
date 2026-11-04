use strict;
use warnings;

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Errno qw(EIO);
use Test::More;

use lib "$Bin/../lib";
use FServe::Transfer::Coordinator qw(open_coordinator);
use FServe::Transfer::Journal ();

my %tempdir_args = (CLEANUP => 1);
$tempdir_args{DIR} = $Bin if $^O eq 'MSWin32';
my $root = tempdir(%tempdir_args);

# Directory durability is tested with the Linux container suite. This focused
# matrix isolates transaction ordering and injected failures across platforms.
local *FServe::Transfer::Journal::_sync_directory = sub { return 1; };

sub seed_journal {
    my ($name) = @_;
    my $path = "$root/$name.jsonl";
    my $coordinator = open_coordinator(path => $path);
    my $job = $coordinator->create_job(provider => 'find',
        network_profile => 'CompactionFaultMatrix', selection => {
            remote_path => "/$name.epub", name => "$name.epub",
            expected_peer => 'FaultBot',
        }, context => { channel => '#offline-test' }, limits => {});
    my $id = $job->{id};
    $coordinator->begin_dispatch($id, casemapping => 'ascii');
    $coordinator->record_dispatch_result($id, 'sent');
    $coordinator->record_event('compaction_fault_probe', {
        job_id => $id, marker => $name,
    });
    return ($coordinator, $path, $id);
}

sub write_fault_artifact {
    my ($path, $contents) = @_;
    open my $fh, '>:raw', $path or die "cannot create test artifact $path: $!";
    print {$fh} $contents or die "cannot write test artifact $path: $!";
    close $fh or die "cannot close test artifact $path: $!";
}

sub read_fault_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read test file $path: $!";
    local $/;
    return <$fh>;
}

sub leave_archived_compaction_for_recovery {
    my ($coordinator, $name) = @_;
    my $path = $coordinator->journal->path;
    my $syncs = 0;
    my $completed;
    {
        local *FServe::Transfer::Journal::_sync_directory = sub {
            $syncs++;
            die "injected preparation stop after archive rename for $name\n"
                if $syncs == 3;
            return 1;
        };
        $completed = eval { $coordinator->compact_journal(); 1 };
    }
    ok(!$completed, "$name prepares an interrupted archived generation");
    is($syncs, 3, "$name stops after the source journal is archived");
    ok(-e "$path.compact.archive",
        "$name retains the archived source generation");
}

sub check_recovery {
    my ($coordinator, $path, $id, $name) = @_;
    $coordinator->close();
    my $recovered = eval { open_coordinator(path => $path) };
    my $error = $@;
    ok($recovered, "$name recovers a readable journal after restart")
        or diag($error);
    return unless $recovered;

    my $job = $recovered->job($id);
    ok($job, "$name retains the exact job identity");
    if ($job) {
        is($job->{state}, 'needs_attention',
            "$name preserves possible dispatch without retrying it");
        is($job->{selection}{remote_path}, "/$name.epub",
            "$name preserves the immutable selected path");
    }
    is($recovered->tuple_count, 1, "$name retains the ambiguous DCC tuple");
    my @probe_events = grep {
        $_->{event} eq 'compaction_fault_probe' &&
            $_->{data}{job_id} eq $id
    } @{$recovered->journal->page(0, 100)};
    is(scalar @probe_events, 1, "$name retains its compactable audit event");

    for my $suffix (qw(.compact.tmp .compact.ready .compact.archive
            .compact.manifest .compact.manifest.tmp)) {
        ok(!-e "$path$suffix", "$name recovery retires $suffix");
    }
    $recovered->close();
}

for my $boundary (1 .. 2) {
    my $name = "file-sync-$boundary";
    my ($coordinator, $path, $id) = seed_journal($name);
    my $syncs = 0;
    my $injected = 0;
    my $real_sync = \&FServe::Transfer::Journal::_sync_file_handle;
    my $completed;
    {
        local *FServe::Transfer::Journal::_sync_file_handle = sub {
            $syncs++;
            if ($syncs == $boundary) {
                $injected++;
                $! = EIO;
                return 0;
            }
            return $real_sync->(@_);
        };
        $completed = eval { $coordinator->compact_journal(); 1 };
    }
    ok(!$completed, "file-sync boundary $boundary aborts compaction");
    is($injected, 1, "file-sync boundary $boundary was reached exactly once");
    check_recovery($coordinator, $path, $id, $name);
}

for my $boundary (1 .. 6) {
    my $name = "sync-$boundary";
    my ($coordinator, $path, $id) = seed_journal($name);
    my $syncs = 0;
    my $injected = 0;
    my $completed;
    {
        local *FServe::Transfer::Journal::_sync_directory = sub {
            $syncs++;
            if ($syncs == $boundary) {
                $injected++;
                die "injected directory-sync failure at boundary $boundary\n";
            }
            # This matrix tests crash ordering, not the host OS's fsync API.
            return 1;
        };
        $completed = eval { $coordinator->compact_journal(); 1 };
    }
    ok(!$completed, "directory-sync boundary $boundary aborts compaction");
    is($injected, 1, "directory-sync boundary $boundary was reached exactly once");
    check_recovery($coordinator, $path, $id, $name);
}

for my $boundary (1 .. 5) {
    my $name = "rename-$boundary";
    my ($coordinator, $path, $id) = seed_journal($name);
    my $renames = 0;
    my $injected = 0;
    my $completed;
    {
        local *FServe::Transfer::Journal::_rename_path = sub {
            my ($source, $destination) = @_;
            $renames++;
            if ($renames == $boundary ||
                    ($boundary == 5 && $renames == 4)) {
                $injected++;
                $! = EIO;
                return 0;
            }
            return CORE::rename($source, $destination);
        };
        $completed = eval { $coordinator->compact_journal(); 1 };
    }
    ok(!$completed, "rename boundary $boundary aborts compaction");
    is($injected, $boundary == 5 ? 2 : 1,
        "rename boundary $boundary failure path was reached");
    check_recovery($coordinator, $path, $id, $name);
}

for my $case (
    {
        name => 'failed-archive-cleanup-sync',
        sync_failure => 3,
        rename_failure => 3,
        error => qr/injected rollback directory-sync failure at failed-archive-cleanup-sync/s,
    },
    {
        name => 'failed-restore-directory-sync',
        sync_failure => 4,
        rename_failure => 4,
        error => qr/original path restored without durable directory sync/,
    },
    {
        name => 'failed-restore-cleanup-sync',
        sync_failure => 5,
        rename_failure => 4,
        error => qr/original was restored but recovery metadata remains/,
    },
) {
    my ($coordinator, $path, $id) = seed_journal($case->{name});
    my $syncs = 0;
    my $sync_failures = 0;
    my $renames = 0;
    my $rename_failures = 0;
    my $completed;
    my $error;
    {
        local *FServe::Transfer::Journal::_sync_directory = sub {
            $syncs++;
            if ($syncs == $case->{sync_failure}) {
                $sync_failures++;
                die "injected rollback directory-sync failure at $case->{name}\n";
            }
            return 1;
        };
        local *FServe::Transfer::Journal::_rename_path = sub {
            my ($source, $destination) = @_;
            $renames++;
            if ($renames == $case->{rename_failure}) {
                $rename_failures++;
                $! = EIO;
                return 0;
            }
            return CORE::rename($source, $destination);
        };
        $completed = eval { $coordinator->compact_journal(); 1 };
        $error = $@;
    }
    ok(!$completed, "$case->{name} aborts compaction");
    is($syncs, $case->{sync_failure},
        "$case->{name} fails at the intended sync call");
    is($sync_failures, 1, "$case->{name} reaches its rollback sync failure once");
    is($rename_failures, 1,
        "$case->{name} reaches its initiating rename failure once");
    like($error, $case->{error}, "$case->{name} reports the correct rollback failure");
    check_recovery($coordinator, $path, $id, $case->{name});
}

for my $artifact_case (
    { name => 'valid-ready', ready => 'valid' },
    { name => 'rejected-ready', ready => 'invalid' },
    { name => 'rejected-ready-collision', ready => 'invalid',
        existing_rejected => 1 },
) {
    for my $failure_boundary (1 .. 2) {
        my $name = "recovery-cleanup-$artifact_case->{name}-sync-$failure_boundary";
        my ($coordinator, $path, $id) = seed_journal($name);
        $coordinator->close();
        my $canonical_before = read_fault_file($path);

        if ($artifact_case->{ready} eq 'valid') {
            copy($path, "$path.compact.ready")
                or die "cannot prepare valid recovery snapshot: $!";
        } else {
            write_fault_artifact("$path.compact.ready", "invalid snapshot\n");
        }
        write_fault_artifact("$path.compact.tmp", "unfinished snapshot\n");
        write_fault_artifact("$path.compact.manifest.tmp", "unfinished manifest\n");
        write_fault_artifact("$path.compact.rejected", "prior rejected evidence\n")
            if $artifact_case->{existing_rejected};

        my $syncs = 0;
        my $sync_failures = 0;
        my ($opened, $error);
        {
            local *FServe::Transfer::Journal::_sync_directory = sub {
                $syncs++;
                if ($syncs == $failure_boundary) {
                    $sync_failures++;
                    die "injected recovery cleanup directory-sync failure at $name\n";
                }
                return 1;
            };
            $opened = eval { open_coordinator(path => $path) };
            $error = $@;
        }
        ok(!$opened, "$name refuses to open when recovery cleanup sync fails");
        is($syncs, $failure_boundary,
            "$name reaches the selected cleanup sync boundary");
        is($sync_failures, 1, "$name injects exactly one cleanup sync failure");
        like($error, qr/injected recovery cleanup directory-sync failure/,
            "$name reports the directory-sync failure");
        is(read_fault_file($path), $canonical_before,
            "$name leaves canonical journal bytes unchanged");

        my $expect_artifacts_retained = $failure_boundary == 1 ? 1 : 0;
        is((-e "$path.compact.tmp") ? 1 : 0, $expect_artifacts_retained,
            "$name preserves temporary snapshot before cleanup sync");
        is((-e "$path.compact.manifest.tmp") ? 1 : 0,
            $expect_artifacts_retained,
            "$name preserves temporary manifest before cleanup sync");
        my $expect_ready = ($artifact_case->{existing_rejected} ||
            $expect_artifacts_retained) ? 1 : 0;
        is((-e "$path.compact.ready") ? 1 : 0, $expect_ready,
            "$name retains a ready snapshot when cleanup has not retired it");
        my $expect_rejected = ($artifact_case->{existing_rejected} ||
            (!$expect_artifacts_retained && $artifact_case->{ready} eq 'invalid'))
                ? 1 : 0;
        is((-e "$path.compact.rejected") ? 1 : 0, $expect_rejected,
            "$name retains or records rejected snapshot evidence");
        if ($artifact_case->{existing_rejected}) {
            is(read_fault_file("$path.compact.rejected"),
                "prior rejected evidence\n",
                "$name does not overwrite existing rejected evidence");
        } elsif ($expect_rejected) {
            is(read_fault_file("$path.compact.rejected"), "invalid snapshot\n",
                "$name preserves the rejected snapshot contents");
        }

        my $retry_syncs = 0;
        my $recovered;
        {
            local *FServe::Transfer::Journal::_sync_directory = sub {
                $retry_syncs++;
                return 1;
            };
            $recovered = open_coordinator(path => $path);
        }
        ok($recovered, "$name succeeds on retry after the sync fault");
        is($retry_syncs,
            $failure_boundary == 1
                ? 2
                : ($artifact_case->{existing_rejected} ? 1 : 0),
            "$name syncs expected boundaries on retry");
        my $job = $recovered->job($id);
        ok($job, "$name preserves the original job");
        is($job->{state}, 'needs_attention',
            "$name preserves the ambiguous dispatch state");
        is($recovered->tuple_count, 1, "$name retains its DCC tuple guard");
        my @events = grep {
            $_->{event} eq 'compaction_fault_probe' &&
                $_->{data}{job_id} eq $id
        } @{$recovered->journal->page(0, 100)};
        is(scalar @events, 1, "$name retains its audit event");
        for my $suffix (qw(.compact.tmp .compact.archive .compact.manifest.tmp)) {
            ok(!-e "$path$suffix", "$name retires $suffix after retry");
        }
        ok(!$artifact_case->{existing_rejected} || -e "$path.compact.ready",
            "$name retains a second rejected snapshot when evidence collides")
            if $artifact_case->{existing_rejected};
        ok(!$expect_rejected || -e "$path.compact.rejected",
            "$name keeps rejected evidence after retry");
        $recovered->close();
    }
}

for my $failure_boundary (1 .. 4) {
    my $name = "recovery-promote-ready-sync-$failure_boundary";
    my ($coordinator, $path, $id) = seed_journal($name);
    leave_archived_compaction_for_recovery($coordinator, $name);
    $coordinator->close();

    my $syncs = 0;
    my $sync_failures = 0;
    my ($opened, $error);
    {
        local *FServe::Transfer::Journal::_sync_directory = sub {
            $syncs++;
            if ($syncs == $failure_boundary) {
                $sync_failures++;
                die "injected manifest recovery directory-sync failure at $name\n";
            }
            return 1;
        };
        $opened = eval { open_coordinator(path => $path) };
        $error = $@;
    }
    ok(!$opened, "$name refuses to open when snapshot recovery sync fails");
    is($syncs, $failure_boundary, "$name fails at the selected recovery sync");
    is($sync_failures, 1, "$name injects one recovery sync failure");
    like($error, qr/injected manifest recovery directory-sync failure/,
        "$name reports the recovery sync failure");
    ok(-e $path, "$name leaves a canonical generation for retry");
    is((-e "$path.compact.manifest") ? 1 : 0,
        $failure_boundary == 4 ? 0 : 1,
        "$name preserves its manifest until final cleanup sync");
    is((-e "$path.compact.archive") ? 1 : 0,
        $failure_boundary <= 2 ? 1 : 0,
        "$name retains the archived source until cleanup begins");
    is((-e "$path.compact.ready") ? 1 : 0, 0,
        "$name consumes the prepared generation when promoting it");
    check_recovery($coordinator, $path, $id, $name);
}

for my $failure_boundary (1 .. 3) {
    my $name = "recovery-restore-archive-sync-$failure_boundary";
    my ($coordinator, $path, $id) = seed_journal($name);
    leave_archived_compaction_for_recovery($coordinator, $name);
    $coordinator->close();
    write_fault_artifact("$path.compact.ready", "invalid prepared snapshot\n");

    my $syncs = 0;
    my $sync_failures = 0;
    my ($opened, $error);
    {
        local *FServe::Transfer::Journal::_sync_directory = sub {
            $syncs++;
            if ($syncs == $failure_boundary) {
                $sync_failures++;
                die "injected manifest recovery directory-sync failure at $name\n";
            }
            return 1;
        };
        $opened = eval { open_coordinator(path => $path) };
        $error = $@;
    }
    ok(!$opened, "$name refuses to open when archive restoration sync fails");
    is($syncs, $failure_boundary, "$name fails at the selected recovery sync");
    is($sync_failures, 1, "$name injects one recovery sync failure");
    like($error, qr/injected manifest recovery directory-sync failure/,
        "$name reports the recovery sync failure");
    ok(-e $path, "$name leaves the restored source journal for retry");
    is((-e "$path.compact.manifest") ? 1 : 0,
        $failure_boundary == 3 ? 0 : 1,
        "$name keeps the recovery manifest until its final sync boundary");
    ok(!-e "$path.compact.archive", "$name restored the archived source");
    ok(!-e "$path.compact.ready", "$name moved rejected snapshot out of ready path");
    is(read_fault_file("$path.compact.rejected"), "invalid prepared snapshot\n",
        "$name preserves the rejected prepared snapshot");
    check_recovery($coordinator, $path, $id, $name);
}

for my $failure_boundary (1 .. 2) {
    my $name = "recovery-canonical-source-sync-$failure_boundary";
    my ($coordinator, $path, $id) = seed_journal($name);
    leave_archived_compaction_for_recovery($coordinator, $name);
    $coordinator->close();
    rename("$path.compact.archive", $path)
        or die "cannot prepare canonical-source recovery state: $!";

    my $syncs = 0;
    my $sync_failures = 0;
    my ($opened, $error);
    {
        local *FServe::Transfer::Journal::_sync_directory = sub {
            $syncs++;
            if ($syncs == $failure_boundary) {
                $sync_failures++;
                die "injected manifest recovery directory-sync failure at $name\n";
            }
            return 1;
        };
        $opened = eval { open_coordinator(path => $path) };
        $error = $@;
    }
    ok(!$opened, "$name refuses to open when cleanup sync fails");
    is($syncs, $failure_boundary, "$name reaches the selected recovery sync");
    is($sync_failures, 1, "$name injects one recovery sync failure");
    like($error, qr/injected manifest recovery directory-sync failure/,
        "$name reports the recovery sync failure");
    ok(-e $path, "$name retains the canonical source generation");
    ok(!-e "$path.compact.archive", "$name has no competing archive generation");
    ok(!-e "$path.compact.ready", "$name retires the prepared snapshot before sync");
    is((-e "$path.compact.manifest") ? 1 : 0,
        $failure_boundary == 1 ? 1 : 0,
        "$name retains its manifest until the final sync boundary");
    check_recovery($coordinator, $path, $id, $name);
}

{
    my $name = 'recovery-legacy-archive-sync';
    my ($coordinator, $path, $id) = seed_journal($name);
    $coordinator->close();
    rename($path, "$path.compact.archive")
        or die "cannot prepare legacy archived journal: $!";
    copy("$path.compact.archive", "$path.compact.ready")
        or die "cannot prepare matching legacy snapshot: $!";

    my $syncs = 0;
    my $sync_failures = 0;
    my ($opened, $error);
    {
        local *FServe::Transfer::Journal::_sync_directory = sub {
            $syncs++;
            if ($syncs == 1) {
                $sync_failures++;
                die "injected legacy recovery directory-sync failure at $name\n";
            }
            return 1;
        };
        $opened = eval { open_coordinator(path => $path) };
        $error = $@;
    }
    ok(!$opened, "$name refuses to open when legacy restore sync fails");
    is($syncs, 1, "$name reaches its legacy recovery sync once");
    is($sync_failures, 1, "$name injects one legacy recovery sync failure");
    like($error, qr/injected legacy recovery directory-sync failure/,
        "$name reports the legacy recovery sync failure");
    ok(-e $path, "$name leaves the restored journal at its canonical path");
    ok(-e "$path.compact.ready", "$name preserves the matching ready file");
    ok(!-e "$path.compact.archive", "$name moved the archived journal once");
    ok(!-e "$path.compact.manifest", "$name remains on the manifest-less path");
    check_recovery($coordinator, $path, $id, $name);
}

done_testing();
