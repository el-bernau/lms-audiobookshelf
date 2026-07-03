package Plugins::Audiobookshelf::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use Time::HiRes;

use Slim::Control::Request;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::Source;
use Slim::Player::Playlist;
use Slim::Player::Sync;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

if (main::WEBUI) {
    require Plugins::Audiobookshelf::Settings;
}

require Plugins::Audiobookshelf::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.audiobookshelf',
    'defaultLevel' => 'ERROR',
    'description'  => 'AUDIOBOOKSHELF',
});

my $prefs = preferences('plugin.audiobookshelf');

sub getDisplayName { 'AUDIOBOOKSHELF' }

sub initPlugin {
    my $class = shift;

    $prefs->init({
        server_url    => '',
        api_token     => '',
        sync_interval => 30,
        auto_resume   => 1,
    });

    if (main::WEBUI) {
        Plugins::Audiobookshelf::Settings->new();
    }

    Slim::Control::Request::subscribe(\&_newsongCallback, [['playlist'], ['newsong']]);
    Slim::Control::Request::subscribe(\&_stopCallback,    [['playlist'], ['stop']]);
    Slim::Control::Request::subscribe(\&_pauseCallback,   [['playlist'], ['pause']]);

    $class->SUPER::initPlugin(
        feed   => \&_handleFeed,
        tag    => 'audiobookshelf',
        menu   => 'apps',
        is_app => 1,
        weight => 80,
    );
}

# ---- Helpers ----

sub _server    { $prefs->get('server_url') || '' }
sub _token     { $prefs->get('api_token')  || '' }
sub _apiBase   { _server() . '/api' }
sub _authHdr   { ('Authorization' => 'Bearer ' . _token()) }

sub _formatTime {
    my $secs = int(shift || 0);
    my $h = int($secs / 3600);
    my $m = int(($secs % 3600) / 60);
    my $s = $secs % 60;
    return $h > 0
        ? sprintf('%d:%02d:%02d', $h, $m, $s)
        : sprintf('%d:%02d', $m, $s);
}

sub _errorItem {
    my $msg = shift;
    return { type => 'text', name => $msg };
}

# Build cumulative time offsets for a book's audio files.
# Returns (\@byIndex, \%byIno, $totalDuration) where byIno maps each file's
# inode to the number of seconds of book that precede it. The total is the
# summed duration of all files, used as a fallback when ABS reports a null
# media.duration (happens for some imports, e.g. OGG), which otherwise leaves
# progress sync disabled.
sub _computeOffsets {
    my $audioFiles = shift || [];
    my (@byIndex, %byIno, $cumulative);
    $cumulative = 0;
    for my $af (@$audioFiles) {
        push @byIndex, $cumulative;
        $byIno{ $af->{ino} } = $cumulative if defined $af->{ino};
        $cumulative += ($af->{duration} || 0);
    }
    return (\@byIndex, \%byIno, $cumulative);
}

