package FServe::Transfer::Journal;

use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_RDONLY O_RDWR O_WRONLY O_APPEND LOCK_EX LOCK_NB);
use IO::Handle ();
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);

our $VERSION = 1;
our $MAX_RECORD_BYTES = 64 * 1024;
our $MAX_JOURNAL_BYTES = 1024 * 1024 * 1024;
our $MAX_COLLECTED_REPLAY_RECORDS = 500;

sub _read_bounded_line {
    my ($fh, $reader, $maximum) = @_;
    $reader->{buffer} //= '';
    $reader->{offset} //= 0;

    while (1) {
        my $buffer = $reader->{buffer};
        my $offset = $reader->{offset};
        my $newline = index($buffer, "\n", $offset);
        if ($newline >= 0) {
            my $length = $newline - $offset + 1;
            die 'journal line exceeds configured record limit' if $length > $maximum;
            my $line = substr($buffer, $offset, $length);
            $reader->{offset} = $newline + 1;
            if ($reader->{offset} >= length($buffer)) {
                $reader->{buffer} = '';
                $reader->{offset} = 0;
            }
            return $line;
        }

        my $remaining = length($buffer) - $offset;
        die 'journal line exceeds configured record limit' if $remaining >= $maximum;
        if ($offset) {
            $reader->{buffer} = substr($buffer, $offset);
            $reader->{offset} = 0;
            $buffer = $reader->{buffer};
        }
        my $room = $maximum + 1 - length($buffer);
        my $want = $room > 4096 ? 4096 : $room;
        my $read = sysread($fh, my $chunk, $want);
        die "cannot read request journal: $!" unless defined $read;
        if ($read == 0) {
            return undef unless length($reader->{buffer});
            die 'journal contains a torn or unterminated record';
        }
        $reader->{buffer} .= $chunk;
    }
}

sub _decode_validated_line {
    my ($line, $expected_seq, $previous) = @_;
    die 'journal contains a torn or unterminated record' unless $line =~ /\n\z/;
    chop $line;
    die 'journal record contains a carriage return' if $line =~ /\r/;
    my $record = eval { JSON::PP->new->decode($line) };
    die 'journal contains invalid JSON' if $@ || ref($record) ne 'HASH';
    for my $key (qw(version sequence event data previous_digest digest)) {
        die "journal record missing $key" unless exists $record->{$key};
    }
    die 'journal schema version mismatch' unless $record->{version} == $VERSION;
    die 'journal sequence discontinuity' unless $record->{sequence} == $expected_seq;
    die 'journal event must be a short string'
        unless !ref($record->{event}) && $record->{event} =~ /\A[a-z][a-z0-9_]{0,63}\z/;
    die 'journal data must be an object' unless ref($record->{data}) eq 'HASH';
    die 'journal hash chain mismatch' unless $record->{previous_digest} eq $previous;
    my %unsigned = %$record;
    my $digest = delete $unsigned{digest};
    my $want = sha256_hex(JSON::PP->new->canonical(1)->encode(\%unsigned));
    die 'journal record integrity check failed' unless $digest eq $want;
    return ($record, $digest);
}

sub _scan_path {
    my ($path, %args) = @_;
    my @events;
    my $collect = $args{collect} ? 1 : 0;
    my $on_event = $args{on_event};
    my $maximum = $args{max_record_bytes} || $MAX_RECORD_BYTES;
    my ($expected_seq, $previous) = (1, '0' x 64);
    if (-e $path) {
        die 'journal path is not a regular file' unless -f $path && !-l $path;
        open my $fh, '<:raw', $path or die "cannot read request journal: $!";
        my %reader;
        while (defined(my $line = _read_bounded_line($fh, \%reader, $maximum))) {
            my ($record, $digest) = _decode_validated_line($line, $expected_seq, $previous);
            if ($collect) {
                die 'collected journal replay exceeds the in-memory event limit'
                    if @events >= $MAX_COLLECTED_REPLAY_RECORDS;
                push @events, $record;
            }
            $on_event->($record, $record->{sequence}) if ref($on_event) eq 'CODE';
            $previous = $digest;
            $expected_seq++;
        }
        close $fh or die "cannot close request journal: $!";
    }
    my @st = stat($path);
    return {
        events => \@events,
        sequence => $expected_seq - 1,
        tail_hash => $previous,
        file_identity => @st ? [@st[0, 1, 7, 9, 10]] : undef,
        size => @st ? $st[7] : 0,
    };
}

sub _compaction_paths {
    my ($path) = @_;
    return map { $path . $_ } qw(
        .compact.tmp .compact.ready .compact.archive
        .compact.manifest .compact.manifest.tmp
    );
}

sub _rename_path {
    my ($source, $destination) = @_;
    return CORE::rename($source, $destination);
}

sub _sync_file_handle {
    my ($fh) = @_;
    return $fh->sync();
}

sub _sync_directory {
    my ($path) = @_;
    my $directory = dirname($path);
    sysopen(my $fh, $directory, O_RDONLY)
        or die "cannot open journal directory for durable sync: $!";
    my $synced = $fh->sync();
    my $error = $! || 'directory sync failed';
    close $fh or die "cannot close journal directory after sync: $!";
    die "journal directory durable sync failed: $error" unless $synced;
    return 1;
}

sub sync_parent_directory {
    my ($self, $path) = @_;
    die 'directory sync path is required'
        unless defined($path) && !ref($path) && length($path);
    _sync_directory($path);
    return 1;
}

sub _scan_matches_identity {
    my ($scan, $identity) = @_;
    return 0 unless ref($scan) eq 'HASH' && ref($identity) eq 'HASH';
    return $scan->{size} == $identity->{bytes} &&
        $scan->{sequence} == $identity->{sequence} &&
        $scan->{tail_hash} eq $identity->{tail_hash};
}

