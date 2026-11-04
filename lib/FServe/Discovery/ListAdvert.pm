package FServe::Discovery::ListAdvert;

use strict;
use warnings;
use Encode qw(decode FB_CROAK);
use Exporter qw(import);

use FServe::Discovery::SysResetAdvert qw(strip_formatting);

our @EXPORT_OK = qw(parse_advert_line names_own_list);

# The channel advert of a list server (2026-10-27): a nick that answers
# "@Nick" with its whole list, and is asked for a file by posting
# "!Nick name". Seen in a real ebook channel, in several scripts' wording:
#
#   Type: @ListServe For My List Of: 3,768 Files ... Search: ON ...
#   Type: @Archivist for my latest file listing (Updated: ...), ...
#
# What they share, and all that is read: the sender names "@" and its own
# nick, as a word of its own. Someone else's "@Nick" is a request or a
# mention, never an advert. The rest is the operator's words, kept as text.

our $MAX_LINE_BYTES = 1024;
our $MAX_TEXT_CHARS = 300;

my $NICK_CHAR = qr/[A-Za-z0-9\-\[\]\\`_^{}|]/;

# Whether $text names "@" and $nick as a word, compared as IRC compares nicks
# (RFC 1459 case: [ ] \ ~ fold with { } | ^).
sub names_own_list {
    my ($text, $nick) = @_;
    return 0 unless defined($text) && defined($nick) && length($nick) &&
        $nick =~ /\A$NICK_CHAR+\z/;
    my $fold = sub { my ($v) = @_; $v = lc $v; $v =~ tr/[]\\~/{}|^/; $v };
    my $want = $fold->($nick);
    while ($text =~ /(?<!$NICK_CHAR)\@($NICK_CHAR+)/g) {
        return 1 if $fold->($1) eq $want;
    }
    return 0;
}

# Returns undef for a line that is not $nick's list advert, or
#   { part => 'whole', script => 'list', triggers => [{ trigger => '@Nick',
#     kind => 'list' }], message => text }
# in the shape FServe::Discovery::SysResetAdvert returns.
sub parse_advert_line {
    my ($raw, $nick) = @_;
    return undef unless defined($raw) && length($raw) <= $MAX_LINE_BYTES;
    # Irssi hands a script the line's bytes: "\x{2022}" bullets came out as
    # three Latin-1 characters each (one server's, 2026-10-27).
    if (!utf8::is_utf8($raw) && $raw =~ /[\x80-\xff]/) {
        my $copy = $raw;
        my $decoded = eval { decode('UTF-8', $copy, FB_CROAK) };
        $raw = $decoded if defined $decoded;
    }
    my $text = strip_formatting($raw);
    $text =~ s/[\x00-\x1f\x7f]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    return undef unless names_own_list($text, $nick);
    $text = substr($text, 0, $MAX_TEXT_CHARS - 1) . "\x{2026}"
        if length($text) > $MAX_TEXT_CHARS;
    return {
        part => 'whole', script => 'list',
        triggers => [{ trigger => '@' . $nick, kind => 'list' }],
        message => $text,
    };
}

1;
