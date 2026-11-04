package FServe::Discovery::SearchBotArchive;

use strict;
use warnings;

use Compress::Raw::Zlib qw(crc32);
use IO::Uncompress::Unzip qw($UnzipError);
use FServe::Discovery::SearchBot;

my $DEFAULT_MAX_ARCHIVE_BYTES = 32 * 1024 * 1024;
my $HARD_MAX_ARCHIVE_BYTES = 32 * 1024 * 1024;
my $DEFAULT_MAX_INPUT_BYTES = 32 * 1024 * 1024;
my $HARD_MAX_INPUT_BYTES = 256 * 1024 * 1024;
my $DEFAULT_MAX_LINE_LENGTH = 8192;
my $HARD_MAX_LINE_LENGTH = 65536;
my $DEFAULT_MAX_PHYSICAL_LINES = 20000;
my $HARD_MAX_PHYSICAL_LINES = 100000;
my $READ_CHUNK_BYTES = 4096;

sub _refusal {
    my ($parser, $reason) = @_;
    $parser->abort($reason) if $parser;
    return { type => 'refusal', reason => $reason };
}

sub _limit {
    my ($provided, $default, $hard, $name) = @_;
    my $value = defined($provided) ? $provided : $default;
    die "$name must be a positive integer no greater than $hard"
        unless $value =~ /\A[1-9][0-9]*\z/ && $value <= $hard;
    return 0 + $value;
}

