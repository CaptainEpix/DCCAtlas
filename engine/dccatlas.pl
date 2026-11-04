package FServeParser;
use strict;
use warnings;
# Keep the original names for callers while parser logic lives in lib/FServe/Parser.pm.
sub parse_line { goto &FServe::Parser::parse_line }
sub strip_formatting { goto &FServe::Parser::strip_formatting }
sub size_to_bytes { goto &FServe::Parser::size_to_bytes }
sub join_path { goto &FServe::Parser::join_path }
1;

package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Digest::SHA qw(sha256_hex);
use File::Spec ();
use POSIX qw(strftime);

our %IRSSI = (
    authors     => 'DCCAtlas',
    contact     => 'https://github.com/CaptainEpix/DCCAtlas/issues',
    name        => 'dccatlas',
    description => "DCCAtlas's IRC and DCC engine, driven by its web service",
    license     => 'MIT',
);

Irssi::settings_add_int('dccatlas', 'fscrawl_max_depth', 2);
Irssi::settings_add_int('dccatlas', 'fscrawl_command_delay_ms', 400);
Irssi::settings_add_int('dccatlas', 'fscrawl_initial_prompt_timeout_ms', 2500);
Irssi::settings_add_int('dccatlas', 'fscrawl_navigation_timeout_ms', 5000);
# File servers that answer in private send a line every second or two, and
# some take over two minutes for 30 rows (seen 2026-10-20), so a search
# collects for up to 150 seconds and ends after 30 seconds without a reply.
Irssi::settings_add_int('dccatlas', 'fscrawl_find_timeout_ms', 150000);
Irssi::settings_add_int('dccatlas', 'fscrawl_find_quiet_ms', 30000);
# A search nothing answers at all ends after this, not after the full limit.
Irssi::settings_add_int('dccatlas', 'fscrawl_find_first_reply_ms', 60000);
Irssi::settings_add_int('dccatlas', 'fscrawl_searchbot_timeout_ms', 30000);
Irssi::settings_add_int('dccatlas', 'fscrawl_searchbot_transfer_timeout_ms', 300000);
Irssi::settings_add_int('dccatlas', 'fscrawl_searchbot_parse_timeout_ms', 300000);
Irssi::settings_add_int('dccatlas', 'fscrawl_searchbot_content_timeout_ms', 120000);
# How long Get list waits for a list server's list (2026-10-27); such
# servers queue requests, and waiting sends nothing.
Irssi::settings_add_int('dccatlas', 'fscrawl_list_offer_timeout_ms', 300000);
Irssi::settings_add_int('dccatlas', 'fscrawl_searchbot_content_transfer_timeout_ms', 300000);
Irssi::settings_add_int('dccatlas', 'fscrawl_searchbot_max_content_bytes', 268435456);
Irssi::settings_add_str('dccatlas', 'fscrawl_output_dir', 'fserve-poc');
Irssi::settings_add_str('dccatlas', 'fscrawl_download_dir', 'fserve-poc/downloads');
# Lists, and a search bot's result lists, are kept here, not with the
# downloads (2026-10-28): the application's own, kept until removed.
Irssi::settings_add_str('dccatlas', 'fscrawl_lists_dir', 'fserve-poc/lists');
Irssi::settings_add_str('dccatlas', 'fscrawl_library_dir', 'scripts/lib');
Irssi::settings_add_str('dccatlas', 'fscrawl_python_executable', 'python');
Irssi::settings_add_str('dccatlas', 'fscrawl_perl_executable', 'perl');
Irssi::settings_add_str('dccatlas', 'fscrawl_state_dir', 'fserve-poc/phase6');
Irssi::settings_add_str('dccatlas', 'fscrawl_bridge_socket', 'fserve-poc/engine.sock');
Irssi::settings_add_int('dccatlas', 'fscrawl_journal_max_bytes', 1073741824);
Irssi::settings_add_int('dccatlas', 'fscrawl_queue_max_wait_ms', 900000);
Irssi::settings_add_int('dccatlas', 'fscrawl_session_open_ms', 60000);
Irssi::settings_add_int('dccatlas', 'fscrawl_offer_timeout_ms', 120000);
Irssi::settings_add_bool('dccatlas', 'fscrawl_auto_recovery', 0);

