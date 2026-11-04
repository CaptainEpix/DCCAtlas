#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $ok = eval {
    Irssi::run_command('fscrawl', 'list', undef, undef);
    1;
};
ok $ok, 'the first list command works in a fresh Perl process';
ok((scalar grep { /No matching files\./ } @Irssi::PRINTS),
    'a cold list reports no matches without requiring another command first');
ok(!(scalar grep { /Undefined subroutine/ } @Irssi::PRINTS),
    'cold list does not expose an undefined catalog helper');

done_testing();
