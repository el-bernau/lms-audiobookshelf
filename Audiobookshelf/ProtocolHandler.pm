package Plugins::Audiobookshelf::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = Slim::Utils::Log->addLogCategory({ category => 'plugin.audiobookshelf' });
my $prefs = preferences('plugin.audiobookshelf');

Slim::Player::ProtocolHandlers->registerHandler('audiobookshelf', __PACKAGE__);

# audiobookshelf://{itemId}/{ino}?format={fmt}&dur={seconds}&seekTime={seconds}
sub _unwrapUrl {
    my ($class, $url) = @_;
    my ($itemId, $ino, $qs) = ($url =~ m{^audiobookshelf://([^/?]+)/([^/?]+)(?:\?(.+))?$});
    my $seekTime = 0;
    my $format   = '';
    my $dur      = 0;
    if ($qs) {
        ($seekTime) = ($qs =~ /(?:^|&)seekTime=([^&]+)/);
        $seekTime ||= 0;
        ($format)   = ($qs =~ /(?:^|&)format=([^&]+)/);
        $format   ||= '';
        ($dur)      = ($qs =~ /(?:^|&)dur=([^&]+)/);
        $dur      ||= 0;
    }
    my $httpUrl = $prefs->get('server_url') . "/api/items/$itemId/file/$ino?token=" . $prefs->get('api_token');
    return ($httpUrl, $seekTime + 0, $format, $dur + 0);
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
    my ($httpUrl, $seekTime, $format, $dur) = $class->_unwrapUrl($url);
    $format ||= 'mp3';

    $song->seekdata({ startTime => $seekTime }) if $seekTime > 0;

    my $cb = $args->{cb};
    $args->{cb} = sub {
        my $track = shift;
        if ($track) {
            main::INFOLOG && $log->info("Scanned audiobookshelf $url => ", $track->url, " format=$format dur=$dur seekTime=$seekTime");
            $song->streamUrl($track->url);
            # The scanned (extension-less) URL leaves content_type as 'unk';
            # set it explicitly so Song::open can build a playback command.
            $track->content_type($format);
            # Give LMS the real track length. Without it the song duration is
            # unknown, the progress bar is broken and some players mis-handle the
            # end of the finite stream.
            if ($dur) {
                $track->secs($dur);
                $song->duration($dur);
            }
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
            if ($ct eq 'mp3') {
                # mp3 is streamed directly, so a byte-offset Range request seeks
                # accurately without a transcoder.
                my $newdata = $song->getSeekData($startTime);
                $song->seekdata($newdata) if $newdata;
                main::INFOLOG && $log->info("mp3: byte-offset seek to $startTime seconds");
            } else {
                # Everything else (mp4/ogg/aac/flac) is transcoded by ffmpeg from
                # the remote URL. Byte-offset seeking would corrupt the container
                # (e.g. an MP4 moov atom lives at the end); pass timeOffset so LMS
                # gives ffmpeg -ss instead.
                $song->seekdata({ timeOffset => $startTime + 0 });
                main::INFOLOG && $log->info("$ct: transcoder seek to $startTime seconds");
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
