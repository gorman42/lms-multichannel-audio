package Plugins::MultichannelAudio::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Scalar::Util qw(blessed);
use Slim::Formats;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::MultichannelAudio::Format::Wrapper;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.multichannelaudio',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_MULTICHANNEL_AUDIO',
});

my $prefs = preferences('plugin.multichannelaudio');

my %SCAN_INTERCEPT_TYPES = map { $_ => 1 } qw(
	flc alc alcx mp4 mp4x ops ogg wav wv wvp wvpx mka ac3 dts mchflc ec3 thd dtshd
);

my %ALWAYS_INTERCEPT_TYPES = map { $_ => 1 } qw(
	wv mka ac3 dts mchflc ec3 thd dtshd
);

my %VIRTUAL_TYPES = map { $_ => 1 } qw(
	mchflc ec3 thd dtshd
);

my %BITSTREAM_FORMAT_BYTE = (
	ec3   => 'E',
	thd   => 'T',
	dtshd => 'H',
);

my %ORIG_FORMAT_CLASS;
my $orig_classForFormat;
my $orig_getConvertCommand2;
my $orig_canDirectStream;
my $orig_stream_s;
my $orig_local_deleted;

sub initPlugin {
	my $class = shift;

	$prefs->init({
		ffprobe_path      => 'ffprobe',
		append_title_tags => 0,
	});

	$class->SUPER::initPlugin(@_);

	if (defined(&main::WEBUI) && main::WEBUI()) {
		require Plugins::MultichannelAudio::Settings;
		Plugins::MultichannelAudio::Settings->new();
	}

	_installHooks();

	$log->info('Plugins::MultichannelAudio initialized (Lyrion Music Server 9.1+)');
}

sub shutdownPlugin {
	_removeHooks();
}

sub originalFormatClass {
	my ($type) = @_;
	return undef unless defined $type;
	my $lc = lc($type);
	if (!exists $ORIG_FORMAT_CLASS{$lc} && $orig_classForFormat) {
		$ORIG_FORMAT_CLASS{$lc} = $orig_classForFormat->('Slim::Formats', $lc);
	}
	return $ORIG_FORMAT_CLASS{$lc};
}

sub _isScanning {
	return 1 if defined(&main::SCANNER) && main::SCANNER();
	if (Slim::Music::Import->can('stillScanning')) {
		return 1 if eval { Slim::Music::Import->stillScanning() };
	}
	return 0;
}

sub _extractTrack {
	my ($obj) = @_;
	return undef unless defined $obj && blessed($obj);
	if ($obj->can('currentTrack')) {
		my $t = eval { $obj->currentTrack() };
		return $t if $t;
	}
	if ($obj->can('track')) {
		my $t = eval { $obj->track() };
		return $t if $t;
	}
	if ($obj->can('content_type')) {
		return $obj;
	}
	return undef;
}

sub _activeTrackForClient {
	my ($client, $params) = @_;
	if (ref $params eq 'HASH') {
		if ($params->{song}) {
			my $t = _extractTrack($params->{song});
			return $t if $t;
		}
		if ($params->{controller} && blessed($params->{controller})) {
			if ($params->{controller}->can('song')) {
				my $t = _extractTrack(eval { $params->{controller}->song() });
				return $t if $t;
			}
			my $t = _extractTrack($params->{controller});
			return $t if $t;
		}
	}
	return undef unless defined $client && blessed($client);
	if ($client->can('streamingSong')) {
		my $ssong = eval { $client->streamingSong() };
		my $t = _extractTrack($ssong);
		return $t if $t;
	}
	if ($client->can('playingSong')) {
		my $psong = eval { $client->playingSong() };
		my $t = _extractTrack($psong);
		return $t if $t;
	}
	return undef;
}

