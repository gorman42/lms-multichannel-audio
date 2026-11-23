package Plugins::MultichannelAudio::Format::Wrapper;

use strict;
use warnings;

use Slim::Formats;
use base qw(Slim::Formats);

use JSON::XS ();
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Plugins::MultichannelAudio::Format::Matroska;

our $AUTOLOAD;

my $log   = logger('plugin.multichannelaudio');
my $prefs = preferences('plugin.multichannelaudio');

my %CANDIDATE_EXT_TO_NATIVE = (
	flac  => 'flc',
	flc   => 'flc',
	m4a   => 'mp4',
	mp4   => 'mp4',
	opus  => 'ops',
	ops   => 'ops',
	ogg   => 'ogg',
	oga   => 'ogg',
	wav   => 'wav',
	wv    => 'wvp',
	wvp   => 'wvp',
);

# Single-entry scan cache to avoid duplicate ffprobe invocations for the same file
my ($cached_path, $cached_probe);

sub _ensureNativeLoaded {
	my ($native) = @_;
	return undef unless $native;
	if (!$Slim::Formats::loadedTagClasses{$native}) {
		eval "use $native";
		return undef if $@;
		$Slim::Formats::loadedTagClasses{$native} = 1;
	}
	return $native;
}

sub AUTOLOAD {
	my $method = $AUTOLOAD;
	$method =~ s/.*:://;
	return if $method eq 'DESTROY';

	my $native = _ensureNativeLoaded(_fallbackNativeClass());
	if ($native && $native->can($method)) {
		shift @_;
		return $native->$method(@_);
	}
	return undef;
}

sub can {
	my ($class, $method) = @_;
	my $code = $class->SUPER::can($method);
	return $code if $code;

	my $native = _ensureNativeLoaded(_fallbackNativeClass());
	return $native->can($method) if $native;
	return undef;
}

sub _fallbackNativeClass {
	return Plugins::MultichannelAudio::Plugin::originalFormatClass('flc')
		|| Plugins::MultichannelAudio::Plugin::originalFormatClass('mp4');
}

sub getInitialAudioBlock {
	my ($class, $fh, $url) = @_;
	my $path = _urlToPath($url);
	my $native = _ensureNativeLoaded(_nativeClassForPath($path) || _fallbackNativeClass());
	if ($native && $native->can('getInitialAudioBlock')) {
		return $native->getInitialAudioBlock($fh, $url);
	}
	return 0;
}

sub findFrameBoundaries {
	my ($class, $fh, $offset, $time) = @_;
	my $native = _ensureNativeLoaded(_fallbackNativeClass());
	if ($native && $native->can('findFrameBoundaries')) {
		return $native->findFrameBoundaries($fh, $offset, $time);
	}
	return undef;
}

sub canSeek {
	return 0;
}

sub _extractMkaCoverArt {
	my ($path) = @_;
	return undef unless defined $path && -f $path;

	if (defined $cached_path && $cached_path eq $path && ref $cached_probe eq 'HASH' && defined $cached_probe->{cover_art}) {
		return length($cached_probe->{cover_art}) > 0 ? $cached_probe->{cover_art} : undef;
	}

	my $meta = eval { Plugins::MultichannelAudio::Format::Matroska->parse($path, { with_cover => 1 }) };
	if ($meta) {
		if (defined $cached_path && $cached_path eq $path && ref $cached_probe eq 'HASH') {
			$cached_probe->{cover_art} = $meta->{cover_art} // '';
		}
		return (defined $meta->{cover_art} && length($meta->{cover_art}) > 0) ? $meta->{cover_art} : undef;
	}

	my $ffprobe = $prefs->get('ffprobe_path') || 'ffprobe';
	my $ffmpeg  = $ffprobe;
	$ffmpeg =~ s/ffprobe(\.exe)?$/ffmpeg$1/i;
	$ffmpeg = 'ffmpeg' if $ffmpeg eq $ffprobe;
	my $bin = Slim::Utils::Misc::findbin($ffmpeg) || $ffmpeg;

	open my $pipe, '-|', $bin, '-v', 'quiet', '-i', $path, '-map', '0:v:0', '-c:v', 'copy', '-f', 'image2pipe', '-'
		or return undef;
	binmode $pipe;
	local $/;
	my $data = <$pipe>;
	close $pipe;

	return (defined $data && length($data) > 0) ? $data : undef;
}

