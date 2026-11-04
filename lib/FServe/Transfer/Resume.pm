package FServe::Transfer::Resume;

use strict;
use warnings;
use Exporter qw(import);
use Cwd qw(abs_path);
use Digest::SHA ();
use Errno qw(EEXIST);
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL S_ISDIR S_ISLNK S_ISREG);
use File::Spec;
use JSON::PP ();
use Scalar::Util qw(refaddr weaken);
use Time::HiRes ();

our @EXPORT_OK = qw(capture_partial begin_partial_seal step_partial_seal
    cancel_partial_seal begin_partial_validation step_partial_validation
    cancel_partial_validation discard_partial_snapshot validate_partial
    begin_resumed_file_verification step_resumed_file_verification
    cancel_resumed_file_verification consume_resumed_file_verification
    resume_decision capability_profile);

my $SNAPSHOT_SEQUENCE = 0;
my %RESUME_VERIFICATION_RECEIPTS;
my $MAX_RESUME_VERIFICATION_RECEIPTS = 256;

sub _clone_resume_verification_record {
    my ($record) = @_;
    my $json = JSON::PP->new->canonical(1)->utf8(1);
    return $json->decode($json->encode($record));
}

sub _prune_abandoned_resume_verification_receipts {
    for my $address (keys %RESUME_VERIFICATION_RECEIPTS) {
        my $entry = $RESUME_VERIFICATION_RECEIPTS{$address};
        delete $RESUME_VERIFICATION_RECEIPTS{$address}
            unless ref($entry) eq 'HASH' && ref($entry->{receipt}) &&
                defined(refaddr($entry->{receipt})) &&
                refaddr($entry->{receipt}) == $address;
    }
}

sub _issue_resume_verification_receipt {
    my ($record) = @_;
    _prune_abandoned_resume_verification_receipts();
    return if keys(%RESUME_VERIFICATION_RECEIPTS) >=
        $MAX_RESUME_VERIFICATION_RECEIPTS;
    my $receipt = bless {}, 'FServe::Transfer::Resume::VerificationReceipt';
    my $address = refaddr($receipt);
    return unless defined $address;
    my $entry = $RESUME_VERIFICATION_RECEIPTS{$address} = {
        receipt => $receipt,
        record => _clone_resume_verification_record($record),
    };
    weaken($entry->{receipt});
    return $receipt;
}