sub _installHooks {
	no warnings 'redefine';

	# Register virtual/custom types in Slim::Formats so loadTagFormatForType() succeeds during playback
	Slim::Formats->init();
	for my $vtype (keys %ALWAYS_INTERCEPT_TYPES) {
		$Slim::Formats::tagClasses{$vtype}       = 'Plugins::MultichannelAudio::Format::Wrapper';
		$Slim::Formats::loadedTagClasses{$vtype} = 1;
	}

	# 1. Intercept Slim::Formats->classForFormat:
	#    - Always for new virtual/container types (mchflc, ec3, thd, dtshd, mka, wv, ac3, dts)
	#    - For native stereo types (flc, mp4, alc, etc.) ONLY while library scanning is active,
	#      leaving live stereo playback 100% untouched on native Slim::Formats::* classes.
	if (!$orig_classForFormat) {
		my $coderef = Slim::Formats->can('classForFormat');
		if ($coderef) {
			$orig_classForFormat = $coderef;
			*Slim::Formats::classForFormat = sub {
				my ($self, $type) = @_;
				my $orig = $orig_classForFormat->(@_);
				if (defined $type) {
					my $lc = lc($type);
					if ($ALWAYS_INTERCEPT_TYPES{$lc} || ($SCAN_INTERCEPT_TYPES{$lc} && _isScanning())) {
						if ($orig && !exists $ORIG_FORMAT_CLASS{$lc}) {
							$ORIG_FORMAT_CLASS{$lc} = $orig;
						}
						return 'Plugins::MultichannelAudio::Format::Wrapper';
					}
				}
				return $orig;
			};
		}
	}

	# Hook Slim::Utils::Scanner::Local::deleted so removing a multi-chapter .mka
	# base track ('cur') also purges its #start-end virtual chapter tracks.
	if (!$orig_local_deleted) {
		require Slim::Utils::Scanner::Local;
		my $coderef = Slim::Utils::Scanner::Local->can('deleted');
		if ($coderef) {
			$orig_local_deleted = $coderef;
			*Slim::Utils::Scanner::Local::deleted = sub {
				my ($url) = @_;
				if (defined $url && !ref $url && $url =~ /\.mka$/i) {
					my $dbh = eval { Slim::Schema->dbh };
					if ($dbh) {
						my $sth = $dbh->prepare_cached(
							'SELECT url FROM tracks WHERE url LIKE ? AND `virtual` = 1'
						);
						$sth->execute("$url#%");
						my @vurls;
						while (my ($vurl) = $sth->fetchrow_array) {
							push @vurls, $vurl;
						}
						$sth->finish;
						for my $vurl (@vurls) {
							$orig_local_deleted->($vurl);
						}
					}
				}
				return $orig_local_deleted->(@_);
			};
		}
	}

	return if defined(&main::SCANNER) && main::SCANNER();

	require Slim::Player::Squeezebox;
	require Slim::Player::Squeezebox2;
	require Slim::Player::TranscodingHelper;

	# 2. Enforce sync-group capability intersection in TranscodingHelper::getConvertCommand2
	#    Signature: ($songOrTrack, $type, $streamModes, $need, $want, $formatOverride, $rateOverride)
	if (!$orig_getConvertCommand2) {
		my $coderef = Slim::Player::TranscodingHelper->can('getConvertCommand2');
		if ($coderef) {
			$orig_getConvertCommand2 = $coderef;
			*Slim::Player::TranscodingHelper::getConvertCommand2 = sub {
				my ($songOrTrack, $format, $streamModes, $need, $want, $formatOverride, $rateOverride) = @_;

				my $ctype = (defined $format && !ref $format) ? lc($format) : '';
				if (!$ctype || !$VIRTUAL_TYPES{$ctype}) {
					return $orig_getConvertCommand2->(@_);
				}

				my $track;
				my $client;
				if (blessed($songOrTrack)) {
					if ($songOrTrack->isa('Slim::Player::Song')) {
						$track  = eval { $songOrTrack->currentTrack() };
						$client = eval { $songOrTrack->master() };
					} elsif ($songOrTrack->isa('Slim::Player::Client')) {
						$client = $songOrTrack;
						$track  = _activeTrackForClient($client);
					} else {
						$track = _extractTrack($songOrTrack);
					}
				}

				my $channels = ($track && blessed($track) && $track->can('channels')) ? int($track->channels || 6) : 6;
				my $capable  = $client ? _syncGroupSupports($client, $ctype, $channels) : 0;

				my @args = @_;
				if ($capable) {
					# Force native bitstream or multichannel FLAC rule instead of stereo 'flc' fallback
					$args[5] ||= ($ctype eq 'mchflc') ? 'flc' : $ctype;
					return $orig_getConvertCommand2->(@args);
				}

				my $cname = ($client && blessed($client) && $client->can('name')) ? $client->name : 'unknown';
				$log->info("Downgrading $ctype (${channels}ch) to 2ch stereo FLAC fallback for $cname");

				$args[5] ||= 'flc';

				if ($ctype eq 'mchflc') {
					if (wantarray) {
						my @res = $orig_getConvertCommand2->(@args);
						if (ref $res[0] eq 'HASH' && defined $res[0]->{command}) {
							$res[0]->{command} =~ s/-c:a\s+flac/-ac 2 -c:a flac/;
						}
						return @res;
					} else {
						my $tc = $orig_getConvertCommand2->(@args);
						if (ref $tc eq 'HASH' && defined $tc->{command}) {
							$tc->{command} =~ s/-c:a\s+flac/-ac 2 -c:a flac/;
						}
						return $tc;
					}
				}

				return $orig_getConvertCommand2->(@args);
			};
		}
	}

	# 3. Route virtual multichannel/bitstream formats through custom-convert.conf
	if (!$orig_canDirectStream) {
		my $coderef = Slim::Player::Squeezebox2->can('canDirectStream');
		if ($coderef) {
			$orig_canDirectStream = $coderef;
			*Slim::Player::Squeezebox2::canDirectStream = sub {
				my ($client, $url, $song) = @_;

				my $track = _extractTrack($song);
				if (!$track && defined $url && !ref $url) {
					$track = eval { Slim::Schema->objectForUrl({ url => $url }) };
				}
				my $ctype = ($track && blessed($track) && $track->can('content_type')) ? lc($track->content_type || '') : '';

				if ($ctype && $VIRTUAL_TYPES{$ctype}) {
					return 0;
				}

				return $orig_canDirectStream->(@_);
			};
		}
	}

	# 4. Patch SlimProto strm 's' header bytes (format, pcm_channels, replay_gain) in Squeezebox::sendFrame
	if (!$orig_stream_s) {
		my $coderef = Slim::Player::Squeezebox2->can('stream_s');
		if ($coderef) {
			$orig_stream_s = $coderef;
			*Slim::Player::Squeezebox2::stream_s = sub {
				my ($client, $params) = @_;

				my $track = _activeTrackForClient($client, $params);
				my $ctype = ($track && blessed($track) && $track->can('content_type')) ? lc($track->content_type || '') : '';

				if (!$ctype || !$VIRTUAL_TYPES{$ctype} || ref $params ne 'HASH') {
					return $orig_stream_s->(@_);
				}

				my $channels = ($track && blessed($track) && $track->can('channels')) ? int($track->channels || 6) : 6;
				my $capable  = _syncGroupSupports($client, $ctype, $channels);

				my ($fmt_byte, $ch_byte, $force_unity_rg) = ('f', '2', 0);
				if ($capable) {
					if (exists $BITSTREAM_FORMAT_BYTE{$ctype}) {
						$fmt_byte       = $BITSTREAM_FORMAT_BYTE{$ctype};
						$ch_byte        = '?';
						$force_unity_rg = 1;
					} elsif ($ctype eq 'mchflc') {
						my $clamped = $channels > 8 ? 8 : ($channels < 3 ? 6 : $channels);
						$fmt_byte = 'f';
						$ch_byte  = chr(ord('0') + $clamped);
					}
				}

				# Pass 'flc' into Squeezebox::stream_s so it builds a clean 24-byte header without mp3 fallback warnings
				my %local_params = %$params;
				$local_params{format} = 'flc';

				my $orig_sendFrame = \&Slim::Player::Squeezebox::sendFrame;
				local *Slim::Player::Squeezebox::sendFrame = sub {
					my ($c, $type, $dataRef) = @_;
					if (defined $type && $type eq 'strm' && ref $dataRef eq 'SCALAR' && length($$dataRef) >= 24 && substr($$dataRef, 0, 1) eq 's') {
						my $patched = $$dataRef;
						substr($patched, 2, 1, $fmt_byte);
						substr($patched, 5, 1, $ch_byte);
						if ($force_unity_rg) {
							substr($patched, 14, 4, pack('N', 0x10000));
						}
						$dataRef = \$patched;
					}
					return $orig_sendFrame->($c, $type, $dataRef);
				};

				return $orig_stream_s->($client, \%local_params);
			};
		}
	}
}

