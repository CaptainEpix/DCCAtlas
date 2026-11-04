use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

use lib File::Spec->catdir($Bin, '..', 'lib');

use FServe::Discovery::ListAdvert qw(parse_advert_line names_own_list);

# List servers' adverts in the wording seen in a real ebook channel on
# 2026-10-27 (nicks changed).
subtest 'three servers, three wordings' => sub {
    for my $case (
        ['ListServe', "Manuals and docs, back online!\x02 Type: \@ListServe" .
            ' For My List Of: 3,768 Files ' . "\x{2022}" . ' Slots: 2/2'],
        ['Musing', "\x0304 Type: \@Musing For My List Of: 1,068,389 Files  Slots: 25/25"],
        ['Archivist', 'Type: @Archivist for my latest file listing (Updated: ' .
            '2026-09-30 14:13:11), 98,846 titles in 125,795 files, 2.2 TB total'],
    ) {
        my ($nick, $line) = @$case;
        my $ad = parse_advert_line($line, $nick);
        ok($ad, "$nick recognised") or next;
        is($ad->{script}, 'list', 'a list server');
        is_deeply($ad->{triggers}, [{ trigger => '@' . $nick, kind => 'list' }],
            'its one trigger is @ and its nick');
        unlike($ad->{message}, qr/[\x00-\x1f]/, 'its words, without formatting');
    }
};

subtest 'only the sender naming itself' => sub {
    ok(!parse_advert_line('@Musing thanks for the book', 'Reader'), 'another nick asking');
    ok(!parse_advert_line('get the list with @Musing', 'Mus'), 'a nick inside a longer one');
    ok(!parse_advert_line('email me at me@Musing.example', 'Musing'),
        'an @ inside a word');
    ok(!parse_advert_line('Type: !Musing for files', 'Musing'), 'no @');
    ok(parse_advert_line('type @musing for my list', 'Musing'), 'nick case is IRC case');
    ok(names_own_list('ask @Nick[1] now', 'nick{1}'), 'and RFC 1459 brackets fold');
    ok(!names_own_list('ask @Nick[1]x now', 'Nick[1]'), 'but the nick must end there');
};

subtest 'UTF-8 text as Irssi passes it, in bytes' => sub {
    my $bytes = "\xe2\x80\xa2 Type: \@TuneKeeper For My List Of: 149,986 Files \xe2\x80\xa2 Slots: 3/3";
    my $ad = parse_advert_line($bytes, 'TuneKeeper');
    ok($ad, 'recognised') or return;
    is($ad->{message}, "\x{2022} Type: \@TuneKeeper For My List Of: 149,986 Files \x{2022} Slots: 3/3",
        'its bullets are bullets');
    ok(parse_advert_line("Type: \@Latin \xa9 list", 'Latin'), 'bytes that are not UTF-8 are kept');
};

subtest 'bounds' => sub {
    ok(!parse_advert_line('@Bot ' . ('x' x 1100), 'Bot'), 'an over-long line is not read');
    my $ad = parse_advert_line('@Bot ' . ('y' x 600), 'Bot');
    ok($ad, 'a long one is');
    ok(length($ad->{message}) <= 300, 'its words are cut to 300 characters');
    ok(!parse_advert_line('@Bad Nick', 'Bad Nick'), 'a nick with a space is never one');
};

done_testing();
