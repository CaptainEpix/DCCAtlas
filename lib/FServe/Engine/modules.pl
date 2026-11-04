# Loading the engine's modules on first use, and small shared checks.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use File::Path qw(make_path);
use File::Spec ();

our (%CATALOG, %CATALOG_WORKER, %FIND, %MANIFEST, %JOBS, %S, %SEARCHBOT_MODULES);

my %PARSER;
my %DCC_POLICY;

sub load_job_modules {
    return 1 if $JOBS{modules_loaded};
    my $library_dir = add_library_dir_to_inc();
    my $loaded = eval {
        require FServe::ConnectionIdentity;
        require FServe::Transfer::Coordinator;
        require FServe::Transfer::Scheduler;
        require FServe::Protocol::SysResetStatus;
        require FServe::Transfer::Resume;
        require FServe::Transfer::NativeResumeGuard;
        require FServe::Catalog::WorkerClient;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'the job modules could not be loaded';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load the job coordinator from [$library_dir]: $error");
        return 0;
    }
    $JOBS{modules_loaded} = 1;
    $JOBS{native_resume_guard} ||=
        FServe::Transfer::NativeResumeGuard->new();
    return 1;
}

sub jobs_ready {
    return 0 if $JOBS{compaction_active};
    return 1 if $JOBS{coordinator} && $JOBS{coordinator}->journal->healthy;
    return 0 unless load_job_modules();
    return 0 if $JOBS{initialization_failed};
    my $state_dir = resolve_irssi_path(Irssi::settings_get_str('fscrawl_state_dir'));
    my $opened = eval {
        die 'state directory is a symbolic link' if -l $state_dir;
        make_path($state_dir) unless -d $state_dir;
        die 'state directory is not a regular directory' unless -d $state_dir && !-l $state_dir;
        my $path = File::Spec->catfile($state_dir, 'requests.jsonl');
        my $journal_max_bytes = Irssi::settings_get_int('fscrawl_journal_max_bytes');
        $journal_max_bytes = 1073741824 unless $journal_max_bytes > 0;
        $journal_max_bytes = 1048576 if $journal_max_bytes < 1048576;
        $journal_max_bytes = 2147483647 if $journal_max_bytes > 2147483647;
        $JOBS{coordinator} = FServe::Transfer::Coordinator::open_coordinator(
            path => $path, max_journal_bytes => $journal_max_bytes);
        $JOBS{coordinator}->journal->set_unhealthy_callback(sub {
            my ($reason) = @_;
            withdraw_pending_outbound_messages(
                'durable journal became unhealthy; no pending application message may be sent: ' .
                    safe_field($reason // 'journal integrity or write failure'));
        });
        die 'request journal failed its post-open ownership check'
            unless $JOBS{coordinator}->journal->healthy;
        my %scheduler_args;
        $scheduler_args{now} = sub { Irssi::test_monotonic_now() }
            if Irssi->can('test_monotonic_now');
        $JOBS{scheduler} = FServe::Transfer::Scheduler->new(%scheduler_args);
        $JOBS{state_dir} = $state_dir;
        1;
    };
    unless ($opened) {
        my $error = $@ || 'state directory or journal could not be opened';
        $error =~ s/[\r\n]+/ /g;
        $JOBS{initialization_failed} = 1;
        p("The job journal is closed: durable request history is unavailable; no retrieval request may be sent. $error");
        return 0;
    }
    for my $recovered (@{$JOBS{coordinator}->recovery_events}) {
        p("Recovered job $recovered->{id} as $recovered->{state}; no request or live connection was restored.");
    }
    return 1;
}

sub load_fserve_parser {
    return 1 if $PARSER{loaded};

    my $library_dir = add_library_dir_to_inc();
    my $loaded = eval {
        require FServe::Parser;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'module load failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load the FServe line parser from [$library_dir]: $error");
        p('Set fscrawl_library_dir to the project lib directory.');
        return 0;
    }

    $PARSER{loaded} = 1;
    return 1;
}

sub load_dcc_policy {
    return 1 if $DCC_POLICY{loaded};

    my $library_dir = add_library_dir_to_inc();
    my $loaded = eval {
        require FServe::DccPolicy;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'module load failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load DCC safety policy from [$library_dir]: $error");
        p('Set fscrawl_library_dir to the project lib directory.');
        return 0;
    }

    $DCC_POLICY{loaded} = 1;
    return 1;
}

sub load_catalog_module {
    return 1 if $CATALOG{loaded};

    my $library_dir = add_library_dir_to_inc();
    my $loaded = eval {
        require FServe::Catalog;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'module load failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load the crawl catalog module from [$library_dir]: $error");
        p('Set fscrawl_library_dir to the project lib directory.');
        return 0;
    }

    my $store = FServe::Catalog::new_store();
    my $output_dir = resolve_irssi_path(
        Irssi::settings_get_str('fscrawl_output_dir')
    );
    my $path = File::Spec->catfile($output_dir, 'catalog.jsonl');
    my $dir_ready = eval {
        make_path($output_dir) unless -d $output_dir;
        1;
    };
    unless ($dir_ready) {
        my $error = $@ || 'could not create the catalog output directory';
        $error =~ s/[\r\n]+/ /g;
        p("Persistent catalog is read-only for this session: $error");
    }

    my ($observations, $invalid) = ([], 0);
    if (-e $path) {
        my $read_ok = eval {
            ($observations, $invalid) = FServe::Catalog::load_jsonl($path);
            1;
        };
        unless ($read_ok) {
            my $error = $@ || 'catalog read failed';
            $error =~ s/[\r\n]+/ /g;
            p("Could not read persistent catalog [$path]: $error");
            $observations = [];
            $invalid++;
        }
    }

    for my $observation (@$observations) {
        my $added = eval {
            FServe::Catalog::add_record($store, $observation);
            1;
        };
        unless ($added) {
            $invalid++;
        }
    }
    p("Loaded " . FServe::Catalog::record_count($store) . " unique records from the local catalog.")
        if FServe::Catalog::record_count($store);
    p("Skipped $invalid invalid local catalog record(s).") if $invalid;

    $CATALOG{store} = $store;
    $CATALOG{jsonl_path} = $path;
    $CATALOG{loaded} = 1;
    return 1;
}

sub load_find_parser {
    return 1 if $FIND{parser_loaded};

    my $library_dir = add_library_dir_to_inc();

    my $loaded = eval {
        require FServe::Discovery::SysResetFind;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'module load failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load the \@Find parser from [$library_dir]: $error");
        p('Set fscrawl_library_dir to the project lib directory.');
        return 0;
    }

    $FIND{parser_loaded} = 1;
    return 1;
}

sub load_searchbot_provider {
    return 1 if $SEARCHBOT_MODULES{loaded};

    my $library_dir = add_library_dir_to_inc();
    my $loaded = eval {
        require FServe::Discovery::SearchBot;
        require FServe::Discovery::SearchBotOffer;
        require FServe::Discovery::SearchBotArchive;
        require FServe::Discovery::SearchBotRequest;
        require FServe::DccPolicy;
        require FServe::Model;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'module load failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load the SearchBot provider or ZIP dependencies from [$library_dir]: $error");
        p('Set fscrawl_library_dir to the project lib directory and ensure IO::Uncompress::Unzip and Compress::Raw::Zlib are installed in Irssi Perl.');
        return 0;
    }

    $SEARCHBOT_MODULES{loaded} = 1;
    return 1;
}

sub load_manifest_provider {
    return 1 if $MANIFEST{loaded};

    my $library_dir = add_library_dir_to_inc();
    my $loaded = eval {
        require FServe::Discovery::Manifest;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'module load failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load the manifest discovery provider from [$library_dir]: $error");
        p('Set fscrawl_library_dir to the project lib directory.');
        return 0;
    }

    $MANIFEST{provider} = FServe::Discovery::Manifest::new_provider();
    $MANIFEST{loaded} = 1;
    return 1;
}

sub load_catalog_worker_client {
    return 1 if $CATALOG_WORKER{loaded};
    my $library_dir = add_library_dir_to_inc();
    my $loaded = eval {
        require FServe::Catalog::WorkerClient;
        1;
    };
    unless ($loaded) {
        my $error = $@ || 'module load failed';
        $error =~ s/[\r\n]+/ /g;
        p("Could not load the asynchronous catalog worker client from [$library_dir]: $error");
        p('Set fscrawl_library_dir to the project lib directory.');
        return 0;
    }
    $CATALOG_WORKER{loaded} = 1;
    return 1;
}

sub ensure_dirs {
    $S{output_dir} = resolve_irssi_path(Irssi::settings_get_str('fscrawl_output_dir'));
    $S{download_dir} = resolve_irssi_path(Irssi::settings_get_str('fscrawl_download_dir'));
    make_path($S{output_dir}) unless -d $S{output_dir};
    make_path($S{download_dir}) unless -d $S{download_dir};
}

# File servers seen in a source's channel (web M3, Y1). Only SysReset 2.55's
# own advert (FServe::Discovery::SysResetAdvert), FServe.pl 2.0.0's
# (FServe::Discovery::FservePlAdvert) and, since 2026-10-27, a list server's
# "@Nick" (FServe::Discovery::ListAdvert) are read, and nothing is ever sent
# because of one. What is kept is bounded: a fixed number of file servers
# per source, the first line of a split advert for a few seconds only.
our %WEB_BRIDGE_ADVERTS;
my %ADVERT_READER;
our $ADVERT_MAX_SERVERS = 200;
our $ADVERT_MAX_PENDING = 50;
our $ADVERT_HEAD_WAIT_SECONDS = 15;
our $ADVERT_LIST_LIMIT = 25;

sub load_advert_reader {
    return 1 if $ADVERT_READER{loaded};
    return 0 if $ADVERT_READER{failed};
    add_library_dir_to_inc();
    if (eval {
        require FServe::Discovery::SysResetAdvert;
        require FServe::Discovery::FservePlAdvert;
        require FServe::Discovery::ListAdvert;
        require FServe::ConnectionIdentity;
        1;
    }) {
        return $ADVERT_READER{loaded} = 1;
    }
    my $error = $@ || 'module load failed';
    $error =~ s/[\r\n]+/ /g;
    $ADVERT_READER{failed} = 1;
    p("Could not load the advert reader: $error");
    return 0;
}

sub bounded_timeout_setting {
    my ($key, $default, $minimum_ms, $maximum_ms) = @_;
    my $value = Irssi::settings_get_int($key);
    $value = $default unless defined($value) && $value > 0;
    $value = $minimum_ms if $value < $minimum_ms;
    $value = $maximum_ms if $value > $maximum_ms;
    return $value;
}

1;
