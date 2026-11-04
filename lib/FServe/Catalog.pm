package FServe::Catalog;

use strict;
use warnings;
use Exporter qw(import);
use Fcntl qw(O_CREAT O_RDWR LOCK_EX);
use FServe::Model qw(identity_key new_remote_file);
use JSON::PP qw(decode_json);

our @EXPORT_OK = qw(
    add_record
    append_observation
    append_observations
    count_type
    files
    load_jsonl
    matching_files
    new_store
    record_count
    records
    search_records
    write_catalog
);

sub new_store {
    # Insertion order is the durable browse index; duplicate observations
    # update provenance in place instead of moving a row.
    return {
        records     => [],
        by_identity => {},
    };
}

sub _normalize_observation {
    my ($input) = @_;
    die 'catalog observation must be a hash reference'
        unless ref($input) eq 'HASH';
    die 'catalog observation must describe a file'
        unless ($input->{type} // 'file') eq 'file';

    my $record = new_remote_file(%$input);
    for my $key (qw(
        discovery_block_id discovery_channel
        manifest_format manifest_remote_path
        searchbot_collection_id searchbot_candidate_id searchbot_result_row
        searchbot_query searchbot_route_trigger searchbot_info_raw searchbot_hash_raw
    )) {
        $record->{$key} = $input->{$key} if exists $input->{$key};
    }
    return $record;
}

sub _source_names {
    my ($input, $normalized) = @_;
    my @sources = ref($input->{sources}) eq 'ARRAY'
        ? @{$input->{sources}}
        : ($normalized->{source});
    my %seen;
    return grep { defined($_) && length($_) && !$seen{$_}++ } @sources;
}

sub _observation_channels {
    my ($input) = @_;
    my @channels = ref($input->{discovery_channels}) eq 'ARRAY'
        ? @{$input->{discovery_channels}} : ();
    push @channels, $input->{discovery_channel}
        if defined($input->{discovery_channel}) && length($input->{discovery_channel});
    my %seen;
    return grep { defined($_) && length($_) && !$seen{$_}++ } @channels;
}

sub add_record {
    my ($store, $input) = @_;
    die 'catalog store must be a hash reference' unless ref($store) eq 'HASH';
    $store->{records} = [] unless ref($store->{records}) eq 'ARRAY';
    $store->{by_identity} = {} unless ref($store->{by_identity}) eq 'HASH';

    my $observation = _normalize_observation($input);
    my @sources = _source_names($input, $observation);
    my @channels = _observation_channels($input);
    my $key = identity_key($observation);
    my $existing = $store->{by_identity}{$key};

    if (!$existing) {
        $observation->{sources} = [@sources];
        $observation->{source} = @sources > 1 ? 'multiple' : ($sources[0] // 'unknown');
        my %source_timestamps = ref($input->{source_timestamps}) eq 'HASH'
            ? %{$input->{source_timestamps}}
            : (defined($observation->{source_timestamp})
                ? map { $_ => $observation->{source_timestamp} } @sources
                : ());
        $observation->{source_timestamps} = \%source_timestamps;
        $observation->{discovery_channels} = [@channels];
        $observation->{source_channels} = {
            map { $_ => [@channels] } @sources
        };
        $observation->{first_seen} = $input->{first_seen}
            // $observation->{source_timestamp};
        $observation->{last_seen} = $input->{last_seen}
            // $observation->{source_timestamp};
        push @{$store->{records}}, $observation;
        $store->{by_identity}{$key} = $observation;
        return $observation;
    }

    my %known_sources = map { $_ => 1 } @{$existing->{sources} || []};
    push @{$existing->{sources}}, grep { !$known_sources{$_}++ } @sources;
    $existing->{source} = @{$existing->{sources}} > 1
        ? 'multiple'
        : ($existing->{sources}[0] // 'unknown');

    my %source_timestamps = (
        %{ref($existing->{source_timestamps}) eq 'HASH'
            ? $existing->{source_timestamps} : {}},
        %{ref($input->{source_timestamps}) eq 'HASH'
            ? $input->{source_timestamps} : {}},
    );
    if (defined $observation->{source_timestamp}) {
        $source_timestamps{$_} = $observation->{source_timestamp} for @sources;
        $existing->{source_timestamp} = $observation->{source_timestamp};
        $existing->{last_seen} = $observation->{source_timestamp};
    }
    $existing->{source_timestamps} = \%source_timestamps;

    my %known_channels = map { $_ => 1 } @{$existing->{discovery_channels} || []};
    push @{$existing->{discovery_channels}},
        grep { !$known_channels{$_}++ } @channels;
    $existing->{source_channels} = {}
        unless ref($existing->{source_channels}) eq 'HASH';
    for my $source (@sources) {
        my $source_channels = $existing->{source_channels}{$source} ||= [];
        my %known = map { $_ => 1 } @$source_channels;
        push @$source_channels, grep { !$known{$_}++ } @channels;
    }

    my $has_new_size = defined($observation->{size_bytes}) ||
        (defined($observation->{size_raw}) && length($observation->{size_raw}));
    my $has_old_size = defined($existing->{size_bytes}) ||
        (defined($existing->{size_raw}) && length($existing->{size_raw}));
    if ($has_new_size) {
        my $old_precision = $existing->{size_precision} //
            ($existing->{size_is_estimate} ? 'estimated' : 'unknown');
        my $new_precision = $observation->{size_precision} // 'unknown';
        my %rank = (unknown => 0, estimated => 1, exact => 2);
        my $old_rank = $rank{$old_precision} // 0;
        my $new_rank = $rank{$new_precision} // 0;
        my $same_precision_newer = $new_rank == $old_rank &&
            defined($observation->{size_observed_at}) &&
            (!defined($existing->{size_observed_at}) ||
                $observation->{size_observed_at} gt $existing->{size_observed_at});
        my $take_new = !$has_old_size ||
            $new_rank > $old_rank ||
            $same_precision_newer;
        if ($take_new) {
            $existing->{$_} = $observation->{$_}
                for qw(size_raw size_bytes size_precision size_is_estimate size_source size_observed_at);
        }
    }
    for my $field (qw(
        trigger_mode section_found_count
        sends_used sends_max queues_used queues_max discovery_block_id
        discovery_channel manifest_format manifest_remote_path
        searchbot_collection_id searchbot_candidate_id searchbot_result_row
        searchbot_query searchbot_route_trigger searchbot_info_raw searchbot_hash_raw
    )) {
        next unless defined $observation->{$field};
        next if $field eq 'trigger_mode' && $observation->{$field} eq 'unknown';
        next if $field eq 'size_raw' && !length($observation->{$field});
        $existing->{$field} = $observation->{$field};
    }
    return $existing;
}

sub records {
    my ($store) = @_;
    return [] unless ref($store) eq 'HASH' && ref($store->{records}) eq 'ARRAY';
    return $store->{records};
}

sub record_count {
    my ($store) = @_;
    return scalar @{records($store)};
}

sub search_records {
    my ($store, $filter, $limit) = @_;
    my $items = records($store);
    $filter //= '';
    my $needle = lc($filter);
    my @matches;

    for my $index (0 .. $#$items) {
        my $record = $items->[$index];
        my $text = join ' ', grep { defined($_) && length($_) } (
            $record->{server_nick},
            $record->{trigger_raw},
            $record->{remote_path},
            $record->{source},
            @{$record->{sources} || []},
        );
        next if length($needle) && index(lc($text), $needle) < 0;
        push @matches, { index => $index + 1, record => $record };
        last if defined($limit) && $limit > 0 && @matches >= $limit;
    }

    return \@matches;
}

sub append_observation {
    my ($path, $input) = @_;
    return append_observations($path, [$input]);
}

sub append_observations {
    my ($path, $inputs) = @_;
    die 'catalog JSONL path is required' unless defined($path) && length($path);
    die 'catalog observations must be an array reference' unless ref($inputs) eq 'ARRAY';
    return 0 unless @$inputs;

    my @normalized = map { _normalize_observation($_) } @$inputs;
    my $json = JSON::PP->new->canonical(1)->utf8(1);
    my @lines = map { $json->encode($_) . "\n" } @normalized;
    sysopen my $fh, $path, O_RDWR | O_CREAT, 0600
        or die "open $path: $!";
    binmode $fh, ':raw';
    flock($fh, LOCK_EX) or die "lock $path: $!";

    seek($fh, 0, 2) or die "seek $path: $!";
    my $size = tell($fh);
    die "tell $path: $!" unless defined $size && $size >= 0;
    if ($size) {
        seek($fh, -1, 2) or die "seek final byte of $path: $!";
        my $read = read($fh, my $last_byte, 1);
        die "read final byte of $path: $!" unless defined($read) && $read == 1;
        unless ($last_byte eq "\n") {
            seek($fh, 0, 2) or die "seek before boundary repair in $path: $!";
            print {$fh} "\n" or die "write record boundary to $path: $!";
        }
    } else {
        seek($fh, 0, 2) or die "seek empty $path: $!";
    }

    for my $line (@lines) {
        print {$fh} $line or die "write $path: $!";
    }
    close $fh or die "close $path: $!";
    return scalar @$inputs;
}

sub load_jsonl {
    my ($path) = @_;
    die 'catalog JSONL path is required' unless defined($path) && length($path);
    return ([], 0) unless -e $path;

    open my $fh, '<', $path or die "open $path: $!";
    binmode $fh, ':raw';
    my (@records, $invalid);
    $invalid = 0;
    while (my $line = <$fh>) {
        next unless $line =~ /\S/;
        my $record = eval { decode_json($line) };
        if ($@ || ref($record) ne 'HASH' || ($record->{type} // 'file') ne 'file') {
            $invalid++;
            next;
        }
        push @records, $record;
    }
    close $fh or die "close $path: $!";
    return (\@records, $invalid);
}

sub files {
    my ($items) = @_;
    return [] unless ref($items) eq 'ARRAY';
    return [grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'file' } @$items];
}

sub matching_files {
    my ($items, $filter, $limit) = @_;
    $items = [] unless ref($items) eq 'ARRAY';
    $filter //= '';
    my $needle = lc($filter);
    my (@matches, $file_index);
    $file_index = 0;

    for my $item (@$items) {
        next unless ref($item) eq 'HASH' && ($item->{type} // '') eq 'file';
        $file_index++;
        next if length($needle) && index(lc($item->{path} // ''), $needle) < 0;

        push @matches, { index => $file_index, file => $item };
        last if defined($limit) && $limit > 0 && @matches >= $limit;
    }

    return \@matches;
}

sub count_type {
    my ($items, $type) = @_;
    return 0 unless ref($items) eq 'ARRAY';
    $type //= '';
    return scalar grep {
        ref($_) eq 'HASH' && ($_->{type} // '') eq $type
    } @$items;
}

sub _safe_field {
    my ($value) = @_;
    return '' unless defined $value;
    $value =~ s/[\r\n\t]+/ /g;
    return $value;
}

sub write_catalog {
    my ($items, $jsonl_path, $tsv_path) = @_;
    $items = [] unless ref($items) eq 'ARRAY';

    my $json = JSON::PP->new->canonical(1)->utf8(1);
    open my $jfh, '>', $jsonl_path or die "open $jsonl_path: $!";
    open my $tfh, '>', $tsv_path or die "open $tsv_path: $!";
    print {$tfh} "index\ttype\tpath\tsize_bytes\tsize_raw\n";

    my $index = 0;
    for my $item (@$items) {
        next unless ref($item) eq 'HASH';
        my %row = %$item;
        $row{index} = ++$index;
        print {$jfh} $json->encode(\%row), "\n";
        my $tsv_size_bytes = $row{size_is_estimate}
            ? ''
            : (defined($row{size_bytes}) ? $row{size_bytes} : '');
        print {$tfh} join("\t",
            $row{index}, _safe_field($row{type}), _safe_field($row{path}),
            $tsv_size_bytes,
            _safe_field($row{size_raw})
        ), "\n";
    }
    close $jfh;
    close $tfh;
    return 1;
}

1;
