package Plugins::Audiobookshelf::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Errno qw(EINTR);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

# Share of the player's buffer we fill ahead of the play position (see
# sysread), for players with at least MIN_BUFFER_SIZE bytes of buffer. That
# keeps the limit far above what a player needs before it starts (<= 255 KB).
use constant MAX_BUFFER_USE  => 0.7;
use constant MIN_BUFFER_SIZE => 1_000_000;

my $log   = Slim::Utils::Log->addLogCategory({ category => 'plugin.audiobookshelf' });
my $prefs = preferences('plugin.audiobookshelf');

# LMS 8.3+ can reconnect a remote stream that was cut off (see canEnhanceHTTP).
my $canReconnect = Slim::Player::Protocols::HTTP->can('canEnhanceHTTP') ? 1 : 0;

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
            # Without a title the scanned track is named after its HTTP URL,
            # which carries the API token and shows up in player displays.
            $track->title($class->getMetadataFor(undef, $url)->{title});
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

# When a paused player's buffer is full, LMS closes a remote stream
# (StreamingController::_CheckPaused) and on resume reconnects to ABS and
# buffers again; over the internet that makes every resume take seconds.
# Stop reading ahead once the player's buffer is MAX_BUFFER_USE full, counting
# what is still on its way to the player, so it never gets there: resume just
# continues from the player's buffer. Only while LMS hands our bytes to the
# player as they are, and only if LMS can reconnect the stream should ABS drop
# it meanwhile.
sub sysread {
    my $self = $_[0];

    my $client = ${*$self}{'client'};
    my $song   = ${*$self}{'song'};
    my $size   = $canReconnect && $client && $client->bufferSize || 0;

    if ($size >= MIN_BUFFER_SIZE && $song && !$song->_transcoded) {
        # The player reports its buffer level and what it received of the
        # current stream. Until its first report for this stream (e.g. right
        # after a seek) both still describe the previous one: count everything
        # we sent as buffered then.
        my $sent     = ${*$self}{'_absSent'} || 0;
        my $received = $client->bytesReceived || 0;
        my $buffered = $received > $sent ? $sent : $client->bufferFullness + $sent - $received;

        if ($buffered > $size * MAX_BUFFER_USE) {
            $! = EINTR;    # LMS retries in a moment
            return undef;
        }
    }

    my $bytes = $self->SUPER::sysread($_[1], $_[2], $_[3]);
    ${*$self}{'_absSent'} += $bytes if $bytes;
    return $bytes;
}

# Keeping the stream open while paused (see sysread) means ABS or a proxy in
# front of it may drop the idle connection. LMS's persistent mode reconnects
# with a Range request from the byte it got to, instead of ending the track.
sub canEnhanceHTTP { Slim::Player::Protocols::HTTP::PERSISTENT() }

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    # Turn the resume position into regular seek data: a byte offset plus the
    # time. LMS uses the byte offset when it streams the file to the player
    # itself (for MP4 it rebuilds the header for that time), and only the
    # time, as ffmpeg's -ss, when canSeek() below routes the seek to the
    # transcoder.
    if (my $seekdata = $song->seekdata) {
        if (my $startTime = $seekdata->{startTime}) {
            $song->seekdata($song->getSeekData($startTime) || { timeOffset => $startTime + 0 });
            main::INFOLOG && $log->info("resume at $startTime seconds");
        }
    }

    $successCb->();
}

# The HTTP handler seeks by byte offset, which only works when LMS itself
# reads the stream (direct playback or a transcoder fed on stdin). Our ffmpeg
# rules fetch the URL on their own ('R' stream mode) and never see that
# offset, so every seek, resume after pause and Resume restarted the file at
# 0:00. Report no byte seeking in that case: Song::canDoSeek then picks the
# transcoder's time seek (the 'T' capability, ffmpeg -ss) instead.
sub canSeek {
    my ($class, $client, $song) = @_;

    if (main::TRANSCODING) {
        my $transcoder = Slim::Player::TranscodingHelper::getConvertCommand2(
            $song, Slim::Music::Info::contentType($song->currentTrack), ['I', 'R'], [], []
        );
        return 0 if $transcoder && $transcoder->{streamMode} eq 'R';
    }

    return $class->SUPER::canSeek($client, $song);
}

# Title, author, book and cover for the player, queue and now-playing views.
# LMS only takes artwork for remote tracks from here; the HTTP handler we
# inherit from falls back to a generic radio icon.
sub getMetadataFor {
    my ($class, $client, $url) = @_;

    my ($itemId, $ino) = ($url || '') =~ m{^audiobookshelf://([^/?]+)/([^/?]+)};
    return {} unless $itemId;

    my (undef, undef, undef, $dur) = $class->_unwrapUrl($url);
    my $book  = Plugins::Audiobookshelf::Plugin::bookMeta($itemId);
    my $file  = $book->{files}{$ino} || {};
    my $cover = $book->{noCover} ? undef : Plugins::Audiobookshelf::Plugin::coverUrl($itemId);

    return {
        title    => $file->{title} || $book->{title} || 'Audiobookshelf',
        artist   => $book->{author},
        album    => $book->{title},
        duration => $dur || $file->{duration},
        cover    => $cover,
        icon     => $cover,
        type     => 'Audiobookshelf',
    };
}

sub isRemote        { 1 }
# Force LMS to proxy/transcode rather than handing the audiobookshelf:// URL
# directly to the player (player wouldn't know how to fetch it anyway).
sub canDirectStream { 0 }

1;