# The inode of the audiobookshelf:// track currently at the play head.
sub _currentIno {
    my $client = shift;
    my $url = Slim::Player::Playlist::url($client) || '';
    my ($ino) = $url =~ m{^audiobookshelf://[^/]+/([^/?]+)};
    return $ino;
}

# Absolute position within the whole book = (offset of the current file) +
# (elapsed time within that file). Uses the ino->offset map so it is correct
# whether the whole book or just a single chapter file is queued.
sub _currentAbsTime {
    my $client = shift;
    my $offsets  = $client->pluginData('abs_offsets') || {};
    my $ino      = _currentIno($client);
    my $songtime = Slim::Player::Source::songTime($client) || 0;
    my $fileOffset = ($ino && defined $offsets->{$ino}) ? $offsets->{$ino} : 0;
    return $fileOffset + $songtime;
}

# Map an ABS audioFile to the LMS format/content_type used by the conversion
# table. The ABS file endpoint is extension-less, so we embed this in the
# audiobookshelf:// URL (see ProtocolHandler::getFormatForURL).
sub _formatForAudioFile {
    my $af  = shift || {};
    my $ext = lc($af->{metadata}{ext} || '');
    $ext =~ s/^\.//;

    return 'mp3' if $ext eq 'mp3';
    return 'mp4' if $ext =~ /^(m4a|m4b|mp4)$/;
    return 'ogg' if $ext =~ /^(ogg|oga|opus)$/;
    return 'flc' if $ext eq 'flac' || $ext eq 'flc';
    return 'aac' if $ext eq 'aac';

    # Fall back to codec when the extension is missing/unknown
    my $codec = lc($af->{codec} || '');
    return 'mp3' if $codec eq 'mp3';
    return 'mp4' if $codec eq 'aac';
    return 'flc' if $codec eq 'flac';
    return 'ogg' if $codec eq 'vorbis' || $codec eq 'opus';
    return 'mp3';
}

# ---- Main Menu Feed ----

sub _handleFeed {
    my ($client, $cb, $params) = @_;

    unless (_server() && _token()) {
        return $cb->({ items => [{
            type => 'text',
            name => cstring($client, 'AUDIOBOOKSHELF_NOT_CONFIGURED'),
        }] });
    }

    my @items;

    # Currently playing info
    if ($client && $client->pluginData('abs_tracking')) {
        my $meta   = $client->pluginData('abs_meta') || {};
        my $absPos = _currentAbsTime($client);
        push @items, {
            type => 'text',
            name => cstring($client, 'AUDIOBOOKSHELF_NOW_PLAYING')
                    . ': ' . ($meta->{title} || '?')
                    . ' — ' . _formatTime($absPos),
        };
    }

    push @items,
        {
            name => cstring($client, 'AUDIOBOOKSHELF_IN_PROGRESS'),
            url  => \&_inProgressFeed,
            type => 'link',
        },
        {
            name => cstring($client, 'AUDIOBOOKSHELF_BROWSE'),
            url  => \&_librariesFeed,
            type => 'link',
        };

    $cb->({ items => \@items });
}

# ---- In Progress ----

sub _inProgressFeed {
    my ($client, $cb) = @_;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http  = shift;
            my $data  = eval { from_json($http->content) } || {};
            my @items;

            for my $item (@{ $data->{libraryItems} || [] }) {
                next unless ($item->{mediaType} || '') eq 'book';

                my $meta     = $item->{media}{metadata} || {};
                my $progress = $item->{userMediaProgress} || {};
                my $title    = $meta->{title}      || $item->{id};
                my $author   = $meta->{authorName} || '';
                my $pct      = int(($progress->{progress} || 0) * 100);

                push @items, {
                    name        => "$title" . ($author ? " \x{2014} $author" : '') . " ($pct%)",
                    url         => \&_bookFeed,
                    passthrough => [{ itemId => $item->{id}, title => $title }],
                    type        => 'link',
                };
            }

            push @items, _errorItem(cstring($client, 'EMPTY')) unless @items;
            $cb->({ items => \@items });
        },
        sub {
            $log->error('In-progress fetch failed: ' . $_[1]);
            $cb->({ items => [_errorItem('Error: ' . ($_[1] || 'unknown'))] });
        },
        { timeout => 15 }
    )->get(_apiBase() . '/me/items-in-progress', _authHdr());
}

# ---- Browse Libraries ----

sub _librariesFeed {
    my ($client, $cb) = @_;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http  = shift;
            my $data  = eval { from_json($http->content) } || {};
            my @items;

            for my $lib (@{ $data->{libraries} || [] }) {
                next unless ($lib->{mediaType} || '') eq 'book';
                push @items, {
                    name        => $lib->{name},
                    url         => \&_libraryItemsFeed,
                    passthrough => [{ libraryId => $lib->{id} }],
                    type        => 'link',
                };
            }

            push @items, _errorItem(cstring($client, 'EMPTY')) unless @items;
            $cb->({ items => \@items });
        },
        sub {
            $log->error('Libraries fetch failed: ' . $_[1]);
            $cb->({ items => [_errorItem('Error: ' . ($_[1] || 'unknown'))] });
        },
        { timeout => 15 }
    )->get(_apiBase() . '/libraries', _authHdr());
}

