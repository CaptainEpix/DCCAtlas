#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Each request stages its file in a folder of its own under .incoming. Such
# folders were never removed (2026-10-29): now one goes once it is empty and
# done with, and an empty one left two hours goes when the next is made, or
# when the engine starts. A folder holding anything stays.

use FindBin;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";
my $engine = 'Irssi::Script::dccatlas';

my $downloads = tempdir(CLEANUP => 1);
my $incoming = File::Spec->catdir($downloads, '.incoming');
my $hours_ago = time() - 3 * 3600;
sub folder {
    my ($name, %how) = @_;
    my $path = File::Spec->catdir($incoming, $name);
    make_path($path);
    if ($how{file}) {
        open(my $out, '>', File::Spec->catfile($path, 'partial.part')) or die $!;
        close $out;
    }
    utime($hours_ago, $hours_ago, $path) if $how{old};
    return $path;
}

my $old_empty = folder('20261029-100000-1-1', old => 1);
my $young_empty = folder('20261029-120000-1-2');
my $old_full = folder('20261029-100000-1-3', old => 1, file => 1);
my $other = folder('kept-by-someone', old => 1);

is(Irssi::Script::dccatlas::sweep_empty_staging($downloads), 1, 'one folder swept');
ok(!-e $old_empty, 'an empty folder left two hours goes');
ok(-d $young_empty, 'a young empty one stays: its request may still be waiting');
ok(-d $old_full, 'one holding a partial stays');
ok(-d $other, 'a folder not named as staging is left alone');

Irssi::Script::dccatlas::remove_empty_staging($young_empty);
ok(!-e $young_empty, 'a request done with its empty folder removes it at once');
Irssi::Script::dccatlas::remove_empty_staging($old_full);
ok(-d $old_full, 'but not one holding anything');
my $outside = File::Spec->catdir(tempdir(CLEANUP => 1), '20261029-100000-1-4');
make_path($outside);
Irssi::Script::dccatlas::remove_empty_staging($outside);
ok(-d $outside, 'nor a folder outside .incoming');

# Making a new staging folder sweeps the old empty ones first.
my $stale = folder('20261029-090000-1-5', old => 1);
my $file = { download_dir => $downloads };
ok(Irssi::Script::dccatlas::prepare_download_staging($file), 'a new staging folder');
ok(-d $file->{staging_dir}, 'is made');
ok(!-e $stale, 'and the stale empty one went first');

done_testing();
