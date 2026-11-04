package FServe::Discovery::SearchBot;

use strict;
use warnings;

use bytes ();
use Digest::SHA qw(sha256_hex);
use FServe::Model qw(identity_key new_remote_file size_to_bytes split_remote_path);
use FServe::Discovery::SearchBotRequest qw(validate_candidate);

my $DEFAULT_MAX_RESULTS = 3000;
my $HARD_MAX_RESULTS = 10000;
my $DEFAULT_MAX_LINE_LENGTH = 8192;
my $HARD_MAX_LINE_LENGTH = 65536;
my $DEFAULT_MAX_INPUT_BYTES = 32 * 1024 * 1024;
my $HARD_MAX_INPUT_BYTES = 256 * 1024 * 1024;
my $NEXT_COLLECTION_ID = 0;

sub new {
    my ($class, %args) = @_;

    my $max_results = defined($args{max_results})
        ? $args{max_results} : $DEFAULT_MAX_RESULTS;
    die 'max_results must be a positive integer no greater than 10000'
        unless $max_results =~ /\A[1-9][0-9]*\z/ && $max_results <= $HARD_MAX_RESULTS;

    my $max_line_length = defined($args{max_line_length})
        ? $args{max_line_length} : $DEFAULT_MAX_LINE_LENGTH;
    die 'max_line_length must be a positive integer no greater than 65536'
        unless $max_line_length =~ /\A[1-9][0-9]*\z/ &&
            $max_line_length <= $HARD_MAX_LINE_LENGTH;

    my $max_input_bytes = defined($args{max_input_bytes})
        ? $args{max_input_bytes} : $DEFAULT_MAX_INPUT_BYTES;
    die 'max_input_bytes must be a positive integer no greater than 268435456'
        unless $max_input_bytes =~ /\A[1-9][0-9]*\z/ &&
            $max_input_bytes <= $HARD_MAX_INPUT_BYTES;

    my $collection_id = $args{collection_id};
    unless (defined($collection_id) && length($collection_id)) {
        ++$NEXT_COLLECTION_ID;
        $collection_id = sha256_hex(join "\0",
            $args{network_id} // '',
            $args{server_tag} // '',
            $args{discovery_channel} // '',
            $args{query} // '',
            $$, time, rand(), $NEXT_COLLECTION_ID,
        );
    }
    die 'collection_id must not contain control characters'
        if $collection_id =~ /[\x00-\x1f\x7f]/;

    my $query = $args{query};
    die 'query must not contain control characters'
        if defined($query) && $query =~ /[\x00-\x1f\x7f]/;

    return bless {
        network_id        => $args{network_id},
        server_tag        => $args{server_tag},
        discovery_channel => $args{discovery_channel},
        source_timestamp  => $args{source_timestamp},
        query             => $query,
        collection_id     => $collection_id,
        max_results       => 0 + $max_results,
        max_line_length   => 0 + $max_line_length,
        max_input_bytes   => 0 + $max_input_bytes,
        input_bytes       => 0,
        line_number       => 0,
        results           => [],
        by_id             => {},
        state             => 'collecting',
    }, $class;
}

sub _copy_candidate {
    my ($candidate) = @_;
    return { %{$candidate || {}} };
}

sub _clean_line {
    my ($raw) = @_;
    $raw = '' unless defined $raw;

    $raw =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g;
    $raw =~ s/\x03(?:\d{1,2})?(?:,\d{1,2})?//g;
    $raw =~ s/[\x02\x0F\x11\x16\x1D\x1E\x1F]//g;
    $raw =~ s/[\r\n\0]+//g;
    $raw =~ s/^\s+//;
    $raw =~ s/\s+$//;
    return $raw;
}

sub _refuse {
    my ($self, $reason, %extra) = @_;
    $self->{state} = 'refused';
    $self->{results} = [];
    $self->{by_id} = {};
    return [{ type => 'refusal', reason => $reason, %extra }];
}

