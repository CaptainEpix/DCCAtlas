#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
no warnings 'redefine';
use FindBin;
use File::Temp qw(tempdir);
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

# Mock transport and disposable local state; no sockets or production state.
my $root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $root;
require "$FindBin::Bin/../../engine/dccatlas.pl";
my $server = MockServer->new();
$server->{nick} = 'LocalNick';
sub command { Irssi::run_command('fscrawl', $_[0], $server, undef); }
sub state {
    my ($id) = @_;
    @Irssi::PRINTS = ();
    command("job-show $id");
    my ($state) = join("\n", @Irssi::PRINTS) =~ /job=\Q$id\E provider=crawl state=(\S+)/;
    return $state;
}

command('start CrawlReview msg #files !crawl');
my $chat = bless {
    type => 'CHAT', nick => 'CrawlReview', id => 'CrawlReview',
    server => $server, servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $chat);
Irssi::emit('dcc connected', $chat);
Irssi::emit('dcc chat message', $chat, $_)
    for ('[\\]', '[\\*.*]', 'Review.txt 4B', 'End of list.');
command('list');
my ($token) = join("\n", @Irssi::PRINTS) =~ /selection=(crawl-\d+-\d+)/;
die 'missing crawl token' unless $token;
command("queue-add crawl $token");
my ($id) = join("\n", @Irssi::PRINTS) =~ /Added held job (job-[a-f0-9]{32})/;
die 'missing queued crawl job' unless $id;
command("queue-run $id");
is state($id), 'held', 'crawl stays held while its initial parent listing is pending';
command('stop');
is state($id), 'stale', 'stop retires crawl preflight during its initial parent listing';
command("queue-run $id");
like join("\n", @Irssi::PRINTS), qr/Queue run refused/,
    'initially stopped crawl cannot be resumed';
is scalar(grep { /^MSG =CrawlReview get / } @Irssi::GLOBAL_COMMANDS), 0,
    'stopping during the initial listing sends no GET';

command('start CrawlReview2 msg #files !crawl');
my $chat2 = bless {
    type => 'CHAT', nick => 'CrawlReview2', id => 'CrawlReview2',
    server => $server, servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $chat2);
Irssi::emit('dcc connected', $chat2);
Irssi::emit('dcc chat message', $chat2, $_)
    for ('[\\]', '[\\*.*]', 'Review2.txt 4B', 'End of list.');
command('list');
my ($token2) = join("\n", @Irssi::PRINTS) =~ /selection=(crawl-\d+-\d+)/;
die 'missing second crawl token' unless $token2;
command("queue-add crawl $token2");
my ($id2) = join("\n", @Irssi::PRINTS) =~ /Added held job (job-[a-f0-9]{32})/;
die 'missing second queued crawl job' unless $id2;
$chat = $chat2;
$id = $id2;
my $dirs_before_resume_case = scalar grep { /^MSG =CrawlReview2 dir$/ } @Irssi::GLOBAL_COMMANDS;
command("queue-run $id");
is state($id), 'held', 'second crawl waits at its initial live-parent listing';
command('queue-pause');
Irssi::emit('dcc chat message', $chat, $_)
    for ('[\\*.*]', 'Review2.txt 4B', 'End of list.');
is scalar(grep { /^MSG =CrawlReview2 get / } @Irssi::GLOBAL_COMMANDS), 0,
    'late listing cannot send GET after pause';
command("queue-run $id");
is scalar(grep { /^MSG =CrawlReview2 dir$/ } @Irssi::GLOBAL_COMMANDS), $dirs_before_resume_case + 2,
    'resume requests a fresh parent listing on the original CHAT';
command('stop');
is state($id), 'stale', 'stop retires crawl preflight during resumed parent verification';
command("queue-run $id");
unlike join("\n", @Irssi::PRINTS), qr/A finite queue run already exists/,
    'stopped preflight does not leave a phantom active batch';
like join("\n", @Irssi::PRINTS), qr/Queue run refused/,
    'the retired crawl job cannot be resumed';
is scalar(grep { /^MSG =CrawlReview2 get / } @Irssi::GLOBAL_COMMANDS), 0,
    'stop and rerun do not send GET';

sub prepare_find_selection {
    my ($query, $peer, $name, $query_id) = @_;
    command("find #files $query");
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, '[@Find Results] -=SysReset 2.55=-',
        $peer, 'bot\@localhost', '#files');
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, "Found [1] file on Trigger:[!$peer] - Sends:[0/1] - Queues:[0/1]",
        $peer, 'bot\@localhost', '#files');
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, "File: [$name] - Size [4B]",
        $peer, 'bot\@localhost', '#files');
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, 'End of @Find.', $peer, 'bot\@localhost', '#files');
    my $quiet_timer = $Irssi::TIMERS[-1];
    ok $quiet_timer && Irssi::fire_timer($quiet_timer->[2]),
        "$peer Find selection is ready for the two-job stop case";
    return "find-$query_id-1";
}

my $next_find_token = prepare_find_selection('pending-stop', 'PendingNext', 'pending.txt', 1);
command('start CrawlPending msg #files !crawl');
my $pending_chat = bless {
    type => 'CHAT', nick => 'CrawlPending', id => 'CrawlPending',
    server => $server, servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $pending_chat);
Irssi::emit('dcc connected', $pending_chat);
Irssi::emit('dcc chat message', $pending_chat, $_)
    for ('[\\]', '[\\*.*]', 'Pending.txt 4B', 'End of list.');
