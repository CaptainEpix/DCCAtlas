#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# Two rules the web service has always applied, kept by the engine itself
# since 2026-10-21: two sources of one kind may not share a server and
# channel, and a password is refused without TLS; a loopback or
# private-network server is the exception to both.

use FindBin;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

*Irssi::servers = sub { () };
*Irssi::reconnects = sub { () };
my $dispatch = \&Irssi::Script::dccatlas::web_bridge_dispatch;
my $local = \&Irssi::Script::dccatlas::web_bridge_host_is_local;
my %revision;

sub configure {
    my ($source_id, %over) = @_;
    return $dispatch->('source.configure', {
        source_id => $source_id, revision => ++$revision{$source_id}, label => $source_id,
        provider => 'sysreset_find', host => 'irc.example.net', port => 6697,
        tls => JSON::PP::true, nickname => "Me$source_id", channel => '#books', %over,
    });
}
sub code_of { my ($reply) = @_; return $reply->{__bridge_error} ? $reply->{code} : 'ok' }

# Which addresses are a lab's, as the web service's is_local_server says.
for my $host (qw(localhost lab.localhost 127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.255
                 192.168.0.9 169.254.1.1 ::1 fd00::1 fc12::3 fe80::1 ::ffff:10.20.30.40)) {
    ok($local->($host), "$host is a lab or test server");
}
for my $host (qw(irc.example.net 203.0.113.9 100.64.0.1 172.32.0.1 172.15.0.1 198.51.100.7
                 2001:db8::1 64:ff9b::cb00:7109 ::ffff:203.0.113.9 010.1.2.3 256.1.1.1
                 localhost.example.net)) {
    ok(!$local->($host), "$host is not");
}

# One server and channel, one source of each kind.
is(code_of(configure('one')), 'ok', 'the first source');
is(code_of(configure('two')), 'duplicate_source_channel',
    'a second of the same kind on the same server and channel is refused');
is(code_of(configure('two', channel => '#BOOKS')), 'duplicate_source_channel',
    'channel names compare without case');
is(code_of(configure('two', port => 6667, tls => JSON::PP::false)), 'duplicate_source_channel',
    'the plain-text port is the same server');
is(code_of(configure('two', channel => '#other')), 'ok', 'another channel is fine');
is(code_of(configure('three', provider => 'searchbot', search_bot => 'Search')), 'ok',
    'so is a search-bot source on the same channel');
is(code_of(configure('one', label => 'renamed')), 'ok', 'a source does not conflict with itself');
is(code_of(configure('lab1', host => '10.20.30.40', channel => '#lab')), 'ok', 'a lab source');
is(code_of(configure('lab2', host => '10.20.30.40', channel => '#lab')), 'ok',
    'and a second on the lab, the one way to try several');

# A password only over TLS, except on a lab.
my $kept = $dispatch->('source.login', {
    source_id => 'two', kind => 'server_password', password => 'secret-pass' });
is(code_of($kept), 'ok', 'a password over TLS is kept');
is(code_of(configure('plain', host => 'irc.plain.example', tls => JSON::PP::false)), 'ok',
    'a plain-text source');
my $refused = $dispatch->('source.login', {
    source_id => 'plain', kind => 'sasl_plain', username => 'me', password => 'secret-pass' });
is(code_of($refused), 'login_needs_tls', 'a password without TLS is refused');
unlike(JSON::PP->new->canonical->encode($refused), qr/secret-pass/,
    'and not repeated in the refusal');
is(code_of($dispatch->('source.login', { source_id => 'plain', kind => 'none' })), 'ok',
    'clearing a login needs no TLS');
is(code_of(configure('lab3', host => '10.0.0.5', tls => JSON::PP::false, channel => '#x')), 'ok',
    'a plain-text lab source');
is(code_of($dispatch->('source.login', {
    source_id => 'lab3', kind => 'server_password', password => 'lab-pass' })), 'ok',
    'takes a password: it does not cross the Internet');

done_testing();
