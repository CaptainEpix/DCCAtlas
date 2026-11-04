use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

use lib File::Spec->catdir($Bin, '..', 'lib');

use FServe::Discovery::SysResetAdvert qw(parse_advert_line merge_advert_parts strip_formatting);

# Lines built the way SysReset 2.55's script builds them (system/aliases.ini,
# alias "ad"), with its two colours: %col1 before brackets and separators,
# %col2 before values. The lab's profile uses 04 and 14.
my ($c1, $c2) = ("\x0304", "\x0314");
sub field { my ($key, $value) = @_; return " - $key:[$c2$value$c1]" }
sub head_marker { my ($restricted) = @_;
    return "$c1\[$c2" . (defined $restricted ? "$restricted " : '') . "Fserve Active$c1]" }
my $ending = ' - SysReset 2.55';

subtest 'one channel trigger, as the lab sends it' => sub {
    my $line = head_marker() . " - Trigger:[$c2!fserve$c1(0/10)$c1]" .
        field('Users', '0/5') . " - Message:[${c2}FServe test server$c1]" . $ending;
    my $ad = parse_advert_line($line);
    ok($ad, 'recognised') or return;
    is($ad->{part}, 'whole', 'whole advert');
    is($ad->{version}, '2.55', 'version');
    is_deeply($ad->{triggers}, [{ trigger => '!fserve', kind => 'channel',
        queued => 0, queue_limit => 10 }], 'trigger with its queue');
    is_deeply($ad->{users}, { in_use => 0, limit => 5 }, 'users');
    is($ad->{message}, 'FServe test server', 'message');
    ok(!exists $ad->{restricted}, 'not restricted');
};

subtest 'two triggers, one by CTCP, with sends and queues' => sub {
    my $line = head_marker() . " - Triggers:[$c2!fserve $c1& $c2/ctcp CaptainEpix !fserve2$c1]" .
        field('Users', '1/5') . field('Sends', '1/2') . field('Queues', '3/10') . $ending;
    my $ad = parse_advert_line($line);
    ok($ad, 'recognised') or return;
    is_deeply($ad->{triggers}, [
        { trigger => '!fserve', kind => 'channel' },
        { trigger => '!fserve2', kind => 'ctcp', ctcp_nick => 'CaptainEpix' },
    ], 'both triggers');
    is_deeply($ad->{sends}, { in_use => 1, limit => 2 }, 'sends');
    is_deeply($ad->{queues}, { in_use => 3, limit => 10 }, 'queues');
    ok(!exists $ad->{message}, 'no message');
};

subtest 'separator without spaces around the ampersand' => sub {
    my $ad = parse_advert_line(head_marker() . " - Triggers:[$c2!a$c1&$c2!b$c1]" . $ending);
    ok($ad, 'recognised') or return;
    is_deeply([map { $_->{trigger} } @{$ad->{triggers}}], ['!a', '!b'], 'two triggers');
};

subtest 'restricted adverts and pool numbers' => sub {
    my $ad = parse_advert_line(head_marker('OP') . " - Triggers:[${c2}1:!ops$c1 & ${c2}2:Voice:!voiced$c1]" .
        field('Queues', '1:0/10 2:4/5') . $ending);
    ok($ad, 'recognised') or return;
    is($ad->{restricted}, 'OP', 'restricted to operators');
    is_deeply($ad->{triggers}, [
        { trigger => '!ops', kind => 'channel', pool => 1 },
        { trigger => '!voiced', kind => 'channel', pool => 2, voice_only => 1 },
    ], 'pools and voice');
    is_deeply($ad->{queues}, { pools => '1:0/10 2:4/5' }, 'queues per pool kept as written');
    is(parse_advert_line(head_marker('Voice') . field('Trigger', '!v') . $ending)->{restricted},
        'Voice', 'voice advert');
};

subtest 'an advert split over two lines' => sub {
    my $head = parse_advert_line(head_marker() . field('Trigger', '!fserve') . field('Users', '0/5') .
        field('Bytes Sent', '1.2GB'));
    my $tail = parse_advert_line("${c1}Files Sent:[${c2}12$c1]" .
        " - Message:[${c2}Books [mostly] - ask: nicely$c1]" . $ending);
    is($head->{part}, 'head', 'first line is the head');
    is($tail->{part}, 'tail', 'second line is the tail');
    is($tail->{message}, 'Books [mostly] - ask: nicely', 'a message may hold brackets and dashes');
    my $ad = merge_advert_parts($head, $tail);
    ok($ad, 'merged') or return;
    is($ad->{part}, 'whole', 'whole');
    is_deeply($ad->{stats}, { 'Bytes Sent' => '1.2GB', 'Files Sent' => '12' }, 'statistics from both');
    is($ad->{version}, '2.55', 'version from the tail');
    is(merge_advert_parts($tail, $head), undef, 'order matters');
    is(merge_advert_parts($head, parse_advert_line(field('Users', '1/5') . $ending)), undef,
        'a field in both lines is refused');
};

subtest 'a tail of only the message and ending' => sub {
    my $tail = parse_advert_line("${c1}Message:[${c2}hello$c1]" . $ending);
    ok($tail, 'recognised') or return;
    is($tail->{part}, 'tail', 'tail');
    is($tail->{message}, 'hello', 'message');
};

subtest 'notice instead of triggers' => sub {
    my $ad = parse_advert_line(head_marker() . field('Notice', 'All Queues are Full') . $ending);
    ok($ad, 'recognised') or return;
    is($ad->{notice}, 'All Queues are Full', 'notice');
    ok(!exists $ad->{triggers}, 'no triggers');
};

subtest 'lines that are not SysReset adverts' => sub {
    my @not = (
        ['plain chat', 'hello there'],
        ['chat ending in the name', 'I use SysReset 2.55'],
        ['another script', head_marker() . field('Trigger', '!x') . ' - Polaris 1.2'],
        ['TDCC advert', "$c1\[${c2}TDCC active$c1]- Trigger:[$c2/ctcp me XDCC LIST$c1]" . $ending],
        ['unknown field', head_marker() . field('Trigger', '!x') . field('Mood', 'happy') . $ending],
        ['field twice', head_marker() . field('Trigger', '!x') . field('Users', '0/5') .
            field('Users', '0/5') . $ending],
        ['Trigger and Triggers', head_marker() . field('Trigger', '!x') . field('Triggers', '!y') . $ending],
        ['Trigger with two', head_marker() . field('Trigger', '!x & !y') . $ending],
        ['bad users', head_marker() . field('Trigger', '!x') . field('Users', 'lots') . $ending],
        ['bad queues', head_marker() . field('Trigger', '!x') . field('Queues', 'many') . $ending],
        ['triggers in a tail', field('Trigger', '!x') . $ending],
        ['nine triggers', head_marker() . field('Triggers', join(' & ', map { "!t$_" } 1 .. 9)) . $ending],
        ['control character', head_marker() . field('Trigger', "!x\x01") . $ending],
        ['too long', head_marker() . field('Trigger', '!x') . " - Message:[" . ('m' x 1100) . "]" . $ending],
        ['message too long', head_marker() . field('Trigger', '!x') . " - Message:[" . ('m' x 301) . "]" . $ending],
        ['text after the fields', head_marker() . field('Trigger', '!x') . ' and more' . $ending],
        ['empty', ''],
        ['undefined', undef],
    );
    for my $case (@not) {
        is(parse_advert_line($case->[1]), undef, $case->[0]);
    }
};

is(strip_formatting("\x02a\x0304,01b\x0fc\x1fd\x16e\x1df\x03g"), 'abcdefg', 'formatting stripped');

done_testing();
