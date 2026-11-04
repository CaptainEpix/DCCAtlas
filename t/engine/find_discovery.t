#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

my $server = bless {
    connected => 1,
    tag       => 'mocknet',
    chatnet   => 'FServeLab',
    nick      => 'LocalNick',
    commands  => [],
}, 'MockServer';

sub emit_public {
    my ($from_server, $nick, $target, $message) = @_;
    Irssi::emit('message public', $from_server, $message, $nick, 'user\@host', $target);
}

sub emit_private {
    my ($from_server, $nick, $target, $message) = @_;
    Irssi::emit('message private', $from_server, $message, $nick, 'user\@host', $target);
}

sub emit_private_without_target {
    my ($from_server, $nick, $message) = @_;
    Irssi::emit('message private', $from_server, $message, $nick, 'user\@host');
}

sub emit_notice {
    my ($from_server, $nick, $target, $message) = @_;
    Irssi::emit('message irc notice', $from_server, $message, $nick, 'user\@host', $target);
}

sub contains_print {
    my ($pattern) = @_;
    return scalar grep { /$pattern/ } @Irssi::PRINTS;
}

sub read_persisted_catalog {
    my $path = File::Spec->catfile($test_root, 'fserve-poc', 'catalog.jsonl');
    open my $fh, '<', $path or die "open persistent catalog $path: $!";
    my @records = map { decode_json($_) } <$fh>;
    close $fh or die "close persistent catalog $path: $!";
    return @records;
}

sub count_find_timers {
    return scalar @Irssi::TIMERS;
}

sub find_dcc_commands {
    my @commands = (@{$server->{commands}}, @Irssi::GLOBAL_COMMANDS);
    return scalar grep { /\bDCC\b/i } @commands;
}

sub emit_chat_line {
    my ($nick, $line) = @_;
    my $chat = $Irssi::ACTIVE_CHAT_BY_NICK{lc $nick};
    die "no active mock CHAT identity for $nick" unless $chat;
    Irssi::emit('dcc chat message', $chat, $line);
}

sub mock_chat {
    my ($nick) = @_;
    return bless {
        type      => 'CHAT',
        nick      => $nick,
        id        => $nick,
        servertag => 'mocknet',
        server    => $server,
        Irssi::new_dcc_identity(),
    }, 'MockDcc';
}

