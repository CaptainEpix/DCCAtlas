use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Zip qw(zip $ZipError);
use Test::More;

use lib File::Spec->catdir($Bin, '..', 'lib');

use FServe::Discovery::PostedList qw(parse_file parse_row);

# A list server's list, in the layout a real one had (2026-10-27): an indented
# banner, folder headings, "!Nick name  ::INFO:: size" rows, a "new files"
# section whose rows carry a %hash%, and Windows-1252 text.
my $text = join("\r\n",
    '  WELCOME TO MY SERVER.',
    '  !shelfbot indented, so banner text',
    '===========================================================================',
    'NEW FILES: 7 Days old or Less as of date in file name',
    '!shelfbot %7EDFBBC9F143% A C Marlow - Raven Rave Island.epub',
    '!shelfbot %GCA77E5F2B6A% A L Example - Carved in the Rock.epub',
    'D:\\Newlist\\Bundles 2026\\Bundle 2643\\',
    '!shelfbot A C Marlow - Raven Rave Island.epub  ::INFO:: 1.14MB',
    '!shelfbot A L Example - Carved in the Rock.epub  ::INFO:: 2.01MB',
    'D:\\Newlist\\Audio Books\\',
    "!shelfbot Ana Pe\xf1a - The Villa (Audiobook).zip  ::INFO:: 305.61MB",
    '!SHELFBOT Witches.pdf  ::INFO:: 73.82MB',
    '!shelfbot Plain row without a size.epub',
    '!other Not shelfbot.epub  ::INFO:: 1KB',
    '!shelfbot bad/name.epub  ::INFO:: 1KB',
    'D:\\Newlist\\..\\Escape\\',
    '809076 Total files for 2.29TB', '');

my $dir = tempdir(CLEANUP => 1);
my $plain = File::Spec->catfile($dir, 'shelfbot.txt');
open my $fh, '>:raw', $plain or die $!;
print {$fh} $text;
close $fh;

sub read_list {
    my ($path, %args) = @_;
    my @records;
    my $result = parse_file($path, server_nick => 'shelfbot',
        on_record => sub { push @records, $_[0] }, %args);
    return ($result, \@records);
}

subtest 'a plain list' => sub {
    my ($result, $records) = read_list($plain);
    ok($result->{ok}, 'read') or diag(explain($result));
    is($result->{files}, 5, 'five files of shelfbot');
    is($result->{records_emitted}, 5, 'each given to the catalog');
    like($result->{sha256}, qr/\A[0-9a-f]{64}\z/, 'with a digest');
    is_deeply([map { $_->{remote_path} } @$records], [
        '/Newlist/Bundles 2026/Bundle 2643/A C Marlow - Raven Rave Island.epub',
        '/Newlist/Bundles 2026/Bundle 2643/A L Example - Carved in the Rock.epub',
        "/Newlist/Audio Books/Ana Pe\x{f1}a - The Villa (Audiobook).zip",
        '/Newlist/Audio Books/Witches.pdf',
        '/Newlist/Audio Books/Plain row without a size.epub',
    ], 'each under its folder heading; no hashed repeat, banner, other nick or unsafe name');
    is($records->[0]{size_raw}, '1.14MB', 'the size as the list wrote it');
    is($records->[0]{size_precision}, 'estimated', 'is an estimate');
    ok($records->[0]{size_bytes} > 1_000_000, 'and is read');
    is($records->[4]{size_precision}, 'unknown', 'a row without one has none');
};

subtest 'the same list zipped' => sub {
    my $zipped = File::Spec->catfile($dir, 'shelfbot-newlist.zip');
    zip(\$text => $zipped, Name => 'shelfbot-newlist.txt') or die $ZipError;
    my ($result, $records) = read_list($zipped);
    ok($result->{ok}, 'read') or diag(explain($result));
    is($result->{files}, 5, 'the same five files');
    my $two = File::Spec->catfile($dir, 'two.zip');
    my $n = 0;
    zip([$plain, $plain] => $two, FilterName => sub { $_ = 'x' . ++$n . '.txt' })
        or die $ZipError;
    ok(!(read_list($two))[0]{ok}, 'a ZIP holding more than the list is refused');
    my $exe = File::Spec->catfile($dir, 'exe.zip');
    zip(\$text => $exe, Name => 'setup.exe') or die $ZipError;
    ok(!(read_list($exe))[0]{ok}, 'a ZIP holding no .txt is refused');
};

subtest 'bounds' => sub {
    my ($small) = read_list($plain, max_source_bytes => 100);
    ok(!$small->{ok}, 'a list over the byte limit is refused');
    my ($few) = read_list($plain, max_rows => 2);
    ok(!$few->{ok}, 'a list over the file limit is refused');
    my ($nobody) = parse_file($plain, server_nick => 'nobody');
    ok(!$nobody->{ok}, 'a list with no row of its server is refused');
    like($nobody->{reason}, qr/no row starting !nobody/, 'and says so');
};

