#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Rows to post back, "!Nick file ::INFO:: size", sent in answer to @find by
# the file server they name (2026-10-20). Only such a row, from that nick, is
# taken; it is fetched as a search bot's row is.

use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $row = \&Irssi::Script::dccatlas::find_direct_row_text;
my $server = MockServer->new();
$server->{nick} = 'Atlas';

is($row->($server, 'QRSN', '!QRSN Space Saga Companion.pdf ::INFO:: 873.78 KiB'),
    '!QRSN Space Saga Companion.pdf ::INFO:: 873.78 KiB', 'a row from the nick it names');
is($row->($server, 'qrsn', '!QRSN Space Saga Companion.pdf ::INFO:: 873.78 KiB'),
    '!QRSN Space Saga Companion.pdf ::INFO:: 873.78 KiB', 'nicks compare without case');
is($row->($server, 'a[b]', '!A{B} file.pdf ::INFO:: 1 KiB'),
    '!A{B} file.pdf ::INFO:: 1 KiB', 'and as IRC folds brackets');
is($row->($server, 'QRSN', "  \x0302!QRSN \x02x.pdf\x02 ::INFO:: 1 KiB\x03  "),
    '!QRSN x.pdf ::INFO:: 1 KiB', 'colours, bold and edge spaces are removed');
is($row->($server, 'Liar', '!QRSN x.pdf ::INFO:: 1 KiB'), undef,
    'a row naming another nick than its sender is not taken');
is($row->($server, 'QRSN', '!QRSN x.pdf'), undef, 'nor one without ::INFO::');
is($row->($server, 'QRSN', '!QRSN x.pdf ::INFO::'), undef, 'nor one with an empty size');
is($row->($server, 'QRSN', '!QRSN ::INFO:: 1 KiB'), undef, 'nor one with no file name');
is($row->($server, 'QRSN', 'I have found 198 file(s) for your query: Space Saga.'), undef,
    'a header line is not a row');
is($row->($server, 'QRSN', 'From list @QRSN found 198, displaying 30:'), undef,
    'nor is the list line');

done_testing();