sub finish_mock_fetch {
    my (%args) = @_;
    my $index = $args{index};
    my $nick = $args{nick};
    my $trigger = $args{trigger};
    my $mode = $args{mode} // 'channel';
    my $name = $args{name};
    my $local_name = $args{local_name} // $name;
    my $size = $args{size};

    Irssi::run_command('fscrawl', "fetch $index $mode", $server, undef);
    my $expected_trigger_command = $mode eq 'ctcp'
        ? "CTCP $nick $trigger"
        : "MSG #files $trigger";
    ok((scalar grep { $_ eq $expected_trigger_command } @{$server->{commands}}),
        "fetch $index sends its selected $mode trigger");

    my $accepted_gets_before_request = scalar grep {
        /^DCC GET \Q$nick\E /
    } @{$server->{commands}};
    my $foreign_server = bless {
        connected => 1, tag => 'othernet', nick => 'LocalNick', commands => [],
    }, 'MockServer';
    my $foreign_offer = bless {
        type=>'GET', orig_type=>'SEND', nick=>$nick, arg=>$name,
        server=>$foreign_server, servertag=>'othernet', size=>1, transfd=>0,
        Irssi::new_dcc_identity(),
    }, 'MockDcc';
    Irssi::emit('dcc request', $foreign_offer, '127.0.0.1');
    is scalar(grep { /^DCC GET \Q$nick\E / } @{$server->{commands}}), $accepted_gets_before_request,
        'same-nick DCC SEND from another network is not accepted';
    my $closed_gets_before_request = scalar grep {
        /^DCC CLOSE GET \Q$nick\E /
    } @{$server->{commands}};
    my $early_offer = bless {
        type=>'GET', orig_type=>'SEND', nick=>$nick, arg=>$name,
        server=>$server, servertag=>'mocknet', size=>1, transfd=>0,
        Irssi::new_dcc_identity(),
    }, 'MockDcc';
    Irssi::emit('dcc request', $early_offer, '127.0.0.1');
    is scalar(grep { /^DCC CLOSE GET \Q$nick\E / } @{$server->{commands}}), $closed_gets_before_request + 1,
        'matching-nick DCC SEND arriving before verified GET is closed locally';
    is scalar(grep { /^DCC GET \Q$nick\E / } @{$server->{commands}}), $accepted_gets_before_request,
        'premature DCC SEND is not accepted';

    my $chat = mock_chat($nick);
    Irssi::emit('dcc request', $chat, '127.0.0.1');
    Irssi::emit('dcc connected', $chat);
    emit_chat_line($nick, '[\\]');
    ok((scalar grep { $_ eq "MSG =$nick dir" } @Irssi::GLOBAL_COMMANDS),
        'direct fetch starts with a verified root-relative parent listing');
    emit_chat_line($nick, '[\\*.*]');
    emit_chat_line($nick, "$name $size");
    emit_chat_line($nick, 'End of list.');
    ok((scalar grep { $_ eq "MSG =$nick get $name" } @Irssi::GLOBAL_COMMANDS),
        'GET is sent only after the fresh parent listing confirms the file');

    my $stage = $Irssi::SETTINGS{dcc_download_path};
    like($stage, qr{[\\/]\.incoming[\\/]}, 'DCC download path is a per-request staging directory');
    my $staged_file = File::Spec->catfile($stage, $name);
    open my $fh, '>', $staged_file or die "create mock staged transfer $staged_file: $!";
    print {$fh} "mock bytes for $trigger\n";
    close $fh or die "close mock staged transfer $staged_file: $!";

    my $get = bless {
        type      => 'GET',
        orig_type => 'SEND',
        nick      => $nick,
        arg       => $name,
        server    => $server,
        servertag => 'mocknet',
        size      => $size =~ /^([0-9]+)/ ? $1 : 1,
        transfd   => $size =~ /^([0-9]+)/ ? $1 : 1,
        file      => $staged_file,
        Irssi::new_dcc_identity(),
    }, 'MockDcc';
    Irssi::emit('dcc request', $get, '127.0.0.1');
    ok((scalar grep { $_ eq qq{DCC GET $nick "$name"} } @{$server->{commands}}),
        'only the matching DCC SEND is accepted');
    Irssi::emit('dcc get receive', $get);
    Irssi::emit('dcc closed', $get);

    my $base = File::Spec->catdir($test_root, 'fserve-poc', 'downloads');
    my $destination = File::Spec->catfile(
        $base, 'FServeLab', $nick, $trigger, $local_name
    );
    ok(-f $destination, 'completed transfer is moved into its collision-safe library path');
    open my $read_fh, '<', $destination or die "read finalized file $destination: $!";
    my $contents = do { local $/; <$read_fh> };
    close $read_fh;
    is $contents, "mock bytes for $trigger\n", 'final destination preserves the staged transfer contents';
    is $Irssi::SETTINGS{dcc_download_path}, $base,
        'global DCC download path returns to the configured base after completion';
    Irssi::run_command('fscrawl', 'stop', $server, undef);
    return $destination;
}

Irssi::run_command('fscrawl', 'find #files cross-trigger', $server, undef);
is_deeply $server->{commands}, ['MSG #files @find cross-trigger'],
    'find sends exactly one channel @find message';
is find_dcc_commands(), 0, 'discovery sends no DCC command';

