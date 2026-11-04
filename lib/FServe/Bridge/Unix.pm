package FServe::Bridge::Unix;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK O_CREAT O_RDWR :flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use IO::Socket::UNIX;
use JSON::PP ();
use Socket qw(SOCK_STREAM);
use Irssi;

our $PROTOCOL_VERSION = 1;
our $MAX_FRAME_BYTES = 64 * 1024;
our $MAX_PENDING_INPUT_BYTES = 256 * 1024;
our $MAX_PENDING_OUTPUT_BYTES = 1024 * 1024;
our $MAX_REQUESTS_PER_CALLBACK = 4;
our $MAX_ACCEPTS_PER_CALLBACK = 4;
our $MAX_READ_BYTES = 8192;
our $MAX_WRITE_BYTES = 16384;
our $MAX_REQUEST_CACHE = 256;
our $DRAIN_DELAY_MS = 10;
our $ACCEPT_RETRY_MS = 1000;
my %MUTATING_OPERATION = map { $_ => 1 } qw(
    source.configure source.connect source.disconnect source.remove search.find
    search.cancel search.download manifest.download job.cancel source.login
    searchbot.held_download browse.start list.request list.download
);

sub new {
    my ($class, %args) = @_;
    die 'bridge socket path is required'
        unless defined($args{path}) && !ref($args{path}) && length($args{path});
    die 'bridge request handler is required'
        unless ref($args{on_request}) eq 'CODE';
    for my $name (qw(input_add input_remove timeout_add_once timeout_remove)) {
        die "bridge $name callback is required"
            unless ref($args{$name}) eq 'CODE';
    }

    my $instance_id = substr(sha256_hex(join("\0", $$, time, rand(), {})), 0, 32);
    return bless {
        path => $args{path},
        on_request => $args{on_request},
        input_add => $args{input_add},
        input_remove => $args{input_remove},
        timeout_add_once => $args{timeout_add_once},
        timeout_remove => $args{timeout_remove},
        instance_id => $instance_id,
        event_sequence => 0,
        request_cache => {},
        request_order => [],
        closed => 0,
    }, $class;
}

sub instance_id { $_[0]{instance_id} }
sub event_sequence { $_[0]{event_sequence} }

sub _set_nonblocking {
    my ($fh) = @_;
    my $flags = fcntl($fh, F_GETFL, 0);
    die "cannot inspect bridge socket flags: $!" unless defined $flags;
    die "cannot set bridge socket nonblocking: $!"
        unless defined fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}

sub _valid_handle {
    my ($handle) = @_;
    return defined($handle) && $handle ? $handle : undef;
}

sub _add_input {
    my ($self, @args) = @_;
    my $handle = eval { $self->{input_add}->(@args) };
    return if $@;
    return _valid_handle($handle);
}

sub _add_timeout {
    my ($self, @args) = @_;
    my $handle = eval { $self->{timeout_add_once}->(@args) };
    return if $@;
    return _valid_handle($handle);
}

sub _remove_input {
    my ($self, $handle) = @_;
    return unless _valid_handle($handle);
    eval { $self->{input_remove}->($handle) };
}

sub _remove_timeout {
    my ($self, $handle) = @_;
    return unless _valid_handle($handle);
    eval { $self->{timeout_remove}->($handle) };
}

sub _schedule_drain {
    my ($self) = @_;
    return 1 if defined $self->{drain_timer};
    my $timer = $self->_add_timeout($DRAIN_DELAY_MS, sub {
        delete $self->{drain_timer};
        $self->_drain_buffer();
    }, undef);
    unless (defined $timer) {
        $self->_close_client();
        return 0;
    }
    $self->{drain_timer} = $timer;
    return 1;
}

