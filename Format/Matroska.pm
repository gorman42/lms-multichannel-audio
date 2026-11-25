package Plugins::MultichannelAudio::Format::Matroska;

use strict;
use warnings;

use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);

# Canonical EBML / Matroska Element IDs (with VINT marker bits intact)
use constant {
	ID_EBML                => 0x1A45DFA3,
	ID_SEGMENT             => 0x18538067,
	ID_SEEK_HEAD           => 0x114D9B74,
	ID_SEEK                => 0x4DBB,
	ID_SEEK_ID             => 0x53AB,
	ID_SEEK_POSITION       => 0x53AC,

	ID_INFO                => 0x1549A966,
	ID_TIMECODE_SCALE      => 0x2AD7B1,
	ID_DURATION            => 0x4489,
	ID_TITLE               => 0x7BA9,

	ID_TRACKS              => 0x1654AE6B,
	ID_TRACK_ENTRY         => 0xAE,
	ID_TRACK_NUMBER        => 0xD7,
	ID_TRACK_UID           => 0x73C5,
	ID_TRACK_TYPE          => 0x83,
	ID_CODEC_ID            => 0x86,
	ID_CODEC_PRIVATE       => 0x63A2,
	ID_CODEC_DELAY         => 0x56AA,
	ID_AUDIO               => 0xE1,
	ID_SAMPLING_FREQ       => 0xB5,
	ID_CHANNELS            => 0x9F,
	ID_BIT_DEPTH           => 0x6264,

	ID_CHAPTERS            => 0x1043A770,
	ID_EDITION_ENTRY       => 0x45B9,
	ID_EDITION_DEFAULT     => 0x45BD,
	ID_CHAPTER_ATOM        => 0xB6,
	ID_CHAPTER_UID         => 0x73C4,
	ID_CHAPTER_TIME_START  => 0x91,
	ID_CHAPTER_TIME_END    => 0x92,
	ID_CHAPTER_FLAG_HIDDEN => 0x98,
	ID_CHAPTER_DISPLAY     => 0x80,
	ID_CHAP_STRING         => 0x85,

	ID_CUES                => 0x1C53BB6B,
	ID_CUE_POINT           => 0xBB,
	ID_CUE_TIME            => 0xB3,
	ID_CUE_TRACK_POSITIONS => 0xB7,
	ID_CUE_TRACK           => 0xF7,
	ID_CUE_CLUSTER_POS     => 0xF1,
	ID_CUE_RELATIVE_POS    => 0xF0,

	ID_ATTACHMENTS         => 0x1941A469,
	ID_ATTACHED_FILE       => 0x61A7,
	ID_FILE_NAME           => 0x466E,
	ID_FILE_MEDIA_TYPE     => 0x4660,
	ID_FILE_DATA           => 0x465C,

	ID_TAGS                => 0x1254C367,
	ID_TAG                 => 0x7373,
	ID_TARGETS             => 0x63C0,
	ID_TARGET_TYPE_VALUE   => 0x68CA,
	ID_TAG_CHAPTER_UID     => 0x63C4,
	ID_TAG_TRACK_UID       => 0x63C5,
	ID_SIMPLE_TAG          => 0x67C8,
	ID_TAG_NAME            => 0x45A3,
	ID_TAG_STRING          => 0x4487,

	ID_CLUSTER             => 0x1F43B675,
	ID_CLUSTER_TIMECODE    => 0xE7,
	ID_SIMPLE_BLOCK        => 0xA3,
	ID_BLOCK_GROUP         => 0xA0,
	ID_BLOCK               => 0xA1,
	ID_BLOCK_DURATION      => 0x9B,

	ID_CRC32               => 0xBF,
	ID_VOID                => 0xEC,
};

# VINT length lookup by leading byte
my @VINT_LEN = (
	0,
	8,
	7,7,
	6,6,6,6,
	5,5,5,5,5,5,5,5,
	4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,
	3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,
	2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
	2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
	1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
	1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
	1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
	1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
);

my @EBML_SIGNED_BIAS = (
	0,
	0x3F,
	0x1FFF,
	0x0FFFFF,
	0x07FFFFFF,
	(1 << 34) - 1,
	(1 << 41) - 1,
	(1 << 48) - 1,
	(1 << 55) - 1,
);

my %CODEC_MAP = (
	'A_TRUEHD'         => 'truehd',
	'A_EAC3'           => 'eac3',
	'A_AC3'            => 'ac3',
	'A_DTS'            => 'dts',
	'A_DTS/LOSSLESS'   => 'dts',
	'A_DTS/EXPRESS'    => 'dts',
	'A_FLAC'           => 'flac',
	'A_ALAC'           => 'alac',
	'A_AAC'            => 'aac',
	'A_OPUS'           => 'opus',
	'A_VORBIS'         => 'vorbis',
	'A_PCM/INT/LIT'    => 'pcm_s24le',
	'A_PCM/INT/BIG'    => 'pcm_s24be',
	'A_PCM/FLOAT/IEEE' => 'pcm_f32le',
);

# Read an EBML Element ID from binary buffer at $$pos_ref (keeps VINT marker bit)
sub _buf_read_id {
	my ($buf_ref, $pos_ref, $end) = @_;
	my $p = $$pos_ref;
	return undef if $p >= $end;

	my $b0  = ord(substr($$buf_ref, $p, 1));
	my $len = $VINT_LEN[$b0];
	return undef if !$len || $len > 4 || ($p + $len) > $end;

	my $val = 0;
	for my $i (0 .. $len - 1) {
		$val = ($val * 256) + ord(substr($$buf_ref, $p + $i, 1));
	}
	$$pos_ref = $p + $len;
	return $val;
}

# Read an EBML Data Size VINT from binary buffer at $$pos_ref (strips VINT marker bit)
# Returns ($size, $is_unknown)
sub _buf_read_size {
	my ($buf_ref, $pos_ref, $end) = @_;
	my $p = $$pos_ref;
	return (undef, 0) if $p >= $end;

	my $b0  = ord(substr($$buf_ref, $p, 1));
	my $len = $VINT_LEN[$b0];
	return (undef, 0) if !$len || ($p + $len) > $end;

	my $mask = (1 << (8 - $len)) - 1;
	my $val  = $b0 & $mask;
	my $all_ones = ($val == $mask) ? 1 : 0;

	for my $i (1 .. $len - 1) {
		my $b = ord(substr($$buf_ref, $p + $i, 1));
		$all_ones = 0 if $b != 0xFF;
		$val = ($val * 256) + $b;
	}
	$$pos_ref = $p + $len;
	return ($val, $all_ones);
}