my $other_server = bless {
    connected => 1,
    tag       => 'othernet',
    nick      => 'LocalNick',
    commands  => [],
}, 'MockServer';
my $initial_timer_count = count_find_timers();
emit_public($other_server, 'WrongNetworkBot', '#files', '[@Find Results] -=SysReset 2.55=-');
emit_public($server, 'WrongChannelBot', '#other', '[@Find Results] -=SysReset 2.55=-');
is count_find_timers(), $initial_timer_count,
    'messages from other networks and channels do not extend collection';

# Responses from two server nicks are interleaved. One nick returns two
# trigger sections for the same path, which must remain separate selections.
emit_public($server, 'CaptainEpix', '#files', '[@Find Results] -=SysReset 2.55=-');
my $stale_quiet_timer = $Irssi::TIMERS[-1];
emit_public($server, 'SecondBot', '#files', '[@Find Results] -=SysReset 2.55=-');
emit_public($server, 'CaptainEpix', '#files', 'Found [1] file on Trigger:[!fserve] - Sends:[0/1] - Queues:[0/1]');
emit_public($server, 'CaptainEpix', '#files', 'File: [cross-trigger.txt] - Size [37B]');
emit_public($server, 'SecondBot', '#files', 'Found [1] file on Trigger:[!other] - Sends:[0/2] - Queues:[1/3]');
emit_public($server, 'SecondBot', '#files', 'File: [second-bot.txt] - Size [8B]');
emit_public($server, 'CaptainEpix', '#files', 'Found [1] file on Trigger:[!fserve2] - Sends:[0/1] - Queues:[0/1]');
emit_public($server, 'CaptainEpix', '#files', 'File: [cross-trigger.txt] - Size [37B]');
emit_public($server, 'CaptainEpix', '#files', 'End of @Find.');
emit_public($server, 'SecondBot', '#files', 'End of @Find.');

my $timers_before_duplicate = count_find_timers();
emit_public($server, 'AnotherUser', '#files', 'hello everyone');
is count_find_timers(), $timers_before_duplicate,
    'unrelated channel chatter does not extend the quiet window';

# An earlier quiet timer is stale after later response lines and must not end
# the search. The most recent quiet callback completes the collection.
$stale_quiet_timer->[0]->($stale_quiet_timer->[1]);
Irssi::run_command('fscrawl', 'status', $server, undef);
ok(contains_print(qr/find_active=yes/), 'stale quiet timer leaves collection active');
my $latest_quiet_timer = $Irssi::TIMERS[-1];
$latest_quiet_timer->[0]->($latest_quiet_timer->[1]);
Irssi::run_command('fscrawl', 'status', $server, undef);
Irssi::run_command('fscrawl', 'findlist', $server, undef);
ok(contains_print(qr/find_active=no/), 'quiet timer closes the collection');
ok(contains_print(qr/1\s+CaptainEpix\s+!fserve\s+37B\s+\/cross-trigger\.txt/),
    'first trigger appears under a stable result index');
ok(contains_print(qr/2\s+SecondBot\s+!other\s+8B\s+\/second-bot\.txt/),
    'interleaved server response receives its own index');
ok(contains_print(qr/3\s+CaptainEpix\s+!fserve2\s+37B\s+\/cross-trigger\.txt/),
    'same path on a second trigger remains a distinct indexed result');
is find_dcc_commands(), 0, 'processing results still sends no DCC command';
my @persisted_find = read_persisted_catalog();
is scalar(@persisted_find), 3,
    'each @Find result is appended to the durable shared catalog';
