package FServe::Discovery::PostedList;

use strict;
use warnings;

use Digest::SHA;
use Encode qw(decode FB_CROAK);
use IO::Uncompress::Unzip qw($UnzipError);
use FServe::Model qw(size_to_bytes);

our @EXPORT_OK = qw(parse_file parse_row parse_framed_heading);
use Exporter qw(import);

# The list a list server sends for "@Nick" in an ebook channel
# (2026-10-27). One text file, often zipped alone: a banner, folder
# headings such as "D:\Newlist\Cookery Books\" (or, from vListMaker,
# "[ Contents of D:\Newlist\Cookery Books\ ]"), and a row per file,
#
#   !Nick Author - Title.epub  ::INFO:: 1.40MB
#
# A file is asked for by posting its row, so only rows that start with the
# list server's own "!Nick" are files; everything else is skipped. A row is
# kept under the folder heading above it, so files of one name in two folders
# stay apart, though the row itself asks for the name alone. A row with a
# "%hash%" before the name is the name after it: under a folder heading it is
# a file (one server's whole list is so, 2026-10-29); before any heading it is
# a "new files" section repeating rows of the main list, and is skipped. A row
# is posted back as name and size.
# Text is UTF-8 where it is valid, else Windows-1252, as a Windows server
# writes it.

my $MAX_LINE_BYTES = 65_536;

sub _decode {
    my ($raw) = @_;
    return $raw unless $raw =~ /[\x80-\xff]/;
    my $copy = $raw;
    my $text = eval { decode('UTF-8', $copy, FB_CROAK) };
    return defined($text) ? $text : decode('cp1252', $raw);
}

# One line of a list, read for the list server $nick: a file row as
# { name, size_raw }, a folder heading as { folder }, or undef.
sub parse_row {
    my ($line, $nick) = @_;
    return undef unless defined($line) && defined($nick) && length($nick);
    $line =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $line =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    # Rows and headings start the line; the banner's lines are indented.
    $line =~ s/\s+\z//;
    # vListMaker (2026-10-28) writes its headings "[ Contents of C:\Books\ ]".
    $line = $1 if $line =~ /\A\[[\t ]*Contents of[\t ]+([A-Za-z]:\\.*?)[\t ]*\]\z/i;
    if ($line =~ /\A[A-Za-z]:\\(.*?)\\?\z/) {
        my @parts = grep { length } split /\\/, $1;
        return undef if grep { $_ eq '.' || $_ eq '..' || /[\x00-\x1f\x7f\/]/ } @parts;
        return { folder => join('/', @parts) };
    }
    # A catalog may give each title as fields (2026-10-28, OmenServe on
    # UnderNet): "ID | Author - Title | !Nick file name | licence". Only a row
    # with the "!Nick name" field is a file; rows of title and web link
    # alone describe works that cannot be asked for, and are skipped.
    if ($line =~ /\A[^!|]*\|.*?\|[\t ]*(!\S+[\t ]+.*?)[\t ]*(?:\|.*)?\z/) {
        $line = $1;
    }
    return undef unless $line =~ /\A!(\S+)[\t ]+(.+)\z/;
    my ($who, $rest) = ($1, $2);
    return undef unless lc($who) eq lc($nick);
    my $hashed = $rest =~ s/\A%[0-9A-Za-z]{8,64}%[\t ]+// ? 1 : 0;
    # A size may be followed by the file's hash (2026-10-29): "::INFO:: 232KB
    # ::HASH:: ad0fd9fbf18ec25d"; the size is what comes before it.
    $rest =~ s/[\t ]+::HASH::[\t ]*[0-9A-Fa-f]{1,128}[\t ]*\z//i;
    my ($name, $size) = ($rest, undef);
    if ($rest =~ /\A(.*?)[\t ]+::INFO::[\t ]*(\S.*?)\z/i) {
        ($name, $size) = ($1, $2);
        return undef if $size =~ /::INFO::/i;
    }
    $name =~ s/\A\s+|\s+\z//g;
    return undef unless length($name) && length($name) <= 255;
    return undef if $name =~ m{[/\\\x00-\x1f\x7f]} || $name eq '.' || $name eq '..';
    return { name => $name, size_raw => $size, ($hashed ? (hashed => 1) : ()) };
}