sub _identity_from_scan {
    my ($scan) = @_;
    return {
        bytes => 0 + $scan->{size},
        sequence => 0 + $scan->{sequence},
        tail_hash => $scan->{tail_hash},
    };
}

sub _read_compaction_manifest {
    my ($path) = @_;
    die 'journal compaction manifest is not a regular file' if -l $path || !-f $path;
    my @st = stat($path);
    die 'journal compaction manifest exceeds its size limit' unless @st && $st[7] <= 4096;
    open my $fh, '<:raw', $path or die "cannot read journal compaction manifest: $!";
    my $raw = '';
    while (length($raw) <= 4096) {
        my $read = sysread($fh, my $chunk, 4097 - length($raw));
        die "cannot read journal compaction manifest: $!" unless defined $read;
        last if $read == 0;
        $raw .= $chunk;
    }
    close $fh or die "cannot close journal compaction manifest: $!";
    die 'journal compaction manifest exceeds its size limit' if length($raw) > 4096;
    die 'journal compaction manifest is malformed' unless defined($raw) && length($raw);
    my $manifest = eval { JSON::PP->new->decode($raw) };
    die 'journal compaction manifest is invalid JSON' if $@ || ref($manifest) ne 'HASH';
    my $digest = delete $manifest->{digest};
    die 'journal compaction manifest schema mismatch'
        unless ($manifest->{version} // 0) == 1 &&
            ref($manifest->{source}) eq 'HASH' && ref($manifest->{snapshot}) eq 'HASH';
    for my $identity ($manifest->{source}, $manifest->{snapshot}) {
        die 'journal compaction manifest identity is malformed'
            unless defined($identity->{bytes}) && $identity->{bytes} =~ /\A\d+\z/ &&
                defined($identity->{sequence}) && $identity->{sequence} =~ /\A\d+\z/ &&
                defined($identity->{tail_hash}) && $identity->{tail_hash} =~ /\A[a-f0-9]{64}\z/;
    }
    my $want = sha256_hex(JSON::PP->new->canonical(1)->encode($manifest));
    die 'journal compaction manifest integrity check failed'
        unless defined($digest) && !ref($digest) && $digest =~ /\A[a-f0-9]{64}\z/ &&
            $digest eq $want;
    $manifest->{digest} = $digest;
    return $manifest;
}

sub _write_compaction_manifest {
    my ($path, $manifest) = @_;
    my @paths = _compaction_paths($path);
    my ($manifest_path, $manifest_tmp) = @paths[3, 4];
    die 'journal compaction manifest already exists'
        if -e $manifest_path || -e $manifest_tmp;
    my %body = %$manifest;
    $body{version} = 1;
    $body{digest} = sha256_hex(JSON::PP->new->canonical(1)->encode(\%body));
    my $encoded = JSON::PP->new->canonical(1)->encode(\%body);
    sysopen(my $fh, $manifest_tmp, O_CREAT | O_EXCL | O_WRONLY, 0600)
        or die "cannot create journal compaction manifest: $!";
    binmode($fh, ':raw');
    my $offset = 0;
    while ($offset < length($encoded)) {
        my $written = syswrite($fh, $encoded, length($encoded) - $offset, $offset);
        unless (defined($written) && $written > 0) {
            my $error = $! || 'short manifest write';
            close $fh;
            die "cannot write journal compaction manifest: $error";
        }
        $offset += $written;
    }
    unless (_sync_file_handle($fh)) {
        my $error = $! || 'manifest sync failed';
        close $fh;
        die "cannot sync journal compaction manifest: $error";
    }
    close $fh or die "cannot close journal compaction manifest: $!";
    _rename_path($manifest_tmp, $manifest_path)
        or die "cannot publish journal compaction manifest: $!";
    _sync_directory($path);
    return 1;
}

sub _remove_compaction_file {
    my ($path) = @_;
    return 1 unless -e $path;
    die 'journal compaction evidence path is not a regular file' if -l $path || !-f $path;
    unlink($path) or die "cannot remove journal compaction evidence: $!";
    return 1;
}

sub _finish_manifest_recovery {
    my ($path, $manifest_path, $temporary, $ready, $archive) = @_;
    # Recovery may be observing a canonical file that was renamed into place
    # before the previous process synced the directory. Make that publication
    # durable before deleting the only recoverable source generation.
    _sync_directory($path);
    _remove_compaction_file($temporary);
    _remove_compaction_file($ready);
    _remove_compaction_file($archive);
    _remove_compaction_file($manifest_path . '.tmp');
    _sync_directory($path);
    _remove_compaction_file($manifest_path);
    _sync_directory($path);
    return 1;
}

sub _preserve_rejected_snapshot {
    my ($ready, $rejected) = @_;
    return 1 unless -e $ready;
    die 'rejected journal snapshot path must not be a symlink' if -l $rejected;
    return 0 if -e $rejected;
    _rename_path($ready, $rejected)
        or die "cannot preserve rejected journal snapshot: $!";
    return 1;
}

sub _recover_compaction_path {
    my ($path, $max_record_bytes) = @_;
    my ($temporary, $ready, $archive, $manifest_path, $manifest_tmp) = _compaction_paths($path);
    my $rejected = $path . '.compact.rejected';
    for my $candidate ($path, $temporary, $ready, $archive, $manifest_path, $manifest_tmp, $rejected) {
        die 'journal compaction path must not be a symlink' if -l $candidate;
    }
    if (-e $manifest_path) {
        my $manifest = _read_compaction_manifest($manifest_path);
        my $source = $manifest->{source};
        my $snapshot = $manifest->{snapshot};
        if (-e $path) {
            my $canonical_scan = _scan_path($path, max_record_bytes => $max_record_bytes);
            if (_scan_matches_identity($canonical_scan, $snapshot)) {
                if (-e $archive) {
                    my $archive_scan = _scan_path($archive, max_record_bytes => $max_record_bytes);
                    die 'journal archive does not match the compaction source manifest'
                        unless _scan_matches_identity($archive_scan, $source);
                }
                _finish_manifest_recovery($path, $manifest_path, $temporary, $ready, $archive);
                return $path;
            }
            if (_scan_matches_identity($canonical_scan, $source) && !-e $archive) {
                my $preserve_ready = 0;
                if (-e $ready) {
                    my $ready_scan = eval { _scan_path($ready, max_record_bytes => $max_record_bytes) };
                    if (!$ready_scan || !_scan_matches_identity($ready_scan, $snapshot)) {
                        _preserve_rejected_snapshot($ready, $rejected);
                        $preserve_ready = 1 if -e $ready;
                    }
                }
                _remove_compaction_file($ready) if -e $ready && !$preserve_ready;
                _remove_compaction_file($temporary);
                _remove_compaction_file($manifest_tmp);
                _sync_directory($path);
                _remove_compaction_file($manifest_path);
                _sync_directory($path);
                return $path;
            }
            die 'canonical journal does not match either durable compaction generation; evidence was preserved';
        }

        my $ready_scan = eval {
            -e $ready ? _scan_path($ready, max_record_bytes => $max_record_bytes) : undef;
        };
        if ($ready_scan && _scan_matches_identity($ready_scan, $snapshot)) {
            _rename_path($ready, $path)
                or die "cannot recover prepared request journal snapshot: $!";
            _sync_directory($path);
            my $published = _scan_path($path, max_record_bytes => $max_record_bytes);
            die 'recovered journal snapshot does not match its manifest'
                unless _scan_matches_identity($published, $snapshot);
            if (-e $archive) {
                my $archive_scan = _scan_path($archive, max_record_bytes => $max_record_bytes);
                die 'journal archive does not match the compaction source manifest'
                    unless _scan_matches_identity($archive_scan, $source);
            }
            _finish_manifest_recovery($path, $manifest_path, $temporary, $ready, $archive);
            return $path;
        }
        if (-e $archive) {
            my $archive_scan = _scan_path($archive, max_record_bytes => $max_record_bytes);
            die 'journal archive does not match the compaction source manifest'
                unless _scan_matches_identity($archive_scan, $source);
            _preserve_rejected_snapshot($ready, $rejected) if -e $ready;
            _rename_path($archive, $path)
                or die "cannot restore archived request journal after interrupted compaction: $!";
            _sync_directory($path);
            my $restored = _scan_path($path, max_record_bytes => $max_record_bytes);
            die 'restored journal does not match the compaction source manifest'
                unless _scan_matches_identity($restored, $source);
            _remove_compaction_file($temporary);
            _remove_compaction_file($manifest_tmp);
            _sync_directory($path);
            _remove_compaction_file($manifest_path);
            _sync_directory($path);
            return $path;
        }
        die 'journal compaction manifest has no matching canonical, prepared, or archived generation';
    }

    if (!-e $path && -e $archive && -e $ready) {
        my $archive_scan = eval { _scan_path($archive, max_record_bytes => $max_record_bytes) };
        if ($archive_scan) {
            my $ready_scan = eval { _scan_path($ready, max_record_bytes => $max_record_bytes) };
            unless ($ready_scan && _scan_matches_identity($ready_scan, _identity_from_scan($archive_scan))) {
                _preserve_rejected_snapshot($ready, $path . '.compact.rejected') if -e $ready;
            }
            _rename_path($archive, $path)
                or die "cannot restore the only verified legacy journal generation: $!";
            _sync_directory($path);
            return $path;
        }
    }
    if (-e $path && -e $archive) {
        die 'legacy compaction artifacts make the canonical journal generation ambiguous; evidence was preserved';
    }
    die 'journal is missing with uncommitted compaction evidence; evidence was preserved'
        unless -e $path || !grep { -e $_ } ($temporary, $ready, $archive, $manifest_tmp);
    return $path;
}

sub _cleanup_compaction_paths {
    my ($path, $max_record_bytes) = @_;
    my ($temporary, $ready, $archive, $manifest_path, $manifest_tmp) = _compaction_paths($path);
    my $rejected = $path . '.compact.rejected';
    die 'unresolved journal compaction manifest remains after recovery'
        if -e $manifest_path;
    my $has_cleanup_candidates = grep { -e $_ }
        ($temporary, $ready, $archive, $manifest_tmp);
    # Recovery may have restored the canonical journal after an earlier
    # directory-sync failure. Make that active name durable before retiring
    # any remaining generation that could otherwise be its only fallback.
    _sync_directory($path) if $has_cleanup_candidates;
    my $preserve_ready = 0;
    my $changed = 0;
    if (-e $ready) {
        my $valid = eval {
            _scan_path($ready, max_record_bytes => $max_record_bytes);
            1;
        };
        unless ($valid) {
            $preserve_ready = 1;
            my $ready_existed = -e $ready;
            _preserve_rejected_snapshot($ready, $rejected);
            $changed = 1 if $ready_existed && !-e $ready && -e $rejected;
        }
    }
    for my $candidate ($temporary, $ready, $archive, $manifest_tmp) {
        next unless -e $candidate;
        next if $candidate eq $ready && $preserve_ready;
        die 'journal compaction evidence path is not a regular file'
            if -l $candidate || !-f $candidate;
        unlink($candidate)
            or die "cannot remove obsolete journal compaction file: $!";
        $changed = 1;
    }
    # If this sync fails, opening the store fails too. The canonical journal
    # was synced above, so a later startup can safely repeat artifact cleanup.
    _sync_directory($path) if $changed;
    return 1;
}

sub open_store {
    my ($class, %args) = @_;
    my $path = $args{path};
    die 'journal path is required' unless defined($path) && length($path);
    my $max_journal_bytes = defined($args{max_journal_bytes})
        ? $args{max_journal_bytes} : $MAX_JOURNAL_BYTES;
    die 'journal byte limit must be a positive integer'
        unless defined($max_journal_bytes) && $max_journal_bytes =~ /\A[1-9][0-9]*\z/;
    die 'journal path must not be a symlink' if -l $path;
    my $lock_path = $path . '.lock';
    die 'journal lock path must not be a symlink' if -l $lock_path;
    my $journal_path_preexisted = -e $path ? 1 : 0;
    my $lock_path_preexisted = -e $lock_path ? 1 : 0;

    my $max_record_bytes = $args{max_record_bytes} || $MAX_RECORD_BYTES;
    die 'journal record limit must be an integer from 1 through 65536'
        unless $max_record_bytes =~ /\A\d+\z/ && $max_record_bytes >= 1 &&
            $max_record_bytes <= $MAX_RECORD_BYTES;

    sysopen(my $lock_fh, $lock_path, O_CREAT | O_RDWR, 0600)
        or die "cannot open journal lock: $!";
    unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
        close $lock_fh;
        die 'another process owns the request journal lock';
    }
    binmode($lock_fh, ':raw');

    my $recovered_path = eval { _recover_compaction_path($path, $max_record_bytes); 1 };
    unless ($recovered_path) {
        my $error = $@ || 'cannot recover request journal compaction';
        close $lock_fh;
        die $error;
    }
    if (!-e $path && $lock_path_preexisted) {
        close $lock_fh;
        die 'request journal is missing for an existing journal lock; refusing to create empty history';
    }

    # Lock the journal inode too. The sidecar pathname can be renamed while
    # its original inode remains locked; the journal lock prevents a second
    # writer from acquiring the same data file through a replacement sidecar.
    sysopen(my $journal_fh, $path, O_CREAT | O_RDWR | O_APPEND, 0600)
        or die "cannot open request journal: $!";
    unless (flock($journal_fh, LOCK_EX | LOCK_NB)) {
        close $journal_fh;
        close $lock_fh;
        die 'another process owns the request journal data file';
    }
    binmode($journal_fh, ':raw');
    if (!$journal_path_preexisted || !$lock_path_preexisted) {
        my $synced = eval { _sync_directory($path); 1 };
        unless ($synced) {
            my $error = $@ || 'cannot durably create journal entries';
            close $journal_fh;
            close $lock_fh;
            die $error;
        }
    }

    my $self = bless {
        path => $path,
        lock_path => $lock_path,
        lock_fh => $lock_fh,
        journal_fh => $journal_fh,
        lock_identity => _handle_identity($lock_fh),
        journal_identity => _handle_identity($journal_fh),
        sequence => 0,
        tail_hash => ('0' x 64),
        healthy => 0,
        opened => 1,
        max_record_bytes => $max_record_bytes,
        max_journal_bytes => 0 + $max_journal_bytes,
    }, $class;
    my $records = $self->replay(
        on_event => $args{on_event},
        collect => $args{collect_replay} ? 1 : 0,
    );
    $self->{recovered} = $records if $args{collect_replay};
    _cleanup_compaction_paths($path, $max_record_bytes);
    $self->{healthy} = 1;
    return $self;
}

