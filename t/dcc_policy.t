use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;

use lib "$Bin/../lib";

use FServe::DccPolicy qw(legacy_alias_conflict match_filename same_peer);

my $peer = bless {
    nick     => 'CaptainEpix',
    servertag => 'FServeLab',
}, 'MockDcc';
ok same_peer($peer, 'CaptainEpix', 'FServeLab'),
    'expected nick and server tag match';
ok same_peer($peer, 'CAPTAINEPIX', 'fservelab'),
    'peer identity comparisons are case-insensitive';
ok !same_peer($peer, 'AnotherBot', 'FServeLab'),
    'a different nick is rejected';
ok !same_peer($peer, 'CaptainEpix', 'OtherNet'),
    'a different server tag is rejected';
ok !same_peer({ nick => 'CaptainEpix' }, 'CaptainEpix', 'FServeLab'),
    'a DCC record with no server tag is rejected';
ok !same_peer($peer, '', 'FServeLab'),
    'an empty expected nick cannot authorize a DCC peer';
ok !same_peer($peer, 'CaptainEpix', ''),
    'an empty expected server tag cannot authorize a DCC peer';
ok same_peer(
    { nick => 'CaptainEpix', server => { tag => 'FServeLab' } },
    'CaptainEpix', 'FServeLab'
), 'server tag falls back to the DCC server object';

my $space_file = {
    type => 'file', name => 'foo bar.txt', parent => '/Movies',
    path => '/Movies/foo bar.txt',
};
my $underscore_file = {
    type => 'file', name => 'foo_bar.txt', parent => '/Movies',
    path => '/Movies/foo_bar.txt',
};
my $other_directory_file = {
    type => 'file', name => 'foo_bar.txt', parent => '/Other',
    path => '/Other/foo_bar.txt',
};
my @catalog = ($space_file, $underscore_file, $other_directory_file);

is_deeply [match_filename('foo bar.txt', 'foo bar.txt', '/Movies', \@catalog)],
    ['exact', 1], 'an exact requested filename is accepted';
is_deeply [match_filename('FOO BAR.TXT', 'foo bar.txt', '/Movies', \@catalog)],
    ['exact', 1], 'exact filename matching is case-insensitive';
is_deeply [match_filename('foo_bar.txt', 'foo bar.txt', '/Movies', [$space_file])],
    ['space-to-underscore', 1], 'the exact legacy alias is accepted when unambiguous';
is_deeply [match_filename('foo_bar.txt', 'foo bar.txt', '/Movies', \@catalog)],
    ['ambiguous-space-to-underscore', 0],
    'a real sibling with the alias name makes the offer ambiguous';
is_deeply [match_filename('foo__bar.txt', 'foo bar.txt', '/Movies', \@catalog)],
    ['none', 0], 'a merely similar filename is rejected';
is_deeply [match_filename('foo_bar.txt', 'foo bar.txt', '/Elsewhere', \@catalog)],
    ['space-to-underscore', 1], 'alias collision checks are scoped to the parent';

is legacy_alias_conflict($space_file, catalog => \@catalog)->{path},
    '/Movies/foo_bar.txt', 'preflight finds a colliding file in the catalog';
is legacy_alias_conflict(
    $space_file,
    verified_parent_path  => '/Movies',
    verified_parent_files => [$space_file],
    catalog               => \@catalog,
), undef, 'a matching fresh listing takes precedence over stale catalog entries';
is legacy_alias_conflict(
    $space_file,
    verified_parent_path  => '/Other',
    verified_parent_files => [$other_directory_file],
    catalog               => \@catalog,
)->{path}, '/Movies/foo_bar.txt',
    'a verified listing for another directory does not replace the catalog';
is legacy_alias_conflict($underscore_file, catalog => \@catalog), undef,
    'a filename without spaces has no legacy alias conflict';
is legacy_alias_conflict({ type => 'dir', name => 'foo bar', parent => '/Movies' },
    catalog => \@catalog), undef, 'directories are not checked as DCC files';

done_testing();