sub feed_line {
    my ($self, $raw_line, %args) = @_;
    return [{ type => 'refusal', reason => 'result collection is not active' }]
        unless $self->{state} eq 'collecting';

    ++$self->{line_number};
    my $line_bytes = defined($raw_line) ? bytes::length($raw_line) : 0;
    return $self->_refuse('result line exceeds configured length',
        line_number => $self->{line_number})
        if $line_bytes > $self->{max_line_length};
    $self->{input_bytes} += $line_bytes;
    return $self->_refuse('result input exceeds configured byte bound',
        line_number => $self->{line_number}, max_input_bytes => $self->{max_input_bytes})
        if $self->{input_bytes} > $self->{max_input_bytes};

    my $request_line = defined($raw_line) ? $raw_line : '';
    $request_line =~ s/\r\z// if $args{physical_crlf};
    my $line = _clean_line($raw_line);
    return [] unless length $line;

    # The SearchBot list format observed in client and result-file evidence
    # starts each file row with a route command such as !ExampleBot. Other
    # lines are headers/summary text and are not treated as files.
    return [] unless $line =~ /^!/;

    return $self->_refuse('malformed SearchBot result row',
        line_number => $self->{line_number}, text => $line)
        unless $line =~ /\A(![^\s\x00-\x1f\x7f]{1,127})[\t ]+(.+)\z/;

    my ($route_trigger, $remainder) = ($1, $2);
    my ($filename, $info_raw, $hash_raw);
    my $info_markers = () = $remainder =~ /::INFO::/ig;
    return $self->_refuse('ambiguous repeated ::INFO:: field',
        line_number => $self->{line_number}, text => $line)
        if $info_markers > 1;

    if ($info_markers) {
        return $self->_refuse('malformed SearchBot ::INFO:: field',
            line_number => $self->{line_number}, text => $line)
            unless $remainder =~ /\A(.*?)\s+::INFO::\s*(.*?)\s*\z/i;
        ($filename, $info_raw) = ($1, $2);
        return $self->_refuse('empty SearchBot ::INFO:: value',
            line_number => $self->{line_number}, text => $line)
            unless length $info_raw;
    } else {
        $filename = $remainder;
    }

    my $hash_markers = () = $remainder =~ /::HASH::/ig;
    return $self->_refuse('ambiguous repeated ::HASH:: field',
        line_number => $self->{line_number}, text => $line)
        if $hash_markers > 1;
    if ($hash_markers) {
        my $hash_is_in_info = defined($info_raw) && $info_raw =~ /::HASH::/i;
        my $hash_field = $hash_is_in_info ? $info_raw : $filename;
        return $self->_refuse('malformed SearchBot ::HASH:: field',
            line_number => $self->{line_number}, text => $line)
            unless $hash_field =~ /\A(.*?)\s+::HASH::\s*([^\s]+)\s*\z/i;
        my ($before_hash, $parsed_hash) = ($1, $2);
        return $self->_refuse('empty SearchBot ::HASH:: value',
            line_number => $self->{line_number}, text => $line)
            unless length $parsed_hash;
        $hash_raw = $parsed_hash;
        if ($hash_is_in_info) {
            $info_raw = $before_hash;
            return $self->_refuse('empty SearchBot ::INFO:: value',
                line_number => $self->{line_number}, text => $line)
                unless length $info_raw;
        } else {
            $filename = $before_hash;
        }
    }

    # Some SearchBot list producers place a digest token between the route
    # command and the display filename. Preserve it, but do not use it as a
    # path or as a substitute for live parent verification.
    my $prefix_hash;
    if ($filename =~ /\A(%[a-f\d]{8,64}%)[\t ]+(.+)\z/i) {
        ($prefix_hash, $filename) = ($1, $2);
    } elsif ($filename =~ /\A([a-f\d]{12})[\t ]+\|[\t ]+(.+)\z/i) {
        ($prefix_hash, $filename) = ($1, $2);
    } elsif ($filename =~ /\A([a-z\d+\/]{22})[\t ]+-[\t ]+(.+)\z/i) {
        ($prefix_hash, $filename) = ($1, $2);
    }
    if (defined $prefix_hash) {
        return $self->_refuse('SearchBot row contains multiple hash fields',
            line_number => $self->{line_number}, text => $line)
            if defined $hash_raw;
        $hash_raw = $prefix_hash;
    }

    # SearchBot variants also append a rounded size without an ::INFO:: tag.
    # Only remove a suffix that parses as a known byte unit.
    unless (defined $info_raw) {
        my $size_expression = qr/[0-9]+(?:\.[0-9]+)?[\t ]*(?:B|BYTES?|K(?:I)?B|M(?:I)?B|G(?:I)?B|T(?:I)?B)/i;
        if ($filename =~ /\A(.+?)(?:[\t ]+-[\t ]*|[\t ]+)($size_expression)[\t ]*\z/i) {
            my ($name_without_size, $size_suffix) = ($1, $2);
            if (defined size_to_bytes($size_suffix)) {
                $filename = $name_without_size;
                $info_raw = $size_suffix;
            }
        }
    }

    $filename =~ s/^[\t ]+//;
    $filename =~ s/[\t ]+$//;
    return $self->_refuse('empty SearchBot filename',
        line_number => $self->{line_number}, text => $line)
        unless length $filename;
    return $self->_refuse('SearchBot filename contains control characters',
        line_number => $self->{line_number}, text => $line)
        if $filename =~ /[\x00-\x1f\x7f]/;

    return $self->_refuse('SearchBot result count exceeds configured bound',
        line_number => $self->{line_number}, max_results => $self->{max_results})
        if @{$self->{results}} >= $self->{max_results};

    my $candidate_id = sha256_hex(join "\0",
        $self->{network_id} // '',
        $self->{server_tag} // '',
        $self->{discovery_channel} // '',
        $self->{collection_id},
        $self->{line_number},
        $route_trigger,
        $filename,
        defined($info_raw) ? $info_raw : '',
        defined($hash_raw) ? $hash_raw : '',
        sha256_hex($request_line),
    );
    my $size_bytes = defined($info_raw) ? size_to_bytes($info_raw) : undef;
    my $candidate = {
        type              => 'search_candidate',
        provider          => 'searchbot',
        candidate_id      => $candidate_id,
        collection_id     => $self->{collection_id},
        result_row        => $self->{line_number},
        result_ordinal    => scalar(@{$self->{results}}) + 1,
        route_trigger     => $route_trigger,
        filename          => $filename,
        request_line      => $request_line,
        request_line_digest => sha256_hex($request_line),
        info_raw          => $info_raw,
        hash_raw          => $hash_raw,
        size_bytes        => $size_bytes,
        network_id        => $self->{network_id},
        server_tag        => $self->{server_tag},
        discovery_channel => $self->{discovery_channel},
        query             => $self->{query},
        source_timestamp  => $self->{source_timestamp},
    };
    $candidate->{direct_requestable} = 1;
    my $direct = validate_candidate($candidate,
        channel => $self->{discovery_channel});
    $candidate->{direct_requestable} = ($direct->{type} // '') eq 'valid' ? 1 : 0;
    $candidate->{direct_refusal_reason} = $direct->{reason}
        unless $candidate->{direct_requestable};
    push @{$self->{results}}, $candidate;
    $self->{by_id}{$candidate_id} = $candidate;

    return [{
        type       => 'row_staged',
        candidate  => _copy_candidate($candidate),
        publishable => 0,
    }];
}

sub finish {
    my ($self) = @_;
    return { type => 'refusal', reason => 'result collection is not active' }
        unless $self->{state} eq 'collecting';
    unless (@{$self->{results}}) {
        my $events = $self->_refuse('no SearchBot result rows were recognized');
        return $events->[0];
    }

    $self->{state} = 'complete';
    return {
        type          => 'complete',
        collection_id => $self->{collection_id},
        result_count  => scalar @{$self->{results}},
        results       => [map { _copy_candidate($_) } @{$self->{results}}],
    };
}

sub abort {
    my ($self, $reason) = @_;
    return { type => 'aborted', reason => ($reason // 'result collection aborted') }
        if $self->{state} eq 'aborted';
    $self->{results} = [];
    $self->{by_id} = {};
    $self->{state} = 'aborted';
    return { type => 'aborted', reason => ($reason // 'result collection aborted') };
}

sub normalize_candidate {
    my ($self, $candidate_id, %resolved) = @_;
    die 'SearchBot result collection must be complete before normalization'
        unless $self->{state} eq 'complete';
    die 'unknown or stale SearchBot candidate id'
        unless defined($candidate_id) &&
            exists $self->{by_id}{$candidate_id} &&
            $self->{by_id}{$candidate_id}{collection_id} eq $self->{collection_id};
    die 'resolved server_nick is required'
        unless defined($resolved{server_nick}) && $resolved{server_nick} =~ /\A[^\s\x00-\x1f\x7f]{1,64}\z/;
    die 'an exact live remote_path is required'
        unless defined($resolved{remote_path}) && length($resolved{remote_path});
    die 'trigger_mode must be explicitly resolved as channel_text or ctcp'
        unless defined($resolved{trigger_mode}) &&
            $resolved{trigger_mode} =~ /\A(?:channel_text|ctcp)\z/;

    my $candidate = $self->{by_id}{$candidate_id};
    my ($remote_path, $parent_path, $basename) = split_remote_path($resolved{remote_path});
    die 'resolved remote_path is invalid'
        unless defined $remote_path;
    die 'resolved remote_path basename does not exactly match the SearchBot filename'
        unless $basename eq $candidate->{filename};

    my $size_raw = defined($candidate->{size_bytes}) ? $candidate->{info_raw} : undef;
    return new_remote_file(
        network_id            => $candidate->{network_id},
        server_tag            => $candidate->{server_tag},
        server_nick           => $resolved{server_nick},
        trigger_raw           => $candidate->{route_trigger},
        trigger_mode          => $resolved{trigger_mode},
        remote_path           => $remote_path,
        size_raw              => $size_raw,
        size_bytes            => $candidate->{size_bytes},
        size_precision        => defined($size_raw) ? 'estimated' : 'unknown',
        size_source           => defined($size_raw) ? 'searchbot' : 'unknown',
        source                => 'searchbot',
        source_timestamp      => $candidate->{source_timestamp},
        discovery_channel     => $candidate->{discovery_channel},
        searchbot_collection_id => $candidate->{collection_id},
        searchbot_candidate_id  => $candidate->{candidate_id},
        searchbot_result_row    => $candidate->{result_row},
        searchbot_query         => $candidate->{query},
        searchbot_route_trigger => $candidate->{route_trigger},
        searchbot_info_raw      => $candidate->{info_raw},
        searchbot_hash_raw      => $candidate->{hash_raw},
    );
}

sub normalize_candidate_from_catalog {
    my ($self, $candidate_id, $records) = @_;
    die 'catalog records must be an array reference'
        unless ref($records) eq 'ARRAY';
    die 'SearchBot result collection must be complete before normalization'
        unless $self->{state} eq 'complete';
    die 'unknown or stale SearchBot candidate id'
        unless defined($candidate_id) &&
            exists $self->{by_id}{$candidate_id} &&
            $self->{by_id}{$candidate_id}{collection_id} eq $self->{collection_id};

    my $candidate = $self->{by_id}{$candidate_id};
    my $candidate_network = lc(
        defined($candidate->{network_id}) && length($candidate->{network_id})
            ? $candidate->{network_id} : ($candidate->{server_tag} // '')
    );
    my $candidate_channel = lc($candidate->{discovery_channel} // '');
    die 'SearchBot candidate lacks network or channel identity'
        unless length($candidate_network) && length($candidate_channel);

    my %matches;
    for my $record (@$records) {
        next unless ref($record) eq 'HASH' && ($record->{type} // '') eq 'file';
        my $record_network = lc(
            defined($record->{network_id}) && length($record->{network_id})
                ? $record->{network_id} : ($record->{server_tag} // '')
        );
        next unless length($record_network) && $record_network eq $candidate_network;
        next unless lc($record->{trigger_raw} // '') eq lc($candidate->{route_trigger});
        next unless ($record->{trigger_mode} // 'unknown') =~ /\A(?:channel_text|ctcp)\z/;
        next unless defined($record->{basename}) &&
            $record->{basename} eq $candidate->{filename};

        my @record_channels = ref($record->{discovery_channels}) eq 'ARRAY'
            ? @{$record->{discovery_channels}} : ();
        push @record_channels, $record->{discovery_channel}
            if defined($record->{discovery_channel}) && length($record->{discovery_channel});
        my %record_channels = map { lc($_) => 1 }
            grep { defined($_) && length($_) } @record_channels;
        next unless $record_channels{$candidate_channel};
        next unless defined($record->{server_nick}) && length($record->{server_nick});
        next unless defined($record->{remote_path}) && length($record->{remote_path});

        $matches{identity_key($record)} = $record;
    }

    my @matches = values %matches;
    die 'SearchBot result has no exact route/path match in the local catalog'
        unless @matches;
    die 'SearchBot result maps to multiple catalog paths; refusing ambiguous selection'
        unless @matches == 1;

    my $record = $matches[0];
    return $self->normalize_candidate(
        $candidate_id,
        server_nick  => $record->{server_nick},
        remote_path  => $record->{remote_path},
        trigger_mode => $record->{trigger_mode},
    );
}

1;