our %S;
# The search being acted on. Since 2026-10-27 each source's connection may
# have a search running at once; one set aside is made %FIND again
# (find_with) whenever something acts on it, so this is a package variable.
our %FIND;
our %SEARCHBOT;
our %SEARCHBOT_DIRECT;
our %SEARCHBOT_MODULES;
our %SEARCHBOT_USED_OFFERS;
our %SEARCHBOT_CONTENT_TOMBSTONES;
our %JOBS;
our %CATALOG;
our %MANIFEST;
our %CATALOG_WORKER;
our %TRANSFERS;
our %USED_TRANSFER_IDENTITIES;
our $SESSION_GENERATION = 0;
our $SEARCHBOT_SEQUENCE = 0;
our $SEARCHBOT_DIRECT_SEQUENCE = 0;
our $PROCESS_INCARNATION = substr(sha256_hex(join("\0", $$, time, rand(), {})), 0, 32);
our $DOWNLOAD_PATH_OWNER;
# A package variable so an engine test can stand in for the bridge.
our $WEB_BRIDGE;
our %WEB_BRIDGE_SOURCES;
our %WEB_BRIDGE_SELECTIONS;
our %WEB_BRIDGE;
# Browsing a file server from the page: at most this many folders are read,
# this many entries kept, and the whole walk may take this long.
our $WEB_BRIDGE_BROWSE_FOLDER_LIMIT = 40;
our $WEB_BRIDGE_BROWSE_ENTRY_LIMIT = 5000;
our $WEB_BRIDGE_BROWSE_SECONDS = 300;
# The most a status reply's result may take, in bytes: one bridge frame is
# 64 KiB, and the rest of the reply around the result needs room too.
our $WEB_BRIDGE_STATUS_BYTES = 60 * 1024;
our $old_dcc_download_path;

# While the web bridge runs an engine command it keeps what the command said,
# so a refusal reaches the browser in the engine's own words.
our $WEB_BRIDGE_SAID;


# The engine is split by area into parts, each in this package (2026-11-03),
# loaded here in order from the library folder.
our @ENGINE_PARTS = qw(
    modules outbound sources engine_log jobs transfer_stop resume_guard
    catalog downloads dcc session searchbot find queue journal web_bridge
    web_searchbot web_lists web_browse commands
);
add_library_dir_to_inc();
for my $part (@ENGINE_PARTS) {
    my $file = "FServe/Engine/$part.pl";
    my $loaded = do $file;
    die "could not load the engine's $file: " . ($@ || $! || 'it returned false') . "\n"
        unless $loaded;
}

sub p {
    push @$WEB_BRIDGE_SAID, join('', @_) if ref($WEB_BRIDGE_SAID) eq 'ARRAY';
    Irssi::print('[fscrawl] ' . join('', @_));
}

sub now_iso {
    return strftime('%Y-%m-%dT%H:%M:%S%z', localtime());
}

sub safe_field {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/[\r\n\t]+/ /g;
    return $v;
}

sub resolve_irssi_path {
    my ($p) = @_;
    return $p if File::Spec->file_name_is_absolute($p);
    return File::Spec->catdir(Irssi::get_irssi_dir(), $p);
}

sub lists_dir {
    return resolve_irssi_path(Irssi::settings_get_str('fscrawl_lists_dir'));
}

sub add_library_dir_to_inc {
    my $library_dir = resolve_irssi_path(
        Irssi::settings_get_str('fscrawl_library_dir')
    );
    if (-d $library_dir && !grep { $_ eq $library_dir } @INC) {
        unshift @INC, $library_dir;
    }
    return $library_dir;
}

Irssi::command_bind('fscrawl', \&cmd_fscrawl);
Irssi::signal_add('message public', \&sig_find_public);
Irssi::signal_add('message public', \&sig_advert_public);
Irssi::signal_add('message private', \&sig_find_private);
Irssi::signal_add('message irc notice', \&sig_find_notice);
Irssi::signal_add('message irc notice', \&sig_trigger_notice);
Irssi::signal_add('message irc notice', \&sig_searchbot_notice);
Irssi::signal_add('message irc notice', \&sig_servers_answer);
Irssi::signal_add('message private', \&sig_servers_answer);
Irssi::signal_add_first('ctcp msg dcc send', \&sig_phase6_pre_native_dcc_send);
Irssi::signal_add_first('ctcp msg dcc accept', \&sig_phase6_pre_native_dcc_accept);
Irssi::signal_add('dcc request', \&sig_dcc_request);
Irssi::signal_add('dcc connected', \&sig_dcc_connected);
Irssi::signal_add_first('dcc chat message', \&sig_dcc_chat_message);
Irssi::signal_add('dcc get receive', \&sig_dcc_get_receive);
Irssi::signal_add_last('dcc closed', \&sig_dcc_closed);
Irssi::signal_add('dcc error connect', \&sig_dcc_error);
Irssi::signal_add('dcc error file create', \&sig_dcc_error);
Irssi::signal_add('dcc destroyed', \&sig_dcc_destroyed);
Irssi::signal_add('server connected', \&sig_server_connected);
Irssi::signal_add('server disconnected', \&sig_server_disconnected);
Irssi::signal_add_last('server connect failed', \&sig_server_connect_failed);
Irssi::signal_add('event 001', \&sig_web_bridge_welcome);
Irssi::signal_add('message irc notice', \&sig_web_bridge_nickserv_notice);
Irssi::signal_add('event error', \&sig_event_error);
Irssi::signal_add('event 464', \&sig_event_464);
Irssi::signal_add('server sasl failure', \&sig_server_sasl_failure);
web_bridge_clear_certificate_files();
Irssi::signal_add('server incoming', \&sig_engine_log_incoming);
Irssi::signal_add('print text', \&sig_engine_log_print);
Irssi::signal_add('message own_public', \&sig_engine_log_own_public);
Irssi::signal_add('message own_private', \&sig_engine_log_own_private);
Irssi::signal_add('message irc own_notice', \&sig_engine_log_own_notice);
Irssi::signal_add('message irc own_ctcp', \&sig_engine_log_own_ctcp);
# After Irssi's own handler, which renames the CHAT.
Irssi::signal_add_last('event nick', \&sig_event_nick);
Irssi::signal_add('channel joined', \&web_bridge_on_channel_joined);
Irssi::signal_add('channel destroyed', \&web_bridge_channel_destroyed);