subtest 'one row at a time' => sub {
    is_deeply(parse_row('D:\\Books\\Fiction\\', 'x'), { folder => 'Books/Fiction' }, 'a heading');
    is_deeply(parse_row('!x a b.epub  ::INFO:: 1KB', 'X'),
        { name => 'a b.epub', size_raw => '1KB' }, 'a row, nick by case');
    is(parse_row('!x a ::INFO:: 1 ::INFO:: 2', 'x'), undef, 'two sizes are not a row');
    is(parse_row(' !x a.epub', 'x'), undef, 'an indented line is not a row');
};

# vListMaker's layout (2026-10-28, two real lists): headings in brackets, the
# same names in many folders, and the drive's own top as a folder.
subtest 'headings in brackets' => sub {
    is_deeply(parse_row('[ Contents of C:\MISC\RPG\MANUALS\13THAGE1E\ ]', 'x'),
        { folder => 'MISC/RPG/MANUALS/13THAGE1E' }, 'a bracketed heading');
    is_deeply(parse_row('[ Contents of F:\ ]', 'x'), { folder => '' }, 'the drive itself');
    is(parse_row('[ Contents of F:\..\Out\ ]', 'x'), undef, 'no way out of the list');
    is(parse_row('[ Contents of nothing ]', 'x'), undef, 'nor a heading naming no folder');
    my $listed = File::Spec->catfile($dir, 'vlist.txt');
    open my $out, '>:raw', $listed or die $!;
    print {$out} join("\r\n",
        'This list contains 3 files (1.00 GiB) - generated by vListMaker by vadi v2.0.',
        'Type "!lister FILENAME" to retrieve a file.', '', '',
        '[ Contents of F:\ ]',
        '!lister Top.pdf     ::INFO:: 1.00 MiB', '',
        '[ Contents of F:\Game One\ ]',
        '!lister Character Sheet.pdf     ::INFO:: 421.20 KiB', '',
        '[ Contents of F:\Game Two\ ]',
        '!lister Character Sheet.pdf     ::INFO:: 1.06 MiB', '');
    close $out;
    my @records;
    my $result = parse_file($listed, server_nick => 'lister',
        on_record => sub { push @records, $_[0] });
    ok($result->{ok}, 'read') or diag(explain($result));
    is_deeply([map { $_->{remote_path} } @records],
        ['/Top.pdf', '/Game One/Character Sheet.pdf', '/Game Two/Character Sheet.pdf'],
        'one name in two folders is two files');
    is($result->{directories}, 3, 'each heading read');
};

# A catalog of fields (2026-10-28, OmenServe on UnderNet): only rows naming
# "!Nick file" are files; title-and-link rows are works it cannot send.
subtest 'a catalog of fields' => sub {
    is(parse_row('2545 | Adam Example - Fale | https://example.org/katalog/fale/', 'grain'),
        undef, 'a title with only a link is no file');
    is_deeply(parse_row('1052323 | Hengtangtuishi - Poems | !Grain Poems [PG-52323].epub', 'grain'),
        { name => 'Poems [PG-52323].epub', size_raw => undef }, 'a row naming the file');
    is_deeply(parse_row("2035545 | 't Hart, Paul - Great | !Grain 't Hart, Paul - Great "
            . '[DOAB-2035545].pdf | https://creativecommons.org/licenses/by/4.0/', 'grain'),
        { name => "'t Hart, Paul - Great [DOAB-2035545].pdf", size_raw => undef },
        'and the licence after it is left off');
    is(parse_row('Usage: !get <ID> or !Grain <exact filename>', 'grain'), undef, 'nor usage text');
    is(parse_row('1 | Someone - Else | !Other Book.epub', 'grain'), undef, "nor another nick's row");
};

# OmenServe's layout (2026-10-28, a real list of 1.6 million files): folder
# headings framed in "=" lines, with no drive; one name in two folders.
subtest 'headings framed in rules' => sub {
    my $listed = File::Spec->catfile($dir, 'omen.txt');
    open my $out, '>:raw', $listed or die $!;
    print {$out} join("\r\n",
        'OmenServe v2.73 (c) OmenScripts',
        'To request a file, copy/paste to the channel... !omen FILENAME', '',
        '===============', '+1New\\2025\\2025-01-12', '===============',
        '!omen Kinky Example - Roadkill.epub ::INFO:: 82.29KB', '',
        '===============', '+1New\\2025\\2025-01-19', '===============',
        '!omen Kinky Example - Roadkill.epub ::INFO:: 392.66KB',
        '==========', 'Single Folder', '==========',
        '!omen Alone.epub ::INFO:: 1KB',
        '==========', '!omen Not A Heading.epub ::INFO:: 2KB', '');
    close $out;
    my @records;
    my $result = parse_file($listed, server_nick => 'omen',
        on_record => sub { push @records, $_[0] });
    ok($result->{ok}, 'read') or diag(explain($result));
    is_deeply([map { $_->{remote_path} } @records], [
        '/+1New/2025/2025-01-12/Kinky Example - Roadkill.epub',
        '/+1New/2025/2025-01-19/Kinky Example - Roadkill.epub',
        '/Single Folder/Alone.epub',
        '/Single Folder/Not A Heading.epub',
    ], 'each under its framed heading; a row after a rule stays a row');
    is(FServe::Discovery::PostedList::parse_framed_heading('..\\escape'), undef,
        'no way out of the list');
};

