use strict;
use warnings;
use utf8;

use Encode qw(decode FB_CROAK);
use JSON::PP qw(decode_json);
use Fcntl qw(SEEK_SET);

my ($source_path, $context_json, $library_dir, $limits_json) = @ARGV;
die "usage: ManifestStream.pl <source> <context-json> <library-dir>\n"
    unless defined($source_path) && defined($context_json) && defined($library_dir);
unshift @INC, $library_dir;
require FServe::Discovery::Manifest;
require FServe::Discovery::PostedList;

my $context = decode_json($context_json);
my $limits = defined($limits_json) && length($limits_json)
    ? decode_json($limits_json) : {};
die "context and limits must be JSON objects\n"
    unless ref($context) eq 'HASH' && ref($limits) eq 'HASH';
binmode STDOUT, ':raw';
binmode STDERR, ':encoding(UTF-8)';
my $json = JSON::PP->new->canonical(1)->utf8(1);
my $emit = sub {
    my ($record) = @_;
    print STDOUT $json->encode($record), "\n"
        or die "could not write normalized record to catalog worker: $!";
};
# A list server's own list ("@Nick", 2026-10-27) has a reader of its own.
my $result = ($context->{list_format} // '') eq 'posted'
    ? FServe::Discovery::PostedList::parse_file($source_path, %$context, %$limits,
        on_record => $emit)
    : FServe::Discovery::Manifest::new_provider()->parse_file(
        $source_path, %$context, %$limits, on_record => $emit);
print STDERR $json->encode($result), "\n";
exit($result->{ok} ? 0 : 2);