sub getCoverArt {
	my ($class, $url) = @_;
	my $path = _urlToPath($url);
	if (defined $path) {
		$path =~ s/#[^#]+$//;
		if ($path =~ /\.mka$/i) {
			return _extractMkaCoverArt($path);
		}
	}
	my $native = _ensureNativeLoaded(_nativeClassForPath($path) || _fallbackNativeClass());
	if ($native && $native->can('getCoverArt')) {
		return $native->getCoverArt($url);
	}
	return undef;
}

sub getTag {
	my ($class, $url, $anchor) = @_;
	if (!defined $anchor && defined $url && $url =~ /#([^#]+)$/) {
		$anchor = $1;
	}
	my $path = _urlToPath($url);

	if (!$path || !-f $path) {
		my $native = _ensureNativeLoaded(_nativeClassForPath($path));
		return $native ? $native->getTag($url, $anchor) : undef;
	}

	# Fast path for 1- and 2-channel native FLAC files: inspect 26-byte STREAMINFO without spawning ffprobe
	if ($path =~ /\.flac$/i) {
		my $flac_ch = _peekFlacChannels($path);
		if (defined $flac_ch && $flac_ch <= 2) {
			my $native = _ensureNativeLoaded(_nativeClassForPath($path));
			return $native ? $native->getTag($url, $anchor) : undef;
		}
	}

	my $probe = _probeFile($path);
	if (!$probe) {
		my $native = _ensureNativeLoaded(_nativeClassForPath($path));
		return $native ? $native->getTag($url, $anchor) : undef;
	}

	my $channels = $probe->{channels} || 2;
	my $vtype    = $probe->{virtual_type};
	my $is_mka   = ($path =~ /\.mka$/i) ? 1 : 0;

	# Matroska (.mka) container handling (single-track or multi-chapter album)
	if ($is_mka) {
		my $eff_type  = $vtype || 'mka';
		my $chapters  = $probe->{chapters} || [];
		my $cover_len = 0;
		if ($probe->{has_cover}) {
			my $art = _extractMkaCoverArt($path);
			$cover_len = length($art) if defined $art;
		}

		# Multi-chapter .mka album container
		if (scalar(@$chapters) > 1) {
			# Direct anchor lookup if requested for a single chapter fragment
			if (defined $anchor && $anchor =~ /^([\d.]+)-([\d.]+)$/) {
				my ($a_start, $a_end) = ($1 + 0, $2 + 0);
				for my $idx (0 .. $#$chapters) {
					my $ch = $chapters->[$idx];
					my $cs = ($ch->{start_time} // 0) + 0;
					my $ce = ($ch->{end_time}   // 0) + 0;
					if (abs($cs - $a_start) < 0.05 && $ce > $cs) {
						my $ctags = _buildTagsFromProbe($path, $probe, undef, $ch->{tags}, $idx + 1);
						$ctags->{CONTENT_TYPE} = $eff_type;
						$ctags->{CHANNELS}     = $channels;
						$ctags->{SECS}         = $ce - $cs;
						$ctags->{COVER_LENGTH} = $cover_len if $cover_len;
						if ($vtype && $prefs->get('append_title_tags') && $ctags->{TITLE}) {
							my $badge = $probe->{badge};
							$ctags->{TITLE} .= " $badge" if $badge && $ctags->{TITLE} !~ /\Q$badge\E/;
						}
						return wantarray ? ($ctags, $eff_type) : $ctags;
					}
				}
			}

			my $file_url = ($url =~ m{^file://}i) ? $url : Slim::Utils::Misc::fileURLFromPath($path);
			$file_url =~ s/#[^#]+$//;
			my $mka_url = $file_url;
			$mka_url =~ s{^file://}{mka://}i;

			eval {
				Slim::Schema->search('Track', { url => { like => "$file_url#%" } })->delete_all;
				Slim::Schema->search('Track', { url => { like => "$mka_url#%" } })->delete_all;
			};

			my $created = 0;
			for my $idx (0 .. $#$chapters) {
				my $ch    = $chapters->[$idx];
				my $start = ($ch->{start_time} // 0) + 0;
				my $end   = ($ch->{end_time}   // 0) + 0;
				next unless $end > $start;

				my $dur      = $end - $start;
				my $chap_url = "${mka_url}#${start}-${end}";
				my $ctags    = _buildTagsFromProbe($path, $probe, undef, $ch->{tags}, $idx + 1);

				$ctags->{CONTENT_TYPE} = $eff_type;
				$ctags->{CHANNELS}     = $channels;
				$ctags->{SECS}         = $dur;
				$ctags->{AUDIO}        = 1;
				$ctags->{VIRTUAL}      = 1;
				$ctags->{COVER_LENGTH} = $cover_len if $cover_len;

				if ($probe->{cues} && @{ $probe->{cues} }) {
					my $c_start = Plugins::MultichannelAudio::Format::Matroska->find_cluster_offset_for_time($probe, $start);
					my $c_end   = Plugins::MultichannelAudio::Format::Matroska->find_cluster_offset_for_time($probe, $end);
					$c_end      = $probe->{seg_end} if !defined $c_end || $c_end <= $c_start;
					$ctags->{OFFSET} = int($c_start);
					$ctags->{SIZE}   = int($c_end - $c_start);
				} elsif ($probe->{secs} && $probe->{secs} > 0 && $probe->{size}) {
					my $byterate = $probe->{size} / $probe->{secs};
					$ctags->{OFFSET} = int($byterate * $start);
					$ctags->{SIZE}   = int($byterate * $dur);
				}

				if ($vtype && $prefs->get('append_title_tags') && $ctags->{TITLE}) {
					my $badge = $probe->{badge};
					if ($badge && $ctags->{TITLE} !~ /\Q$badge\E/) {
						$ctags->{TITLE} .= " $badge";
					}
				}

				Slim::Formats::sanitizeTagValues($ctags, $path);
				Slim::Schema->updateOrCreate({
					url        => $chap_url,
					attributes => $ctags,
					readTags   => 0,
					commit     => 0,
				});
				$created++;
			}

			my $album_title = $probe->{tags}{ALBUM} || $probe->{tags}{TITLE};
			if (!defined $album_title || !length $album_title) {
				($album_title) = ($path =~ m{([^/\\]+)$});
				$album_title =~ s/\.[^.]+$// if defined $album_title;
			}

			$log->info("Expanded multi-chapter MKA $path -> $created virtual tracks (type=$eff_type ch=$channels codec=$probe->{codec})");

			my $base_tags = {
				CONTENT_TYPE => 'cur',
				AUDIO        => 0,
				TITLE        => $album_title || $path,
			};
			return wantarray ? ($base_tags, 'cur') : $base_tags;
		}

		# Single-track .mka file (2ch stereo or multichannel/bitstream)
		my $tags = _buildTagsFromProbe($path, $probe, undef);
		$tags->{CONTENT_TYPE} = $eff_type;
		$tags->{CHANNELS}     = $channels;
		$tags->{COVER_LENGTH} = $cover_len if $cover_len;

		if ($vtype && $prefs->get('append_title_tags') && $tags->{TITLE}) {
			my $badge = $probe->{badge};
			if ($badge && $tags->{TITLE} !~ /\Q$badge\E/) {
				$tags->{TITLE} .= " $badge";
			}
		}

		# Route multichannel/bitstream single-track .mka through mka:// virtual track for direct Perl streaming
		if ($vtype && (!defined $url || $url !~ m{^mka://}i)) {
			my $file_url = ($url && $url =~ m{^file://}i) ? $url : Slim::Utils::Misc::fileURLFromPath($path);
			$file_url =~ s/#[^#]+$//;
			my $mka_url = $file_url;
			$mka_url =~ s{^file://}{mka://}i;

			eval {
				Slim::Schema->search('Track', { url => { like => "$file_url#%" } })->delete_all;
				Slim::Schema->search('Track', { url => { like => "$mka_url#%" } })->delete_all;
			};

			my $end_sec = ($probe->{secs} || 0) + 0;
			my $vurl    = "${mka_url}#0-${end_sec}";
			my %vtags   = %$tags;
			$vtags{AUDIO}   = 1;
			$vtags{VIRTUAL} = 1;
			if (defined $probe->{first_cluster} && defined $probe->{seg_end} && $probe->{seg_end} > $probe->{first_cluster}) {
				$vtags{OFFSET} = int($probe->{first_cluster});
				$vtags{SIZE}   = int($probe->{seg_end} - $probe->{first_cluster});
			}

			Slim::Formats::sanitizeTagValues(\%vtags, $path);
			Slim::Schema->updateOrCreate({
				url        => $vurl,
				attributes => \%vtags,
				readTags   => 0,
				commit     => 0,
			});

			$log->info("Classified MKA $path -> virtual mka:// track (type=$eff_type ch=$channels codec=$probe->{codec} profile=$probe->{profile})");

			my $base_tags = {
				CONTENT_TYPE => 'cur',
				AUDIO        => 0,
				TITLE        => $tags->{TITLE} || $path,
			};
			return wantarray ? ($base_tags, 'cur') : $base_tags;
		}

		$log->info("Classified MKA $path -> type=$eff_type ch=$channels codec=$probe->{codec} profile=$probe->{profile}");
		return wantarray ? ($tags, $eff_type) : $tags;
	}

	# Strictly preserve 1- and 2-channel non-bitstream files untouched
	if (!$vtype && $channels <= 2) {
		my $native = _ensureNativeLoaded(_nativeClassForPath($path));
		if ($native) {
			return $native->getTag($url, $anchor);
		}
		return _buildTagsFromProbe($path, $probe, undef);
	}

	# Multichannel (>2 ch) or immersive bitstream (ec3, thd, dtshd)
	my $tags;
	my $native = _ensureNativeLoaded(_nativeClassForPath($path));
	if ($native) {
		$tags = scalar eval { $native->getTag($url, $anchor) };
	}

	$tags = _buildTagsFromProbe($path, $probe, $tags);
	$tags->{CONTENT_TYPE} = $vtype;
	$tags->{CHANNELS}     = $channels;

	if ($prefs->get('append_title_tags') && $tags->{TITLE}) {
		my $badge = $probe->{badge};
		if ($badge && $tags->{TITLE} !~ /\Q$badge\E/) {
			$tags->{TITLE} .= " $badge";
		}
	}

	$log->info("Classified $path -> type=$vtype ch=$channels codec=$probe->{codec} profile=$probe->{profile}");

	return wantarray ? ($tags, $vtype) : $tags;
}

sub _urlToPath {
	my ($url) = @_;
	return undef unless defined $url;
	if ($url =~ m{^(?:file|mka)://}i) {
		my $furl = $url;
		$furl =~ s{^mka://}{file://}i;
		return Slim::Utils::Misc::pathFromFileURL($furl);
	}
	return $url;
}

sub _nativeClassForPath {
	my ($path) = @_;
	return undef unless defined $path && $path =~ /\.([^.]+)$/;
	my $ext  = lc($1);
	my $type = $CANDIDATE_EXT_TO_NATIVE{$ext} or return undef;
	return Plugins::MultichannelAudio::Plugin::originalFormatClass($type);
}

sub _peekFlacChannels {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return undef;
	my $hdr;
	my $n = read($fh, $hdr, 26);
	close $fh;
	return undef unless defined $n && $n == 26;
	return undef unless substr($hdr, 0, 4) eq 'fLaC';

	# Block header (4 bytes): bit 7 = last-metadata-block flag, bits 0..6 = block type (0 = STREAMINFO)
	my $block_type = unpack('C', substr($hdr, 4, 1)) & 0x7f;
	return undef unless $block_type == 0;

	# STREAMINFO bytes 10..13 (offset 8 + 10 = 18 in file): 20 bits sample rate, 3 bits (channels - 1), 5 bits (bps - 1)
	my $packed = unpack('N', substr($hdr, 18, 4));
	my $channels = (($packed >> 9) & 0x07) + 1;
	return $channels;
}

sub _probeFile {
	my ($path) = @_;
	if (defined $cached_path && $cached_path eq $path) {
		return $cached_probe;
	}

	if ($path =~ /\.mka$/i) {
		my $meta = eval { Plugins::MultichannelAudio::Format::Matroska->parse($path) };
		if ($meta) {
			my $channels = int($meta->{channels} || 2);
			my $codec    = lc($meta->{codec} || '');
			my $profile  = lc($meta->{profile} || '');
			my $rate     = int($meta->{sample_rate} || 0);
			my $bps      = int($meta->{sample_size} || 0);

			my %merged_tags;
			if (ref $meta->{tags} eq 'HASH') {
				while (my ($k, $v) = each %{ $meta->{tags} }) {
					$merged_tags{ uc($k) } = $v if defined $v && length $v;
				}
			}

			my ($vtype, $badge);
			if ($codec eq 'truehd' && $profile =~ /atmos/) {
				$vtype = 'thd';
				$badge = '[Atmos]';
			} elsif ($codec eq 'eac3' && $profile =~ /atmos/) {
				$vtype = 'ec3';
				$badge = '[Atmos]';
			} elsif ($codec eq 'dts' && $profile =~ /dts-hd ma/) {
				$vtype = 'dtshd';
				my $hint = join(' ', values %merged_tags);
				$badge = ($hint =~ /auro[\s\-_]?3d/i) ? '[Auro-3D]' : '[DTS-HD MA]';
			} elsif ($channels > 2) {
				$vtype = 'mchflc';
				if ($channels == 6) {
					$badge = '[5.1]';
				} elsif ($channels == 8) {
					$badge = '[7.1]';
				} else {
					$badge = "[${channels}ch]";
				}
			}

			my $result = {
				channels       => $channels,
				codec          => $codec,
				codec_id       => $meta->{codec_id},
				profile        => $profile,
				sample_rate    => $rate,
				sample_size    => $bps,
				secs           => ($meta->{secs} || 0) + 0,
				bitrate        => int($meta->{bitrate} || 0),
				size           => int($meta->{size} || (-s $path) || 0),
				tags           => \%merged_tags,
				chapters       => $meta->{chapters} || [],
				cues           => $meta->{cues} || [],
				first_cluster  => $meta->{first_cluster},
				seg_data_start => $meta->{seg_data_start},
				seg_end        => $meta->{seg_end},
				timecode_scale => $meta->{timecode_scale},
				track_number   => $meta->{track_number},
				has_cover      => $meta->{has_cover} ? 1 : 0,
				virtual_type   => $vtype,
				badge          => $badge,
			};

			$cached_path  = $path;
			$cached_probe = $result;

			return $result;
		}
	}

	my $ffprobe = $prefs->get('ffprobe_path') || 'ffprobe';
	my $bin = Slim::Utils::Misc::findbin($ffprobe) || $ffprobe;

	open my $pipe, '-|', $bin, '-v', 'quiet', '-print_format', 'json', '-show_streams', '-show_format', '-show_chapters', $path
		or do {
			$log->warn("Failed to execute ffprobe ($bin) on $path: $!");
			return undef;
		};
	local $/;
	my $json_text = <$pipe>;
	close $pipe;

	return undef unless defined $json_text && length $json_text;

	my $data = eval { JSON::XS::decode_json($json_text) };
	if ($@ || ref $data ne 'HASH' || ref $data->{streams} ne 'ARRAY') {
		$log->warn("Invalid ffprobe JSON output for $path");
		return undef;
	}

	my ($audio_stream, $has_cover);
	for my $s (@{ $data->{streams} }) {
		my $stype = $s->{codec_type} || '';
		if (!$audio_stream && $stype eq 'audio') {
			$audio_stream = $s;
		} elsif (!$has_cover && $stype eq 'video') {
			my $disp   = ref $s->{disposition} eq 'HASH' ? $s->{disposition} : {};
			my $vcodec = lc($s->{codec_name} || '');
			if ($disp->{attached_pic} || $vcodec =~ /^(?:mjpeg|png|gif|bmp)$/) {
				$has_cover = 1;
			}
		}
	}
	return undef unless $audio_stream;

	my $channels = int($audio_stream->{channels} || 2);
	my $codec    = lc($audio_stream->{codec_name} || '');
	my $profile  = lc($audio_stream->{profile} || '');
	my $rate     = int($audio_stream->{sample_rate} || 0);
	my $bps      = int($audio_stream->{bits_per_raw_sample} || $audio_stream->{bits_per_sample} || 0);

	my ($vtype, $badge);
	if ($codec eq 'truehd' && $profile =~ /atmos/) {
		$vtype = 'thd';
		$badge = '[Atmos]';
	} elsif ($codec eq 'eac3' && $profile =~ /atmos/) {
		$vtype = 'ec3';
		$badge = '[Atmos]';
	} elsif ($codec eq 'dts' && $profile =~ /dts-hd ma/) {
		$vtype = 'dtshd';
		my $ftags = $data->{format}{tags} || {};
		my $stags = $audio_stream->{tags} || {};
		my $hint  = join(' ', values %$ftags, values %$stags);
		$badge = ($hint =~ /auro[\s\-_]?3d/i) ? '[Auro-3D]' : '[DTS-HD MA]';
	} elsif ($channels > 2) {
		$vtype = 'mchflc';
		if ($channels == 6) {
			$badge = '[5.1]';
		} elsif ($channels == 8) {
			$badge = '[7.1]';
		} else {
			$badge = "[${channels}ch]";
		}
	}

	my %merged_tags;
	if (ref $data->{format}{tags} eq 'HASH') {
		while (my ($k, $v) = each %{ $data->{format}{tags} }) {
			$merged_tags{ uc($k) } = $v if defined $v && length $v;
		}
	}
	if (ref $audio_stream->{tags} eq 'HASH') {
		while (my ($k, $v) = each %{ $audio_stream->{tags} }) {
			$merged_tags{ uc($k) } //= $v if defined $v && length $v;
		}
	}

	my $chapters = (ref $data->{chapters} eq 'ARRAY') ? $data->{chapters} : [];
	my $secs     = ($data->{format}{duration} || $audio_stream->{duration} || 0) + 0;
	my $bitrate  = int($audio_stream->{bit_rate} || $data->{format}{bit_rate} || 0);
	my $size     = int($data->{format}{size} || (-s $path) || 0);

	my $result = {
		channels     => $channels,
		codec        => $codec,
		profile      => $profile,
		sample_rate  => $rate,
		sample_size  => $bps,
		secs         => $secs,
		bitrate      => $bitrate,
		size         => $size,
		tags         => \%merged_tags,
		chapters     => $chapters,
		has_cover    => $has_cover ? 1 : 0,
		virtual_type => $vtype,
		badge        => $badge,
	};

	$cached_path  = $path;
	$cached_probe = $result;

	return $result;
}

sub _buildTagsFromProbe {
	my ($path, $probe, $base, $chap_tags, $chap_num) = @_;
	my %tags = ref $base eq 'HASH' ? %$base : ();
	my %pt   = %{ $probe->{tags} || {} };

	if (ref $chap_tags eq 'HASH') {
		# Container-level TITLE in multi-chapter MKA is the album title, not the track title
		delete $pt{TITLE};
		while (my ($k, $v) = each %$chap_tags) {
			$pt{ uc($k) } = $v if defined $v && length $v;
		}
	}

	$pt{ALBUMARTIST} //= $pt{ALBUM_ARTIST} if defined $pt{ALBUM_ARTIST};

	for my $key (qw(TITLE ARTIST ALBUM ALBUMARTIST COMPOSER GENRE DATE YEAR COMMENT DISCNUMBER)) {
		if (!defined $tags{$key} && defined $pt{$key}) {
			$tags{$key} = $pt{$key};
		}
	}

	if (!defined $tags{YEAR}) {
		for my $dkey (qw(YEAR DATE DATE_RECORDED DATE_RELEASED ORIGINAL_DATE)) {
			if (defined $pt{$dkey} && $pt{$dkey} =~ /^(\d{4})/) {
				$tags{YEAR} = $1;
				last;
			}
		}
	}

	if (!defined $tags{TRACKNUM}) {
		my $trk = $pt{TRACK} // $pt{TRACKNUMBER} // $pt{PART_NUMBER};
		if (defined $trk && $trk =~ /^(\d+)/) {
			$tags{TRACKNUM} = int($1);
		} elsif (defined $chap_num) {
			$tags{TRACKNUM} = int($chap_num);
		}
	}

	if (!defined $tags{TITLE} || !length $tags{TITLE}) {
		if (defined $chap_num) {
			$tags{TITLE} = "Track $chap_num";
		} else {
			my ($name) = ($path =~ m{([^/\\]+)$});
			$name =~ s/\.[^.]+$// if defined $name;
			$tags{TITLE} = $name || $path;
		}
	}

	$tags{CHANNELS}   ||= $probe->{channels};
	$tags{SAMPLERATE} ||= $probe->{sample_rate} if $probe->{sample_rate};
	$tags{SAMPLESIZE} ||= $probe->{sample_size} || 24;
	$tags{SECS}       ||= $probe->{secs} if $probe->{secs};
	$tags{BITRATE}    ||= $probe->{bitrate} if $probe->{bitrate};
	$tags{SIZE}       ||= $probe->{size} if $probe->{size};

	return \%tags;
}

1;
