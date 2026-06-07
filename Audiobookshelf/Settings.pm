package Plugins::Audiobookshelf::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.audiobookshelf');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('AUDIOBOOKSHELF');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/Audiobookshelf/settings/basic.html');
}

sub prefs {
    return ($prefs, qw(server_url api_token sync_interval auto_resume));
}

1;