# Read EBML Element ID directly from filehandle at current offset
sub _fh_read_id {
	my ($fh) = @_;
	my $b0_str;
	return undef unless read($fh, $b0_str, 1) == 1;
	my $b0  = ord($b0_str);
	my $len = $VINT_LEN[$b0];
	return undef if !$len || $len > 4;

	my $val = $b0;
	if ($len > 1) {
		my $rest;
		return undef unless read($fh, $rest, $len - 1) == ($len - 1);
		for my $i (0 .. $len - 2) {
			$val = ($val * 256) + ord(substr($rest, $i, 1));
		}
	}
	return $val;
}

# Read EBML Data Size VINT directly from filehandle
sub _fh_read_size {
	my ($fh) = @_;
	my $b0_str;
	return (undef, 0) unless read($fh, $b0_str, 1) == 1;
	my $b0  = ord($b0_str);
	my $len = $VINT_LEN[$b0];
	return (undef, 0) unless $len;

	my $mask     = (1 << (8 - $len)) - 1;
	my $val      = $b0 & $mask;
	my $all_ones = ($val == $mask) ? 1 : 0;

	if ($len > 1) {
		my $rest;
		return (undef, 0) unless read($fh, $rest, $len - 1) == ($len - 1);
		for my $i (0 .. $len - 2) {
			my $b = ord(substr($rest, $i, 1));
			$all_ones = 0 if $b != 0xFF;
			$val = ($val * 256) + $b;
		}
	}
	return ($val, $all_ones);
}

sub _decode_uint {
	my ($bytes) = @_;
	my $val = 0;
	my $len = length($bytes);
	for my $i (0 .. $len - 1) {
		$val = ($val * 256) + ord(substr($bytes, $i, 1));
	}
	return $val;
}

sub _decode_float {
	my ($bytes) = @_;
	my $len = length($bytes);
	return unpack('f>', $bytes) if $len == 4;
	return unpack('d>', $bytes) if $len == 8;
	return 0;
}

sub _decode_str {
	my ($bytes) = @_;
	$bytes =~ s/\x00+$//;
	utf8::decode($bytes);
	return $bytes;
}

# Parse full Matroska metadata, chapters, cues, and optional cover art
sub parse {
	my ($class, $path, $opts) = @_;
	$opts ||= {};
	return undef unless defined $path && -f $path;

	my $file_size = -s $path;
	return undef unless $file_size && $file_size > 16;

	open my $fh, '<:raw', $path or return undef;

	# 1. Verify EBML Header (0x1A45DFA3)
	my $ebml_id = _fh_read_id($fh);
	if (!defined $ebml_id || $ebml_id != ID_EBML) {
		close $fh;
		return undef;
	}
	my ($ebml_size) = _fh_read_size($fh);
	if (!defined $ebml_size) {
		close $fh;
		return undef;
	}
	seek($fh, $ebml_size, SEEK_CUR);

	# 2. Locate Segment (0x18538067)
	my $seg_id = _fh_read_id($fh);
	if (!defined $seg_id || $seg_id != ID_SEGMENT) {
		close $fh;
		return undef;
	}
	my ($seg_size, $seg_unknown) = _fh_read_size($fh);
	my $seg_data_start = tell($fh);
	my $seg_end = (!$seg_unknown && defined $seg_size && ($seg_data_start + $seg_size) <= $file_size)
		? ($seg_data_start + $seg_size)
		: $file_size;

	my $state = {
		path           => $path,
		file_size      => $file_size,
		seg_data_start => $seg_data_start,
		seg_end        => $seg_end,
		timecode_scale => 1_000_000, # default 1 ms in ns
		duration_ticks => 0,
		title          => undef,
		tracks         => [],
		chapters       => [],
		cues           => [],
		tags           => {},
		chapter_tags   => {},
		track_tags     => {},
		cover_art      => undef,
		has_cover      => 0,
		first_cluster  => undef,
		parsed_ids     => {},
		seek_positions => {},
	};

	# 3. Walk top-level Segment elements up to first Cluster, using SeekHead to jump to trailing Cues/Chapters/Tags
	seek($fh, $seg_data_start, SEEK_SET);
	while (tell($fh) < $seg_end) {
		my $elem_pos = tell($fh);
		my $id = _fh_read_id($fh);
		last unless defined $id;
		my ($sz, $unk) = _fh_read_size($fh);
		last unless defined $sz;
		my $data_pos = tell($fh);

		if ($id == ID_CLUSTER) {
			$state->{first_cluster} //= $elem_pos;
			last;
		}

		last if $unk || ($data_pos + $sz) > $seg_end;

		_dispatch_top_element($fh, $state, $id, $data_pos, $sz, $opts);
		seek($fh, $data_pos + $sz, SEEK_SET);
	}

	# Jump to any unparsed metadata sections referenced in SeekHead (e.g., Cues/Chapters/Tags at EOF)
	for my $target_id (ID_INFO, ID_TRACKS, ID_CHAPTERS, ID_CUES, ID_TAGS, ID_ATTACHMENTS) {
		next if $state->{parsed_ids}{$target_id};
		my $rel = $state->{seek_positions}{$target_id};
		next unless defined $rel;

		my $abs_pos = $seg_data_start + $rel;
		next if $abs_pos < $seg_data_start || $abs_pos >= $seg_end;

		seek($fh, $abs_pos, SEEK_SET);
		my $id = _fh_read_id($fh);
		next unless defined $id && $id == $target_id;
		my ($sz, $unk) = _fh_read_size($fh);
		next unless defined $sz && !$unk;
		my $data_pos = tell($fh);
		next if ($data_pos + $sz) > $seg_end;

		_dispatch_top_element($fh, $state, $id, $data_pos, $sz, $opts);
	}

	# Select primary audio track
	my $audio_track;
	for my $t (@{ $state->{tracks} }) {
		if (($t->{track_type} || 0) == 2) {
			$audio_track = $t;
			last;
		}
	}
	if (!$audio_track) {
		close $fh;
		return undef;
	}

	# Inspect first audio frame in first Cluster to detect Atmos / DTS-HD MA profile accurately
	my $profile = '';
	if (defined $state->{first_cluster}) {
		my $first_frame = _peek_first_audio_frame($fh, $state, $audio_track->{track_number});
		if (defined $first_frame && length($first_frame) >= 8) {
			$profile = _detect_bitstream_profile($audio_track->{codec_id}, $first_frame);
		}
	}

	close $fh;

	# Finalize duration in seconds
	my $secs = 0;
	if ($state->{duration_ticks} > 0) {
		$secs = ($state->{duration_ticks} * $state->{timecode_scale}) / 1_000_000_000;
	}

	# Finalize chapters list (sorted by start_time, filling missing end_time from next chapter or total duration)
	my @chapters = sort { $a->{start_time} <=> $b->{start_time} } @{ $state->{chapters} };
	for my $i (0 .. $#chapters) {
		my $ch = $chapters[$i];
		if (!defined $ch->{end_time} || $ch->{end_time} <= $ch->{start_time}) {
			if ($i < $#chapters) {
				$ch->{end_time} = $chapters[$i + 1]{start_time};
			} elsif ($secs > $ch->{start_time}) {
				$ch->{end_time} = $secs;
			}
		}
		if (defined $ch->{uid} && exists $state->{chapter_tags}{ $ch->{uid} }) {
			my $ct = $state->{chapter_tags}{ $ch->{uid} };
			while (my ($k, $v) = each %$ct) {
				$ch->{tags}{$k} //= $v;
			}
		}
		$ch->{tags}{TITLE} //= $ch->{title} if defined $ch->{title} && length $ch->{title};
	}

	# Filter & sort Cues for the selected audio track (or all cues if CueTrack omitted)
	my $tnum = $audio_track->{track_number};
	my @cues = sort { $a->{time_ns} <=> $b->{time_ns} }
		grep { !defined $_->{track} || $_->{track} == $tnum } @{ $state->{cues} };

	my $cid_str = $audio_track->{codec_id} || '';
	my $codec_name = $CODEC_MAP{$cid_str} || lc($cid_str);
	if ($cid_str eq 'A_PCM/INT/LIT' && ($audio_track->{bit_depth} || 24) == 16) {
		$codec_name = 'pcm_s16le';
	}

	my $sample_size = int($audio_track->{bit_depth} || 0);
	if (!$sample_size && ($cid_str eq 'A_TRUEHD' || $cid_str eq 'A_DTS/LOSSLESS')) {
		$sample_size = 24;
	}

	my %merged_tags = %{ $state->{tags} };
	if (defined $audio_track->{uid} && exists $state->{track_tags}{ $audio_track->{uid} }) {
		while (my ($k, $v) = each %{ $state->{track_tags}{ $audio_track->{uid} } }) {
			$merged_tags{$k} //= $v;
		}
	}
	$merged_tags{TITLE} //= $state->{title} if defined $state->{title} && length $state->{title};

	return {
		path           => $path,
		file_size      => $file_size,
		seg_data_start => $seg_data_start,
		seg_end        => $seg_end,
		first_cluster  => $state->{first_cluster},
		timecode_scale => $state->{timecode_scale},
		track_number   => $tnum,
		codec_id       => $audio_track->{codec_id},
		codec          => $codec_name,
		profile        => $profile,
		channels       => $audio_track->{channels} || 2,
		sample_rate    => int($audio_track->{sample_rate} || 48000),
		sample_size    => $sample_size,
		codec_private  => $audio_track->{codec_private},
		codec_delay_ns => $audio_track->{codec_delay_ns} || 0,
		secs           => $secs,
		size           => $file_size,
		bitrate        => ($secs > 0) ? int(($file_size * 8) / $secs) : 0,
		tags           => \%merged_tags,
		chapters       => \@chapters,
		cues           => \@cues,
		has_cover      => $state->{has_cover} ? 1 : 0,
		cover_art      => $state->{cover_art},
	};
}

