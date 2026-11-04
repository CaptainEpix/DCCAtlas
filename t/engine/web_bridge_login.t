#!/usr/bin/env perl
use strict;
use warnings;
no warnings qw(once redefine);

# A source's login (web M3, Y2): the engine keeps a server password or a SASL
# PLAIN account for a managed source, gives it to Irssi at the next Connect,
# never puts it in a reply or a view, and drops it when the source points at
# another server.

use FindBin;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

my $test_root = tempdir(CLEANUP => 1);
$ENV{IRSSI_TEST_DIR} = $test_root;
require "$FindBin::Bin/../../engine/dccatlas.pl";

# No server is connected and none is waiting to reconnect: Connect only gives
# Irssi its commands, which the stand-in records.
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
    is($reply->{__bridge_error} && $reply->{code}, $code, $label);
}
# The current revision sent again is answered with the source's view, unchanged.
sub view { return $dispatch->('source.configure', { %last })->{source} }
sub connect_commands {
    Irssi::clear_capture();
    my $reply = $dispatch->('source.connect', { source_id => 'net' });
    ok(!$reply->{__bridge_error}, 'connect started') or diag explain $reply;
    my @commands = @Irssi::GLOBAL_COMMANDS;
    # Leave the source at rest again: the connection fails, as Irssi reports it.
    my ($tag) = map { /-network (\S+)/ ? $1 : () } @commands;
    Irssi::emit('server connect failed', bless({ tag => $tag, address => $last{host},
        port => $last{port}, connected => 0 }, 'MockServer')) if defined $tag;
    return @commands;
}

configure();
is(view()->{login}, undef, 'no login to begin with');
my ($connect) = grep { /^CONNECT / } connect_commands();
like($connect, qr/ 6697 "" Me\z/, 'without a login the password argument is empty, as before');

# Refusals.
my $secret = 'pa ss"wo\\rd$x;y%z';
refused_with(login(kind => 'other', password => 'x'), 'invalid_arguments', 'an unknown kind');
refused_with(login(kind => 'server_password'), 'invalid_arguments', 'no password');
refused_with(login(kind => 'server_password', password => ''), 'invalid_arguments', 'an empty password');
refused_with(login(kind => 'server_password', password => 'x' x 129), 'invalid_arguments', 'too long');
refused_with(login(kind => 'server_password', password => "a\x01b"), 'invalid_arguments', 'a control character');
refused_with(login(kind => 'server_password', password => "caf\x{e9}"), 'invalid_arguments', 'not ASCII');
refused_with(login(kind => 'server_password', password => 'two words'), 'invalid_arguments',
    'a server password with a space');
refused_with(login(kind => 'server_password', password => ':colon'), 'invalid_arguments',
    'a server password starting with a colon');
refused_with(login(kind => 'server_password', password => '-'), 'invalid_arguments',
    'a server password of "-", which CONNECT reads as none');
refused_with(login(kind => 'server_password', password => 'x', username => 'u'), 'invalid_arguments',
    'a server password with a username');
refused_with(login(kind => 'sasl_plain', password => 'x'), 'invalid_arguments', 'an account without a name');
refused_with(login(kind => 'sasl_plain', password => 'x', username => 'two words'), 'invalid_arguments',
    'an account name with a space');
refused_with(login(kind => 'none', password => 'x'), 'invalid_arguments', 'clearing with a password');
refused_with($dispatch->('source.login', { source_id => 'nowhere', kind => 'none' }), 'unknown_source',
    'an unknown source');

# A server password.
my $set = login(kind => 'server_password', password => 'Pass\\w"rd$1;');
is_deeply($set, { source_id => 'net', login => { kind => 'server_password' } },
    'the reply names the kind only');
is_deeply(view()->{login}, { kind => 'server_password' }, 'and so does the view');
($connect) = grep { /^CONNECT / } connect_commands();
like($connect, qr/ 6697 "Pass\\\\w\\"rd\$1;" Me\z/, 'Connect passes it quoted, as Irssi reads it');

# A SASL account.
$set = login(kind => 'sasl_plain', username => 'my_account', password => $secret);
is_deeply($set->{login}, { kind => 'sasl_plain', username => 'my_account' }, 'an account: kind and name only');
my @commands = connect_commands();
my ($add_at) = grep { $commands[$_] =~ /^NETWORK ADD / } 0 .. $#commands;
my ($connect_at) = grep { $commands[$_] =~ /^CONNECT / } 0 .. $#commands;
my ($remove_at) = grep { $commands[$_] =~ /^NETWORK REMOVE / } 0 .. $#commands;
ok(defined($add_at) && defined($connect_at) && defined($remove_at) &&
    $add_at < $connect_at && $connect_at < $remove_at,
    'the network with the account is added before Connect and removed after it')
    or diag explain \@commands;
my ($tag) = $commands[$connect_at] =~ /-network (\S+)/;
is($commands[$add_at],
    'NETWORK ADD -sasl_mechanism PLAIN -sasl_username "my_account" -sasl_password ' .
    '"pa ss\\"wo\\\\rd$x;y%z" ' . $tag, 'the account goes to that connection\'s own network');
is($commands[$remove_at], "NETWORK REMOVE $tag", 'and that network is removed');
like($commands[$connect_at], qr/ 6697 "" Me\z/, 'with an account there is no server password');

# Nothing that is read back carries it.
my $everything = $json->encode([$set, view()]);
unlike($everything, qr/\Q$secret\E|pa ss/, 'the password is in no view or reply');

# The same server keeps it; another one drops it.
configure(label => 'Renamed');
is_deeply(view()->{login}, { kind => 'sasl_plain', username => 'my_account' },
    'changing the label keeps the login');
configure(channel => '#other');
ok(view()->{login}, 'so does changing the channel');
configure(port => 7000);
is(view()->{login}, undef, 'another port drops it');
login(kind => 'server_password', password => 'x');
configure(port => 7000, tls => JSON::PP::false);
is(view()->{login}, undef, 'turning TLS off drops it');
login(kind => 'server_password', password => 'x');
configure(port => 7000, tls => JSON::PP::false, host => 'irc.elsewhere.example');
is(view()->{login}, undef, 'another host drops it');
($connect) = grep { /^CONNECT / } connect_commands();
like($connect, qr/ "" Me\z/, 'and the next Connect has no password');

login(kind => 'server_password', password => 'x');
is_deeply(login(kind => 'none'), { source_id => 'net', login => undef }, 'clearing it');
is(view()->{login}, undef, 'leaves none');

login(kind => 'server_password', password => 'x');
my $removed = $dispatch->('source.remove', { source_id => 'net' });
ok(!$removed->{__bridge_error}, 'the source is removed') or diag explain $removed;
$revision = 0;
configure(port => 7000, tls => JSON::PP::false, host => 'irc.elsewhere.example');
is(view()->{login}, undef, 'and a source added again under its ID has no login');

done_testing();