sub start {
    my ($self) = @_;
    die 'bridge is already started' if $self->{listener};
    my $path = File::Spec->rel2abs($self->{path});
    die 'bridge Unix socket path exceeds 100 bytes'
        if length($path) > 100;
    my $directory = dirname($path);
    if (-e $directory || -l $directory) {
        die 'bridge socket directory must be a real directory, not a symbolic link'
            if -l $directory || !-d $directory;
    } else {
        make_path($directory, { mode => 0700 });
    }
    die 'bridge socket directory is a symbolic link' if -l $directory;

    my $lock_path = $path . '.lock';
    die 'bridge lock path is a symbolic link' if -l $lock_path;
    my $nofollow = eval { Fcntl::O_NOFOLLOW() } || 0;
    my $lock_flags = O_CREAT | O_RDWR | $nofollow;
    sysopen(my $lock_fh, $lock_path, $lock_flags, 0600)
        or die "cannot open bridge ownership lock: $!";
    chmod 0600, $lock_path
        or die "cannot protect bridge ownership lock: $!";
    unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
        close $lock_fh;
        die 'another engine bridge already owns this socket path';
    }
    $self->{lock_fh} = $lock_fh;

    if (-l $path || (-e $path && !-S $path)) {
        $self->_release_lock();
        die 'refusing to replace a non-socket entry at the bridge path';
    }
    if (-S $path) {
        my $probe = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path);
        if ($probe) {
            close $probe;
            $self->_release_lock();
            die 'a bridge is already listening at the requested socket path';
        }
        unlink $path or do {
            $self->_release_lock();
            die "cannot remove stale bridge socket: $!";
        };
    }

    my $old_mask = umask 0077;
    my $listener = IO::Socket::UNIX->new(
        Type => SOCK_STREAM, Local => $path, Listen => 8,
    );
    umask $old_mask;
    unless ($listener) {
        my $error = "$!";
        $self->_release_lock();
        die "cannot create bridge socket: $error";
    }
    unless (chmod(0600, $path) && eval { _set_nonblocking($listener); 1 }) {
        my $error = $@ || "$!";
        close $listener;
        unlink $path;
        $self->_release_lock();
        die "cannot secure bridge listener: $error";
    }
    my @socket_identity = lstat($path);
    unless (@socket_identity && -S _) {
        close $listener;
        unlink $path if -S $path;
        $self->_release_lock();
        die 'bridge socket identity could not be captured';
    }
    $self->{path} = $path;
    $self->{listener} = $listener;
    $self->{socket_identity} = [$socket_identity[0], $socket_identity[1]];
    unless ($self->_listen()) {
        $self->stop();
        die 'Irssi refused the bridge listener callback';
    }
    return 1;
}

sub _listen {
    my ($self) = @_;
    $self->{listener_input} = $self->_add_input(
        fileno($self->{listener}), Irssi::INPUT_READ,
        sub { $self->_accept_ready() }, undef,
    );
    return $self->{listener_input} ? 1 : 0;
}

# Stop taking connections for $ACCEPT_RETRY_MS, then take them again.
sub _pause_listener {
    my ($self) = @_;
    return if defined $self->{accept_retry_timer};
    $self->_remove_input(delete $self->{listener_input});
    $self->{accept_retry_timer} = $self->_add_timeout($ACCEPT_RETRY_MS, sub {
        delete $self->{accept_retry_timer};
        $self->_listen() if !$self->{closed} && $self->{listener};
    }, undef);
    $self->_listen() unless defined $self->{accept_retry_timer};
}

sub _release_lock {
    my ($self) = @_;
    if (my $fh = delete $self->{lock_fh}) {
        close $fh;
    }
}

