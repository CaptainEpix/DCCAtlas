package FServe::Discovery::SysResetFind;

use strict;
use warnings;

use FServe::Model qw(new_remote_file parse_slot_counts);

sub new {
    my ($class, %args) = @_;

    return bless {
        network_id       => $args{network_id},
        server_tag       => $args{server_tag},
        discovery_channel => $args{discovery_channel},
        trigger_mode     => defined($args{trigger_mode}) ? $args{trigger_mode} : 'channel_text',
        source_timestamp => $args{source_timestamp},
        states           => {},
        next_block_id    => 0,
    }, $class;
}

sub _sender_key {
    my ($sender) = @_;
    return lc($sender // '');
}

sub _clean_line {
    my ($raw) = @_;
    $raw = '' unless defined $raw;

    # Accommodate the display form used in the captured fixtures while still
    # accepting the payload text an Irssi signal would normally provide.
    $raw =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g;
    $raw =~ s/\x03(?:\d{1,2})?(?:,\d{1,2})?//g;
    $raw =~ s/[\x02\x0F\x11\x16\x1D\x1E\x1F]//g;
    $raw =~ s/[\r\0]//g;
    $raw =~ s/^\s+//;
    $raw =~ s/\s+$//;
    $raw =~ s/^<[^>]+>\s*//;
    return $raw;
}

sub _copy_results {
    my ($results) = @_;
    return [ map { { %$_ } } @{$results || []} ];
}

sub _normalize_trigger {
    my ($raw, $sender_nick, $default_mode) = @_;
    $raw = _clean_line($raw);

    # SysReset serializes CTCP triggers as a mIRC command in @Find output,
    # e.g. "/ctcp CaptainEpix !fserve2". Store the actual CTCP payload and
    # its invocation mode so a selected result can be fetched correctly.
    if ($raw =~ m{^/?ctcp(?:\s|$)}i) {
        return (undef, undef, 'unsupported CTCP trigger format')
            unless $raw =~ m{^/?ctcp\s+(\S+)\s+(\S+)$}i;

        my ($target_nick, $payload) = ($1, $2);
        return (undef, undef, 'CTCP trigger target does not match response sender')
            unless lc($target_nick) eq lc($sender_nick // '');
        return (undef, undef, 'unsafe CTCP trigger payload')
            unless $payload =~ /^[^\s\x00-\x1f\x7f]{1,128}$/;

        return ($payload, 'ctcp', undef);
    }

    return ($raw, $default_mode, undef);
}

sub _event {
    my ($type, $state, %extra) = @_;
    return {
        type        => $type,
        sender_nick => $state->{sender_nick},
        block_id    => $state->{block_id},
        %extra,
    };
}

sub _new_state {
    my ($self, $sender) = @_;
    return {
        sender_nick => $sender,
        block_id    => ++$self->{next_block_id},
        active      => 1,
        results     => [],
        section     => undef,
    };
}

sub feed_line {
    my ($self, $sender, $raw_line) = @_;
    my $sender_text = defined($sender) ? $sender : '';
    my $key = _sender_key($sender_text);
    return [ { type => 'parse_error', reason => 'sender_nick is required' } ]
        unless length $key;

    my $line = _clean_line($raw_line);
    return [] unless length $line;

    my $state = $self->{states}{$key};

    # SysReset's header, or FServe.pl's: "Find Results for (Star.*Wars) -
    # [FServe.pl 2.0.0]" (2026-10-20). The rest of FServe.pl's reply has the
    # same shape in other words.
    if ($line =~ /^\[\s*\@Find\s+Results\s*\](?:\s*-=\s*SysReset(?:\s+[\d.]+)?\s*=-)?\s*$/i ||
            $line =~ /^(?:Find\s+Results\s+for\s+\(.*\)|\(\s*\@Find\s+Results\s*\))\s*-\s*\[\s*FServe\.pl(?:\s+[\d.]+)?\s*\]\s*$/i) {
        my @events;
        if ($state && $state->{active}) {
            push @events, _event(
                'end', $state,
                complete => 0,
                reason   => 'replaced-by-new-header',
                results  => _copy_results($state->{results}),
            );
        }
        $state = _new_state($self, $sender_text);
        $self->{states}{$key} = $state;
        push @events, _event('header', $state, text => $line);
        return \@events;
    }

    # This marker is allowed to close a block even if the sender omitted its
    # header, but it is still surfaced as unmatched rather than fabricating a
    # successful result set.
    if ($line =~ /^End\s+of\s+\@?Find\.?\s*$/i) {
        return [ {
            type        => 'end',
            sender_nick => $sender_text,
            complete    => 0,
            reason      => 'no-active-block',
            results     => [],
        } ] unless $state && $state->{active};

        $state->{active} = 0;
        my $results = _copy_results($state->{results});
        return [ _event('end', $state, complete => 1, results => $results) ];
    }

    if ($line =~ /^Found\s+\[(\d+)\]\s+files?\s+on\s+Trigger:\[([^\]]+)\]\s*-\s*Sends:\[([^\]]+)\]\s*-\s*Queues:\[([^\]]+)\]\s*$/i ||
            $line =~ /^Found\s+(\d+)\s+file\(s\)\s+on\s+trigger:\((.+?)\)\s+Sends:\(([^)]*)\)\s+Queues:\(([^)]*)\)\s*$/i) {
        return [ {
            type        => 'parse_error',
            sender_nick => $sender_text,
            reason      => 'trigger section arrived before @Find header',
            text        => $line,
        } ] unless $state && $state->{active};

        # A malformed/rejected section must not leave the preceding trigger
        # active for the next File line.
        $state->{section} = undef;
        my ($found_count, $trigger_display, $sends_raw, $queues_raw) = ($1, $2, $3, $4);
        my ($send_used, $send_max) = parse_slot_counts($sends_raw);
        my ($queue_used, $queue_max) = parse_slot_counts($queues_raw);
        return [ _event(
            'parse_error', $state,
            reason => 'invalid Sends or Queues counts',
            text   => $line,
        ) ] unless defined($send_used) && defined($queue_used);

        my ($trigger_raw, $trigger_mode, $trigger_error) = _normalize_trigger(
            $trigger_display, $sender_text, $self->{trigger_mode}
        );
        return [ _event(
            'parse_error', $state,
            reason => $trigger_error,
            text   => $line,
        ) ] if $trigger_error;

        my $section = {
            found_count => 0 + $found_count,
            trigger_raw => $trigger_raw,
            trigger_mode => $trigger_mode,
            sends_used  => $send_used,
            sends_max   => $send_max,
            queues_used => $queue_used,
            queues_max  => $queue_max,
        };
        $state->{section} = $section;
        return [ _event('section', $state, section => { %$section }) ];
    }

    if ($line =~ /^File:\s*\[(.*)\]\s*-\s*Size\s*\[([^\]]*)\]\s*$/i ||
            $line =~ /^\d+\.\s*File:\s*\((.*)\)\s+Size:\s*\(([^()]*)\)\s*$/i) {
        return [ {
            type        => 'parse_error',
            sender_nick => $sender_text,
            reason      => 'file result arrived before @Find trigger section',
            text        => $line,
        } ] unless $state && $state->{active} && $state->{section};

        my ($remote_path, $size_raw) = ($1, $2);
        my $section = $state->{section};
        my $result;
        my $error;
        eval {
            $result = new_remote_file(
                network_id         => $self->{network_id},
                server_tag         => $self->{server_tag},
                server_nick        => $sender_text,
                trigger_raw        => $section->{trigger_raw},
                trigger_mode       => $section->{trigger_mode},
                remote_path        => $remote_path,
                size_raw           => $size_raw,
                section_found_count => $section->{found_count},
                source             => 'find',
                source_timestamp   => $self->{source_timestamp},
                sends_used         => $section->{sends_used},
                sends_max          => $section->{sends_max},
                queues_used        => $section->{queues_used},
                queues_max         => $section->{queues_max},
                discovery_block_id => $state->{block_id},
                discovery_channel  => $self->{discovery_channel},
            );
            1;
        } or $error = $@ || 'invalid file result';

        return [ _event(
            'parse_error', $state,
            reason => $error,
            text   => $line,
        ) ] if $error;

        push @{$state->{results}}, $result;
        return [ _event('result', $state, result => { %$result }) ];
    }

    # Queue/flood/status lines are intentionally opaque. The caller can show
    # them to the user without treating them as a zero-result response.
    if ($line =~ /\b(?:flood(?:\s+protection|ed|ing)?|rate[\s-]*limit(?:ed|ing)?|too\s+many\s+(?:requests|searches)|try\s+again\s+(?:later|in\s+\d+)|please\s+wait)\b/i) {
        return [ {
            type        => 'status',
            sender_nick => $sender_text,
            text        => $line,
        } ];
    }

    # Query echoes and unrelated channel chatter are harmless noise.
    return [];
}

sub timeout {
    my ($self, $sender) = @_;
    my $key = _sender_key($sender);
    my $state = $self->{states}{$key};

    return [ {
        type        => 'timeout',
        sender_nick => $sender,
        had_block   => 0,
        results     => [],
        reason      => 'no-active-block',
    } ] unless $state && $state->{active};

    $state->{active} = 0;
    return [ _event(
        'timeout',
        $state,
        had_block => 1,
        results   => _copy_results($state->{results}),
        reason    => 'collection-window-expired',
    ) ];
}

sub active_senders {
    my ($self) = @_;
    return [ map { $self->{states}{$_}{sender_nick} }
        grep { $self->{states}{$_}{active} } keys %{$self->{states}} ];
}

sub results_for {
    my ($self, $sender) = @_;
    my $state = $self->{states}{_sender_key($sender)};
    return [] unless $state;
    return _copy_results($state->{results});
}

1;