# Irssi binds file-descriptor and timeout registrations to the script package
# that calls its Perl API. The bridge module owns the protocol callbacks, but
# these closures make their registrations belong to this loaded script.
sub web_bridge_input_add {
    my ($fd, $condition, $callback, $data) = @_;
    return unless ref($callback) eq 'CODE';
    return Irssi::input_add($fd, $condition, sub { $callback->(@_) }, $data);
}

sub web_bridge_input_remove {
    return Irssi::input_remove($_[0]);
}

sub web_bridge_timeout_add_once {
    my ($milliseconds, $callback, $data) = @_;
    return unless ref($callback) eq 'CODE';
    return Irssi::timeout_add_once(
        $milliseconds, sub { $callback->(@_) }, $data,
    );
}

sub web_bridge_timeout_remove {
    return Irssi::timeout_remove($_[0]);
}

my $bridge_started = eval {
    add_library_dir_to_inc();
    require FServe::Bridge::Unix;
    my $socket_path = resolve_irssi_path(
        Irssi::settings_get_str('fscrawl_bridge_socket'));
    $WEB_BRIDGE = FServe::Bridge::Unix->new(
        path => $socket_path,
        on_request => \&web_bridge_dispatch,
        input_add => \&web_bridge_input_add,
        input_remove => \&web_bridge_input_remove,
        timeout_add_once => \&web_bridge_timeout_add_once,
        timeout_remove => \&web_bridge_timeout_remove,
    );
    $WEB_BRIDGE->start();
    1;
};
unless ($bridge_started) {
    my $error = $@ || 'bridge startup failed';
    $error =~ s/[\r\n]+/ /g;
    $WEB_BRIDGE = undef;
    p("Web engine bridge is unavailable: $error");
}

sub UNLOAD {
    if ($WEB_BRIDGE) {
        eval { $WEB_BRIDGE->stop(); 1 };
        $WEB_BRIDGE = undef;
    }
    for my $source (values %WEB_BRIDGE_SOURCES) {
        Irssi::timeout_remove($source->{join_timer}) if defined $source->{join_timer};
    }
    %WEB_BRIDGE_SOURCES = ();
    %WEB_BRIDGE_SELECTIONS = ();
    %WEB_BRIDGE = ();
    $JOBS{paused} = 1;
    resume_guard_close_owned_for_unload();
    Irssi::timeout_remove($JOBS{native_resume_guard_release_timer})
        if defined $JOBS{native_resume_guard_release_timer};
    delete $JOBS{native_resume_guard_release_timer};
    Irssi::timeout_remove($JOBS{native_resume_guard_destination_restore_timer})
        if defined $JOBS{native_resume_guard_destination_restore_timer};
    delete $JOBS{native_resume_guard_destination_restore_timer};
    delete $JOBS{native_resume_guard_destination_restore_attempts};
    Irssi::timeout_remove($JOBS{compaction_validation_timer})
        if defined $JOBS{compaction_validation_timer};
    delete $JOBS{compaction_validation_timer};
    cancel_all_outbound_messages('script unloaded before delayed message dispatch');
    queue_cancel_dispatch_timer();
    if (my $run = $JOBS{run_batch}) {
        Irssi::timeout_remove($run->{advance_timer}) if defined $run->{advance_timer};
    }
    delete $JOBS{run_batch};
    delete $JOBS{executing_job_id};
    $CATALOG_WORKER{unloading} = 1;
    abort_searchbot_collection(1, 'needs_attention', 'plugin unloaded while SearchBot archive was in flight');
    stop_session(1);
    cleanup_owned_transfers_for_unload();
    cancel_partial_sealers();
    restore_download_path_for_unload();
    drain_catalog_leases_for_unload();
    my $stopped = $CATALOG_WORKER{loaded}
        ? (eval { FServe::Catalog::WorkerClient::shutdown() } || 0)
        : 0;
    p("Stopped $stopped catalog worker job(s) during unload.") if $stopped;
    $CATALOG_WORKER{loaded} = 0;
    if ($JOBS{coordinator}) {
        eval { $JOBS{coordinator}->close(); };
        delete $JOBS{coordinator};
    }
    if ($JOBS{compaction_coordinator}) {
        eval { $JOBS{compaction_coordinator}->close(); };
        delete $JOBS{compaction_coordinator};
    }
    delete $JOBS{scheduler};
}

for my $setting ('fscrawl_download_dir', 'fscrawl_lists_dir') {
    my $removed = eval { sweep_empty_staging(resolve_irssi_path(Irssi::settings_get_str($setting))) };
    p("Removed $removed empty staging folder(s).") if $removed;
}

p('loaded. /fscrawl for help.');

1;
