use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

use lib File::Spec->catdir($Bin, '..', 'lib');

use FServe::Discovery::FservePlAdvert qw(parse_advert_line);

# Lines built the way FServe.pl 2.0.0 builds them (sub show_notice in
# https://scripts.irssi.org/scripts/fserve.pl): bold around "(", "FServe
# Online" and ")"; clr_hi after every "(" and clr_txt before every ")"; clr_txt
# in front of it all. Its default colours are 12 and 15.
my ($hi, $txt) = ("\x0312", "\x0315");
sub notice {
    my ($fields, $version) = @_;
    my $msg = "\x02(\x02FServe Online\x02)\x02" . $fields;
    $msg =~ s/\(/\($hi/g;
    $msg =~ s/\)/$txt\)/g;
    return $txt . $msg . ' [FServe.pl ' . ($version // '2.0.0') . ']';
}

subtest 'the default fields' => sub {
    my $ad = parse_advert_line(notice(' Trigger:(/ctcp fsnick !fsnick) Sends:(0/2)' .
        ' Queues:(3/10) Min CPS:(9.5 kB/s)'));
    ok($ad, 'recognised') or return;
    is($ad->{part}, 'whole', 'always one line');
    is($ad->{script}, 'fserve.pl', 'named');
    is($ad->{version}, '2.0.0', 'version');
    is_deeply($ad->{triggers}, [{ trigger => '!fsnick', kind => 'ctcp', ctcp_nick => 'fsnick' }],
        'a CTCP trigger');
    is_deeply($ad->{sends}, { in_use => 0, limit => 2 }, 'sends');
    is_deeply($ad->{queues}, { in_use => 3, limit => 10 }, 'queues');
    is_deeply($ad->{stats}, { 'Min CPS' => '9.5 kB/s' }, 'minimum speed');
};

subtest 'every field' => sub {
    my $ad = parse_advert_line(notice(' Trigger:(/ctcp Srv !get) Sends:(1/2) Queues:(0/10)' .
        ' Min CPS:(9.5 kB/s) Online:(2/5) Accessed:(14 times) Snagged:(1.20 GB in 33 files)' .
        ' Record CPS:(220.4 kB/s by someone) Current Upstream:(0 B/s)' .
        ' Serving:(12.04 GB in 1669 files) Note:(be nice (please)) On FServe:(RPG books)'));
    ok($ad, 'recognised') or return;
    is_deeply($ad->{users}, { in_use => 2, limit => 5 }, 'online users');
    is($ad->{message}, 'be nice (please)', 'the note, with its own brackets');
    is($ad->{content}, 'RPG books', 'what it serves');
    is_deeply([sort keys %{$ad->{stats}}],
        ['Accessed', 'Current Upstream', 'Min CPS', 'Record CPS', 'Serving', 'Snagged'],
        'the statistics');
    is($ad->{stats}{Serving}, '12.04 GB in 1669 files', 'kept as written');
};

subtest 'fields in another order, and only some' => sub {
    my $ad = parse_advert_line(notice(' Note:(hi) Trigger:(/ctcp Srv !t)', '2.0.1'));
    ok($ad, 'recognised') or return;
    is($ad->{version}, '2.0.1', 'another version');
    is($ad->{message}, 'hi', 'note first');
    ok(!exists $ad->{sends}, 'no sends');
};

subtest 'not taken' => sub {
    my @cases = (
        ['no trigger', notice(' Sends:(0/2)')],
        ['no fields', notice('')],
        ['a channel trigger', notice(' Trigger:(!get)')],
        ['a trigger with more words', notice(' Trigger:(/ctcp Srv !a b)')],
        ['a field twice', notice(' Trigger:(/ctcp Srv !t) Sends:(0/2) Sends:(0/2)')],
        ['an unknown field', notice(' Trigger:(/ctcp Srv !t) Mood:(good)')],
        ['text before the fields', notice(' hello Trigger:(/ctcp Srv !t)')],
        ['a bad count', notice(' Trigger:(/ctcp Srv !t) Sends:(lots)')],
        ['no ending', "(FServe Online) Trigger:(/ctcp Srv !t)"],
        ['another ending', "(FServe Online) Trigger:(/ctcp Srv !t) [FServe.pl]"],
        ['text after the ending', notice(' Trigger:(/ctcp Srv !t)') . ' extra'],
        ['chat about it', 'is FServe Online today? [FServe.pl 2.0.0]'],
        ['a SysReset advert', '[Fserve Active] - Trigger:[!x] - SysReset 2.55'],
        ['a long note', notice(' Trigger:(/ctcp Srv !t) Note:(' . ('x' x 301) . ')')],
        ['a control character', notice(" Trigger:(/ctcp Srv !t) Note:(a\x07b)")],
        ['too long a line', notice(' Trigger:(/ctcp Srv !t) Note:(' . ('x' x 1100) . ')')],
        ['undefined', undef],
    );
    for my $case (@cases) {
        is(parse_advert_line($case->[1]), undef, $case->[0]);
    }
};

done_testing();