# Another OmenServe list (2026-10-29): "/" between folders, a welcome text
# with its own lines of "=", and a hash after each size.
subtest 'framed headings with slashes, and a banner' => sub {
    my $listed = File::Spec->catfile($dir, 'omen2.txt');
    open my $out, '>:raw', $listed or die $!;
    print {$out} join("\r\n",
        'WELCOME TO MY SERVER.', '  =============================', '   ',
        '=====', 'OmenServe v2.74 (c) OmenScripts & BuildDatabase v1.6 (c) quill', '',
        '========================================',
        'Fiction/A/A K Example, Other Example',
        '========================================',
        '!quill A K Example - Wrath of One (epub).rar  ::INFO:: 232KB ::HASH:: ad0fd9fbf18ec25d', '');
    close $out;
    my @records;
    my $result = parse_file($listed, server_nick => 'quill',
        on_record => sub { push @records, $_[0] });
    ok($result->{ok}, 'read') or diag(explain($result));
    is_deeply([map { $_->{remote_path} } @records],
        ['/Fiction/A/A K Example, Other Example/A K Example - Wrath of One (epub).rar'],
        'the heading between two rules; the banner line under one rule is no folder');
    is($records[0]{size_raw}, '232KB', 'the size without the hash after it');
};

# A list whose every row has a "%hash%" before its name (2026-10-29, nearly a
# million files): under a heading each is a file, named after the hash.
subtest 'hashed rows under headings' => sub {
    my $listed = File::Spec->catfile($dir, 'fw.txt');
    open my $out, '>:raw', $listed or die $!;
    print {$out} join("\r\n",
        '=' x 75, 'G:\\Library\\New Arrivals\\', '=' x 75,
        '!sprout %586A4F8B434B% A J Example - Do Not Speak.epub  ::INFO:: 328.26 KB',
        '!sprout %62D962370E55% Other Writer - Someday.epub  ::INFO:: 228.67 KB', '');
    close $out;
    my @records;
    my $result = parse_file($listed, server_nick => 'sprout',
        on_record => sub { push @records, $_[0] });
    ok($result->{ok}, 'read') or diag(explain($result));
    is_deeply([map { [$_->{remote_path}, $_->{size_raw}] } @records], [
        ['/Library/New Arrivals/A J Example - Do Not Speak.epub', '328.26 KB'],
        ['/Library/New Arrivals/Other Writer - Someday.epub', '228.67 KB'],
    ], 'each a file, by the name after its hash');
};

# OmenServe names a list "<Nick>-<list name>" and writes it in each row
# (2026-11-02, a list of a million files): read by that word, row_nick.
subtest 'rows naming the list, not the nick' => sub {
    my $listed = File::Spec->catfile($dir, 'named.txt');
    open my $out, '>:raw', $listed or die $!;
    print {$out} join("\r\n",
        'List Quill-Ebooks2 of 2 Files (1MB)', '',
        'To request a file, copy/paste to the channel... !Quill FILENAME', '',
        '======', 'EBookz/2006/01 June 06', '======',
        '!Quill-Ebooks2 A B Example - Witherspin (v1.0) [rtf].rar  ::INFO:: 37KB ::HASH:: 6191bcee55ba0c88',
        '!Quill-Ebooks3 From another list.rar  ::INFO:: 1KB',
        '!Quill Other Example - Snail Stones.rar  ::INFO:: 17KB', '');
    close $out;
    my ($by_nick) = parse_file($listed, server_nick => 'Quill');
    ok($by_nick->{ok}, 'by the nick, its own row only') or diag(explain($by_nick));
    is($by_nick->{files}, 1, 'one file');
    my @records;
    my $result = parse_file($listed, server_nick => 'Quill', row_nick => 'quill-ebooks2',
        on_record => sub { push @records, $_[0] });
    ok($result->{ok}, 'read') or diag(explain($result));
    is_deeply([map { [$_->{remote_path}, $_->{size_raw}] } @records], [
        ['/EBookz/2006/01 June 06/A B Example - Witherspin (v1.0) [rtf].rar', '37KB'],
    ], "the list's rows, not another list's or the nick's own");
    my ($none) = parse_file($listed, server_nick => 'Quill', row_nick => 'Quill-Ebooks9');
    like($none->{reason}, qr/no row starting !Quill-Ebooks9/, 'a word with no rows says so');
};

done_testing();