command('list');
my ($pending_token) = join("\n", @Irssi::PRINTS) =~ /selection=(crawl-\d+-\d+)/;
die 'missing pending-stop crawl token' unless $pending_token;
@Irssi::PRINTS = ();
command("queue-add crawl $pending_token");
my ($pending_crawl) = join("\n", @Irssi::PRINTS) =~
    /Added held job (job-[a-f0-9]{32})/;
die 'missing pending-stop crawl job' unless $pending_crawl;
@Irssi::PRINTS = ();
command("queue-add find $next_find_token channel");
my ($next_find) = join("\n", @Irssi::PRINTS) =~
    /Added held job (job-[a-f0-9]{32})/;
die 'missing pending-stop Find job' unless $next_find;
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
command("queue-run $pending_crawl $next_find");
is state($pending_crawl), 'held',
    'two-job crawl is held while the verified-parent command waits to send';
is Irssi::Script::dccatlas::outbound_scheduler()->pending_count, 1,
    'the crawl parent listing is pending in the outbound scheduler';
command('stop');
is state($pending_crawl), 'stale',
    'stop durably retires the crawl when cancelling its pending listing';
Irssi::test_run_outbound_timers();
is scalar(grep { /^MSG #files !PendingNext$/ } @{$server->{commands}}), 0,
    'cancellation callback cannot dispatch the next job after stop';
is scalar(grep { /^MSG =CrawlPending get / } @Irssi::GLOBAL_COMMANDS), 0,
    'stopping the pending crawl sends no GET';
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 1;
command("queue-cancel $next_find");
command("queue-run $pending_crawl $next_find");

my $paused_find_token = prepare_find_selection('paused-stop', 'PausedNext', 'paused.txt', 2);
command('start CrawlPaused msg #files !crawl');
my $paused_chat = bless {
    type => 'CHAT', nick => 'CrawlPaused', id => 'CrawlPaused',
    server => $server, servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $paused_chat);
Irssi::emit('dcc connected', $paused_chat);
Irssi::emit('dcc chat message', $paused_chat, $_)
    for ('[\\]', '[\\*.*]', 'Paused.txt 4B', 'End of list.');
command('list');
my ($paused_token) = join("\n", @Irssi::PRINTS) =~ /selection=(crawl-\d+-\d+)/;
die 'missing paused-stop crawl token' unless $paused_token;
@Irssi::PRINTS = ();
command("queue-add crawl $paused_token");
my ($paused_crawl) = join("\n", @Irssi::PRINTS) =~
    /Added held job (job-[a-f0-9]{32})/;
die 'missing paused-stop crawl job' unless $paused_crawl;
@Irssi::PRINTS = ();
command("queue-add find $paused_find_token channel");
my ($paused_find) = join("\n", @Irssi::PRINTS) =~
    /Added held job (job-[a-f0-9]{32})/;
die 'missing paused-stop Find job' unless $paused_find;
command("queue-run $paused_crawl $paused_find");
is state($paused_crawl), 'held', 'second crawl waits for parent verification';
command('queue-pause');
is state($paused_crawl), 'held', 'pause checkpoints the crawl before GET';
command('stop');
is state($paused_crawl), 'stale',
    'stop retires a paused crawl whose active CHAT is being discarded';
is scalar(grep { /^MSG #files !PausedNext$/ } @{$server->{commands}}), 0,
    'stopping the saved paused context does not start its next job';
is scalar(grep { /^MSG =CrawlPaused get / } @Irssi::GLOBAL_COMMANDS), 0,
    'stopping the saved paused context sends no GET';
@Irssi::PRINTS = ();
command("queue-run $paused_crawl $paused_find");
is scalar(grep { /^MSG #files !PausedNext$/ } @{$server->{commands}}), 1,
    'explicit resume skips the retired paused crawl and advances to the next job';
is scalar(grep { /^MSG =CrawlPaused get / } @Irssi::GLOBAL_COMMANDS), 0,
    'resuming the batch does not send the stopped crawl GET';
command("queue-cancel $paused_find");

command('start CrawlReview3 msg #files !crawl');
my $chat3 = bless {
    type => 'CHAT', nick => 'CrawlReview3', id => 'CrawlReview3',
    server => $server, servertag => 'mocknet', Irssi::new_dcc_identity(),
}, 'MockDcc';
Irssi::emit('dcc request', $chat3);
Irssi::emit('dcc connected', $chat3);
Irssi::emit('dcc chat message', $chat3, $_)
    for ('[\\]', '[\\*.*]', 'Review3.txt 4B', 'End of list.');
command('list');
my ($token3) = join("\n", @Irssi::PRINTS) =~ /selection=(crawl-\d+-\d+)/;
die 'missing third crawl token' unless $token3;
command("queue-add crawl $token3");
my ($id3) = join("\n", @Irssi::PRINTS) =~ /Added held job (job-[a-f0-9]{32})/;
die 'missing third queued crawl job' unless $id3;
command("queue-run $id3");
is state($id3), 'held', 'journal failure fixture is at parent verification';
{
    local *Irssi::Script::dccatlas::job_transition = sub { return 0; };
    command('stop');
}
my $stop_failure_output = join("\n", @Irssi::PRINTS);
is state($id3), 'held', 'journal failure preserves the job for inspection';
like $stop_failure_output, qr/The job batch paused because stopped crawl preflight/,
    'journal failure pauses the batch and reports that retirement was not recorded';
command("queue-run $id3");
like join("\n", @Irssi::PRINTS), qr/Queued crawl job requires its original active DCC CHAT session/,
    'journal failure clears the phantom wait and fails closed without the original CHAT';
is scalar(grep { /^MSG =CrawlReview3 get / } @Irssi::GLOBAL_COMMANDS), 0,
    'journal failure and later resume send no GET';

done_testing();
