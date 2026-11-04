#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Downloads are readable as the umask allows (2026-10-28). The downloads
# folder is the operator's to share (on unRAID other users and apps read it),
# so a folder made for an @find, list or search-bot row, and a file published
# by copy, take 0777 and 0666 less the umask, not 0700 and 0600.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

plan skip_all => 'file modes are not POSIX here'
    if $^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin';

sub mode_of { return sprintf('%o', (stat($_[0]))[2] & 07777) }

for my $umask (022, 002) {
    umask($umask);
    my $downloads = tempdir(CLEANUP => 1);
    my $folder = sprintf('%o', 0777 & ~$umask);
    my $file_mode = sprintf('%o', 0666 & ~$umask);
    for my $row ({ from_find => 1 }, { from_list => 1 }, { searchbot_collection_id => 'c1' }) {
        my $made = Irssi::Script::dccatlas::direct_searchbot_destination_dir({
            download_dir => $downloads, destination_network => 'Net',
            expected_sender => 'Server', %$row });
        ok($made, 'a folder is made for ' . join(',', keys %$row)) or next;
        my $current = $made;
        while ($current ne $downloads) {
            is(mode_of($current), $folder, sprintf('umask %03o: %s is %s', $umask,
                substr($current, length($downloads)), $folder));
            $current =~ s{/[^/]+\z}{};
        }
    }
    my $source = "$downloads/staged.bin";
    open(my $out, '>', $source) or die $!;
    print {$out} "bytes";
    close $out;
    my $destination = "$downloads/published.bin";
    ok(Irssi::Script::dccatlas::_copy_to_exclusive_destination($source, $destination),
        'a file is published by copy');
    is(mode_of($destination), $file_mode, sprintf('umask %03o: it is %s', $umask, $file_mode));
}

done_testing();
