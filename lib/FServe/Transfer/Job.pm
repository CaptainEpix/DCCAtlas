package FServe::Transfer::Job;

use strict;
use warnings;
use Exporter qw(import);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use FServe::ConnectionIdentity qw(tuple_key);

our @EXPORT_OK = qw(
    new_job
    clone_job
    transition_job
    resume_binding_fingerprint
    resume_partial_fingerprint
    job_identity_key
    tuple_keys_for_job
    is_terminal
    validate_job
    unfinished_count
);

my %TERMINAL = map { $_ => 1 } qw(complete failed cancelled expired stale refused_without_queue);
my %ALLOWED = (
    held => { map { $_ => 1 } qw(ready cancelled stale expired) },
    ready => { map { $_ => 1 } qw(preparing held backoff cancelled stale expired needs_attention) },
    preparing => { map { $_ => 1 } qw(backoff dispatch_intent held failed cancelled stale needs_attention) },
    backoff => { map { $_ => 1 } qw(ready preparing cancelled expired needs_attention) },
    dispatch_intent => { map { $_ => 1 } qw(held awaiting_offer remote_queued receiving cancelled failed refused_without_queue needs_attention) },
    awaiting_offer => { map { $_ => 1 } qw(remote_queued receiving expired cancelled failed refused_without_queue needs_attention) },
    remote_queued => { map { $_ => 1 } qw(receiving expired cancelled failed refused_without_queue needs_attention) },
    receiving => { map { $_ => 1 } qw(finalizing interrupted failed cancelled needs_attention) },
    finalizing => { map { $_ => 1 } qw(complete failed needs_attention) },
    interrupted => { map { $_ => 1 } qw(resume_pending cancelled expired needs_attention) },
    resume_pending => { map { $_ => 1 } qw(receiving interrupted failed needs_attention) },
    needs_attention => { map { $_ => 1 } qw(interrupted cancelled expired) },
    refused_without_queue => {}, complete => {}, failed => {}, cancelled => {}, expired => {}, stale => {},
);

sub resume_binding_fingerprint {
    my ($job) = @_;
    return sha256_hex(JSON::PP->new->canonical(1)->encode({
        id => $job->{id}, provider => $job->{provider},
        network_profile => $job->{network_profile}, selection => $job->{selection},
        context => $job->{context}, limits => $job->{limits},
        trusted_content_digest => $job->{trusted_content_digest},
    }));
}

sub resume_partial_fingerprint {
    my ($partial) = @_;
    return unless defined $partial;
    die 'resume partial evidence must be an object' unless ref($partial) eq 'HASH';
    return sha256_hex(JSON::PP->new->canonical(1)->utf8(1)->encode($partial));
}

sub _clone_value {
    my ($value) = @_;
    return unless ref($value) eq 'HASH';
    my $json = JSON::PP->new->canonical(1)->allow_nonref(0);
    return $json->decode($json->encode($value));
}

