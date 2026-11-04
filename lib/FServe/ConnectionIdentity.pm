package FServe::ConnectionIdentity;

use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(refaddr);

our @EXPORT_OK = qw(
    irc_casefold
    network_profile_key
    connection_key
    peer_key
    tuple_key
    same_irc_identity
);

sub irc_casefold {
    my ($value, $mapping) = @_;
    $value = '' unless defined $value;
    $mapping = lc($mapping // 'rfc1459');
    $mapping = 'rfc1459' unless $mapping =~ /\A(?:ascii|strict-rfc1459|rfc1459)\z/;

    my $folded = lc($value);
    if ($mapping ne 'ascii') {
        $folded =~ s/\[/\{/g;
        $folded =~ s/\]/\}/g;
        $folded =~ s/\\/|/g;
        $folded =~ s/\^/~/g if $mapping eq 'rfc1459';
    }
    return $folded;
}

sub network_profile_key {
    my ($profile) = @_;
    return unless defined($profile) && !ref($profile) && length($profile);
    return lc($profile);
}

sub connection_key {
    my ($server) = @_;
    return unless ref($server);
    my $native = eval { $server->{_irssi} };
    return 'irssi:' . $native if defined($native) && !ref($native) && length("$native");
    my $address = refaddr($server);
    return defined($address) ? 'wrapper:' . $address : undef;
}

sub peer_key {
    my ($network_profile, $nick, $mapping) = @_;
    return unless defined($network_profile) && length($network_profile) &&
        defined($nick) && length($nick);
    return join("\x1f", lc($network_profile), irc_casefold($nick, $mapping));
}

sub tuple_key {
    my (%args) = @_;
    my $peer = peer_key($args{network_profile}, $args{peer}, $args{casemapping});
    return unless defined $peer;
    my $basename = $args{basename};
    return unless defined($basename) && length($basename);
    # DCC filenames are payload bytes, not IRC identifiers: preserve case.
    return join("\x1e", $peer, $basename);
}

sub same_irc_identity {
    my ($left, $right, $mapping) = @_;
    return 0 unless defined($left) && defined($right);
    return irc_casefold($left, $mapping) eq irc_casefold($right, $mapping) ? 1 : 0;
}

1;
