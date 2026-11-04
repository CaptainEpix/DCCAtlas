#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';

use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
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

sub mock_chat {
    my ($nick) = @_;
    return bless {
        type=>'CHAT', nick=>$nick, id=>$nick, server=>$server,
        servertag=>'mocknet', Irssi::new_dcc_identity(),
    }, 'MockDcc';
}

sub mock_get {
    my (%args) = @_;
    return bless {
        type=>'GET', orig_type=>'SEND', nick=>$args{nick}, arg=>$args{name},
        server=>$server, servertag=>'mocknet', size=>$args{size},
        transfd=>$args{transfd} // 0, file=>$args{file},
        Irssi::new_dcc_identity(),
    }, 'MockDcc';
}

sub start_crawl {
    my ($nick) = @_;
    Irssi::Script::dccatlas::start_fserve_session(
        $nick, $server, "MSG #files !$nick", undef
    );
    my $chat = mock_chat($nick);
    Irssi::emit('dcc request', $chat, '127.0.0.1');
    Irssi::emit('dcc connected', $chat);
    return $chat;
}

sub start_fetch {
    my ($nick, $path, $leave_connecting) = @_;
    my ($name) = $path =~ m{([^/]+)$};
    my $parent = $path;
    $parent =~ s{/?\Q$name\E$}{};
    $parent = '/' unless length $parent;
    my $record = {
        type=>'file', path=>$path, name=>$name, parent=>$parent,
        trigger_raw=>"!$nick", trigger_mode=>'channel_text',
    };
    Irssi::Script::dccatlas::start_fserve_session(
        $nick, $server, "MSG #files !$nick", $record
    );
    my $chat = mock_chat($nick);
    Irssi::emit('dcc request', $chat, '127.0.0.1');
    Irssi::emit('dcc connected', $chat) unless $leave_connecting;
    return $chat;
}

sub chat_line {
    my ($chat, $line) = @_;
    Irssi::emit('dcc chat message', $chat, $line);
}