sub _dispatch_top_element {
	my ($fh, $state, $id, $data_pos, $sz, $opts) = @_;
	return if $sz <= 0 || $sz > 64 * 1024 * 1024; # guard against corrupt >64MB metadata blocks

	# For Attachments, only load binary image payload if requested (or inspect header fast)
	if ($id == ID_ATTACHMENTS && !$opts->{with_cover} && $sz > 256 * 1024) {
		$state->{has_cover} = 1;
		$state->{parsed_ids}{$id} = 1;
		return;
	}

	my $buf;
	return unless read($fh, $buf, $sz) == $sz;
	$state->{parsed_ids}{$id} = 1;

	if ($id == ID_SEEK_HEAD) {
		_parse_seek_head($state, \$buf, 0, $sz);
	} elsif ($id == ID_INFO) {
		_parse_info($state, \$buf, 0, $sz);
	} elsif ($id == ID_TRACKS) {
		_parse_tracks($state, \$buf, 0, $sz);
	} elsif ($id == ID_CHAPTERS) {
		_parse_chapters($state, \$buf, 0, $sz);
	} elsif ($id == ID_CUES) {
		_parse_cues($state, \$buf, 0, $sz);
	} elsif ($id == ID_TAGS) {
		_parse_tags($state, \$buf, 0, $sz);
	} elsif ($id == ID_ATTACHMENTS) {
		_parse_attachments($state, \$buf, 0, $sz, $opts);
	}
}

sub _parse_seek_head {
	my ($state, $buf_ref, $pos, $end) = @_;
	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		if ($id == ID_SEEK) {
			my ($sid, $spos);
			my $p = $pos;
			my $e = $pos + $sz;
			while ($p < $e) {
				my $cid = _buf_read_id($buf_ref, \$p, $e) // last;
				my ($csz) = _buf_read_size($buf_ref, \$p, $e);
				last unless defined $csz && ($p + $csz) <= $e;
				if ($cid == ID_SEEK_ID) {
					$sid = _decode_uint(substr($$buf_ref, $p, $csz));
				} elsif ($cid == ID_SEEK_POSITION) {
					$spos = _decode_uint(substr($$buf_ref, $p, $csz));
				}
				$p += $csz;
			}
			if (defined $sid && defined $spos) {
				$state->{seek_positions}{$sid} //= $spos;
			}
		}
		$pos += $sz;
	}
}

sub _parse_info {
	my ($state, $buf_ref, $pos, $end) = @_;
	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		my $chunk = substr($$buf_ref, $pos, $sz);
		if ($id == ID_TIMECODE_SCALE) {
			my $ts = _decode_uint($chunk);
			$state->{timecode_scale} = $ts if $ts > 0;
		} elsif ($id == ID_DURATION) {
			$state->{duration_ticks} = _decode_float($chunk);
		} elsif ($id == ID_TITLE) {
			$state->{title} = _decode_str($chunk);
		}
		$pos += $sz;
	}
}

