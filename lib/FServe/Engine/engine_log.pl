# The engine's log: what each connection said and was told, for the Log page.
#
# A part of the Irssi script engine/dccatlas.pl, in its package;
# the script loads its parts in order (2026-11-03).
package Irssi::Script::dccatlas;

use strict;
use warnings;
use Irssi;
use Encode qw(encode_utf8);
use JSON::PP ();

our (%WEB_BRIDGE_SOURCES);

# The connection log (2026-10-20). Irssi prints why a connection failed
# only to its own screen, which the container discards, and a file server's
# answer to a search is invisible when it is in a form the engine does not
# read. The log keeps, in memory and bounded, what the managed connections'
# servers send to this client, what the engine sends, and Irssi's own
# notices and errors; the web service reads it with log.list. Channel chat,
# the MOTD and anything that could carry a password are left out: the
# password goes in CONNECT and NETWORK ADD, which are never logged, and
# AUTHENTICATE lines are dropped.
our $ENGINE_LOG_LIMIT = 1000;
our $ENGINE_LOG_TEXT_CHARS = 300;
our $ENGINE_LOG_LINES_PER_SECOND = 100;
our $ENGINE_LOG_PAGE_BYTES = 36 * 1024;
our $ENGINE_LOG_PAGE_LINES = 200;
our $ENGINE_LOG_ERROR_SECONDS = 10;
our $ENGINE_LOG_TEST_SECOND;   # tests only: the second the rate limit counts in
my @ENGINE_LOG;
my $ENGINE_LOG_SEQUENCE = 0;
my %ENGINE_LOG_RATE = (second => 0, count => 0, dropped => 0);
my %ENGINE_LOG_LAST_ERROR;   # server tag (or '') => { time, text }
my %ENGINE_LOG_LEVELS;

sub engine_log_level {
    my ($name) = @_;
    return $ENGINE_LOG_LEVELS{$name} //= eval {
        no strict 'refs';
        &{"Irssi::MSGLEVEL_$name"}();
    } || 0;
}

sub engine_log_clean {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $text =~ s/[\x00-\x1f\x7f]+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    $text = substr($text, 0, $ENGINE_LOG_TEXT_CHARS - 1) . "\x{2026}"
        if length($text) > $ENGINE_LOG_TEXT_CHARS;
    return $text;
}