sub timer_handles { return Irssi::timer_handles(); }
sub last_timer_handle { my @handles = timer_handles(); return $handles[-1]; }
sub global_matches { my ($pattern) = @_; return scalar grep { /$pattern/ } @Irssi::GLOBAL_COMMANDS; }
sub print_matches { my ($pattern) = @_; return scalar grep { /$pattern/ } @Irssi::PRINTS; }
sub run_status { Irssi::run_command('fscrawl', 'status', $server, undef); }
sub current_job_status {
    @Irssi::PRINTS = ();
    run_status();
    my ($job_id, $state) = join("\n", @Irssi::PRINTS) =~
        /active_job=(job-[a-f0-9]{32}) state=([a-z_]+)/;
    return ($job_id, $state);
}
sub job_state {
    my ($job_id) = @_;
    @Irssi::PRINTS = ();
    Irssi::run_command('fscrawl', "job-show $job_id", $server, undef);
    my ($state) = join("\n", @Irssi::PRINTS) =~ /\bstate=([a-z_]+)/;
    return $state;
}
sub latest_job_snapshot {
    my ($job_id) = @_;
    require JSON::PP;
    my $journal = File::Spec->catfile(
        $test_root, 'fserve-poc', 'phase6', 'requests.jsonl');
    open my $fh, '<', $journal or die "open Phase 6 test journal: $!";
    my $latest;
    while (my $line = <$fh>) {
        my $record = eval { JSON::PP->new->decode($line) };
        next unless ref($record) eq 'HASH' &&
            ($record->{event} // '') =~ /\Ajob_(?:created|transition)\z/;
        my $data = $record->{data};
        next unless ref($data) eq 'HASH';
        my $job = $data->{job};
        $latest = $job if ref($job) eq 'HASH' &&
            ($job->{id} // '') eq $job_id;
    }
    close $fh or die "close Phase 6 test journal: $!";
    die "Phase 6 test journal has no snapshot for $job_id" unless $latest;
    return $latest;
}
sub trigger_count {
    my ($nick) = @_;
    return scalar grep { $_ eq "MSG #files !$nick" } @{$server->{commands}};
}
sub timers_due_in_ms_range {
    my ($minimum_ms, $maximum_ms) = @_;
    my $now = $Irssi::MOCK_MONOTONIC;
    return sort {
        Irssi::timer_record($a)->[6] <=> Irssi::timer_record($b)->[6]
    } grep {
        my $timer = Irssi::timer_record($_);
        $timer && !$timer->[3] && !$timer->[4] && defined($timer->[6]) &&
            ($timer->[6] - $now) * 1000 >= $minimum_ms &&
            ($timer->[6] - $now) * 1000 <= $maximum_ms
    } Irssi::timer_handles();
}
sub timer_count_due_in_ms_range {
    my @handles = timers_due_in_ms_range(@_);
    return scalar @handles;
}
sub fire_next_outbound_timer {
    my @handles = sort {
        Irssi::timer_record($a)->[6] <=> Irssi::timer_record($b)->[6]
    } grep { $Irssi::OUTBOUND_TIMERS{$_} } Irssi::timer_handles();
    return @handles ? Irssi::fire_timer($handles[0]) : 0;
}

sub start_verified_root_get {
    my ($nick, $name, $size) = @_;
    my $chat = start_fetch($nick, "/$name");
    chat_line($chat, '[\\]');
    chat_line($chat, '[\\*.*]');
    chat_line($chat, "$name ${size}B");
    chat_line($chat, 'End of list.');
    return $chat;
}

sub stage_and_complete {
    my ($nick, $chat, $get, $name, $contents, $size) = @_;
    my $stage = $Irssi::SETTINGS{dcc_download_path};
    like $stage, qr{[\\/]\.incoming[\\/]}, "$nick uses a request-specific staging directory";
    $get->{file} = File::Spec->catfile($stage, $name);
    Irssi::emit('dcc request', $get, '127.0.0.1');
    ok((scalar grep { /^DCC GET \Q$nick\E / } @{$server->{commands}}),
        "$nick accepts the correlated expected DCC GET");
    Irssi::emit('dcc get receive', $get);
    is $Irssi::SETTINGS{dcc_download_path},
        File::Spec->catdir($test_root, 'fserve-poc', 'downloads'),
        "$nick restores the global path after Irssi selects the staging file";
    open my $fh, '>', $get->{file} or die "create staged file $get->{file}: $!";
    print {$fh} $contents or die "write staged file $get->{file}: $!";
    close $fh or die "close staged file $get->{file}: $!";
    $get->{transfd} = $size;
    Irssi::emit('dcc closed', $get);
    my $destination = File::Spec->catfile(
        $test_root, 'fserve-poc', 'downloads', 'FServeLab', $nick,
        "!$nick", $name,
    );
    ok -f $destination, "${nick}'s accepted transfer finalizes under its original session";
    return $destination;
}

sub start_detached_queue_wait {
    my ($nick, $name, $size) = @_;
    my $chat = start_verified_root_get($nick, $name, $size);
    @Irssi::PRINTS = ();
    run_status();
    my ($job_id) = join("\n", @Irssi::PRINTS) =~
        /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
    die "queued-wait fixture has no dispatched job for $nick" unless $job_id;
    chat_line($chat, "[fserve-phase6-test] QUEUED job=$job_id position=1");
    Irssi::emit('dcc closed', $chat);
    return ($chat, $job_id);
}

sub assert_replacement_chat_has_no_authority {
    my ($nick, $name, $label) = @_;
    my $accepted_before = scalar grep { /^DCC CHAT \Q$nick\E\z/ } @{$server->{commands}};
    my $navigation_before = global_matches(qr/^MSG =\Q$nick\E (?:dir|cd|get)(?:\s|$)/);
    my $replacement = mock_chat($nick);
    Irssi::emit('dcc request', $replacement, '127.0.0.1');
    is scalar(grep { /^DCC CHAT \Q$nick\E\z/ } @{$server->{commands}}),
        $accepted_before, "$label replacement CHAT request is not accepted";
    ok $replacement->{destroyed}, "$label replacement CHAT request is closed";
    Irssi::emit('dcc connected', $replacement);
    chat_line($replacement, '[\\]');
    chat_line($replacement, '[\\*.*]');
    chat_line($replacement, "$name 4B");
    chat_line($replacement, 'End of list.');
    is scalar(grep { /^DCC CHAT \Q$nick\E\z/ } @{$server->{commands}}),
        $accepted_before, "$label connected signal cannot bind the refused CHAT";
    is global_matches(qr/^MSG =\Q$nick\E (?:dir|cd|get)(?:\s|$)/),
        $navigation_before, "$label prompts cannot send FServe application traffic";
}

# Both sessions have navigation sequence 1. A callback retained from the old
# session is fired after cancellation and cannot fail the replacement.
my $nav_old_chat = start_fetch('NavOld', '/subdir/old.txt');
chat_line($nav_old_chat, '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =NavOld cd subdir',
    'first direct fetch begins acknowledged navigation';
my $old_navigation_timer = last_timer_handle();
my $nav_new_chat = start_fetch('NavNew', '/different/new.txt');
chat_line($nav_new_chat, '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =NavNew cd different',
    'replacement session starts its own first navigation operation';
my $new_navigation_timer = last_timer_handle();
ok $old_navigation_timer != $new_navigation_timer,
    'replacement navigation has a distinct timer handle';
ok Irssi::fire_timer($old_navigation_timer, 1),
    'a captured callback can be invoked after cancellation';
run_status();
ok(print_matches(qr/active=yes phase=navigating nick=NavNew/),
    'stale navigation timeout cannot fail the replacement session');
Irssi::run_command('fscrawl', 'stop', $server, undef);

# A same-peer CHAT with a different Irssi chat ID is never authorized, including
# a connected event arriving before the actual requested CHAT connects.
my $identity_chat = start_fetch('IdentityBot', '/subdir/file.txt', 1);
run_status();
ok(print_matches(qr/active=yes phase=connecting_chat nick=IdentityBot chat=no/),
    'the requested CHAT remains pending before its connected event');
my %wrong_chat_record = %$identity_chat;
$wrong_chat_record{id} = 'old-chat';
my $wrong_chat = bless \%wrong_chat_record, 'MockDcc';
Irssi::emit('dcc connected', $wrong_chat);
chat_line($wrong_chat, '[\\]');
Irssi::emit('dcc closed', $wrong_chat);
run_status();
ok(print_matches(qr/active=yes phase=connecting_chat nick=IdentityBot chat=no/),
    'wrong-ID connected, message, and close events leave the requested CHAT pending');
Irssi::emit('dcc connected', $identity_chat);
run_status();
ok(print_matches(qr/active=yes phase=await_prompt nick=IdentityBot chat=IdentityBot/),
    'the correctly identified CHAT can connect after a mismatched event');
chat_line($identity_chat, '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =IdentityBot cd subdir',
    'the correctly identified CHAT can start navigation';
my $before_wrong_prompt = scalar @Irssi::GLOBAL_COMMANDS;
chat_line($wrong_chat, '[\\subdir\\]');
is scalar(@Irssi::GLOBAL_COMMANDS), $before_wrong_prompt,
    'wrong-ID CHAT message cannot acknowledge navigation or send another command';
run_status();
ok(print_matches(qr/phase=navigating nick=IdentityBot chat=IdentityBot/),
    'wrong-ID prompt leaves the legitimate navigation pending');
my $identity_nav_timer = last_timer_handle();
Irssi::emit('dcc closed', $identity_chat);
ok Irssi::fire_timer($identity_nav_timer, 1),
    'owned CHAT closure cancels a captured navigation callback';
my $commands_after_close = scalar @Irssi::GLOBAL_COMMANDS;
chat_line($identity_chat, '[\\subdir\\]');
is scalar(@Irssi::GLOBAL_COMMANDS), $commands_after_close,
    'late lines after owned CHAT closure cannot advance navigation';
run_status();
ok(print_matches(qr/active=no phase=disconnected nick=IdentityBot/),
    'owned CHAT closure invalidates the session instead of waiting for a timeout');

# Closure during parent verification prevents late listing rows from issuing GET.
my $verify_chat = start_fetch('VerifyClose', '/Movies/target.txt');
chat_line($verify_chat, '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =VerifyClose cd Movies',
    'parent-verification case starts at the expected remote directory';
chat_line($verify_chat, '[\\Movies\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =VerifyClose dir',
    'parent verification starts only after navigation acknowledgement';
my %wrong_verify_record = %$verify_chat;
$wrong_verify_record{id} = 'unrelated-chat';
my $wrong_verify_chat = bless \%wrong_verify_record, 'MockDcc';
my $commands_before_wrong_listing = scalar @Irssi::GLOBAL_COMMANDS;
chat_line($wrong_verify_chat, '[\\Movies\\*.*]');
chat_line($wrong_verify_chat, 'target.txt 4B');
chat_line($wrong_verify_chat, 'End of list.');
is scalar(@Irssi::GLOBAL_COMMANDS), $commands_before_wrong_listing,
    'wrong-ID listing lines cannot advance parent verification';
ok(!(global_matches(qr/MSG =VerifyClose get target\.txt/)),
    'wrong-ID CHAT message cannot verify a file or issue GET');
Irssi::emit('dcc closed', $verify_chat);
my $commands_at_verify_close = scalar @Irssi::GLOBAL_COMMANDS;
chat_line($verify_chat, '[\\MOVIES\\*.*]');
chat_line($verify_chat, 'target.txt 4B');
chat_line($verify_chat, 'End of list.');
is scalar(@Irssi::GLOBAL_COMMANDS), $commands_at_verify_close,
    'late parent listing after CHAT closure cannot issue GET';
ok(!(global_matches(qr/MSG =VerifyClose get target\.txt/)),
    'CHAT closure during verification leaves the target unrequested');
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Initial-prompt and pagination continuations are canceled and generation
# guarded; the current callbacks still perform their expected work.
my $initial_old_chat = start_crawl('InitialOld');
my $old_initial_timer = last_timer_handle();
Irssi::run_command('fscrawl', 'stop', $server, undef);
my $initial_new_chat = start_crawl('InitialNew');
my $new_initial_timer = last_timer_handle();
ok Irssi::fire_timer($old_initial_timer, 1),
    'old initial-prompt callback remains safely invocable after restart';
ok(!(global_matches(qr/MSG =InitialNew dir/)),
    'old initial-prompt callback cannot send into the replacement CHAT');
ok Irssi::fire_timer($new_initial_timer), 'current initial-prompt fallback still runs';
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =InitialNew dir',
    'current initial-prompt fallback begins the root listing';
chat_line($initial_new_chat, '[C for more, S to stop]');
my $old_pagination_timer = last_timer_handle();
Irssi::run_command('fscrawl', 'stop', $server, undef);
my $pagination_new_chat = start_crawl('PaginationNew');
chat_line($pagination_new_chat, '[C for more, S to stop]');
my $new_pagination_timer = last_timer_handle();
my $dir_count_before_old_pagination = global_matches(qr/MSG =PaginationNew dir/);
ok Irssi::fire_timer($old_pagination_timer, 1),
    'old pagination continuation can be fired after restart';
is global_matches(qr/MSG =PaginationNew dir/), $dir_count_before_old_pagination,
    'old pagination continuation cannot start a listing in the new session';
ok Irssi::fire_timer($new_pagination_timer), 'current pagination continuation still runs';
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =PaginationNew dir',
    'current pagination sequence sends the expected listing command';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Rejected matching GET before the verified command closes synchronously here.
# Its later close signal is inert; the legitimate GET still binds and completes.
my $prior_download_path = File::Spec->catdir($test_root, 'prior-download-setting');
Irssi::settings_set_str('dcc_download_path', $prior_download_path);
my $sync_chat = start_fetch('SyncReject', '/sync.txt');
my $sync_offer = mock_get(nick=>'SyncReject', name=>'sync.txt', size=>5);
my $sync_closed_during_command = 0;
$server->{on_command} = sub {
    my ($command) = @_;
    if ($command =~ /^DCC CLOSE GET /) {
        Irssi::emit('dcc closed', $sync_offer);
        $sync_closed_during_command++;
    }
};
Irssi::emit('dcc request', $sync_offer, '127.0.0.1');
$server->{on_command} = undef;
is $sync_closed_during_command, 1,
    'premature matching GET close can be delivered reentrantly during rejection';
chat_line($sync_chat, '[\\]');
chat_line($sync_chat, '[\\*.*]');
chat_line($sync_chat, 'sync.txt 5B');
chat_line($sync_chat, 'End of list.');
ok(global_matches(qr/MSG =SyncReject get sync\.txt/),
    'synchronous rejected close cannot clear the pending verified request');
run_status();
my ($sync_job_id) = join("\n", @Irssi::PRINTS) =~ /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
ok $sync_job_id, 'durable job is visible in status after its one content dispatch';
chat_line($sync_chat, "[fserve-phase6-test] QUEUED job=$sync_job_id position=2");
run_status();
ok print_matches(qr/active_job=\Q$sync_job_id\E state=remote_queued/),
    'only a correlated synthetic queue acknowledgement changes the job to remote_queued';
my $remote_queue_timer = last_timer_handle();
chat_line($sync_chat, "[fserve-phase6-test] POSITION job=$sync_job_id position=1");
is last_timer_handle(), $remote_queue_timer,
    'queue-position updates do not reset the absolute queue deadline';
my $sync_get = mock_get(nick=>'SyncReject', name=>'sync.txt', size=>5);
my $sync_destination = stage_and_complete(
    'SyncReject', $sync_chat, $sync_get, 'sync.txt', 'sync', 5
);
ok Irssi::timer_record($remote_queue_timer)->[3],
    'accepting the exact queued offer cancels its wait timer';
my $completed_count = print_matches(qr/Download completed: sync\.txt/);
Irssi::emit('dcc closed', $sync_get);
is print_matches(qr/Download completed: sync\.txt/), $completed_count,
    'duplicate close delivery cannot finalize a bound transfer twice';
Irssi::run_command('fscrawl', 'stop', $server, undef);
is $Irssi::SETTINGS{dcc_download_path}, $prior_download_path,
    'stopping restores the user download path after synchronous reject sequence';

# Closing CHAT before a queued offer is accepted must retire the local wait.
my $queue_loss_chat = start_verified_root_get('QueueLossBot', 'queue-loss.txt', 4);
@Irssi::PRINTS = ();
run_status();
my ($queue_loss_job) = join("\n", @Irssi::PRINTS) =~
    /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
ok $queue_loss_job, 'queue-loss fixture has one dispatched durable job';
chat_line($queue_loss_chat,
    "[fserve-phase6-test] QUEUED job=$queue_loss_job position=1");
my $queue_loss_timer = last_timer_handle();
Irssi::emit('dcc closed', $queue_loss_chat);
my $queue_loss_timer_record = Irssi::timer_record($queue_loss_timer);
ok $queue_loss_timer_record && $queue_loss_timer_record->[3],
    'CHAT loss cancels the job-owned remote queue deadline';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $queue_loss_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=remote_queued/,
    'confirmed queued offer remains authorized after CHAT loss without retrying';
Irssi::run_command('fscrawl', 'stop', $server, undef);
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $queue_loss_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=cancelled/,
    'local stop cancels the bounded wait without changing remote queue state';

# Closing CHAT after a correlated queue acknowledgement revokes navigation
# authority for the rest of that session, including after transfer resolution.
my ($auth_wait_chat, $auth_wait_job) = start_detached_queue_wait(
    'QueueAuthComplete', 'auth-complete.bin', 4);
assert_replacement_chat_has_no_authority(
    'QueueAuthComplete', 'auth-complete.bin', 'before delayed SEND');
my $auth_get = mock_get(nick=>'QueueAuthComplete', name=>'auth-complete.bin', size=>4);
Irssi::emit('dcc request', $auth_get, '127.0.0.1');
ok scalar(grep { /^DCC GET QueueAuthComplete / } @{$server->{commands}}),
    'original queued SEND remains authorized after CHAT navigation is revoked';
$auth_get->{file} = File::Spec->catfile(
    $Irssi::SETTINGS{dcc_download_path}, 'auth-complete.bin');
Irssi::emit('dcc get receive', $auth_get);
assert_replacement_chat_has_no_authority(
    'QueueAuthComplete', 'auth-complete.bin', 'during queued transfer');
open my $auth_payload, '>:raw', $auth_get->{file} or die "create queued fixture: $!";
print {$auth_payload} 'data' or die "write queued fixture: $!";
close $auth_payload or die "close queued fixture: $!";
$auth_get->{transfd} = 4;
Irssi::emit('dcc closed', $auth_get);
my $auth_destination = File::Spec->catfile(
    $test_root, 'fserve-poc', 'downloads', 'FServeLab', 'QueueAuthComplete',
    '!QueueAuthComplete', 'auth-complete.bin');
ok -f $auth_destination, 'authorized delayed SEND completes and publishes after CHAT closure';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $auth_wait_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=complete/,
    'queued transfer reaches its durable complete state';
@Irssi::PRINTS = ();
run_status();
ok print_matches(qr/active=yes phase=complete nick=QueueAuthComplete/),
    'successful transfer leaves the session in its terminal progress phase';
assert_replacement_chat_has_no_authority(
    'QueueAuthComplete', 'auth-complete.bin', 'after successful completion');
Irssi::run_command('fscrawl', 'stop', $server, undef);

my ($auth_error_chat, $auth_error_job) = start_detached_queue_wait(
    'QueueAuthError', 'auth-error.bin', 5);
my $auth_error_get = mock_get(nick=>'QueueAuthError', name=>'auth-error.bin', size=>5);
Irssi::emit('dcc request', $auth_error_get, '127.0.0.1');
ok scalar(grep { /^DCC GET QueueAuthError / } @{$server->{commands}}),
    'queued SEND remains authorized in the error-path fixture';
$auth_error_get->{file} = File::Spec->catfile(
    $Irssi::SETTINGS{dcc_download_path}, 'auth-error.bin');
Irssi::emit('dcc get receive', $auth_error_get);
assert_replacement_chat_has_no_authority(
    'QueueAuthError', 'auth-error.bin', 'during transfer that will fail');
Irssi::emit('dcc closed', $auth_error_get);
@Irssi::PRINTS = ();
run_status();
ok print_matches(qr/active=yes phase=error nick=QueueAuthError/),
    'incomplete transfer close leaves the session in its terminal error phase';
assert_replacement_chat_has_no_authority(
    'QueueAuthError', 'auth-error.bin', 'after incomplete transfer close');
Irssi::run_command('fscrawl', 'stop', $server, undef);
my $auth_fresh_chat = start_fetch('QueueAuthFresh', '/fresh-session.txt');
ok scalar(grep { /^DCC CHAT QueueAuthFresh\z/ } @{$server->{commands}}),
    'a separately authorized session accepts its own CHAT after prior revocation';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Replacing a session after CHAT loss must preserve that outcome.
my $replace_chat = start_verified_root_get('QueueReplaceBot', 'replace-loss.txt', 5);
@Irssi::PRINTS = ();
run_status();
my ($replace_job) = join("\n", @Irssi::PRINTS) =~
    /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
ok $replace_job, 'replacement fixture has a dispatched durable job';
chat_line($replace_chat, "[fserve-phase6-test] QUEUED job=$replace_job position=1");
Irssi::emit('dcc closed', $replace_chat);
my $replacement_session = start_crawl('ReplacementBot');
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $replace_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=cancelled/,
    'starting a replacement session cancels the prior local queued wait';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# IRC disconnect also retires a confirmed queue wait without remote removal.
my $disconnect_chat = start_verified_root_get(
    'QueueDisconnectBot', 'disconnect-loss.txt', 6);
@Irssi::PRINTS = ();
run_status();
my ($disconnect_job) = join("\n", @Irssi::PRINTS) =~
    /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
ok $disconnect_job, 'disconnect fixture has a dispatched durable job';
chat_line($disconnect_chat,
    "[fserve-phase6-test] QUEUED job=$disconnect_job position=1");
$server->{connected} = 0;
Irssi::emit('server disconnected', $server);
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $disconnect_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=needs_attention/,
    'IRC disconnect retires the queued wait without remote queue removal';
$server->{connected} = 1;

# A confirmed queue deadline is absolute: position chatter cannot move it, and
# expiration never repeats the already-dispatched GET.
my $queue_expire_chat = start_verified_root_get(
    'QueueExpireBot', 'queue-expire.txt', 8);
@Irssi::PRINTS = ();
run_status();
my ($queue_expire_job) = join("\n", @Irssi::PRINTS) =~
    /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
ok $queue_expire_job, 'queue-deadline fixture has one dispatched job';
my $queue_expire_get_count = global_matches(qr/MSG =QueueExpireBot get queue-expire\.txt/);
chat_line($queue_expire_chat,
    "[fserve-phase6-test] QUEUED job=$queue_expire_job position=3");
my $queue_deadline_timer = last_timer_handle();
my $queue_deadline_record = Irssi::timer_record($queue_deadline_timer);
ok $queue_deadline_record && $queue_deadline_record->[5] >= 30000,
    'correlated queue acknowledgement arms a bounded absolute wait timer';
chat_line($queue_expire_chat,
    "[fserve-phase6-test] POSITION job=$queue_expire_job position=2");
is last_timer_handle(), $queue_deadline_timer,
    'later queue position does not replace the absolute wait timer';
ok Irssi::fire_timer($queue_deadline_timer),
    'the synthetic absolute queue deadline can be expired deterministically';
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $queue_expire_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=expired.*outcome=remote_queue_deadline/s,
    'confirmed queue deadline expires the job without retry';
is global_matches(qr/MSG =QueueExpireBot get queue-expire\.txt/),
    $queue_expire_get_count,
    'queue-wait expiration never retransmits the original file request';

# A correlated, explicit full response is distinct from ambiguous already-
# queued text and does not cause a guessed retry.
my $queue_full_chat = start_verified_root_get('QueueFullBot', 'queue-full.txt', 9);
@Irssi::PRINTS = ();
run_status();
my ($queue_full_job) = join("\n", @Irssi::PRINTS) =~
    /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
ok $queue_full_job, 'queue-full fixture has one dispatched job';
my $queue_full_get_count = global_matches(qr/MSG =QueueFullBot get queue-full\.txt/);
chat_line($queue_full_chat,
    "[fserve-phase6-test] SENDS-FULL job=$queue_full_job");
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $queue_full_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=refused_without_queue.*outcome=sends_full/s,
    'correlated explicit sends-full response has a distinct durable outcome';
is global_matches(qr/MSG =QueueFullBot get queue-full\.txt/),
    $queue_full_get_count,
    'explicit full refusal does not automatically repeat the GET';

# A server's unproven "already queued" response is not attached to this job.
my $already_chat = start_verified_root_get('AlreadyBot', 'already.txt', 10);
@Irssi::PRINTS = ();
run_status();
my ($already_job) = join("\n", @Irssi::PRINTS) =~
    /active_job=(job-[a-f0-9]{32}) state=awaiting_offer/;
ok $already_job, 'ambiguous already-queued fixture has one dispatched job';
chat_line($already_chat,
    "[fserve-phase6-test] ALREADY-QUEUED job=$already_job");
@Irssi::PRINTS = ();
Irssi::run_command('fscrawl', "job-show $already_job", $server, undef);
like join("\n", @Irssi::PRINTS), qr/state=needs_attention.*outcome=already_queued_ambiguous/s,
    'ambiguous already-queued response pauses for inspection rather than confirming ownership';

# A later rejected close, a mismatched offer, and a same-name duplicate all
# remain isolated from the one accepted transfer.
my $delayed_chat = start_fetch('DelayedReject', '/delayed.txt');
my $delayed_early = mock_get(nick=>'DelayedReject', name=>'delayed.txt', size=>7);
Irssi::emit('dcc request', $delayed_early, '127.0.0.1');
chat_line($delayed_chat, '[\\]');
chat_line($delayed_chat, '[\\*.*]');
chat_line($delayed_chat, 'delayed.txt 7B');
chat_line($delayed_chat, 'End of list.');
Irssi::emit('dcc closed', $delayed_early);
ok(global_matches(qr/MSG =DelayedReject get delayed\.txt/),
    'delayed premature-offer close leaves the verified request pending');

my $wrong_name = mock_get(nick=>'DelayedReject', name=>'unrelated.txt', size=>2);
Irssi::emit('dcc request', $wrong_name, '127.0.0.1');
Irssi::emit('dcc closed', $wrong_name);
my $delayed_get = mock_get(nick=>'DelayedReject', name=>'delayed.txt', size=>7);
my $delayed_stage = $Irssi::SETTINGS{dcc_download_path};
$delayed_get->{file} = File::Spec->catfile($delayed_stage, 'delayed.txt');
Irssi::emit('dcc request', $delayed_get, '127.0.0.1');
ok((scalar grep { /^DCC GET DelayedReject / } @{$server->{commands}}),
    'a later matching offer is accepted after a mismatched offer closes');

my $same_name_duplicate = mock_get(nick=>'DelayedReject', name=>'delayed.txt', size=>7);
my $close_get_commands_before_duplicate = scalar grep {
    /^DCC CLOSE GET DelayedReject /
} @{$server->{commands}};
my $download_path_before_duplicate = $Irssi::SETTINGS{dcc_download_path};
Irssi::emit('dcc request', $same_name_duplicate, '127.0.0.1');
ok($same_name_duplicate->{destroyed},
    'same-name duplicate offer is closed through its own DCC lifecycle handle');
is(
    scalar(grep { /^DCC CLOSE GET DelayedReject / } @{$server->{commands}}),
    $close_get_commands_before_duplicate,
    'rejecting a duplicate cannot run nick-and-filename close against the accepted handle',
);
Irssi::emit('dcc closed', $same_name_duplicate);
is $Irssi::SETTINGS{dcc_download_path}, $download_path_before_duplicate,
    'duplicate close cannot alter the bound transfer staging path';
Irssi::emit('dcc get receive', $delayed_get);
open my $delayed_fh, '>', $delayed_get->{file} or die "create delayed file: $!";
print {$delayed_fh} 'delayed' or die "write delayed file: $!";
close $delayed_fh or die "close delayed file: $!";
$delayed_get->{transfd} = 7;
Irssi::emit('dcc closed', $delayed_get);
my $delayed_destination = File::Spec->catfile(
    $test_root, 'fserve-poc', 'downloads', 'FServeLab', 'DelayedReject',
    '!DelayedReject', 'delayed.txt',
);
ok -f $delayed_destination,
    'only the accepted same-name handle completes the requested file';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# A transfer that outlives CHAT is finalized from its captured session context;
# its late close leaves a replacement session and its download path untouched.
my $detached_chat = start_fetch('DetachedBot', '/detached.txt');
chat_line($detached_chat, '[\\]');
chat_line($detached_chat, '[\\*.*]');
chat_line($detached_chat, 'detached.txt 8B');
chat_line($detached_chat, 'End of list.');
my $detached_get = mock_get(nick=>'DetachedBot', name=>'detached.txt', size=>8);
my $detached_stage = $Irssi::SETTINGS{dcc_download_path};
$detached_get->{file} = File::Spec->catfile($detached_stage, 'detached.txt');
Irssi::emit('dcc request', $detached_get, '127.0.0.1');
Irssi::emit('dcc get receive', $detached_get);
open my $detached_fh, '>', $detached_get->{file} or die "create detached file: $!";
print {$detached_fh} 'detached' or die "write detached file: $!";
close $detached_fh or die "close detached file: $!";
$detached_get->{transfd} = 8;
Irssi::run_command('fscrawl', 'stop', $server, undef);
my $replacement_chat = start_crawl('ReplacementBot');
my $replacement_path = $Irssi::SETTINGS{dcc_download_path};
Irssi::emit('dcc closed', $detached_get);
my $detached_destination = File::Spec->catfile(
    $test_root, 'fserve-poc', 'downloads', 'FServeLab', 'DetachedBot',
    '!DetachedBot', 'detached.txt',
);
ok -f $detached_destination, 'detached transfer finalizes into its original session directory';
is $Irssi::SETTINGS{dcc_download_path}, $replacement_path,
    'old transfer close does not restore over the replacement session setting';
run_status();
ok(print_matches(qr/active=yes phase=await_prompt nick=ReplacementBot chat=ReplacementBot/),
    'old transfer close does not clear replacement session state');
Irssi::run_command('fscrawl', 'stop', $server, undef);

# One interrupted accepted transfer clears only its matching request and is
# processed once; unrelated or duplicate close delivery remains inert.
my $interrupted_chat = start_verified_root_get('InterruptedBot', 'partial.txt', 10);
my $interrupted_stage = $Irssi::SETTINGS{dcc_download_path};
my $interrupted_get = mock_get(
    nick=>'InterruptedBot', name=>'partial.txt', size=>10,
    file=>File::Spec->catfile($interrupted_stage, 'partial.txt'), transfd=>3,
);
Irssi::emit('dcc request', $interrupted_get, '127.0.0.1');
Irssi::emit('dcc get receive', $interrupted_get);
open my $partial_fh, '>', $interrupted_get->{file} or die "create partial file: $!";
print {$partial_fh} 'par' or die "write partial file: $!";
close $partial_fh or die "close partial file: $!";
Irssi::emit('dcc closed', $interrupted_get);
ok(print_matches(qr/Download closed before confirmed completion: partial\.txt \(3\/10 bytes\)/),
    'interrupted accepted transfer is retained as partial data');
my $incomplete_count = print_matches(qr/Download closed before confirmed completion: partial\.txt/);
Irssi::emit('dcc closed', $interrupted_get);
is print_matches(qr/Download closed before confirmed completion: partial\.txt/), $incomplete_count,
    'duplicate interruption close is processed only once';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Native Irssi reports dcc get receive before it creates the local file.
# The follow-up connected event must capture ownership for an accepted alias.
my $alias_chat = start_verified_root_get('AliasReceiveBot', 'Space Name.txt', 10);
my ($alias_job_id) = current_job_status();
ok $alias_job_id, 'space-containing direct fetch created its durable job';
my $alias_stage = $Irssi::SETTINGS{dcc_download_path};
my $alias_path = File::Spec->catfile($alias_stage, 'Space_Name.txt');
my $alias_get = mock_get(nick=>'AliasReceiveBot', name=>'Space_Name.txt',
    size=>10, file=>$alias_path, transfd=>3);
Irssi::emit('dcc request', $alias_get, '127.0.0.1');
ok((scalar grep { /^DCC GET AliasReceiveBot / } @{$server->{commands}}),
    'unambiguous space-to-underscore DCC offer is accepted');
Irssi::emit('dcc get receive', $alias_get);
open my $alias_fh, '>:raw', $alias_path or die "create aliased partial file: $!";
print {$alias_fh} 'par' or die "write aliased partial file: $!";
close $alias_fh or die "close aliased partial file: $!";
Irssi::emit('dcc connected', $alias_get);
Irssi::emit('dcc closed', $alias_get);
my $alias_job = latest_job_snapshot($alias_job_id);
is $alias_job->{state}, 'interrupted',
    'closed aliased receive is recorded as interrupted';
ok $alias_job->{partial}{writer_closed},
    'aliased partial records confirmed native writer closure';
is $alias_job->{partial}{ownership_status}, 'captured',
    'accepted offered basename captures the aliased partial ownership';
ok !$alias_job->{partial}{source_invalid},
    'unchanged staged alias path remains valid';
my $alias_seal = FServe::Transfer::Resume::begin_partial_seal(
    path => $alias_job->{partial}{path},
    staging_root => $alias_job->{partial}{staging_root},
    expected_identity => $alias_job->{partial}{file_identity},
    total_size => $alias_job->{partial}{total_size},
);
is $alias_seal->{type}, 'sealing',
    'captured closed alias partial is eligible for the production sealer';
FServe::Transfer::Resume::cancel_partial_seal($alias_seal)
    if $alias_seal->{type} eq 'sealing';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# A later path change or inode replacement still invalidates capture.
my $path_chat = start_verified_root_get('ChangedPathBot', 'PathChange.txt', 10);
my ($path_job_id) = current_job_status();
my $path_stage = $Irssi::SETTINGS{dcc_download_path};
my $path_file = File::Spec->catfile($path_stage, 'PathChange.txt');
my $path_get = mock_get(nick=>'ChangedPathBot', name=>'PathChange.txt',
    size=>10, file=>$path_file, transfd=>3);
Irssi::emit('dcc request', $path_get, '127.0.0.1');
Irssi::emit('dcc get receive', $path_get);
open my $path_fh, '>:raw', $path_file or die "create path-change partial: $!";
print {$path_fh} 'par' or die "write path-change partial: $!";
close $path_fh or die "close path-change partial: $!";
Irssi::emit('dcc connected', $path_get);
$path_get->{file} = File::Spec->catfile($test_root, 'outside-partial.txt');
Irssi::emit('dcc connected', $path_get);
Irssi::emit('dcc closed', $path_get);
my $path_job = latest_job_snapshot($path_job_id);
ok $path_job->{partial}{source_invalid},
    'changed receive path remains ineligible for sealing';
is $path_job->{partial}{ownership_status}, 'unverified',
    'changed receive path fails closed as unverified';
Irssi::run_command('fscrawl', 'stop', $server, undef);

my $inode_chat = start_verified_root_get('ChangedInodeBot', 'InodeChange.txt', 10);
my ($inode_job_id) = current_job_status();
my $inode_stage = $Irssi::SETTINGS{dcc_download_path};
my $inode_file = File::Spec->catfile($inode_stage, 'InodeChange.txt');
my $inode_get = mock_get(nick=>'ChangedInodeBot', name=>'InodeChange.txt',
    size=>10, file=>$inode_file, transfd=>3);
Irssi::emit('dcc request', $inode_get, '127.0.0.1');
Irssi::emit('dcc get receive', $inode_get);
open my $inode_fh, '>:raw', $inode_file or die "create inode-change partial: $!";
print {$inode_fh} 'par' or die "write inode-change partial: $!";
close $inode_fh or die "close inode-change partial: $!";
Irssi::emit('dcc connected', $inode_get);
my $inode_displaced = $inode_file . '.displaced';
my $inode_replacement = $inode_file . '.replacement';
open my $replacement_fh, '>:raw', $inode_replacement
    or die "create inode replacement: $!";
print {$replacement_fh} 'par' or die "write inode replacement: $!";
close $replacement_fh or die "close inode replacement: $!";
rename $inode_file, $inode_displaced or die "displace original partial: $!";
rename $inode_replacement, $inode_file or die "install replacement partial: $!";
Irssi::emit('dcc connected', $inode_get);
Irssi::emit('dcc closed', $inode_get);
my $inode_job = latest_job_snapshot($inode_job_id);
ok $inode_job->{partial}{source_invalid},
    'replacement inode at the accepted path remains ineligible for sealing';
is $inode_job->{partial}{ownership_status}, 'unverified',
    'replacement inode fails closed as unverified';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Invalid indices cannot select the final array element or cause remote work.
my $index_chat = start_crawl('IndexBot');
chat_line($index_chat, '[\\]');
chat_line($index_chat, '[\\*.*]');
chat_line($index_chat, 'first.txt 1B');
chat_line($index_chat, 'last.txt 2B');
chat_line($index_chat, 'End of list.');
my $commands_before_invalid_indexes = scalar @Irssi::GLOBAL_COMMANDS;
for my $invalid ('0', '-1', 'nonnumeric', '', '3') {
    Irssi::run_command('fscrawl', "get $invalid", $server, undef);
}
is scalar(@Irssi::GLOBAL_COMMANDS), $commands_before_invalid_indexes,
    'zero, negative, nonnumeric, empty, and out-of-range indices send no chat commands';
ok(!(print_matches(qr/A download request is already pending/)),
    'invalid indices do not create a pending request');
Irssi::run_command('fscrawl', 'get 1', $server, undef);
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =IndexBot dir', 'first valid index remains one-based';
Irssi::run_command('fscrawl', 'stop', $server, undef);

my $last_index_chat = start_crawl('LastIndexBot');
chat_line($last_index_chat, '[\\]');
chat_line($last_index_chat, '[\\*.*]');
chat_line($last_index_chat, 'first.txt 1B');
chat_line($last_index_chat, 'last.txt 2B');
chat_line($last_index_chat, 'End of list.');
Irssi::run_command('fscrawl', 'get 2', $server, undef);
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =LastIndexBot dir', 'last valid file index remains selectable';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Automatic pre-dispatch recovery is captured per job, bounded, tied to the
# originating IRC connection, and must reverify the parent before GET.
Irssi::settings_set_bool('fscrawl_auto_recovery', 0);
my $recovery_off_chat = start_fetch('RecoveryOffBot', '/off.txt');
my ($recovery_off_job, $recovery_off_initial_state) = current_job_status();
is $recovery_off_initial_state, 'preparing',
    'direct fetch is durably preparing before its CHAT closes';
is trigger_count('RecoveryOffBot'), 1,
    'default-off direct fetch dispatches only its original trigger';
Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
Irssi::emit('dcc closed', $recovery_off_chat);
is job_state($recovery_off_job), 'needs_attention',
    'enabling recovery after job creation does not expand its captured policy';
is trigger_count('RecoveryOffBot'), 1,
    'default-off job is not retriggered after CHAT loss';
is timer_count_due_in_ms_range(1000, 120000), 0,
    'default-off job schedules no pre-dispatch retry';

Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
$server->{on_command} = sub {
    die "mock trigger transport failure\n"
        if $_[0] eq 'MSG #files !RecoveryFailedBot';
};
my $previous_auto_drain = $Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND;
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = 0;
my $failed_trigger_chat = start_fetch('RecoveryFailedBot', '/late-chat.txt');
my ($failed_trigger_job, $failed_trigger_state) = current_job_status();
ok defined($failed_trigger_job),
    'ambiguous trigger failure remains addressable in session status';
is $failed_trigger_state, 'preparing',
    'trigger job remains preparing while its paced send is pending';
my @failed_trigger_timers = timers_due_in_ms_range(1990, 2100);
is scalar(@failed_trigger_timers), 1,
    'failed-trigger fixture pauses at the connection pacing boundary';
ok fire_next_outbound_timer(),
    'ambiguous trigger transport failure is injected at dispatch time';
$Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = $previous_auto_drain;
delete $server->{on_command};
is job_state($failed_trigger_job), 'needs_attention',
    'ambiguous trigger transport failure remains a durable attention case';
is trigger_count('RecoveryFailedBot'), 1,
    'ambiguous trigger failure is never repeated automatically';
Irssi::emit('dcc request', $failed_trigger_chat, '127.0.0.1');
Irssi::emit('dcc connected', $failed_trigger_chat);
is scalar(grep { $_ eq 'DCC CHAT RecoveryFailedBot' } @{$server->{commands}}), 0,
    'late indistinguishable CHAT is not accepted after trigger failure';
chat_line($failed_trigger_chat, '[\\]');
ok(!(global_matches(qr/^MSG =RecoveryFailedBot (?:dir|cd|get)(?:\s|$)/)),
    'a late CHAT cannot regain navigation authority after ambiguous trigger failure');
is timer_count_due_in_ms_range(1000, 120000), 0,
    'ambiguous trigger failure creates no recovery timer';
Irssi::run_command('fscrawl', 'stop', $server, undef);

Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
my $recovery_chat = start_fetch('RecoveryBot', '/subdir/recovery.txt');
my ($recovery_job, $recovery_initial_state) = current_job_status();
is $recovery_initial_state, 'preparing',
    'opted-in direct fetch begins in the recoverable pre-dispatch state';
is trigger_count('RecoveryBot'), 1,
    'opted-in job sends one initial trigger';
chat_line($recovery_chat, '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =RecoveryBot cd subdir',
    'original CHAT begins navigation before recovery';
my $stale_recovery_nav_timer = last_timer_handle();
Irssi::settings_set_bool('fscrawl_auto_recovery', 0);
Irssi::emit('dcc closed', $recovery_chat);
is job_state($recovery_job), 'preparing',
    'CHAT loss retains the opted-in job while its bounded retry is pending';
my @first_recovery_timers = timers_due_in_ms_range(5000, 6000);
is scalar(@first_recovery_timers), 1,
    'first automatic attempt uses the configured five-second backoff with bounded jitter';
ok(Irssi::fire_timer($first_recovery_timers[0]),
    'first recovery timer starts a fresh session');
ok(fire_next_outbound_timer(),
    'fresh session trigger waits for the serving-route cooldown, then dispatches');
is trigger_count('RecoveryBot'), 2,
    'the first recovery dispatch adds exactly one trigger';
ok Irssi::fire_timer($stale_recovery_nav_timer, 1),
    'a cancelled navigation callback from the prior CHAT can be invoked';
@Irssi::PRINTS = ();
run_status();
ok(print_matches(qr/active=yes phase=waiting_for_chat nick=RecoveryBot chat=no/),
    'old-session navigation callback cannot fail the fresh recovery generation');
my $fresh_recovery_chat = mock_chat('RecoveryBot');
Irssi::emit('dcc request', $fresh_recovery_chat, '127.0.0.1');
Irssi::emit('dcc connected', $fresh_recovery_chat);
is scalar(grep { $_ eq 'DCC CHAT RecoveryBot' } @{$server->{commands}}), 2,
    'retry accepts a distinct fresh CHAT lifecycle for the expected peer';
chat_line($fresh_recovery_chat, '[\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =RecoveryBot cd subdir',
    'fresh CHAT restarts navigation from its acknowledged root';
chat_line($fresh_recovery_chat, '[\\subdir\\]');
is $Irssi::GLOBAL_COMMANDS[-1], 'MSG =RecoveryBot dir',
    'fresh navigation acknowledgement starts live-parent verification';
chat_line($fresh_recovery_chat, '[\\subdir\\*.*]');
chat_line($fresh_recovery_chat, 'recovery.txt 5B');
chat_line($fresh_recovery_chat, 'End of list.');
ok(global_matches(qr/^MSG =RecoveryBot get recovery\.txt\z/),
    'recovery navigates the fresh CHAT and requests the file only after live-parent verification');
is job_state($recovery_job), 'awaiting_offer',
    'durable GET intent closes the pre-dispatch recovery window';
is timer_count_due_in_ms_range(5000, 20000), 0,
    'no recovery backoff timer remains after GET intent is recorded';
Irssi::emit('dcc closed', $fresh_recovery_chat);
is trigger_count('RecoveryBot'), 2,
    'CHAT loss after GET dispatch does not replay the content request trigger';
is job_state($recovery_job), 'needs_attention',
    'post-dispatch CHAT loss requires attention instead of automatic recovery';
Irssi::run_command('fscrawl', 'stop', $server, undef);

Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
my $recovery_cap_chat = start_fetch('RecoveryCapBot', '/cap.txt');
my ($recovery_cap_job) = current_job_status();
Irssi::emit('dcc closed', $recovery_cap_chat);
my @cap_first_timers = timers_due_in_ms_range(5000, 6000);
is scalar(@cap_first_timers), 1, 'attempt one is scheduled within its bounded backoff';
ok(Irssi::fire_timer($cap_first_timers[0]), 'attempt one is started');
ok(fire_next_outbound_timer(), 'attempt one trigger respects the route cooldown');
my $cap_first_retry_chat = mock_chat('RecoveryCapBot');
Irssi::emit('dcc request', $cap_first_retry_chat, '127.0.0.1');
Irssi::emit('dcc connected', $cap_first_retry_chat);
Irssi::emit('dcc closed', $cap_first_retry_chat);
my @cap_second_timers = timers_due_in_ms_range(15000, 18000);
is scalar(@cap_second_timers), 1,
    'attempt two uses the configured fifteen-second backoff with bounded jitter';
ok(Irssi::fire_timer($cap_second_timers[0]), 'attempt two is started');
ok(fire_next_outbound_timer(), 'attempt two trigger respects the route cooldown');
my $cap_second_retry_chat = mock_chat('RecoveryCapBot');
Irssi::emit('dcc request', $cap_second_retry_chat, '127.0.0.1');
Irssi::emit('dcc connected', $cap_second_retry_chat);
Irssi::emit('dcc closed', $cap_second_retry_chat);
is trigger_count('RecoveryCapBot'), 3,
    'recovery never exceeds two additional triggers';
is job_state($recovery_cap_job), 'needs_attention',
    'exhausted recovery leaves the job for explicit attention';
is timer_count_due_in_ms_range(1000, 120000), 0,
    'attempt exhaustion cancels retry and deadline timers';

Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
my $recovery_deadline_chat = start_fetch('RecoveryDeadlineBot', '/deadline.txt');
my ($recovery_deadline_job) = current_job_status();
Irssi::emit('dcc closed', $recovery_deadline_chat);
my @recovery_deadline_timers = timers_due_in_ms_range(119000, 120000);
is scalar(@recovery_deadline_timers), 1,
    'recovery arms one absolute 120-second deadline';
ok Irssi::fire_timer($recovery_deadline_timers[0]),
    'absolute recovery deadline can be expired deterministically';
is job_state($recovery_deadline_job), 'needs_attention',
    'deadline expiry settles the job without waiting for another retry';
is trigger_count('RecoveryDeadlineBot'), 1,
    'deadline expiry does not replay the original trigger';

Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
my $recovery_disconnect_chat = start_fetch('RecoveryDisconnectBot', '/offline.txt');
my ($recovery_disconnect_job) = current_job_status();
Irssi::emit('dcc closed', $recovery_disconnect_chat);
my @recovery_disconnect_timers = timers_due_in_ms_range(5000, 6000);
is scalar(@recovery_disconnect_timers), 1,
    'connection-liveness fixture has one pending retry';
$server->{connected} = 0;
ok Irssi::fire_timer($recovery_disconnect_timers[0]),
    'retry callback checks its captured connection liveness';
$server->{connected} = 1;
is job_state($recovery_disconnect_job), 'needs_attention',
    'retry on a disconnected server settles for attention';
is trigger_count('RecoveryDisconnectBot'), 1,
    'disconnected retry sends no trigger';

Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
my $recovery_stop_chat = start_fetch('RecoveryStopBot', '/stop.txt');
my ($recovery_stop_job) = current_job_status();
Irssi::emit('dcc closed', $recovery_stop_chat);
my @recovery_stop_timers = timers_due_in_ms_range(5000, 6000);
is scalar(@recovery_stop_timers), 1,
    'user-cancellation fixture has one pending retry timer';
my $cancelled_recovery_timer = $recovery_stop_timers[0];
Irssi::run_command('fscrawl', 'stop', $server, undef);
is job_state($recovery_stop_job), 'needs_attention',
    'explicit stop settles the pre-dispatch job for inspection';
ok Irssi::fire_timer($cancelled_recovery_timer, 1),
    'a cancelled retry callback remains safely invocable in the harness';
is trigger_count('RecoveryStopBot'), 1,
    'a late cancelled callback cannot dispatch another trigger';

# A session given up as not an FServe's is stopped from a timer. When its
# CHAT closes before that timer has run, as it does once its socket is cut,
# the session ends the same way, and there is no CHAT left to close.
Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
my $given_up_chat = start_fetch('GivenUpBot', '/subdir/given-up.txt');
chat_line($given_up_chat, '[\\]');
@Irssi::PRINTS = ();
chat_line($given_up_chat, "\x7fELF\x02\x01\x01");
ok(print_matches(qr/data that is not text over its session/),
    'a line that is not text gives the session up');
my @given_up_stop_timers = grep { Irssi::timer_record($_)->[5] == 10 } timer_handles();
ok scalar(@given_up_stop_timers), 'the session is to be stopped from a timer';
@Irssi::GLOBAL_COMMANDS = ();
Irssi::emit('dcc closed', $given_up_chat);
@Irssi::PRINTS = ();
run_status();
ok(print_matches(qr/active=no phase=- nick=- chat=no/),
    'a given-up session whose CHAT closes first ends as its timer would end it');
Irssi::fire_timer($_) for @given_up_stop_timers;
is global_matches(qr/^DCC CLOSE CHAT /), 0,
    'neither the close nor the late timer asks Irssi to close the CHAT again';
is trigger_count('GivenUpBot'), 1, 'a given-up session is not triggered again';
is timer_count_due_in_ms_range(1000, 120000), 0,
    'a given-up session schedules no retry when its CHAT closes';

# Preserve a real Find selection through the retry copy and fresh CHAT.
Irssi::settings_set_bool('fscrawl_auto_recovery', 1);
$Irssi::SETTINGS{fscrawl_find_quiet_ms} = 250;
Irssi::run_command('fscrawl', 'find #files recovery-selection', $server, undef);
for my $line (
    '[@Find Results] -=SysReset 2.55=-',
    'Found [1] file on Trigger:[!FindRecoveryBot] - Sends:[0/1] - Queues:[0/1]',
    'File: [found.txt] - Size [7B]',
    'End of @Find.',
) {
    Irssi::Script::dccatlas::handle_find_message(
        'public', $server, $line, 'FindRecoveryBot', 'bot@localhost', '#files');
}
ok Irssi::fire_timer($Irssi::TIMERS[-1][2]), 'recovery Find collection completes';
Irssi::run_command('fscrawl', 'fetch 1 channel', $server, undef);
my $find_recovery_chat = mock_chat('FindRecoveryBot');
Irssi::emit('dcc request', $find_recovery_chat, '127.0.0.1');
Irssi::emit('dcc connected', $find_recovery_chat);
my ($find_recovery_job, $find_recovery_state) = current_job_status();
is $find_recovery_state, 'preparing', 'fresh Find selection starts preparing';
Irssi::emit('dcc closed', $find_recovery_chat);
my @find_recovery_timers = timers_due_in_ms_range(5000, 6000);
is scalar(@find_recovery_timers), 1, 'Find recovery schedules one retry';
Irssi::fire_timer($find_recovery_timers[0]) if @find_recovery_timers;
Irssi::test_run_outbound_timers();
is trigger_count('FindRecoveryBot'), 2, 'unchanged Find selection sends one retry trigger';
is job_state($find_recovery_job), 'preparing', 'Find sender identity survives retry';
my $find_fresh_chat = mock_chat('FindRecoveryBot');
Irssi::emit('dcc request', $find_fresh_chat, '127.0.0.1');
Irssi::emit('dcc connected', $find_fresh_chat);
is global_matches(qr/^MSG =FindRecoveryBot get found\.txt\z/), 0,
    'Find retry has no GET before fresh parent verification';
chat_line($find_fresh_chat, '[\\]');
chat_line($find_fresh_chat, '[\\*.*]');
chat_line($find_fresh_chat, 'found.txt 7B');
chat_line($find_fresh_chat, 'End of list.');
is global_matches(qr/^MSG =FindRecoveryBot get found\.txt\z/), 1,
    'Find retry sends one GET after fresh parent verification';
is job_state($find_recovery_job), 'awaiting_offer', 'Find retry reaches offer wait';
Irssi::run_command('fscrawl', 'stop', $server, undef);

# Fire outbound work before the overdue deadline callback, as can happen
# after an event-loop stall. The recovery clock is controlled independently
# of timer delivery, so expiry must be checked at the dispatch boundary.
{
    no warnings 'redefine';
    my $recovery_clock = 10000;
    local *Irssi::Script::dccatlas::monotonic_now = sub { $recovery_clock };
    my $late_chat = start_fetch('LateTriggerBot', '/late.txt');
    my ($late_job) = current_job_status();
    Irssi::emit('dcc closed', $late_chat);
    my @late_retry = timers_due_in_ms_range(5000, 6000);
    is scalar(@late_retry), 1, 'late-trigger fixture schedules retry';
    $recovery_clock = 10006;
    Irssi::fire_timer($late_retry[0]) if @late_retry;
    is trigger_count('LateTriggerBot'), 1, 'retry trigger waits on route pacing';
    $recovery_clock = 10121;
    $Irssi::MOCK_MONOTONIC += 121;
    Irssi::test_run_outbound_timers();
    is trigger_count('LateTriggerBot'), 1, 'overdue trigger callback sends no retry';
    is job_state($late_job), 'needs_attention', 'expired paced trigger settles for attention';
    Irssi::run_command('fscrawl', 'stop', $server, undef);

    for my $paced_get (0, 1) {
        my $nick = $paced_get ? 'PacedExpiryBot' : 'ListingExpiryBot';
        $recovery_clock = 20000;
        my $initial_chat = start_fetch($nick, '/deadline.txt');
        my ($job_id) = current_job_status();
        Irssi::emit('dcc closed', $initial_chat);
        my @retry = timers_due_in_ms_range(5000, 6000);
        is scalar(@retry), 1, "$nick schedules one recovery attempt";
        $recovery_clock = 20006;
        Irssi::fire_timer($retry[0]) if @retry;
        Irssi::test_run_outbound_timers();
        is trigger_count($nick), 2, "$nick sends its retry inside the window";
        my $fresh_chat = mock_chat($nick);
        Irssi::emit('dcc request', $fresh_chat, '127.0.0.1');
        Irssi::emit('dcc connected', $fresh_chat);
        chat_line($fresh_chat, '[\\]');
        chat_line($fresh_chat, '[\\*.*]');
        chat_line($fresh_chat, 'deadline.txt 5B');
        $recovery_clock = $paced_get ? 20119 : 20120;
        local $Irssi::AUTO_DRAIN_OUTBOUND_ON_COMMAND = $paced_get ? 0 : 1;
        chat_line($fresh_chat, 'End of list.');
        if ($paced_get) {
            is job_state($job_id), 'dispatch_intent', 'GET intent precedes the paced transport';
            is global_matches(qr/^MSG =\Q$nick\E get deadline\.txt\z/), 0,
                'GET remains unsent while pacing is pending';
            $recovery_clock = 20120;
            $Irssi::MOCK_MONOTONIC += 120;
            Irssi::test_run_outbound_timers();
        }
        is global_matches(qr/^MSG =\Q$nick\E get deadline\.txt\z/), 0,
            "$nick refuses GET at the absolute recovery deadline";
        is job_state($job_id), 'needs_attention', "$nick settles expired recovery for attention";
        Irssi::run_command('fscrawl', 'stop', $server, undef);
    }
}

Irssi::Script::dccatlas::UNLOAD();
my $journal_probe = FServe::Transfer::Journal->open_store(
    path => File::Spec->catfile($test_root, 'fserve-poc', 'phase6', 'requests.jsonl'));
ok $journal_probe, 'unload releases the durable request-journal lock after lifecycle tests';
$journal_probe->close();

done_testing();