sub _opaque_id {
    my ($seed) = @_;
    my $entropy = join("\0", $seed // '', $$, time, rand(), {}, rand());
    return 'job-' . substr(sha256_hex($entropy), 0, 32);
}

sub _trusted_content_digest {
    my ($value, %options) = @_;
    die 'trusted content digest must be an object' unless ref($value) eq 'HASH';
    my %digest_keys = map { $_ => 1 } qw(sha256 provenance);
    die 'trusted content digest has unsupported fields'
        if grep { !$digest_keys{$_} } keys %$value;
    die 'trusted content digest requires sha256 and provenance'
        unless exists($value->{sha256}) && exists($value->{provenance});
    die 'trusted content digest must be a strict SHA-256 hex value'
        unless defined($value->{sha256}) && !ref($value->{sha256}) &&
            $value->{sha256} =~ /\A[0-9A-Fa-f]{64}\z/;

    my $provenance = $value->{provenance};
    die 'trusted content digest provenance must be an object'
        unless ref($provenance) eq 'HASH';
    my %provenance_keys = map { $_ => 1 } qw(kind asserted_by asserted_at);
    die 'trusted content digest provenance has unsupported fields'
        if grep { !$provenance_keys{$_} } keys %$provenance;
    die 'trusted content digest provenance is incomplete'
        unless exists($provenance->{kind}) && exists($provenance->{asserted_by}) &&
            exists($provenance->{asserted_at});
    die 'trusted content digest provenance kind is unsupported'
        unless defined($provenance->{kind}) && !ref($provenance->{kind}) &&
            $provenance->{kind} =~ /\A(?:pre_dispatch_operator_attestation|test_fixture)\z/;
    die 'trusted content digest provenance asserted_by must contain 1-128 printable ASCII characters'
        unless defined($provenance->{asserted_by}) && !ref($provenance->{asserted_by}) &&
            $provenance->{asserted_by} =~ /\A[\x20-\x7e]{1,128}\z/;
    die 'trusted content digest provenance asserted_at is invalid'
        unless defined($provenance->{asserted_at}) && !ref($provenance->{asserted_at}) &&
            $provenance->{asserted_at} =~ /\A[0-9]{1,12}\z/;
    my $provenance_bytes = JSON::PP->new->canonical(1)->utf8(1)->encode($provenance);
    die 'trusted content digest provenance exceeds 1 KiB'
        if length($provenance_bytes) > 1024;

    my $sha256 = $options{normalize} ? lc($value->{sha256}) : $value->{sha256};
    die 'trusted content digest SHA-256 is not normalized'
        unless $sha256 =~ /\A[a-f0-9]{64}\z/;
    return {
        sha256 => $sha256,
        provenance => _clone_value($provenance),
    };
}

sub _resume_intent {
    my ($value, $job) = @_;
    die 'resume intent must be an object' unless ref($value) eq 'HASH';
    my %allowed = map { $_ => 1 } qw(
        schema_version attempt_id capability_profile process_incarnation
        connection_identity connection_epoch server_tag
        previous_lifecycle_identity offer_lifecycle_identity sender
        offered_basename total_size offset partial_sha256 expected_sha256
        source_path snapshot_path staging_root snapshot_identity
        snapshot_directory_identities get_dispatched_by_admission
        selection_replayed_by_admission partial_evidence partial_binding_sha256
        job_binding_sha256 created_at
    );
    die 'resume intent has unsupported fields'
        if grep { !$allowed{$_} } keys %$value;
    die 'resume intent is incomplete'
        if grep { !exists $value->{$_} } keys %allowed;
    die 'unsupported resume intent schema'
        unless defined($value->{schema_version}) && $value->{schema_version} == 1;
    die 'resume attempt id is invalid'
        unless defined($value->{attempt_id}) &&
            $value->{attempt_id} =~ /\Aresume-[a-f0-9]{32}\z/;
    for my $field (qw(capability_profile process_incarnation connection_identity
            offer_lifecycle_identity sender offered_basename source_path snapshot_path
            staging_root)) {
        die "resume intent $field is invalid"
            unless defined($value->{$field}) && !ref($value->{$field}) &&
                length($value->{$field}) && length($value->{$field}) <= 4096 &&
                $value->{$field} !~ /[\x00-\x1f\x7f]/;
    }
    die 'resume capability profile name is invalid'
        unless $value->{capability_profile} =~ /\A[\x20-\x7e]{1,96}\z/;
    die 'resume offer lifecycle identity is invalid'
        unless $value->{offer_lifecycle_identity} =~ /\A[\x21-\x7e]{1,128}\z/;
    die 'resume prior lifecycle identity is invalid'
        unless defined($value->{previous_lifecycle_identity}) &&
            !ref($value->{previous_lifecycle_identity}) &&
            $value->{previous_lifecycle_identity} =~ /\A[\x21-\x7e]{1,128}\z/;
    die 'resume connection epoch is invalid'
        unless defined($value->{connection_epoch}) &&
            $value->{connection_epoch} =~ /\A[1-9][0-9]{0,18}\z/;
    for my $field (qw(total_size offset created_at)) {
        die "resume intent $field is invalid"
            unless defined($value->{$field}) && !ref($value->{$field}) &&
                $value->{$field} =~ /\A(?:0|[1-9][0-9]{0,18})\z/;
    }
    die 'resume offset must be strictly inside the offered file'
        unless $value->{offset} > 0 &&
            (length($value->{offset}) < length($value->{total_size}) ||
                (length($value->{offset}) == length($value->{total_size}) &&
                    $value->{offset} lt $value->{total_size}));
    for my $field (qw(partial_sha256 expected_sha256)) {
        die "resume intent $field is invalid"
            unless defined($value->{$field}) &&
                $value->{$field} =~ /\A[a-f0-9]{64}\z/;
    }
    die 'resume intent is not bound to the immutable job digest'
        unless ref($job->{trusted_content_digest}) eq 'HASH' &&
            $value->{expected_sha256} eq $job->{trusted_content_digest}{sha256};
    die 'resume intent is not bound to the interrupted job snapshot'
        unless $value->{job_binding_sha256} =~ /\A[a-f0-9]{64}\z/ &&
            $value->{job_binding_sha256} eq resume_binding_fingerprint($job);
    for my $field (qw(process_incarnation connection_identity connection_epoch)) {
        die "resume intent does not match the job's original $field"
            unless defined($job->{context}{$field}) &&
                "$value->{$field}" eq "$job->{context}{$field}";
    }
    die 'resume intent server tag differs from the job context'
        if defined($job->{context}{server_tag}) &&
            "$value->{server_tag}" ne "$job->{context}{server_tag}";
    die 'resume intent reuses the interrupted native lifecycle'
        if "$value->{offer_lifecycle_identity}" eq
            "$value->{previous_lifecycle_identity}";
    my $partial = $value->{partial_evidence};
    die 'resume intent partial evidence is malformed'
        unless ref($partial) eq 'HASH' && $partial->{writer_closed} &&
            ($partial->{ownership_status} // '') eq 'captured' &&
            ($partial->{digest_status} // '') eq 'sealed' &&
            defined($partial->{path}) && defined($partial->{staging_root}) &&
            defined($partial->{size}) && "$partial->{size}" eq "$value->{offset}" &&
            defined($partial->{total_size}) &&
                "$partial->{total_size}" eq "$value->{total_size}" &&
            defined($partial->{partial_sha256}) &&
                "$partial->{partial_sha256}" eq "$value->{partial_sha256}" &&
            "$partial->{path}" eq "$value->{source_path}" &&
            "$partial->{staging_root}" eq "$value->{staging_root}" &&
            defined($partial->{offered_basename}) &&
                "$partial->{offered_basename}" eq "$value->{offered_basename}";
    die 'resume intent partial evidence binding is invalid'
        unless defined($value->{partial_binding_sha256}) &&
            $value->{partial_binding_sha256} =~ /\A[a-f0-9]{64}\z/ &&
            $value->{partial_binding_sha256} eq
                resume_partial_fingerprint($partial);
    my $selected_name = $job->{selection}{offered_basename} //
        $job->{selection}{basename} // $job->{selection}{name};
    my $selected_peer = $job->{selection}{expected_peer} //
        $job->{selection}{sender} // $job->{context}{expected_peer};
    die 'resume intent offer differs from the immutable job selection'
        unless defined($selected_name) && defined($selected_peer) &&
            $value->{offered_basename} eq $selected_name &&
            tuple_key(network_profile => $job->{network_profile},
                peer => $value->{sender}, basename => $value->{offered_basename},
                casemapping => $job->{context}{casemapping}) eq
            tuple_key(network_profile => $job->{network_profile},
                peer => $selected_peer, basename => $selected_name,
                casemapping => $job->{context}{casemapping});
    die 'resume admission must not dispatch GET or replay the selected row'
        unless defined($value->{get_dispatched_by_admission}) &&
            "$value->{get_dispatched_by_admission}" eq '0' &&
            defined($value->{selection_replayed_by_admission}) &&
            "$value->{selection_replayed_by_admission}" eq '0';
    my $identity = $value->{snapshot_identity};
    die 'resume snapshot identity is malformed' unless ref($identity) eq 'HASH';
    my %identity_fields = map { $_ => 1 } qw(device inode mode links size mtime ctime);
    die 'resume snapshot identity has unsupported fields'
        if grep { !$identity_fields{$_} } keys %$identity;
    die 'resume snapshot identity is incomplete'
        if grep { !exists $identity->{$_} } keys %identity_fields;
    for my $field (qw(device inode mode links size)) {
        die "resume snapshot identity $field is invalid"
            unless defined($identity->{$field}) && !ref($identity->{$field}) &&
                $identity->{$field} =~ /\A\d+\z/;
    }
    for my $field (qw(mtime ctime)) {
        die "resume snapshot identity $field is invalid"
            unless defined($identity->{$field}) && !ref($identity->{$field}) &&
                $identity->{$field} =~ /\A-?\d+(?:\.\d+)?\z/;
    }
    die 'resume snapshot identity does not match the requested offset'
        unless "$identity->{size}" eq "$value->{offset}" &&
            "$identity->{links}" eq '1' &&
            ($identity->{mode} & 0777) == 0600;
    my $directories = $value->{snapshot_directory_identities};
    die 'resume snapshot directory ancestry is malformed'
        unless ref($directories) eq 'ARRAY' && @$directories > 0 && @$directories <= 256;
    for my $directory (@$directories) {
        die 'resume snapshot directory identity is malformed'
            unless ref($directory) eq 'HASH' &&
                scalar(grep { !exists($directory->{$_}) } qw(device inode mode)) == 0 &&
                scalar(grep { $_ ne 'device' && $_ ne 'inode' && $_ ne 'mode' }
                    keys %$directory) == 0;
        die 'resume snapshot directory identity is invalid'
            if grep { !defined($directory->{$_}) || ref($directory->{$_}) ||
                $directory->{$_} !~ /\A\d+\z/ } qw(device inode mode);
    }
    my $encoded = JSON::PP->new->canonical(1)->utf8(1)->encode($value);
    die 'resume intent exceeds 16 KiB' if length($encoded) > 16 * 1024;
    return 1;
}

sub new_job {
    my (%args) = @_;
    die 'provider must be a short non-empty identifier'
        unless defined($args{provider}) && $args{provider} =~ /\A[a-z][a-z0-9_-]{0,31}\z/;
    die 'selection must be a hash reference' unless ref($args{selection}) eq 'HASH';
    die 'network profile is required' unless defined($args{network_profile}) && length($args{network_profile});
    die 'selection exceeds 48 KiB' if length(JSON::PP->new->canonical(1)->encode($args{selection})) > 48 * 1024;

    my $id = $args{id} // _opaque_id($args{provider});
    die 'invalid opaque job id' unless $id =~ /\Ajob-[a-f0-9]{32}\z/;
    my $selection = _clone_value($args{selection});
    my $context = _clone_value($args{context} || {});
    die 'web operation identity is invalid'
        if defined($context->{web_operation_id}) &&
            (ref($context->{web_operation_id}) ||
             $context->{web_operation_id} !~ /\Aweb-download-[a-f0-9]{64}\z/);
    my $limits = _clone_value($args{limits} || {});
    my $trusted_content_digest = exists($args{trusted_content_digest})
        ? _trusted_content_digest($args{trusted_content_digest}, normalize => 1)
        : undef;
    my $job = {
        schema_version => 1,
        id => $id,
        provider => $args{provider},
        created_at => defined($args{created_at}) ? $args{created_at} : time(),
        state => 'held',
        selection => $selection,
        network_profile => $args{network_profile},
        context => $context,
        limits => $limits,
        transition_sequence => 0,
        outcomes => [],
    };
    $job->{trusted_content_digest} = $trusted_content_digest
        if defined $trusted_content_digest;
    validate_job($job);
    return $job;
}

sub clone_job { return _clone_value($_[0]); }

sub validate_job {
    my ($job) = @_;
    die 'job must be a hash reference' unless ref($job) eq 'HASH';
    die 'unsupported job schema' unless ($job->{schema_version} // 0) == 1;
    die 'invalid job id' unless ($job->{id} // '') =~ /\Ajob-[a-f0-9]{32}\z/;
    die 'invalid provider' unless ($job->{provider} // '') =~ /\A[a-z][a-z0-9_-]{0,31}\z/;
    die 'invalid state' unless exists $ALLOWED{$job->{state} // ''};
    die 'selection must be immutable object data' unless ref($job->{selection}) eq 'HASH';
    die 'network profile missing' unless defined($job->{network_profile}) && length($job->{network_profile});
    die 'context must be an object' unless ref($job->{context}) eq 'HASH';
    die 'web operation identity is invalid'
        if defined($job->{context}{web_operation_id}) &&
            (ref($job->{context}{web_operation_id}) ||
             $job->{context}{web_operation_id} !~ /\Aweb-download-[a-f0-9]{64}\z/);
    die 'limits must be an object' unless ref($job->{limits}) eq 'HASH';
    _trusted_content_digest($job->{trusted_content_digest})
        if exists $job->{trusted_content_digest};
    die 'resume_pending requires a durable resume intent'
        if $job->{state} eq 'resume_pending' && !exists($job->{resume_intent});
    _resume_intent($job->{resume_intent}, $job)
        if exists $job->{resume_intent};
    die 'outcomes must be a bounded array' unless ref($job->{outcomes}) eq 'ARRAY' && @{$job->{outcomes}} <= 256;
    die 'transition sequence invalid' unless ($job->{transition_sequence} // -1) =~ /\A\d+\z/;
    return 1;
}

sub transition_job {
    my ($job, $next, %meta) = @_;
    validate_job($job);
    die 'transition data must be an object'
        if defined($meta{data}) && ref($meta{data}) ne 'HASH';
    die 'trusted content digest is creation-only and immutable'
        if exists($meta{trusted_content_digest}) ||
            (ref($meta{data}) eq 'HASH' && exists($meta{data}{trusted_content_digest}));
    die 'resume intent is immutable once recorded'
        if exists($job->{resume_intent}) &&
            ref($meta{data}) eq 'HASH' && exists($meta{data}{resume_intent});
    die 'resume intent may only be recorded when entering resume_pending'
        if ref($meta{data}) eq 'HASH' && exists($meta{data}{resume_intent}) &&
            $next ne 'resume_pending';
    my %protected_fields = map { $_ => 1 } qw(
        schema_version id provider created_at state selection network_profile
        context limits transition_sequence updated_at outcome reason outcomes
    );
    die 'transition data cannot override lifecycle field ' .
        (sort grep { $protected_fields{$_} } keys %{$meta{data}})[0]
        if ref($meta{data}) eq 'HASH' &&
            grep { $protected_fields{$_} } keys %{$meta{data}};
    die 'unknown target state' unless exists $ALLOWED{$next // ''};
    die "illegal job transition $job->{state} -> $next"
        unless $ALLOWED{$job->{state}}{$next};
    my $updated = clone_job($job);
    $updated->{state} = $next;
    $updated->{transition_sequence}++;
    $updated->{updated_at} = defined($meta{at}) ? $meta{at} : time();
    $updated->{reason} = $meta{reason} if defined $meta{reason};
    $updated->{outcome} = $meta{outcome} if defined $meta{outcome};
    if (defined $meta{data}) {
        $updated->{$_} = $meta{data}{$_} for keys %{$meta{data}};
    }
    push @{$updated->{outcomes}}, {
        type => $meta{outcome}, at => $updated->{updated_at},
        detail => $meta{reason},
    } if defined $meta{outcome};
    die 'too many job outcomes' if @{$updated->{outcomes}} > 256;
    validate_job($updated);
    return $updated;
}

sub job_identity_key {
    my ($job) = @_;
    validate_job($job);
    return sha256_hex(JSON::PP->new->canonical(1)->encode({
        provider => $job->{provider},
        network_profile => $job->{network_profile},
        selection => $job->{selection},
        context => $job->{context},
    }));
}

sub tuple_keys_for_job {
    my ($job, $mapping) = @_;
    validate_job($job);
    my $selection = $job->{selection};
    my $peer = $selection->{expected_peer} // $selection->{sender} // $job->{context}{expected_peer};
    my $profile = $job->{network_profile};
    my @names = ($selection->{offered_basename} // $selection->{basename} // $selection->{name});
    push @names, @{$selection->{legacy_aliases}} if ref($selection->{legacy_aliases}) eq 'ARRAY';
    my %seen;
    return grep { defined($_) && !$seen{$_}++ }
        map { tuple_key(network_profile => $profile, peer => $peer, basename => $_, casemapping => $mapping) }
        @names;
}

sub is_terminal { return $TERMINAL{$_[0] // ''} ? 1 : 0; }

sub unfinished_count {
    my ($jobs) = @_;
    return 0 unless ref($jobs) eq 'HASH';
    return scalar grep { !is_terminal($_->{state}) } values %$jobs;
}

1;
