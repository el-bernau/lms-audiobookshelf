package Plugins::Audiobookshelf::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = Slim::Utils::Log->addLogCategory({ category => 'plugin.audiobookshelf' });
my $prefs = preferences('plugin.audiobookshelf');

Slim::Player::ProtocolHandlers->registerHandler('audiobookshelf', __PACKAGE__);

# audiobookshelf://{itemId}/{ino}?format={fmt}&seekTime={seconds}
sub _unwrapUrl {
    my ($class, $url) = @_;
    my ($itemId, $ino, $qs) = ($url =~ m{^audiobookshelf://([^/?]+)/([^/?]+)(?:\?(.+))?$});
    my $seekTime = 0;
    my $format   = '';
    if ($qs) {
        ($seekTime) = ($qs =~ /(?:^|&)seekTime=([^&]+)/);
        $seekTime ||= 0;
        ($format)   = ($qs =~ /(?:^|&)format=([^&]+)/);
        $format   ||= '';
    }
    my $httpUrl = $prefs->get('server_url') . "/api/items/$itemId/file/$ino?token=" . $prefs->get('api_token');
    return ($httpUrl, $seekTime + 0, $format);
}

# LMS uses this to pick the conversion/playback rule for the URL. The ABS file
# endpoint is extension-less, so without this the scanned content_type ends up
# 'unk' and Song::open can't build a command line (track skips after ~2s).
sub getFormatForURL {
    my ($class, $url) = @_;
    my (undef, undef, $format) = $class->_unwrapUrl($url);
    return $format || 'mp3';
}

sub scanUrl {
    my ($class, $url, $args) = @_;

    my $song = $args->{song};
    my ($httpUrl, $seekTime, $format) = $class->_unwrapUrl($url);
    $format ||= 'mp3';

    $song->seekdata({ startTime => $seekTime }) if $seekTime > 0;

    my $cb = $args->{cb};
    $args->{cb} = sub {
        my $track = shift;
        if ($track) {
            main::INFOLOG && $log->info("Scanned audiobookshelf $url => ", $track->url, " format=$format seekTime=$seekTime");
            $song->streamUrl($track->url);
            # The scanned (extension-less) URL leaves content_type as 'unk';
            # set it explicitly so Song::open can build a playback command.
            $track->content_type($format);
            $track->url($url);
        }
        $cb->($track, @_);
    };

    $class->SUPER::scanUrl($httpUrl, $args);
}

sub new {
    my ($class, $args) = @_;
    $args->{url} = $args->{song}->streamUrl unless $args->{redir};
    return $class->SUPER::new($args);
}

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    if (my $seekdata = $song->seekdata) {
        if (my $startTime = $seekdata->{startTime}) {
            my $ct = $song->currentTrack->content_type || '';
            if ($ct =~ /mp4|m4[ab]/i) {
                # MP4 container: moov atom is typically at the end of the file.
                # Byte-offset Range requests break decoding (skip the moov).
                # Instead, pass timeOffset so LMS passes -ss to ffmpeg (R mode),
                # which fetches the URL itself and can seek to find the moov.
                $song->seekdata({ timeOffset => $startTime + 0 });
                main::INFOLOG && $log->info("M4B: transcoder seek to $startTime seconds");
            } else {
                # For MP3 and similar: byte-offset Range request works fine.
                my $newdata = $song->getSeekData($startTime);
                $song->seekdata($newdata) if $newdata;
                main::INFOLOG && $log->info("MP3: byte-offset seek to $startTime seconds");
            }
        }
    }

    $successCb->();
}

sub isRemote        { 1 }
# Force LMS to proxy/transcode rather than handing the audiobookshelf:// URL
# directly to the player (player wouldn't know how to fetch it anyway).
sub canDirectStream { 0 }

1;