ok((scalar grep {
    ($_->{source} // '') eq 'find' &&
    ($_->{discovery_channel} // '') eq '#files' &&
    ($_->{trigger_raw} // '') eq '!fserve2'
} @persisted_find), 'persisted @Find records retain channel and trigger provenance');
my $catalog_output_start = scalar @Irssi::PRINTS;
Irssi::run_command('fscrawl', 'catalog cross-trigger', $server, undef);
my @catalog_output = @Irssi::PRINTS[$catalog_output_start .. $#Irssi::PRINTS];
is scalar(grep { /CaptainEpix/ && /cross-trigger\.txt/ } @catalog_output), 2,
    'durable catalog search finds both trigger-specific result records';

# A result may be fetched only from the same network that supplied it.
my $commands_before_wrong_network_fetch = scalar @{$other_server->{commands}};
Irssi::run_command('fscrawl', 'fetch 1', $other_server, undef);
is scalar @{$other_server->{commands}}, $commands_before_wrong_network_fetch,
    'fetch refuses a result from a different network';

my $preexisting_download_path = File::Spec->catdir($test_root, 'prior-download-setting');
Irssi::settings_set_str('dcc_download_path', $preexisting_download_path);
my $pre_phase6_legacy_path = File::Spec->catfile(
    $test_root, 'fserve-poc', 'downloads', 'FServeLab', 'CaptainEpix',
    '!fserve', 'cross-trigger.txt');
File::Path::make_path((File::Spec->splitpath($pre_phase6_legacy_path))[1]);
open my $pre_phase6_legacy_fh, '>:raw', $pre_phase6_legacy_path or die "create legacy destination: $!";
print {$pre_phase6_legacy_fh} 'pre-Phase-6 user file' or die "write legacy destination: $!";
close $pre_phase6_legacy_fh or die "close legacy destination: $!";
my $first_destination = finish_mock_fetch(
    index => 1, nick => 'CaptainEpix', trigger => '!fserve',
    name => 'cross-trigger.txt', local_name => 'cross-trigger-1.txt', size => '37B',
);
is $first_destination, File::Spec->catfile(
    $test_root, 'fserve-poc', 'downloads', 'FServeLab', 'CaptainEpix',
    '!fserve', 'cross-trigger-1.txt'),
    'pre-existing local destination is preserved using collision-safe suffixing';
open my $legacy_read_fh, '<:raw', $pre_phase6_legacy_path or die "read legacy destination: $!";
is do { local $/; <$legacy_read_fh> }, 'pre-Phase-6 user file',
    'collision-safe publication leaves the pre-existing file byte-for-byte intact';
close $legacy_read_fh;
my $commands_before_repeat = scalar @{$server->{commands}};
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'fetch 1', $server, undef);
is scalar(@{$server->{commands}}), $commands_before_repeat,
    're-fetching an identical provider selection is refused before another trigger';
like join("\n", @Irssi::PRINTS), qr/identical provider history already exists/,
    'identical-selection refusal explains durable duplicate protection';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', 'fetch 3 ctcp', $server, undef);
is scalar(@{$server->{commands}}), $commands_before_repeat,
    'same peer/name through another trigger is refused before remote traffic';
like join("\n", @Irssi::PRINTS), qr/DCC offer tuple is already reserved/,
    'cross-trigger tuple collision explains why the request cannot be distinguished safely';
ok(-f $pre_phase6_legacy_path && -f $first_destination,
    'both the original local file and the one completed publication remain present');
is $Irssi::SETTINGS{dcc_download_path}, $preexisting_download_path,
    'stopping the fetch session restores the user’s original DCC download setting';

# Irssi private-message signals can omit the target argument; a public notice
# addressed to the requested channel carries its target explicitly.
Irssi::run_command('fscrawl', 'find #files private-query', $server, undef);
my $private_timers_before_wrong_target = count_find_timers();
emit_private($server, 'WrongTargetBot', 'OtherNick', '[@Find Results] -=SysReset 2.55=-');
is count_find_timers(), $private_timers_before_wrong_target,
    'private response with an explicit different target is ignored';
emit_private_without_target($server, 'PrivateBot', '[@Find Results] -=SysReset 2.55=-');
emit_private_without_target($server, 'PrivateBot', 'Found [1] file on Trigger:[!private] - Sends:[0/1] - Queues:[0/1]');
emit_private_without_target($server, 'PrivateBot', 'File: [private.txt] - Size [4B]');
emit_notice($server, 'NoticeBot', '#files', '[@Find Results] -=SysReset 2.55=-');
emit_notice($server, 'NoticeBot', '#files', 'Found [1] file on Trigger:[!notice] - Sends:[0/1] - Queues:[0/1]');
emit_notice($server, 'NoticeBot', '#files', 'File: [notice.txt] - Size [5B]');
emit_notice($server, 'NoticeBot', '#files', 'End of @Find.');
my $private_quiet_timer = $Irssi::TIMERS[-1];
$private_quiet_timer->[0]->($private_quiet_timer->[1]);
Irssi::run_command('fscrawl', 'findlist', $server, undef);
ok(contains_print(qr/1\s+PrivateBot\s+!private\s+4B\s+\/private\.txt/),
    'direct private reply is collected');
ok(contains_print(qr/2\s+NoticeBot\s+!notice\s+5B\s+\/notice\.txt/),
    'channel-targeted notice reply is collected');

# A SysReset trigger serialized as a CTCP command is normalized end to end,
# and direct fetch uses that inferred mode without an override.
Irssi::run_command('fscrawl', 'find #files ctcp-query', $server, undef);
emit_private_without_target($server, 'CaptainEpix', '[@Find Results] -=SysReset 2.55=-');
emit_private_without_target($server, 'CaptainEpix', 'Found [1] file on Trigger:[/ctcp CaptainEpix !fserve2] - Sends:[0/1] - Queues:[0/1]');
emit_private_without_target($server, 'CaptainEpix', 'File: [ctcp-only.txt] - Size [7B]');
emit_private_without_target($server, 'CaptainEpix', 'End of @Find.');
my $ctcp_quiet_timer = $Irssi::TIMERS[-1];
$ctcp_quiet_timer->[0]->($ctcp_quiet_timer->[1]);
my $dcc_commands_before_ctcp_selection = find_dcc_commands();
Irssi::run_command('fscrawl', 'fetch 1', $server, undef);
ok((scalar grep { $_ eq 'CTCP CaptainEpix !fserve2' } @{$server->{commands}}),
    'normalized SysReset CTCP trigger is selected automatically for direct fetch');
is find_dcc_commands(), $dcc_commands_before_ctcp_selection,
    'trigger-mode selection alone does not request or download a file';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# No response is bounded by the absolute timeout and reports silence without
# claiming that the server does not support @Find.
my $dcc_commands_before_silent_search = find_dcc_commands();
Irssi::run_command('fscrawl', 'find #files no-match', $server, undef);
my $deadline_timer = $Irssi::TIMERS[-1];
$deadline_timer->[0]->($deadline_timer->[1]);
ok(contains_print(qr/No file results were observed\. Silence can mean no matches/),
    'silent search reports bounded silence without inferring unsupported');
is find_dcc_commands(), $dcc_commands_before_silent_search,
    'silent search sends no additional DCC command';

# A fresh verified parent listing catches a SysReset space-to-underscore
# alias collision before any GET is sent.
Irssi::run_command('fscrawl', 'find #files alias-query', $server, undef);
emit_public($server, 'AliasBot', '#files', '[@Find Results] -=SysReset 2.55=-');
emit_public($server, 'AliasBot', '#files', 'Found [1] file on Trigger:[!alias] - Sends:[0/1] - Queues:[0/1]');
emit_public($server, 'AliasBot', '#files', 'File: [Movies/foo bar.txt] - Size [30B]');
emit_public($server, 'AliasBot', '#files', 'End of @Find.');
my $alias_quiet_timer = $Irssi::TIMERS[-1];
$alias_quiet_timer->[0]->($alias_quiet_timer->[1]);
Irssi::run_command('fscrawl', 'fetch 1', $server, undef);
my $alias_chat = mock_chat('AliasBot');
Irssi::emit('dcc request', $alias_chat, '127.0.0.1');
Irssi::emit('dcc connected', $alias_chat);
emit_chat_line('AliasBot', '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =AliasBot cd Movies',
    'direct fetch navigates to the result parent rather than crawling';
emit_chat_line('AliasBot', '[\\Movies\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =AliasBot dir',
    'parent listing begins only after the expected navigation prompt';
emit_chat_line('AliasBot', '[\\MOVIES\\*.*]');
emit_chat_line('AliasBot', 'foo bar.txt 30B');
emit_chat_line('AliasBot', 'foo_bar.txt 31B');
emit_chat_line('AliasBot', 'End of list.');
ok(!(scalar grep { /MSG =AliasBot get foo bar\.txt$/ } @Irssi::GLOBAL_COMMANDS),
    'ambiguous legacy DCC alias is refused before GET');
ok(contains_print(qr/Refusing GET after verified parent listing/),
    'verified alias-collision refusal is reported');
Irssi::run_command('fscrawl', 'stop', $server, undef);

# A successful nested direct fetch proves that every path component is
# acknowledged before verification and that local path components are safe.
Irssi::run_command('fscrawl', 'find #files nested-query', $server, undef);
emit_public($server, 'CaptainEpix', '#files', '[@Find Results] -=SysReset 2.55=-');
emit_public($server, 'CaptainEpix', '#files', 'Found [1] file on Trigger:[!fserve] - Sends:[0/1] - Queues:[0/1]');
emit_public($server, 'CaptainEpix', '#files', 'File: [Movies/Another Directory/nested-file.txt] - Size [15B]');
emit_public($server, 'CaptainEpix', '#files', 'End of @Find.');
my $nested_quiet_timer = $Irssi::TIMERS[-1];
$nested_quiet_timer->[0]->($nested_quiet_timer->[1]);
Irssi::run_command('fscrawl', 'fetch 1', $server, undef);
my $nested_chat = mock_chat('CaptainEpix');
Irssi::emit('dcc request', $nested_chat, '127.0.0.1');
Irssi::emit('dcc connected', $nested_chat);
emit_chat_line('CaptainEpix', '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =CaptainEpix cd Movies',
    'nested direct fetch starts with its first remote path component';
emit_chat_line('CaptainEpix', '[\\Movies\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =CaptainEpix cd Another Directory',
    'next remote path component is sent only after its parent prompt';
emit_chat_line('CaptainEpix', '[\\Movies\\Another Directory\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =CaptainEpix dir',
    'fresh parent listing starts after the final navigation acknowledgement';
emit_chat_line('CaptainEpix', '[\\MOVIES\\ANOTHER DIRECTORY\\*.*]');
emit_chat_line('CaptainEpix', 'nested-file.txt 15B');
emit_chat_line('CaptainEpix', 'End of list.');
ok((scalar grep { $_ eq 'MSG =CaptainEpix get nested-file.txt' } @Irssi::GLOBAL_COMMANDS),
    'nested target is requested only after the exact parent listing');
my $nested_stage = $Irssi::SETTINGS{dcc_download_path};
my $nested_staged_file = File::Spec->catfile($nested_stage, 'nested-file.txt');
open my $nested_fh, '>', $nested_staged_file or die "create nested staged file: $!";
print {$nested_fh} "nested transfer\n";
close $nested_fh or die "close nested staged file: $!";
my $nested_get = bless {
    type=>'GET', orig_type=>'SEND', nick=>'CaptainEpix', arg=>'nested-file.txt',
    server=>$server, servertag=>'mocknet', size=>15, transfd=>15,
    file=>$nested_staged_file,
    Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $nested_get, '127.0.0.1');
Irssi::emit('dcc get receive', $nested_get);
Irssi::emit('dcc closed', $nested_get);
my $nested_destination = File::Spec->catfile(
    $test_root, 'fserve-poc', 'downloads', 'FServeLab', 'CaptainEpix',
    '!fserve', 'Movies', 'Another Directory', 'nested-file.txt'
);
ok(-f $nested_destination,
    'completed nested transfer preserves remote hierarchy and safe space-containing names');
Irssi::run_command('fscrawl', 'stop', $server, undef);

# A stale @Find entry is harmless only if the target disappears from the fresh
# parent listing and no GET is sent.
Irssi::run_command('fscrawl', 'find #files stale-query', $server, undef);
emit_public($server, 'StaleBot', '#files', '[@Find Results] -=SysReset 2.55=-');
emit_public($server, 'StaleBot', '#files', 'Found [1] file on Trigger:[!stale] - Sends:[0/1] - Queues:[0/1]');
emit_public($server, 'StaleBot', '#files', 'File: [Movies/stale.txt] - Size [9B]');
emit_public($server, 'StaleBot', '#files', 'End of @Find.');
my $stale_result_quiet_timer = $Irssi::TIMERS[-1];
$stale_result_quiet_timer->[0]->($stale_result_quiet_timer->[1]);
Irssi::run_command('fscrawl', 'fetch 1', $server, undef);
my $stale_chat = mock_chat('StaleBot');
Irssi::emit('dcc request', $stale_chat, '127.0.0.1');
Irssi::emit('dcc connected', $stale_chat);
emit_chat_line('StaleBot', '[\\]');
emit_chat_line('StaleBot', '[\\Movies\\]');
emit_chat_line('StaleBot', '[\\MOVIES\\*.*]');
emit_chat_line('StaleBot', 'normal-file.txt 12B');
emit_chat_line('StaleBot', 'End of list.');
ok(!(scalar grep { /MSG =StaleBot get stale\.txt$/ } @Irssi::GLOBAL_COMMANDS),
    'stale @Find target missing from verified parent is never requested');
ok(contains_print(qr/Refusing GET: target file was not present/),
    'stale-result refusal is reported');
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Keep the active script's original crawl -> list -> get path covered too;
# the frozen v0.1.5 regression alone cannot catch regressions in v0.2.0-dev.
my $legacy_trigger_count = scalar @{$server->{commands}};
Irssi::run_command('fscrawl', 'start LegacyBot msg #files !legacy', $server, undef);
is $server->{commands}[$legacy_trigger_count], 'msg #files !legacy',
    'active crawl start still sends the user-specified trigger command';
my $legacy_chat = mock_chat('LegacyBot');
Irssi::emit('dcc request', $legacy_chat, '127.0.0.1');
Irssi::emit('dcc connected', $legacy_chat);
emit_chat_line('LegacyBot', '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =LegacyBot dir',
    'active crawler still requests a root listing after its prompt';
emit_chat_line('LegacyBot', '[\\*.*]');
emit_chat_line('LegacyBot', 'legacy-root.txt 6B');
emit_chat_line('LegacyBot', 'End of list.');
ok(contains_print(qr/Crawl complete: 0 directories, 1 files\./),
    'active crawler still builds a catalog from the root listing');
Irssi::run_command('fscrawl', 'get 1', $server, undef);
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =LegacyBot dir',
    'active catalog retrieval still verifies the parent before GET';
emit_chat_line('LegacyBot', '[\\*.*]');
emit_chat_line('LegacyBot', 'legacy-root.txt 6B');
emit_chat_line('LegacyBot', 'End of list.');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =LegacyBot get legacy-root.txt',
    'active catalog retrieval sends GET after target verification';
my $legacy_stage = $Irssi::SETTINGS{dcc_download_path};
my $legacy_staged_file = File::Spec->catfile($legacy_stage, 'legacy-root.txt');
open my $legacy_fh, '>', $legacy_staged_file or die "create legacy staged file: $!";
print {$legacy_fh} 'legacy';
close $legacy_fh or die "close legacy staged file: $!";
my $legacy_get = bless {
    type=>'GET', orig_type=>'SEND', nick=>'LegacyBot', arg=>'legacy-root.txt',
    server=>$server, servertag=>'mocknet', size=>6, transfd=>6,
    file=>$legacy_staged_file,
    Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $legacy_get, '127.0.0.1');
ok((scalar grep { $_ eq 'DCC GET LegacyBot "legacy-root.txt"' } @{$server->{commands}}),
    'active crawler accepts only the matching post-request DCC SEND');
Irssi::emit('dcc get receive', $legacy_get);
Irssi::emit('dcc closed', $legacy_get);
my $legacy_destination = File::Spec->catfile(
    $test_root, 'fserve-poc', 'downloads', 'FServeLab', 'LegacyBot',
    '!legacy', 'legacy-root.txt'
);
ok(-f $legacy_destination,
    'active crawler retrieval also finalizes into the new collision-safe layout');
Irssi::run_command('fscrawl', 'stop', $server, undef);
is $Irssi::SETTINGS{dcc_download_path}, $preexisting_download_path,
    'stopping the active crawler restores the original DCC download setting';

# Crawl and @Find sightings of the same trigger-specific path coalesce in the
# durable catalog while retaining both provenance sources.
my @observations_before_merge = read_persisted_catalog();
my $merge_trigger_count = scalar @{$server->{commands}};
Irssi::run_command('fscrawl', 'start CaptainEpix msg #files !fserve', $server, undef);
is $server->{commands}[$merge_trigger_count], 'msg #files !fserve',
    'shared-catalog crawl starts with the selected trigger';
my $merge_chat = mock_chat('CaptainEpix');
Irssi::emit('dcc request', $merge_chat, '127.0.0.1');
Irssi::emit('dcc connected', $merge_chat);
emit_chat_line('CaptainEpix', '[\\]');
emit_chat_line('CaptainEpix', '[\\*.*]');
emit_chat_line('CaptainEpix', 'cross-trigger.txt 37B');
emit_chat_line('CaptainEpix', 'End of list.');
Irssi::run_command('fscrawl', 'stop', $server, undef);
my $merged_output_start = scalar @Irssi::PRINTS;
Irssi::run_command('fscrawl', 'catalog cross-trigger.txt', $server, undef);
my @merged_output = @Irssi::PRINTS[$merged_output_start .. $#Irssi::PRINTS];
ok((scalar grep {
    /CaptainEpix\s+!fserve\s+find,crawl\s+.*cross-trigger\.txt/
} @merged_output), 'shared catalog merges matching crawl and @Find provenance');
is scalar(read_persisted_catalog()), scalar(@observations_before_merge) + 1,
    'durable JSONL retains the crawl observation for replay';

# Candidate ranking is local-only: it consumes the completed @Find results and
# never sends an additional IRC message or DCC command.
Irssi::run_command('fscrawl', 'find #files manifest-query', $server, undef);
emit_public($server, 'TNW', '#files', '[@Find Results] -=SysReset 2.55=-');
emit_public($server, 'TNW', '#files', 'Found [1] file on Trigger:[!TNW] - Sends:[0/1] - Queues:[0/1]');
emit_public($server, 'TNW', '#files', 'File: [TicTocTome-FullFiles-List.txt] - Size [450M]');
emit_public($server, 'TNW', '#files', 'End of @Find.');
my $commands_before_candidate_scan = scalar @{$server->{commands}};
my $dcc_before_candidate_scan = find_dcc_commands();
my $candidate_output_start = scalar @Irssi::PRINTS;
Irssi::run_command('fscrawl', 'manifest-candidates', $server, undef);
my @candidate_output = @Irssi::PRINTS[$candidate_output_start .. $#Irssi::PRINTS];
like join("\n", @candidate_output), qr/1\s+score=120\s+TNW\s+!TNW\s+\/TicTocTome-FullFiles-List\.txt/,
    'manifest-candidates identifies and indexes a likely full-list result';
is scalar(@{$server->{commands}}), $commands_before_candidate_scan,
    'manifest candidate ranking sends no IRC command';
is find_dcc_commands(), $dcc_before_candidate_scan,
    'manifest candidate ranking sends no DCC command';

Irssi::Script::dccatlas::UNLOAD();

done_testing;
