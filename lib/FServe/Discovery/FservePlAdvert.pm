package FServe::Discovery::FservePlAdvert;

use strict;
use warnings;
use Exporter qw(import);

use FServe::Discovery::SysResetAdvert qw(strip_formatting);

our @EXPORT_OK = qw(parse_advert_line);

# The channel advert of FServe for Irssi (fserve.pl), read exactly as its own
# script builds it (sub show_notice in fserve.pl 2.0.0, published at
# https://scripts.irssi.org/scripts/fserve.pl), and nothing else. A whole
# advert looks like
#
#   (FServe Online) Trigger:(/ctcp <nick> !trigger) Sends:(0/2) Queues:(0/10) Min CPS:(9.5 kB/s) [FServe.pl 2.0.0]
#
# once its colour codes are gone. The fields present, and their order, are
# the server's "custom_notice_fields" setting; the script always sends the
# trigger as a CTCP one under its own nick, and always on one line. "Note"
# and "On FServe" are the operator's own words and may hold brackets.

our $MAX_LINE_BYTES = 1024;
our $MAX_TEXT_CHARS = 300;
our $MAX_STAT_CHARS = 60;

my %STAT_KEYS = map { $_ => 1 } (
    'Min CPS', 'Accessed', 'Snagged', 'Record CPS', 'Current Upstream', 'Serving',
);
my $KEYS = join('|', map { quotemeta } (
    'Trigger', 'Sends', 'Queues', 'Online', 'Note', 'On FServe', keys %STAT_KEYS));

# Returns undef for a line that is not an FServe.pl advert, or
#   { part => 'whole', script => 'fserve.pl', triggers => [...], ... }
# in the shape FServe::Discovery::SysResetAdvert returns.
sub parse_advert_line {
    my ($raw) = @_;
    return undef unless defined($raw) && length($raw) <= $MAX_LINE_BYTES;
    my $text = strip_formatting($raw);
    $text =~ s/\A\s+|\s+\z//g;
    return undef if $text =~ /[\x00-\x1f\x7f]/;
    my ($body, $version) = $text =~
        /\A\(FServe Online\)((?: .*)?) \[FServe\.pl ([0-9][0-9A-Za-z.\-]{0,15})\]\z/s
        or return undef;

    my @starts;
    while ($body =~ / (?=(?:$KEYS):\()/g) {
        push @starts, $-[0];
    }
    return undef unless @starts && $starts[0] == 0;
    my %fields;
    for my $i (0 .. $#starts) {
        my $end = $i < $#starts ? $starts[$i + 1] : length($body);
        my $part = substr($body, $starts[$i] + 1, $end - $starts[$i] - 1);
        my ($key, $value) = $part =~ /\A($KEYS):\((.*)\)\z/s or return undef;
        return undef if exists $fields{$key};
        $fields{$key} = $value;
    }

    my ($ctcp_nick, $word) = ($fields{Trigger} // '') =~ m{\A/ctcp ([^\s/]{1,30}) (\S{1,60})\z}
        or return undef;
    my %advert = (
        part => 'whole',
        script => 'fserve.pl',
        version => $version,
        triggers => [{ trigger => $word, kind => 'ctcp', ctcp_nick => $ctcp_nick }],
    );
    for my $pair (['Sends', 'sends'], ['Queues', 'queues'], ['Online', 'users']) {
        my ($key, $name) = @$pair;
        next unless exists $fields{$key};
        my ($in_use, $limit) = $fields{$key} =~ /\A(\d{1,5})\/(\d{1,5})\z/ or return undef;
        $advert{$name} = { in_use => 0 + $in_use, limit => 0 + $limit };
    }
    for my $pair (['Note', 'message'], ['On FServe', 'content']) {
        my ($key, $name) = @$pair;
        next unless exists $fields{$key};
        return undef if length($fields{$key}) > $MAX_TEXT_CHARS;
        $advert{$name} = $fields{$key};
    }
    my %stats;
    for my $key (grep { $STAT_KEYS{$_} } keys %fields) {
        return undef if length($fields{$key}) > $MAX_STAT_CHARS;
        $stats{$key} = $fields{$key};
    }
    $advert{stats} = \%stats if %stats;
    return \%advert;
}

1;
