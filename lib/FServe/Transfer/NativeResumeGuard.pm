package FServe::Transfer::NativeResumeGuard;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(ascii_nick_key parse_dcc_send parse_dcc_accept
    dcc_accept_lookup_port);
our $MAX_RETIRED_NATIVE_KEYS = 1000;

sub new {
    return bless { owner => undef }, $_[0];
}

sub ascii_nick_key {
    my ($nick) = @_;
    return unless defined($nick) && !ref($nick) && length($nick);
    my $key = $nick;
    $key =~ tr/A-Z/a-z/;
    return $key;
}

sub _uint {
    my ($value, $maximum) = @_;
    return unless defined($value) && !ref($value) && $value =~ /\A[0-9]+\z/;
    my $canonical = "$value";
    $canonical =~ s/\A0+(?=[0-9])//;
    return if length($canonical) > length($maximum) ||
        (length($canonical) == length($maximum) && $canonical gt $maximum);
    return $canonical;
}

sub _valid_dcc_address {
    my ($address) = @_;
    return unless defined($address) && !ref($address) &&
        length($address) <= 64 && $address !~ /[\x00-\x20\x7f]/;
    my $family = index($address, ':') >= 0 ? 'AF_INET6' : 'AF_INET';
    my $valid = eval {
        require Socket;
        my $af = $family eq 'AF_INET6' ? Socket::AF_INET6() : Socket::AF_INET();
        defined Socket::inet_pton($af, $address);
    };
    return $valid ? "$address" : undef;
}