sub _libraryItemsFeed {
    my ($client, $cb, $params, $passthrough) = @_;
    my $libId = $passthrough->{libraryId};

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http  = shift;
            my $data  = eval { from_json($http->content) } || {};
            my @items;

            for my $item (@{ $data->{results} || [] }) {
                my $meta   = $item->{media}{metadata} || {};
                my $title  = $meta->{title}      || $item->{id};
                my $author = $meta->{authorName} || '';

                push @items, {
                    name        => $title . ($author ? " \x{2014} $author" : ''),
                    url         => \&_bookFeed,
                    passthrough => [{ itemId => $item->{id}, title => $title }],
                    type        => 'link',
                };
            }

            push @items, _errorItem(cstring($client, 'EMPTY')) unless @items;
            $cb->({ items => \@items });
        },
        sub {
            $log->error('Library items fetch failed: ' . $_[1]);
            $cb->({ items => [_errorItem('Error: ' . ($_[1] || 'unknown'))] });
        },
        { timeout => 15 }
    )->get(
        _apiBase() . "/libraries/$libId/items?limit=100&sort=media.metadata.title&minified=1",
        _authHdr()
    );
}

# ---- Book Detail Menu ----

sub _bookFeed {
    my ($client, $cb, $params, $passthrough) = @_;
    my $itemId = $passthrough->{itemId};
    my $title  = $passthrough->{title} || $itemId;

    # Fetch item details first, then chain to progress fetch
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $item = eval { from_json($http->content) };

            if ($@ || !$item || !$item->{id}) {
                return $cb->({ items => [_errorItem('Error parsing book data')] });
            }

            # Now fetch progress
            Slim::Networking::SimpleAsyncHTTP->new(
                sub {
                    my $progHttp = shift;
                    my $progress = eval { from_json($progHttp->content) } || {};
                    _buildBookMenu($client, $cb, $item, $progress);
                },
                sub {
                    # 404 = no progress yet, treat as empty
                    _buildBookMenu($client, $cb, $item, {});
                },
                { timeout => 10 }
            )->get(_apiBase() . "/me/progress/$itemId", _authHdr());
        },
        sub {
            $log->error('Book fetch failed: ' . $_[1]);
            $cb->({ items => [_errorItem('Error: ' . ($_[1] || 'unknown'))] });
        },
        { timeout => 15 }
    )->get(_apiBase() . "/items/$itemId", _authHdr());
}

sub _buildBookMenu {
    my ($client, $cb, $item, $progress) = @_;

    my $itemId     = $item->{id};
    my $media      = $item->{media} || {};
    my $meta       = $media->{metadata} || {};
    my $audioFiles = $media->{audioFiles} || [];
    my $title      = $meta->{title}      || $itemId;
    my $cover      = _server() . "/api/items/$itemId/cover?token=" . _token();

    # Build cumulative offsets (one per audio file). Fall back to the summed
    # file durations when ABS reports a null media.duration.
    my ($offsetsRef, $offsetByIno, $totalDuration) = _computeOffsets($audioFiles);
    my @offsets  = @$offsetsRef;
    my $duration = $media->{duration} || $totalDuration;

    my @items;

    # Resume option (shown only when auto_resume is enabled and progress exists)
    my $currentTime = $progress->{currentTime} || 0;
    if ($prefs->get('auto_resume') && $currentTime > 10 && !$progress->{isFinished}) {
        my $posStr = _formatTime($currentTime);
        push @items, {
            name        => cstring($client, 'AUDIOBOOKSHELF_RESUME') . " ($posStr)",
            url         => \&_playHandler,
            passthrough => [{
                itemId      => $itemId,
                title       => $title,
                audioFiles  => $audioFiles,
                duration    => $duration,
                offsets     => \@offsets,
                offsetByIno => $offsetByIno,
                startTime   => $currentTime,
                cover       => $cover,
            }],
            type        => 'link',
            image       => $cover,
        };
    }

    # Play from start
    push @items, {
        name        => cstring($client, 'AUDIOBOOKSHELF_PLAY_FROM_START'),
        url         => \&_playHandler,
        passthrough => [{
            itemId      => $itemId,
            title       => $title,
            audioFiles  => $audioFiles,
            duration    => $duration,
            offsets     => \@offsets,
            offsetByIno => $offsetByIno,
            startTime   => 0,
            cover       => $cover,
        }],
        type        => 'link',
        image       => $cover,
    };

    # Individual files (chapters/parts)
    my $fileIdx = 0;
    for my $af (@$audioFiles) {
        my $ino       = $af->{ino};
        my $fmt       = _formatForAudioFile($af);
        my $dur       = $af->{duration} || 0;
        my $fileTitle = $af->{metaTags}{tagTitle} || $af->{metadata}{title}
                        || $af->{metadata}{filename} || "Part " . ($fileIdx + 1);
        my $offsetStr = _formatTime($offsets[$fileIdx]);

        my $play = "audiobookshelf://$itemId/$ino?format=$fmt";
        $play .= "&dur=$dur" if $dur;
        push @items, {
            name      => "$offsetStr \x{2014} $fileTitle",
            type      => 'audio',
            play      => $play,
            on_select => 'play',
            image     => $cover,
        };
        $fileIdx++;
    }

    push @items, _errorItem(cstring($client, 'EMPTY')) unless @items;
    $cb->({ items => \@items });
}

