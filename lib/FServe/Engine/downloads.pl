# Where downloads go: staging folders, finalizing, and the download path.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use Digest::SHA ();
use Cwd qw(abs_path);
use File::Copy ();
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec ();
use POSIX qw(strftime);

our (%S, %SEARCHBOT_DIRECT, %TRANSFERS, $DOWNLOAD_PATH_OWNER, $old_dcc_download_path);

my $DOWNLOAD_REQUEST_SEQUENCE = 0;
my $download_sequence = 0;

sub sanitize_local_component {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s{[\x00-\x1f\x7f<>:"/\\|?*]}{_}g;
    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    $value =~ s/[. ]+$//;
    $value = '_' if !length($value) || $value eq '.' || $value eq '..';
    $value = '_' . $value
        if $value =~ /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i;
    return $value;
}

sub new_pending_download {
    my ($file) = @_;
    return unless $file && ref($file) eq 'HASH';
    return {
        %$file,
        download_dir       => $S{download_dir},
        network_id         => $S{network_id},
        session_server_tag => $S{server_tag},
        server_nick        => $S{nick},
        trigger_raw        => $file->{trigger_raw} // $S{catalog_trigger_raw} // $S{trigger_raw} // 'crawl',
        log_file           => $S{log_file},
        session_generation => $S{generation},
        request_token      => ++$DOWNLOAD_REQUEST_SEQUENCE,
    };
}

sub has_active_download_transfer {
    return scalar keys %TRANSFERS;
}

# The transfers that hold the current session. A session the web started
# alongside a transfer already arriving from another file server (web_parallel,
# 2026-10-22) is held only by its own; any other session by every transfer.
sub session_transfer_count {
    return has_active_download_transfer() unless $S{web_parallel};
    my $generation = $S{generation} || 0;
    return scalar grep { ($_->{generation} || 0) == $generation } values %TRANSFERS;
}

# A request's staging folder under .incoming is removed once it is empty and
# done with (2026-10-29): at once after its file is published, and otherwise
# when it has stood empty two hours, longer than any request waits for its
# file. A folder that still holds anything, such as a partial, is kept.
our $STAGING_EMPTY_SECONDS = 2 * 3600;

sub remove_empty_staging {
    my ($staging) = @_;
    return unless defined($staging) && length($staging) && -d $staging && !-l $staging;
    my @parts = File::Spec->splitdir(File::Spec->canonpath($staging));
    return unless @parts >= 2 && $parts[-2] eq '.incoming' &&
        $parts[-1] =~ /\A[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+\z/;
    rmdir $staging;   # only succeeds when empty
}

sub sweep_empty_staging {
    my ($download_dir) = @_;
    return unless defined($download_dir) && length($download_dir);
    my $incoming = File::Spec->catdir($download_dir, '.incoming');
    return unless -d $incoming && !-l $incoming;
    opendir(my $dh, $incoming) or return;
    my @names = grep { /\A[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+\z/ } readdir($dh);
    closedir($dh);
    my $removed = 0;
    for my $name (@names) {
        my $staging = File::Spec->catdir($incoming, $name);
        my @stat = lstat($staging);
        next unless @stat && -d _ && !-l _;
        next if time() - $stat[9] < $STAGING_EMPTY_SECONDS;
        $removed++ if rmdir $staging;
    }
    return $removed;
}

sub prepare_download_staging {
    my ($file) = @_;
    my $download_dir = $file->{download_dir} // $S{download_dir} if $file;
    return 0 unless $file && $download_dir;
    if ($file->{staging_dir} && -d $file->{staging_dir} && !-l $file->{staging_dir}) {
        Irssi::settings_set_str('dcc_download_path', $file->{staging_dir});
        return 1;
    }

    sweep_empty_staging($download_dir);
    my $incoming = File::Spec->catdir($download_dir, '.incoming');
    my $created = eval {
        die 'incoming staging directory is a symbolic link' if -l $incoming;
        make_path($incoming) unless -d $incoming;
        die 'incoming staging directory is not a regular directory' unless -d $incoming && !-l $incoming;
        while (1) {
            my $request_id = strftime('%Y%m%d-%H%M%S', localtime()) . '-' . $$ . '-' . ++$download_sequence;
            my $staging = File::Spec->catdir($incoming, $request_id);
            next if -e $staging;
            make_path($staging);
            die 'new staging directory is not a regular directory' unless -d $staging && !-l $staging;
            $file->{staging_dir} = $staging;
            last;
        }
        1;
    };
    unless ($created) {
        my $error = $@ || 'could not create staging directory';
        $error =~ s/[\r\n]+/ /g;
        p("Could not prepare a staging directory: $error");
        log_line('DOWNLOAD_STAGE_FAILED', $error);
        return 0;
    }

    Irssi::settings_set_str('dcc_download_path', $file->{staging_dir});
    log_line('DOWNLOAD_STAGE', $file->{staging_dir});
    return 1;
}

sub restore_download_path_to_base {
    return unless $S{download_dir};
    Irssi::settings_set_str('dcc_download_path', $S{download_dir});
}

sub staged_download_source {
    my ($file, $dcc) = @_;
    return unless $file && $file->{staging_dir} && $dcc;
    my $raw_source = $dcc->{file} // '';
    return unless length($raw_source) && -f $raw_source && !-l $raw_source;

    my $stage = abs_path($file->{staging_dir});
    my $source = abs_path($raw_source);
    return unless defined($stage) && defined($source) && -d $stage && !-l $file->{staging_dir};
    my $relative = File::Spec->abs2rel($source, $stage);
    return if File::Spec->file_name_is_absolute($relative);
    my @relative_parts = File::Spec->splitdir($relative);
    return if !@relative_parts || grep { $_ eq File::Spec->updir() } @relative_parts;
    my @source_stat = stat($source);
    return unless @source_stat && -f _;
    return $source;
}

sub staged_download_target {
    my ($file, $dcc, $accepted_name) = @_;
    return unless $file && $file->{staging_dir} && $dcc;
    my $raw_target = $dcc->{file} // '';
    my $expected_name = defined($accepted_name)
        ? $accepted_name
        : ($file->{name} // $dcc->{arg} // '');
    return unless length($raw_target) && length($expected_name) &&
        ($dcc->{arg} // '') eq $expected_name && basename($raw_target) eq $expected_name;

    my $stage = abs_path($file->{staging_dir});
    my $parent = abs_path(dirname($raw_target));
    return unless defined($stage) && defined($parent) && $stage eq $parent &&
        -d $stage && !-l $file->{staging_dir};
    my $target = File::Spec->catfile($stage, $expected_name);
    if (-e $target || -l $target) {
        return if -l $target;
        my @target_stat = lstat($target);
        return unless @target_stat && -f _;
        my $physical_target = abs_path($target);
        return unless defined($physical_target) && $physical_target eq $target;
    }
    return $target;
}

# A published file, and a folder made for one, are readable as the umask
# allows (2026-10-28): the downloads folder is the operator's to share, as on
# unRAID, where other users and apps read it.
sub _copy_to_exclusive_destination {
    my ($source, $destination) = @_;
    return 0 unless sysopen(my $out, $destination, O_WRONLY | O_CREAT | O_EXCL, 0666);
    binmode $out;
    my $copied = File::Copy::copy($source, $out);
    my $closed = close $out;
    unless ($copied && $closed) {
        unlink $destination;
        return 0;
    }
    unlink $source;
    return 1;
}

sub _safe_local_filename {
    my ($name) = @_;
    return 0 unless defined($name) && length($name) && length($name) <= 255;
    return 0 if $name eq '.' || $name eq '..' || $name =~ m{[/\\]};
    return 0 if $name =~ /[\x00-\x1f\x7f<>:"|?*]/ || $name =~ /[. ]\z/;
    return 0 if $name =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)/i;
    return 1;
}

sub direct_searchbot_destination_dir {
    my ($file) = @_;
    my $download_dir = $file->{download_dir};
    return unless defined($download_dir) && length($download_dir);
    my $root = File::Spec->rel2abs($download_dir);
    make_path($root) unless -d $root;
    return if -l $root || !-d $root;
    my $physical_root = abs_path($root);
    return unless defined($physical_root) && length($physical_root);
    # A row an @find answer gave is filed by how it was found (2026-10-20).
    my @components = map { sanitize_local_component($_) } (
        $file->{destination_network} // $file->{network_id} // 'network',
        $file->{expected_sender} // 'server',
        # A list, and a file asked for from one, under "@list" (2026-10-27).
        $file->{from_find} ? ('@find')
            : $file->{list_request} || $file->{from_list} ? ('@list')
            : ('SearchBot', $file->{searchbot_collection_id} // 'collection'),
    );
    my $current = $root;
    for my $component (@components) {
        $current = File::Spec->catdir($current, $component);
        if (!-e $current) {
            mkdir($current, 0777) or return;
        }
        return if -l $current || !-d $current;
        my $physical = abs_path($current);
        my $prefix = $physical_root;
        $prefix =~ s{[/\\]+\z}{};
        my $within = defined($physical) && ($physical eq $physical_root ||
            index($physical, $prefix . '/') == 0 || index($physical, $prefix . '\\') == 0);
        return unless $within;
    }
    return $current;
}

sub finalize_download {
    my ($file, $dcc) = @_;
    my $download_dir = $file->{download_dir} // $S{download_dir};
    my $source = staged_download_source($file, $dcc);
    unless ($source) {
        log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED', 'completed transfer was not found inside its request staging directory');
        return;
    }
    $file->{phase6_staging_path} = $source;

    my ($basename, $destination_dir);
    if (($file->{retrieval_protocol} // '') eq 'searchbot_direct_send') {
        $basename = sanitize_local_component($file->{name});
        $destination_dir = direct_searchbot_destination_dir($file);
        unless ($destination_dir && _safe_local_filename($file->{name})) {
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED',
                'direct SearchBot destination could not be created safely');
            return;
        }
    } else {
        my @remote_parts = grep { length } split m{/+}, ($file->{path} // '');
        unless (@remote_parts) {
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED', 'remote path was empty');
            return;
        }
        $basename = sanitize_local_component(pop @remote_parts);
        my @destination_parts = map { sanitize_local_component($_) } (
            ($file->{destination_network} // $file->{network_id} //
                $file->{session_server_tag} // 'network'),
            ($file->{server_nick} // 'server'),
            ($file->{trigger_raw} // 'trigger'),
            @remote_parts,
        );
        $destination_dir = File::Spec->catdir($download_dir, @destination_parts);
        my $made_dir = eval {
            make_path($destination_dir) unless -d $destination_dir;
            1;
        };
        unless ($made_dir) {
            my $error = $@ || 'could not create final destination directory';
            $error =~ s/[\r\n]+/ /g;
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED', $error);
            return;
        }
    }

    my ($stem, $extension) = ($basename, '');
    if ($basename =~ /^(.*?)(\.[^.]+)$/ && length $1) {
        ($stem, $extension) = ($1, $2);
    }
    for my $suffix (0 .. 9999) {
        my $name = $suffix ? "$stem-$suffix$extension" : $basename;
        my $destination = File::Spec->catfile($destination_dir, $name);
        # A list, or a result list, newer than one of its name kept before
        # takes its place (2026-10-28); a plain file only, nothing else.
        if (!$suffix && $file->{replace_same_name} && -f $destination && !-l $destination) {
            if (unlink $destination) {
                log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_REPLACING', $destination);
            }
        }
        next if -e $destination;

        my $observed_size = -s $source;
        unless (defined($observed_size) && $observed_size =~ /\A\d+\z/) {
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED',
                'staged file size could not be measured');
            return;
        }
        my $digest = $file->{local_sha256};
        unless (defined($digest) && $digest =~ /\A[a-f0-9]{64}\z/i) {
            my $hash_ok = eval {
                open my $fh, '<:raw', $source or die "cannot open staged file for hashing: $!";
                my $sha = Digest::SHA->new(256);
                $sha->addfile($fh);
                close $fh or die "cannot close staged file after hashing: $!";
                $digest = $sha->hexdigest;
                1;
            };
            unless ($hash_ok && defined($digest) && $digest =~ /\A[a-f0-9]{64}\z/i) {
                my $error = $@ || 'staged file SHA-256 could not be computed';
                $error =~ s/[\r\n]+/ /g;
                log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED', $error);
                return;
            }
            $file->{local_sha256} = lc($digest);
            $digest = lc($digest);
        }
        unless (reserve_finalization($file, $source, $destination,
                $observed_size, $digest)) {
            return;
        }

        if (link($source, $destination)) {
            unless (finish_finalization($file, 1, $destination, $observed_size,
                    $digest, 'published by exclusive hard link')) {
                log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_PUBLISHED_UNRECORDED',
                    'destination=[' . $destination . '] staging=[' . $source . '] size=' .
                    $observed_size . ' sha256=' . $digest);
                return;
            }
            unlink $source or log_to_path($file->{log_file} // $S{log_file},
                'DOWNLOAD_STAGE_CLEANUP_FAILED', "completed staging copy retained at $source: $!");
            remove_empty_staging($file->{staging_dir});
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZED', $destination);
            return $destination;
        }
        if (-e $destination) {
            finish_finalization($file, 0, $destination, $observed_size,
                $digest, 'destination appeared after durable reservation');
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED',
                'reserved destination became occupied; staged data was retained');
            return;
        }

        if (_copy_to_exclusive_destination($source, $destination)) {
            unless (finish_finalization($file, 1, $destination, $observed_size,
                    $digest, 'published by exclusive copy')) {
                log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_PUBLISHED_UNRECORDED',
                    'destination=[' . $destination . '] staging=[' . $source . '] size=' .
                    $observed_size . ' sha256=' . $digest);
                return;
            }
            unlink $source or log_to_path($file->{log_file} // $S{log_file},
                'DOWNLOAD_STAGE_CLEANUP_FAILED', "completed staging copy retained at $source: $!");
            remove_empty_staging($file->{staging_dir});
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZED', $destination);
            return $destination;
        }
        if (-e $destination) {
            finish_finalization($file, 0, $destination, $observed_size,
                $digest, 'exclusive copy failed after creating reserved destination');
            log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED',
                'reserved destination may contain partial bytes; staged data was retained');
            return;
        }
        finish_finalization($file, 0, $destination, $observed_size,
            $digest, 'exclusive publication failed');
        log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED', "could not move staged file to $destination: $!");
        return;
    }

    log_to_path($file->{log_file} // $S{log_file}, 'DOWNLOAD_FINALIZE_FAILED', 'could not find an unused collision-safe destination name');
    return;
}

sub restore_download_path {
    if ($DOWNLOAD_PATH_OWNER) {
        if (defined $old_dcc_download_path) {
            # The current DCC owner may belong to a different IRC connection
            # (or be a detached transfer surviving this FServe session). Keep
            # its selected staging path intact and hand it the eventual
            # restore target instead of changing a setting it still owns.
            $DOWNLOAD_PATH_OWNER->{restore_to} = $old_dcc_download_path;
            if (($DOWNLOAD_PATH_OWNER->{kind} // '') eq
                    'phase6_native_resume') {
                my $current = Irssi::settings_get_str('dcc_download_path');
                if (defined($S{download_dir}) &&
                        $current eq $S{download_dir}) {
                    $DOWNLOAD_PATH_OWNER->{restore_if_current} = $current;
                    $DOWNLOAD_PATH_OWNER->{restore_on_unload} = 1;
                    delete $DOWNLOAD_PATH_OWNER->{external_setting_preserved};
                } else {
                    $DOWNLOAD_PATH_OWNER->{restore_on_unload} = 0;
                    $DOWNLOAD_PATH_OWNER->{external_setting_preserved} = 1;
                }
            }
            undef $old_dcc_download_path;
        }
        return;
    }
    if (defined $old_dcc_download_path) {
        Irssi::settings_set_str('dcc_download_path', $old_dcc_download_path);
        undef $old_dcc_download_path;
    }
}

sub release_download_path_owner {
    my ($transfer) = @_;
    return unless $DOWNLOAD_PATH_OWNER && $transfer;
    return unless $DOWNLOAD_PATH_OWNER->{key} eq $transfer->{key};

    if (($transfer->{kind} // '') eq 'searchbot_content') {
        my $request = \%SEARCHBOT_DIRECT;
        return unless ($DOWNLOAD_PATH_OWNER->{request_id} // '') eq
            ($transfer->{request_id} // '') &&
            ($request->{request_id} // '') eq ($transfer->{request_id} // '');
        Irssi::settings_set_str('dcc_download_path', $DOWNLOAD_PATH_OWNER->{restore_to})
            if defined $DOWNLOAD_PATH_OWNER->{restore_to};
        $request->{path_owner_key} = undef;
        $request->{path_restored} = 1;
        undef $DOWNLOAD_PATH_OWNER;
        return;
    }

    my $target;
    if (session_is_current($transfer->{generation}) &&
        $S{pending_download} &&
        ($S{pending_download}{request_token} || 0) == $transfer->{request_token}) {
        $target = $S{download_dir};
    } else {
        $target = $DOWNLOAD_PATH_OWNER->{restore_to};
    }
    Irssi::settings_set_str('dcc_download_path', $target) if defined $target;
    undef $DOWNLOAD_PATH_OWNER;
}

sub restore_download_path_for_unload {
    if (ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
            ($DOWNLOAD_PATH_OWNER->{kind} // '') eq 'phase6_native_resume' &&
            ($DOWNLOAD_PATH_OWNER->{override_active} ||
             $DOWNLOAD_PATH_OWNER->{restore_on_unload})) {
        my $restored = 0;
        for (1 .. 20) {
            $restored = eval {
                resume_guard_restore_owned_setting(
                    $DOWNLOAD_PATH_OWNER);
            } ? 1 : 0;
            last if $restored;
        }
        unless ($restored) {
            p('Unload could not confirm restoration of the native-resume download directory; destination ownership is retained in memory.');
            return 0;
        }
    }
    my $preserve_external_setting = ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
        ($DOWNLOAD_PATH_OWNER->{kind} // '') eq 'phase6_native_resume' &&
        $DOWNLOAD_PATH_OWNER->{external_setting_preserved};
    if (ref($DOWNLOAD_PATH_OWNER) eq 'HASH' &&
            ($DOWNLOAD_PATH_OWNER->{kind} // '') eq 'phase6_native_resume') {
        my $current = eval { Irssi::settings_get_str('dcc_download_path') };
        my $setting_is_still_owned = defined($current) &&
            defined($DOWNLOAD_PATH_OWNER->{restore_if_current}) &&
            $current eq $DOWNLOAD_PATH_OWNER->{restore_if_current};
        if (!$preserve_external_setting &&
                $DOWNLOAD_PATH_OWNER->{restore_on_unload} &&
                $setting_is_still_owned) {
            my $restore_to = $DOWNLOAD_PATH_OWNER->{restore_to};
            my $restored = 0;
            for (1 .. 20) {
                eval { Irssi::settings_set_str('dcc_download_path', $restore_to); 1 };
                my $value = eval { Irssi::settings_get_str('dcc_download_path') };
                if (defined($value) && $value eq $restore_to) {
                    $restored = 1;
                    last;
                }
            }
            unless ($restored) {
                p('Unload could not confirm restoration of the handed-off FServe download directory; cleanup ownership is retained in memory.');
                return 0;
            }
        }
        undef $old_dcc_download_path;
        undef $DOWNLOAD_PATH_OWNER;
        return 1;
    }
    my $restore_to;
    unless ($preserve_external_setting) {
        $restore_to = defined($old_dcc_download_path)
            ? $old_dcc_download_path
            : $DOWNLOAD_PATH_OWNER
                ? $DOWNLOAD_PATH_OWNER->{restore_to} : undef;
    }
    if (defined $restore_to) {
        my $restored = 0;
        for (1 .. 20) {
            eval { Irssi::settings_set_str('dcc_download_path', $restore_to); 1 };
            my $current = eval { Irssi::settings_get_str('dcc_download_path') };
            if (defined($current) && $current eq $restore_to) {
                $restored = 1;
                last;
            }
        }
        unless ($restored) {
            p('Unload could not confirm restoration of dcc_download_path; cleanup ownership is retained in memory.');
            return 0;
        }
    }
    undef $old_dcc_download_path;
    undef $DOWNLOAD_PATH_OWNER;
    return 1;
}

1;
