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
    var hint;

    function send(message) { window.parent.postMessage(message, location.origin); }
    function position() {
        if (!snapshot) { return 0; }
        return Math.max(0, snapshot.position + (snapshot.paused ? 0 :
            (performance.now() - receivedAt) / 1000 * snapshot.rate));
    }
    function status(text) { if (hint) { hint.textContent = text; } }
    function inform() {
        status(!connected ? '同步連線中斷，正在重新連線…' :
            host ? '你是主控，可以播放、暫停與調整進度。' : '跟隨主控播放 · 音量與彈幕可自行調整');
    }
    function apply(force) {
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
        else if (video.paused && !video.ended) {
            expected.play = true;
            video.play().then(inform).catch(function () {
                delete expected.play;
                status('點一下播放器開始收看，之後會跟隨主控同步。');
                send({ type: 'agp:activity-autoplay-blocked' });
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
        if (connected && host) { return toggle.call(this); }
        if (connected && snapshot && !snapshot.paused) { apply(true); }
        else { this.flash('等待主控開始播放'); }
    };
    var handleKey = AgpPlayer.prototype.handleKey;
    AgpPlayer.prototype.handleKey = function (event) {
        if ((!connected || !host) && ['Home', 'End'].indexOf(event.key) !== -1) {
            event.preventDefault();
            return;
        }
        return handleKey.call(this, event);
    };

    window.addEventListener('message', function (event) {
        if (event.source !== window.parent || event.origin !== location.origin || !event.data) { return; }
        if (event.data.type === 'agp:activity-disconnect') {
            connected = false;
            if (player) { player.video.pause(); player.seek.disabled = true; }
            inform();
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
        inform();
    });

    window.AgpActivityPlayer = {
        connect: function (instance) {
            player = instance;
            player.autoNext = false;
            player.seek.disabled = true;
            hint = document.createElement('p');
            hint.className = 'activity-player-hint';
            hint.setAttribute('role', 'status');
            player.shell.appendChild(hint);
            var video = player.video;
            ['play', 'pause', 'seeked', 'ratechange', 'ended'].forEach(function (name) {
                video.addEventListener(name, function () {
                    if (Object.prototype.hasOwnProperty.call(expected, name)) {
                        var value = expected[name];
                        delete expected[name];
                        if ((name === 'seeked' && Math.abs(video.currentTime - value) < 0.2) ||
                            (name === 'ratechange' && video.playbackRate === value) ||
                            (name === 'play' && !video.paused) || (name === 'pause' && video.paused)) { return; }
                    }
                    if (!connected || !host) { apply(false); return; }
                    control({ play: 'play', pause: 'pause', seeked: 'seek', ratechange: 'rate', ended: 'pause' }[name]);
                });
            });
            video.addEventListener('loadedmetadata', function () { apply(true); });
            setInterval(function () { if (connected && host && !video.seeking && video.readyState >= 2) { control('sync'); } }, 5000);
            inform();
            send({ type: 'agp:activity-ready' });
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
            '.activity-player-hint{position:absolute;top:8px;left:12px;right:12px;z-index:4;pointer-events:none;margin:0;' +
            'color:#c8ccd7;text-shadow:0 1px 4px #000;font-size:12px}' +
            '.activity-viewer [data-action="prev"],.activity-viewer [data-action="next"],' +
            '.activity-viewer [data-action="back"],.activity-viewer [data-action="forward"],' +
            '.activity-viewer #skipIntro{display:none!important}';
        document.head.appendChild(style);
    });
}());
