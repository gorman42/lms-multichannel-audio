package Plugins::MultichannelAudio::Format::Wrapper;

use strict;
use warnings;

use base qw(Slim::Formats);

use JSON::XS ();
use Slim::Formats;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

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

sub getCoverArt {
	my ($class, $url) = @_;
	my $path = _urlToPath($url);
	my $native = _ensureNativeLoaded(_nativeClassForPath($path) || _fallbackNativeClass());
	if ($native && $native->can('getCoverArt')) {
		return $native->getCoverArt($url);
	}
	return undef;
}

sub getTag {
	my ($class, $url, $anchor) = @_;
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
	if ($url =~ m{^file://}i) {
		return Slim::Utils::Misc::pathFromFileURL($url);
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

	my $ffprobe = $prefs->get('ffprobe_path') || 'ffprobe';
	my $bin = Slim::Utils::Misc::findbin($ffprobe) || $ffprobe;

	open my $pipe, '-|', $bin, '-v', 'quiet', '-print_format', 'json', '-show_streams', '-show_format', $path
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

	my $audio_stream;
	for my $s (@{ $data->{streams} }) {
		if (($s->{codec_type} || '') eq 'audio') {
			$audio_stream = $s;
			last;
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

	my $secs    = ($data->{format}{duration} || $audio_stream->{duration} || 0) + 0;
	my $bitrate = int($audio_stream->{bit_rate} || $data->{format}{bit_rate} || 0);
	my $size    = int($data->{format}{size} || (-s $path) || 0);

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
		virtual_type => $vtype,
		badge        => $badge,
	};

	$cached_path  = $path;
	$cached_probe = $result;

	return $result;
}

sub _buildTagsFromProbe {
	my ($path, $probe, $base) = @_;
	my %tags = ref $base eq 'HASH' ? %$base : ();
	my $pt   = $probe->{tags} || {};

	for my $key (qw(TITLE ARTIST ALBUM ALBUMARTIST COMPOSER GENRE DATE YEAR COMMENT DISCNUMBER)) {
		if (!defined $tags{$key} && defined $pt->{$key}) {
			$tags{$key} = $pt->{$key};
		}
	}

	if (!defined $tags{YEAR} && defined $pt->{DATE} && $pt->{DATE} =~ /^(\d{4})/) {
		$tags{YEAR} = $1;
	}

	if (!defined $tags{TRACKNUM}) {
		my $trk = $pt->{TRACK} // $pt->{TRACKNUMBER};
		if (defined $trk && $trk =~ /^(\d+)/) {
			$tags{TRACKNUM} = int($1);
		}
	}

	if (!defined $tags{TITLE} || !length $tags{TITLE}) {
		my ($name) = ($path =~ m{([^/\\]+)$});
		$name =~ s/\.[^.]+$// if defined $name;
		$tags{TITLE} = $name || $path;
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
