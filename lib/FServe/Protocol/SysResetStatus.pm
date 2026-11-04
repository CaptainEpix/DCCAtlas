package FServe::Protocol::SysResetStatus;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(parse_status);

sub parse_status {
    my ($raw, %context) = @_;
    $raw = '' unless defined $raw;
    my $unknown = { type => 'unknown', raw => $raw, correlated => 0 };
    return $unknown unless $context{peer_matches} && $context{connection_matches};
    return $unknown unless ($context{message_context} // '') eq 'dcc_chat';

    # These exact markers are emitted only by the isolated Phase 6 responder.
    # Production wording is recognized further down, from the SysReset source.
    if ($raw =~ /\A\[fserve-phase6-test\] QUEUED job=(job-[a-f0-9]{32}) position=([1-9][0-9]*)\z/) {
        my ($job, $position) = ($1, 0 + $2);
        return { type => 'unknown', raw => $raw, correlated => 0 }
            unless defined($context{job_id}) && $context{job_id} eq $job;
        return { type => 'queued', raw => $raw, job_id => $job, position => $position, correlated => 1, dialect => 'synthetic-phase6' };
    }
    if ($raw =~ /\A\[fserve-phase6-test\] POSITION job=(job-[a-f0-9]{32}) position=([1-9][0-9]*)\z/) {
        my ($job, $position) = ($1, 0 + $2);
        return { type => 'unknown', raw => $raw, correlated => 0 }
            unless defined($context{job_id}) && $context{job_id} eq $job;
        return { type => 'queue_position', raw => $raw, job_id => $job, position => $position, correlated => 1, dialect => 'synthetic-phase6' };
    }
    if ($raw =~ /\A\[fserve-phase6-test\] EXPLICIT-REFUSAL job=(job-[a-f0-9]{32}) reason=([a-z0-9_-]{1,32})\z/) {
        my ($job, $reason) = ($1, $2);
        return { type => 'unknown', raw => $raw, correlated => 0 }
            unless defined($context{job_id}) && $context{job_id} eq $job;
        return { type => 'explicit_refusal', raw => $raw, job_id => $job, reason => $reason, correlated => 1, dialect => 'synthetic-phase6' };
    }
    for my $variant (
        ['ALREADY-QUEUED', 'already_queued'],
        ['SENDS-FULL', 'sends_full'],
        ['USER-QUEUE-FULL', 'user_queue_full'],
        ['QUEUE-FULL', 'queue_full'],
    ) {
        my ($wire, $type) = @$variant;
        if ($raw =~ /\A\[fserve-phase6-test\] \Q$wire\E job=(job-[a-f0-9]{32})\z/) {
            my $job = $1;
            return { type => 'unknown', raw => $raw, correlated => 0 }
                unless defined($context{job_id}) && $context{job_id} eq $job;
            return { type => $type, raw => $raw, job_id => $job,
                correlated => 1, dialect => 'synthetic-phase6' };
        }
    }
    return _sysreset_get_reply($raw, \%context) // $unknown;
}

# SysReset 2.55 answers every FServe "get" with exactly one of the fixed lines
# below (its script: system/events.ini, the "get" branch of the chat handler).
# They name no file and no request, so they are attributed to a job only while
# that job's own GET is the outstanding request in the CHAT they arrived in.
sub _sysreset_get_reply {
    my ($raw, $context) = @_;
    return undef unless $context->{request_outstanding} && defined $context->{job_id};
    my $text = $raw;
    $text =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
    $text =~ s/[\x02\x0f\x16\x1d\x1f]//g;
    $text =~ s/\A\s+|\s+\z//g;
    $text =~ s/\s+/ /g;
    my %reply = (raw => $raw, text => $text, job_id => $context->{job_id},
        correlated => 1, dialect => 'sysreset-2.55');
    return { %reply, type => 'queued', position => 0 + $1 }
        if $text =~ /\AAdding your file to queue slot ([1-9][0-9]{0,3})\. The file will send when the next send slot is open\.\z/;
    return { %reply, type => 'already_queued', position => 0 + $1 }
        if $text =~ /\AThat file has already been queued in slot ([1-9][0-9]{0,3})!\z/;
    my %fixed = (
        'Sorry, all of your queue slots are full.' => ['user_queue_full'],
        'Sorry, all send and queue slots are full.' => ['queue_full'],
        'That file is already sending!' => ['already_queued', 'already_sending'],
        'Sorry, you already have this file queued in another pool.' => ['already_queued', 'other_pool'],
        'Sorry, this file is above the maximum sent file size limits.' => ['explicit_refusal', 'file_too_large'],
        'Invalid file name, please use the form: < get filename.ext >' => ['explicit_refusal', 'invalid_file_name'],
        'Invalid file name, please use the form: <get filename.ext>' => ['explicit_refusal', 'invalid_file_name'],
        'A Queue Error has occured. Cannot queue your file at this time.' => ['explicit_refusal', 'queue_error'],
        'Server Error. Cannot Comply.' => ['explicit_refusal', 'server_error'],
    );
    my $known = $fixed{$text};
    return { %reply, type => $known->[0], (defined $known->[1] ? (reason => $known->[1]) : ()) }
        if $known;
    return _fservepl_get_reply($text, \%reply);
}

# FServe.pl 2.0.0 for Irssi answers a "get" with one of these (its queue_file,
# https://scripts.irssi.org/scripts/fserve.pl; seen in use on 2026-10-20).
# "Sending '<file>'" says an instant send follows and needs no action.
sub _fservepl_get_reply {
    my ($text, $reply) = @_;
    my %reply = (%$reply, dialect => 'fservepl-2.0.0');
    return { %reply, type => 'queued', position => 0 + $1 }
        if $text =~ /\AQueued '.+' \([^()]*\) in slot #([1-9][0-9]{0,3})\z/;
    return { %reply, type => 'already_queued', position => 0 + $1 }
        if $text =~ /\AYou have already queued '.+' in slot #([1-9][0-9]{0,3})!\z/;
    return { %reply, type => 'user_queue_full' }
        if $text =~ /\ANo sends are available and you have used all your queue slots \([0-9]+\)\z/;
    return { %reply, type => 'queue_full' }
        if $text eq 'No send or queue slots are available!';
    return { %reply, type => 'explicit_refusal', reason => 'invalid_file_name' }
        if $text =~ /\AInvalid filename: '.*'!\z/;
    return undef;
}

1;