sub _removeHooks {
	no warnings 'redefine';
	*Slim::Formats::classForFormat                      = $orig_classForFormat      if $orig_classForFormat;
	*Slim::Player::TranscodingHelper::getConvertCommand2 = $orig_getConvertCommand2  if $orig_getConvertCommand2;
	*Slim::Player::Squeezebox2::canDirectStream          = $orig_canDirectStream     if $orig_canDirectStream;
	*Slim::Player::Squeezebox2::stream_s                 = $orig_stream_s            if $orig_stream_s;
	*Slim::Utils::Scanner::Local::deleted                = $orig_local_deleted       if $orig_local_deleted;
}

sub playerCapabilities {
	my ($client) = @_;
	return { mch => 0, ec3 => 0, thd => 0, dtshd => 0 } unless $client;

	my $mch   = int(_readClientCap($client, 'mch')   || 0);
	my $ec3   = _readClientCap($client, 'ec3')   ? 1 : 0;
	my $thd   = _readClientCap($client, 'thd')   ? 1 : 0;
	my $dtshd = _readClientCap($client, 'dtshd') ? 1 : 0;

	return {
		mch   => $mch,
		ec3   => $ec3,
		thd   => $thd,
		dtshd => $dtshd,
	};
}

sub isMultichannelCapable {
	my ($client) = @_;
	my $caps = playerCapabilities($client);
	return ($caps->{mch} > 0 || $caps->{ec3} || $caps->{thd} || $caps->{dtshd}) ? 1 : 0;
}

