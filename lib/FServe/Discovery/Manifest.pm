package FServe::Discovery::Manifest;

use strict;
use warnings;
use utf8;

use Digest::SHA;
use Encode qw(decode FB_CROAK);
use Exporter qw(import);
use Fcntl qw(SEEK_SET);
use FServe::Model qw(new_remote_file normalize_remote_path size_to_bytes);
use POSIX qw(strftime);

our @EXPORT_OK = qw(new_provider);

sub new_provider {
    my (%args) = @_;
    my $self = bless {
        parsers      => [],
        known_paths  => [],
    }, __PACKAGE__;

    $self->register_parser(
        name       => 'box-tree-size-v1',
        detect     => \&_looks_like_tree_size_row,
        parse_line => \&_parse_tree_size_row,
    );
    _register_bracket_folders($self);

    if (ref($args{known_paths}) eq 'ARRAY') {
        $self->{known_paths} = [@{$args{known_paths}}];
    }
    if (ref($args{parsers}) eq 'ARRAY') {
        $self->register_parser(%$_) for @{$args{parsers}};
    }

    return $self;
}

sub register_parser {
    my ($self, %args) = @_;
    die 'manifest provider must be an object' unless ref($self) eq __PACKAGE__;
    die 'parser name is required'
        unless defined($args{name}) && $args{name} =~ /^[a-z0-9][a-z0-9-]*$/;
    die 'parser detect callback is required' unless ref($args{detect}) eq 'CODE';
    die 'parser parse_line callback is required' unless ref($args{parse_line}) eq 'CODE';
    die "duplicate manifest parser [$args{name}]"
        if grep { $_->{name} eq $args{name} } @{$self->{parsers}};

    die 'parser begin callback must be code' if defined($args{begin}) && ref($args{begin}) ne 'CODE';

    push @{$self->{parsers}}, {
        name       => $args{name},
        detect     => $args{detect},
        parse_line => $args{parse_line},
        # Called once a file is found to be in this format, for a reader
        # that keeps state from line to line (the folder it is in).
        ($args{begin} ? (begin => $args{begin}) : ()),
    };
    return $self;
}

# One file server's list sent on "@Nick" (2026-10-29), as a script beside
# FServe.pl writes it: a line or two about the server, then each folder as
# "[path/]" ("[]" for the top) and its files under it, indented, each
# "name   (size)":
#
#   100Mbps of Pen & Paper RPGs. Trigger: /ctcp Nick !nick
#   []
#     .stignore   (0 B)
#   [Books/Fantasy/]
#     A Title [_oef_].pdf   (9.74 MB)
#
# A folder's own name may hold "]"; its heading ends "/]".
#
# Lines before the first folder that are no file are the server's words and
# are passed over, a few at most; any other line is a malformed row.
our $BRACKET_PREAMBLE_LINES = 5;

sub _register_bracket_folders {
    my ($self) = @_;
    my %state;
    $self->register_parser(
        name   => 'bracket-folders-v1',
        detect => sub {
            my ($line) = @_;
            return defined(_bracket_heading($line)) || defined(_bracket_row($line)) ||
                $line =~ /\bTrigger:\s*\S/ ? 1 : 0;
        },
        begin => sub { %state = (folder => undef, preamble => 0) },
        parse_line => sub {
            my ($line) = @_;
            my $folder = _bracket_heading($line);
            if (defined $folder) {
                die "unsafe folder\n" if length($folder) &&
                    !defined(normalize_remote_path($folder));
                $state{folder} = $folder;
                return { is_directory => 1 };
            }
            my $row = _bracket_row($line);
            unless ($row) {
                die "not a row\n" if defined($state{folder}) ||
                    ++$state{preamble} > $BRACKET_PREAMBLE_LINES;
                return { skip => 1 };
            }
            my $where = $state{folder} // '';
            my $remote_path = normalize_remote_path(length($where)
                ? "$where/$row->{name}" : $row->{name});
            die "unsafe path\n" unless defined $remote_path;
            return { %$row, remote_path => $remote_path };
        },
    );
}