sub _parse_tracks {
	my ($state, $buf_ref, $pos, $end) = @_;
	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		if ($id == ID_TRACK_ENTRY) {
			my %track = (channels => 2, sample_rate => 48000);
			my $p = $pos;
			my $e = $pos + $sz;
			while ($p < $e) {
				my $cid = _buf_read_id($buf_ref, \$p, $e) // last;
				my ($csz) = _buf_read_size($buf_ref, \$p, $e);
				last unless defined $csz && ($p + $csz) <= $e;
				my $chunk = substr($$buf_ref, $p, $csz);
				if ($cid == ID_TRACK_NUMBER) {
					$track{track_number} = _decode_uint($chunk);
				} elsif ($cid == ID_TRACK_UID) {
					$track{uid} = _decode_uint($chunk);
				} elsif ($cid == ID_TRACK_TYPE) {
					$track{track_type} = _decode_uint($chunk);
				} elsif ($cid == ID_CODEC_ID) {
					$track{codec_id} = _decode_str($chunk);
				} elsif ($cid == ID_CODEC_PRIVATE) {
					$track{codec_private} = $chunk;
				} elsif ($cid == ID_CODEC_DELAY) {
					$track{codec_delay_ns} = _decode_uint($chunk);
				} elsif ($cid == ID_AUDIO) {
					my $ap = $p;
					my $ae = $p + $csz;
					while ($ap < $ae) {
						my $aid = _buf_read_id($buf_ref, \$ap, $ae) // last;
						my ($asz) = _buf_read_size($buf_ref, \$ap, $ae);
						last unless defined $asz && ($ap + $asz) <= $ae;
						my $achunk = substr($$buf_ref, $ap, $asz);
						if ($aid == ID_SAMPLING_FREQ) {
							$track{sample_rate} = _decode_float($achunk);
						} elsif ($aid == ID_CHANNELS) {
							$track{channels} = _decode_uint($achunk);
						} elsif ($aid == ID_BIT_DEPTH) {
							$track{bit_depth} = _decode_uint($achunk);
						}
						$ap += $asz;
					}
				}
				$p += $csz;
			}
			push @{ $state->{tracks} }, \%track;
			$state->{has_cover} = 1 if ($track{track_type} || 0) == 1;
		}
		$pos += $sz;
	}
}

sub _parse_chapters {
	my ($state, $buf_ref, $pos, $end) = @_;
	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		if ($id == ID_EDITION_ENTRY) {
			my $p = $pos;
			my $e = $pos + $sz;
			while ($p < $e) {
				my $cid = _buf_read_id($buf_ref, \$p, $e) // last;
				my ($csz) = _buf_read_size($buf_ref, \$p, $e);
				last unless defined $csz && ($p + $csz) <= $e;
				if ($cid == ID_CHAPTER_ATOM) {
					_parse_chapter_atom($state, $buf_ref, $p, $p + $csz);
				}
				$p += $csz;
			}
		}
		$pos += $sz;
	}
}

sub _parse_chapter_atom {
	my ($state, $buf_ref, $pos, $end) = @_;
	my %ch = (tags => {});
	my $hidden = 0;

	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		my $chunk = substr($$buf_ref, $pos, $sz);
		if ($id == ID_CHAPTER_UID) {
			$ch{uid} = _decode_uint($chunk);
		} elsif ($id == ID_CHAPTER_TIME_START) {
			$ch{start_ns}   = _decode_uint($chunk);
			$ch{start_time} = $ch{start_ns} / 1_000_000_000;
		} elsif ($id == ID_CHAPTER_TIME_END) {
			$ch{end_ns}   = _decode_uint($chunk);
			$ch{end_time} = $ch{end_ns} / 1_000_000_000;
		} elsif ($id == ID_CHAPTER_FLAG_HIDDEN) {
			$hidden = _decode_uint($chunk);
		} elsif ($id == ID_CHAPTER_DISPLAY) {
			my $dp = $pos;
			my $de = $pos + $sz;
			while ($dp < $de) {
				my $did = _buf_read_id($buf_ref, \$dp, $de) // last;
				my ($dsz) = _buf_read_size($buf_ref, \$dp, $de);
				last unless defined $dsz && ($dp + $dsz) <= $de;
				if ($did == ID_CHAP_STRING && !defined $ch{title}) {
					$ch{title} = _decode_str(substr($$buf_ref, $dp, $dsz));
				}
				$dp += $dsz;
			}
		}
		$pos += $sz;
	}

	if (!$hidden && defined $ch{start_time}) {
		push @{ $state->{chapters} }, \%ch;
	}
}

sub _parse_cues {
	my ($state, $buf_ref, $pos, $end) = @_;
	my $scale = $state->{timecode_scale} || 1_000_000;
	my $seg_start = $state->{seg_data_start};

	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		if ($id == ID_CUE_POINT) {
			my ($cue_time, $cue_track, $cue_cluster_pos, $cue_rel_pos);
			my $p = $pos;
			my $e = $pos + $sz;
			while ($p < $e) {
				my $cid = _buf_read_id($buf_ref, \$p, $e) // last;
				my ($csz) = _buf_read_size($buf_ref, \$p, $e);
				last unless defined $csz && ($p + $csz) <= $e;
				if ($cid == ID_CUE_TIME) {
					$cue_time = _decode_uint(substr($$buf_ref, $p, $csz));
				} elsif ($cid == ID_CUE_TRACK_POSITIONS) {
					my $tp = $p;
					my $te = $p + $csz;
					while ($tp < $te) {
						my $tid = _buf_read_id($buf_ref, \$tp, $te) // last;
						my ($tsz) = _buf_read_size($buf_ref, \$tp, $te);
						last unless defined $tsz && ($tp + $tsz) <= $te;
						my $tchunk = substr($$buf_ref, $tp, $tsz);
						if ($tid == ID_CUE_TRACK) {
							$cue_track = _decode_uint($tchunk);
						} elsif ($tid == ID_CUE_CLUSTER_POS) {
							$cue_cluster_pos = _decode_uint($tchunk);
						} elsif ($tid == ID_CUE_RELATIVE_POS) {
							$cue_rel_pos = _decode_uint($tchunk);
						}
						$tp += $tsz;
					}
				}
				$p += $csz;
			}
			if (defined $cue_time && defined $cue_cluster_pos) {
				my $time_ns = $cue_time * $scale;
				push @{ $state->{cues} }, {
					time_ticks  => $cue_time,
					time_ns     => $time_ns,
					time_sec    => $time_ns / 1_000_000_000,
					track       => $cue_track,
					cluster_pos => $seg_start + $cue_cluster_pos,
					rel_pos     => $cue_rel_pos,
				};
			}
		}
		$pos += $sz;
	}
}

