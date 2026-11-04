package FServe::DccPolicy;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(
    legacy_alias_conflict
    match_filename
    same_peer
);

sub same_peer {
    my ($dcc, $expected_nick, $expected_tag) = @_;
    return 0 unless ref($dcc);
    return 0 unless defined($expected_nick) && length($expected_nick);
    return 0 unless defined($expected_tag) && length($expected_tag);
    return 0 unless lc($dcc->{nick} // '') eq lc($expected_nick);

    # Irssi DCC records carry a server tag; without it we cannot prove the
    # offer belongs to this session's network, so keep the policy fail-closed.
    my $observed_tag = $dcc->{servertag} // '';
    $observed_tag = $dcc->{server}{tag} // ''
        if !length($observed_tag) && ref($dcc->{server});
    return 0 unless length($observed_tag);

    return lc($observed_tag) eq lc($expected_tag);
}

sub match_filename {
    my ($offered, $want, $parent, $catalog) = @_;
    $offered //= '';
    $want //= '';
    $parent //= '';
    $catalog = [] unless ref($catalog) eq 'ARRAY';

    return ('exact', 1) if lc($offered) eq lc($want);

    # Older DCC senders commonly advertise filenames with spaces converted
    # to underscores. Accept only that exact transformation of the file we
    # explicitly requested.
    my $legacy = $want;
    $legacy =~ s/ /_/g;

    if (lc($offered) eq lc($legacy) && lc($legacy) ne lc($want)) {
        # Refuse the legacy alias if it is ambiguous with a different real
        # file in the same directory (e.g. both "foo bar.txt" and
        # "foo_bar.txt" exist).
        for my $item (@$catalog) {
            next unless ($item->{type} // '') eq 'file';
            next unless lc($item->{parent} // '') eq lc($parent);
            next unless lc($item->{name} // '') eq lc($offered);
            next if lc($item->{name} // '') eq lc($want);
            return ('ambiguous-space-to-underscore', 0);
        }
        return ('space-to-underscore', 1);
    }

    return ('none', 0);
}

sub legacy_alias_conflict {
    my ($file, %context) = @_;
    return undef unless $file && ($file->{type} // '') eq 'file';

    my $name = $file->{name} // '';
    return undef unless $name =~ / /;

    my $legacy = $name;
    $legacy =~ s/ /_/g;
    return undef if lc($legacy) eq lc($name);

    my $parent = $file->{parent} // '';
    my $items = defined($context{verified_parent_path}) &&
        lc($context{verified_parent_path}) eq lc($parent)
        ? ($context{verified_parent_files} || [])
        : ($context{catalog} || []);

    for my $item (@$items) {
        next unless ($item->{type} // '') eq 'file';
        next unless lc($item->{parent} // '') eq lc($parent);
        next unless lc($item->{name} // '') eq lc($legacy);
        next if lc($item->{name} // '') eq lc($name);
        return $item;
    }

    return undef;
}

1;
