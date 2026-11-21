package Plugins::MultichannelAudio::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Player::Client;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.multichannelaudio');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MULTICHANNEL_AUDIO_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MultichannelAudio/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(ffprobe_path append_title_tags));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	my @capable_players = grep {
		Plugins::MultichannelAudio::Plugin::isMultichannelCapable($_)
	} sort { lc($a->name) cmp lc($b->name) } Slim::Player::Client::clients();

	if ($params->{saveSettings}) {
		for my $p (@capable_players) {
			my $id = $p->id;
			my $cprefs = $prefs->client($p);
			$cprefs->set('player_enabled',  $params->{"player_enabled_$id"}  ? 1 : 0);
			$cprefs->set('allow_bitstream', $params->{"allow_bitstream_$id"} ? 1 : 0);
			$cprefs->set('max_channels',    int($params->{"max_channels_$id"} || 0));
		}
	}

	my @player_rows;
	for my $p (@capable_players) {
		my $id     = $p->id;
		my $cprefs = $prefs->client($p);
		my $caps   = Plugins::MultichannelAudio::Plugin::playerCapabilities($p);

		my $enabled  = $cprefs->get('player_enabled');
		$enabled     = 1 unless defined $enabled;
		my $allow_bs = $cprefs->get('allow_bitstream');
		$allow_bs    = 1 unless defined $allow_bs;
		my $max_ch   = int($cprefs->get('max_channels') || 0);

		my @cap_list;
		push @cap_list, "mch=$caps->{mch}" if $caps->{mch};
		push @cap_list, 'ec3'              if $caps->{ec3};
		push @cap_list, 'thd'              if $caps->{thd};
		push @cap_list, 'dtshd'            if $caps->{dtshd};

		push @player_rows, {
			id              => $id,
			name            => $p->name,
			player_enabled  => $enabled,
			allow_bitstream => $allow_bs,
			max_channels    => $max_ch,
			has_mch         => $caps->{mch} > 0 ? 1 : 0,
			has_bitstream   => ($caps->{ec3} || $caps->{thd} || $caps->{dtshd}) ? 1 : 0,
			caps_summary    => join(', ', @cap_list),
		};
	}

	$params->{player_rows} = \@player_rows;

	return $class->SUPER::handler($client, $params, $callback, @args);
}

1;