sub path { return $_[0]{path}; }
sub max_journal_bytes { return $_[0]{max_journal_bytes}; }
sub set_unhealthy_callback {
    my ($self, $callback) = @_;
    $self->{on_unhealthy} = ref($callback) eq 'CODE' ? $callback : undef;
    return 1;
}
sub _mark_unhealthy {
    my ($self, $reason) = @_;
    my $was_healthy = $self->{healthy};
    $self->{healthy} = 0;
    $self->{unhealthy_reason} = $reason // 'journal became unhealthy';
    return unless $was_healthy && !$self->{unhealthy_notified}++;
    my $callback = $self->{on_unhealthy};
    eval { $callback->($self->{unhealthy_reason}) }
        if ref($callback) eq 'CODE';
}
sub healthy {
    my ($self) = @_;
    return 0 unless $self->{healthy} && $self->{opened};
    my $ok = eval { $self->_assert_ownership(); 1 };
    unless ($ok) {
        my $reason = $@ || 'journal ownership check failed';
        $reason =~ s/[\r\n]+/ /g;
        $self->_mark_unhealthy($reason);
        return 0;
    }
    return 1;
}
sub recovered_events { return $_[0]{recovered} || []; }

sub snapshot_identity {
    my ($self) = @_;
    return {
        bytes => $self->{file_identity} ? 0 + $self->{file_identity}[2] : 0,
        sequence => 0 + ($self->{sequence} // 0),
        tail_hash => $self->{tail_hash} // ('0' x 64),
    };
}

sub _handle_identity {
    my ($handle) = @_;
    my @st = stat($handle);
    return @st ? [@st[0, 1]] : undef;
}

sub _path_identity {
    my ($path) = @_;
    return if -l $path;
    my @st = stat($path);
    return @st ? [@st[0, 1]] : undef;
}

sub _same_identity {
    my ($left, $right) = @_;
    return 0 unless ref($left) eq 'ARRAY' && ref($right) eq 'ARRAY';
    return $left->[0] == $right->[0] && $left->[1] == $right->[1] ? 1 : 0;
}

sub _assert_source_unchanged {
    my ($self, $expected) = @_;
    $self->_assert_ownership();
    my @st = stat($self->{path});
    my $current = @st ? [@st[0, 1, 7, 9, 10]] : undef;
    my $same = ref($expected) eq 'ARRAY' && ref($current) eq 'ARRAY';
    if ($same) {
        for my $index (0 .. 4) {
            $same = 0 if $expected->[$index] != $current->[$index];
        }
    }
    unless ($same) {
        $self->_mark_unhealthy('journal file changed outside this writer');
        die 'journal file changed outside this writer';
    }
    return 1;
}

sub _write_chunk {
    my ($self, $fh, $line, $length, $offset) = @_;
    return syswrite($fh, $line, $length, $offset);
}

sub _sync_handle {
    my ($self, $fh) = @_;
    return _sync_file_handle($fh);
}

sub _assert_ownership {
    my ($self) = @_;
    die 'journal lock pathname was removed or replaced'
        unless _same_identity($self->{lock_identity}, _path_identity($self->{lock_path})) &&
            _same_identity($self->{lock_identity}, _handle_identity($self->{lock_fh}));
    die 'journal data pathname was removed or replaced'
        unless _same_identity($self->{journal_identity}, _path_identity($self->{path})) &&
            _same_identity($self->{journal_identity}, _handle_identity($self->{journal_fh}));
    return 1;
}

sub replay {
    my ($self, %args) = @_;
    $self->_assert_ownership();
    my $scan = _scan_path($self->{path},
        max_record_bytes => $self->{max_record_bytes},
        collect => $args{collect},
        on_event => $args{on_event});
    $self->{sequence} = $scan->{sequence};
    $self->{tail_hash} = $scan->{tail_hash};
    $self->{file_identity} = $scan->{file_identity};
    $self->_assert_ownership();
    return $scan->{events};
}

sub begin_compacted_reopen {
    my ($self, %args) = @_;
    die 'journal is already open' if $self->{opened};
    my $snapshot = $args{snapshot_identity};
    my $expected_stat = $args{file_identity};
    die 'compacted journal snapshot identity is malformed'
        unless ref($snapshot) eq 'HASH' &&
            defined($snapshot->{bytes}) && $snapshot->{bytes} =~ /\A\d+\z/ &&
            defined($snapshot->{sequence}) && $snapshot->{sequence} =~ /\A\d+\z/ &&
            defined($snapshot->{tail_hash}) &&
                $snapshot->{tail_hash} =~ /\A[a-f0-9]{64}\z/;
    die 'compacted journal file identity is malformed'
        unless ref($expected_stat) eq 'ARRAY' && @$expected_stat == 5 &&
            !grep { !defined($_) || ref($_) || $_ !~ /\A\d+\z/ } @$expected_stat;
    die 'journal path must not be a symlink' if -l $self->{path};
    die 'journal lock path must not be a symlink' if -l $self->{lock_path};
    die 'compacted journal or lock file is missing'
        unless -f $self->{path} && -f $self->{lock_path};

    sysopen(my $lock_fh, $self->{lock_path}, O_RDWR, 0600)
        or die "cannot reopen journal lock: $!";
    unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
        close $lock_fh;
        die 'another process owns the request journal lock';
    }
    binmode($lock_fh, ':raw');
    sysopen(my $journal_fh, $self->{path}, O_RDWR | O_APPEND, 0600)
        or do { close $lock_fh; die "cannot reopen compacted journal: $!"; };
    unless (flock($journal_fh, LOCK_EX | LOCK_NB)) {
        close $journal_fh;
        close $lock_fh;
        die 'another process owns the compacted journal data file';
    }
    binmode($journal_fh, ':raw');
    sysopen(my $read_fh, $self->{path}, O_RDONLY, 0600)
        or do { close $journal_fh; close $lock_fh; die "cannot open compacted journal for validation: $!"; };
    binmode($read_fh, ':raw');

    my @handle_stat = stat($journal_fh);
    my @path_stat = stat($self->{path});
    my @read_stat = stat($read_fh);
    my @actual = @handle_stat ? @handle_stat[0, 1, 7, 9, 10] : ();
    my $valid = @actual == 5 && @path_stat && @read_stat &&
        -f $self->{path} && !-l $self->{path};
    if ($valid) {
        for my $index (0 .. 4) {
            $valid = 0 if $actual[$index] != $expected_stat->[$index];
        }
        $valid = 0 if $actual[2] != $snapshot->{bytes};
        $valid = 0 if $handle_stat[0] != $path_stat[0] ||
            $handle_stat[1] != $path_stat[1] ||
            $read_stat[0] != $path_stat[0] || $read_stat[1] != $path_stat[1];
    }
    unless ($valid) {
        close $read_fh;
        close $journal_fh;
        close $lock_fh;
        die 'compacted journal changed after the worker validated it; restart recovery is required';
    }

    $self->{lock_fh} = $lock_fh;
    $self->{journal_fh} = $journal_fh;
    $self->{compaction_validation} = {
        read_fh => $read_fh,
        reader => {},
        expected_stat => [@{$expected_stat}],
        expected_snapshot => { %{$snapshot} },
        sequence => 0,
        previous => '0' x 64,
        bytes => 0,
    };
    $self->{lock_identity} = _handle_identity($lock_fh);
    $self->{journal_identity} = _handle_identity($journal_fh);
    $self->{file_identity} = \@actual;
    $self->{sequence} = 0;
    $self->{tail_hash} = '0' x 64;
    $self->{opened} = 1;
    $self->{healthy} = 0;
    $self->{unhealthy_reason} = undef;
    $self->{unhealthy_notified} = 0;
    return 1;
}