sub consume_resumed_file_verification {
    my ($result) = @_;
    return { type => 'refusal', reason => 'verified resumed-file result is malformed' }
        unless ref($result) eq 'HASH' &&
            ($result->{type} // '') eq 'verified_resumed_file' &&
            ref($result->{verification_receipt}) eq
                'FServe::Transfer::Resume::VerificationReceipt';
    my $receipt = $result->{verification_receipt};
    my $address = refaddr($receipt);
    my $entry = defined($address)
        ? delete($RESUME_VERIFICATION_RECEIPTS{$address}) : undef;
    return { type => 'refusal', reason => 'verified resumed-file receipt is invalid or already consumed' }
        unless ref($entry) eq 'HASH' && ref($entry->{receipt}) &&
            refaddr($entry->{receipt}) == $address &&
            ref($entry->{record}) eq 'HASH';
    return { type => 'consumed_resume_verification',
        verification => _clone_resume_verification_record($entry->{record}) };
}

sub capability_profile {
    my (%args) = @_;
    return {
        supported => 0,
        name => 'irssi-1.4.5-unverified',
        reason => $args{reason} // 'native RESUME offer binding and exact offset semantics have not passed the isolated capability probe',
    };
}

sub _identity_from_stat {
    my ($stat) = @_;
    return {
        device => 0 + $stat->[0], inode => 0 + $stat->[1],
        mode => 0 + $stat->[2], links => 0 + $stat->[3],
        size => 0 + $stat->[7], mtime => 0 + $stat->[9],
        ctime => 0 + $stat->[10],
    };
}

sub _identity_matches {
    my ($left, $right) = @_;
    return 0 unless ref($left) eq 'HASH' && ref($right) eq 'HASH';
    for my $field (qw(device inode mode links size mtime ctime)) {
        return 0 unless defined($left->{$field}) && defined($right->{$field}) &&
            $left->{$field} eq $right->{$field};
    }
    return 1;
}

sub _directory_identity {
    my ($stat) = @_;
    return { device => 0 + $stat->[0], inode => 0 + $stat->[1],
        mode => 0 + $stat->[2] };
}

sub _directory_chain_to {
    my ($directory) = @_;
    my ($volume, $directories) = File::Spec->splitpath($directory, 1);
    my $cursor = File::Spec->catpath($volume, File::Spec->rootdir(), '');
    my @anchor = lstat($cursor);
    return unless @anchor && S_ISDIR($anchor[2]) && !S_ISLNK($anchor[2]);
    my @identities = (_directory_identity(\@anchor));
    my @parts = grep { length($_) && $_ ne File::Spec->curdir() }
        File::Spec->splitdir($directories);
    for my $part (@parts) {
        $cursor = File::Spec->catdir($cursor, $part);
        my @stat = lstat($cursor);
        return unless @stat && S_ISDIR($stat[2]) && !S_ISLNK($stat[2]);
        push @identities, _directory_identity(\@stat);
    }
    return \@identities;
}

sub _directory_chain_matches {
    my ($expected, $current) = @_;
    return 0 unless ref($expected) eq 'ARRAY' && ref($current) eq 'ARRAY' &&
        @$expected == @$current;
    for my $index (0 .. $#$expected) {
        return 0 unless ref($expected->[$index]) eq 'HASH' &&
            ref($current->[$index]) eq 'HASH';
        for my $field (qw(device inode mode)) {
            return 0 unless defined($expected->[$index]{$field}) &&
                defined($current->[$index]{$field}) &&
                $expected->[$index]{$field} eq $current->[$index]{$field};
        }
    }
    return 1;
}

sub _owned_path_info {
    my (%args) = @_;
    my ($path, $root) = @args{qw(path staging_root)};
    return { type => 'refusal', reason => 'partial path or owned staging root is missing' }
        unless defined($path) && length($path) && defined($root) && length($root);

    my $root_abs = File::Spec->canonpath(File::Spec->rel2abs($root));
    my $path_abs = File::Spec->canonpath(File::Spec->rel2abs($path));
    my $directory_identities = _directory_chain_to($root_abs);
    return { type => 'refusal', reason => 'owned staging root or one of its ancestors is missing, linked, or not a directory' }
        unless $directory_identities && @$directory_identities;
    my $root_real = abs_path($root_abs);
    return { type => 'refusal', reason => 'owned staging root cannot be resolved' }
        unless defined($root_real) && length($root_real);
    my $root_directory_identities = [ map { +{%$_} } @$directory_identities ];

    my $relative = File::Spec->abs2rel($path_abs, $root_abs);
    return { type => 'refusal', reason => 'partial path is outside its owned staging root' }
        if File::Spec->file_name_is_absolute($relative) ||
            grep { $_ eq File::Spec->updir() } File::Spec->splitdir($relative);
    my @parts = File::Spec->splitdir($relative);
    return { type => 'refusal', reason => 'partial path does not name a file under its staging root' }
        unless @parts && !grep { $_ eq '' || $_ eq File::Spec->curdir() } @parts;

    my $cursor = $root_abs;
    my @path_lstat;
    for my $index (0 .. $#parts) {
        $cursor = File::Spec->catfile($cursor, $parts[$index]);
        my @component = lstat($cursor);
        return { type => 'refusal', reason => 'partial path component is missing or is a symbolic link' }
            unless @component && !S_ISLNK($component[2]);
        if ($index == $#parts) {
            @path_lstat = @component;
            return { type => 'refusal', reason => 'partial path is not a regular file' }
                unless S_ISREG($component[2]);
        } else {
            return { type => 'refusal', reason => 'partial parent component is not a directory' }
                unless S_ISDIR($component[2]);
            push @$directory_identities, _directory_identity(\@component);
        }
    }

    my $path_real = abs_path($path_abs);
    return { type => 'refusal', reason => 'partial path cannot be resolved beneath its owned staging root' }
        unless defined($path_real) && length($path_real);
    my $real_relative = File::Spec->abs2rel($path_real, $root_real);
    return { type => 'refusal', reason => 'partial path resolves outside its owned staging root' }
        if File::Spec->file_name_is_absolute($real_relative) ||
            grep { $_ eq File::Spec->updir() } File::Spec->splitdir($real_relative);

    return {
        type => 'owned_path', path_abs => $path_abs, root_abs => $root_abs,
        path => $path_real, staging_root => $root_real,
        path_lstat => \@path_lstat,
        root_directory_identities => $root_directory_identities,
        directory_identities => $directory_identities,
    };
}

sub _open_owned_partial {
    my (%args) = @_;
    my $location = _owned_path_info(%args);
    return $location unless $location->{type} eq 'owned_path';
    return { type => 'refusal', reason => 'owned staging root or parent directory changed' }
        if exists($args{expected_directory_identities}) &&
            !_directory_chain_matches($args{expected_directory_identities},
                $location->{directory_identities});

    my $no_follow = eval { Fcntl::O_NOFOLLOW() };
    return { type => 'refusal', reason => 'platform cannot open partial files without following symbolic links' }
        unless defined $no_follow;
    sysopen(my $fh, $location->{path_abs}, O_RDONLY | $no_follow)
        or return { type => 'refusal', reason => 'partial file cannot be opened without following symbolic links' };
    binmode($fh, ':raw') or do { close $fh; return { type => 'refusal', reason => 'partial file cannot be read in binary mode' }; };
    my @opened = Time::HiRes::stat($fh);
    unless (@opened && S_ISREG($opened[2]) && $opened[3] == 1 &&
            $opened[0] == $location->{path_lstat}[0] &&
            $opened[1] == $location->{path_lstat}[1]) {
        close $fh;
        return { type => 'refusal', reason => 'partial file identity changed or is shared by another path' };
    }

    return { %$location, type => 'opened_partial', fh => $fh,
        identity => _identity_from_stat(\@opened) };
}

sub _create_validation_snapshot {
    my (%args) = @_;
    my ($root, $expected_directories) = @args{qw(staging_root root_directory_identities)};
    my $current_directories = _directory_chain_to($root);
    return { type => 'refusal', reason => 'owned staging root changed before snapshot creation' }
        unless _directory_chain_matches($expected_directories, $current_directories);

    for (1 .. 32) {
        my $sequence = ++$SNAPSHOT_SEQUENCE;
        my $nonce = sprintf('%08x', int(rand(2_147_483_647)));
        my $name = ".fserve-resume-validate-$$-$sequence-$nonce";
        my $path = File::Spec->catfile($root, $name);
        my $old_umask = umask(0077);
        my $created = sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL, 0600);
        my $open_error = 0 + $!;
        umask($old_umask);
        unless ($created) {
            $! = $open_error;
            next if $! == EEXIST;
            return { type => 'refusal', reason => 'private validation snapshot cannot be exclusively created' };
        }
        unless (binmode($fh, ':raw')) {
            my @identity_stat = Time::HiRes::stat($fh);
            @identity_stat = lstat($path) unless @identity_stat;
            close $fh;
            my $removed = _remove_validation_snapshot({
                snapshot_path => $path, staging_root => $root,
                snapshot_identity => @identity_stat
                    ? _identity_from_stat(\@identity_stat) : undef,
                snapshot_directory_identities => $expected_directories,
            });
            my $reason = 'private validation snapshot cannot be opened in binary mode';
            $reason .= '; incomplete snapshot could not be safely removed' unless $removed;
            return { type => 'refusal', reason => $reason,
                snapshot_removed => $removed ? 1 : 0 };
        }
        my @opened = Time::HiRes::stat($fh);
        my @path_stat = lstat($path);
        unless (@opened && @path_stat && S_ISREG($opened[2]) &&
                !S_ISLNK($path_stat[2]) && $opened[3] == 1 &&
                $opened[0] == $path_stat[0] && $opened[1] == $path_stat[1] &&
                $opened[7] == 0 && ($opened[2] & 0777) == 0600) {
            close $fh;
            my $identity_stat = @opened ? \@opened : \@path_stat;
            my $cleanup = { snapshot_path => $path, staging_root => $root,
                snapshot_identity => @$identity_stat
                    ? _identity_from_stat($identity_stat) : undef,
                snapshot_directory_identities => $expected_directories };
            my $removed = _remove_validation_snapshot($cleanup);
            my $reason = 'private validation snapshot identity could not be established';
            $reason .= '; incomplete snapshot could not be safely removed' unless $removed;
            return { type => 'refusal', reason => $reason,
                snapshot_removed => $removed ? 1 : 0 };
        }
        my $location = _owned_path_info(path => $path, staging_root => $root);
        unless ($location->{type} eq 'owned_path' &&
                _directory_chain_matches($expected_directories,
                    $location->{directory_identities}) &&
                $location->{path_lstat}[0] == $opened[0] &&
                $location->{path_lstat}[1] == $opened[1]) {
            close $fh;
            my $cleanup = { snapshot_path => $path, staging_root => $root,
                snapshot_identity => _identity_from_stat(\@opened),
                snapshot_directory_identities => $expected_directories };
            my $removed = _remove_validation_snapshot($cleanup);
            my $reason = 'private validation snapshot escaped or changed its owned root';
            $reason .= '; incomplete snapshot could not be safely removed' unless $removed;
            return { type => 'refusal', reason => $reason,
                snapshot_removed => $removed ? 1 : 0 };
        }
        return { type => 'created_snapshot', fh => $fh,
            path => $location->{path}, path_abs => $location->{path_abs},
            staging_root => $location->{staging_root},
            directory_identities => $location->{directory_identities},
            identity => _identity_from_stat(\@opened) };
    }
    return { type => 'refusal', reason => 'private validation snapshot name collisions exceeded the retry limit' };
}

