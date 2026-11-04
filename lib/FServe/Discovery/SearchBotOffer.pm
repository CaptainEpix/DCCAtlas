package FServe::Discovery::SearchBotOffer;

use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(reftype);

use FServe::DccPolicy qw(same_peer);

our @EXPORT_OK = qw(expected_archive_filename match_result_offer);

my $DEFAULT_MAX_ARCHIVE_BYTES = 32 * 1024 * 1024;
my $HARD_MAX_ARCHIVE_BYTES = 32 * 1024 * 1024;

sub expected_archive_filename {
    my ($query) = @_;
    return undef unless defined($query) && !ref($query);
    return undef if $query =~ /[\x00-\x1f\x7f]/;

    # These transformations are grounded in the user's observed examples:
    # terminal ! is stripped, while internal ! and spaces each become '_'.
    # Fail closed on other punctuation until its SearchBot mapping is known.
    $query =~ s/\A +| +\z//g;
    return undef unless length($query) && $query =~ /\A[A-Za-z0-9 !]+\z/;
    $query =~ s/!+\z//;
    return undef unless length($query);
    $query =~ s/ /_/g;
    $query =~ s/!/_/g;

    # The supplied SearchBot result is a ZIP archive whose sole member is a
    # .txt file; this deployment names the archive with the compound suffix.
    return 'SearchBot_results_for__' . $query . '.txt.zip';
}

sub _refusal {
    my ($reason) = @_;
    return { type => 'refusal', reason => $reason };
}

sub match_result_offer {
    my ($offer, %context) = @_;
    return _refusal('invalid DCC offer record')
        unless ref($offer) && (reftype($offer) // '') eq 'HASH';
    return _refusal('SearchBot result query is not awaiting a response')
        unless ($context{state} // '') eq 'awaiting_result';
    return _refusal('SearchBot result collection identity is missing')
        unless defined($context{collection_id}) &&
            $context{collection_id} =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    return _refusal('SearchBot expected sender or server tag is missing')
        unless defined($context{expected_nick}) && length($context{expected_nick}) &&
            defined($context{server_tag}) && length($context{server_tag});
    return _refusal('SearchBot query deadline is missing or invalid')
        unless defined($context{expires_at}) && $context{expires_at} =~ /\A[0-9]+(?:\.[0-9]+)?\z/;

    my $now = defined($context{now}) ? $context{now} : time();
    return _refusal('current time is invalid')
        unless defined($now) && $now =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
    return _refusal('SearchBot query deadline has expired')
        if $now >= $context{expires_at};

    my $expected = $context{expected_filename};
    $expected = expected_archive_filename($context{query}) unless defined $expected;
    return _refusal('query contains characters with an unverified SearchBot filename mapping')
        unless defined($expected) && length($expected);
    return _refusal('expected result filename is not a safe ZIP basename')
        if $expected =~ m{[/\\]} || $expected =~ /[\x00-\x1f\x7f]/ ||
            $expected !~ /\ASearchBot_results_for__.+\.zip\z/i;

    return _refusal('DCC offer is not a file receive')
        unless uc($offer->{type} // '') eq 'GET';
    return _refusal('DCC sender or IRC server does not match the active SearchBot query')
        unless same_peer($offer, $context{expected_nick}, $context{server_tag});

    my $offered = $offer->{arg};
    return _refusal('DCC result filename is missing or is not a basename')
        unless defined($offered) && length($offered) &&
            $offered !~ m{[/\\]} && $offered !~ /[\x00-\x1f\x7f]/;
    return _refusal('DCC result filename does not match the active query')
        unless $offered eq $expected;

    my $size = $offer->{size};
    my $max = defined($context{max_archive_bytes})
        ? $context{max_archive_bytes} : $DEFAULT_MAX_ARCHIVE_BYTES;
    return _refusal('invalid configured SearchBot archive size limit')
        unless $max =~ /\A[1-9][0-9]*\z/ && $max <= $HARD_MAX_ARCHIVE_BYTES;
    return _refusal('DCC result size is missing or invalid')
        unless defined($size) && $size =~ /\A[1-9][0-9]*\z/;
    return _refusal('DCC result archive exceeds the configured size limit')
        if $size > $max;

    return {
        type          => 'matched',
        collection_id => $context{collection_id},
        filename      => $offered,
        size_bytes    => 0 + $size,
    };
}

1;