sub _filename_and_tail {
    my ($data, $tail_count) = @_;
    return unless defined($data) && !ref($data) && length($data) <= 4096;
    return if $data =~ /[\x00-\x1f\x7f]/;
    my $filename;
    my $tail;
    if ($data =~ /\A"([^"\\]+)"\s+(.+)\z/) {
        ($filename, $tail) = ($1, $2);
    } elsif ($data =~ /\A([^\s"\\]+)\s+(.+)\z/) {
        ($filename, $tail) = ($1, $2);
    } else {
        return;
    }
    my @parts = split /\s+/, $tail;
    return unless @parts == $tail_count &&
        !grep { !defined($_) || !length($_) || /["\\]/ } @parts;
    return ($filename, @parts);
}

sub parse_dcc_send {
    my ($data) = @_;
    my ($filename, $address, $port, $size) = _filename_and_tail($data, 3);
    return unless defined $filename;
    $address = _uint($address, '4294967295');
    $port = _uint($port, '65535');
    $size = _uint($size, '9223372036854775807');
    return unless defined($address) && $port && defined($size) && $size;
    return { filename => $filename, address => $address,
        port => $port, size => $size };
}

sub parse_dcc_accept {
    my ($data) = @_;
    my ($filename, $port, $offset) = _filename_and_tail($data, 2);
    return unless defined $filename;
    $port = _uint($port, '65535');
    $offset = _uint($offset, '9223372036854775807');
    return unless $port && defined $offset;
    return { filename => $filename, port => $port, offset => $offset };
}

sub dcc_accept_lookup_port {
    my ($data) = @_;
    return unless defined($data) && !ref($data) && length($data) <= 4096;
    return if $data =~ /[\x00-\x1f\x7f]/;
    my @parts = split /\s+/, $data;
    return unless @parts >= 3;

    # Native Irssi accepts unquoted filenames containing spaces and locates
    # the DCC command port immediately before the final offset (ACCEPT) or
    # size (SEND). Its C parser applies atoi(), so recognize a leading plus
    # and numeric prefixes too; strict parsing still decides authorization.
    my $port_token = $parts[-2];
    return unless defined($port_token) && $port_token =~ /\A\+?([0-9]+)/;
    return _uint($1, '65535');
}

sub _stop {
    my ($reason) = @_;
    return { action => 'stop', reason => $reason };
}

sub _pass { return { action => 'pass' }; }

sub _owner_snapshot {
    my ($owner) = @_;
    return unless ref($owner) eq 'HASH';
    my %copy = %$owner;
    $copy{staging_identity} = { %{$owner->{staging_identity}} }
        if ref($owner->{staging_identity}) eq 'HASH';
    return \%copy;
}

sub _positive_integer {
    my ($value) = @_;
    return defined($value) && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
}

sub _safe_basename {
    my ($name) = @_;
    return defined($name) && !ref($name) && length($name) <= 1024 &&
        $name !~ m{[/\\"\x00-\x1f\x7f]};
}

sub _canonical_path {
    my ($path) = @_;
    return unless defined($path) && !ref($path) && length($path);
    require File::Spec;
    return File::Spec->canonpath(File::Spec->rel2abs($path));
}

sub _same_path {
    my ($left, $right) = @_;
    my ($a, $b) = (_canonical_path($left), _canonical_path($right));
    return defined($a) && defined($b) && $a eq $b;
}

sub _key_filename {
    my ($key) = @_;
    return unless ref($key) eq 'HASH';
    return $key->{filename} if defined $key->{filename};
    return $key->{offered_name};
}

sub _same_native_offer {
    my ($left, $right, %options) = @_;
    return 0 unless ref($left) eq 'HASH' && ref($right) eq 'HASH' &&
        ($left->{type} // '') eq 'GET' && ($right->{type} // '') eq 'GET' &&
        ($left->{lifecycle_identity} // '') eq ($right->{lifecycle_identity} // '') &&
        ($left->{server_tag} // '') eq ($right->{server_tag} // '') &&
        ($left->{sender_key} // '') eq ($right->{sender_key} // '') &&
        ($left->{filename} // '') eq ($right->{filename} // '') &&
        ($left->{address} // '') eq ($right->{address} // '') &&
        ($left->{port} // '') eq ($right->{port} // '') &&
        ($left->{size} // '') eq ($right->{size} // '');
    return 0 if exists($right->{passive}) &&
        (!exists($left->{passive}) || !!$left->{passive} != !!$right->{passive});
    for my $field (qw(server_identity connection_epoch)) {
        next unless exists $right->{$field};
        return 0 unless defined($left->{$field}) &&
            "$left->{$field}" eq "$right->{$field}";
    }
    my $left_has_file = defined($left->{file}) && length($left->{file}) ? 1 : 0;
    my $right_has_file = defined($right->{file}) && length($right->{file}) ? 1 : 0;
    my $allow_uninitialized_file = $options{allow_uninitialized_file} &&
        !$left_has_file && ref($left->{staging_identity}) ne 'HASH';
    unless ($allow_uninitialized_file || $options{ignore_file}) {
        return 0 if $left_has_file != $right_has_file;
        return 0 if $left_has_file && !_same_path($left->{file}, $right->{file});
    }
    return 1 if $allow_uninitialized_file;
    return 1 if $options{ignore_file};
    return 1 unless ref($right->{staging_identity}) eq 'HASH';
    return 0 unless ref($left->{staging_identity}) eq 'HASH';
    for my $field (qw(device inode size)) {
        return 0 unless defined($left->{staging_identity}{$field}) &&
            defined($right->{staging_identity}{$field}) &&
            "$left->{staging_identity}{$field}" eq
                "$right->{staging_identity}{$field}";
    }
    return 1;
}

sub _native_file_matches_expected {
    my ($record, $path, $identity, %options) = @_;
    return 0 unless ref($record) eq 'HASH' && ref($identity) eq 'HASH';
    my $has_file = defined($record->{file}) && length($record->{file}) ? 1 : 0;
    unless ($has_file) {
        return $options{allow_uninitialized} &&
            ref($record->{staging_identity}) ne 'HASH' ? 1 : 0;
    }
    return 0 unless _same_path($record->{file}, $path) &&
        ref($record->{staging_identity}) eq 'HASH';
    for my $field (qw(device inode size)) {
        return 0 unless defined($record->{staging_identity}{$field}) &&
            defined($identity->{$field}) &&
            "$record->{staging_identity}{$field}" eq "$identity->{$field}";
    }
    return 1;
}

sub reserve_owner {
    my ($self, %args) = @_;
    die 'native resume guard already has an owner' if $self->{owner};
    die 'native resume retired-key history reached its safety bound'
        if @{$self->{retired} || []} >= $MAX_RETIRED_NATIVE_KEYS;
    my $owner = $args{owner};
    my $candidate = $args{candidate};
    my $pending = $args{pending};
    die 'native resume owner is malformed' unless ref($owner) eq 'HASH';
    die 'native DCC candidate is malformed' unless ref($candidate) eq 'HASH';
    die 'pending DCC inventory is unavailable' unless ref($pending) eq 'ARRAY';

    for my $field (qw(job_id process_incarnation connection_identity server_tag
            sender casemapping offered_name target_nick native_lifecycle_identity
            staging_path)) {
        die "native resume owner lacks $field"
            unless defined($owner->{$field}) && !ref($owner->{$field}) &&
                length("$owner->{$field}");
    }
    die 'native resume job id is invalid'
        unless $owner->{job_id} =~ /\Ajob-[a-f0-9]{32}\z/;
    die 'native resume connection epoch is invalid'
        unless _positive_integer($owner->{connection_epoch});
    die 'native resume casemapping is invalid'
        unless $owner->{casemapping} =~ /\A(?:ascii|strict-rfc1459|rfc1459)\z/;
    die 'native resume passive offers are unsupported'
        if !exists($owner->{passive}) || $owner->{passive};
    die 'native resume sender is invalid'
        unless defined(ascii_nick_key($owner->{sender}));
    die 'native resume offered name is unsupported'
        unless _safe_basename($owner->{offered_name});
    my $address = _valid_dcc_address($owner->{address});
    my $port = _uint($owner->{port}, '65535');
    my $size = _uint($owner->{advertised_size}, '9223372036854775807');
    my $offset = _uint($owner->{requested_offset}, '9223372036854775807');
    die 'native resume address, port, or size is invalid'
        unless defined($address) && defined($port) && $port ne '0' &&
            defined($size) && $size ne '0';
    die 'native resume offset is invalid'
        unless defined($offset) && $offset ne '0' &&
            (length($offset) < length($size) ||
                (length($offset) == length($size) && $offset lt $size));
    die 'native resume deadline is invalid'
        unless defined($owner->{deadline}) && $owner->{deadline} =~
            /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ &&
            defined($args{now}) && $args{now} =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ &&
            $owner->{deadline} > $args{now};
    die 'native resume staging identity is malformed'
        unless ref($owner->{staging_identity}) eq 'HASH';
    my %staging_identity;
    for my $field (qw(device inode size)) {
        my $value = _uint($owner->{staging_identity}{$field},
            '9223372036854775807');
        die 'native resume staging identity is malformed'
            unless defined $value;
        $staging_identity{$field} = $value;
    }
    die 'native resume staging size does not match requested offset'
        unless $staging_identity{size} eq $offset;
    my $target_key = ascii_nick_key($owner->{target_nick});
    die 'native resume target nick is invalid' unless defined $target_key;

    # Keep all DCC tuple components in canonical decimal form. Irssi's native
    # lookup uses numeric ports, so e.g. "0087" must collide with "87".
    $owner = {
        %$owner,
        address => $address,
        port => $port,
        advertised_size => $size,
        requested_offset => $offset,
        staging_identity => \%staging_identity,
    };

    die 'native DCC candidate is not the expected GET'
        unless _same_native_offer($candidate, {
            %$candidate,
            type => 'GET',
            server_tag => $owner->{server_tag},
            server_identity => $owner->{connection_identity},
            connection_epoch => $owner->{connection_epoch},
            sender_key => ascii_nick_key($owner->{sender}),
            filename => $owner->{offered_name},
            address => $owner->{address},
            port => $owner->{port},
            size => $owner->{advertised_size},
            passive => 0,
            lifecycle_identity => $owner->{native_lifecycle_identity},
            file => $owner->{staging_path},
            staging_identity => $owner->{staging_identity},
        }, allow_uninitialized_file => 1);

    my @owned_candidates = grep {
        ref($_) eq 'HASH' &&
            ($_->{lifecycle_identity} // '') eq $owner->{native_lifecycle_identity}
    } @$pending;
    die 'native DCC inventory does not contain exactly the owned offer'
        unless @owned_candidates == 1 &&
            _same_native_offer($candidate, $owned_candidates[0],
                ignore_file => 1) &&
            _native_file_matches_expected($owned_candidates[0],
                $owner->{staging_path}, $owner->{staging_identity},
                allow_uninitialized =>
                    !(defined($candidate->{file}) && length($candidate->{file})) &&
                    ref($candidate->{staging_identity}) ne 'HASH');

    my $sender_key = ascii_nick_key($owner->{sender});
    for my $retired (@{$self->{retired} || []}) {
        next unless ($retired->{sender_key} // '') eq $sender_key;
        die 'native DCC lookup key collides with a recently retired resume owner'
            if ($retired->{filename} // '') eq $owner->{offered_name} ||
                ($retired->{port} // '') eq $owner->{port};
    }
    for my $other (@$pending) {
        next unless ref($other) eq 'HASH';
        next if ($other->{lifecycle_identity} // '') eq
            $owner->{native_lifecycle_identity};
        die 'native DCC inventory contains an uninspectable GET'
            if uc($other->{type} // '') eq 'GET' &&
                (!defined($other->{sender_key}) || !defined($other->{filename}) ||
                 !defined(_uint($other->{port}, '65535')));
        next unless uc($other->{type} // '') eq 'GET';
        next unless ($other->{sender_key} // '') eq $sender_key;
        my $other_port = _uint($other->{port}, '65535');
        die 'native DCC SEND or ACCEPT lookup key is already occupied'
            if ($other->{filename} // '') eq $owner->{offered_name} ||
                (defined($other_port) && $other_port eq $owner->{port});
    }

    $self->{owner} = {
        %$owner,
        sender_key => $sender_key,
        target_key => $target_key,
        accepted => 0,
        state => 'negotiating',
    };
    return _owner_snapshot($self->{owner});
}

sub owner {
    my ($self) = @_;
    return unless $self->{owner};
    return _owner_snapshot($self->{owner});
}

sub begin_native_open {
    my ($self, %args) = @_;
    my $owner = $self->{owner} or return;
    return unless ($args{job_id} // '') eq ($owner->{job_id} // '') &&
        ($args{native_lifecycle_identity} // '') eq
            ($owner->{native_lifecycle_identity} // '') &&
        ($owner->{state} // '') eq 'negotiating' &&
        !$owner->{accepted} && !$owner->{native_open_attempted};
    $owner->{native_open_attempted} = 1;
    $owner->{state} = 'opening';
    return _owner_snapshot($owner);
}

sub active {
    my ($self) = @_;
    return $self->{owner} || @{$self->{retired} || []} ? 1 : 0;
}

sub incoming_send {
    my ($self, %args) = @_;
    my $sender_key = ascii_nick_key($args{sender}) // '';
    my $owner = $self->{owner};
    my @keys = @{$self->{retired} || []};
    unshift @keys, $owner if $owner;
    return _pass() unless @keys;
    # Irssi's nick/name and nick/port dispatch keys are process-wide. The
    # connection identity authorizes the owned continuation, but cannot scope
    # the native collision domain.
    @keys = grep { ($_->{sender_key} // '') eq $sender_key } @keys;
    return _pass() unless @keys;
    my $parsed = parse_dcc_send($args{data});
    my $name = $parsed ? $parsed->{filename} : undef;
    my $native_port = $parsed ? $parsed->{port}
        : dcc_accept_lookup_port($args{data});
    return _stop('SEND collides with the active native nick/port lookup key')
        if $owner && ($owner->{sender_key} // '') eq $sender_key &&
            defined($native_port) && $native_port == $owner->{port};
    return _stop('SEND collides with a retired native nick/port lookup key')
        if defined($native_port) && grep {
            ($_->{sender_key} // '') eq $sender_key &&
                defined($_->{port}) && $_->{port} == $native_port
        } @{$self->{retired} || []};
    if (!defined $name) {
        my $raw = $args{data} // '';
        if ($raw =~ /\A"((?:[^"\\]|\\.)*)"(?:\s|\z)/) {
            my $quoted_name = $1;
            $quoted_name =~ s/\\(.)/$1/g;
            return _stop('unsupported quoted offer matches the guarded native filename')
                if grep { ($_->{sender_key} // '') eq $sender_key &&
                    (_key_filename($_) // '') eq $quoted_name } @keys;
        }
        for my $key (@keys) {
            next unless ($key->{sender_key} // '') eq $sender_key;
            my $filename = _key_filename($key) // '';
            next unless length $filename;
            my $quoted = '"' . $filename . '"';
            return _stop('unparseable offer may collide with a guarded native filename')
                if $raw =~ /\A(?:\Q$quoted\E|\Q$filename\E)(?:\s|\z)/;
        }
        return _pass();
    }
    return _stop('SEND matches a guarded globally keyed native nick/filename request')
        if grep { ($_->{sender_key} // '') eq $sender_key &&
            (_key_filename($_) // '') eq $name } @keys;
    return _pass();
}

sub incoming_accept {
    my ($self, %args) = @_;
    my $sender_key = ascii_nick_key($args{sender}) // '';
    my $owner = $self->{owner};

    my $parsed = parse_dcc_accept($args{data});
    my $port = $parsed ? $parsed->{port} : undef;
    $port = dcc_accept_lookup_port($args{data}) unless defined $port;
    unless (defined $port) {
        my $raw = $args{data} // '';
        my @keys = @{$self->{retired} || []};
        unshift @keys, $owner if $owner;
        for my $key (@keys) {
            next unless ($key->{sender_key} // '') eq $sender_key;
            my $name = _key_filename($key) // '';
            my $quoted = '"' . $name . '"';
            return _stop('unparseable ACCEPT may target a guarded native filename')
                if $raw =~ /\A(?:\Q$quoted\E|\Q$name\E)(?:\s|\z)/;
        }
        return _pass();
    }
    return _stop('late ACCEPT targets a retired native resume nick/port')
        if grep { ($_->{sender_key} // '') eq $sender_key &&
            ($_->{port} // '') == $port } @{$self->{retired} || []};
    # Stop any ACCEPT that occupies the process-wide native lookup key before
    # exact connection/epoch checks decide whether it belongs to this owner.
    return _pass() unless $owner && $sender_key eq $owner->{sender_key} &&
        $port == $owner->{port};
    return _stop('duplicate or late ACCEPT targets the owned native nick/port')
        if $owner->{accepted};

    my $live = $args{native_record};
    my $exact = $parsed && !$args{chat} && $args{server_connected} &&
        ($args{server_identity} // '') eq $owner->{connection_identity} &&
        ($args{connection_epoch} // 0) == $owner->{connection_epoch} &&
        ($args{sender_key} // '') eq $owner->{sender_key} &&
        $parsed->{filename} eq $owner->{offered_name} &&
        $parsed->{port} eq $owner->{port} &&
        $parsed->{offset} eq $owner->{requested_offset} &&
        ($args{target_key} // '') eq $owner->{target_key} &&
        defined($args{now}) && !ref($args{now}) &&
        $args{now} =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ &&
        $args{now} < $owner->{deadline} &&
        ref($live) eq 'HASH' && _same_native_offer($live, {
            type => 'GET', lifecycle_identity => $owner->{native_lifecycle_identity},
            server_tag => $owner->{server_tag}, sender_key => $owner->{sender_key},
            server_identity => $owner->{connection_identity},
            connection_epoch => $owner->{connection_epoch},
            filename => $owner->{offered_name}, address => $owner->{address},
            port => $owner->{port}, size => $owner->{advertised_size},
            passive => 0,
            file => $owner->{staging_path},
            staging_identity => $owner->{staging_identity},
        });
    return _stop('ACCEPT failed exact connection, epoch, offer, target, offset, deadline, or lifecycle validation')
        unless $exact;

    my $inventory = $args{native_inventory};
    return _stop('ACCEPT refused because the fresh native DCC inventory is unavailable')
        unless ref($inventory) eq 'ARRAY';
    for my $record (@$inventory) {
        return _stop('ACCEPT refused because a native DCC record is uninspectable')
            unless ref($record) eq 'HASH';
        next unless uc($record->{type} // '') eq 'GET';
        next if ($record->{lifecycle_identity} // '') eq
            $owner->{native_lifecycle_identity};
        my $record_port = _uint($record->{port}, '65535');
        return _stop('ACCEPT refused because another GET has an uninspectable lookup key')
            unless defined($record->{sender_key}) &&
                defined($record->{filename}) && defined($record_port);
        return _stop('ACCEPT refused because another GET occupies the native nick/filename or nick/port key')
            if $record->{sender_key} eq $owner->{sender_key} &&
                ($record->{filename} eq $owner->{offered_name} ||
                 $record_port eq $owner->{port});
    }

    $owner->{accepted} = 1;
    $owner->{state} = 'accepted';
    return { action => 'pass', owner => _owner_snapshot($owner) };
}

sub clear_owner {
    my ($self, %args) = @_;
    my $owner = $self->{owner} or return 0;
    return 0 unless ($args{job_id} // '') eq $owner->{job_id} &&
        ($args{native_lifecycle_identity} // '') eq
            $owner->{native_lifecycle_identity};
    return 0 if @{$self->{retired} || []} >= $MAX_RETIRED_NATIVE_KEYS;
    push @{$self->{retired}}, {
        sender_key => $owner->{sender_key},
        filename => $owner->{offered_name},
        port => $owner->{port},
        server_identity => $owner->{connection_identity},
        connection_epoch => $owner->{connection_epoch},
    };
    delete $self->{owner};
    return 1;
}

1;