sub _feed_line {
    my ($parser, $line, $line_number, $has_lf_terminator) = @_;
    $line =~ s/\r\z// if $has_lf_terminator;
    return { type => 'refusal', reason => 'result line exceeds configured length', line_number => $line_number }
        if length($line) > $parser->{max_line_length};
    my $events = $parser->feed_line($line);
    for my $event (@$events) {
        return $event if ($event->{type} // '') eq 'refusal';
    }
    return undef;
}

sub _fail_job {
    my ($job, $reason) = @_;
    return { type => 'refusal', reason => $reason }
        unless ref($job) eq 'HASH';
    if (!$job->{closed} && $job->{zip}) {
        eval { $job->{zip}->close() };
        $job->{closed} = 1;
    }
    $job->{parser}->abort($reason) if $job->{parser};
    $job->{done} = 1;
    return { type => 'refusal', reason => $reason };
}

sub begin_archive {
    my ($path, %args) = @_;
    return { type => 'refusal', reason => 'archive path is required' }
        unless defined($path) && !ref($path) && length($path);
    return { type => 'refusal', reason => 'archive path must name a regular non-symlink file' }
        unless -f $path && !-l $path;

    my ($max_archive, $max_input, $max_line, $max_results, $max_physical_lines);
    my $limits_ok = eval {
        $max_archive = _limit($args{max_archive_bytes},
            $DEFAULT_MAX_ARCHIVE_BYTES, $HARD_MAX_ARCHIVE_BYTES,
            'max_archive_bytes');
        $max_input = _limit($args{max_input_bytes},
            $DEFAULT_MAX_INPUT_BYTES, $HARD_MAX_INPUT_BYTES,
            'max_input_bytes');
        $max_line = _limit($args{max_line_length},
            $DEFAULT_MAX_LINE_LENGTH, $HARD_MAX_LINE_LENGTH,
            'max_line_length');
        $max_results = _limit($args{max_results}, 3000, 10000, 'max_results');
        $max_physical_lines = _limit($args{max_physical_lines},
            $DEFAULT_MAX_PHYSICAL_LINES, $HARD_MAX_PHYSICAL_LINES,
            'max_physical_lines');
        1;
    };
    return { type => 'refusal', reason => ($@ || 'invalid archive limits') }
        unless $limits_ok;

    my $compressed_size = -s $path;
    return { type => 'refusal', reason => 'archive size is missing or invalid' }
        unless defined($compressed_size) && $compressed_size > 0;
    return { type => 'refusal', reason => 'archive exceeds configured compressed-byte limit' }
        if $compressed_size > $max_archive;

    my $parser = eval {
        FServe::Discovery::SearchBot->new(
            network_id        => $args{network_id},
            server_tag        => $args{server_tag},
            discovery_channel => $args{discovery_channel},
            query             => $args{query},
            collection_id     => $args{collection_id},
            source_timestamp  => $args{source_timestamp},
            max_results       => $max_results,
            max_line_length   => $max_line,
            max_input_bytes   => $max_input,
        );
    };
    return { type => 'refusal', reason => ($@ || 'could not initialize SearchBot parser') }
        unless $parser;

    my $zip = IO::Uncompress::Unzip->new(
        $path,
        Strict     => 1,
        MultiStream => 0,
        Transparent => 0,
    );
    return _refusal($parser, "invalid ZIP archive: $UnzipError") unless $zip;

    my $header = $zip->getHeaderInfo();
    my $member_name = ref($header) eq 'HASH' ? ($header->{Name} // '') : '';
    unless (length($member_name) && $member_name !~ m{[/\\]} &&
            $member_name !~ /[\x00-\x1f\x7f]/ && $member_name =~ /\.txt\z/i) {
        eval { $zip->close() };
        return _refusal($parser, 'ZIP must contain one basename-only .txt result member');
    }
    if (defined($header->{UncompressedLength}) &&
        $header->{UncompressedLength} =~ /\A[0-9]+\z/ &&
        $header->{UncompressedLength} > $max_input) {
        eval { $zip->close() };
        return _refusal($parser, 'declared result member exceeds decompressed-byte limit');
    }
    return {
        type => 'pending',
        job => {
            path => $path,
            zip => $zip,
            parser => $parser,
            header => $header,
            member_name => $member_name,
            compressed_size => 0 + $compressed_size,
            max_input => $max_input,
            max_line => $max_line,
            max_physical_lines => $max_physical_lines,
            total_bytes => 0,
            crc => 0,
            line_number => 0,
            pending => '',
            eof => 0,
            trailing_line_done => 0,
            done => 0,
            closed => 0,
        },
    };
}

sub abort_archive {
    my ($job, $reason) = @_;
    return 0 unless ref($job) eq 'HASH' && !$job->{done};
    _fail_job($job, $reason // 'SearchBot archive processing cancelled');
    return 1;
}

sub _complete_job {
    my ($job) = @_;
    my $header = $job->{header};
    return _fail_job($job, 'ZIP member checksum is missing or invalid')
        unless defined($header->{CRC32}) && $header->{CRC32} =~ /\A[0-9]+\z/ &&
            $job->{crc} == $header->{CRC32};
    return _fail_job($job, 'ZIP member length does not match decompressed data')
        if defined($header->{UncompressedLength}) &&
            $header->{UncompressedLength} =~ /\A[0-9]+\z/ &&
            $job->{total_bytes} != $header->{UncompressedLength};

    my $next_stream = $job->{zip}->nextStream();
    return _fail_job($job, "ZIP structure validation failed: $UnzipError")
        unless defined($next_stream) && $next_stream >= 0;
    return _fail_job($job, 'ZIP must not contain additional members')
        if $next_stream > 0;
    return _fail_job($job, "ZIP close/integrity validation failed: $UnzipError")
        unless $job->{zip}->close();
    $job->{closed} = 1;

    my $complete = $job->{parser}->finish();
    $job->{done} = 1;
    return $complete if ($complete->{type} // '') eq 'refusal';
    return {
        %$complete,
        archive_member => $job->{member_name},
        compressed_bytes => $job->{compressed_size},
        decompressed_bytes => 0 + $job->{total_bytes},
        parser => $job->{parser},
    };
}

sub step_archive {
    my ($job, %args) = @_;
    return { type => 'refusal', reason => 'invalid or inactive archive job' }
        unless ref($job) eq 'HASH' && !$job->{done};

    my ($line_budget, $byte_budget);
    my $valid_budget = eval {
        $line_budget = _limit($args{max_lines}, 128, 4096, 'max_lines_per_step');
        $byte_budget = _limit($args{max_read_bytes}, 65536, 1048576,
            'max_read_bytes_per_step');
        1;
    };
    return _fail_job($job, $@ || 'invalid archive step budget') unless $valid_budget;

    my ($lines, $bytes_read) = (0, 0);
    while ($lines < $line_budget && $bytes_read < $byte_budget) {
        my $newline = index($job->{pending}, "\n");
        if ($newline >= 0) {
            my $line = substr($job->{pending}, 0, $newline, '');
            substr($job->{pending}, 0, 1, '');
            ++$job->{line_number};
            ++$lines;
            return _fail_job($job, 'result member exceeds physical-line limit')
                if $job->{line_number} > $job->{max_physical_lines};
            my $error = _feed_line($job->{parser}, $line, $job->{line_number}, 1);
            return _fail_job($job, $error->{reason}) if $error;
            next;
        }

        if ($job->{eof}) {
            if (length($job->{pending}) && !$job->{trailing_line_done}) {
                ++$job->{line_number};
                ++$lines;
                return _fail_job($job, 'result member exceeds physical-line limit')
                    if $job->{line_number} > $job->{max_physical_lines};
                my $line = $job->{pending};
                $job->{pending} = '';
                $job->{trailing_line_done} = 1;
                my $error = _feed_line($job->{parser}, $line, $job->{line_number}, 0);
                return _fail_job($job, $error->{reason}) if $error;
                next;
            }
            return _complete_job($job);
        }

        my $read_size = $byte_budget - $bytes_read;
        $read_size = $READ_CHUNK_BYTES if $read_size > $READ_CHUNK_BYTES;
        my $chunk = '';
        my $read = $job->{zip}->read($chunk, $read_size);
        return _fail_job($job, "ZIP decompression failed: $UnzipError")
            unless defined($read) && $read >= 0;
        if ($read == 0) {
            $job->{eof} = 1;
            next;
        }
        return _fail_job($job, 'ZIP reader returned an inconsistent chunk length')
            unless length($chunk) == $read;

        $bytes_read += $read;
        $job->{total_bytes} += $read;
        return _fail_job($job, 'result member exceeds decompressed-byte limit')
            if $job->{total_bytes} > $job->{max_input};
        $job->{crc} = crc32($chunk, $job->{crc});
        $job->{pending} .= $chunk;
        return _fail_job($job, 'result line exceeds configured length')
            if length($job->{pending}) > $job->{max_line} + 1 &&
                index($job->{pending}, "\n") < 0;
    }

    return { type => 'pending', job => $job };
}

sub parse_archive {
    my ($path, %args) = @_;
    my $result;
    my $ok = eval {
        $result = begin_archive($path, %args);
        if (($result->{type} // '') eq 'pending') {
            my $job = $result->{job};
            while (($result->{type} // '') eq 'pending') {
                $result = step_archive($job, max_lines => 512,
                    max_read_bytes => 1048576);
            }
        }
        1;
    };
    return { type => 'refusal', reason => 'archive processing failed safely' }
        unless $ok;
    return $result;
}

1;