sub _accept_ready {
    my ($self) = @_;
    return if $self->{closed} || !$self->{listener};
    for (1 .. $MAX_ACCEPTS_PER_CALLBACK) {
        my $client = $self->{listener}->accept();
        if (!$client) {
            return if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
            # Accepting failed for another reason, such as having no file
            # descriptor left. The connection already open is not at fault and
            # stays. The waiting connection keeps the listener readable, so
            # listening pauses for a while rather than failing again at once.
            $self->_pause_listener();
            return;
        }
        if ($self->{client}) {
            close $client;
            next;
        }
        unless (eval { _set_nonblocking($client); 1 }) {
            close $client;
            next;
        }
        $self->{client} = $client;
        $self->{client_buffer} = '';
        $self->{output_queue} = [];
        $self->{output_bytes} = 0;
        $self->{handshake_complete} = 0;
        $self->{handshake_timer} = $self->_add_timeout(
            10000, sub {
                delete $self->{handshake_timer};
                $self->_close_client() unless $self->{handshake_complete};
            }, undef,
        );
        unless ($self->{handshake_timer}) {
            $self->_close_client();
            return;
        }
        $self->{read_input} = $self->_add_input(
            fileno($client), Irssi::INPUT_READ,
            sub { $self->_read_ready() }, undef,
        );
        unless ($self->{read_input}) {
            $self->_close_client();
        }
        return;
    }
}

sub _read_ready {
    my ($self) = @_;
    my $client = $self->{client} or return;
    my $read = sysread($client, my $chunk, $MAX_READ_BYTES);
    if (!defined $read) {
        return if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        $self->_close_client();
        return;
    }
    if ($read == 0) {
        $self->_close_client();
        return;
    }
    $self->{client_buffer} .= $chunk;
    if (length($self->{client_buffer}) > $MAX_PENDING_INPUT_BYTES) {
        $self->_close_client();
        return;
    }
    if (length($self->{client_buffer}) > $MAX_FRAME_BYTES &&
            index($self->{client_buffer}, "\n") < 0) {
        $self->_close_client();
        return;
    }

    $self->_drain_buffer();
}

sub _drain_buffer {
    my ($self) = @_;
    return unless $self->{client};
    my $handled = 0;
    while ($handled < $MAX_REQUESTS_PER_CALLBACK) {
        my $newline = index($self->{client_buffer}, "\n");
        last if $newline < 0;
        if ($newline > $MAX_FRAME_BYTES) {
            $self->_close_client();
            return;
        }
        my $line = substr($self->{client_buffer}, 0, $newline + 1, '');
        $line =~ s/\n\z//;
        $line =~ s/\r\z//;
        if (!length($line) || !$self->_handle_frame($line)) {
            $self->_close_client();
            return;
        }
        $handled++;
        return unless $self->{client};
    }
    if (index($self->{client_buffer}, "\n") >= 0) {
        $self->_schedule_drain();
    }
}

sub _error_response {
    my ($id, $code, $message, $operation_id) = @_;
    $message = 'request could not be processed' unless defined($message) && !ref($message);
    $message =~ s/[\r\n\x00-\x1f\x7f]+/ /g;
    $message = substr($message, 0, 512);
    return {
        protocol_version => $PROTOCOL_VERSION,
        request_id => $id,
        (defined($operation_id) ? (operation_id => $operation_id) : ()),
        ok => JSON::PP::false,
        error => { code => $code, message => $message },
    };
}