sub validate_compacted_reopen_step {
    my ($self, %args) = @_;
    die 'compacted journal validation is not active'
        unless $self->{opened} && $self->{compaction_validation};
    my $state = $self->{compaction_validation};
    my $max_bytes = $args{max_bytes} // 262_144;
    my $max_records = $args{max_records} // 64;
    die 'invalid compacted journal validation budget'
        unless $max_bytes =~ /\A[1-9][0-9]*\z/ && $max_records =~ /\A[1-9][0-9]*\z/;
    my $scan_identity = sub {
        $self->_assert_ownership();
        my @handle_stat = stat($self->{journal_fh});
        my @path_stat = stat($self->{path});
        my @read_stat = stat($state->{read_fh});
        return 0 unless @handle_stat && @path_stat && @read_stat &&
            -f $self->{path} && !-l $self->{path};
        my @actual = @handle_stat[0, 1, 7, 9, 10];
        for my $index (0 .. 4) {
            return 0 if $actual[$index] != $state->{expected_stat}[$index];
        }
        return 0 if $handle_stat[0] != $path_stat[0] ||
            $handle_stat[1] != $path_stat[1] ||
            $read_stat[0] != $path_stat[0] || $read_stat[1] != $path_stat[1];
        return 1;
    };
    die 'compacted journal changed during hash-chain validation'
        unless $scan_identity->();

    my ($bytes_this_step, $records_this_step) = (0, 0);
    while ($bytes_this_step < $max_bytes && $records_this_step < $max_records) {
        my $line = _read_bounded_line(
            $state->{read_fh}, $state->{reader}, $self->{max_record_bytes});
        unless (defined $line) {
            my $snapshot = $state->{expected_snapshot};
            die 'compacted journal byte count does not match the worker snapshot'
                unless $state->{bytes} == $snapshot->{bytes};
            die 'compacted journal record count does not match the worker snapshot'
                unless $state->{sequence} == $snapshot->{sequence};
            die 'compacted journal tail digest does not match the worker snapshot'
                unless $state->{previous} eq $snapshot->{tail_hash};
            die 'compacted journal changed during hash-chain validation'
                unless $scan_identity->();
            close $state->{read_fh}
                or die "cannot close compacted journal validation handle: $!";
            delete $self->{compaction_validation};
            $self->{sequence} = 0 + $snapshot->{sequence};
            $self->{tail_hash} = $snapshot->{tail_hash};
            $self->{file_identity} = [@{$state->{expected_stat}}];
            $self->{healthy} = 1;
            $self->{unhealthy_reason} = undef;
            $self->{unhealthy_notified} = 0;
            return 1;
        }
        my ($record, $digest) = _decode_validated_line(
            $line, $state->{sequence} + 1, $state->{previous});
        my $line_bytes = length($line);
        $state->{bytes} += $line_bytes;
        $bytes_this_step += $line_bytes;
        $state->{sequence} = $record->{sequence};
        $state->{previous} = $digest;
        $records_this_step++;
        die 'compacted journal contains more bytes than the worker snapshot'
            if $state->{bytes} > $state->{expected_snapshot}{bytes};
    }
    return 0;
}