sub _parse_tags {
	my ($state, $buf_ref, $pos, $end) = @_;
	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		if ($id == ID_TAG) {
			my $target_type = 50;
			my ($chap_uid, $track_uid);
			my %kv;
			my $p = $pos;
			my $e = $pos + $sz;
			while ($p < $e) {
				my $cid = _buf_read_id($buf_ref, \$p, $e) // last;
				my ($csz) = _buf_read_size($buf_ref, \$p, $e);
				last unless defined $csz && ($p + $csz) <= $e;
				if ($cid == ID_TARGETS) {
					my $tp = $p;
					my $te = $p + $csz;
					while ($tp < $te) {
						my $tid = _buf_read_id($buf_ref, \$tp, $te) // last;
						my ($tsz) = _buf_read_size($buf_ref, \$tp, $te);
						last unless defined $tsz && ($tp + $tsz) <= $te;
						my $tchunk = substr($$buf_ref, $tp, $tsz);
						if ($tid == ID_TARGET_TYPE_VALUE) {
							$target_type = _decode_uint($tchunk);
						} elsif ($tid == ID_TAG_CHAPTER_UID) {
							$chap_uid = _decode_uint($tchunk);
						} elsif ($tid == ID_TAG_TRACK_UID) {
							$track_uid = _decode_uint($tchunk);
						}
						$tp += $tsz;
					}
				} elsif ($cid == ID_SIMPLE_TAG) {
					my ($tname, $tval);
					my $sp = $p;
					my $se = $p + $csz;
					while ($sp < $se) {
						my $sid = _buf_read_id($buf_ref, \$sp, $se) // last;
						my ($ssz) = _buf_read_size($buf_ref, \$sp, $se);
						last unless defined $ssz && ($sp + $ssz) <= $se;
						my $schunk = substr($$buf_ref, $sp, $ssz);
						if ($sid == ID_TAG_NAME) {
							$tname = uc(_decode_str($schunk));
						} elsif ($sid == ID_TAG_STRING) {
							$tval = _decode_str($schunk);
						}
						$sp += $ssz;
					}
					if (defined $tname && length $tname && defined $tval && length $tval) {
						$kv{$tname} = $tval;
					}
				}
				$p += $csz;
			}
			if (defined $chap_uid) {
				while (my ($k, $v) = each %kv) {
					$state->{chapter_tags}{$chap_uid}{$k} //= $v;
				}
			} elsif (defined $track_uid && $target_type < 50) {
				while (my ($k, $v) = each %kv) {
					$state->{track_tags}{$track_uid}{$k} //= $v;
				}
			} else {
				while (my ($k, $v) = each %kv) {
					$state->{tags}{$k} //= $v;
				}
			}
		}
		$pos += $sz;
	}
}

sub _parse_attachments {
	my ($state, $buf_ref, $pos, $end, $opts) = @_;
	while ($pos < $end) {
		my $id = _buf_read_id($buf_ref, \$pos, $end) // last;
		my ($sz) = _buf_read_size($buf_ref, \$pos, $end);
		last unless defined $sz && ($pos + $sz) <= $end;
		if ($id == ID_ATTACHED_FILE) {
			my ($fname, $mime, $fdata);
			my $p = $pos;
			my $e = $pos + $sz;
			while ($p < $e) {
				my $cid = _buf_read_id($buf_ref, \$p, $e) // last;
				my ($csz) = _buf_read_size($buf_ref, \$p, $e);
				last unless defined $csz && ($p + $csz) <= $e;
				if ($cid == ID_FILE_NAME) {
					$fname = _decode_str(substr($$buf_ref, $p, $csz));
				} elsif ($cid == ID_FILE_MEDIA_TYPE) {
					$mime = lc(_decode_str(substr($$buf_ref, $p, $csz)));
				} elsif ($cid == ID_FILE_DATA) {
					$fdata = substr($$buf_ref, $p, $csz) if $opts->{with_cover};
				}
				$p += $csz;
			}
			if (($mime && $mime =~ m{^image/(?:jpeg|jpg|png|gif|bmp)$})
				|| ($fname && $fname =~ /\.(?:jpe?g|png|gif|bmp)$/i)) {
				$state->{has_cover} = 1;
				$state->{cover_art} //= $fdata if defined $fdata && length $fdata;
			}
		}
		$pos += $sz;
	}
}

# Unpack a SimpleBlock or Block payload into individual audio access-unit frames
# Returns ($track_num, $rel_timecode, \@frames)
sub unpack_block {
	my ($block_ref) = @_;
	my $len = length($$block_ref);
	return undef if $len < 5;

	my $pos = 0;
	my ($track_num) = _buf_read_size($block_ref, \$pos, $len);
	return undef unless defined $track_num && ($pos + 3) <= $len;

	my $rel_tc = unpack('s>', substr($$block_ref, $pos, 2));
	my $flags  = ord(substr($$block_ref, $pos + 2, 1));
	$pos += 3;

	my $lacing = ($flags >> 1) & 0x03;

	# 0 = No lacing
	if ($lacing == 0) {
		return ($track_num, $rel_tc, [ substr($$block_ref, $pos) ]);
	}

	return undef if $pos >= $len;
	my $num_frames = ord(substr($$block_ref, $pos, 1)) + 1;
	$pos += 1;

	my @frames;

	# 1 = Xiph lacing
	if ($lacing == 1) {
		my @sizes;
		for (1 .. $num_frames - 1) {
			my $fsize = 0;
			while ($pos < $len) {
				my $b = ord(substr($$block_ref, $pos++, 1));
				$fsize += $b;
				last if $b < 0xFF;
			}
			push @sizes, $fsize;
		}
		for my $fsz (@sizes) {
			return undef if ($pos + $fsz) > $len;
			push @frames, substr($$block_ref, $pos, $fsz);
			$pos += $fsz;
		}
		push @frames, substr($$block_ref, $pos);
		return ($track_num, $rel_tc, \@frames);
	}

	# 2 = Fixed-size lacing
	if ($lacing == 2) {
		my $rem = $len - $pos;
		return undef if $rem <= 0 || ($rem % $num_frames) != 0;
		my $fsz = int($rem / $num_frames);
		for (0 .. $num_frames - 1) {
			push @frames, substr($$block_ref, $pos + ($_ * $fsz), $fsz);
		}
		return ($track_num, $rel_tc, \@frames);
	}

	# 3 = EBML lacing
	if ($lacing == 3) {
		my @sizes;
		my ($first_sz) = _buf_read_size($block_ref, \$pos, $len);
		return undef unless defined $first_sz;
		push @sizes, $first_sz;

		my $prev_sz = $first_sz;
		for (2 .. $num_frames - 1) {
			return undef if $pos >= $len;
			my $b0   = ord(substr($$block_ref, $pos, 1));
			my $vlen = $VINT_LEN[$b0];
			return undef if !$vlen || ($pos + $vlen) > $len;

			my ($uval) = _buf_read_size($block_ref, \$pos, $len);
			return undef unless defined $uval;

			my $delta = $uval - $EBML_SIGNED_BIAS[$vlen];
			$prev_sz += $delta;
			return undef if $prev_sz < 0;
			push @sizes, $prev_sz;
		}

		for my $fsz (@sizes) {
			return undef if ($pos + $fsz) > $len;
			push @frames, substr($$block_ref, $pos, $fsz);
			$pos += $fsz;
		}
		push @frames, substr($$block_ref, $pos);
		return ($track_num, $rel_tc, \@frames);
	}

	return undef;
}