# ---- Play Handler (Resume / Play from Start) ----

sub _playHandler {
    my ($client, $cb, $params, $passthrough) = @_;

    unless ($client) {
        return $cb->({ items => [_errorItem('No player selected')] });
    }

    my $itemId     = $passthrough->{itemId};
    my $title      = $passthrough->{title}      || $itemId;
    my $audioFiles = $passthrough->{audioFiles} || [];
    my $startTime  = $passthrough->{startTime}  || 0;
    my $cover      = $passthrough->{cover};

    # Derive offsets/duration from the audio files so this is self-contained
    # and robust to a null media.duration reported by ABS.
    my ($offsets, $offsetByIno, $totalDuration) = _computeOffsets($audioFiles);
    my $duration = $passthrough->{duration} || $totalDuration;

    # Find which file to start on and the seek offset within that file
    my ($startIdx, $seekTime) = (0, 0);
    if ($startTime > 0) {
        for my $i (0 .. $#$offsets) {
            if ($i == $#$offsets || $offsets->[$i + 1] > $startTime) {
                $startIdx = $i;
                $seekTime = $startTime - $offsets->[$i];
                last;
            }
        }
    }
    $seekTime = 0 if $seekTime < 0;

    # Build audiobookshelf:// URLs; embed format always and seekTime only in
    # the starting file.
    my @urls;
    for my $i (0 .. $#$audioFiles) {
        my $ino = $audioFiles->[$i]{ino};
        my $fmt = _formatForAudioFile($audioFiles->[$i]);
        my $dur = $audioFiles->[$i]{duration} || 0;
        my $url = "audiobookshelf://$itemId/$ino?format=$fmt";
        $url .= "&dur=$dur" if $dur;
        $url .= "&seekTime=$seekTime" if $i == $startIdx && $seekTime > 0;
        push @urls, $url;
    }

    # Store tracking state before executing playlist commands
    $client->pluginData('abs_item_id', $itemId);
    $client->pluginData('abs_offsets',  $offsetByIno);
    $client->pluginData('abs_duration', $duration);
    $client->pluginData('abs_tracking', 1);
    $client->pluginData('abs_meta',    { title => $title, cover => $cover });

    # Build and start playlist
    $client->execute(['playlist', 'clear']);
    $client->execute(['playlist', 'addtracks', 'listref', \@urls]);
    $client->execute(['playlist', 'index', $startIdx]);
    $client->execute(['play']);

    _startSyncTimer($client);

    $cb->({ items => [{
        type => 'text',
        name => cstring($client, 'AUDIOBOOKSHELF_NOW_PLAYING') . ': ' . $title,
    }] });
}

# ---- Position Sync ----

sub _startSyncTimer {
    my $client   = shift;
    my $interval = $prefs->get('sync_interval') || 30;
    Slim::Utils::Timers::killTimers($client, \&_syncTick);
    Slim::Utils::Timers::setTimer(
        $client,
        Time::HiRes::time() + $interval,
        \&_syncTick
    );
}

sub _syncTick {
    my $client = shift;
    return unless $client && $client->pluginData('abs_tracking');
    _syncPosition($client);
    _startSyncTimer($client);
}