sub append {
    my ($self, $event, $data) = @_;
    die 'journal is not healthy' unless $self->healthy();
    die 'invalid journal event name' unless defined($event) && $event =~ /\A[a-z][a-z0-9_]{0,63}\z/;
    die 'journal event data must be an object' unless ref($data) eq 'HASH';
    unless (-f $self->{path} && !-l $self->{path}) {
        $self->_mark_unhealthy('journal path is no longer a regular file');
        die 'journal path is not a regular file';
    }
    my @st = stat($self->{path});
    if (!@st || ($self->{file_identity} &&
            ($st[0] != $self->{file_identity}[0] || $st[1] != $self->{file_identity}[1]))) {
        $self->_mark_unhealthy('journal file identity changed');
        die 'journal file identity changed';
    }
    if ($self->{file_identity} &&
            ($st[7] != $self->{file_identity}[2] || $st[9] != $self->{file_identity}[3])) {
        $self->_mark_unhealthy('journal file changed outside this writer');
        die 'journal file changed outside this writer';
    }
    my $record = {
        version => $VERSION,
        sequence => $self->{sequence} + 1,
        event => $event,
        data => $data,
        previous_digest => $self->{tail_hash},
    };
    my $canonical = JSON::PP->new->canonical(1);
    $record->{digest} = sha256_hex($canonical->encode($record));
    my $line = $canonical->encode($record) . "\n";
    die 'journal event exceeds configured record limit' if length($line) > $self->{max_record_bytes};
    if ($st[7] + length($line) > $self->{max_journal_bytes}) {
        my $reason = 'request journal reached its configured byte limit (' .
            $self->{max_journal_bytes} . ' bytes); no record was appended';
        $self->_mark_unhealthy($reason);
        die $reason;
    }
    my $fh = $self->{journal_fh};
    my $written = 0;
    while ($written < length($line)) {
        my $count = $self->_write_chunk($fh, $line, length($line) - $written, $written);
        unless (defined($count) && $count > 0) {
            my $error = $! || 'short journal write';
            $self->_mark_unhealthy("request journal write failed: $error");
            die "request journal write failed: $error";
        }
        $written += $count;
    }
    unless ($self->_sync_handle($fh)) {
        my $error = $! || 'durable sync failed';
        $self->_mark_unhealthy("request journal durable sync failed: $error");
        die "request journal durable sync failed: $error";
    }
    eval { $self->_assert_ownership(); 1 } or do {
        my $error = $@ || 'journal ownership changed during append';
        $self->_mark_unhealthy($error);
        die 'journal ownership changed during append';
    };
    my @handle_st = stat($self->{journal_fh});
    my @path_st = stat($self->{path});
    unless (@handle_st && @path_st && $handle_st[0] == $path_st[0] &&
            $handle_st[1] == $path_st[1]) {
        $self->_mark_unhealthy('journal pathname changed during append');
        die 'journal pathname changed during append';
    }
    $self->{sequence} = $record->{sequence};
    $self->{tail_hash} = $record->{digest};
    $self->{file_identity} = [@handle_st[0, 1, 7, 9, 10]];
    return $record;
}

