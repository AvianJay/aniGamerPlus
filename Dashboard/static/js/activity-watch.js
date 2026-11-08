/* Keep the existing player inside the Activity; the server owns the shared clock. */
(function () {
    'use strict';
    if (window.parent === window || new URLSearchParams(location.search).get('activity') !== '1') { return; }

    var player = null;
    var snapshot = null;
    var receivedAt = 0;
    var host = false;
    var connected = false;
    var expected = {};
    var lastRevision = null;
    var expanded = false;
    var lastPlaybackReport = 0;
    var playbackBlocked = false;
    var lastPlaybackError = '';

    function send(message) { window.parent.postMessage(message, location.origin); }
    function playbackReport(force) {
        if (!player || (!force && performance.now() - lastPlaybackReport < 5000)) { return; }
        lastPlaybackReport = performance.now();
        var video = player.video;
        send({ type: 'agp:activity-playback', sn: String(player.videoData.sn),
            title: player.seriesInfo && player.seriesInfo.title || player.videoData.anime_name || player.videoData.title || '',
            episode: episodeLabel(player.videoData), position: video.currentTime,
            duration: player.playableDuration(), paused: video.paused,
            rate: video.playbackRate, cover: player.seriesInfo && player.seriesInfo.cover || '' });
    }
    function position() {
        if (!snapshot) { return 0; }
        return Math.max(0, snapshot.position + (snapshot.paused ? 0 :
            (performance.now() - receivedAt) / 1000 * snapshot.rate));
    }
    function apply(force, manual) {
        if (!player || !snapshot) { return; }
        var video = player.video;
        var target = position();
        if (isFinite(video.duration)) { target = Math.min(target, Math.max(0, video.duration - 0.05)); }
        if (video.readyState && (force || Math.abs(video.currentTime - target) > 1.25)) {
            expected.seeked = target;
            video.currentTime = target;
        }
        if (video.playbackRate !== snapshot.rate) {
            expected.ratechange = snapshot.rate;
            video.playbackRate = snapshot.rate;
        }
        player.rate = snapshot.rate;
        if (snapshot.paused || !connected) {
            if (!video.paused) { expected.pause = true; video.pause(); }
        }
        else if (video.paused && !video.ended && (manual || (!playbackBlocked && video.readyState >= 1))) {
            if (manual && video.error) { player.retryFileSource(true); }
            expected.play = true;
            player.play().then(function (started) {
                if (!started) { delete expected.play; }
            });
        }
    }
    function control(action, extra) {
        if (!connected || !host || !player) { return; }
        send(Object.assign({ type: 'agp:activity-control', action: action,
            sn: String(player.videoData.sn),
            position: player.video.currentTime, paused: player.video.paused,
            rate: player.video.playbackRate }, extra || {}));
    }
    function guarded(original) {
        return function () {
            if (connected && host) { return original.apply(this, arguments); }
            this.flash('播放進度由主控控制');
        };
    }

    function syncExpanded(on) {
        expanded = !!on;
        if (!player) { return; }
        player.pseudoFullscreen = expanded;
        player.syncFullscreenButton();
    }

    // Discord owns the outer window. Expand our parent Activity layout only.
    AgpPlayer.prototype.toggleFullscreen = function () {
        send({ type: 'agp:activity-fullscreen', expanded: !expanded });
    };
    AgpPlayer.prototype.setPseudoFullscreen = function (on) {
        send({ type: 'agp:activity-fullscreen', expanded: !!on });
    };
    AgpPlayer.prototype.syncFullscreenButton = function () {
        var button = this.shell.querySelector('#fullscreenToggle');
        if (!button) { return; }
        button.innerHTML = AGP.icon(expanded ? 'compress' : 'expand', 23);
        button.setAttribute('aria-pressed', String(expanded));
        button.setAttribute('aria-label', expanded ? '還原畫面' : '填滿畫面');
        this.shell.classList.toggle('is-fullscreen', expanded);
    };

    // Prevent player navigation from discarding the Discord SDK and room context.
    AgpPlayer.prototype.goRelative = function (direction) {
        var next = this.neighbour(direction);
        if (next) { control('select', { sn: String(next.sn) }); }
    };
    AgpPlayer.prototype.offerNextEpisode = function () { /* Selection belongs to the room. */ };
    AgpPlayer.prototype.openEpisodeMenu = function () { this.flash('請在一起看片單中選集'); };
    AgpPlayer.prototype.nudge = guarded(AgpPlayer.prototype.nudge);
    AgpPlayer.prototype.skipOpening = guarded(AgpPlayer.prototype.skipOpening);
    AgpPlayer.prototype.applySettingRate = guarded(AgpPlayer.prototype.applySettingRate);
    var toggle = AgpPlayer.prototype.toggle;
    AgpPlayer.prototype.toggle = function () {
        if (connected && host) { playbackBlocked = false; return toggle.call(this); }
        if (connected && snapshot && !snapshot.paused) { apply(true, true); }
        else { this.flash('等待主控開始播放'); }
    };
    var handleKey = AgpPlayer.prototype.handleKey;
    AgpPlayer.prototype.handleKey = function (event) {
        if (event.key === 'Escape' && expanded) {
            send({ type: 'agp:activity-fullscreen', expanded: false });
            this.closeMenus();
            this.cancelNextEpisode();
            event.preventDefault();
            return;
        }
        if ((!connected || !host) && ['Home', 'End'].indexOf(event.key) !== -1) {
            event.preventDefault();
            return;
        }
        return handleKey.call(this, event);
    };

    window.addEventListener('message', function (event) {
        if (event.source !== window.parent || event.origin !== location.origin || !event.data) { return; }
        if (event.data.type === 'agp:activity-fullscreen-state') {
            syncExpanded(event.data.expanded === true);
            return;
        }
        if (event.data.type === 'agp:activity-disconnect') {
            connected = false;
            syncExpanded(false);
            if (player) { player.video.pause(); player.seek.disabled = true; }
            return;
        }
        if (event.data.type !== 'agp:activity-state') { return; }
        var state = event.data.state;
        if (!state || typeof state.sn !== 'string' || !Number.isFinite(state.position) ||
            !Number.isFinite(state.rate) || state.rate < 0.25 || state.rate > 4 ||
            typeof state.paused !== 'boolean') { return; }
        if (player && state.sn !== String(player.videoData.sn)) { return; }
        var force = !connected || !snapshot || host !== !!event.data.isHost;
        connected = true;
        host = !!event.data.isHost;
        // The parent projects server time to the instant it sends the snapshot.
        snapshot = state;
        receivedAt = performance.now();
        if (player) {
            player.seek.disabled = !host;
            player.shell.classList.toggle('activity-viewer', !host);
        }
        if (!host || force || state.revision !== lastRevision) { apply(force); }
        lastRevision = state.revision;
    });

    window.AgpActivityPlayer = {
        playbackError: function (reason) {
            playbackBlocked = true;
            delete expected.play;
            if (lastPlaybackError === reason) { return; }
            lastPlaybackError = reason;
            send({ type: reason === 'autoplay' ? 'agp:activity-autoplay-blocked' : 'agp:activity-playback-error',
                sn: String(player ? player.videoData.sn : activityWatchParams.get('id') || ''),
                streaming: !!(player && player.streaming), reason: reason });
        },
        playbackStarted: function () {
            playbackBlocked = false;
            lastPlaybackError = '';
            if (player) { send({ type: 'agp:activity-playback-ok', sn: String(player.videoData.sn) }); }
        },
        connect: function (instance) {
            player = instance;
            player.autoNext = false;
            player.seek.disabled = true;
            syncExpanded(expanded);
            var video = player.video;
            ['play', 'pause', 'seeked', 'ratechange', 'ended'].forEach(function (name) {
                video.addEventListener(name, function () {
                    playbackReport(true);
                    if (Object.prototype.hasOwnProperty.call(expected, name)) {
                        var value = expected[name];
                        delete expected[name];
                        if ((name === 'seeked' && Math.abs(video.currentTime - value) < 0.2) ||
                            (name === 'ratechange' && video.playbackRate === value) ||
                            (name === 'play' && !video.paused) || (name === 'pause' && video.paused)) { return; }
                    }
                    // A local media failure/reload must not pause everyone else.
                    if (video.error || playbackBlocked || (name === 'pause' && video.readyState === 0)) { return; }
                    if (!connected || !host) { apply(false); return; }
                    control({ play: 'play', pause: 'pause', seeked: 'seek', ratechange: 'rate', ended: 'pause' }[name]);
                });
            });
            video.addEventListener('loadedmetadata', function () { playbackBlocked = false; apply(true); playbackReport(true); });
            video.addEventListener('durationchange', function () { playbackReport(true); });
            video.addEventListener('timeupdate', function () { playbackReport(false); });
            setInterval(function () {
                if (connected && host && !playbackBlocked && !player.playPromise && !video.error &&
                    !video.seeking && video.readyState >= 2) { control('sync'); }
            }, 5000);
            send({ type: 'agp:activity-ready' });
            playbackReport(true);
            apply(true);
        }
    };

    document.addEventListener('DOMContentLoaded', function () {
        document.body.classList.add('activity-watch');
        var style = document.createElement('style');
        style.textContent = '.activity-watch .agp-topbar,.activity-watch .agp-subnav,' +
            '.activity-watch .watch-titlebar,.activity-watch .watch-episodes,.activity-watch .watch-info,' +
            '.activity-watch .watch-side,.activity-watch .watch-library,.activity-watch .agp-footer,' +
            '.activity-watch nav{display:none!important}.activity-watch .watch-grid{display:block}' +
            '.activity-watch .watch-page{width:100%;max-width:none;margin:0;padding:0}' +
            '.activity-watch{overflow:hidden}.activity-watch .player-shell{border:0;border-radius:0;height:100vh;aspect-ratio:auto}' +
            '.activity-viewer [data-action="prev"],.activity-viewer [data-action="next"],' +
            '.activity-viewer [data-action="back"],.activity-viewer [data-action="forward"],' +
            '.activity-viewer #skipIntro{display:none!important}';
        document.head.appendChild(style);
    });
}());