sub _handle_frame {
    my ($self, $line) = @_;
    return 0 if length($line) > $MAX_FRAME_BYTES;
    my $json = JSON::PP->new->utf8(1)->max_depth(16);
    my $request = eval { $json->decode($line) };
    return 0 unless ref($request) eq 'HASH';
    my %allowed = map { $_ => 1 } qw(protocol_version request_id operation operation_id arguments);
    return 0 if grep { !$allowed{$_} } keys %$request;
    return 0 unless keys(%$request) == 4 || keys(%$request) == 5;
    my $id = $request->{request_id};
    return 0 unless defined($id) && !ref($id) &&
        $id =~ /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/;
    return 0 unless defined($request->{protocol_version}) &&
        !ref($request->{protocol_version}) && $request->{protocol_version} =~ /\A1\z/;
    return 0 unless defined($request->{operation}) && !ref($request->{operation}) &&
        $request->{operation} =~ /\A[a-z][a-z0-9_.-]{0,63}\z/;
    return 0 unless ref($request->{arguments}) eq 'HASH';
    my $operation_id = $request->{operation_id};
    if (exists $request->{operation_id}) {
        return 0 unless defined($operation_id) && !ref($operation_id) &&
            $operation_id =~ /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/;
    }
    return 0 if $MUTATING_OPERATION{$request->{operation}} && !defined($operation_id);

    my %digest_record = %$request;
    delete $digest_record{request_id};
    my $canonical = eval { JSON::PP->new->canonical(1)->utf8(1)->encode(\%digest_record) };
    return 0 unless defined $canonical;
    my $digest = sha256_hex($canonical);
    # Only requests that carry an operation ID are remembered. Read-only
    # requests are safe to run again, and caching each status poll would
    # evict the acknowledgements that protect mutations from a lost reply.
    # A request refused for coming before hello did nothing, and is not
    # remembered either: the same request after hello must run.
    my $cache_key = defined($operation_id) && $request->{operation} ne 'hello' &&
        $self->{handshake_complete} ? 'operation:' . $operation_id : undef;
    if (defined($cache_key) && (my $cached = $self->{request_cache}{$cache_key})) {
        if ($cached->{digest} ne $digest) {
            return $self->_queue_json(_error_response(
                $id, 'operation_id_conflict', 'operation_id was already used for different content', $operation_id));
        }
        my %replay = %{$cached->{response}};
        $replay{request_id} = $id;
        $replay{operation_id} = $operation_id if defined $operation_id;
        $replay{replayed} = JSON::PP::true;
        return $self->_queue_json(\%replay);
    }

    my $response;
    if (!$self->{handshake_complete}) {
        if ($request->{operation} ne 'hello' || keys %{$request->{arguments}}) {
            $response = _error_response($id, 'handshake_required',
                'send hello with an empty arguments object before other operations', $operation_id);
        } else {
            $self->{handshake_complete} = 1;
            $response = {
                protocol_version => $PROTOCOL_VERSION,
                request_id => $id,
                    (defined($operation_id) ? (operation_id => $operation_id) : ()),
                ok => JSON::PP::true,
                result => {
                    engine_instance_id => $self->{instance_id},
                    event_sequence => $self->{event_sequence},
                    capabilities => [qw(status source.configure source.connect
                        source.disconnect source.remove search.find search.status search.cancel
                    search.download manifest.download job.status
                    job.find_by_operation job.cancel adverts.list source.login
                    searchbot.hold searchbot.held_download browse.start browse.status
                    list.request list.download)],
                },
            };
        }
    } elsif ($request->{operation} eq 'hello') {
        $response = _error_response($id, 'already_connected',
            'hello is valid only as the first request on a bridge connection', $operation_id);
    } else {
        my $result = eval { $self->{on_request}->($request->{operation},
            $request->{arguments}, $request->{request_id}, $operation_id) };
        if ($@) {
            my $error = $@;
            $error =~ s/[\r\n]+/ /g;
            $response = _error_response($id, 'engine_error', substr($error, 0, 512), $operation_id);
        } elsif (ref($result) eq 'HASH' && $result->{__bridge_error}) {
            $response = _error_response($id, $result->{code} // 'request_refused',
                $result->{message} // 'request refused', $operation_id);
        } elsif (ref($result) eq 'HASH') {
            $response = {
                protocol_version => $PROTOCOL_VERSION,
                request_id => $id,
                (defined($operation_id) ? (operation_id => $operation_id) : ()),
                ok => JSON::PP::true,
                result => $result,
            };
        } else {
            $response = _error_response($id, 'invalid_engine_response',
                'engine returned an invalid response', $operation_id);
        }
    }

    if (defined $cache_key) {
        $self->{request_cache}{$cache_key} = { digest => $digest, response => $response };
        push @{$self->{request_order}}, $cache_key;
        while (@{$self->{request_order}} > $MAX_REQUEST_CACHE) {
            my $expired = shift @{$self->{request_order}};
            delete $self->{request_cache}{$expired};
        }
    }
    return $self->_queue_json($response);
}

sub _queue_json {
    my ($self, $record) = @_;
    my $json = JSON::PP->new->canonical(1)->utf8(1);
    my $encoded = eval { $json->encode($record) };
    return 0 unless defined $encoded;
    if (length($encoded) > $MAX_FRAME_BYTES) {
        # A reply too large for one frame is refused, so that the controller
        # learns what happened and keeps its connection. An event is left
        # out; the gap in its sequence tells the controller to ask again.
        return 0 if defined($record->{type}) || !defined($record->{request_id});
        $encoded = eval { $json->encode(_error_response($record->{request_id},
            'response_too_large', 'the reply was too large to send',
            $record->{operation_id})) };
        return 0 unless defined($encoded) && length($encoded) <= $MAX_FRAME_BYTES;
    }
    $encoded .= "\n";
    if (!$self->{client} ||
            $self->{output_bytes} + length($encoded) > $MAX_PENDING_OUTPUT_BYTES) {
        $self->_close_client() if $self->{client};
        return 0;
    }
    push @{$self->{output_queue}}, { data => $encoded, offset => 0 };
    $self->{output_bytes} += length($encoded);
    unless ($self->{write_input}) {
        $self->{write_input} = $self->_add_input(
            fileno($self->{client}), Irssi::INPUT_WRITE,
            sub { $self->_write_ready() }, undef,
        );
        unless ($self->{write_input}) {
            $self->_close_client();
            return 0;
        }
    }
    return 1;
}

sub _write_ready {
    my ($self) = @_;
    my $client = $self->{client} or return;
    my $budget = $MAX_WRITE_BYTES;
    while ($budget > 0 && @{$self->{output_queue} || []}) {
        my $item = $self->{output_queue}[0];
        my $remaining = length($item->{data}) - $item->{offset};
        my $amount = $remaining < $budget ? $remaining : $budget;
        my $written = syswrite($client, $item->{data}, $amount, $item->{offset});
        if (!defined $written) {
            return if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
            $self->_close_client();
            return;
        }
        if ($written == 0) {
            $self->_close_client();
            return;
        }
        $item->{offset} += $written;
        $self->{output_bytes} -= $written;
        $budget -= $written;
        shift @{$self->{output_queue}}
            if $item->{offset} >= length($item->{data});
    }
    if (!@{$self->{output_queue} || []} && $self->{write_input}) {
        $self->_remove_input(delete $self->{write_input});
    }
}

sub publish_event {
    my ($self, $name, $payload) = @_;
    return 0 if $self->{closed};
    die 'invalid bridge event name'
        unless defined($name) && $name =~ /\A[a-z][a-z0-9_.-]{0,63}\z/;
    die 'bridge event payload must be an object' unless ref($payload) eq 'HASH';
    my $sequence = ++$self->{event_sequence};
    return 0 unless $self->{client} && $self->{handshake_complete};
    return $self->_queue_json({
        protocol_version => $PROTOCOL_VERSION,
        type => 'event',
        engine_instance_id => $self->{instance_id},
        event_sequence => $sequence,
        event => $name,
        payload => $payload,
    });
}

sub _close_client {
    my ($self) = @_;
    $self->_remove_timeout(delete $self->{drain_timer});
    $self->_remove_timeout(delete $self->{handshake_timer});
    $self->_remove_input(delete $self->{read_input});
    $self->_remove_input(delete $self->{write_input});
    if (my $client = delete $self->{client}) {
        close $client;
    }
    delete @{$self}{qw(client_buffer output_queue output_bytes handshake_complete)};
}

sub stop {
    my ($self) = @_;
    return 1 if $self->{closed};
    $self->{closed} = 1;
    $self->_close_client();
    $self->_remove_timeout(delete $self->{accept_retry_timer});
    $self->_remove_input(delete $self->{listener_input});
    if (my $listener = delete $self->{listener}) {
        close $listener;
    }
    if (defined($self->{path}) && $self->{socket_identity}) {
        my @current = lstat($self->{path});
        unlink $self->{path}
            if @current && -S _ && $current[0] == $self->{socket_identity}[0] &&
                $current[1] == $self->{socket_identity}[1];
    }
    $self->_release_lock();
    return 1;
}

1;
