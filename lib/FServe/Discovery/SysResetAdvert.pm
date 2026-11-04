package FServe::Discovery::SysResetAdvert;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(parse_advert_line merge_advert_parts strip_formatting);

# The channel advert of SysReset 2.55's file server, read exactly as its own
# script builds it (system/aliases.ini, alias "ad"; system/aliases2.ini,
# alias "buildstats"), and nothing else. A whole advert looks like
#
#   [Fserve Active] - Trigger:[!fserve (0/10)] - Users:[0/5] - Message:[text] - SysReset 2.55
#
# with "Triggers:" and " & " between several triggers, "/ctcp <nick> <word>"
# for a CTCP trigger, "OP " or "Voice " inside the first brackets for a
# restricted advert, and further " - Key:[value]" statistics. An advert too
# long for one line is sent as two: the first ends before the last fields,
# the second starts at the next field and carries the "SysReset" ending.
# Other scripts' adverts, and SysReset's XDCC ("TDCC") adverts, are not read.

our $MAX_LINE_BYTES = 1024;
our $MAX_TRIGGERS = 8;
our $MAX_MESSAGE_CHARS = 300;

my %STAT_KEYS = map { $_ => 1 } (
    'Record CPS', 'Bytes Sent', 'Files Sent', 'Sends Failed', 'Resends',
    'Accesses', 'Upload Speed', 'Download Speed', 'Current Bandwidth',
);
my %KNOWN_KEYS = (%STAT_KEYS,
    map { $_ => 1 } qw(Trigger Triggers Users Sends Queues Notice));

sub strip_formatting {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $text =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    return $text;
}

# Returns undef for a line that is not (part of) a SysReset advert, or
#   { part => 'whole' | 'head' | 'tail', ... }
# A head starts with "[Fserve Active]" and lacks the ending; a tail has the
# ending and no "[Fserve Active]"; a whole advert has both.
sub parse_advert_line {
    my ($raw) = @_;
    return undef unless defined($raw) && length($raw) <= $MAX_LINE_BYTES;
    my $text = strip_formatting($raw);
    $text =~ s/\A\s+|\s+\z//g;
    return undef if $text =~ /[\x00-\x1f\x7f]/;

    my ($version, $has_ending);
    if ($text =~ s/(?:\A| - )SysReset(?: v?([0-9][0-9.]{0,15}))?\z//) {
        ($has_ending, $version) = (1, $1);
    }
    my $message;
    if ($has_ending) {
        my $at = _field_start($text, 'Message:[');
        if (defined($at) && substr($text, -1) eq ']') {
            my $start = $at + length('Message:[');
            $message = substr($text, $start, length($text) - $start - 1);
            $text = substr($text, 0, $at);
            $text =~ s/ - \z//;
        }
    }
    my ($head, $restricted);
    if ($text =~ s/\A\[(?:(OP|Voice) )?Fserve Active\]//) {
        ($head, $restricted) = (1, $1);
    }
    return undef unless $head || $has_ending;
    $text = " - $text" if !$head && length $text;

    my (%fields, @order);
    while ($text =~ /\G - ([A-Za-z][A-Za-z ]{0,30}):\[([^\]]{0,300})\]/gc) {
        my ($key, $value) = ($1, $2);
        return undef unless $KNOWN_KEYS{$key} && !exists $fields{$key};
        $fields{$key} = $value;
        push @order, $key;
    }
    return undef unless (pos($text) // 0) == length($text);
    return undef if !$head && (exists $fields{Trigger} || exists $fields{Triggers});
    return undef if exists $fields{Trigger} && exists $fields{Triggers};

    my %advert = (part => $head ? ($has_ending ? 'whole' : 'head') : 'tail');
    $advert{restricted} = $restricted if defined $restricted;
    $advert{version} = $version if defined $version;
    if (defined $message) {
        return undef if length($message) > $MAX_MESSAGE_CHARS;
        $advert{message} = $message;
    }
    my $triggers = $fields{Trigger} // $fields{Triggers};
    if (defined $triggers) {
        my @items = _triggers($triggers) or return undef;
        return undef if exists($fields{Trigger}) && @items != 1;
        $advert{triggers} = \@items;
    }
    for my $key (qw(Users Sends)) {
        next unless exists $fields{$key};
        my ($in_use, $limit) = $fields{$key} =~ /\A(\d{1,5})\/(\d{1,5})\z/ or return undef;
        $advert{lc $key} = { in_use => 0 + $in_use, limit => 0 + $limit };
    }
    if (exists $fields{Queues}) {
        my $value = $fields{Queues};
        if (my ($in_use, $limit) = $value =~ /\A(\d{1,5})\/(\d{1,5})\z/) {
            $advert{queues} = { in_use => 0 + $in_use, limit => 0 + $limit };
        } elsif ($value =~ /\A\d{1,2}:\d{1,5}\/\d{1,5}(?: \d{1,2}:\d{1,5}\/\d{1,5}){0,7}\z/) {
            $advert{queues} = { pools => $value };
        } else {
            return undef;
        }
    }
    $advert{notice} = $fields{Notice} if exists $fields{Notice};
    my %stats = map { $_ => $fields{$_} } grep { $STAT_KEYS{$_} } @order;
    $advert{stats} = \%stats if %stats;
    return \%advert;
}