sub _remove_validation_snapshot {
    my ($session) = @_;
    if ($session->{snapshot_fh}) {
        close $session->{snapshot_fh};
        delete $session->{snapshot_fh};
    }
    return 0 unless defined($session->{snapshot_path});
    my $location = _owned_path_info(path => $session->{snapshot_path},
        staging_root => $session->{staging_root});
    return 0 unless $location->{type} eq 'owned_path' &&
        _directory_chain_matches($session->{snapshot_directory_identities},
            $location->{directory_identities});
    my $expected = $session->{snapshot_identity};
    return 0 unless ref($expected) eq 'HASH' &&
        $location->{path_lstat}[0] == $expected->{device} &&
        $location->{path_lstat}[1] == $expected->{inode} &&
        S_ISREG($location->{path_lstat}[2]);
    return unlink($location->{path_abs}) ? 1 : 0;
}

sub discard_partial_snapshot {
    my ($snapshot) = @_;
    return { type => 'refusal', reason => 'validated snapshot record is invalid' }
        unless ref($snapshot) eq 'HASH' &&
            defined($snapshot->{snapshot_path}) &&
            defined($snapshot->{staging_root}) &&
            ref($snapshot->{identity}) eq 'HASH';
    my $session = {
        snapshot_path => $snapshot->{snapshot_path},
        staging_root => $snapshot->{staging_root},
        snapshot_identity => $snapshot->{identity},
        snapshot_directory_identities => $snapshot->{snapshot_directory_identities},
    };
    return { type => 'refusal', reason => 'verified snapshot identity or ancestry changed; refusing to remove an unowned path' }
        unless _remove_validation_snapshot($session);
    return { type => 'discarded_snapshot' };
}

sub capture_partial {
    my (%args) = @_;
    my $opened = _open_owned_partial(%args);
    return $opened unless $opened->{type} eq 'opened_partial';
    if (exists $args{expected_identity}) {
        my $expected = $args{expected_identity};
        unless (ref($expected) eq 'HASH' &&
                defined($expected->{device}) && defined($expected->{inode}) &&
                $opened->{identity}{device} eq $expected->{device} &&
                $opened->{identity}{inode} eq $expected->{inode}) {
            close $opened->{fh};
            return { type => 'refusal', reason => 'partial file differs from its receive-time identity' };
        }
    }
    my $closed = close $opened->{fh};
    return { type => 'refusal', reason => 'partial file handle could not be closed after identity capture' }
        unless $closed;
    delete $opened->{fh};
    $opened->{type} = 'captured_partial';
    return $opened;
}

sub _path_still_matches_snapshot {
    my ($session) = @_;
    my $current = capture_partial(
        path => $session->{path},
        staging_root => $session->{staging_root},
        expected_identity => $session->{identity},
        expected_directory_identities => $session->{directory_identities},
    );
    return $current->{type} eq 'captured_partial' &&
        _identity_matches($session->{identity}, $current->{identity});
}

