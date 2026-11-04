package FServe::Model;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(
    identity_key
    new_remote_file
    normalize_remote_path
    parse_slot_counts
    size_to_bytes
    split_remote_path
);

sub _trim {
    my ($value) = @_;
    return '' unless defined $value;
    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    return $value;
}

sub normalize_remote_path {
    my ($raw) = @_;
    return undef unless defined $raw;

    my $path = _trim($raw);
    return undef unless length $path;

    # FServe listings and @Find replies commonly use Windows separators,
    # while the catalog uses one stable, root-relative representation.
    $path =~ s{\\}{/}g;
    $path =~ s{/+}{/}g;
    $path =~ s{^/+}{};
    $path =~ s{/+$}{};
    return undef unless length $path;

    my @parts = split m{/}, $path, -1;
    for my $part (@parts) {
        return undef unless length $part;
        return undef if $part eq '.' || $part eq '..';
    }

    return '/' . join('/', @parts);
}

sub split_remote_path {
    my ($raw) = @_;
    my $path = normalize_remote_path($raw);
    return unless defined $path;

    my @parts = split m{/}, substr($path, 1);
    my $basename = pop @parts;
    my $parent = @parts ? '/' . join('/', @parts) : '/';

    return ($path, $parent, $basename);
}

sub size_to_bytes {
    my ($raw) = @_;
    return undef unless defined $raw;

    my $value = _trim($raw);
    $value =~ s/,//g;
    return undef unless $value =~ /^([0-9]+(?:\.[0-9]+)?)\s*(B|BYTES?|K(?:I)?B|M(?:I)?B|G(?:I)?B|T(?:I)?B)$/i;

    my ($number, $unit) = ($1 + 0, uc $2);
    my $power = 0;
    $power = 1 if $unit =~ /^K/;
    $power = 2 if $unit =~ /^M/;
    $power = 3 if $unit =~ /^G/;
    $power = 4 if $unit =~ /^T/;

    return int($number * (1024 ** $power) + 0.5);
}

sub _size_precision {
    my (%args) = @_;
    if (defined($args{size_precision})) {
        die 'size_precision must be unknown, estimated, or exact'
            unless $args{size_precision} =~ /^(?:unknown|estimated|exact)$/;
        return $args{size_precision};
    }
    return 'estimated' if $args{size_is_estimate};
    my $raw = $args{size_raw};
    my $bytes = $args{size_bytes};
    return 'unknown' unless defined($bytes) || (defined($raw) && length($raw));
    return 'exact' if defined($raw) && $raw =~ /^\s*\d+(?:\s*(?:B|BYTES?))?\s*$/i;
    return 'exact' if defined($bytes) && !defined($raw);
    return 'estimated' if defined($raw) && $raw =~ /^\s*\d+(?:\.\d+)?\s*(?:K(?:I?B)?|M(?:I?B)?|G(?:I?B)?|T(?:I?B))\s*$/i;
    return 'unknown';
}

sub parse_slot_counts {
    my ($raw) = @_;
    return unless defined $raw;
    return unless $raw =~ /^\s*(\d+)\s*\/\s*(\d+)\s*$/;
    return (0 + $1, 0 + $2);
}

sub new_remote_file {
    my (%args) = @_;

    my ($remote_path, $parent_path, $basename) =
        split_remote_path($args{remote_path} // $args{path});
    die 'remote_path must be a non-empty root-relative path without . or .. components'
        unless defined $remote_path;

    my $trigger = _trim($args{trigger_raw});
    die 'trigger_raw is required' unless length $trigger;

    my $server_nick = _trim($args{server_nick});
    die 'server_nick is required' unless length $server_nick;

    my $size_precision = _size_precision(%args);
    my %record = (
        type          => 'file',
        network_id    => $args{network_id},
        server_tag    => $args{server_tag},
        server_nick   => $server_nick,
        trigger_raw   => $trigger,
        trigger_mode  => defined($args{trigger_mode}) ? $args{trigger_mode} : 'unknown',
        remote_path   => $remote_path,
        parent_path   => $parent_path,
        basename      => $basename,
        size_raw      => $args{size_raw},
        size_bytes    => defined($args{size_bytes})
            ? $args{size_bytes}
            : size_to_bytes($args{size_raw}),
        size_is_estimate => $args{size_is_estimate} ? 1 : 0,
        size_precision => $size_precision,
        size_source => defined($args{size_source}) ? $args{size_source} : ($args{source} // 'unknown'),
        size_observed_at => defined($args{size_observed_at})
            ? $args{size_observed_at} : $args{source_timestamp},
        section_found_count => $args{section_found_count},
        source        => defined($args{source}) ? $args{source} : 'unknown',
        source_timestamp => $args{source_timestamp},
        sends_used    => $args{sends_used},
        sends_max     => $args{sends_max},
        queues_used   => $args{queues_used},
        queues_max    => $args{queues_max},
    );
    $record{size_is_estimate} = $size_precision eq 'estimated' ? 1 : 0;

    # Keep provider-specific provenance without making the common model
    # depend on a particular discovery implementation.
    for my $key (qw(
        discovery_block_id discovery_channel
        manifest_format manifest_remote_path
        searchbot_collection_id searchbot_candidate_id searchbot_result_row
        searchbot_query searchbot_route_trigger searchbot_info_raw searchbot_hash_raw
    )) {
        $record{$key} = $args{$key} if exists $args{$key};
    }

    return \%record;
}

sub identity_key {
    my ($record) = @_;
    die 'identity_key requires a hash reference' unless ref($record) eq 'HASH';

    my $network = defined($record->{network_id}) && length($record->{network_id})
        ? $record->{network_id}
        : ($record->{server_tag} // '');
    # IRC identities are case-insensitive here, but a remote path is not an
    # IRC identifier. Preserve its case so distinct case-sensitive paths do
    # not collapse into one catalog record or one apparently unique match.
    my @parts = map { lc($_ // '') } (
        $network,
        $record->{server_nick},
        $record->{trigger_raw},
    );
    my $mode = lc($record->{trigger_mode} // '');
    push @parts, $mode if $mode eq 'channel_text' || $mode eq 'ctcp';
    push @parts, $record->{remote_path} // '';

    return join("\x1e", @parts);
}

1;
