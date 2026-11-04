package FServe::Discovery::SearchBotRequest;

use strict;
use warnings;
use bytes ();
use Digest::SHA qw(sha256_hex);
use Exporter qw(import);
use Scalar::Util qw(refaddr reftype);
use FServe::ConnectionIdentity qw(same_irc_identity);

our @EXPORT_OK = qw(validate_candidate validate_content_offer tombstone_key tombstone_matches);

# What a list request ("@Nick", 2026-10-27) reserves in place of a file name:
# the sender's list, whatever it is named. No DCC file name can hold \x1f.
our $LIST_TUPLE_NAME = "\x1flist";

sub _refusal {
    return { type => 'refusal', reason => $_[0] };
}

sub _safe_basename {
    my ($name) = @_;
    return 0 unless defined($name) && !ref($name) && length($name) <= 255;
    return 0 if $name eq '.' || $name eq '..' || $name =~ m{[/\\]};
    return 0 if $name =~ /[\x00-\x1f\x7f<>:"|?*]/;
    return 0 if $name =~ /[. ]\z/ || $name =~ /\A\s/;
    return 0 if $name =~ /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)/i;
    return 1;
}

sub validate_candidate {
    my ($candidate, %args) = @_;
    return _refusal('SearchBot candidate is invalid') unless ref($candidate) eq 'HASH';
    return _refusal($candidate->{direct_refusal_reason} // 'result row is not eligible for direct sending')
        unless $candidate->{direct_requestable};
    my $payload = $candidate->{request_line};
    return _refusal('original SearchBot request line is missing')
        unless defined($payload) && !ref($payload) && length($payload);
    return _refusal('original SearchBot request digest does not match its bytes')
        if defined($candidate->{request_line_digest}) &&
            $candidate->{request_line_digest} ne sha256_hex($payload);
    return _refusal('original SearchBot request line is not printable ASCII')
        if $payload =~ /[^\x20-\x7e]/;
    return _refusal('request line does not begin with its parsed route trigger')
        unless defined($candidate->{route_trigger}) &&
            $candidate->{route_trigger} =~ /\A![^\s\x00-\x1f\x7f]{1,127}\z/ &&
            $payload =~ /\A\Q$candidate->{route_trigger}\E +/;
    return _refusal('result filename is not a safe, unambiguous basename')
        unless _safe_basename($candidate->{filename});
    my $channel = $args{channel} // $candidate->{discovery_channel} // '';
    return _refusal('originating SearchBot channel is missing or unsafe')
        unless $channel =~ /\A[#&+!][^\s,\x00-\x1f\x7f]{0,199}\z/;
    my $wire = "PRIVMSG $channel :$payload\r\n";
    return _refusal('serialized IRC request exceeds the 512-byte line limit')
        if bytes::length($wire) > 512;
    return {
        type => 'valid', request_line => $payload,
        request_line_digest => sha256_hex($payload),
        expected_basename => $candidate->{filename}, channel => $channel,
        serialized_line => $wire,
    };
}

sub _same_irc_nick {
    my ($server, $observed, $expected, $mapping) = @_;
    return 0 unless defined($observed) && defined($expected);
    return same_irc_identity($observed, $expected, $mapping)
        if defined($mapping) && $mapping =~ /\A(?:ascii|strict-rfc1459|rfc1459)\z/i;
    if (ref($server) && eval { $server->can('nickcmp') }) {
        my $same = eval { $server->nickcmp($observed, $expected) == 0 };
        return $same ? 1 : 0 unless $@;
    }
    # RFC1459 case mapping is the safe default when an adapter/test server
    # does not expose Irssi's negotiated nick comparator.
    for ($observed, $expected) {
        tr/A-Z/a-z/;
        s/\[/\{/g;
        s/\]/\}/g;
        s/\\/|/g;
        s/\^/~/g;
    }
    return $observed eq $expected;
}

sub _server_connection_identity {
    my ($server) = @_;
    return unless ref($server);
    my $native = eval { $server->{_irssi} };
    return 'irssi:' . $native if defined($native) && !ref($native) && length("$native");
    my $wrapper = refaddr($server);
    return defined($wrapper) ? 'wrapper:' . $wrapper : undef;
}

sub validate_content_offer {
    my ($offer, $request, %args) = @_;
    return _refusal('invalid DCC offer') unless ref($offer) && (reftype($offer) // '') eq 'HASH';
    return _refusal('no direct SearchBot request is awaiting an offer')
        unless ref($request) eq 'HASH' &&
            ($request->{state} // '') =~ /\A(?:dispatching|awaiting_offer)\z/ &&
            $request->{dispatch_attempted};
    return _refusal('DCC offer is not an incoming file SEND')
        unless uc($offer->{type} // '') eq 'GET';
    # The list of a nick the operator typed may come from any nick on the
    # same connection (2026-11-02): one nick advertises "@Name" and another
    # sends it. The checks below still hold.
    return _refusal('DCC offer is not from the explicitly expected content sender')
        unless ($request->{list_request} && $request->{any_sender}) ||
            _same_irc_nick($offer->{server}, $offer->{nick}, $request->{expected_sender});
    my $tag = $offer->{servertag} // (ref($offer->{server}) ? ($offer->{server}{tag} // '') : '');
    return _refusal('DCC offer is from a different IRC server')
        unless length($tag) && lc($tag) eq lc($request->{server_tag} // '');
    my $offer_connection = _server_connection_identity($offer->{server});
    my $request_connection = $request->{server_identity} //
        _server_connection_identity($request->{server});
    return _refusal('DCC offer is not attached to the originating live connection')
        unless defined($offer_connection) && defined($request_connection) &&
            $offer_connection eq $request_connection;
    # A list request names no file: any one safe .txt, .zip, .rar or .7z
    # name is its list (whether another request reserved the name is the
    # caller's check). RAR and 7-Zip since 2026-10-28, as some servers send.
    if ($request->{list_request}) {
        return _refusal('a list is offered as one .txt, .zip, .rar or .7z file with a safe name')
            unless _safe_basename($offer->{arg}) && $offer->{arg} =~ /\.(?:zip|txt|rar|7z)\z/i;
    }
    # mIRC-based senders offer a name with underscores for its spaces; that
    # one alias is taken when the request names it (2026-10-20).
    return _refusal('DCC offer filename is not the exact expected basename')
        unless $request->{list_request} || defined($offer->{arg}) &&
            ($offer->{arg} eq ($request->{expected_basename} // '') ||
                (defined($request->{expected_alias}) && length($request->{expected_alias}) &&
                    $offer->{arg} eq $request->{expected_alias}));
    my $size = $offer->{size};
    my $max = $args{max_content_bytes} // $request->{max_content_bytes} // (256 * 1024 * 1024);
    return _refusal('configured SearchBot content size limit is invalid')
        unless $max =~ /\A[1-9][0-9]*\z/ && $max <= (1024 * 1024 * 1024);
    return _refusal('DCC offer size is missing or invalid')
        unless defined($size) && $size =~ /\A[1-9][0-9]*\z/;
    return _refusal('DCC offer exceeds the configured SearchBot content size limit')
        if $size > $max;
    return {
        type => 'matched', filename => $offer->{arg}, size_bytes => 0 + $size,
        expected_sender => $request->{expected_sender},
    };
}

sub tombstone_key {
    my ($server_tag, $sender, $filename) = @_;
    return unless defined($server_tag) && length($server_tag) &&
        defined($sender) && length($sender) && defined($filename) && length($filename);
    return join("\0", lc($server_tag), lc($sender), $filename);
}

sub tombstone_matches {
    my ($server, $server_tag, $sender, $filename, $entry) = @_;
    return 0 unless ref($entry) eq 'HASH';
    return 0 unless defined($server_tag) && defined($entry->{server_tag}) &&
        lc($server_tag) eq lc($entry->{server_tag});
    return 0 unless defined($filename) && defined($entry->{filename}) &&
        $filename eq $entry->{filename};
    return _same_irc_nick($server, $sender, $entry->{sender}, $entry->{casemapping});
}

1;
