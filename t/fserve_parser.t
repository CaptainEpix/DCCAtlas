use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;

use lib "$Bin/../lib";

use FServe::Parser qw(join_path parse_line size_to_bytes strip_formatting);

is strip_formatting("\x02bold\x02 \x0304red\x03"), 'bold red',
    'mIRC formatting controls are removed';
is parse_line('')->{type}, 'blank', 'empty input is classified as blank';

my $prompt = parse_line(q{[\Movies]});
is $prompt->{type}, 'prompt', 'bracketed FServe prompt is recognized';
is $prompt->{path}, q{\Movies}, 'prompt path is normalized to backslashes';
is parse_line(q{['C' for more, 'S' to stop]})->{type}, 'more_prompt',
    'historical pagination prompt is recognized';
is parse_line('*** End of list ***')->{type}, 'end',
    'end-of-list marker is recognized';
is parse_line('..')->{type}, 'parent', 'parent entry is recognized';

my $numbered_dir = parse_line('12D: TV SHOWS');
is $numbered_dir->{type}, 'dir', 'numbered directory entry is recognized';
is $numbered_dir->{name}, 'TV SHOWS', 'numbered directory name is retained';

my $numbered_file = parse_line('4F: My File With Spaces.mkv 1.5 GB');
is $numbered_file->{type}, 'file', 'numbered file entry is recognized';
is $numbered_file->{name}, 'My File With Spaces.mkv',
    'spaces in a numbered filename are retained';
is $numbered_file->{size_bytes}, 1_610_612_736,
    'numbered file size is normalized to bytes';

my $plain_file = parse_line('My File With Spaces.mkv 700 MB');
is $plain_file->{type}, 'file', 'plain file entry is recognized';
is $plain_file->{name}, 'My File With Spaces.mkv',
    'spaces in a plain filename are retained';
is $plain_file->{size_bytes}, 734_003_200,
    'plain file size is normalized to bytes';

is parse_line('SOME DIRECTORY')->{type}, 'dir',
    'uppercase directory dialect is recognized';
is parse_line('Closing idle connection in 5 seconds')->{type}, 'idle_warning',
    'idle warning is kept out of directory heuristics';
is parse_line('Queue is full')->{type}, 'status',
    'queue status is recognized';
is parse_line('Welcome to Bob\'s server')->{type}, 'noise',
    'unrecognized lines remain noise';

is size_to_bytes('3 kb'), 3_072, 'size helper accepts case-insensitive units';
is size_to_bytes('1,024 B'), 1_024, 'size helper accepts grouped byte counts';
is join_path(qw(Comics DC Batman)), '/Comics/DC/Batman',
    'path helper joins components with a canonical separator';
is join_path(), '/', 'empty path resolves to the FServe root';

# FServe.pl 2.0.0 for Irssi, as seen on 2026-10-20, colours and all.
my $fp_root = parse_line("\x0312[\\]");
is $fp_root->{type}, 'prompt', 'FServe.pl root prompt';
is $fp_root->{path}, '\\', 'at the root';
my $fp_cd = parse_line("\x0312[\x0303/###Work-in-Progress\x0312]");
is $fp_cd->{type}, 'prompt', 'FServe.pl prompt after cd';
is $fp_cd->{path}, '\\###Work-in-Progress', 'with its folder';
my $fp_listing = parse_line("\x0312Listing [\x0303/###Work-in-Progress/*.*\x0312]");
is $fp_listing->{type}, 'prompt', 'FServe.pl listing header reads as a wildcard prompt';
is $fp_listing->{path}, '\\###Work-in-Progress\\*.*', 'for its folder';
is parse_line("\x0312Listing [\x0303/*.*\x0312]")->{path}, '\\*.*', 'the root listing too';
is parse_line("\x0312End [\x0303/###Work-in-Progress\x0312]")->{type}, 'end',
    'FServe.pl listing end';
is parse_line("\x0312End [\x0303/\x0312]")->{type}, 'end', 'at the root too';
my $fp_dir = parse_line("\x0312\x0304#Fate Core\x0312/");
is $fp_dir->{type}, 'dir', 'a folder with a trailing slash';
is $fp_dir->{name}, '#Fate Core', 'named without the slash';
is parse_line("\x0312\x0304Warhammer 40,000\x0312/")->{name}, 'Warhammer 40,000',
    'a folder name with a comma';
my $fp_file = parse_line("\x0312\x0305artifacts [_oef_].pdf  487.4 kB");
is $fp_file->{type}, 'file', 'a FServe.pl file line';
is $fp_file->{name}, 'artifacts [_oef_].pdf', 'its name';
is $fp_file->{size_bytes}, 499098, 'its size';
is parse_line("\x0312\x0304..")->{type}, 'parent', 'its parent entry';
is parse_line('Endless Quest.pdf 2 MB')->{type}, 'file', 'a file named End… is still a file';
is parse_line('/')->{type}, 'noise', 'a lone slash is not a folder';

done_testing();