sub compact {
    my ($self, $build_snapshot) = @_;
    die 'journal compaction requires a snapshot builder'
        unless ref($build_snapshot) eq 'CODE';
    die 'journal is closed' unless $self->{opened};
    die 'journal compaction is allowed only after a byte-capacity refusal'
        unless $self->{healthy} ||
            (($self->{unhealthy_reason} // '') =~ /reached its configured byte limit/);
    $self->_assert_ownership();
    my $source_identity = $self->{file_identity}
        ? [@{$self->{file_identity}}] : undef;
    $self->_assert_source_unchanged($source_identity);
    $self->replay();
    my $old_bytes = $self->{file_identity} ? $self->{file_identity}[2] : 0;

    my ($temporary, $ready, $archive, $manifest_path, $manifest_tmp) = _compaction_paths($self->{path});
    for my $candidate ($temporary, $ready, $archive, $manifest_path, $manifest_tmp) {
        die 'journal compaction path must not be a symlink' if -l $candidate;
    }
    die 'an unfinished journal compaction artifact already exists'
        if grep { -e $_ } ($temporary, $ready, $archive, $manifest_path, $manifest_tmp);

    sysopen(my $tmp_fh, $temporary, O_CREAT | O_EXCL | O_WRONLY, 0600)
        or die "cannot create compacted journal temporary file: $!";
    binmode($tmp_fh, ':raw');
    my ($next_sequence, $previous, $new_bytes) = (1, '0' x 64, 0);
    my $emit = sub {
        my ($event, $data) = @_;
        die 'invalid journal event name'
            unless defined($event) && $event =~ /\A[a-z][a-z0-9_]{0,63}\z/;
        die 'journal event data must be an object' unless ref($data) eq 'HASH';
        my $record = {
            version => $VERSION,
            sequence => $next_sequence,
            event => $event,
            data => $data,
            previous_digest => $previous,
        };
        my $canonical = JSON::PP->new->canonical(1);
        $record->{digest} = sha256_hex($canonical->encode($record));
        my $line = $canonical->encode($record) . "\n";
        die 'journal event exceeds configured record limit'
            if length($line) > $self->{max_record_bytes};
        die 'compacted journal exceeds its configured byte limit'
            if $new_bytes + length($line) > $self->{max_journal_bytes};
        my $written = 0;
        while ($written < length($line)) {
            my $count = $self->_write_chunk($tmp_fh, $line, length($line) - $written, $written);
            die "compacted journal write failed: " . ($! || 'short write')
                unless defined($count) && $count > 0;
            $written += $count;
        }
        $new_bytes += length($line);
        $previous = $record->{digest};
        $next_sequence++;
        return $record->{sequence};
    };

    my $built = eval { $build_snapshot->($emit); 1 };
    unless ($built) {
        my $error = $@ || 'journal snapshot builder failed';
        close $tmp_fh;
        unlink($temporary) if -f $temporary && !-l $temporary;
        die $error;
    }
    unless ($self->_sync_handle($tmp_fh)) {
        my $error = $! || 'durable sync failed';
        close $tmp_fh;
        unlink($temporary) if -f $temporary && !-l $temporary;
        die "compacted journal durable sync failed: $error";
    }
    close $tmp_fh or do {
        my $error = $! || 'close failed';
        unlink($temporary) if -f $temporary && !-l $temporary;
        die "cannot close compacted journal: $error";
    };

    my $scan = eval { _scan_path($temporary, max_record_bytes => $self->{max_record_bytes}); };
    unless ($scan && $scan->{size} == $new_bytes &&
            $scan->{sequence} == $next_sequence - 1 && $scan->{tail_hash} eq $previous) {
        my $error = $@ || 'compacted journal failed its integrity check';
        unlink($temporary) if -f $temporary && !-l $temporary;
        die $error;
    }
    _rename_path($temporary, $ready) or do {
        my $error = $! || 'rename failed';
        unlink($temporary) if -f $temporary && !-l $temporary;
        die "cannot publish prepared journal snapshot: $error";
    };
    eval { _sync_directory($self->{path}); 1 } or do {
        my $error = $@ || 'cannot durably publish prepared journal snapshot';
        die $error;
    };

    $self->_assert_source_unchanged($source_identity);
    my $manifest = {
        source => _identity_from_scan({
            size => $self->{file_identity} ? $self->{file_identity}[2] : 0,
            sequence => $self->{sequence}, tail_hash => $self->{tail_hash},
        }),
        snapshot => _identity_from_scan($scan),
    };
    _write_compaction_manifest($self->{path}, $manifest);
    $self->_assert_ownership();
    my $was_healthy = $self->{healthy};
    my $old_path = $self->{path};
    my $old_fh = $self->{journal_fh};
    close($old_fh) or do {
        my $error = $! || 'close failed';
        $self->_mark_unhealthy("cannot close request journal for compaction: $error");
        die "cannot close request journal for compaction: $error";
    };
    $self->{journal_fh} = undef;

    unless (_rename_path($old_path, $archive)) {
        my $error = $! || 'rename failed';
        my $reopened = eval { $self->_reopen_journal_handle(); 1 };
        unless ($reopened) {
            my $reopen_error = $@ || 'cannot reopen original journal';
            $self->_mark_unhealthy($reopen_error);
            die "cannot stage current journal for compaction: $error; $reopen_error";
        }
        my $cleaned = eval {
            _remove_compaction_file($ready);
            _remove_compaction_file($manifest_path);
            _sync_directory($old_path);
            1;
        };
        unless ($cleaned) {
            my $cleanup_error = $@ || 'cannot clear failed compaction preparation';
            $self->_mark_unhealthy($cleanup_error);
            die "cannot stage current journal for compaction: $error; $cleanup_error";
        }
        $self->{healthy} = $was_healthy;
        die "cannot stage current journal for compaction: $error";
    }
    eval { _sync_directory($old_path); 1 } or do {
        my $error = $@ || 'cannot durably stage original journal';
        $self->_mark_unhealthy($error);
        die $error;
    };
    unless (_rename_path($ready, $old_path)) {
        my $error = $! || 'rename failed';
        unless (_rename_path($archive, $old_path)) {
            $self->_mark_unhealthy('compaction publication failed and the original journal could not be restored');
            die "cannot publish compacted journal or restore the original: $error; $!";
        }
        eval { _sync_directory($old_path); 1 } or do {
            my $sync_error = $@ || 'cannot durably restore the original journal';
            $self->_mark_unhealthy($sync_error);
            die "compaction publication failed; original path restored without durable directory sync: $sync_error";
        };
        my $restored = eval {
            $self->_reopen_journal_handle();
            $self->replay();
            1;
        };
        unless ($restored) {
            my $restore_error = $@ || 'cannot reopen the restored journal';
            $self->_mark_unhealthy($restore_error);
            die "compaction publication failed; the original path was restored but could not be reopened: $restore_error";
        }
        my $cleaned = eval {
            _remove_compaction_file($ready);
            _remove_compaction_file($manifest_path);
            _sync_directory($old_path);
            1;
        };
        unless ($cleaned) {
            my $cleanup_error = $@ || 'cannot clear failed compaction preparation';
            $self->_mark_unhealthy($cleanup_error);
            die "compaction publication failed; the original was restored but recovery metadata remains: $cleanup_error";
        }
        $self->{healthy} = $was_healthy;
        die "cannot publish compacted journal; original journal was restored: $error";
    }
    eval { _sync_directory($old_path); 1 } or do {
        my $error = $@ || 'cannot durably publish compacted journal';
        $self->_mark_unhealthy($error);
        die $error;
    };

    my $reopened = eval { $self->_reopen_journal_handle(); 1 };
    unless ($reopened) {
        my $error = $@ || 'cannot reopen compacted journal';
        $self->_mark_unhealthy($error);
        die $error;
    }
    my $replayed = eval { $self->replay(); 1 };
    unless ($replayed) {
        my $error = $@ || 'compacted journal could not be replayed';
        $self->_mark_unhealthy($error);
        die $error;
    }
    my $published_scan = _scan_path($old_path, max_record_bytes => $self->{max_record_bytes});
    unless (_scan_matches_identity($published_scan, $manifest->{snapshot})) {
        my $error = 'published journal does not match its durable compaction manifest';
        $self->_mark_unhealthy($error);
        die $error;
    }
    my $archive_scan = _scan_path($archive, max_record_bytes => $self->{max_record_bytes});
    unless (_scan_matches_identity($archive_scan, $manifest->{source})) {
        my $error = 'archived journal does not match its durable compaction manifest';
        $self->_mark_unhealthy($error);
        die $error;
    }
    _remove_compaction_file($archive);
    eval { _sync_directory($old_path); 1 } or do {
        my $error = $@ || 'cannot durably retire archived journal';
        $self->_mark_unhealthy($error);
        die $error;
    };
    _remove_compaction_file($manifest_path);
    eval { _sync_directory($old_path); 1 } or do {
        my $error = $@ || 'cannot durably retire compaction manifest';
        $self->_mark_unhealthy($error);
        die $error;
    };
    $self->{healthy} = 1;
    $self->{unhealthy_reason} = undef;
    $self->{unhealthy_notified} = 0;
    return {
        old_bytes => $old_bytes,
        new_bytes => $new_bytes,
        record_count => $scan->{sequence},
        sequence => $self->{sequence},
        source_identity => $manifest->{source},
        snapshot_identity => $manifest->{snapshot},
        file_identity => $published_scan->{file_identity},
    };
}

sub _reopen_journal_handle {
    my ($self) = @_;
    sysopen(my $journal_fh, $self->{path}, O_RDWR | O_APPEND, 0600)
        or die "cannot reopen request journal: $!";
    unless (flock($journal_fh, LOCK_EX | LOCK_NB)) {
        close $journal_fh;
        die 'another process owns the request journal data file';
    }
    binmode($journal_fh, ':raw');
    $self->{journal_fh} = $journal_fh;
    $self->{journal_identity} = _handle_identity($journal_fh);
    return 1;
}

sub page {
    my ($self, $after, $limit) = @_;
    die 'journal is not healthy' unless $self->healthy();
    $after = 0 unless defined($after) && length($after);
    $limit = 100 unless defined($limit) && length($limit);
    die 'invalid page cursor' unless $after =~ /\A\d+\z/;
    die 'page limit must be between 1 and 500' unless $limit =~ /\A\d+\z/ && $limit >= 1 && $limit <= 500;
    my @page;
    my $ok = eval {
        $self->replay(on_event => sub {
            my ($record) = @_;
            push @page, $record
                if $record->{sequence} > $after && @page < $limit;
        });
        1;
    };
    unless ($ok) {
        my $error = $@ || 'journal history could not be validated';
        $self->{healthy} = 0;
        die $error;
    }
    return \@page;
}

sub find_job {
    my ($self, $id) = @_;
    die 'invalid job ID' unless defined($id) && $id =~ /\Ajob-[a-f0-9]{32}\z/;
    my $found;
    my $ok = eval {
        $self->replay(on_event => sub {
            my ($record) = @_;
            return unless $record->{event} eq 'job_created' ||
                $record->{event} eq 'job_transition';
            my $job = $record->{data}{job};
            $found = $job if ref($job) eq 'HASH' && ($job->{id} // '') eq $id;
        });
        1;
    };
    unless ($ok) {
        my $error = $@ || 'journal history could not be validated';
        $self->{healthy} = 0;
        die $error;
    }
    return $found;
}

sub close {
    my ($self) = @_;
    return 1 unless $self->{opened};
    if ($self->{compaction_validation} && $self->{compaction_validation}{read_fh}) {
        close $self->{compaction_validation}{read_fh};
    }
    close $self->{journal_fh} if $self->{journal_fh};
    close $self->{lock_fh} if $self->{lock_fh};
    delete @{$self}{qw(compaction_validation journal_fh lock_fh)};
    $self->{opened} = 0;
    $self->{healthy} = 0;
    return 1;
}

sub DESTROY { eval { $_[0]->close() }; }

1;