sub _syncPosition {
    my ($client) = @_;

    my $itemId   = $client->pluginData('abs_item_id') || return;
    my $duration = $client->pluginData('abs_duration') || 0;

    my $absTime = _currentAbsTime($client);

    # Don't clobber the saved position with 0. songTime() reads 0 once the play
    # head has stopped/ended, so a stop fired at end-of-playlist would otherwise
    # reset ABS progress to the very start.
    return if $absTime <= 0;

    # Always report currentTime. Only report duration/progress/isFinished when
    # we know the total duration, so we never overwrite ABS with a bogus 0.
    my %payload = ( currentTime => $absTime + 0 );
    if ($duration > 0) {
        my $progress = $absTime / $duration;
        $progress = 1.0 if $progress > 1.0;
        $payload{duration}   = $duration + 0;
        $payload{progress}   = $progress + 0;
        $payload{isFinished} = $progress >= 0.99 ? \1 : \0;
    }

    my $url  = _apiBase() . "/me/progress/$itemId";
    my $body = to_json(\%payload);

    main::INFOLOG && $log->info(sprintf(
        'ABS sync -> item=%s currentTime=%.1fs duration=%s', $itemId, $absTime, $duration
    ));

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub { main::INFOLOG && $log->info("ABS progress sync OK (currentTime=${absTime}s)") },
        sub { $log->warn('ABS progress sync failed: ' . ($_[1] || 'unknown')) },
        { timeout => 15 }
    );
    # SimpleAsyncHTTP has no PATCH wrapper; drive the shared request builder
    # directly with the method string (same path get()/post() take).
    $http->_createHTTPRequest('PATCH', $url,
        _authHdr(),
        'Content-Type' => 'application/json',
        $body
    );
}

# ---- Player Event Callbacks ----

sub _newsongCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    # In synced groups, only track the master player
    return if $client->isSynced() && !Slim::Player::Sync::isMaster($client);

    my $url = Slim::Player::Playlist::url($client) || '';

    if (index($url, 'audiobookshelf://') == 0) {
        my ($itemId) = $url =~ m{^audiobookshelf://([^/]+)/};
        my $curItem  = $client->pluginData('abs_item_id') || '';

        if ($client->pluginData('abs_tracking') && $curItem eq $itemId) {
            # Same book, new file: just restart the sync timer
            _startSyncTimer($client);
        } else {
            # Playback started outside the Resume / Play-from-Start flow
            # (e.g. selecting a single chapter file). Bootstrap tracking so the
            # position still syncs back to ABS.
            _bootstrapTracking($client, $itemId);
        }

    } else {
        # Left ABS content: final sync and clear tracking
        if ($client->pluginData('abs_tracking')) {
            _syncPosition($client);
            $client->pluginData('abs_tracking', 0);
            Slim::Utils::Timers::killTimers($client, \&_syncTick);
        }
    }
}

# Fetch a book's details and set up position tracking for a play that did not
# go through _playHandler (so abs_* pluginData was never populated).
sub _bootstrapTracking {
    my ($client, $itemId) = @_;
    return unless $itemId;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $item = eval { from_json($http->content) };
            return unless $item && $item->{id};

            my $media      = $item->{media} || {};
            my $meta       = $media->{metadata} || {};
            my $audioFiles = $media->{audioFiles} || [];
            my (undef, $offsetByIno, $totalDuration) = _computeOffsets($audioFiles);

            $client->pluginData('abs_item_id', $itemId);
            $client->pluginData('abs_offsets',  $offsetByIno);
            $client->pluginData('abs_duration', ($media->{duration} || $totalDuration));
            $client->pluginData('abs_tracking', 1);
            $client->pluginData('abs_meta',    { title => ($meta->{title} || $itemId) });

            _startSyncTimer($client);
            main::INFOLOG && $log->info("ABS tracking bootstrapped for $itemId");
        },
        sub {
            $log->warn('ABS bootstrap tracking failed: ' . ($_[1] || 'unknown'));
        },
        { timeout => 15 }
    )->get(_apiBase() . "/items/$itemId", _authHdr());
}

sub _stopCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    return unless $client->pluginData('abs_tracking');
    _syncPosition($client);
    Slim::Utils::Timers::killTimers($client, \&_syncTick);
}

sub _pauseCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    return unless $client->pluginData('abs_tracking');

    if ($client->isPaused()) {
        _syncPosition($client);
        Slim::Utils::Timers::killTimers($client, \&_syncTick);
    } else {
        _startSyncTimer($client);
    }
}

1;