sub begin_partial_seal {
    my (%args) = @_;
    return { type => 'refusal', reason => 'captured partial identity is missing' }
        unless ref($args{expected_identity}) eq 'HASH';
    return { type => 'refusal', reason => 'partial total size is invalid' }
        unless defined($args{total_size}) && $args{total_size} =~ /\A\d+\z/ && $args{total_size} > 0;

    my $opened = _open_owned_partial(%args);
    return $opened unless $opened->{type} eq 'opened_partial';
    my $identity = $opened->{identity};
    unless (_identity_matches($identity, $args{expected_identity})) {
        close $opened->{fh};
        return { type => 'refusal', reason => 'partial changed after its ownership snapshot' };
    }
    unless ($identity->{size} > 0 && $identity->{size} < $args{total_size}) {
        close $opened->{fh};
        return { type => 'refusal', reason => 'partial is empty or already complete' };
    }
    return {
        type => 'sealing', fh => $opened->{fh}, path => $opened->{path},
        staging_root => $opened->{staging_root}, identity => $identity,
        directory_identities => $opened->{directory_identities},
        total_size => 0 + $args{total_size}, bytes_hashed => 0,
        sha => Digest::SHA->new(256), state => 'sealing',
    };
}

sub _partial_seal_refusal {
    my ($session, $reason) = @_;
    if ($session->{fh}) {
        close $session->{fh};
        delete $session->{fh};
    }
    $session->{state} = 'refused';
    return { type => 'refusal', reason => $reason };
}

sub _finish_partial_seal {
    my ($session) = @_;
    my $fh = $session->{fh};
    my @handle_after = Time::HiRes::stat($fh);
    my $closed = close($fh);
    delete $session->{fh};
    my $handle_identity = @handle_after ? _identity_from_stat(\@handle_after) : undef;
    unless ($closed && $session->{bytes_hashed} == $session->{identity}{size} &&
            _identity_matches($session->{identity}, $handle_identity)) {
        $session->{state} = 'refused';
        return { type => 'refusal', reason => 'partial changed while its digest was being sealed' };
    }
    unless (_path_still_matches_snapshot($session)) {
        $session->{state} = 'refused';
        return { type => 'refusal', reason => 'partial path or a staging directory changed while its digest was being sealed' };
    }
    $session->{state} = 'sealed';
    return {
        type => 'sealed_partial', path => $session->{path},
        staging_root => $session->{staging_root}, identity => $session->{identity},
        size => $session->{bytes_hashed}, sha256 => $session->{sha}->hexdigest,
    };
}