sub _readClientCap {
	my ($client, $cap) = @_;
	return undef unless $client;

	if (blessed($client) && $client->can('capabilities')) {
		my $caps = eval { $client->capabilities() };
		return $caps->{$cap} if ref $caps eq 'HASH' && exists $caps->{$cap};
	}

	if (ref $client) {
		for my $slot (qw(capabilities _capabilities)) {
			my $h = eval { $client->{$slot} };
			return $h->{$cap} if ref $h eq 'HASH' && exists $h->{$cap};
		}
	}

	# LMS stores bare SlimProto HELO tokens (e.g. mch8, ec3, thd, dtshd) in $client->formats()
	if (blessed($client) && $client->can('formats')) {
		my @fmts = eval { $client->formats() };
		if (@fmts == 1 && ref $fmts[0] eq 'ARRAY') {
			@fmts = @{ $fmts[0] };
		}
		for my $f (@fmts) {
			next unless defined $f;
			if (lc($cap) eq 'mch' && $f =~ /^mch=?(\d+)$/i) {
				return int($1);
			}
			return 1 if lc($f) eq lc($cap);
		}
	}

	if (blessed($client) && $client->can('canDo')) {
		my $val = eval { $client->canDo($cap) };
		return $val if defined $val;
	}

	if (blessed($client) && $client->can('deviceData')) {
		my $dd = eval { $client->deviceData() };
		return $dd->{$cap} if ref $dd eq 'HASH' && exists $dd->{$cap};
	}

	return undef;
}

sub _playerSupports {
	my ($client, $ctype, $channels) = @_;
	return 0 unless $client;
	return 0 unless isMultichannelCapable($client);

	my $cprefs  = $prefs->client($client);
	my $enabled = $cprefs->get('player_enabled');
	$enabled = 1 unless defined $enabled;
	return 0 unless $enabled;

	my $caps = playerCapabilities($client);

	if ($ctype eq 'mchflc') {
		my $max_ch = $caps->{mch} || 0;
		my $override = int($cprefs->get('max_channels') || 0);
		if ($override > 0 && $override < $max_ch) {
			$max_ch = $override;
		}
		return ($max_ch >= $channels && $channels >= 3) ? 1 : 0;
	}

	if ($ctype eq 'ec3' || $ctype eq 'thd' || $ctype eq 'dtshd') {
		my $allow_bs = $cprefs->get('allow_bitstream');
		$allow_bs = 1 unless defined $allow_bs;
		return 0 unless $allow_bs;
		return $caps->{$ctype} ? 1 : 0;
	}

	return 0;
}

sub _syncGroupSupports {
	my ($client, $ctype, $channels) = @_;
	return 0 unless $client;

	my @members = ($client);
	if (blessed($client) && $client->can('isSynced') && $client->isSynced(1) && $client->can('syncedWith')) {
		push @members, $client->syncedWith();
	}

	for my $member (@members) {
		return 0 unless _playerSupports($member, $ctype, $channels);
	}

	return 1;
}

1;