# OmenServe (2026-10-28, a real list of 1.6 million files) frames each
# folder heading in lines of "=", with no drive and perhaps no "\"; another
# server's (2026-10-29) writes "/" between its folders:
#
#   ===============
#   +1New\2024\2024-12-16
#   ===============
#
# A line between two lines of "=" that is not itself a row is read as one; a
# welcome banner's line framed above only is not.
sub is_rule { my ($line) = @_; return defined($line) && $line =~ /\A[\t ]*={5,}[\t ]*\z/ ? 1 : 0 }

sub parse_framed_heading {
    my ($line) = @_;
    return undef unless defined $line;
    $line =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $line =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    $line =~ s/\A\s+|\s+\z//g;
    return undef if !length($line) || $line =~ /\A!/ || is_rule($line);
    $line =~ s/\A[A-Za-z]:[\\\/]//;
    my @parts = grep { length } split /[\\\/]/, $line;
    return undef unless @parts;
    return undef if grep { $_ eq '.' || $_ eq '..' || /[\x00-\x1f\x7f\/]/ } @parts;
    return { folder => join('/', @parts) };
}

sub _source {
    my ($path, $max_bytes) = @_;
    open my $probe, '<:raw', $path or return (undef, "could not open the list: $!");
    my $magic = '';
    read($probe, $magic, 4);
    close $probe;
    if ($magic eq "PK\x03\x04") {
        my $zip = IO::Uncompress::Unzip->new($path, Strict => 1, MultiStream => 0,
            Transparent => 0) or return (undef, "invalid ZIP archive: $UnzipError");
        my $header = $zip->getHeaderInfo();
        my $member = ref($header) eq 'HASH' ? ($header->{Name} // '') : '';
        unless (length($member) && $member !~ m{[/\\\x00-\x1f\x7f]} && $member =~ /\.txt\z/i) {
            eval { $zip->close() };
            return (undef, 'the ZIP must hold one .txt list');
        }
        if (defined($header->{UncompressedLength}) &&
                $header->{UncompressedLength} =~ /\A[0-9]+\z/ &&
                $header->{UncompressedLength} > $max_bytes) {
            eval { $zip->close() };
            return (undef, "the list is larger than $max_bytes bytes");
        }
        return ({ zip => $zip, header => $header });
    }
    open my $fh, '<:raw', $path or return (undef, "could not open the list: $!");
    return ({ fh => $fh });
}

sub _read {
    my ($source) = @_;
    my $chunk;
    my $read = $source->{zip} ? $source->{zip}->read($chunk, 65_536)
        : sysread($source->{fh}, $chunk, 65_536);
    return (undef, $source->{zip} ? "ZIP read failed: $UnzipError" : "read failed: $!")
        if !defined($read) || $read < 0;
    return ($read ? $chunk : '');
}

sub _finish {
    my ($source) = @_;
    return close($source->{fh}) ? undef : "could not close the list: $!" if $source->{fh};
    my $zip = $source->{zip};
    my $next = $zip->nextStream();
    return "ZIP structure validation failed: $UnzipError" unless defined($next) && $next >= 0;
    return 'the ZIP must not hold more than the list' if $next > 0;
    return "ZIP close/integrity validation failed: $UnzipError" unless $zip->close();
    return undef;
}

# Reads the list at $path for the list server $args{server_nick}, calling
# $args{on_record} with each file's record, and returns a result in the
# catalog's form: { ok, sha256, rows, files, ... } or { ok => 0, reason }.
sub parse_file {
    my ($path, %args) = @_;
    # OmenServe names a list "<Nick>-<list name>" and writes its rows
    # "!Quill-Ebooks2 name" (2026-11-02): such a list is read by that word,
    # row_nick, while its files come from the nick itself.
    my $nick = $args{row_nick} // $args{server_nick};
    return { ok => 0, reason => 'the list server is not named' }
        unless defined($nick) && $nick =~ /\A[^\s\x00-\x1f\x7f]{1,64}\z/;
    my $max_bytes = $args{max_source_bytes} // 256 * 1024 * 1024;
    my $max_rows = $args{max_rows} // 5_000_000;
    my $max_seconds = $args{max_seconds} // 1_800;
    my $on_record = $args{on_record};
    my ($source, $why) = _source($path, $max_bytes);
    return { ok => 0, reason => $why } unless $source;
    my $digest = Digest::SHA->new(256);
    my %stats = (ok => 0, format => 'posted-list-v1', lines => 0, rows => 0, files => 0,
        directories => 0, bytes_read => 0, records_emitted => 0);
    my ($folder, $pending, $started) = ('', '', time());
    my ($after_rule, $framed_heading) = (0, undef);
    my $line_of = sub {
        my ($raw) = @_;
        $stats{lines}++;
        $raw =~ s/\r?\n\z//;
        my $text = _decode($raw);
        if (is_rule($text)) {
            # The rule under a framed line makes it a heading.
            if ($framed_heading) {
                $stats{rows}++;
                $stats{directories}++;
                $folder = $framed_heading->{folder};
            }
            ($after_rule, $framed_heading) = (1, undef);
            return 1;
        }
        my $framed = $after_rule;
        ($after_rule, $framed_heading) = (0, undef);
        my $row = parse_row($text, $nick);
        unless ($row) {
            $framed_heading = parse_framed_heading($text) if $framed;
            return 1;
        }
        $stats{rows}++;
        if (exists $row->{folder}) {
            $stats{directories}++;
            $folder = $row->{folder};
            return 1;
        }
        # A "new files" section before the first heading repeats the list.
        return 1 if $row->{hashed} && !length($folder);
        if ($stats{files} >= $max_rows) {
            $stats{reason} = "the list has more than $max_rows files";
            return 0;
        }
        # What the catalog reads of a record; the folder and name were
        # checked above, so the path is safe and root-relative.
        my $size = defined($row->{size_raw}) ? size_to_bytes($row->{size_raw}) : undef;
        my $record = {
            type => 'file', remote_path => '/' . join('/', grep { length } $folder, $row->{name}),
            size_raw => $row->{size_raw}, size_bytes => $size,
            size_precision => defined($size) ? 'estimated' : 'unknown',
        };
        $stats{files}++;
        if ($on_record) {
            unless (eval { $on_record->($record); 1 }) {
                my $error = $@ || 'record callback failed';
                $error =~ s/[\r\n]+/ /g;
                $stats{reason} = "record callback failed at line $stats{lines}: $error";
                return 0;
            }
            $stats{records_emitted}++;
        }
        return 1;
    };
    while (1) {
        my ($chunk, $error) = _read($source);
        if (defined $error) {
            $stats{reason} = $error;
            return \%stats;
        }
        last unless length $chunk;
        $stats{bytes_read} += length $chunk;
        if ($stats{bytes_read} > $max_bytes) {
            $stats{reason} = "the list is larger than $max_bytes bytes";
            return \%stats;
        }
        if (time() - $started > $max_seconds) {
            $stats{reason} = "reading the list took longer than $max_seconds seconds";
            return \%stats;
        }
        $digest->add($chunk);
        $pending .= $chunk;
        while ((my $newline = index($pending, "\n")) >= 0) {
            my $raw = substr($pending, 0, $newline + 1, '');
            if (length($raw) > $MAX_LINE_BYTES) {
                $stats{reason} = "a line of the list is longer than $MAX_LINE_BYTES bytes";
                return \%stats;
            }
            return \%stats unless $line_of->($raw);
        }
        if (length($pending) > $MAX_LINE_BYTES) {
            $stats{reason} = "a line of the list is longer than $MAX_LINE_BYTES bytes";
            return \%stats;
        }
    }
    return \%stats if length($pending) && !$line_of->($pending);
    if (defined(my $error = _finish($source))) {
        $stats{reason} = $error;
        return \%stats;
    }
    unless ($stats{files}) {
        $stats{reason} = "no row starting !$nick was found in the list";
        return \%stats;
    }
    $stats{sha256} = $digest->hexdigest;
    $stats{ok} = 1;
    return \%stats;
}

1;