# Joins the two lines of a split advert. Returns undef unless they fit.
sub merge_advert_parts {
    my ($head, $tail) = @_;
    return undef unless ref($head) eq 'HASH' && ref($tail) eq 'HASH' &&
        ($head->{part} // '') eq 'head' && ($tail->{part} // '') eq 'tail';
    my %merged = (%$head, part => 'whole');
    for my $key (qw(users sends queues notice)) {
        next unless exists $tail->{$key};
        return undef if exists $head->{$key};
        $merged{$key} = $tail->{$key};
    }
    my %stats = (%{$head->{stats} || {}});
    for my $key (keys %{$tail->{stats} || {}}) {
        return undef if exists $stats{$key};
        $stats{$key} = $tail->{stats}{$key};
    }
    $merged{stats} = \%stats if %stats;
    $merged{version} = $tail->{version} if defined $tail->{version};
    $merged{message} = $tail->{message} if defined $tail->{message};
    return \%merged;
}

# A field starts at the beginning of the text or after " - ".
sub _field_start {
    my ($text, $marker) = @_;
    my $from = 0;
    while ((my $at = index($text, $marker, $from)) >= 0) {
        return $at if $at == 0 || substr($text, $at - 3, 3) eq ' - ';
        $from = $at + 1;
    }
    return undef;
}

sub _triggers {
    my ($value) = @_;
    # The script puts its colour code before the "&"; with the codes gone
    # the spaces around it vary.
    my @parts = split /\s*&\s*/, $value, -1;
    return () if !@parts || @parts > $MAX_TRIGGERS;
    my @items;
    for my $part (@parts) {
        my ($pool, $voice, $ctcp_nick, $word, $plain, $queued, $queue_limit) = $part =~ m{
            \A
            (?:([1-9][0-9]?):)?
            (Voice:)?
            (?: /ctcp \s ([^\s/]{1,30}) \s (\S{1,60}?) | ([^\s/]\S{0,59}?) )
            (?: \s? \( (\d{1,4}) / (\d{1,4}) \) )?
            \z
        }x or return ();
        my %item = defined($ctcp_nick)
            ? (trigger => $word, kind => 'ctcp', ctcp_nick => $ctcp_nick)
            : (trigger => $plain, kind => 'channel');
        $item{pool} = 0 + $pool if defined $pool;
        $item{voice_only} = 1 if $voice;
        if (defined $queued) {
            $item{queued} = 0 + $queued;
            $item{queue_limit} = 0 + $queue_limit;
        }
        push @items, \%item;
    }
    return @items;
}

1;