# Estimate exact duration (in nanoseconds) of a single audio frame for sub-block lacing splits
sub frame_duration_ns {
	my ($codec_id, $sample_rate, $frame) = @_;
	$codec_id    ||= '';
	$sample_rate ||= 48000;

	if ($codec_id eq 'A_TRUEHD') {
		# TrueHD access units are always 40 samples at 48kHz base (80 at 96kHz, 160 at 192kHz) = 1/1200 s
		return 833_333.333333;
	}
	if ($codec_id eq 'A_EAC3' || $codec_id eq 'A_AC3') {
		return (1536 / $sample_rate) * 1_000_000_000;
	}
	if ($codec_id =~ /^A_DTS/) {
		return (512 / $sample_rate) * 1_000_000_000;
	}
	return 0;
}

sub _peek_first_audio_frame {
	my ($fh, $state, $target_track) = @_;
	my $cpos = $state->{first_cluster} // return undef;
	seek($fh, $cpos, SEEK_SET);

	my $cid = _fh_read_id($fh);
	return undef unless defined $cid && $cid == ID_CLUSTER;
	my ($csz, $unk) = _fh_read_size($fh);
	return undef unless defined $csz;

	my $cdata_start = tell($fh);
	my $cend = (!$unk && ($cdata_start + $csz) <= $state->{seg_end})
		? ($cdata_start + $csz)
		: $state->{seg_end};

	while (tell($fh) < $cend) {
		my $id = _fh_read_id($fh) // last;
		my ($sz, $bunk) = _fh_read_size($fh);
		last unless defined $sz && !$bunk;
		my $dpos = tell($fh);
		last if ($dpos + $sz) > $cend;

		if ($id == ID_SIMPLE_BLOCK) {
			my $blk;
			if (read($fh, $blk, $sz) == $sz) {
				my ($tnum, undef, $frames) = unpack_block(\$blk);
				if (defined $tnum && $tnum == $target_track && $frames && @$frames) {
					return $frames->[0];
				}
			}
		} elsif ($id == ID_BLOCK_GROUP) {
			my $bg;
			if (read($fh, $bg, $sz) == $sz) {
				my ($p, $e) = (0, $sz);
				while ($p < $e) {
					my $gid = _buf_read_id(\$bg, \$p, $e) // last;
					my ($gsz) = _buf_read_size(\$bg, \$p, $e);
					last unless defined $gsz && ($p + $gsz) <= $e;
					if ($gid == ID_BLOCK) {
						my $blk = substr($bg, $p, $gsz);
						my ($tnum, undef, $frames) = unpack_block(\$blk);
						if (defined $tnum && $tnum == $target_track && $frames && @$frames) {
							return $frames->[0];
						}
					}
					$p += $gsz;
				}
			}
		}
		seek($fh, $dpos + $sz, SEEK_SET);
	}
	return undef;
}

sub _detect_bitstream_profile {
	my ($codec_id, $frame) = @_;
	$codec_id ||= '';

	# TrueHD Major Sync (bytes 4..7 == 0xF8 0x72 0x6F 0xBA)
	# Byte 20 high nibble = substreams count (4 substreams => Dolby Atmos 16-ch object bed)
	if ($codec_id eq 'A_TRUEHD' && length($frame) >= 22) {
		if (substr($frame, 4, 4) eq "\xF8\x72\x6F\xBA") {
			my $substreams = (ord(substr($frame, 20, 1)) >> 4) & 0x0F;
			return 'Dolby TrueHD + Dolby Atmos' if $substreams >= 4;
		}
		return 'Dolby TrueHD';
	}

	# DTS-HD MA / High Resolution extension sync word (0x64582025)
	if ($codec_id =~ /^A_DTS/) {
		return 'DTS-HD MA' if $codec_id eq 'A_DTS/LOSSLESS' || index($frame, "\x64\x58\x20\x25") >= 0;
		return 'DTS';
	}

	# E-AC-3 JOC (Atmos) detection via ETSI TS 102 366 / TS 103 420 bit-level BSI parser
	if ($codec_id eq 'A_EAC3' && length($frame) >= 8) {
		if (substr($frame, 0, 2) eq "\x0B\x77") {
			return 'Dolby Digital Plus + Dolby Atmos' if _eac3_frame_has_joc($frame);
		}
		return 'Dolby Digital Plus';
	}

	return '';
}

