use strict;
use warnings;
use Irssi;

# Delay only the adapter's own "server disconnected" handler for the first
# managed connection. Irssi's core handlers must still run on time: stopping
# the signal would skip their cleanup and leave freed native server state
# behind. The delayed call therefore receives a plain snapshot of the fields
# the adapter reads, never the native-backed server object. The test releases
# the held call explicitly, so the window does not depend on machine speed.
my $adapter_handler = \&Irssi::Script::dccatlas::sig_server_disconnected;
my $held = 0;
my $release;
Irssi::signal_remove('server disconnected', $adapter_handler);
Irssi::signal_add('server disconnected', sub {
    my ($server) = @_;
    if ($held || !ref($server) ||
            ($server->{tag} // '') !~ /\Afserve-web-/) {
        return $adapter_handler->($server);
    }
    $held = 1;
    my %snapshot = map { $_ => $server->{$_} }
        grep { !ref($server->{$_}) } keys %$server;
    $release = sub {
        $adapter_handler->(\%snapshot);
        Irssi::print('W2_TEST_DISCONNECT_RELEASED');
    };
    Irssi::print('W2_TEST_DISCONNECT_PAUSED');
});
Irssi::command_bind('w2_release_disconnect', sub {
    my $pending = $release or return;
    $release = undef;
    $pending->();
});
Irssi::print('W2_TEST_DISCONNECT_HOOK_READY');