sub _bracket_heading {
    my ($line) = @_;
    return undef unless defined($line) && $line =~ m{\A\[((?:[^\x00-\x1f\x7f]*/)?)\]\s*\z};
    my $folder = $1;
    $folder =~ s{/\z}{};
    return undef if $folder =~ m{\A/|//};
    return $folder;
}

sub _bracket_row {
    my ($line) = @_;
    return undef unless defined($line) && $line =~
        /\A[ \t]+(\S.*?)[ \t]{2,}\(([0-9]+(?:\.[0-9]+)?)[ ]?(B|[kKMGT]i?B)\)[ \t]*\z/;
    my ($name, $number, $unit) = ($1, $2, $3);
    return undef if $name =~ m{[/\\\x00-\x1f\x7f]} || $name eq '.' || $name eq '..';
    my $exact = $unit eq 'B';
    return undef if $exact && $number =~ /\./;
    return {
        name             => $name,
        size_raw         => "$number $unit",
        size_bytes       => $exact ? 0 + $number : size_to_bytes("$number $unit"),
        size_is_estimate => $exact ? 0 : 1,
        is_directory     => 0,
    };
}

sub discover_candidates {
    my ($self, $items, %args) = @_;
    die 'manifest provider must be an object' unless ref($self) eq __PACKAGE__;
    return [] unless ref($items) eq 'ARRAY';

    my @known = @{$self->{known_paths} || []};
    push @known, @{$args{known_paths}}
        if ref($args{known_paths}) eq 'ARRAY';
    my (%known_global, %known_scoped);
    for my $path (@known) {
        my ($raw_path, $scope);
        if (ref($path) eq 'HASH') {
            $raw_path = $path->{path} // $path->{remote_path};
            $scope = _candidate_scope($path, '');
        } else {
            $raw_path = $path;
        }
        my $normalized = normalize_remote_path($raw_path);
        next unless defined $normalized;
        if (defined($scope) && length($scope)) {
            $known_scoped{$scope . "\x1f" . $normalized} = 1;
        } else {
            # Legacy unscoped entries remain useful for single-route callers;
            # multi-route configuration should use {path, ...route fields}.
            $known_global{$normalized} = 1;
        }
    }

    my (@candidates, %seen);
    for my $position (0 .. $#$items) {
        my $item = $items->[$position];
        next unless ref($item) eq 'HASH';
        next if _is_directory($item);

        my $raw_path = $item->{remote_path} // $item->{path} // $item->{name};
        next unless defined($raw_path) &&
            $raw_path !~ /[\x00-\x1f\x7f]/ &&
            $raw_path !~ m{^(?:[A-Za-z]:|\\\\)};
        my $path = normalize_remote_path($raw_path);
        next unless defined $path;
        my $scope = _candidate_scope($item, '');
        my $key = $scope . "\x1f" . $path;
        next if $seen{$key}++;

        my $is_known = $known_global{$path} || $known_scoped{$scope . "\x1f" . $path};
        my ($score, $reason) = _candidate_score($path, $is_known);
        next unless $score;
        push @candidates, {
            index       => $position + 1,
            remote_path => $path,
            score       => $score,
            reason      => $reason,
            source      => $item->{source},
            item        => { %$item },
            _position   => $position,
        };
    }

    @candidates = sort {
        $b->{score} <=> $a->{score} || $a->{_position} <=> $b->{_position}
    } @candidates;
    delete $_->{_position} for @candidates;

    if (defined($args{limit}) && $args{limit} =~ /^\d+$/ && $args{limit} > 0) {
        splice @candidates, $args{limit} if @candidates > $args{limit};
    }
    return \@candidates;
}

sub _candidate_scope {
    my ($item) = @_;
    return join "\x1f", map { defined($_) ? $_ : '' } (
        $item->{network_id}, $item->{server_tag}, $item->{server_nick},
        $item->{trigger_raw}, $item->{trigger_mode}, $item->{discovery_channel},
    );
}

sub _candidate_score {
    my ($path, $is_known) = @_;
    return (1000, 'configured exact path') if $is_known;

    my ($basename) = $path =~ m{([^/]+)$};
    return (0, undef) unless defined $basename;
    return (0, undef) unless $basename =~ /\.(?:txt|list|lst|csv|json|xml)$/i;

    return (120, 'full files list name')
        if $basename =~ /\bfull[\s._-]*files?[\s._-]*list\b/i;
    return (100, 'files list name')
        if $basename =~ /\bfiles?[\s._-]*list\b/i;
    return (80, 'inventory or catalog name')
        if $basename =~ /\b(?:inventory|catalog|file[-_ .]*index)\b/i;
    return (0, undef);
}

sub _is_directory {
    my ($item) = @_;
    return 1 if ($item->{type} // '') eq 'dir';
    return 1 if ($item->{kind} // '') eq 'directory';
    return 1 if $item->{is_directory};
    return 0;
}

sub parse_file {
    my ($self, $path, %args) = @_;
    die 'manifest provider must be an object' unless ref($self) eq __PACKAGE__;
    die 'manifest path is required' unless defined($path) && length($path);
    die 'on_record must be a code reference'
        if defined($args{on_record}) && ref($args{on_record}) ne 'CODE';

    my $context = _validated_context(%args);
    my %limits = _validated_limits(%args);
    open my $fh, '<:raw', $path or return {
        ok     => 0,
        reason => "could not open manifest: $!",
    };

    my $first = _scan_handle($self, $fh, $context, undef, \%limits);
    unless ($first->{ok}) {
        close $fh;
        return $first;
    }
    unless (close $fh) {
        return { %$first, ok => 0, reason => "could not close manifest after validation: $!" };
    }

    if (my $callback = $args{on_record}) {
        open $fh, '<:raw', $path or return {
            %$first, ok => 0, reason => "could not reopen manifest for emission: $!",
        };
        seek($fh, 0, SEEK_SET) or do {
            close $fh;
            return { %$first, ok => 0, reason => "could not rewind manifest: $!" };
        };
        my $second = _scan_handle($self, $fh, $context, $callback, \%limits);
        my $closed = close $fh;
        if (!$closed && $second->{ok}) {
            $second->{ok} = 0;
            $second->{reason} = "could not close manifest after emission: $!";
        }
        unless ($second->{ok} && $second->{sha256} eq $first->{sha256}) {
            return {
                %$first,
                ok     => 0,
                reason => $second->{reason} || 'manifest changed between validation and emission passes',
                records_emitted => $second->{files} || 0,
            };
        }
        $first->{records_emitted} = $second->{files};
    } else {
        close $fh;
        $first->{records_emitted} = 0;
    }

    return $first;
}

sub _validated_limits {
    my (%args) = @_;
    my %limits = (
        max_line_bytes   => defined($args{max_line_bytes}) ? $args{max_line_bytes} : 65_536,
        max_source_bytes => defined($args{max_source_bytes}) ? $args{max_source_bytes} : 1_073_741_824,
        max_rows         => defined($args{max_rows}) ? $args{max_rows} : 5_000_000,
        max_seconds      => defined($args{max_seconds}) ? $args{max_seconds} : 1_800,
        should_cancel    => $args{should_cancel},
    );
    for my $name (qw(max_line_bytes max_source_bytes max_rows max_seconds)) {
        die "$name must be a positive number"
            unless defined($limits{$name}) && $limits{$name} =~ /^\d+(?:\.\d+)?$/ && $limits{$name} > 0;
    }
    die 'max_line_bytes must not exceed max_source_bytes'
        if $limits{max_line_bytes} > $limits{max_source_bytes};
    die 'should_cancel must be a code reference'
        if defined($limits{should_cancel}) && ref($limits{should_cancel}) ne 'CODE';
    return %limits;
}

sub _validated_context {
    my (%args) = @_;
    for my $required (qw(server_nick trigger_raw)) {
        die "$required is required to normalize manifest records"
            unless defined($args{$required}) && length($args{$required});
    }
    my $mode = defined($args{trigger_mode}) ? $args{trigger_mode} : 'unknown';
    die 'trigger_mode must be channel_text, ctcp, or unknown'
        unless $mode =~ /^(?:channel_text|ctcp|unknown)$/;

    my $manifest_remote_path;
    if (defined($args{manifest_remote_path}) && length($args{manifest_remote_path})) {
        $manifest_remote_path = normalize_remote_path($args{manifest_remote_path});
        die 'manifest_remote_path must be a safe root-relative path'
            unless defined $manifest_remote_path &&
                $args{manifest_remote_path} !~ m{^(?:[A-Za-z]:|\\\\)};
    }

    my $timestamp = $args{source_timestamp};
    $timestamp = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()) unless defined($timestamp) && length($timestamp);
    die 'source_timestamp may not contain control characters'
        if $timestamp =~ /[\x00-\x1f\x7f]/;

    return {
        network_id          => $args{network_id},
        server_tag          => $args{server_tag},
        server_nick         => $args{server_nick},
        trigger_raw         => $args{trigger_raw},
        trigger_mode        => $mode,
        discovery_channel   => $args{discovery_channel},
        source_timestamp    => $timestamp,
        manifest_remote_path => $manifest_remote_path,
    };
}

sub _scan_handle {
    my ($self, $fh, $context, $on_record, $limits) = @_;
    $limits ||= {
        max_line_bytes => 65_536, max_source_bytes => 1_073_741_824,
        max_rows => 5_000_000, max_seconds => 1_800,
    };
    my $digest = Digest::SHA->new(256);
    my $started = time();
    my %stats = (
        ok               => 0,
        format           => undef,
        lines            => 0,
        rows             => 0,
        files            => 0,
        directories      => 0,
        estimated_sizes  => 0,
        bytes_read       => 0,
    );
    my $format;

    my $pending = '';
    my $consume = sub {
        my ($raw) = @_;
        $stats{lines}++;
        $raw =~ s/\n\z//;
        $raw =~ s/\r\z//;
        my $line = eval { decode('UTF-8', $raw, FB_CROAK) };
        if ($@) {
            $stats{reason} = "invalid UTF-8 at line $stats{lines}";
            return 0;
        }
        $line =~ s/\A\x{FEFF}// if $stats{lines} == 1;
        $line =~ s/\r?\n\z//;
        return 1 if $line =~ /^\s*$/;

        if (!$format) {
            ($format) = grep { $_->{detect}->($line) } @{$self->{parsers}};
            unless ($format) {
                $stats{reason} = "unrecognized manifest format at line $stats{lines}";
                return 0;
            }
            $stats{format} = $format->{name};
            $format->{begin}->() if $format->{begin};
        }

        my $row = eval { $format->{parse_line}->($line) };
        if ($@ || ref($row) ne 'HASH') {
            $stats{reason} = "malformed $format->{name} row at line $stats{lines}";
            return 0;
        }
        return 1 if $row->{skip};
        $stats{rows}++;
        if ($stats{rows} > $limits->{max_rows}) {
            $stats{reason} = "manifest exceeds the $limits->{max_rows}-row limit";
            return 0;
        }

        if ($row->{is_directory}) {
            $stats{directories}++;
            return 1;
        }

        my $record = eval {
            new_remote_file(
                %$context,
                remote_path          => $row->{remote_path},
                size_raw             => $row->{size_raw},
                size_bytes           => $row->{size_bytes},
                size_is_estimate     => $row->{size_is_estimate},
                source               => 'manifest',
                manifest_format      => $format->{name},
                manifest_remote_path => $context->{manifest_remote_path},
            );
        };
        if ($@ || ref($record) ne 'HASH') {
            $stats{reason} = "unsafe path or invalid record at line $stats{lines}";
            return 0;
        }
        $stats{files}++;
        $stats{estimated_sizes}++ if $row->{size_is_estimate};
        if ($on_record) {
            my $ok = eval { $on_record->($record); 1 };
            unless ($ok) {
                my $error = $@ || 'record callback failed';
                $error =~ s/[\r\n]+/ /g;
                $stats{reason} = "record callback failed at line $stats{lines}: $error";
                return 0;
            }
        }
        return 1;
    };

    while (1) {
        my $chunk;
        local $! = 0;
        my $read = sysread($fh, $chunk, 8_192);
        unless (defined $read) {
            $stats{reason} = "manifest read failed after $stats{bytes_read} bytes: $!";
            return \%stats;
        }
        last if $read == 0;
        $stats{bytes_read} += $read;
        if ($stats{bytes_read} > $limits->{max_source_bytes}) {
            $stats{reason} = "manifest exceeds the $limits->{max_source_bytes}-byte limit";
            return \%stats;
        }
        $digest->add($chunk);
        if ($limits->{should_cancel}) {
            my $cancelled = eval { $limits->{should_cancel}->() };
            if ($@ || $cancelled) {
                $stats{reason} = 'manifest parsing was cancelled';
                return \%stats;
            }
        }
        if (time() - $started > $limits->{max_seconds}) {
            $stats{reason} = "manifest exceeded the $limits->{max_seconds}-second time limit";
            return \%stats;
        }
        $pending .= $chunk;
        while ((my $newline = index($pending, "\n")) >= 0) {
            my $raw = substr($pending, 0, $newline + 1, '');
            if (length($raw) > $limits->{max_line_bytes}) {
                $stats{reason} = "manifest line exceeds the $limits->{max_line_bytes}-byte limit";
                return \%stats;
            }
            unless ($consume->($raw)) {
                return \%stats;
            }
        }
        if (length($pending) > $limits->{max_line_bytes}) {
            $stats{reason} = "manifest line exceeds the $limits->{max_line_bytes}-byte limit";
            return \%stats;
        }
    }
    if (length $pending) {
        unless ($consume->($pending)) {
            return \%stats;
        }
    }

    $stats{sha256} = $digest->hexdigest;
    unless ($stats{rows}) {
        $stats{reason} = 'manifest contains no recognizable rows';
        return \%stats;
    }
    $stats{ok} = 1;
    return \%stats;
}

sub _looks_like_tree_size_row {
    my ($line) = @_;
    return defined(_parse_tree_size_row($line));
}

sub _parse_tree_size_row {
    my ($line) = @_;
    return unless defined $line;

    my $opening = index($line, '[');
    return if $opening < 0;
    my $prefix = substr($line, 0, $opening);
    return unless $prefix =~ /^[\p{Zs}\t│├└─]*$/u;

    my $body = substr($line, $opening);
    return unless $body =~ /^\[\s*(\d+(?:\.\d+)?\s*(?:B|BYTES?|K(?:I?B)?|M(?:I?B)?|G(?:I?B)?|T(?:I?B)?)?)\s*\]\s{2,}(.+?)\s*$/i;
    my ($size_raw, $path) = ($1, $2);
    $size_raw =~ s/^\s+|\s+$//g;
    return if $path =~ /[\x00-\x1f\x7f]/;
    return if $path =~ m{^(?:[/\\]|[A-Za-z]:)};
    return if $path =~ m{(?:^|[/\\])(?:\.|\.\.)(?:[/\\]|$)};
    return if $path =~ m{[/\\]{2,}};

    my ($number, $unit) = $size_raw =~ /^(\d+(?:\.\d+)?)\s*([A-Za-z]*)$/;
    return unless defined $number;
    my $numeric_size = 0 + $number;
    my $bytes;
    my $estimate = 0;
    if (!length($unit)) {
        return if $number =~ /\./;
        $bytes = 0 + $number;
    } else {
        my $convertible_size = $unit =~ /^[KMGT]$/i
            ? $size_raw . 'B'
            : $size_raw;
        $bytes = size_to_bytes($convertible_size);
        return unless defined $bytes;
        $estimate = $unit =~ /^[KMGT]/i ? 1 : 0;
    }

    my $remote_path = normalize_remote_path($path);
    return unless defined $remote_path;

    return {
        remote_path      => $remote_path,
        size_raw         => $size_raw,
        size_bytes       => $bytes,
        size_is_estimate => $estimate,
        is_directory     => $numeric_size == 0 ? 1 : 0,
    };
}

1;