sub _eac3_frame_has_joc {
	my ($frame) = @_;
	my $len = length($frame);
	return 0 if $len < 8;

	# Build bit array over the E-AC-3 header (first 64 bytes is always well past BSI/addbsi)
	my $scan_len = $len > 64 ? 64 : $len;
	my @bits;
	for my $i (0 .. $scan_len - 1) {
		my $b = ord(substr($frame, $i, 1));
		for my $sh (reverse 0 .. 7) {
			push @bits, ($b >> $sh) & 1;
		}
	}
	my $nbits = scalar(@bits);
	my $pos = 0;

	my $read_bits = sub {
		my ($n) = @_;
		return undef if ($pos + $n) > $nbits;
		my $v = 0;
		for (1 .. $n) {
			$v = ($v << 1) | $bits[$pos++];
		}
		return $v;
	};

	my $sync = $read_bits->(16);
	return 0 unless defined $sync && $sync == 0x0B77;

	my $strmtyp = $read_bits->(2);      # 0=indep, 1=dep, 2=ac3_conv, 3=reserved
	my $substreamid = $read_bits->(3);
	my $frmsiz = $read_bits->(11);
	return 0 if !defined $frmsiz || ($strmtyp // 3) == 3;

	my $fscod = $read_bits->(2);
	return 0 unless defined $fscod;
	my $num_blocks = 6;
	if ($fscod == 3) {
		my $fscod2 = $read_bits->(2);
		return 0 unless defined $fscod2;
	} else {
		my $numblkscod = $read_bits->(2);
		return 0 unless defined $numblkscod;
		my @blk_map = (1, 2, 3, 6);
		$num_blocks = $blk_map[$numblkscod];
	}

	my $acmod = $read_bits->(3);
	my $lfeon = $read_bits->(1);
	my $bsid  = $read_bits->(5);
	return 0 unless defined $acmod && defined $lfeon && defined $bsid && $bsid > 10 && $bsid <= 16;

	my $n_ch_sets = ($acmod == 0) ? 2 : 1;
	for (1 .. $n_ch_sets) {
		my $dialnorm = $read_bits->(5);
		my $compre   = $read_bits->(1);
		return 0 unless defined $dialnorm && defined $compre;
		if ($compre) {
			return 0 unless defined $read_bits->(8); # compr
		}
	}

	if ($strmtyp == 1) {
		my $chanmape = $read_bits->(1);
		return 0 unless defined $chanmape;
		if ($chanmape) {
			return 0 unless defined $read_bits->(16); # chanmap
		}
	}

	my $mixmdate = $read_bits->(1);
	return 0 unless defined $mixmdate;
	if ($mixmdate) {
		if ($acmod > 2) {
			return 0 unless defined $read_bits->(2); # dmixmod
		}
		if (($acmod & 1) && ($acmod > 2)) {
			return 0 unless defined $read_bits->(6); # ltrtcmixlev + lorocmixlev
		}
		if ($acmod & 4) {
			return 0 unless defined $read_bits->(6); # ltrtsurmixlev + lorosurmixlev
		}
		if ($lfeon) {
			my $lfemixlevcode = $read_bits->(1);
			return 0 unless defined $lfemixlevcode;
			if ($lfemixlevcode) {
				return 0 unless defined $read_bits->(5); # lfemixlevcod
			}
		}
		if ($strmtyp == 0) {
			for (1 .. $n_ch_sets) {
				my $pgmscle = $read_bits->(1);
				return 0 unless defined $pgmscle;
				if ($pgmscle) {
					return 0 unless defined $read_bits->(6);
				}
			}
			my $extpgmscle = $read_bits->(1);
			return 0 unless defined $extpgmscle;
			if ($extpgmscle) {
				return 0 unless defined $read_bits->(6);
			}

			my $mixdef = $read_bits->(2);
			return 0 unless defined $mixdef;
			if ($mixdef == 1) {
				return 0 unless defined $read_bits->(5);
			} elsif ($mixdef == 2) {
				return 0 unless defined $read_bits->(12);
			} elsif ($mixdef == 3) {
				my $mixdeflen = $read_bits->(5);
				return 0 unless defined $mixdeflen;
				return 0 unless defined $read_bits->(($mixdeflen + 2) * 8);
			}

			if ($acmod < 2) {
				for (1 .. $n_ch_sets) {
					my $paninfoe = $read_bits->(1);
					return 0 unless defined $paninfoe;
					if ($paninfoe) {
						return 0 unless defined $read_bits->(14);
					}
				}
			}

			my $frmmixcfginfoe = $read_bits->(1);
			return 0 unless defined $frmmixcfginfoe;
			if ($frmmixcfginfoe) {
				if ($num_blocks == 1) {
					return 0 unless defined $read_bits->(5);
				} else {
					for (1 .. $num_blocks) {
						my $blkmixcfginfoe = $read_bits->(1);
						return 0 unless defined $blkmixcfginfoe;
						if ($blkmixcfginfoe) {
							return 0 unless defined $read_bits->(5);
						}
					}
				}
			}
		}
	}

	my $infomdate = $read_bits->(1);
	return 0 unless defined $infomdate;
	if ($infomdate) {
		my $bsmod = $read_bits->(3);
		return 0 unless defined $bsmod;
		return 0 unless defined $read_bits->(2); # copyrightb + origbs
		if ($acmod == 2) {
			return 0 unless defined $read_bits->(4); # dsurmod + dheadphonmod
		}
		if ($acmod >= 6) {
			return 0 unless defined $read_bits->(2); # dsurexmod
		}
		for (1 .. $n_ch_sets) {
			my $audprodie = $read_bits->(1);
			return 0 unless defined $audprodie;
			if ($audprodie) {
				return 0 unless defined $read_bits->(8);
			}
		}
		if ($fscod != 3) {
			return 0 unless defined $read_bits->(1); # sourcefscod
		}
	}

	if ($strmtyp == 0 && $num_blocks != 6) {
		return 0 unless defined $read_bits->(1); # convsync
	}
	if ($strmtyp == 2) {
		my $blkid = 1;
		if ($fscod != 3) {
			my $b = $read_bits->(1);
			return 0 unless defined $b;
			$blkid = $b;
		}
		if ($blkid) {
			return 0 unless defined $read_bits->(6); # frmsizecod
		}
	}

	my $addbsie = $read_bits->(1);
	return 0 unless defined $addbsie && $addbsie == 1;

	my $addbsil = $read_bits->(6);
	return 0 unless defined $addbsil && $addbsil >= 1;

	# First byte of addbsi: LSB (bit 0) is flag_ec3_extension_type_a (Atmos JOC)
	my $ext_byte0 = $read_bits->(8);
	return 0 unless defined $ext_byte0;
	return ($ext_byte0 & 0x01) ? 1 : 0;
}

# Validate a candidate Cluster file offset and return its timestamp in seconds (or undef)
sub _probe_cluster_at {
	my ($fh, $pos, $seg_end, $scale) = @_;
	return undef if !defined $pos || $pos < 0 || ($pos + 12) >= $seg_end;
	seek($fh, $pos, SEEK_SET) or return undef;

	my $cid = _fh_read_id($fh);
	return undef unless defined $cid && $cid == ID_CLUSTER;
	my ($csz, $unk) = _fh_read_size($fh);
	return undef unless defined $csz;

	my $cdata_start = tell($fh);
	my $cend = (!$unk && ($cdata_start + $csz) <= $seg_end)
		? ($cdata_start + $csz)
		: $seg_end;
	my $scan_limit = $cdata_start + 64;
	$scan_limit = $cend if $cend < $scan_limit;

	while (tell($fh) < $scan_limit) {
		my $id = _fh_read_id($fh) // return undef;
		my ($sz, $bunk) = _fh_read_size($fh);
		return undef unless defined $sz && !$bunk;
		my $dpos = tell($fh);
		return undef if ($dpos + $sz) > $cend;

		if ($id == ID_CLUSTER_TIMECODE) {
			return undef if $sz < 1 || $sz > 8;
			my $tc_bytes;
			return undef unless read($fh, $tc_bytes, $sz) == $sz;
			# Verify next element inside Cluster has a valid Matroska Cluster-child ID
			if (($dpos + $sz + 2) <= $cend) {
				my $nid = _fh_read_id($fh);
				return undef unless defined $nid && (
					$nid == ID_SIMPLE_BLOCK || $nid == ID_BLOCK_GROUP ||
					$nid == 0xA7 || $nid == 0xAB || $nid == 0x5854 ||
					$nid == ID_CRC32 || $nid == ID_VOID
				);
			}
			return (_decode_uint($tc_bytes) * $scale) / 1_000_000_000;
		}
		seek($fh, $dpos + $sz, SEEK_SET);
	}
	return undef;
}

# Scan near $approx_pos within [$min_pos, $max_pos] for a valid Cluster header
sub _find_nearest_cluster {
	my ($fh, $approx_pos, $min_pos, $max_pos, $seg_end, $scale) = @_;
	my $win_start = $approx_pos - 65536;
	$win_start = $min_pos if $win_start < $min_pos;
	my $win_end = $approx_pos + 262144;
	$win_end = $max_pos if $win_end > $max_pos;
	return (undef, undef) if $win_end <= $win_start + 8;

	my $read_len = $win_end - $win_start;
	seek($fh, $win_start, SEEK_SET) or return (undef, undef);
	my $buf;
	my $got = read($fh, $buf, $read_len);
	return (undef, undef) unless defined $got && $got > 8;

	my $sig = pack('N', ID_CLUSTER);
	my $search_from = 0;
	while ((my $idx = index($buf, $sig, $search_from)) >= 0) {
		my $cand = $win_start + $idx;
		$search_from = $idx + 1;
		next if $cand < $min_pos || $cand >= $max_pos;
		my $tc = _probe_cluster_at($fh, $cand, $seg_end, $scale);
		return ($cand, $tc) if defined $tc;
	}
	return (undef, undef);
}

# Binary search file byte offsets for the latest Cluster with timestamp <= $target_sec
sub _binary_search_cluster {
	my ($meta, $lo, $hi, $best_pos, $best_sec, $target_sec) = @_;
	my $path = $meta->{path} or return $best_pos;
	open my $fh, '<:raw', $path or return $best_pos;

	my $seg_end = $meta->{seg_end}        || $meta->{file_size} || 0;
	my $scale   = $meta->{timecode_scale} || 1_000_000;

	while (($hi - $lo) > 262144) {
		my $mid = int(($lo + $hi) / 2);
		my ($cpos, $csec) = _find_nearest_cluster($fh, $mid, $lo, $hi, $seg_end, $scale);
		if (!defined $cpos) {
			# Either inside a single large cluster or past the final cluster (trailing Cues/Tags/Attachments)
			my $next_hi = $mid - 65536;
			last if $next_hi <= $lo;
			$hi = $next_hi;
			next;
		}
		if ($csec <= $target_sec) {
			if ($cpos >= $best_pos) {
				$best_pos = $cpos;
				$best_sec = $csec;
			}
			$lo = $cpos + 4;
		} else {
			$hi = $cpos;
		}
	}

	# Linearly scan remaining <= 256 KB window to pick the closest cluster <= $target_sec
	my $scan = $best_pos > $lo ? $best_pos : $lo;
	while ($scan < $hi) {
		my ($cpos, $csec) = _find_nearest_cluster($fh, $scan, $scan, $hi, $seg_end, $scale);
		last unless defined $cpos;
		if ($csec <= $target_sec) {
			$best_pos = $cpos;
			$best_sec = $csec;
			$scan = $cpos + 4;
		} else {
			last;
		}
	}

	close $fh;

	# Cache discovered cue point in $meta->{cues} so repeated jumps are O(1)
	if (defined $best_pos && defined $best_sec && $best_pos > ($meta->{first_cluster} || 0)) {
		my $cues = $meta->{cues} ||= [];
		if (!grep { $_->{cluster_pos} == $best_pos } @$cues) {
			push @$cues, {
				time_ticks  => int(($best_sec * 1_000_000_000) / $scale),
				time_ns     => int($best_sec * 1_000_000_000),
				time_sec    => $best_sec,
				track       => $meta->{track_number},
				cluster_pos => $best_pos,
			};
			@$cues = sort { $a->{time_ns} <=> $b->{time_ns} } @$cues;
		}
	}

	return $best_pos;
}

# Find the file byte offset of the Cluster at or immediately before $target_sec
sub find_cluster_offset_for_time {
	my ($class, $meta, $target_sec) = @_;
	return $meta->{first_cluster} unless defined $target_sec && $target_sec > 0;

	my $cues      = $meta->{cues} || [];
	my $best_pos  = $meta->{first_cluster};
	my $best_sec  = 0;
	my $upper_pos = $meta->{seg_end} || $meta->{file_size} || 0;

	for my $cue (@$cues) {
		if ($cue->{time_sec} <= $target_sec) {
			$best_pos = $cue->{cluster_pos};
			$best_sec = $cue->{time_sec};
		} else {
			$upper_pos = $cue->{cluster_pos} if $cue->{cluster_pos} < $upper_pos;
			last;
		}
	}

	# If Cues were absent or sparse (> 5s gap), binary-search directly to the target Cluster
	if (defined $best_pos && defined $upper_pos && ($upper_pos - $best_pos) > 262144
		&& (!@$cues || ($target_sec - $best_sec) > 5.0))
	{
		$best_pos = _binary_search_cluster($meta, $best_pos, $upper_pos, $best_pos, $best_sec, $target_sec);
	}

	return $best_pos;
}

# CLI self-test helper: perl Format/Matroska.pm /path/to/file.mka [start_sec] [end_sec]
if (!caller && @ARGV) {
	my ($file, $s_sec, $e_sec) = @ARGV;
	my $meta = __PACKAGE__->parse($file, { with_cover => 1 });
	die "Failed to parse $file\n" unless $meta;

	printf "File       : %s (%d bytes)\n", $meta->{path}, $meta->{file_size};
	printf "Codec      : %s (%s) profile='%s'\n", $meta->{codec}, $meta->{codec_id}, $meta->{profile};
	printf "Format     : %d ch, %d Hz, %d-bit, %.3f s\n", $meta->{channels}, $meta->{sample_rate}, $meta->{sample_size}, $meta->{secs};
	printf "Cover Art  : %s (%d bytes)\n", $meta->{has_cover} ? 'YES' : 'NO', defined $meta->{cover_art} ? length($meta->{cover_art}) : 0;
	printf "Cues       : %d entries\n", scalar(@{ $meta->{cues} });
	printf "Chapters   : %d entries\n", scalar(@{ $meta->{chapters} });
	for my $i (0 .. $#{ $meta->{chapters} }) {
		my $c = $meta->{chapters}[$i];
		printf "  [%02d] %.6f -> %.6f : %s\n", $i + 1, $c->{start_time}, $c->{end_time} // 0, $c->{tags}{TITLE} // '';
	}
}

1;
