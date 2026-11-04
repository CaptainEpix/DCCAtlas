package FServe::Parser;

use strict;
no warnings 'redefine';
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(parse_line strip_formatting size_to_bytes join_path);

sub strip_formatting {
    my ($s) = @_;
    $s = '' unless defined $s;

    # ANSI escape sequences (occasionally leaked through gateways/clients).
    $s =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g;

    # mIRC formatting controls: color + optional fg/bg numbers, bold,
    # italic, reverse, underline, reset, monospace.
    $s =~ s/\x03(?:\d{1,2})?(?:,\d{1,2})?//g;
    $s =~ s/[\x02\x0F\x11\x16\x1D\x1E\x1F]//g;

    # Remove stray CR/NUL and trim external whitespace only.
    $s =~ s/[\r\0]//g;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub size_to_bytes {
    my ($raw) = @_;
    return undef unless defined $raw;

    my $s = $raw;
    $s =~ s/,//g;
    $s =~ s/^\s+|\s+$//g;

    # Accept forms seen in historical FServes: 123 B, 42.4MB, 3 kb,
    # and a few harmless modern variants.
    return undef unless $s =~ /^([0-9]+(?:\.[0-9]+)?)\s*(B|BYTES?|K(?:I)?B|M(?:I)?B|G(?:I)?B|T(?:I)?B)$/i;
    my ($n, $unit) = ($1 + 0, uc($2));

    my $pow = 0;
    $pow = 1 if $unit =~ /^K/;
    $pow = 2 if $unit =~ /^M/;
    $pow = 3 if $unit =~ /^G/;
    $pow = 4 if $unit =~ /^T/;

    return int($n * (1024 ** $pow) + 0.5);
}

sub _split_file_size {
    my ($text) = @_;
    return unless defined $text;

    # Prefer the final size token(s). This deliberately allows spaces in
    # filenames and a space between the number and unit.
    if ($text =~ /^(.*?)\s+([0-9]+(?:\.[0-9]+)?\s*(?:B|BYTES?|K(?:I)?B|M(?:I)?B|G(?:I)?B|T(?:I)?B))\s*$/i) {
        my ($name, $size) = ($1, $2);
        $name =~ s/^\s+|\s+$//g;
        return ($name, $size) if length $name;
    }
    return;
}

sub parse_line {
    my ($raw) = @_;
    $raw = '' unless defined $raw;
    my $line = strip_formatting($raw);

    return { type => 'blank', raw => $raw, text => $line } if $line eq '';

    # Historical mIRC FServe welcome/disclaimer pagination prompt.
    if ($line =~ /^\[\s*['\"]?C['\"]?\s+for\s+more\s*,\s*['\"]?S['\"]?\s+to\s+stop\s*\]$/i) {
        return { type => 'more_prompt', raw => $raw, text => $line };
    }

    # XDCC Browser 4.52 used essentially this end marker regex.
    if ($line =~ /^\W*end\s+of\s+list\W*$/i) {
        return { type => 'end', raw => $raw, text => $line };
    }

    # FServe.pl (2.0.0 for Irssi) frames a listing: "Listing [/dir/*.*]"
    # opens it as SysReset's wildcard prompt does, "End [/dir]" closes it
    # (seen 2026-10-20).
    if ($line =~ /^End\s+\[\s*[\\\/][^\]]*\]$/i) {
        return { type => 'end', raw => $raw, text => $line };
    }
    if ($line =~ /^Listing\s+\[\s*([\\\/].*?\*\.\*)\s*\]$/i) {
        my $path = $1;
        $path =~ s/\//\\/g;
        $path =~ s/\\+/\\/g;
        return { type => 'prompt', raw => $raw, text => $line, path => $path };
    }

    # Typical FServe path prompt: [\], [/], [\MOVIES], [/foo/bar].
    if ($line =~ /^\[\s*([\\\/].*?)\s*\]$/) {
        my $path = $1;
        $path =~ s/\//\\/g;
        $path =~ s/\\+/\\/g;
        return { type => 'prompt', raw => $raw, text => $line, path => $path };
    }

    # A useful status line to keep out of directory heuristics.
    if ($line =~ /closing\s+idle\s+connection\s+in\s+\d+\s+seconds?/i) {
        return { type => 'idle_warning', raw => $raw, text => $line };
    }

    # Parent directory entries are navigation noise, not crawl children.
    if ($line eq '..' || $line =~ /^\d+D:\s*\.\.\s*$/i) {
        return { type => 'parent', raw => $raw, text => $line };
    }

    # FServe.pl marks a directory with a trailing slash: "Fate Core/".
    if ($line =~ m{^(.*[^/\s])/$}) {
        return { type => 'dir', raw => $raw, text => $line, name => $1, dialect => 'slash' };
    }

    # Number-letter dialect: "12D: SOME DIR".
    if ($line =~ /^\s*\d+D:\s*(.+?)\s*$/i) {
        my $name = $1;
        return { type => 'dir', raw => $raw, text => $line, name => $name, dialect => 'numbered' };
    }

    # Number-letter dialect: "12F: filename with spaces.ext 42.4 MB".
    if ($line =~ /^\s*\d+F:\s*(.+?)\s*$/i) {
        my ($name, $size_raw) = _split_file_size($1);
        if (defined $name) {
            return {
                type       => 'file',
                raw        => $raw,
                text       => $line,
                name       => $name,
                size_raw   => $size_raw,
                size_bytes => size_to_bytes($size_raw),
                dialect    => 'numbered',
            };
        }
    }

    # Ordinary mIRC/SysReset-style DIR line. Filename is everything before
    # the final size, so spaces in names are naturally supported.
    {
        my ($name, $size_raw) = _split_file_size($line);
        if (defined $name) {
            return {
                type       => 'file',
                raw        => $raw,
                text       => $line,
                name       => $name,
                size_raw   => $size_raw,
                size_bytes => size_to_bytes($size_raw),
                dialect    => 'plain',
            };
        }
    }

    # Historical XDCC Browser treated all-uppercase non-file lines as dirs.
    # Require at least one letter so separators do not become directories.
    my $letters = $line;
    $letters =~ s/[^A-Za-z]//g;
    if (length($letters) && uc($letters) eq $letters) {
        return { type => 'dir', raw => $raw, text => $line, name => $line, dialect => 'uppercase' };
    }

    # Queue-related messages are not standardized, but tagging obvious ones
    # is useful to the transcript without claiming exact semantics.
    if ($line =~ /\b(queue(?:d|s)?|slot(?:s)?|send(?:s|ing)?)\b/i) {
        return { type => 'status', raw => $raw, text => $line };
    }

    return { type => 'noise', raw => $raw, text => $line };
}

sub join_path {
    my (@parts) = @_;
    return '/' unless @parts;
    my @clean = map {
        my $p = defined($_) ? $_ : '';
        $p =~ s{^[\\/]+}{};
        $p =~ s{[\\/]+$}{};
        $p;
    } @parts;
    return '/' . join('/', @clean);
}

1;
