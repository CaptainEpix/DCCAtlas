# The guard that keeps Irssi from resuming into a file it does not own.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Fcntl qw(S_ISLNK S_ISREG);
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use File::Spec ();
use JSON::PP ();

our (%JOBS, %TRANSFERS, $DOWNLOAD_PATH_OWNER, $PROCESS_INCARNATION);

sub resume_guard_release_if_owned {
    my ($lifecycle, $after_native_return) = @_;
    my $guard = $JOBS{native_resume_guard} or return 0;
    my $owner = $guard->owner() or return 0;
    return 0 unless ($owner->{native_lifecycle_identity} // '') eq
        ($lifecycle // '');
    return schedule_resume_guard_release($owner)
        if $after_native_return;
    resume_guard_release_after_destroy($owner->{job_id}, $lifecycle);
    return 1;
}

sub resume_guard_close_owned_for_unload {
    my $guard = $JOBS{native_resume_guard} or return 1;
    my $owner = $guard->owner() or return 1;
    my $lifecycle = $owner->{native_lifecycle_identity} // '';
    unless (length($lifecycle)) {
        p('Unload could not identify the reserved native resume; its pending DCC may remain active.');
        return 0;
    }
    my @native;
    my $available = eval {
        require Irssi::Irc;
        @native = Irssi::Irc::dccs();
        1;
    };
    unless ($available && !$@) {
        p('Unload could not inspect native DCC records to close the reserved resume; refusing to claim cleanup.');
        return 0;
    }
    my @owned = grep {
        dcc_transfer_identity_key($_) eq $lifecycle
    } @native;
    if (!@owned) {
        Irssi::timeout_remove($JOBS{native_resume_guard_release_timer})
            if defined $JOBS{native_resume_guard_release_timer};
        delete $JOBS{native_resume_guard_release_timer};
        resume_guard_release_after_destroy($owner->{job_id}, $lifecycle);
        my $status = resume_guard_ownership_status(
            $owner->{job_id}, $lifecycle);
        if ($status && !$status->{guard_owner_present} &&
                !$status->{destination_owner_present}) {
            p('Settled the resume owner because its native DCC lifecycle was already absent before unloading.');
            return 1;
        }
        p('Unload found the native DCC already absent but could not settle its durable resume owner.');
        return 0;
    }
    my $candidate = @owned == 1
        ? native_dcc_snapshot($owned[0]) : undef;
    my $same_reserved_tuple = ref($candidate) eq 'HASH' &&
        uc($candidate->{type} // '') eq 'GET' &&
        ($candidate->{lifecycle_identity} // '') eq $lifecycle &&
        ($candidate->{server_tag} // '') eq ($owner->{server_tag} // '') &&
        ((($candidate->{server_identity} // '') eq
            ($owner->{connection_identity} // '')) ||
            (!$candidate->{server_connected} &&
                !length($candidate->{server_identity} // ''))) &&
        ($candidate->{sender_key} // '') eq ($owner->{sender_key} // '') &&
        ($candidate->{filename} // '') eq ($owner->{offered_name} // '') &&
        ($candidate->{address} // '') eq ($owner->{address} // '') &&
        ($candidate->{port} // '') eq ($owner->{port} // '') &&
        ($candidate->{size} // '') eq ($owner->{advertised_size} // '') &&
        !$candidate->{passive};
    unless ($same_reserved_tuple) {
        p('Unload found no unique, exactly matching native resume record; it will not close an ambiguous DCC.');
        return 0;
    }

    my $closed = eval { $owned[0]->destroy(); 1 };
    my $close_error = $@ || '';
    my $after = native_dcc_inventory();
    unless ($closed && ref($after) eq 'ARRAY' && !grep {
            ($_->{lifecycle_identity} // '') eq $lifecycle
        } @$after) {
        $close_error =~ s/[\r\n]+/ /g;
        p('Unload could not confirm destruction of the exact reserved native DCC; cleanup remains unverified. ' .
            safe_field($close_error));
        return 0;
    }

    Irssi::timeout_remove($JOBS{native_resume_guard_release_timer})
        if defined $JOBS{native_resume_guard_release_timer};
    delete $JOBS{native_resume_guard_release_timer};
    resume_guard_release_after_destroy($owner->{job_id}, $lifecycle);
    my $status = resume_guard_ownership_status(
        $owner->{job_id}, $lifecycle);
    if (!$status || $status->{guard_owner_present} ||
            $status->{destination_owner_present}) {
        p('Unload destroyed the reserved native DCC but could not settle its durable owner; cleanup remains unverified.');
        return 0;
    }
    p('Closed and released the exact pending native resume before unloading.');
    return 1;
}

sub native_dcc_snapshot {
    my ($dcc) = @_;
    return unless ref($dcc);
    my $server = $dcc->{server};
    my $path = $dcc->{file};
    my $staging_identity;
    if (defined($path) && length($path)) {
        my @stat = lstat($path);
        if (@stat && S_ISREG($stat[2]) && !S_ISLNK($stat[2])) {
            $staging_identity = {
                device => 0 + $stat[0], inode => 0 + $stat[1],
                size => 0 + $stat[7],
            };
        }
    }
    my $type = uc($dcc->{type} // '');
    return {
        type => $type,
        lifecycle_identity => $type eq 'GET'
            ? (dcc_transfer_identity_key($dcc) // '') : '',
        server_tag => dcc_tag($dcc),
        server_identity => server_connection_identity($server) // '',
        connection_epoch => server_connection_epoch($server) // 0,
        server_connected => $server && $server->{connected} ? 1 : 0,
        sender => $dcc->{nick} // '',
        sender_key => FServe::Transfer::NativeResumeGuard::ascii_nick_key(
            $dcc->{nick}),
        filename => $dcc->{arg},
        address => defined($dcc->{addr}) ? "$dcc->{addr}" : undef,
        port => defined($dcc->{port}) ? "$dcc->{port}" : undef,
        # Irssi 1.4.5's Perl DCC binding omits pasv_id; passive SEND records
        # advertise port zero, so treat that native marker as unsupported.
        passive => defined($dcc->{port}) && "$dcc->{port}" =~ /\A0+\z/ ? 1 : 0,
        size => defined($dcc->{size}) ? "$dcc->{size}" : undef,
        file => defined($path) ? $path : undef,
        staging_identity => $staging_identity,
    };
}

sub native_dcc_inventory {
    my @native;
    my $available = eval {
        require Irssi::Irc;
        @native = Irssi::Irc::dccs();
        die 'native DCC inventory is unbounded' if @native > 10000;
        1;
    };
    return unless $available && !$@;
    return [map { native_dcc_snapshot($_) } @native];
}

sub resume_guard_same_path {
    my ($left, $right) = @_;
    return 0 unless defined($left) && defined($right) &&
        !ref($left) && !ref($right) && length($left) && length($right);
    my ($left_real, $right_real) = (abs_path($left), abs_path($right));
    return defined($left_real) && defined($right_real) &&
        File::Spec->canonpath($left_real) eq File::Spec->canonpath($right_real);
}

sub resume_guard_claim_destination {
    my ($job_id, $lifecycle, $partial_path, $offered_name) = @_;
    return if $DOWNLOAD_PATH_OWNER || !defined($job_id) || !defined($lifecycle) ||
        !defined($partial_path) || !defined($offered_name) ||
        basename($partial_path) ne $offered_name || -l $partial_path;
    my @partial_stat = lstat($partial_path);
    return unless @partial_stat && S_ISREG($partial_stat[2]) && -f _;
    my $directory = abs_path(dirname($partial_path));
    my $partial_real = abs_path($partial_path);
    return unless defined($directory) && defined($partial_real) && -d $directory;
    my $resolved_target = File::Spec->canonpath(
        File::Spec->catfile($directory, $offered_name));
    return unless File::Spec->canonpath($partial_real) eq $resolved_target;
    my $restore_to;
    my $setting_read = eval {
        $restore_to = Irssi::settings_get_str('dcc_download_path');
        1;
    };
    return unless $setting_read && !$@ && defined($restore_to) &&
        !ref($restore_to);
    my $key = identity_key('phase6-native-resume-path', $job_id, $lifecycle);
    # Reserve the file/lifecycle only. The process-wide setting is changed
    # later, around the synchronous native-open operation alone.
    my $claim = {
        key => $key, kind => 'phase6_native_resume', job_id => $job_id,
        lifecycle_identity => $lifecycle, selected_path => $directory,
        destination_path => $partial_real, restore_to => $restore_to,
        override_active => 0, native_opened => 0,
    };
    $DOWNLOAD_PATH_OWNER = $claim;
    return {
        destination_owner_key => $key,
        destination_directory => $directory,
        destination_path => $partial_real,
    };
}

sub resume_guard_verify_destination {
    my ($owner) = @_;
    return 0 unless ref($owner) eq 'HASH' &&
        defined($owner->{destination_owner_key}) &&
        defined($owner->{destination_directory}) &&
        defined($owner->{destination_path}) &&
        defined($owner->{staging_path}) &&
        ref($owner->{staging_identity}) eq 'HASH' &&
        defined($owner->{offered_name}) &&
        basename($owner->{staging_path}) eq $owner->{offered_name};
    my $path_owner = $DOWNLOAD_PATH_OWNER;
    return 0 unless ref($path_owner) eq 'HASH' &&
        ($path_owner->{kind} // '') eq 'phase6_native_resume' &&
        ($path_owner->{key} // '') eq $owner->{destination_owner_key} &&
        ($path_owner->{job_id} // '') eq ($owner->{job_id} // '') &&
        ($path_owner->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '') &&
        !$path_owner->{override_active};
    my $guard = $JOBS{native_resume_guard};
    my $guard_owner = $guard ? $guard->owner() : undef;
    return 0 unless $guard_owner &&
        ($guard_owner->{job_id} // '') eq ($owner->{job_id} // '') &&
        ($guard_owner->{native_lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '');
    my $configured = eval { Irssi::settings_get_str('dcc_download_path') };
    return 0 unless defined($configured) &&
        $configured eq $path_owner->{restore_to};
    return 0 unless resume_guard_same_path(
        $owner->{staging_path}, $owner->{destination_path});
    my $captured = eval {
        FServe::Transfer::Resume::capture_partial(
            path => $owner->{staging_path},
            staging_root => $owner->{staging_root},
            expected_identity => $owner->{staging_identity});
    };
    return 0 unless $captured && !$@ &&
        ($captured->{type} // '') eq 'captured_partial' &&
        ref($captured->{identity}) eq 'HASH' &&
        ($captured->{identity}{device} // '') eq
            ($owner->{staging_identity}{device} // '') &&
        ($captured->{identity}{inode} // '') eq
            ($owner->{staging_identity}{inode} // '') &&
        ($captured->{identity}{size} // '') eq
            ($owner->{requested_offset} // '');
    return 1;
}

# Whether the resume guard and the download path still hold a job's native
# resume, read only: unloading settles a resume only once both have let go.
sub resume_guard_ownership_status {
    my ($job_id, $lifecycle) = @_;
    my $guard = $JOBS{native_resume_guard};
    my $guard_owner = $guard ? $guard->owner() : undef;
    my $path_owner = ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
        ($DOWNLOAD_PATH_OWNER->{kind} // '') eq 'phase6_native_resume'
        ? $DOWNLOAD_PATH_OWNER : undef;
    my $matches = sub {
        my ($owner, $lifecycle_field) = @_;
        return $owner &&
            ($owner->{job_id} // '') eq ($job_id // '') &&
            ($owner->{$lifecycle_field} // '') eq ($lifecycle // '') ? 1 : 0;
    };
    return {
        guard_owner_present => $guard_owner ? 1 : 0,
        guard_owner_matches => $matches->($guard_owner,
            'native_lifecycle_identity'),
        destination_owner_present => $path_owner ? 1 : 0,
        destination_owner_matches => $matches->($path_owner,
            'lifecycle_identity'),
    };
}

sub resume_guard_native_record_matches_destination {
    my ($owner, $record) = @_;
    return 0 unless ref($owner) eq 'HASH' && ref($record) eq 'HASH' &&
        ($record->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '') &&
        resume_guard_same_path($record->{file},
            $owner->{destination_path}) &&
        ref($record->{staging_identity}) eq 'HASH';
    for my $field (qw(device inode)) {
        return 0 unless defined($record->{staging_identity}{$field}) &&
            defined($owner->{staging_identity}{$field}) &&
            "$record->{staging_identity}{$field}" eq
                "$owner->{staging_identity}{$field}";
    }
    return 0 unless defined($record->{staging_identity}{size}) &&
        "$record->{staging_identity}{size}" eq
            ($owner->{requested_offset} // '');
    return 1;
}

sub resume_guard_native_offer_matches_owner {
    my ($owner, $record) = @_;
    return 0 unless ref($owner) eq 'HASH' && ref($record) eq 'HASH' &&
        uc($record->{type} // '') eq 'GET' &&
        ($record->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '') &&
        ($record->{server_tag} // '') eq ($owner->{server_tag} // '') &&
        ($record->{server_identity} // '') eq
            ($owner->{connection_identity} // '') &&
        ($record->{connection_epoch} // -1) ==
            ($owner->{connection_epoch} // -2) &&
        $record->{server_connected} &&
        ($record->{sender_key} // '') eq
            FServe::Transfer::NativeResumeGuard::ascii_nick_key(
                $owner->{sender}) &&
        defined($record->{filename}) &&
            $record->{filename} eq ($owner->{offered_name} // '') &&
        defined($record->{address}) &&
            $record->{address} eq ($owner->{address} // '') &&
        defined($record->{port}) &&
            $record->{port} eq ($owner->{port} // '') &&
        defined($record->{size}) &&
            $record->{size} eq ($owner->{advertised_size} // '') &&
        !$record->{passive};
    my $file = $record->{file};
    if (!defined($file) || !length($file)) {
        return ref($record->{staging_identity}) ne 'HASH';
    }
    return resume_guard_native_record_matches_destination(
        $owner, $record);
}

sub resume_guard_native_lookup_port {
    my ($port) = @_;
    return unless defined($port) && !ref($port) && $port =~ /\A[0-9]+\z/;
    $port =~ s/\A0+(?=[0-9])//;
    return $port;
}

sub resume_guard_preflight_native_open {
    my ($owner) = @_;
    return 0 unless ref($owner) eq 'HASH' &&
        resume_guard_verify_destination($owner);
    my $guard = $JOBS{native_resume_guard};
    my $current_owner = $guard ? $guard->owner() : undef;
    return 0 unless $current_owner &&
        ($current_owner->{job_id} // '') eq ($owner->{job_id} // '') &&
        ($current_owner->{native_lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '') &&
        ($current_owner->{state} // '') eq 'negotiating' &&
        !$current_owner->{accepted} && !$current_owner->{native_open_attempted};
    my $now = eval { monotonic_now() };
    return 0 unless defined($now) && !ref($now) && $now =~
        /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ &&
        defined($owner->{deadline}) && $owner->{deadline} > $now;
    my $inventory = native_dcc_inventory();
    return 0 unless ref($inventory) eq 'ARRAY';
    my @owned = grep {
        ($_->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '')
    } @$inventory;
    return 0 unless @owned == 1 &&
        resume_guard_native_offer_matches_owner($owner, $owned[0]);
    my $sender_key = FServe::Transfer::NativeResumeGuard::ascii_nick_key(
        $owner->{sender}) // '';
    my $owner_port = resume_guard_native_lookup_port($owner->{port});
    return 0 unless defined $owner_port;
    for my $record (@$inventory) {
        next unless ref($record) eq 'HASH' &&
            uc($record->{type} // '') eq 'GET';
        my $record_port = resume_guard_native_lookup_port(
            $record->{port});
        return 0 unless defined($record->{sender_key}) &&
            defined($record->{filename}) && defined($record_port);
        next if ($record->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '');
        next unless $record->{sender_key} eq $sender_key;
        return 0 if $record->{filename} eq $owner->{offered_name} ||
            $record_port eq $owner_port;
    }
    return 1;
}

sub resume_guard_restore_temporary_destination {
    my ($path_owner) = @_;
    return 0 unless ref($path_owner) eq 'HASH' &&
        ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
        ($DOWNLOAD_PATH_OWNER->{key} // '') eq ($path_owner->{key} // '');
    my $current = eval { Irssi::settings_get_str('dcc_download_path') };
    return 0 unless defined $current;
    if ($current eq ($path_owner->{restore_to} // "\0")) {
        $path_owner->{override_active} = 0;
        delete $path_owner->{restore_pending};
        delete $path_owner->{destination_restore_pending};
        return 1;
    }
    if (!defined($path_owner->{selected_setting}) ||
            $current ne $path_owner->{selected_setting}) {
        # Another setting change is external state; preserve it rather than
        # overwriting it with the value captured at reservation time.
        $path_owner->{override_active} = 0;
        $path_owner->{external_setting_preserved} = 1;
        delete $path_owner->{restore_pending};
        delete $path_owner->{destination_restore_pending};
        return 1;
    }
    my $restore_to = $path_owner->{restore_to};
    return 0 unless defined $restore_to;
    eval { Irssi::settings_set_str('dcc_download_path', $restore_to); 1 };
    my $restored = eval { Irssi::settings_get_str('dcc_download_path') };
    if (defined($restored) && $restored eq $restore_to) {
        $path_owner->{override_active} = 0;
        delete $path_owner->{selected_setting};
        delete $path_owner->{restore_pending};
        delete $path_owner->{destination_restore_pending};
        return 1;
    }
    $path_owner->{override_active} = 1;
    $path_owner->{restore_pending} = 1;
    return 0;
}

sub resume_guard_restore_owned_setting {
    my ($path_owner) = @_;
    return 0 unless ref($path_owner) eq 'HASH' &&
        ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
        ($DOWNLOAD_PATH_OWNER->{key} // '') eq ($path_owner->{key} // '');
    if ($path_owner->{override_active}) {
        return 0 unless resume_guard_restore_temporary_destination(
            $path_owner);
    }
    return 1 unless $path_owner->{restore_on_unload};

    my $current = eval { Irssi::settings_get_str('dcc_download_path') };
    return 0 unless defined $current;
    my $restore_to = $path_owner->{restore_to};
    if (defined($restore_to) && $current eq $restore_to) {
        delete $path_owner->{restore_on_unload};
        delete $path_owner->{restore_if_current};
        delete $path_owner->{destination_restore_pending};
        return 1;
    }
    if (!defined($path_owner->{restore_if_current}) ||
            $current ne $path_owner->{restore_if_current}) {
        # Preserve a setting changed by the user after the session stopped.
        $path_owner->{external_setting_preserved} = 1;
        delete $path_owner->{restore_on_unload};
        delete $path_owner->{restore_if_current};
        delete $path_owner->{destination_restore_pending};
        return 1;
    }

    return 0 unless defined $restore_to;
    eval { Irssi::settings_set_str('dcc_download_path', $restore_to); 1 };
    my $restored = eval { Irssi::settings_get_str('dcc_download_path') };
    if (defined($restored) && $restored eq $restore_to) {
        delete $path_owner->{restore_on_unload};
        delete $path_owner->{restore_if_current};
        delete $path_owner->{destination_restore_pending};
        return 1;
    }
    $path_owner->{destination_restore_pending} = 1;
    return 0;
}

sub schedule_resume_guard_destination_restore {
    my ($owner, $delay_ms) = @_;
    return unless ref($owner) eq 'HASH' &&
        !$JOBS{native_resume_guard_destination_restore_timer} &&
        ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
        ($DOWNLOAD_PATH_OWNER->{key} // '') eq
            ($owner->{destination_owner_key} // '');
    my $timer = eval {
        Irssi::timeout_add_once($delay_ms // 25, sub {
            delete $JOBS{native_resume_guard_destination_restore_timer};
            my $path_owner = $DOWNLOAD_PATH_OWNER;
            return unless ref($path_owner) eq 'HASH' &&
                ($path_owner->{key} // '') eq
                    ($owner->{destination_owner_key} // '');
            my $restored = eval {
                resume_guard_restore_owned_setting(
                    $path_owner);
            } ? 1 : 0;
            unless ($restored) {
                $path_owner->{destination_restore_pending} = 1;
                $path_owner->{restore_pending} = 1;
            }
            if ($restored) {
                delete $path_owner->{restore_pending};
                delete $path_owner->{destination_restore_pending};
                delete $JOBS{native_resume_guard_destination_restore_attempts};
                if ($path_owner->{release_after_restore}) {
                    delete $path_owner->{release_after_restore};
                    resume_guard_release_after_destroy(
                        $owner->{job_id}, $owner->{native_lifecycle_identity});
                }
                return;
            }
            my $attempts = $JOBS{native_resume_guard_destination_restore_attempts} // 0;
            if ($attempts < 20) {
                $JOBS{native_resume_guard_destination_restore_attempts} = $attempts + 1;
                schedule_resume_guard_destination_restore($owner, 25);
            } else {
                p('Native resume keeps its destination owner because Irssi has not confirmed restoration of dcc_download_path; new DCC SEND offers remain stopped.');
            }
        }, undef);
    };
    if (defined($timer) && !ref($timer) && $timer =~ /\A[1-9][0-9]*\z/) {
        $JOBS{native_resume_guard_destination_restore_timer} = $timer;
        return 1;
    }
    p('Native resume keeps its destination owner because a setting-restoration retry could not be scheduled.');
    return 0;
}

sub resume_guard_open_native_destination {
    my ($owner, $operation) = @_;
    return { type => 'refusal', reason => 'native resume destination or operation is missing' }
        unless ref($owner) eq 'HASH' && ref($operation) eq 'CODE';
    return { type => 'refusal', reason => 'native resume reservation failed fresh dispatch validation' }
        unless resume_guard_preflight_native_open($owner);
    my $guard = $JOBS{native_resume_guard};
    my $dispatch = $guard->begin_native_open(
        job_id => $owner->{job_id},
        native_lifecycle_identity => $owner->{native_lifecycle_identity});
    return { type => 'refusal', reason => 'native resume dispatch permission was already consumed' }
        unless $dispatch;
    my $path_owner = $DOWNLOAD_PATH_OWNER;
    delete $path_owner->{external_setting_preserved};
    $path_owner->{override_active} = 1;
    $path_owner->{selected_setting} = $owner->{destination_directory};
    my $write_ok = eval {
        Irssi::settings_set_str('dcc_download_path',
            $owner->{destination_directory});
        1;
    };
    my $selected_value = eval {
        Irssi::settings_get_str('dcc_download_path');
    };
    my $selected = $write_ok && defined($selected_value) &&
        resume_guard_same_path($selected_value,
            $owner->{destination_directory});
    $path_owner->{selected_setting} = $selected_value
        if defined($selected_value) &&
            ($selected || $selected_value eq $owner->{destination_directory});
    unless ($selected && !$@) {
        $path_owner->{restore_pending} = 1;
        unless (resume_guard_restore_temporary_destination(
                $path_owner)) {
            schedule_resume_guard_destination_restore($owner);
        }
        return { type => 'refusal', reason => 'native resume destination setting could not be selected' };
    }

    my $operation_ok = eval { $operation->(); 1 };
    my $operation_error = $@;
    $operation_error =~ s/[\r\n]+/ /g if defined $operation_error;
    my $opened = 0;
    my $inspection_ok = eval {
        my $inventory = native_dcc_inventory();
        my @lifecycle = ref($inventory) eq 'ARRAY' ? grep {
            ($_->{lifecycle_identity} // '') eq
                ($owner->{native_lifecycle_identity} // '')
        } @$inventory : ();
        $opened = @lifecycle == 1 &&
            resume_guard_native_record_matches_destination(
                $owner, $lifecycle[0]) ? 1 : 0;
        1;
    };
    if (!$inspection_ok) {
        my $inspection_error = $@ || 'native DCC inventory inspection failed';
        $inspection_error =~ s/[\r\n]+/ /g;
        $operation_error = join('; ', grep { defined($_) && length($_) }
            ($operation_error, $inspection_error));
    }
    $path_owner->{native_opened} = 1
        if $operation_ok && $inspection_ok && $opened;
    my $restored = eval {
        resume_guard_restore_temporary_destination($path_owner);
    } ? 1 : 0;
    unless ($restored) {
        $path_owner->{override_active} = 1;
        $path_owner->{restore_pending} = 1;
    }
    schedule_resume_guard_destination_restore($owner) unless $restored;
    return {
        type => $operation_ok && $inspection_ok && $opened && $restored
            ? 'opened' : 'attention',
        command_invoked => 1,
        native_opened => $opened ? 1 : 0,
        setting_restored => $restored ? 1 : 0,
        error => $operation_error,
    };
}

sub resume_guard_opened_destination_record {
    my ($owner, $inventory) = @_;
    return unless ref($owner) eq 'HASH' &&
        ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
        ($DOWNLOAD_PATH_OWNER->{kind} // '') eq 'phase6_native_resume' &&
        ($DOWNLOAD_PATH_OWNER->{key} // '') eq
            ($owner->{destination_owner_key} // '') &&
        ($DOWNLOAD_PATH_OWNER->{job_id} // '') eq ($owner->{job_id} // '') &&
        ($DOWNLOAD_PATH_OWNER->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '') &&
        $DOWNLOAD_PATH_OWNER->{native_opened} &&
        !$DOWNLOAD_PATH_OWNER->{override_active};
    my $guard = $JOBS{native_resume_guard};
    my $guard_owner = $guard ? $guard->owner() : undef;
    return unless $guard_owner &&
        ($guard_owner->{job_id} // '') eq ($owner->{job_id} // '') &&
        ($guard_owner->{native_lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '');
    $inventory = native_dcc_inventory() unless @_ > 1;
    return unless ref($inventory) eq 'ARRAY';
    my @lifecycle = grep {
        ($_->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '')
    } @$inventory;
    return unless @lifecycle == 1 &&
        resume_guard_native_record_matches_destination(
            $owner, $lifecycle[0]);
    return $lifecycle[0];
}

sub resume_guard_release_destination {
    my ($owner) = @_;
    return 0 unless ref($owner) eq 'HASH' &&
        ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
        ($DOWNLOAD_PATH_OWNER->{kind} // '') eq 'phase6_native_resume' &&
        ($DOWNLOAD_PATH_OWNER->{key} // '') eq
            ($owner->{destination_owner_key} // '') &&
        ($DOWNLOAD_PATH_OWNER->{job_id} // '') eq ($owner->{job_id} // '') &&
        ($DOWNLOAD_PATH_OWNER->{lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '');
    if ($DOWNLOAD_PATH_OWNER->{override_active} ||
            $DOWNLOAD_PATH_OWNER->{restore_on_unload}) {
        $DOWNLOAD_PATH_OWNER->{release_after_restore} = 1;
        unless (resume_guard_restore_owned_setting(
                $DOWNLOAD_PATH_OWNER)) {
            schedule_resume_guard_destination_restore($owner);
            return 0;
        }
    }
    undef $DOWNLOAD_PATH_OWNER;
    return 1;
}

sub resume_guard_reserve_owner {
    my ($job_id, $dcc, $requested_offset, $deadline) = @_;
    return unless defined($job_id) && jobs_ready() &&
        load_job_modules();
    my $job = $JOBS{coordinator}->job($job_id);
    my $server = ref($dcc) ? $dcc->{server} : undef;
    my $partial = $job ? $job->{partial} : undef;
    my $server_key = defined($server) ? server_connection_identity($server) : undef;
    my $lifecycle = dcc_transfer_identity_key($dcc);
    my $candidate = native_dcc_snapshot($dcc);
    my $inventory = native_dcc_inventory();
    unless ($job && $job->{state} eq 'resume_pending' &&
            ($job->{context}{process_incarnation} // '') eq $PROCESS_INCARNATION &&
            job_is_on_connection($job, $server) &&
            ref($partial) eq 'HASH' &&
            ($partial->{digest_status} // '') eq 'sealed' &&
            ref($partial->{file_identity}) eq 'HASH' &&
            defined($partial->{path}) &&
            defined($requested_offset) && $requested_offset =~ /\A[1-9][0-9]*\z/ &&
            $requested_offset == ($partial->{size} // -1) &&
            defined($partial->{total_size}) && $partial->{total_size} =~ /\A[1-9][0-9]*\z/ &&
            $requested_offset < $partial->{total_size} &&
            defined($deadline) && $deadline =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ &&
            defined($server_key) && defined($lifecycle) && $candidate &&
            ref($inventory) eq 'ARRAY') {
        return;
    }
    my $partial_check = eval {
        FServe::Transfer::Resume::capture_partial(
            path => $partial->{path},
            staging_root => $partial->{staging_root},
            expected_identity => $partial->{file_identity});
    };
    unless ($partial_check && !$@ &&
            ($partial_check->{type} // '') eq 'captured_partial' &&
            ref($partial_check->{identity}) eq 'HASH' &&
            ($partial_check->{identity}{device} // '') eq
                ($partial->{file_identity}{device} // '') &&
            ($partial_check->{identity}{inode} // '') eq
                ($partial->{file_identity}{inode} // '') &&
            ($partial_check->{identity}{size} // '') eq "$requested_offset") {
        return;
    }
    my $selection = $job->{selection} || {};
    my $sender = $selection->{expected_peer} // $selection->{sender} // '';
    my $offered_name = $partial->{offered_basename} // '';
    my $stage = $candidate->{staging_identity};
    my $native_file = $candidate->{file};
    my $native_file_uninitialized = !defined($native_file) || !length($native_file);
    unless (uc($dcc->{type} // '') eq 'GET' && $server->{connected} &&
            $candidate->{filename} eq $offered_name &&
            $candidate->{sender_key} eq
                FServe::Transfer::NativeResumeGuard::ascii_nick_key($sender) &&
            $candidate->{size} == $partial->{total_size} &&
            ($native_file_uninitialized
                ? ref($stage) ne 'HASH'
                : File::Spec->canonpath(File::Spec->rel2abs($native_file)) eq
                    File::Spec->canonpath(File::Spec->rel2abs($partial->{path})) &&
                    ref($stage) eq 'HASH' &&
                    $stage->{device} == ($partial->{file_identity}{device} // -1) &&
                    $stage->{inode} == ($partial->{file_identity}{inode} // -1) &&
                    $stage->{size} == $requested_offset) &&
            !$candidate->{passive} &&
            "$candidate->{port}" =~ /\A[1-9][0-9]*\z/) {
        return;
    }

    my $owner = {
        job_id => $job_id,
        process_incarnation => $PROCESS_INCARNATION,
        connection_identity => $server_key,
        connection_epoch => server_connection_epoch($server),
        server_tag => dcc_tag($dcc),
        sender => $sender,
        casemapping => job_casemapping($job, $server),
        offered_name => $offered_name,
        address => $candidate->{address},
        port => $candidate->{port},
        advertised_size => $candidate->{size},
        staging_path => $partial->{path},
        staging_identity => $partial->{file_identity},
        requested_offset => $requested_offset,
        deadline => $deadline,
        native_lifecycle_identity => $lifecycle,
        target_nick => $server->{nick} // '',
        passive => 0,
        staging_root => $partial->{staging_root},
    };
    my $destination = resume_guard_claim_destination(
        $job_id, $lifecycle, $partial->{path}, $offered_name);
    unless ($destination) {
        p('Native resume guard refused reservation because the staging destination is already owned or cannot be selected safely.');
        return;
    }
    @{$owner}{qw(destination_owner_key destination_directory destination_path)} =
        @{$destination}{qw(destination_owner_key destination_directory destination_path)};
    my $reserved = eval {
        $JOBS{native_resume_guard}->reserve_owner(
            owner => $owner, candidate => $candidate,
            pending => $inventory, now => monotonic_now());
    };
    unless ($reserved && !$@) {
        my $error = $@ || 'native DCC ownership could not be made unique';
        $error =~ s/[\r\n]+/ /g;
        unless (resume_guard_release_destination($owner)) {
            p('Native resume reservation failed, and its download-path ownership remains retained because restoration or release could not be confirmed.');
        }
        p("Native resume guard refused to reserve this DCC lifecycle: $error.");
        return;
    }
    unless (resume_guard_verify_destination($reserved)) {
        $JOBS{native_resume_guard}->clear_owner(
            job_id => $job_id, native_lifecycle_identity => $lifecycle);
        unless (resume_guard_release_destination($reserved)) {
            p('Native resume destination ownership remains retained because cleanup could not be confirmed after destination revalidation failed.');
        }
        p('Native resume guard cleared its reservation because staging destination ownership could not be revalidated.');
        return;
    }
    delete $JOBS{native_resume_guard_release_attempts};
    return $reserved;
}

sub sig_phase6_pre_native_dcc_send {
    my ($server, $data, $nick) = @_;
    my $path_owner = $DOWNLOAD_PATH_OWNER;
    if (ref($path_owner) eq 'HASH' &&
            ($path_owner->{kind} // '') eq 'phase6_native_resume' &&
            ($path_owner->{override_active} ||
             $path_owner->{destination_restore_pending})) {
        p('Stopped DCC SEND before native parsing because the resume destination setting has not been restored.');
        Irssi::signal_stop();
        return;
    }
    my $guard = $JOBS{native_resume_guard};
    return unless $guard && $guard->active();
    my $decision = $guard->incoming_send(sender => $nick, data => $data,
        connection_identity => server_connection_identity($server) // '',
        connection_epoch => server_connection_epoch($server) // 0);
    return unless ($decision->{action} // '') eq 'stop';
    p('Stopped a competing DCC SEND before Irssi native parsing: ' .
        safe_field($decision->{reason}));
    Irssi::signal_stop();
}

sub sig_phase6_pre_native_dcc_accept {
    my ($server, $data, $nick, $address, $target, $chat) = @_;
    my $guard = $JOBS{native_resume_guard};
    return unless $guard && $guard->active();
    my $owner = $guard->owner();
    my $native_inventory = $owner ? native_dcc_inventory() : undef;
    my $native_record = $owner && ref($native_inventory) eq 'ARRAY'
        ? resume_guard_opened_destination_record($owner, $native_inventory)
        : undef;
    my $decision = $guard->incoming_accept(
        sender => $nick, data => $data, chat => $chat,
        server_identity => server_connection_identity($server) // '',
        connection_epoch => server_connection_epoch($server) // 0,
        server_connected => $server && $server->{connected} ? 1 : 0,
        target_key => FServe::Transfer::NativeResumeGuard::ascii_nick_key($target),
        sender_key => FServe::Transfer::NativeResumeGuard::ascii_nick_key($nick),
        native_record => $native_record,
        native_inventory => $native_inventory,
        now => eval { monotonic_now() },
    );
    return unless ($decision->{action} // '') eq 'stop';
    p('Stopped an uncorrelated DCC ACCEPT before Irssi native parsing: ' .
        safe_field($decision->{reason}));
    Irssi::signal_stop();
}

sub schedule_resume_guard_release {
    my ($owner, $delay_ms) = @_;
    return unless ref($owner) eq 'HASH' &&
        $JOBS{native_resume_guard} &&
        !$JOBS{native_resume_guard_release_timer};
    my $timer = eval {
        Irssi::timeout_add_once($delay_ms // 10, sub {
            delete $JOBS{native_resume_guard_release_timer};
            resume_guard_release_after_destroy($owner->{job_id},
                $owner->{native_lifecycle_identity});
        }, undef);
    };
    if (defined($timer) && !ref($timer) && $timer =~ /\A[1-9][0-9]*\z/) {
        $JOBS{native_resume_guard_release_timer} = $timer;
        return 1;
    }
    p('Native resume owner remains reserved because its post-destruction release timer could not be registered.');
    return 0;
}

sub resume_guard_release_after_destroy {
    my ($job_id, $lifecycle) = @_;
    my $guard = $JOBS{native_resume_guard} or return;
    my $owner = $guard->owner() or return;
    return unless ($owner->{job_id} // '') eq ($job_id // '') &&
        ($owner->{native_lifecycle_identity} // '') eq ($lifecycle // '');
    return if $TRANSFERS{$lifecycle};
    my $inventory = native_dcc_inventory();
    unless (ref($inventory) eq 'ARRAY') {
        my $attempts = $JOBS{native_resume_guard_release_attempts} // 0;
        if ($attempts < 20) {
            $JOBS{native_resume_guard_release_attempts} = $attempts + 1;
            schedule_resume_guard_release($owner, 25);
        } else {
            p('Native resume owner remains reserved because Irssi DCC lifecycle state could not be inspected after destruction.');
        }
        return;
    }
    if (grep {
        ($_->{lifecycle_identity} // '') eq $lifecycle
    } @$inventory) {
        my $attempts = $JOBS{native_resume_guard_release_attempts} // 0;
        if ($attempts < 20) {
            $JOBS{native_resume_guard_release_attempts} = $attempts + 1;
            schedule_resume_guard_release($owner, 25);
        } else {
            p('Native resume owner remains reserved because its DCC lifecycle is still present after destruction.');
        }
        return;
    }
    delete $JOBS{native_resume_guard_release_attempts};
    my $job = jobs_ready() ? $JOBS{coordinator}->job($job_id) : undef;
    unless ($job) {
        p('Native resume owner remains reserved because its durable job outcome is unavailable.');
        return;
    }
    if ($job->{state} =~ /\A(?:receiving|resume_pending)\z/) {
        my $recorded = job_transition($job_id, 'needs_attention',
            outcome => 'native_resume_destroyed_without_bound_transfer',
            reason => 'native resume DCC was destroyed without an application receive binding; inspect the staged partial before retrying');
        $job = $recorded ? $JOBS{coordinator}->job($job_id) : undef;
        if ($recorded && $JOBS{run_batch} &&
                ($JOBS{run_batch}{current_job_id} // '') eq $job_id) {
            my $run = $JOBS{run_batch};
            $run->{paused_for_attention} = 1;
            $JOBS{paused} = 1;
            $run->{current_job_id} = undef;
            $run->{waiting_manifest} = undef;
            $run->{waiting_crawl} = undef;
            Irssi::timeout_remove($run->{advance_timer})
                if defined $run->{advance_timer};
            delete $run->{advance_timer};
        }
    }
    unless ($job && $job->{state} !~ /\A(?:receiving|resume_pending)\z/) {
        p('Native resume owner remains reserved because its durable transfer outcome is not recorded.');
        return;
    }
    if ($job->{state} eq 'interrupted') {
        my $partial = $job->{partial};
        unless (ref($partial) eq 'HASH' && $partial->{writer_closed}) {
            p('Native resume owner remains reserved because closed-writer evidence is missing.');
            return;
        }
    }
    unless (resume_guard_release_destination($owner)) {
        p('Native resume owner remains reserved because download destination ownership could not be restored safely.');
        return;
    }
    $guard->clear_owner(job_id => $job_id,
        native_lifecycle_identity => $lifecycle);
    delete $JOBS{native_resume_guard_release_attempts};
}

1;
