use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../..";
use JSON::PP ();
use FServe::Transfer::Coordinator qw(open_coordinator);

sub emit_event {
    my ($event) = @_;
    print JSON::PP->new->canonical(1)->encode($event), "\n";
}

my ($path, $maximum) = @ARGV;
unless (defined($path) && length($path) && defined($maximum) && $maximum =~ /\A[1-9][0-9]*\z/) {
    emit_event({ event => 'error', reason => 'journal path and positive byte ceiling are required' });
    exit 2;
}

my $coordinator;
my $result = eval {
    $coordinator = open_coordinator(path => $path, max_journal_bytes => $maximum);
    $coordinator->compact_journal();
};
unless ($result) {
    my $error = $@ || 'journal compaction failed';
    $error =~ s/[\r\n]+/ /g;
    eval { $coordinator->close() if $coordinator };
    emit_event({ event => 'error', reason => $error });
    exit 1;
}

eval { $coordinator->close() if $coordinator };
emit_event({ event => 'result', %$result });
exit 0;