sub engine_log_sources_for_tag {
    my ($tag) = @_;
    return [] unless defined($tag) && length($tag);
    return [sort map { $_->{source_id} } grep {
        lc($_->{server_tag} // '') eq lc($tag)
    } values %WEB_BRIDGE_SOURCES];
}

sub engine_log_flush_dropped {
    my $second = $ENGINE_LOG_TEST_SECOND // int(time);
    return if $second == $ENGINE_LOG_RATE{second};
    my $dropped = $ENGINE_LOG_RATE{dropped};
    %ENGINE_LOG_RATE = (second => $second, count => 0, dropped => 0);
    engine_log_store('engine', undef, [],
        "$dropped lines were not logged: more than $ENGINE_LOG_LINES_PER_SECOND came in one second")
        if $dropped;
}

sub engine_log_store {
    my ($kind, $tag, $source_ids, $text) = @_;
    push @ENGINE_LOG, {
        seq => ++$ENGINE_LOG_SEQUENCE,
        time => eval { require Time::HiRes; Time::HiRes::time() } || time,
        kind => $kind,
        server_tag => defined($tag) ? safe_field($tag) : undef,
        source_ids => $source_ids,
        text => $text,
    };
    splice(@ENGINE_LOG, 0, @ENGINE_LOG - $ENGINE_LOG_LIMIT) if @ENGINE_LOG > $ENGINE_LOG_LIMIT;
}

# One line for the log. $where is a server, a server tag, or undef; lines
# tied to a server are attributed to the sources using it.
sub engine_log_add {
    my ($kind, $where, $text, $source_ids) = @_;
    $text = engine_log_clean($text);
    return unless length $text;
    engine_log_flush_dropped();
    if (++$ENGINE_LOG_RATE{count} > $ENGINE_LOG_LINES_PER_SECOND) {
        $ENGINE_LOG_RATE{dropped}++;
        return;
    }
    my $tag = ref($where) ? $where->{tag} : $where;
    engine_log_store($kind, $tag, $source_ids || engine_log_sources_for_tag($tag), $text);
}

sub engine_log_server_is_managed {
    my ($server) = @_;
    my $tag = lc($server->{tag} // '');
    return 0 unless length $tag;
    for my $source (values %WEB_BRIDGE_SOURCES) {
        return 1 if lc($source->{server_tag} // '') eq $tag;
    }
    return 0;
}

# What a line from the server says, in words, or undef for a line the log
# leaves out.
sub engine_log_describe_incoming {
    my ($server, $line) = @_;
    $line =~ s/\A\@\S+ +//;
    my $prefix = $line =~ s/\A:(\S+) +// ? $1 : '';
    my ($command, $rest) = $line =~ /\A(\S+) *(.*)\z/s or return;
    $command = uc $command;
    my @params;
    while (length $rest) {
        if ($rest =~ /\A:(.*)\z/s) { push @params, $1; last }
        $rest =~ s/\A(\S+) *// or last;
        push @params, $1;
    }
    my $from = $prefix =~ /\A([^!@]+)/ ? $1 : $prefix;
    my $me = lc($server->{nick} // '');
    my $is_me = sub { length($me) && lc($_[0] // '') eq $me };
    my $is_channel = sub { ($_[0] // '') =~ /\A[#&!+]/ };
    if ($command =~ /\A\d{3}\z/) {
        # The welcome and every error; not the MOTD, names or statistics.
        return unless $command eq '001' || $command >= 400;
        shift @params;
        return "$command " . join(' ', @params);
    }
    if ($command eq 'PRIVMSG' || $command eq 'NOTICE') {
        my ($target, $text) = @params;
        # Channel messages are chat; a channel notice is usually a bot's.
        return if $command eq 'PRIVMSG' && $is_channel->($target);
        my $who = length($from) ? $from : 'the server';
        my $in = $is_channel->($target) ? " in $target" : '';
        if (defined($text) && $text =~ /\A\x01([^\x01]*)\x01?\z/) {
            return ($command eq 'NOTICE' ? 'CTCP reply' : 'CTCP') . " from $who$in: $1";
        }
        return ($command eq 'NOTICE' ? 'Notice' : 'Message') . " from $who$in: " . ($text // '');
    }
    if ($command eq 'JOIN' || $command eq 'PART' || $command eq 'QUIT' || $command eq 'NICK') {
        return unless $is_me->($from);
        return "$command (this client) " . join(' ', @params);
    }
    if ($command eq 'KICK') {
        return unless $is_me->($params[1]);
        return "Kicked from $params[0] by $from: " . ($params[2] // '');
    }
    return 'CAP ' . join(' ', @params[1 .. $#params]) if $command eq 'CAP' && @params > 1;
    return "$command " . join(' ', @params)
        if $command eq 'ERROR' || $command eq 'KILL' || $command eq 'INVITE';
    return;
}

sub sig_engine_log_incoming {
    my ($server, $line) = @_;
    return unless ref($server) && defined($line) && engine_log_server_is_managed($server);
    my $text = engine_log_describe_incoming($server, $line);
    engine_log_add('received', $server, $text) if defined $text;
}

sub engine_log_sent {
    my ($server, $target, $text) = @_;
    return unless ref($server) && engine_log_server_is_managed($server);
    engine_log_add('sent', $server, 'To ' . ($target // '?') . ': ' . ($text // ''));
}

sub sig_engine_log_own_public { engine_log_sent($_[0], $_[2], $_[1]) }
sub sig_engine_log_own_private { engine_log_sent($_[0], $_[2], $_[1]) }
sub sig_engine_log_own_notice { engine_log_sent($_[0], $_[2], 'notice ' . ($_[1] // '')) }
sub sig_engine_log_own_ctcp {
    my ($server, $command, $data, $target) = @_;
    engine_log_sent($server, $target, 'CTCP ' . ($command // '') .
        (defined($data) && length($data) ? " $data" : ''));
}

# A raw PRIVMSG or NOTICE the engine wrote itself, as the search-bot
# request is. Nothing else is sent raw.
sub engine_log_sent_raw {
    my ($server, $wire) = @_;
    return unless defined($wire) && $wire =~ /\A(PRIVMSG|NOTICE) (\S+) :(.*)\z/s;
    engine_log_sent($server, $2, ($1 eq 'NOTICE' ? 'notice ' : '') . $3);
}

# Irssi's own notices and errors: connecting, connected, lost, and why a
# connection failed, including TLS errors, which are not tied to a server.
sub sig_engine_log_print {
    my ($dest, $text, $stripped) = @_;
    return unless ref($dest);
    my $level = $dest->{level} || 0;
    my $error = $level & engine_log_level('CLIENTERROR');
    return unless $error ||
        ($level & (engine_log_level('CLIENTNOTICE') | engine_log_level('DCC')));
    my $server = $dest->{server};
    if (ref $server) {
        return unless engine_log_server_is_managed($server);
    } else {
        return unless $error;
        $server = undef;
    }
    my $clean = engine_log_clean($stripped // $text);
    # The theme's line start: a time, "-!-", and "Irssi:" on Irssi's own lines.
    $clean =~ s/\A(?:\d\d:\d\d(?::\d\d)? +)?(?:-!- +)?(?:Irssi: +)?//;
    # A GLib warning's "(domain) warning" label, as on a TLS failure.
    $clean =~ s/\A(?:GLib +)?\([^()]*\) +(?:warning|critical|error|message):? +//i;
    return unless length $clean;
    $ENGINE_LOG_LAST_ERROR{$server ? lc($server->{tag} // '') : ''} =
        { time => time, text => $clean } if $error;
    engine_log_add($error ? 'error' : 'irssi', $server, $clean);
}

# Why Irssi says a connection failed: its error for that server, or a
# recent error not tied to any (a TLS failure), when there is one.
sub engine_log_recent_error {
    my ($server) = @_;
    for my $key (lc($server->{tag} // ''), '') {
        my $last = $ENGINE_LOG_LAST_ERROR{$key} or next;
        next if time - $last->{time} > $ENGINE_LOG_ERROR_SECONDS;
        delete $ENGINE_LOG_LAST_ERROR{$key};
        my $text = $last->{text};
        $text = $1 if $text =~ /\AUnable to connect server .* \[(.*)\]\z/;
        return substr($text, 0, 200);
    }
    return;
}

sub web_bridge_log_page {
    my ($after, $limit) = @_;
    engine_log_flush_dropped();
    my @lines;
    my $bytes = 0;
    my $more = 0;
    for my $entry (@ENGINE_LOG) {
        next unless $entry->{seq} > $after;
        my $size = length(encode_utf8($entry->{text})) + 160;
        if (@lines >= $limit || (@lines && $bytes + $size > $ENGINE_LOG_PAGE_BYTES)) {
            $more = 1;
            last;
        }
        $bytes += $size;
        push @lines, { %$entry, source_ids => [@{$entry->{source_ids} || []}] };
    }
    return {
        now => time(),
        first_seq => @ENGINE_LOG ? $ENGINE_LOG[0]{seq} : $ENGINE_LOG_SEQUENCE + 1,
        last_seq => $ENGINE_LOG_SEQUENCE,
        more => $more ? JSON::PP::true : JSON::PP::false,
        lines => \@lines,
    };
}

1;
