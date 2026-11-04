#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Lists, and search bots' result lists, are kept in a folder of their own,
# not with the downloads, and one received again under the same name takes
# the old one's place instead of being kept beside it (2026-10-28).

use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

is(Irssi::Script::dccatlas::lists_dir(), "$test_root/fserve-poc/lists",
    'lists are kept in the Irssi home unless set');
my $lists = tempdir(CLEANUP => 1);
Irssi::settings_set_str('fscrawl_lists_dir', $lists);
is(Irssi::Script::dccatlas::lists_dir(), $lists, 'or where the setting says');

sub slurp {
    open(my $in, '<:raw', $_[0]) or return undef;
    local $/;
    return scalar <$in>;
}

my $staged = 0;
# One file received as $file describes, holding $bytes; where it was kept.
sub receive {
    my ($file, $bytes) = @_;
    my $stage = "$lists/.incoming/" . ++$staged;
    make_path($stage);
    my $name = $file->{name};
    open(my $out, '>:raw', "$stage/$name") or die $!;
    print {$out} $bytes;
    close $out;
    return Irssi::Script::dccatlas::finalize_download(
        { %$file, staging_dir => $stage, local_sha256 => undef },
        { file => "$stage/$name" });
}

my $list = {
    type => 'file', name => 'share.VPS.2026-10-22-(1801).rar', download_dir => $lists,
    retrieval_protocol => 'searchbot_direct_send', list_request => 1,
    replace_same_name => 1, destination_network => 'irc.example.net',
    expected_sender => 'Lister', server_nick => 'Lister',
};
my $first = receive($list, 'first list');
is($first, "$lists/irc.example.net/Lister/\@list/share.VPS.2026-10-22-(1801).rar",
    'a list is kept under its server in the lists folder');
my $again = receive($list, 'second list');
is($again, $first, 'the same list again takes the same name');
is(slurp($again), 'second list', 'and holds what came last');
ok(!-e "$lists/irc.example.net/Lister/\@list/share.VPS.2026-10-22-(1801)-1.rar",
    'with no copy kept beside it');

my $results = {
    type => 'file', name => 'SearchBot_results_for_dune.txt.zip',
    path => '/SearchBot results/SearchBot_results_for_dune.txt.zip',
    download_dir => $lists, network_id => 'irc.example.net', server_nick => 'Search',
    trigger_raw => '@search', replace_same_name => 1,
};
my $kept = receive($results, 'old results');
like($kept, qr{\A\Q$lists\E/irc\.example\.net/Search/\@search/}, 'a result list is kept there too');
is(receive($results, 'new results'), $kept, 'a newer one of its name replaces it');
is(slurp($kept), 'new results', 'holding the newer results');

my $book = { %$list, list_request => 0, replace_same_name => 0, from_list => 1,
    name => 'Book.epub' };
my $one = receive($book, 'one');
my $two = receive($book, 'two');
isnt($two, $one, 'a file that is no list is never replaced');
is(slurp($one), 'one', 'and the first is left as it was');

done_testing();
