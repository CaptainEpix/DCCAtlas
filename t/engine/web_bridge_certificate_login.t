#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# A certificate login (2026-10-27): the engine keeps a managed source's client
# certificate in a file of its own folder that only its user can read, gives
# it to Irssi at the next Connect with SASL EXTERNAL, never puts it in a reply
# or a view, and removes the file with the login.

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
my $json = JSON::PP->new->canonical(1)->allow_nonref(1)->convert_blessed(1);
my $revision = 0;

my %last;
sub configure {
    my (%over) = @_;
    %last = (
        source_id => 'net', revision => ++$revision, label => 'Net', provider => 'sysreset_find',
        host => 'irc.example.net', port => 6697, tls => JSON::PP::true, nickname => 'Me',
        channel => '#books', %over,
    );
    my $reply = $dispatch->('source.configure', { %last });
    ok(!$reply->{__bridge_error}, "configured (revision $revision)") or diag explain $reply;
    return $reply;
}
sub login { return $dispatch->('source.login', { source_id => 'net', @_ }) }
sub refused_with {
    my ($reply, $code, $label) = @_;
    is($reply->{__bridge_error} && $reply->{code}, $code, $label) or diag explain $reply;
}
sub view { return $dispatch->('source.configure', { %last })->{source} }
sub connect_commands {
    Irssi::clear_capture();
    my $reply = $dispatch->('source.connect', { source_id => 'net' });
    my @commands = @Irssi::GLOBAL_COMMANDS;
    my ($tag) = map { /-network (\S+)/ ? $1 : () } @commands;
    Irssi::emit('server connect failed', bless({ tag => $tag, address => $last{host},
        port => $last{port}, connected => 0 }, 'MockServer')) if defined $tag;
    return ($reply, @commands);
}

my $key_line = 'S0VZLVNFQ1JFVC1MSU5FLWZvci10aGUtdGVzdA==';
my $pem = "-----BEGIN CERTIFICATE-----\nQ0VSVElGSUNBVEU=\n-----END CERTIFICATE-----\n" .
    "-----BEGIN PRIVATE KEY-----\n$key_line\n-----END PRIVATE KEY-----\n";
my $folder = "$test_root/fserve-poc/certificates";
sub files { opendir(my $handle, $folder) or return (); return sort grep { !/\A\./ } readdir($handle) }

configure();

# Refusals.
refused_with(login(kind => 'certificate'), 'invalid_arguments', 'no certificate');
refused_with(login(kind => 'certificate', certificate => $pem, password => 'x'), 'invalid_arguments',
    'a certificate with a password');
refused_with(login(kind => 'certificate', certificate => $pem, username => 'u'), 'invalid_arguments',
    'a certificate with a username');
refused_with(login(kind => 'nickserv', password => 'x', certificate => $pem), 'invalid_arguments',
    'a certificate with another kind of login');
refused_with(login(kind => 'certificate', certificate => "not a certificate"), 'invalid_arguments',
    'not PEM');
refused_with(login(kind => 'certificate',
    certificate => "-----BEGIN CERTIFICATE-----\nQQ==\n-----END CERTIFICATE-----\n"),
    'invalid_arguments', 'a certificate without its key');
refused_with(login(kind => 'certificate', certificate => $pem =~ s/PRIVATE KEY/ENCRYPTED PRIVATE KEY/gr),
    'invalid_arguments', 'a key with a passphrase, which Irssi would ask for');
refused_with(login(kind => 'certificate',
    certificate => $pem =~ s/\Q$key_line\E/"A" x 17000/er), 'invalid_arguments', 'too long');
is_deeply([files()], [], 'nothing refused was written');

configure(host => '10.20.30.40', tls => JSON::PP::false);
refused_with(login(kind => 'certificate', certificate => $pem), 'login_needs_tls',
    'without TLS, even on a private network');
configure();

# Kept, and given to Irssi at Connect.
my $set = login(kind => 'certificate', certificate => $pem);
is_deeply($set, { source_id => 'net', login => { kind => 'certificate' } }, 'the reply names the kind only');
is_deeply(view()->{login}, { kind => 'certificate' }, 'and so does the view');
my @kept = files();
is(scalar(@kept), 1, 'one file is kept') or diag explain \@kept;
my $path = "$folder/$kept[0]";
SKIP: {
    skip 'file modes are not POSIX here', 2 if $^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin';
    is((stat($folder))[2] & 07777, 0700, 'its folder is the engine user\'s alone');
    is((stat($path))[2] & 07777, 0600, 'and so is the file');
}
open(my $in, '<', $path) or die $!;
is(do { local $/; <$in> }, $pem, 'the file holds the certificate and key as given');
close($in);

my ($reply, @commands) = connect_commands();
ok(!$reply->{__bridge_error}, 'connect started') or diag explain $reply;
my ($add_at) = grep { $commands[$_] =~ /^NETWORK ADD / } 0 .. $#commands;
my ($connect_at) = grep { $commands[$_] =~ /^CONNECT / } 0 .. $#commands;
my ($remove_at) = grep { $commands[$_] =~ /^NETWORK REMOVE / } 0 .. $#commands;
ok(defined($add_at) && defined($connect_at) && defined($remove_at) &&
    $add_at < $connect_at && $connect_at < $remove_at,
    'the network with SASL EXTERNAL is added before Connect and removed after it')
    or diag explain \@commands;
my ($tag) = $commands[$connect_at] =~ /-network (\S+)/;
is($commands[$add_at], "NETWORK ADD -sasl_mechanism EXTERNAL $tag",
    'EXTERNAL, with no account name or password');
like($commands[$connect_at], qr/ -tls -tls_verify -tls_cert "\Q$path\E" irc\.example\.net 6697 "" Me\z/,
    'Connect presents the certificate and still verifies the server');
my $log = $dispatch->('log.list', {});
like($json->encode($log), qr/with a client certificate \(SASL EXTERNAL\)/, 'the log says how it logs in');
unlike($json->encode([$set, view(), $log, \@commands]), qr/\Q$key_line\E|PRIVATE KEY/,
    'the key is in no reply, view, log line or command');

# A missing file fails the connection instead of connecting without it.
unlink($path);
($reply, @commands) = connect_commands();
ok(!grep({ /^CONNECT / } @commands), 'no CONNECT without the file') or diag explain \@commands;
like($json->encode(view()), qr/certificate is missing/, 'and the source says why');

# Each way the login goes removes the file.
login(kind => 'certificate', certificate => $pem);
login(kind => 'nickserv', password => 'x');
is_deeply([files()], [], 'another kind of login replaces it');
login(kind => 'certificate', certificate => $pem);
login(kind => 'none');
is_deeply([files()], [], 'clearing it');
login(kind => 'certificate', certificate => $pem);
configure(port => 7000);
is(view()->{login}, undef, 'another port drops it');
is_deeply([files()], [], 'with its file');
login(kind => 'certificate', certificate => $pem);
my $removed = $dispatch->('source.remove', { source_id => 'net' });
ok(!$removed->{__bridge_error}, 'the source is removed') or diag explain $removed;
is_deeply([files()], [], 'with its file');

# A file left by an earlier run of the engine belongs to no login.
$revision = 0;
configure();
login(kind => 'certificate', certificate => $pem);
open(my $stray, '>', "$folder/" . ('0' x 24) . '.pem') or die $!;
close($stray);
Irssi::Script::dccatlas::web_bridge_clear_certificate_files();
is_deeply([files()], [], 'is removed when the engine starts');

done_testing();