sub step_partial_seal {
    my ($session, $budget) = @_;
    return { type => 'refusal', reason => 'partial seal session is invalid' }
        unless ref($session) eq 'HASH';
    return { type => 'cancelled' } if ($session->{state} // '') eq 'cancelled';
    return { type => 'refusal', reason => 'partial seal session is not active' }
        unless ($session->{state} // '') eq 'sealing' && $session->{fh};
    $budget = 64 * 1024 unless defined $budget;
    return _partial_seal_refusal($session, 'partial seal byte budget is invalid')
        unless $budget =~ /\A\d+\z/ && $budget > 0;
    $budget = 64 * 1024 if $budget > 64 * 1024;

    my $consumed = 0;
    while ($consumed < $budget && $session->{bytes_hashed} < $session->{identity}{size}) {
        my $remaining = $session->{identity}{size} - $session->{bytes_hashed};
        my $request = $budget - $consumed;
        $request = 64 * 1024 if $request > 64 * 1024;
        $request = $remaining if $request > $remaining;
        my $buffer = '';
        my $read = sysread($session->{fh}, $buffer, $request);
        return _partial_seal_refusal($session, 'partial read failed while its digest was being sealed')
            unless defined $read;
        return _partial_seal_refusal($session, 'partial ended before its captured length')
            if $read == 0;
        $session->{sha}->add($buffer);
        $session->{bytes_hashed} += $read;
        $consumed += $read;
    }
    return { type => 'in_progress', bytes_hashed => $session->{bytes_hashed},
        total_bytes => $session->{identity}{size} }
        if $session->{bytes_hashed} < $session->{identity}{size};

    my $extra = '';
    my $read = sysread($session->{fh}, $extra, 1);
    return _partial_seal_refusal($session, 'partial read failed while checking its final length')
        unless defined $read;
    return _partial_seal_refusal($session, 'partial grew beyond its captured length') if $read > 0;
    return _finish_partial_seal($session);
}

sub cancel_partial_seal {
    my ($session) = @_;
    return { type => 'cancelled' } unless ref($session) eq 'HASH';
    if ($session->{fh}) {
        close $session->{fh};
        delete $session->{fh};
    }
    $session->{state} = 'cancelled';
    return { type => 'cancelled' };
}

sub begin_partial_validation {
    my (%args) = @_;
    return { type => 'refusal', reason => 'partial file identity snapshot is missing' }
        unless ref($args{partial_identity}) eq 'HASH';
    return { type => 'refusal', reason => 'sealed partial digest is missing or invalid' }
        unless defined($args{partial_sha256}) &&
            $args{partial_sha256} =~ /\A[0-9a-f]{64}\z/i;
    return { type => 'refusal', reason => 'partial total size is invalid' }
        unless defined($args{total_size}) && $args{total_size} =~ /\A\d+\z/ &&
            $args{total_size} > 0;

    my $opened = _open_owned_partial(%args);
    return $opened unless $opened->{type} eq 'opened_partial';
    my $identity = $opened->{identity};
    unless (_identity_matches($identity, $args{partial_identity}) &&
            $identity->{size} > 0 && $identity->{size} < $args{total_size} &&
            (!defined($args{partial_size}) ||
                $args{partial_size} == $identity->{size})) {
        close $opened->{fh};
        return { type => 'refusal', reason => 'partial file identity, length, or completeness changed' };
    }

    my $snapshot = _create_validation_snapshot(
        staging_root => $opened->{root_abs},
        root_directory_identities => $opened->{root_directory_identities});
    unless ($snapshot->{type} eq 'created_snapshot') {
        close $opened->{fh};
        return $snapshot;
    }

    return {
        type => 'validating_partial', fh => $opened->{fh}, path => $opened->{path},
        snapshot_fh => $snapshot->{fh}, snapshot_path => $snapshot->{path},
        snapshot_path_abs => $snapshot->{path_abs},
        snapshot_identity => $snapshot->{identity},
        snapshot_directory_identities => $snapshot->{directory_identities},
        staging_root => $opened->{staging_root}, identity => $identity,
        directory_identities => $opened->{directory_identities},
        total_size => 0 + $args{total_size},
        expected_partial_sha256 => lc($args{partial_sha256}),
        bytes_hashed => 0, sha => Digest::SHA->new(256), state => 'validating',
    };
}

sub _partial_validation_refusal {
    my ($session, $reason) = @_;
    if ($session->{fh}) {
        close $session->{fh};
        delete $session->{fh};
    }
    my $snapshot_removed = _remove_validation_snapshot($session);
    $session->{state} = 'refused';
    $session->{terminal_reason} = $reason;
    $session->{snapshot_removed} = $snapshot_removed ? 1 : 0;
    $session->{snapshot_cleanup_reason} = 'incomplete validation snapshot could not be safely removed'
        unless $snapshot_removed;
    my $reported_reason = $reason;
    $reported_reason .= '; ' . $session->{snapshot_cleanup_reason}
        unless $snapshot_removed;
    return { type => 'refusal', reason => $reported_reason,
        snapshot_removed => $snapshot_removed ? 1 : 0 };
}

sub _finish_partial_validation {
    my ($session) = @_;
    my $fh = $session->{fh};
    my @handle_after = Time::HiRes::stat($fh);
    my $closed = close($fh);
    delete $session->{fh};
    my $handle_identity = @handle_after ? _identity_from_stat(\@handle_after) : undef;
    unless ($closed && $session->{bytes_hashed} == $session->{identity}{size} &&
            _identity_matches($session->{identity}, $handle_identity)) {
        return _partial_validation_refusal($session,
            'partial changed while it was being revalidated');
    }
    unless (_path_still_matches_snapshot($session)) {
        return _partial_validation_refusal($session,
            'partial path or a staging directory changed during revalidation');
    }
    my $digest = $session->{sha}->hexdigest;
    unless ($digest eq $session->{expected_partial_sha256}) {
        return _partial_validation_refusal($session, 'partial digest changed');
    }

    my $snapshot_fh = $session->{snapshot_fh};
    my @snapshot_after = Time::HiRes::stat($snapshot_fh);
    my $snapshot_closed = close($snapshot_fh);
    delete $session->{snapshot_fh};
    my $snapshot_handle_identity = @snapshot_after
        ? _identity_from_stat(\@snapshot_after) : undef;
    unless ($snapshot_closed && $snapshot_handle_identity &&
            $snapshot_handle_identity->{device} eq $session->{snapshot_identity}{device} &&
            $snapshot_handle_identity->{inode} eq $session->{snapshot_identity}{inode} &&
            $snapshot_handle_identity->{links} == 1 &&
            $snapshot_handle_identity->{size} == $session->{identity}{size}) {
        return _partial_validation_refusal($session,
            'private validation snapshot identity or length changed while it was written');
    }
    my $snapshot_location = _owned_path_info(path => $session->{snapshot_path},
        staging_root => $session->{staging_root});
    unless ($snapshot_location->{type} eq 'owned_path' &&
            _directory_chain_matches($session->{snapshot_directory_identities},
                $snapshot_location->{directory_identities}) &&
            $snapshot_location->{path_lstat}[0] == $session->{snapshot_identity}{device} &&
            $snapshot_location->{path_lstat}[1] == $session->{snapshot_identity}{inode}) {
        return _partial_validation_refusal($session,
            'private validation snapshot path or staging ancestry changed');
    }
    my $captured_snapshot = capture_partial(
        path => $session->{snapshot_path},
        staging_root => $session->{staging_root},
        expected_identity => $session->{snapshot_identity},
        expected_directory_identities => $session->{snapshot_directory_identities});
    unless ($captured_snapshot->{type} eq 'captured_partial' &&
            _directory_chain_matches($session->{snapshot_directory_identities},
                $captured_snapshot->{directory_identities}) &&
            $captured_snapshot->{identity}{size} == $session->{identity}{size} &&
            ($captured_snapshot->{identity}{mode} & 0777) == 0600) {
        return _partial_validation_refusal($session,
            'private validation snapshot failed its final path, length, or private-mode check');
    }
    $session->{snapshot_identity} = $captured_snapshot->{identity};
    $session->{state} = 'validated';
    my $result = {
        type => 'valid_partial', path => $session->{snapshot_path},
        snapshot_path => $session->{snapshot_path}, source_path => $session->{path},
        staging_root => $session->{staging_root}, size => $session->{bytes_hashed},
        sha256 => $digest, identity => $session->{snapshot_identity},
        snapshot_directory_identities => $session->{snapshot_directory_identities},
    };
    # The successful result is now the sole cleanup owner. Delayed lifecycle
    # callbacks holding the completed session cannot remove its spool.
    delete @{$session}{qw(snapshot_path snapshot_path_abs snapshot_identity
        snapshot_directory_identities)};
    return $result;
}

sub step_partial_validation {
    my ($session, $budget) = @_;
    return { type => 'refusal', reason => 'partial validation session is invalid' }
        unless ref($session) eq 'HASH';
    return { type => 'cancelled' } if ($session->{state} // '') eq 'cancelled';
    return { type => 'refusal', reason => 'partial validation session is not active' }
        unless ($session->{state} // '') eq 'validating' && $session->{fh};
    $budget = 64 * 1024 unless defined $budget;
    return _partial_validation_refusal($session,
        'partial validation byte budget is invalid')
        unless $budget =~ /\A\d+\z/ && $budget > 0;
    $budget = 64 * 1024 if $budget > 64 * 1024;

    my $consumed = 0;
    while ($consumed < $budget &&
            $session->{bytes_hashed} < $session->{identity}{size}) {
        my $remaining = $session->{identity}{size} - $session->{bytes_hashed};
        my $request = $budget - $consumed;
        $request = 64 * 1024 if $request > 64 * 1024;
        $request = $remaining if $request > $remaining;
        my $buffer = '';
        my $read = sysread($session->{fh}, $buffer, $request);
        return _partial_validation_refusal($session,
            'partial read failed during revalidation') unless defined $read;
        return _partial_validation_refusal($session,
            'partial ended before its captured length') if $read == 0;
        my $written_offset = 0;
        while ($written_offset < $read) {
            my $written = syswrite($session->{snapshot_fh}, $buffer,
                $read - $written_offset, $written_offset);
            return _partial_validation_refusal($session,
                'private validation snapshot write failed')
                unless defined($written) && $written > 0;
            $session->{sha}->add(substr($buffer, $written_offset, $written));
            $session->{bytes_hashed} += $written;
            $consumed += $written;
            $written_offset += $written;
        }
    }
    return { type => 'in_progress', bytes_hashed => $session->{bytes_hashed},
        total_bytes => $session->{identity}{size} }
        if $session->{bytes_hashed} < $session->{identity}{size};

    my $extra = '';
    my $read = sysread($session->{fh}, $extra, 1);
    return _partial_validation_refusal($session,
        'partial read failed while checking its final length') unless defined $read;
    return _partial_validation_refusal($session,
        'partial grew beyond its captured length') if $read > 0;
    return _finish_partial_validation($session);
}

sub _repeat_terminal_validation_cancel {
    my ($session, $state) = @_;
    my $retried = 0;
    unless ($session->{snapshot_removed}) {
        $retried = 1;
        my $removed = _remove_validation_snapshot($session);
        $session->{snapshot_removed} = $removed ? 1 : 0;
        if ($removed) {
            delete $session->{snapshot_cleanup_reason};
        } else {
            $session->{snapshot_cleanup_reason} //=
                'incomplete validation snapshot could not be safely removed';
        }
    }
    my $type = $state eq 'refused' ? 'already_refused' : 'already_cancelled';
    my $result = { type => $type,
        snapshot_removed => $session->{snapshot_removed} ? 1 : 0 };
    $result->{cleanup_retried} = 1 if $retried;
    my @reasons;
    push @reasons, $session->{terminal_reason}
        if defined($session->{terminal_reason}) && length($session->{terminal_reason});
    push @reasons, $session->{snapshot_cleanup_reason}
        if !$session->{snapshot_removed} &&
            defined($session->{snapshot_cleanup_reason}) &&
            length($session->{snapshot_cleanup_reason});
    $result->{reason} = join('; ', @reasons) if @reasons;
    return $result;
}

sub cancel_partial_validation {
    my ($session) = @_;
    return { type => 'cancelled' } unless ref($session) eq 'HASH';
    return { type => 'already_completed', snapshot_preserved => 1 }
        if ($session->{state} // '') eq 'validated';
    return _repeat_terminal_validation_cancel($session, 'cancelled')
        if ($session->{state} // '') eq 'cancelled';
    return _repeat_terminal_validation_cancel($session, 'refused')
        if ($session->{state} // '') eq 'refused';
    if ($session->{fh}) {
        close $session->{fh};
        delete $session->{fh};
    }
    my $snapshot_removed = _remove_validation_snapshot($session);
    $session->{state} = 'cancelled';
    $session->{snapshot_removed} = $snapshot_removed ? 1 : 0;
    $session->{snapshot_cleanup_reason} = 'incomplete validation snapshot could not be safely removed'
        unless $snapshot_removed;
    return { type => 'cancelled', snapshot_removed => $snapshot_removed ? 1 : 0,
        ($snapshot_removed ? () : (reason => $session->{snapshot_cleanup_reason})) };
}

sub validate_partial {
    my (%args) = @_;
    # Compatibility wrapper for non-event-loop callers. Native/UI workflows
    # must use begin/step so a large partial is never read in one callback.
    my $session = begin_partial_validation(%args);
    return $session unless ($session->{type} // '') eq 'validating_partial';
    while (1) {
        my $result = step_partial_validation($session, 64 * 1024);
        return $result unless ($result->{type} // '') eq 'in_progress';
    }
}

sub _same_canonical_path {
    my ($left, $right) = @_;
    return 0 unless defined($left) && defined($right) &&
        !ref($left) && !ref($right);
    return File::Spec->canonpath(File::Spec->rel2abs($left)) eq
        File::Spec->canonpath(File::Spec->rel2abs($right));
}

sub begin_resumed_file_verification {
    my (%args) = @_;
    my $intent = $args{resume_intent};
    return { type => 'refusal', reason => 'durable resume intent is required' }
        unless ref($intent) eq 'HASH';
    return { type => 'refusal', reason => 'resumed-file verification requires explicit writer-closure evidence' }
        unless defined($args{writer_closed}) && !ref($args{writer_closed}) &&
            "$args{writer_closed}" eq '1';
    return { type => 'refusal', reason => 'resume attempt identity is invalid' }
        unless defined($intent->{attempt_id}) &&
            $intent->{attempt_id} =~ /\Aresume-[a-f0-9]{32}\z/;
    for my $field (qw(offset total_size)) {
        return { type => 'refusal', reason => "resume intent $field is invalid" }
            unless defined($intent->{$field}) && !ref($intent->{$field}) &&
                $intent->{$field} =~ /\A[1-9][0-9]{0,18}\z/;
    }
    return { type => 'refusal', reason => 'resume offset is outside the offered file' }
        unless $intent->{offset} < $intent->{total_size};
    for my $field (qw(partial_sha256 expected_sha256)) {
        return { type => 'refusal', reason => "resume intent $field is invalid" }
            unless defined($intent->{$field}) &&
                $intent->{$field} =~ /\A[a-f0-9]{64}\z/;
    }
    return { type => 'refusal', reason => 'trusted whole-file digest does not match the durable resume intent' }
        unless defined($args{expected_sha256}) && !ref($args{expected_sha256}) &&
            $args{expected_sha256} =~ /\A[a-f0-9]{64}\z/i &&
            lc($args{expected_sha256}) eq $intent->{expected_sha256};
    return { type => 'refusal', reason => 'resume snapshot identity is missing' }
        unless ref($intent->{snapshot_identity}) eq 'HASH';
    my $snapshot_identity = $intent->{snapshot_identity};
    for my $field (qw(device inode mode links size)) {
        return { type => 'refusal', reason => "resume snapshot identity $field is invalid" }
            unless defined($snapshot_identity->{$field}) &&
                !ref($snapshot_identity->{$field}) &&
                $snapshot_identity->{$field} =~ /\A\d+\z/;
    }
    return { type => 'refusal', reason => 'resume snapshot was not a private single-link partial' }
        unless $snapshot_identity->{size} == $intent->{offset} &&
            $snapshot_identity->{links} == 1 &&
            ($snapshot_identity->{mode} & 0777) == 0600;
    return { type => 'refusal', reason => 'resume snapshot directory ancestry is missing' }
        unless ref($intent->{snapshot_directory_identities}) eq 'ARRAY' &&
            @{$intent->{snapshot_directory_identities}};
    return { type => 'refusal', reason => 'resume staging root does not match its durable intent' }
        unless _same_canonical_path($args{staging_root}, $intent->{staging_root});
    return { type => 'refusal', reason => 'resume target is not the exact durable snapshot path' }
        unless _same_canonical_path($args{path}, $intent->{snapshot_path});

    my $opened = _open_owned_partial(path => $intent->{snapshot_path},
        staging_root => $intent->{staging_root},
        expected_directory_identities => $intent->{snapshot_directory_identities});
    return $opened unless $opened->{type} eq 'opened_partial';
    my $identity = $opened->{identity};
    unless ($identity->{device} eq $snapshot_identity->{device} &&
            $identity->{inode} eq $snapshot_identity->{inode} &&
            $identity->{links} == 1 && ($identity->{mode} & 0777) == 0600) {
        close $opened->{fh};
        return { type => 'refusal', reason => 'resumed file is not the originally owned private snapshot' };
    }
    unless ($identity->{size} == $intent->{total_size}) {
        close $opened->{fh};
        return { type => 'refusal', reason => 'resumed file length does not equal the advertised total size' };
    }
    return {
        type => 'verifying_resumed_file', state => 'verifying',
        fh => $opened->{fh}, path => $opened->{path},
        staging_root => $opened->{staging_root}, identity => $identity,
        directory_identities => $opened->{directory_identities},
        attempt_id => $intent->{attempt_id}, offset => 0 + $intent->{offset},
        expected_size => 0 + $intent->{total_size},
        expected_partial_sha256 => $intent->{partial_sha256},
        expected_sha256 => lc($args{expected_sha256}),
        bytes_hashed => 0, prefix_bytes_hashed => 0,
        prefix_sha => Digest::SHA->new(256),
        whole_sha => Digest::SHA->new(256),
    };
}

sub _resumed_file_verification_refusal {
    my ($session, $reason) = @_;
    if ($session->{fh}) {
        close $session->{fh};
        delete $session->{fh};
    }
    $session->{state} = 'refused';
    return { type => 'refusal', reason => $reason,
        staging_preserved => 1 };
}

sub _finish_resumed_file_verification {
    my ($session) = @_;
    my $fh = $session->{fh};
    my @handle_after = Time::HiRes::stat($fh);
    my $closed = close($fh);
    delete $session->{fh};
    my $handle_identity = @handle_after
        ? _identity_from_stat(\@handle_after) : undef;
    unless ($closed && $session->{bytes_hashed} == $session->{expected_size} &&
            $session->{prefix_bytes_hashed} == $session->{offset} &&
            _identity_matches($session->{identity}, $handle_identity)) {
        $session->{state} = 'refused';
        return { type => 'refusal',
            reason => 'resumed file changed while its digests were being verified',
            staging_preserved => 1 };
    }
    unless (_path_still_matches_snapshot($session)) {
        $session->{state} = 'refused';
        return { type => 'refusal',
            reason => 'resumed file path or staging ancestry changed during verification',
            staging_preserved => 1 };
    }
    my $prefix_sha256 = $session->{prefix_sha}->hexdigest;
    unless ($prefix_sha256 eq $session->{expected_partial_sha256}) {
        $session->{state} = 'refused';
        return { type => 'refusal',
            reason => 'resumed file prefix does not match the sealed partial digest',
            staging_preserved => 1 };
    }
    my $sha256 = $session->{whole_sha}->hexdigest;
    unless ($sha256 eq $session->{expected_sha256}) {
        $session->{state} = 'refused';
        return { type => 'refusal',
            reason => 'resumed file does not match the trusted whole-file digest',
            staging_preserved => 1 };
    }
    my $verification = {
        schema_version => 1,
        attempt_id => $session->{attempt_id},
        path => $session->{path}, staging_root => $session->{staging_root},
        offset => $session->{offset}, total_size => $session->{bytes_hashed},
        partial_sha256 => $prefix_sha256,
        expected_sha256 => $session->{expected_sha256},
        sha256 => $sha256, prefix_sha256 => $prefix_sha256,
        writer_closed => 1,
        identity => $session->{identity},
        directory_identities => $session->{directory_identities},
    };
    my $receipt = _issue_resume_verification_receipt($verification);
    unless ($receipt) {
        $session->{state} = 'refused';
        return { type => 'refusal',
            reason => 'pending resumed-file verification receipt capacity is exhausted',
            staging_preserved => 1 };
    }
    $session->{state} = 'verified';
    return {
        type => 'verified_resumed_file', attempt_id => $session->{attempt_id},
        path => $session->{path}, staging_root => $session->{staging_root},
        offset => $session->{offset}, size => $session->{bytes_hashed},
        sha256 => $sha256, prefix_sha256 => $prefix_sha256,
        identity => $session->{identity},
        directory_identities => $session->{directory_identities},
        verification_receipt => $receipt,
    };
}

sub step_resumed_file_verification {
    my ($session, $budget) = @_;
    return { type => 'refusal', reason => 'resumed-file verification session is invalid' }
        unless ref($session) eq 'HASH';
    return { type => 'cancelled', staging_preserved => 1 }
        if ($session->{state} // '') eq 'cancelled';
    return { type => 'refusal', reason => 'resumed-file verification session is not active' }
        unless ($session->{state} // '') eq 'verifying' && $session->{fh};
    $budget = 64 * 1024 unless defined $budget;
    return _resumed_file_verification_refusal($session,
        'resumed-file verification byte budget is invalid')
        unless $budget =~ /\A\d+\z/ && $budget > 0;
    $budget = 64 * 1024 if $budget > 64 * 1024;

    my $consumed = 0;
    while ($consumed < $budget && $session->{bytes_hashed} < $session->{expected_size}) {
        my $remaining = $session->{expected_size} - $session->{bytes_hashed};
        my $request = $budget - $consumed;
        $request = 64 * 1024 if $request > 64 * 1024;
        $request = $remaining if $request > $remaining;
        my $buffer = '';
        my $read = sysread($session->{fh}, $buffer, $request);
        return _resumed_file_verification_refusal($session,
            'resumed file read failed during verification') unless defined $read;
        return _resumed_file_verification_refusal($session,
            'resumed file ended before its captured total length') if $read == 0;
        $session->{whole_sha}->add($buffer);
        my $prefix_remaining = $session->{offset} - $session->{prefix_bytes_hashed};
        if ($prefix_remaining > 0) {
            my $prefix_length = $read < $prefix_remaining ? $read : $prefix_remaining;
            $session->{prefix_sha}->add(substr($buffer, 0, $prefix_length));
            $session->{prefix_bytes_hashed} += $prefix_length;
        }
        $session->{bytes_hashed} += $read;
        $consumed += $read;
    }
    return { type => 'in_progress', bytes_hashed => $session->{bytes_hashed},
        total_bytes => $session->{expected_size} }
        if $session->{bytes_hashed} < $session->{expected_size};

    my $extra = '';
    my $read = sysread($session->{fh}, $extra, 1);
    return _resumed_file_verification_refusal($session,
        'resumed file read failed while checking final length') unless defined $read;
    return _resumed_file_verification_refusal($session,
        'resumed file grew beyond its expected total length') if $read > 0;
    return _finish_resumed_file_verification($session);
}

sub cancel_resumed_file_verification {
    my ($session) = @_;
    return { type => 'cancelled', staging_preserved => 1 }
        unless ref($session) eq 'HASH';
    return { type => 'already_completed', staging_preserved => 1 }
        if ($session->{state} // '') eq 'verified';
    if ($session->{fh}) {
        close $session->{fh};
        delete $session->{fh};
    }
    $session->{state} = 'cancelled';
    return { type => 'cancelled', staging_preserved => 1 };
}

sub resume_decision {
    my (%args) = @_;
    my $profile = $args{profile} || capability_profile();
    return { type => 'refusal', reason => $profile->{reason} // 'native resume profile is unsupported' }
        unless $profile->{supported};
    return { type => 'refusal', reason => 'resume cannot bind a prior process or IRC connection' }
        unless $args{same_process} && $args{same_connection} && $args{same_epoch};
    return { type => 'refusal', reason => 'server continuation has not been correlated without replaying the request' }
        unless $args{correlated_continuation};
    return { type => 'refusal', reason => 'trusted full-file SHA-256 is required' }
        unless defined($args{expected_sha256}) && $args{expected_sha256} =~ /\A[0-9a-f]{64}\z/i;
    return { type => 'refusal', reason => 'ambiguous DCC tuple is reserved by another request' }
        if $args{tuple_ambiguous};
    my $partial = validate_partial(%args);
    return $partial unless $partial->{type} eq 'valid_partial';
    return { type => 'resume_allowed', offset => $partial->{size}, partial => $partial,
        expected_sha256 => lc($args{expected_sha256}) };
}

1;
