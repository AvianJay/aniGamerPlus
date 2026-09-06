/* ---------------------------------------------------------------------------
   aniGamerPlus+ — watch page
   A custom player (control bar, nested settings menu, danmaku overlay, HUD)
   plus the page around it: title bar, episode grid, info card, danmaku list
   and the library rails underneath.
   --------------------------------------------------------------------------- */
'use strict';

var AGP = window.AGP;
var dashboardApi = window.dashboardApi || {};

/* The iOS shell injects this before any page script runs. Where it exists, the
   two levels a browser refuses to hand over — the device's screen brightness
   and the system output volume — are the system's own, so the player drives
   them directly instead of dimming an overlay and apologising for the volume. */
var NATIVE = (window.AgpNative && window.AgpNative.version >= 1) ? window.AgpNative : null;
var BRIGHTNESS_LABEL = NATIVE ? '螢幕亮度' : '畫面亮度';

var PLAYBACK_RATES = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
var DANMAKU_OPACITIES = [100, 75, 50, 25];
var BRIGHTNESS_LEVELS = [100, 80, 60, 40, 20];
var DANMAKU_AREAS = [
    { value: '100', label: '全畫面' },
    { value: '75', label: '上方 3/4' },
    { value: '50', label: '上半部' },
    { value: '25', label: '頂端 1/4' }
];
var ASPECT_MODES = [
    { key: 'contain', label: '原始比例' },
    { key: 'cover', label: '裁切填滿' },
    { key: 'fill', label: '完整填滿' }
];
var TOUCH_PLAYER_QUERY = '(hover: none) and (pointer: coarse)';
var SKIP_SECONDS = 10;
var GESTURE_LOCK_PX = 12;          /* travel before an axis is committed */
var GESTURE_SEEK_SPAN = 120;       /* seconds represented by a full-width drag */
var DOUBLE_TAP_MS = 280;
var MIN_BRIGHTNESS = 0.2;
var CONTROLS_IDLE_MS = 2600;
var TOUCH_CONTROLS_IDLE_MS = 8000;   /* a mouse re-summons the bar by moving;
                                        a finger has to be lifted and tapped */
var NEXT_EPISODE_COUNTDOWN = 8;
/* Keys a page needs to scroll itself; the player only claims them when it is
   the thing being used. */
var PAGE_SCROLL_KEYS = [' ', 'ArrowUp', 'ArrowDown', 'Home', 'End'];

var SHORTCUTS = [
    { keys: ['Space', 'K'], label: '播放 / 暫停' },
    { keys: ['←', '→'], label: '倒退 / 快進 5 秒' },
    { keys: ['J', 'L'], label: '倒退 / 快進 10 秒' },
    { keys: ['↑', '↓'], label: '音量 +5% / -5%' },
    { keys: ['M'], label: '靜音' },
    { keys: ['F'], label: '全螢幕' },
    { keys: ['D'], label: '彈幕開關' },
    { keys: ['I'], label: '子母畫面' },
    { keys: ['B'], label: '畫面亮度循環' },
    { keys: ['<', '>'], label: '播放速度' },
    { keys: ['Home', 'End'], label: '跳到開頭 / 結尾' },
    { keys: ['?'], label: '這份清單' }
];

/* --- storage ------------------------------------------------------------- */

function readStore(key, fallback) {
    try {
        var value = window.localStorage.getItem(key);
        return value === null ? fallback : value;
    } catch (error) {
        return fallback;
    }
}

function writeStore(key, value) {
    try {
        window.localStorage.setItem(key, String(value));
    } catch (error) { /* private mode */ }
}

/* --- data ---------------------------------------------------------------- */

function isLoggedIn() {
    return dashboardApi.isLoggedIn ? dashboardApi.isLoggedIn() : false;
}

function getWatchBootstrap() {
    var bootstrap = window.__AGP_WATCH_BOOTSTRAP__;
    if (bootstrap && typeof bootstrap === 'object') {
        return bootstrap;
    }
    var element = document.getElementById('agp-watch-bootstrap');
    if (element) {
        try {
            bootstrap = JSON.parse(element.textContent || '{}');
            window.__AGP_WATCH_BOOTSTRAP__ = bootstrap;
            return bootstrap;
        } catch (error) {
            console.warn('Failed to parse watch bootstrap:', error);
        }
    }
    return {};
}

function getBootstrappedVideoData(sn) {
    var videoData = getWatchBootstrap().initialVideoData;
    return videoData && String(videoData.sn) === String(sn) ? videoData : null;
}

function getBootstrappedSeries(sn) {
    var bootstrap = getWatchBootstrap();
    if (getBootstrappedVideoData(sn) && Array.isArray(bootstrap.initialVideoSeries) &&
        bootstrap.initialVideoSeries.length) {
        return bootstrap.initialVideoSeries;
    }
    return [];
}

function getBootstrappedResumeTime(sn) {
    var bootstrap = getWatchBootstrap();
    if (String(bootstrap.requestedVideoId || '') !== String(sn)) { return null; }
    var resumeTime = Number(bootstrap.resumeTime);
    return isFinite(resumeTime) ? resumeTime : null;
}

async function getTime(sn) {
    var bootstrapped = getBootstrappedResumeTime(sn);
    if (bootstrapped !== null) { return bootstrapped; }
    if (!isLoggedIn()) { return 0; }
    try {
        var response = await fetch('./watch/time?sn=' + encodeURIComponent(sn) + '&type=get');
        var data = await response.json();
        if (data.ended) { return 0; }
        return Number(data.time) || 0;
    } catch (error) {
        return 0;
    }
}

async function getAllTimes() {
    if (!isLoggedIn()) { return {}; }
    try {
        var response = await fetch('./watch/time?type=get');
        var data = await response.json();
        return data && typeof data === 'object' ? data : {};
    } catch (error) {
        return {};
    }
}

var lastSetTime = 0;

/* The duration rides along so the home page can draw a real progress bar
   instead of guessing against a nominal episode length. */
async function setTime(sn, time, ended, duration, force) {
    var now = Date.now();
    if (!force && now - lastSetTime < 10000) { return; }
    lastSetTime = now;
    if (!isLoggedIn()) { return; }
    var query = './watch/time?type=set&sn=' + encodeURIComponent(sn);
    if (duration) { query += '&duration=' + Math.round(duration); }
    query += ended ? '&time=0&ended=true' : '&time=' + Math.round(time);
    try {
        await fetch(query);
    } catch (error) { /* a lost position is not worth interrupting playback */ }
}

var videoListCache = null;

async function getVideoList() {
    if (videoListCache) { return videoListCache; }
    try {
        var response = await fetch('./video_list.json');
        videoListCache = await response.json();
    } catch (error) {
        console.error('無法載入影片清單：', error);
        videoListCache = { videos: [] };
    }
    return videoListCache;
}

async function fetchVideoData(sn) {
    var bootstrapped = getBootstrappedVideoData(sn);
    if (bootstrapped) { return bootstrapped; }
    var list = await getVideoList();
    var videos = Array.isArray(list.videos) ? list.videos : [];
    return videos.filter(function (video) { return String(video.sn) === String(sn); })[0] || null;
}

async function getVideoSeries(video) {
    var bootstrapped = getBootstrappedSeries(video.sn);
    if (bootstrapped.length) { return bootstrapped; }
    var list = await getVideoList();
    return (list.videos || []).filter(function (candidate) {
        return candidate.anime_name === video.anime_name;
    });
}

function episodeNumber(video) {
    var value = parseFloat(video && video.episode);
    return isNaN(value) ? 0 : value;
}

function episodeLabel(video) {
    var value = String(video && video.episode !== undefined && video.episode !== null ? video.episode : '').trim();
    if (!value) { return '單集'; }
    return /^[0-9.]+$/.test(value) ? '第 ' + value + ' 集' : value;
}

function watchUrl(video) {
    return './watch?id=' + encodeURIComponent(video.sn) +
        (video.resolution ? '&res=' + encodeURIComponent(video.resolution) : '');
}

/* Cover art comes out of the episode itself: /thumbnail.jpg grabs a frame with
   ffmpeg and caches it. It sits over the generated gradient plate, and the
   capture-phase error handler below drops it again when the server has nothing
   to grab -- which is what leaves the plate showing. */
function thumbImg(video) {
    if (!video || !video.sn) { return ''; }
    return '<img class="agp-art-img" alt="" loading="lazy" src="./thumbnail.jpg?id=' +
        AGP.escapeHtml(encodeURIComponent(video.sn)) + '">';
}

document.addEventListener('error', function (event) {
    var target = event.target;
    if (target && target.classList && target.classList.contains('agp-art-img')) {
        target.remove();
    }
}, true);

/* Bahamut ships danmaku as an .ass track. Reading the dialogue lines back out
   gives the sidebar its list without a second request. */
function parseDanmakuList(assText) {
    var rows = [];
    String(assText || '').split(/\r?\n/).forEach(function (line) {
        if (line.indexOf('Dialogue:') !== 0) { return; }
        var fields = line.slice('Dialogue:'.length).split(',');
        if (fields.length < 10) { return; }
        var start = fields[1].trim();
        var text = fields.slice(9).join(',')
            .replace(/\{[^}]*\}/g, '')
            .replace(/\\[Nnh]/g, ' ')
            .trim();
        if (!text) { return; }
        var parts = start.split(':');
        if (parts.length !== 3) { return; }
        var seconds = (parseInt(parts[0], 10) * 3600) + (parseInt(parts[1], 10) * 60) + parseFloat(parts[2]);
        if (!isFinite(seconds)) { return; }
        rows.push({ time: seconds, text: text });
    });
    rows.sort(function (a, b) { return a.time - b.time; });
    return rows;
}

/* --- player -------------------------------------------------------------- */

function AgpPlayer(shell, options) {
    this.shell = shell;
    this.videoData = options.videoData;
    this.series = options.series || [];
    this.onTimeUpdate = options.onTimeUpdate || function () { };
    this.onDanmakuLoaded = options.onDanmakuLoaded || function () { };

    this.ass = null;
    this.hudTimer = null;
    this.idleTimer = null;
    this.nextTimer = null;
    this.menuView = null;
    this.scrubbing = false;
    this.danmakuEnabled = readStore('agp-danmaku', '1') === '1';
    this.danmakuOpacity = Number(readStore('agp-danmaku-opacity', '100')) || 100;
    this.danmakuArea = readStore('agp-danmaku-area', '100');
    this.aspectMode = readStore('agp-aspect', 'contain');
    this.autoNext = readStore('agp-auto-next', '1') === '1';
    /* Native reports what the screen is actually at, so the first drag starts
       from what the viewer is looking at rather than from a number the browser
       build had to remember for itself. */
    this.brightness = NATIVE
        ? NATIVE.brightness
        : Math.min(1, Math.max(MIN_BRIGHTNESS, Number(readStore('agp-brightness', '1')) || 1));
    this.rate = Number(readStore('agp-rate', '1')) || 1;
    this.isTouch = window.matchMedia(TOUCH_PLAYER_QUERY).matches;

    this.build();
}

AgpPlayer.prototype.build = function () {
    var self = this;
    var shell = this.shell;

    shell.className = 'player-shell is-custom-player' + (this.isTouch ? ' is-touch-player' : '');
    shell.tabIndex = 0;
    shell.setAttribute('aria-label', '影片播放器');
    shell.innerHTML =
        '<video id="player" playsinline webkit-playsinline preload="metadata"></video>' +
        /* On touch the surface is only the gesture pad -- announcing it as a
           play/pause button hands VoiceOver a control whose activation goes
           nowhere, because the tap belongs to attachGestures(). */
        (this.isTouch
            ? '<div class="desktop-player-surface"></div>'
            : '<button class="desktop-player-surface" type="button" aria-label="播放或暫停"></button>') +
        '<div class="desktop-player-overlay">' +
        '<div class="danmaku-layer" id="danmakuLayer"></div>' +
        '<div class="player-dim" id="playerDim"></div>' +
        '<div class="desktop-player-loader" id="playerLoader">' + AGP.icon('loader', 34) + '</div>' +
        '<div class="desktop-player-caption" id="playerCaption" hidden><span></span></div>' +
        '<div class="player-hud" id="playerHud" hidden></div>' +
        '<div class="touch-player-center" id="touchCenter"' + (this.isTouch ? '' : ' hidden') + '>' +
        '<button type="button" data-action="back" aria-label="倒退 10 秒">' + AGP.icon('rotateCcw', 26) + '<b>10</b></button>' +
        '<button type="button" class="touch-player-play" data-action="toggle" aria-label="播放或暫停">' +
        AGP.icon('play', 33) + '</button>' +
        '<button type="button" data-action="forward" aria-label="快進 10 秒">' + AGP.icon('rotateCw', 26) + '<b>10</b></button>' +
        '</div>' +
        '<div class="player-next" id="playerNext" hidden></div>' +
        '<div class="desktop-player-menu settings-menu" id="settingsMenu" hidden></div>' +
        '<div class="desktop-player-menu chapter-menu" id="episodeMenu" hidden></div>' +
        '<div class="desktop-player-controls" id="playerControls">' +
        '<div class="desktop-player-progress">' +
        '<input id="playerSeek" type="range" min="0" max="1000" value="0" step="1" aria-label="播放進度">' +
        '<output id="playerSeekTip" hidden></output>' +
        '</div>' +
        '<div class="desktop-player-control-row">' +
        '<div class="desktop-player-control-group">' +
        '<button class="desktop-player-icon-button" type="button" data-action="prev" aria-label="上一集">' +
        AGP.icon('skipBack', 23) + '</button>' +
        '<button class="desktop-player-icon-button" type="button" data-action="toggle" id="playToggle" aria-label="播放">' +
        AGP.icon('play', 23) + '</button>' +
        '<button class="desktop-player-icon-button" type="button" data-action="next" aria-label="下一集">' +
        AGP.icon('skipForward', 23) + '</button>' +
        '<div class="desktop-player-volume">' +
        '<button class="desktop-player-icon-button" type="button" data-action="mute" id="muteToggle"' +
        ' aria-label="靜音" aria-pressed="false">' +
        AGP.icon('volume', 23) + '</button>' +
        '<input id="playerVolume" type="range" min="0" max="100" value="100" aria-label="音量">' +
        '</div>' +
        '<div class="desktop-player-time"><b id="timeCurrent">0:00</b><i>/</i><i id="timeTotal">0:00</i></div>' +
        '<button class="desktop-player-chapter-button" type="button" id="episodeChip"' +
        ' aria-haspopup="true" aria-expanded="false">' +
        '<span id="episodeChipLabel">載入中</span>' + AGP.icon('chevronDown', 16) + '</button>' +
        '</div>' +
        '<div class="desktop-player-control-group desktop-player-control-actions">' +
        '<button class="desktop-player-icon-button" type="button" data-action="danmaku" id="danmakuToggle"' +
        ' aria-label="彈幕" aria-pressed="false">' +
        AGP.icon('danmaku', 23) + '</button>' +
        '<button class="desktop-player-icon-button" type="button" data-action="settings" id="settingsToggle"' +
        ' aria-label="設定" aria-haspopup="true" aria-expanded="false">' +
        AGP.icon('settings', 23) + '</button>' +
        '<button class="desktop-player-icon-button" type="button" data-action="pip" id="pipToggle" aria-label="子母畫面">' +
        AGP.icon('pip', 23) + '</button>' +
        '<button class="desktop-player-icon-button" type="button" data-action="fullscreen" id="fullscreenToggle"' +
        ' aria-label="全螢幕" aria-pressed="false">' +
        AGP.icon('expand', 23) + '</button>' +
        '</div></div></div></div>';

    this.video = shell.querySelector('video');
    this.surface = shell.querySelector('.desktop-player-surface');
    this.loader = shell.querySelector('#playerLoader');
    this.hud = shell.querySelector('#playerHud');
    this.seek = shell.querySelector('#playerSeek');
    this.seekTip = shell.querySelector('#playerSeekTip');
    this.volume = shell.querySelector('#playerVolume');
    this.timeCurrent = shell.querySelector('#timeCurrent');
    this.timeTotal = shell.querySelector('#timeTotal');
    this.settingsMenu = shell.querySelector('#settingsMenu');
    this.episodeMenu = shell.querySelector('#episodeMenu');
    this.danmakuLayer = shell.querySelector('#danmakuLayer');
    this.nextBox = shell.querySelector('#playerNext');
    this.dim = shell.querySelector('#playerDim');
    this.episodeChipLabel = shell.querySelector('#episodeChipLabel');

    /* Something to look at while the first bytes arrive, instead of a black box. */
    this.video.poster = './thumbnail.jpg?id=' + encodeURIComponent(this.videoData.sn);
    this.video.src = './get_video.mp4?id=' + encodeURIComponent(this.videoData.sn) +
        (this.videoData.resolution ? '&res=' + encodeURIComponent(this.videoData.resolution) : '');
    this.video.playbackRate = this.rate;
    this.video.volume = Math.min(1, Math.max(0, Number(readStore('agp-volume', '1'))));
    this.volume.value = String(Math.round(this.video.volume * 100));

    this.applyAspect();
    this.applyBrightness();
    this.applyDanmakuStyle();
    this.syncDanmakuButton();
    this.episodeChipLabel.textContent = episodeLabel(this.videoData) + ' · ' + this.videoData.anime_name;

    this.wire();
    this.attachGestures();
    this.showControls();
    this.loadDanmaku();

    if (!this.isTouch) {
        /* Desktop autoplays muted-free because the file is same-origin and the
           navigation was user-initiated; a rejected promise just leaves the
           poster frame up, which is the right fallback. */
        var attempt = this.video.play();
        if (attempt && attempt.catch) { attempt.catch(function () { self.updatePlayButtons(); }); }
    }
};

AgpPlayer.prototype.wire = function () {
    var self = this;
    var video = this.video;
    var shell = this.shell;

    if (!this.isTouch) {
        /* On touch the surface is the gesture pad, so tapping it reveals the
           controls instead of toggling playback (that is what the big centre
           button is for). attachGestures() owns those taps. */
        this.surface.addEventListener('click', function () { self.toggle(); });
        this.surface.addEventListener('dblclick', function () { self.toggleFullscreen(); });
    }

    shell.addEventListener('click', function (event) {
        var button = event.target.closest('[data-action]');
        if (!button || button === self.surface) { return; }
        self.handleAction(button.dataset.action);
    });

    shell.querySelector('#episodeChip').addEventListener('click', function () {
        self.openEpisodeMenu();
    });

    /* Bound to the containers, which outlive the markup each open replaces. */
    this.wireMenuKeys(this.settingsMenu);
    this.wireMenuKeys(this.episodeMenu);

    if (!this.isTouch) {
        /* Revealing the chrome on pointer movement is a hover affordance. On
           touch every tap starts with a pointerdown, so wiring it there made
           the tap handler below see freshly-revealed controls and hide them
           again -- the bar could only be summoned by tapping twice. */
        ['pointermove', 'pointerdown'].forEach(function (name) {
            shell.addEventListener(name, function () { self.showControls(); });
        });
        shell.addEventListener('pointerleave', function () {
            if (!video.paused && !self.menuView) { self.hideControls(); }
        });
    }

    video.addEventListener('loadedmetadata', function () {
        self.timeTotal.textContent = AGP.formatClock(video.duration);
        self.updateProgress();
    });
    video.addEventListener('timeupdate', function () {
        self.updateProgress();
        self.onTimeUpdate(video.currentTime, video.duration);
        if (!video.paused) {
            setTime(self.videoData.sn, video.currentTime, false, video.duration, false);
        }
    });
    video.addEventListener('progress', function () { self.updateProgress(); });
    video.addEventListener('play', function () {
        self.updatePlayButtons();
        self.armIdleTimer();
        /* Starting the picture again is a decision not to take the next
           episode, whichever control said so. */
        self.cancelNextEpisode();
    });
    video.addEventListener('pause', function () {
        self.updatePlayButtons();
        self.showControls();
        setTime(self.videoData.sn, video.currentTime, false, video.duration, true);
    });
    video.addEventListener('waiting', function () { self.loader.hidden = false; });
    video.addEventListener('playing', function () { self.loader.hidden = true; });
    video.addEventListener('canplay', function () { self.loader.hidden = true; });
    video.addEventListener('volumechange', function () {
        self.volume.value = String(Math.round(video.volume * 100));
        self.syncMuteButton();
        writeStore('agp-volume', video.volume);
    });
    video.addEventListener('ratechange', function () { self.rate = video.playbackRate; });
    video.addEventListener('ended', function () {
        setTime(self.videoData.sn, 0, true, video.duration, true);
        self.showControls();
        self.offerNextEpisode();
    });
    video.addEventListener('error', function () {
        self.loader.hidden = true;
        self.flash('影片載入失敗');
    });

    this.seek.addEventListener('input', function () {
        self.scrubbing = true;
        var target = (Number(self.seek.value) / 1000) * (video.duration || 0);
        self.timeCurrent.textContent = AGP.formatClock(target);
        self.seek.setAttribute('aria-valuetext', AGP.formatClock(target));
        self.paintSeek();
        self.showSeekTip(target);
        /* A drag is not idleness: without this the bar fades out from under
           the finger that is holding the slider. */
        self.showControls();
    });
    this.seek.addEventListener('change', function () {
        self.scrubbing = false;
        if (video.duration) {
            video.currentTime = (Number(self.seek.value) / 1000) * video.duration;
        }
        self.seekTip.hidden = true;
    });
    this.seek.addEventListener('pointerleave', function () {
        if (!self.scrubbing) { self.seekTip.hidden = true; }
    });

    this.volume.addEventListener('input', function () {
        video.muted = false;
        self.setVolumeSafe(Number(self.volume.value) / 100);
    });

    /* The hardware buttons, Control Centre and auto-brightness move the same
       levels the player does; the app says so when they do. */
    if (NATIVE) {
        window.addEventListener('agpnativechange', function () {
            self.brightness = NATIVE.brightness;
            self.volume.value = String(Math.round(NATIVE.volume * 100));
        });
    }

    document.addEventListener('fullscreenchange', function () { self.syncFullscreenButton(); });
    document.addEventListener('webkitfullscreenchange', function () { self.syncFullscreenButton(); });

    document.addEventListener('keydown', function (event) { self.handleKey(event); });

    document.addEventListener('click', function (event) {
        if (!self.menuView) { return; }
        /* Opening a sub-view replaces the menu's markup while this click is
           still bubbling, so event.target is already detached by the time we
           run and shell.contains() says "outside". composedPath() still
           remembers where the click really happened. */
        var path = event.composedPath ? event.composedPath() : [];
        if (path.indexOf(shell) !== -1 || shell.contains(event.target)) { return; }
        self.closeMenus();
    });

    window.addEventListener('beforeunload', function () {
        if (video.currentTime > 0 && !video.ended) {
            setTime(self.videoData.sn, video.currentTime, false, video.duration, true);
        }
    });
};

AgpPlayer.prototype.handleAction = function (action) {
    switch (action) {
        case 'toggle': this.toggle(); break;
        case 'back': this.nudge(-SKIP_SECONDS); break;
        case 'forward': this.nudge(SKIP_SECONDS); break;
        case 'mute': this.toggleMute(); break;
        case 'danmaku': this.setDanmaku(!this.danmakuEnabled); break;
        case 'settings': this.toggleSettings(); break;
        case 'pip': this.togglePip(); break;
        case 'fullscreen': this.toggleFullscreen(); break;
        case 'prev': this.goRelative(-1); break;
        case 'next': this.goRelative(1); break;
        default: break;
    }
};

AgpPlayer.prototype.toggle = function () {
    if (this.video.paused) {
        this.video.play();
        this.flash('播放');
    } else {
        this.video.pause();
        this.flash('暫停');
    }
};

AgpPlayer.prototype.nudge = function (delta) {
    if (!this.video.duration) { return; }
    this.video.currentTime = Math.min(this.video.duration,
        Math.max(0, this.video.currentTime + delta));
    this.flash((delta > 0 ? '快進 ' : '倒退 ') + Math.abs(delta) + ' 秒');
    this.showControls();
};

AgpPlayer.prototype.toggleMute = function () {
    this.video.muted = !this.video.muted;
    this.flash(this.video.muted ? '靜音' : '取消靜音');
};

AgpPlayer.prototype.syncMuteButton = function () {
    var button = this.shell.querySelector('#muteToggle');
    var muted = this.video.muted;
    /* The icon shows whether anything is audible; the label and pressed state
       have to describe the toggle itself, which only flips video.muted. */
    var silent = muted || this.video.volume === 0;
    button.innerHTML = AGP.icon(silent ? 'volumeOff' : 'volume', 23);
    button.classList.toggle('active', silent);
    button.setAttribute('aria-pressed', muted ? 'true' : 'false');
    button.setAttribute('aria-label', muted ? '取消靜音' : '靜音');
};

AgpPlayer.prototype.updatePlayButtons = function () {
    var paused = this.video.paused;
    var main = this.shell.querySelector('#playToggle');
    main.innerHTML = AGP.icon(paused ? 'play' : 'pause', 23);
    main.setAttribute('aria-label', paused ? '播放' : '暫停');
    var touch = this.shell.querySelector('.touch-player-play');
    if (touch) { touch.innerHTML = AGP.icon(paused ? 'play' : 'pause', 33); }
};

AgpPlayer.prototype.paintSeek = function () {
    var video = this.video;
    var played = video.duration ? (video.currentTime / video.duration) * 100 : 0;
    if (this.scrubbing) { played = Number(this.seek.value) / 10; }
    var buffered = 0;
    if (video.buffered && video.buffered.length && video.duration) {
        buffered = (video.buffered.end(video.buffered.length - 1) / video.duration) * 100;
    }
    buffered = Math.max(buffered, played);
    this.seek.style.background =
        'linear-gradient(to right, #ff0033 0%, #ff0033 ' + played + '%, ' +
        'rgb(255 255 255 / 72%) ' + played + '%, rgb(255 255 255 / 72%) ' + buffered + '%, ' +
        'rgb(255 255 255 / 32%) ' + buffered + '%, rgb(255 255 255 / 32%) 100%)';
};

AgpPlayer.prototype.updateProgress = function () {
    var video = this.video;
    if (!this.scrubbing) {
        this.seek.value = String(video.duration ? Math.round((video.currentTime / video.duration) * 1000) : 0);
        this.timeCurrent.textContent = AGP.formatClock(video.currentTime);
        this.seek.setAttribute('aria-valuetext', AGP.formatClock(video.currentTime) +
            (video.duration ? ' / ' + AGP.formatClock(video.duration) : ''));
    }
    if (video.duration) { this.timeTotal.textContent = AGP.formatClock(video.duration); }
    this.paintSeek();
};

AgpPlayer.prototype.showSeekTip = function (seconds) {
    var ratio = Number(this.seek.value) / 1000;
    this.seekTip.hidden = false;
    this.seekTip.textContent = AGP.formatClock(seconds);
    /* The bubble is centred on the thumb, so at either end of the bar half of
       it would sit outside the row and be clipped away. Keep that half in. */
    var lane = this.seekTip.parentNode.getBoundingClientRect().width;
    var margin = lane ? (this.seekTip.getBoundingClientRect().width / 2) / lane : 0;
    this.seekTip.style.left =
        (Math.max(margin, Math.min(1 - margin, ratio)) * 100) + '%';
};

AgpPlayer.prototype.flash = function (message) {
    var self = this;
    this.hud.hidden = false;
    this.hud.classList.remove('is-bar');
    this.hud.textContent = message;
    /* Restarting the animation needs a reflow between the removal and the
       re-add, otherwise a repeated tap shows nothing at all. */
    this.hud.style.animation = 'none';
    void this.hud.offsetWidth;
    this.hud.style.animation = '';
    clearTimeout(this.hudTimer);
    this.hudTimer = setTimeout(function () { self.hud.hidden = true; }, 900);
};

AgpPlayer.prototype.showControls = function () {
    this.shell.classList.add('controls-visible');
    /* The tap handler refuses to hide a bar this fresh, so the first tap of a
       double tap can never take it away. */
    this.controlsShownAt = Date.now();
    this.armIdleTimer();
};

AgpPlayer.prototype.hideControls = function () {
    if (this.menuView) { return; }
    this.shell.classList.remove('controls-visible');
    this.seekTip.hidden = true;
};

AgpPlayer.prototype.armIdleTimer = function () {
    var self = this;
    clearTimeout(this.idleTimer);
    if (this.video.paused || this.menuView) { return; }
    this.idleTimer = setTimeout(function () { self.hideControls(); },
        this.isTouch ? TOUCH_CONTROLS_IDLE_MS : CONTROLS_IDLE_MS);
};

/* --- brightness and volume ------------------------------------------------ */

/* No browser exposes screen brightness to a page, so in a browser "brightness"
   dims the picture with an overlay — what every mobile web player does, and why
   it is labelled 畫面亮度 rather than 螢幕亮度 there. In the iOS app the bridge
   hands over the real thing, and the label changes to match. */
AgpPlayer.prototype.applyBrightness = function () {
    if (NATIVE) {
        /* Dimming the picture too would apply the same drop twice. */
        if (this.dim) { this.dim.style.opacity = '0'; }
        NATIVE.setBrightness(this.brightness);
        return;
    }
    if (!this.dim) { return; }
    this.dim.style.opacity = String(1 - this.brightness);
    writeStore('agp-brightness', this.brightness);
};

/* The floor stops a web viewer blacking the picture out with no way back. iOS
   never turns the backlight fully off, so the app has no such trap and gets the
   whole range. */
AgpPlayer.prototype.setBrightness = function (value) {
    this.brightness = Math.min(1, Math.max(NATIVE ? 0 : MIN_BRIGHTNESS, value));
    this.applyBrightness();
    return this.brightness;
};

/* iOS ignores writes to HTMLMediaElement.volume — the hardware buttons own it.
   Probing once tells the gesture handler whether it has to route audio through
   a gain node to have any effect at all. */
AgpPlayer.prototype.volumeIsLocked = function () {
    if (this.volumeLocked !== undefined) { return this.volumeLocked; }
    var original = this.video.volume;
    var probe = original > 0.5 ? 0.3 : 0.7;
    this.video.volume = probe;
    this.volumeLocked = Math.abs(this.video.volume - probe) > 0.01;
    if (!this.volumeLocked) { this.video.volume = original; }
    return this.volumeLocked;
};

/* WebAudio can still attenuate a locked element, at the cost of taking the
   audio off the native path (AirPlay and the iOS route picker follow the
   element, not the graph). Built lazily so a viewer who never uses the volume
   gesture keeps the plain path. */
AgpPlayer.prototype.ensureGain = function () {
    if (this.gain !== undefined) { return this.gain; }
    var Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) { this.gain = null; return null; }
    try {
        var context = new Context();
        var source = context.createMediaElementSource(this.video);
        var gain = context.createGain();
        source.connect(gain);
        gain.connect(context.destination);
        this.audioContext = context;
        this.gain = gain;
    } catch (error) {
        console.warn('無法建立音訊增益節點：', error);
        this.gain = null;
    }
    return this.gain;
};

AgpPlayer.prototype.effectiveVolume = function () {
    if (NATIVE) { return NATIVE.volume; }
    if (this.gain) { return this.gain.gain.value; }
    return this.video.muted ? 0 : this.video.volume;
};

/* Returns the level actually applied, or null when the platform refuses. */
AgpPlayer.prototype.setVolumeSafe = function (value) {
    var level = Math.min(1, Math.max(0, value));
    if (NATIVE) {
        /* The system output level, not the element's: this is the same slider
           the hardware buttons move, so nothing has to be routed off the
           native audio path to make it work. */
        NATIVE.setVolume(level);
        this.volume.value = String(Math.round(level * 100));
        return level;
    }
    if (!this.volumeIsLocked()) {
        this.video.muted = false;
        this.video.volume = level;
        return level;
    }
    var gain = this.ensureGain();
    if (!gain) { return null; }
    if (this.audioContext && this.audioContext.state === 'suspended') {
        this.audioContext.resume();
    }
    gain.gain.value = level;
    writeStore('agp-volume', level);
    this.volume.value = String(Math.round(level * 100));
    return level;
};

/* --- touch gestures -------------------------------------------------------- */

/* Drag up/down on the right half for volume, on the left half for brightness,
   sideways anywhere to scrub — the layout every mobile video app uses. */
AgpPlayer.prototype.attachGestures = function () {
    if (!this.isTouch) { return; }

    var self = this;
    /* The gesture pad has to be the shell, not the surface: the overlay above
       the surface carries the big centre buttons, and a drag that starts on
       one of them never reached a listener bound to the surface alone. The
       geometry still comes from the surface -- the picture is what the zones
       are about. */
    var pad = this.shell;
    var gesture = null;
    var lastTap = { time: 0, zone: '' };

    this.surface.style.touchAction = 'none';
    var center = this.shell.querySelector('#touchCenter');
    if (center) { center.style.touchAction = 'none'; }

    function zoneOf(clientX, rect) {
        return (clientX - rect.left) / rect.width < 0.5 ? 'left' : 'right';
    }

    /* A menu or the next-episode card owns its whole area. The control bar
       does not: on a phone it covers the bottom 40% of the picture, so only
       its actual widgets are off-limits and a drag started in the gaps
       between them still scrubs. */
    function isChrome(target) {
        if (!target || !target.closest) { return false; }
        if (target.closest('.desktop-player-menu, #playerNext')) { return true; }
        return !!(target.closest('#playerControls') &&
            target.closest('button, input, select, a, label'));
    }

    pad.addEventListener('pointerdown', function (event) {
        /* Nothing fades out from under a finger that is still on the glass --
           including a finger on the bar's own widgets, which leave through the
           early return below. */
        clearTimeout(self.idleTimer);
        if (event.pointerType === 'mouse' && event.button !== 0) { return; }
        /* A second finger must not take the slot the first one settles from:
           finger 1's pointerup would then be dropped, stranding its HUD and
           throwing away the seek it had lined up. */
        if (gesture) { return; }
        if (isChrome(event.target)) { return; }
        var rect = self.surface.getBoundingClientRect();
        gesture = {
            id: event.pointerId,
            rect: rect,
            x: event.clientX,
            y: event.clientY,
            zone: zoneOf(event.clientX, rect),
            axis: null,
            button: event.target.closest ? event.target.closest('[data-action]') : null,
            /* Tapping the bar's own background should not hide the bar out
               from under the finger that is reaching for a button. */
            passive: !!(event.target.closest && event.target.closest('#playerControls')),
            startTime: self.video.currentTime,
            startVolume: self.effectiveVolume(),
            startBrightness: self.brightness,
            seekTarget: null
        };
    });

    pad.addEventListener('pointermove', function (event) {
        if (!gesture || event.pointerId !== gesture.id) { return; }
        var dx = event.clientX - gesture.x;
        var dy = event.clientY - gesture.y;

        if (!gesture.axis) {
            if (Math.abs(dx) < GESTURE_LOCK_PX && Math.abs(dy) < GESTURE_LOCK_PX) { return; }
            gesture.axis = Math.abs(dx) > Math.abs(dy)
                ? 'seek'
                : (gesture.zone === 'right' ? 'volume' : 'brightness');
            /* Capture only once this is definitely a drag: capturing on
               pointerdown would swallow the click on the centre buttons. */
            if (pad.setPointerCapture) { pad.setPointerCapture(event.pointerId); }
            self.showControls();
        }

        event.preventDefault();

        if (gesture.axis === 'seek') {
            if (!self.video.duration) { return; }
            var delta = (dx / gesture.rect.width) * GESTURE_SEEK_SPAN;
            var target = Math.min(self.video.duration, Math.max(0, gesture.startTime + delta));
            gesture.seekTarget = target;
            self.flashBar('rotateCw',
                AGP.formatClock(target) + ' / ' + AGP.formatClock(self.video.duration) +
                ' (' + (delta >= 0 ? '+' : '-') + Math.round(Math.abs(delta)) + 's)',
                target / self.video.duration, true);
            return;
        }

        /* 70% of the player height is a full sweep — a whole screen height
           makes fine adjustment impossible on a phone. */
        var ratio = -dy / (gesture.rect.height * 0.7);

        if (gesture.axis === 'volume') {
            var applied = self.setVolumeSafe(gesture.startVolume + ratio);
            if (applied === null) {
                self.flashBar('volume', '此裝置需用實體音量鍵調整', 0, true);
                return;
            }
            self.flashBar(applied > 0 ? 'volume' : 'volumeOff',
                '音量 ' + Math.round(applied * 100) + '%', applied, true);
        } else {
            var level = self.setBrightness(gesture.startBrightness + ratio);
            self.flashBar('star', BRIGHTNESS_LABEL + ' ' + Math.round(level * 100) + '%',
                NATIVE ? level : (level - MIN_BRIGHTNESS) / (1 - MIN_BRIGHTNESS), true);
        }
    });

    function finish(event) {
        if (!gesture || event.pointerId !== gesture.id) { return; }
        var settled = gesture;
        gesture = null;
        if (pad.hasPointerCapture && pad.hasPointerCapture(event.pointerId)) {
            pad.releasePointerCapture(event.pointerId);
        }

        if (settled.axis === 'seek' && settled.seekTarget !== null) {
            self.video.currentTime = settled.seekTarget;
        }
        if (settled.axis) {
            self.hideBar();
            self.armIdleTimer();
            return;
        }

        /* A tap that landed on a button is that button's to handle. */
        if (settled.button || settled.passive) { self.armIdleTimer(); return; }

        var now = Date.now();
        if (now - lastTap.time < DOUBLE_TAP_MS && lastTap.zone === settled.zone) {
            /* Keep the stamp: zeroing it made the next tap look like a fresh
               single tap, so a run of taps skipped and hid the bar by turns. */
            lastTap = { time: now, zone: settled.zone };
            self.nudge(settled.zone === 'right' ? SKIP_SECONDS : -SKIP_SECONDS);
            return;
        }
        lastTap = { time: now, zone: settled.zone };

        /* A lone tap toggles the chrome; the centre button plays and pauses.
           The bar only goes away once it has been up for longer than a double
           tap, so a tap can always be trusted to summon it. */
        if (self.menuView) {
            self.closeMenus();
        } else if (self.shell.classList.contains('controls-visible') &&
            now - self.controlsShownAt > DOUBLE_TAP_MS) {
            self.hideControls();
        } else {
            self.showControls();
        }
    }

    /* A cancelled pointer is the browser taking the gesture over -- a page pan,
       an edge swipe, a second finger. Running the tap branch on it is what made
       the chrome blink away mid-scroll on an iPad, so a cancel only drops the
       gesture and leaves the bar where it was. */
    function abort(event) {
        if (!gesture || event.pointerId !== gesture.id) { return; }
        gesture = null;
        if (pad.hasPointerCapture && pad.hasPointerCapture(event.pointerId)) {
            pad.releasePointerCapture(event.pointerId);
        }
        self.hideBar();
        self.armIdleTimer();
    }

    pad.addEventListener('pointerup', finish);
    pad.addEventListener('pointercancel', abort);

    /* The bar's own widgets never reach finish(), so lifting a finger off one
       has to restart the idle countdown itself. */
    var controls = this.shell.querySelector('#playerControls');
    if (controls) {
        ['pointerup', 'pointercancel'].forEach(function (name) {
            controls.addEventListener(name, function () { self.showControls(); });
        });
    }
};

/* The plain HUD is a fading toast; a gesture needs one that stays for as long
   as the finger does and carries a level bar. */
AgpPlayer.prototype.flashBar = function (iconName, label, ratio, sticky) {
    clearTimeout(this.hudTimer);
    this.hud.hidden = false;
    this.hud.classList.add('is-bar');
    this.hud.style.animation = 'none';
    this.hud.innerHTML = AGP.icon(iconName, 20) +
        '<span>' + AGP.escapeHtml(label) + '</span>' +
        '<i class="player-hud-bar"><b style="width:' +
        Math.round(Math.min(1, Math.max(0, ratio)) * 100) + '%"></b></i>';
    if (!sticky) { this.hideBar(); }
};

AgpPlayer.prototype.hideBar = function () {
    var self = this;
    clearTimeout(this.hudTimer);
    this.hudTimer = setTimeout(function () {
        self.hud.hidden = true;
        self.hud.classList.remove('is-bar');
        self.hud.style.animation = '';
    }, 620);
};

/* --- danmaku ------------------------------------------------------------- */

AgpPlayer.prototype.loadDanmaku = async function () {
    if (!this.videoData.danmu) {
        this.onDanmakuLoaded([]);
        return;
    }
    var url = './get_danmu.ass?id=' + encodeURIComponent(this.videoData.sn) + '&t=' + Date.now();
    for (var attempt = 0; attempt < 3; attempt++) {
        try {
            var response = await fetch(url);
            if (!response.ok) { throw new Error('HTTP ' + response.status); }
            var text = await response.text();
            this.danmakuText = text;
            this.mountAss(text);
            this.onDanmakuLoaded(parseDanmakuList(text));
            return;
        } catch (error) {
            if (attempt === 2) {
                console.warn('彈幕載入失敗：', error);
                this.onDanmakuLoaded([]);
            }
        }
    }
};

AgpPlayer.prototype.mountAss = function (text) {
    if (typeof window.ASS !== 'function') { return; }
    try {
        this.ass = new window.ASS(text, this.video, {
            container: this.danmakuLayer,
            resampling: 'video_width'
        });
    } catch (error) {
        console.warn('彈幕渲染失敗：', error);
        this.ass = null;
    }
    this.applyDanmakuStyle();
};

AgpPlayer.prototype.setDanmaku = function (enabled) {
    this.danmakuEnabled = !!enabled;
    writeStore('agp-danmaku', this.danmakuEnabled ? '1' : '0');
    this.applyDanmakuStyle();
    this.syncDanmakuButton();
    this.flash(this.danmakuEnabled ? '彈幕開啟' : '彈幕關閉');
};

AgpPlayer.prototype.syncDanmakuButton = function () {
    var button = this.shell.querySelector('#danmakuToggle');
    if (!button) { return; }
    button.classList.toggle('active', this.danmakuEnabled);
    button.setAttribute('aria-pressed', this.danmakuEnabled ? 'true' : 'false');
};

AgpPlayer.prototype.applyDanmakuStyle = function () {
    this.danmakuLayer.hidden = !this.danmakuEnabled;
    /* Set as a variable, not as opacity: the stylesheet scales it down while
       the chrome is up so the flood does not swallow the controls. */
    this.danmakuLayer.style.setProperty('--danmaku-opacity',
        String(this.danmakuOpacity / 100));
    this.shell.dataset.danmakuArea = this.danmakuArea;
    writeStore('agp-danmaku-opacity', this.danmakuOpacity);
    writeStore('agp-danmaku-area', this.danmakuArea);
};

AgpPlayer.prototype.applyAspect = function () {
    this.shell.classList.remove('aspect-cover', 'aspect-fill');
    if (this.aspectMode !== 'contain') { this.shell.classList.add('aspect-' + this.aspectMode); }
    writeStore('agp-aspect', this.aspectMode);
};

/* --- fullscreen / pip ----------------------------------------------------- */

AgpPlayer.prototype.toggleFullscreen = function () {
    var self = this;
    var element = this.shell;
    if (document.fullscreenElement || document.webkitFullscreenElement) {
        (document.exitFullscreen || document.webkitExitFullscreen).call(document);
        return;
    }
    var request = element.requestFullscreen || element.webkitRequestFullscreen;
    if (request) {
        var result = request.call(element);
        if (result && result.catch) { result.catch(function () { self.flash('無法進入全螢幕'); }); }
    } else if (this.video.webkitEnterFullscreen) {
        /* iPhone Safari never gives an element fullscreen — only the video's
           own native player. Handing it the video is the only path there. */
        this.video.webkitEnterFullscreen();
    } else {
        this.flash('此裝置不支援全螢幕');
    }
};

AgpPlayer.prototype.syncFullscreenButton = function () {
    var active = !!(document.fullscreenElement || document.webkitFullscreenElement);
    var button = this.shell.querySelector('#fullscreenToggle');
    button.innerHTML = AGP.icon(active ? 'compress' : 'expand', 23);
    button.setAttribute('aria-pressed', active ? 'true' : 'false');
    button.setAttribute('aria-label', active ? '離開全螢幕' : '全螢幕');
    this.shell.classList.toggle('is-fullscreen', active);
};

AgpPlayer.prototype.togglePip = async function () {
    if (!document.pictureInPictureEnabled) {
        this.flash('此瀏覽器不支援子母畫面');
        return;
    }
    try {
        if (document.pictureInPictureElement) {
            await document.exitPictureInPicture();
        } else {
            await this.video.requestPictureInPicture();
        }
    } catch (error) {
        this.flash('無法開啟子母畫面');
    }
};

/* --- menus ---------------------------------------------------------------- */

var MENU_TITLES = {
    main: '設定',
    speed: '播放速度',
    brightness: BRIGHTNESS_LABEL,
    danmaku: '彈幕',
    'danmaku-opacity': '彈幕透明度',
    'danmaku-area': '彈幕顯示區域',
    aspect: '畫面比例',
    shortcuts: '鍵盤快速鍵'
};

var MENU_PARENTS = {
    speed: 'main',
    brightness: 'main',
    danmaku: 'main',
    'danmaku-opacity': 'main',
    'danmaku-area': 'main',
    aspect: 'main',
    shortcuts: 'main'
};

AgpPlayer.prototype.toggleSettings = function () {
    if (this.menuView && this.menuView !== 'episodes') {
        this.closeMenus();
    } else {
        this.openSettings('main');
    }
};

AgpPlayer.prototype.openSettings = function (view) {
    this.episodeMenu.hidden = true;
    this.menuView = view;
    this.shell.querySelector('#settingsToggle').classList.add('active');
    this.setMenuExpanded('#settingsToggle', true);
    this.setMenuExpanded('#episodeChip', false);
    /* The shortcut sheet is a two-column grid half again as wide as a settings
       list, and its <kbd> chips are styled per view rather than per menu. */
    this.settingsMenu.className = 'desktop-player-menu ' +
        (view === 'shortcuts' ? 'shortcut-menu' : 'settings-menu');
    this.settingsMenu.hidden = false;
    this.settingsMenu.innerHTML = this.renderMenu(view);
    this.showControls();
    clearTimeout(this.idleTimer);

    var self = this;
    var back = this.settingsMenu.querySelector('.desktop-player-menu-back');
    if (back) {
        back.addEventListener('click', function () { self.openSettings(MENU_PARENTS[view] || 'main'); });
    }
    this.settingsMenu.querySelectorAll('[data-view]').forEach(function (button) {
        button.addEventListener('click', function () { self.openSettings(button.dataset.view); });
    });
    this.settingsMenu.querySelectorAll('[data-set]').forEach(function (button) {
        button.addEventListener('click', function () {
            self.applySetting(button.dataset.set, button.dataset.value);
        });
    });

    /* The menus are emitted before the control bar, so without this the first
       row is nine Shift+Tabs backwards from the gear that opened it. Every
       render tears out the row that was focused, so a sub-view has to catch
       focus too, or it falls through to <body> and the viewer loses the sheet.
       applySetting() still moves it back to the row that was used. */
    var landing = this.settingsMenu.querySelector('button.active') ||
        this.settingsMenu.querySelector('.desktop-player-menu-back') ||
        this.settingsMenu.querySelector('button');
    if (landing) { landing.focus(); }
};

AgpPlayer.prototype.renderMenu = function (view) {
    var self = this;
    var rows = '';

    function row(label, value, attrs) {
        return '<button type="button" ' + attrs + '><span>' + AGP.escapeHtml(label) + '</span>' +
            '<span class="desktop-player-setting-value">' + AGP.escapeHtml(value) +
            AGP.icon('chevronRight', 15) + '</span></button>';
    }

    function choice(label, active, attrs) {
        /* The tick is an icon, and every icon() output is aria-hidden, so the
           chosen row needs to say so itself. */
        return '<button type="button" class="' + (active ? 'active' : '') + '"' +
            (active ? ' aria-current="true"' : '') + ' ' + attrs + '>' +
            '<span>' + AGP.escapeHtml(label) + '</span>' + (active ? AGP.icon('check', 15) : '') + '</button>';
    }

    if (view === 'main') {
        rows += row('播放速度', this.rate === 1 ? '正常' : this.rate + '×', 'data-view="speed"');
        rows += row('彈幕', this.danmakuEnabled ? '開啟' : '關閉', 'data-view="danmaku"');
        rows += row('彈幕透明度', this.danmakuOpacity + '%', 'data-view="danmaku-opacity"');
        rows += row('彈幕顯示區域', (DANMAKU_AREAS.filter(function (area) {
            return area.value === self.danmakuArea;
        })[0] || DANMAKU_AREAS[0]).label, 'data-view="danmaku-area"');
        rows += row('畫面比例', (ASPECT_MODES.filter(function (mode) {
            return mode.key === self.aspectMode;
        })[0] || ASPECT_MODES[0]).label, 'data-view="aspect"');
        rows += row(BRIGHTNESS_LABEL, Math.round(this.brightness * 100) + '%', 'data-view="brightness"');
        rows += row('鍵盤快速鍵', '', 'data-view="shortcuts"');
    } else if (view === 'speed') {
        rows = PLAYBACK_RATES.map(function (rate) {
            return choice(rate === 1 ? '正常' : rate + '×', self.rate === rate,
                'data-set="speed" data-value="' + rate + '"');
        }).join('');
    } else if (view === 'danmaku') {
        rows = [true, false].map(function (on) {
            return choice(on ? '開啟' : '關閉', self.danmakuEnabled === on,
                'data-set="danmaku" data-value="' + (on ? '1' : '0') + '"');
        }).join('');
        if (!this.videoData.danmu) {
            rows += '<p class="desktop-player-menu-note">這一集沒有彈幕檔，開啟後畫面不會有變化。</p>';
        }
    } else if (view === 'danmaku-opacity') {
        rows = DANMAKU_OPACITIES.map(function (value) {
            return choice(value + '%', self.danmakuOpacity === value,
                'data-set="danmaku-opacity" data-value="' + value + '"');
        }).join('');
    } else if (view === 'danmaku-area') {
        rows = DANMAKU_AREAS.map(function (area) {
            return choice(area.label, self.danmakuArea === area.value,
                'data-set="danmaku-area" data-value="' + area.value + '"');
        }).join('');
    } else if (view === 'brightness') {
        rows = BRIGHTNESS_LEVELS.map(function (value) {
            return choice(value + '%', Math.round(self.brightness * 100) === value,
                'data-set="brightness" data-value="' + value + '"');
        }).join('');
        rows += '<p class="desktop-player-menu-note">' + (NATIVE
            ? '這會直接調整裝置的螢幕亮度。'
            : '這會調暗播放畫面本身；瀏覽器無法變更裝置的螢幕亮度。') + '</p>';
    } else if (view === 'aspect') {
        rows = ASPECT_MODES.map(function (mode) {
            return choice(mode.label, self.aspectMode === mode.key,
                'data-set="aspect" data-value="' + mode.key + '"');
        }).join('');
    } else if (view === 'shortcuts') {
        rows = '<dl>' + SHORTCUTS.map(function (item) {
            return '<dt>' + item.keys.map(function (key) {
                return '<kbd>' + AGP.escapeHtml(key) + '</kbd>';
            }).join(' ') + '</dt><dd>' + AGP.escapeHtml(item.label) + '</dd>';
        }).join('') + '</dl>';
    }

    var isRoot = view === 'main';
    return '<header>' +
        (isRoot ? '' : '<button class="desktop-player-menu-back" type="button" aria-label="返回">' +
            AGP.icon('chevronLeft', 17) + '</button>') +
        '<strong>' + AGP.escapeHtml(MENU_TITLES[view] || '設定') + '</strong>' +
        '</header><div>' + rows + '</div>';
};

AgpPlayer.prototype.applySetting = function (key, value) {
    var from = this.menuView;
    switch (key) {
        case 'speed':
            this.rate = Number(value);
            this.video.playbackRate = this.rate;
            writeStore('agp-rate', this.rate);
            this.flash('播放速度 ' + (this.rate === 1 ? '正常' : this.rate + '×'));
            break;
        case 'danmaku':
            this.setDanmaku(value === '1');
            break;
        case 'danmaku-opacity':
            this.danmakuOpacity = Number(value);
            this.applyDanmakuStyle();
            break;
        case 'danmaku-area':
            this.danmakuArea = value;
            this.applyDanmakuStyle();
            break;
        case 'brightness':
            this.setBrightness(Number(value) / 100);
            break;
        case 'aspect':
            this.aspectMode = value;
            this.applyAspect();
            this.flash((ASPECT_MODES.filter(function (mode) { return mode.key === value; })[0] || {}).label || '');
            break;
        default: break;
    }
    this.openSettings(MENU_PARENTS[from] || 'main');
    var resumed = this.settingsMenu.querySelector('[data-view="' + from + '"]');
    if (resumed) { resumed.focus(); }
};

AgpPlayer.prototype.openEpisodeMenu = function () {
    var self = this;
    if (this.menuView === 'episodes') {
        this.closeMenus();
        return;
    }
    this.settingsMenu.hidden = true;
    this.shell.querySelector('#settingsToggle').classList.remove('active');
    this.setMenuExpanded('#settingsToggle', false);
    this.setMenuExpanded('#episodeChip', true);
    this.menuView = 'episodes';
    this.episodeMenu.hidden = false;
    clearTimeout(this.idleTimer);

    var sorted = this.series.slice().sort(function (a, b) { return episodeNumber(a) - episodeNumber(b); });
    this.episodeMenu.innerHTML = '<header><strong>' + AGP.escapeHtml(this.videoData.anime_name) +
        '</strong><span>' + sorted.length + ' 集</span></header><div>' +
        sorted.map(function (video) {
            var current = String(video.sn) === String(self.videoData.sn);
            return '<button type="button" class="' + (current ? 'active' : '') + '"' +
                (current ? ' aria-current="true"' : '') + ' data-sn="' +
                AGP.escapeHtml(video.sn) + '"><time>' + AGP.escapeHtml(episodeLabel(video)) + '</time>' +
                '<span>' + AGP.escapeHtml(video.title || video.anime_name) + '</span>' +
                (current ? AGP.icon('play', 16) : '') + '</button>';
        }).join('') + '</div>';

    this.episodeMenu.querySelectorAll('[data-sn]').forEach(function (button) {
        button.addEventListener('click', function () {
            var target = self.series.filter(function (video) {
                return String(video.sn) === button.dataset.sn;
            })[0];
            if (target) { window.location.href = watchUrl(target); }
        });
    });
    this.showControls();

    var current = this.episodeMenu.querySelector('button.active') ||
        this.episodeMenu.querySelector('button');
    if (current) { current.focus(); }
};

AgpPlayer.prototype.closeMenus = function () {
    var opener = this.menuView === 'episodes' ? '#episodeChip' : '#settingsToggle';
    var wasFocused = this.settingsMenu.contains(document.activeElement) ||
        this.episodeMenu.contains(document.activeElement);
    this.menuView = null;
    this.settingsMenu.hidden = true;
    this.episodeMenu.hidden = true;
    var settingsButton = this.shell.querySelector('#settingsToggle');
    if (settingsButton) { settingsButton.classList.remove('active'); }
    this.setMenuExpanded('#settingsToggle', false);
    this.setMenuExpanded('#episodeChip', false);
    /* Hiding the menu the viewer was standing in would drop focus on the
       document; hand it back to the button that opened it. */
    if (wasFocused) {
        var button = this.shell.querySelector(opener);
        if (button) { button.focus(); }
    }
    this.armIdleTimer();
};

AgpPlayer.prototype.setMenuExpanded = function (selector, open) {
    var button = this.shell.querySelector(selector);
    if (button) { button.setAttribute('aria-expanded', open ? 'true' : 'false'); }
};

/* Inside a menu the arrows walk the rows; left to reach the page shortcuts
   they would change the volume instead. */
AgpPlayer.prototype.wireMenuKeys = function (menu) {
    menu.addEventListener('keydown', function (event) {
        var step = event.key === 'ArrowDown' ? 1 : (event.key === 'ArrowUp' ? -1 : 0);
        if (!step && event.key !== 'Home' && event.key !== 'End') { return; }
        var rows = Array.prototype.slice.call(menu.querySelectorAll('button'));
        if (!rows.length) { return; }
        var index = rows.indexOf(document.activeElement);
        var next;
        if (event.key === 'Home') {
            next = 0;
        } else if (event.key === 'End') {
            next = rows.length - 1;
        } else {
            next = index === -1 ? 0 : (index + step + rows.length) % rows.length;
        }
        rows[next].focus();
        event.preventDefault();
        event.stopPropagation();
    });
};

/* --- episode navigation --------------------------------------------------- */

AgpPlayer.prototype.neighbour = function (direction) {
    var self = this;
    var sorted = this.series.slice().sort(function (a, b) { return episodeNumber(a) - episodeNumber(b); });
    var index = -1;
    sorted.forEach(function (video, i) {
        if (String(video.sn) === String(self.videoData.sn)) { index = i; }
    });
    if (index === -1) { return null; }
    return sorted[index + direction] || null;
};

AgpPlayer.prototype.goRelative = function (direction) {
    var target = this.neighbour(direction);
    if (!target) {
        this.flash(direction > 0 ? '已是最後一集' : '已是第一集');
        return;
    }
    window.location.href = watchUrl(target);
};

AgpPlayer.prototype.offerNextEpisode = function () {
    var self = this;
    var next = this.neighbour(1);
    if (!next) { return; }

    var remaining = NEXT_EPISODE_COUNTDOWN;
    this.nextBox.hidden = false;
    this.nextBox.innerHTML = '<p>即將播放下一集</p><strong>' +
        AGP.escapeHtml(episodeLabel(next) + ' · ' + (next.title || next.anime_name)) + '</strong>' +
        '<div class="player-next-actions">' +
        '<button type="button" class="is-primary" data-next="go">立即播放' +
        (this.autoNext ? ' (' + remaining + ')' : '') + '</button>' +
        '<button type="button" class="is-ghost" data-next="cancel">取消</button></div>';

    var go = this.nextBox.querySelector('[data-next="go"]');
    go.addEventListener('click', function () {
        window.location.href = watchUrl(next);
    });
    this.nextBox.querySelector('[data-next="cancel"]').addEventListener('click', function () {
        self.cancelNextEpisode();
        self.showControls();
        self.shell.querySelector('#playToggle').focus();
    });

    if (!this.autoNext) { return; }

    clearInterval(this.nextTimer);
    this.nextTimer = setInterval(function () {
        remaining -= 1;
        if (remaining <= 0) {
            clearInterval(self.nextTimer);
            window.location.href = watchUrl(next);
            return;
        }
        /* Only the number moves: rebuilding the card every second destroyed
           whichever button the viewer had tabbed onto. */
        go.textContent = '立即播放 (' + remaining + ')';
    }, 1000);
};

AgpPlayer.prototype.cancelNextEpisode = function () {
    clearInterval(this.nextTimer);
    if (this.nextBox) { this.nextBox.hidden = true; }
};

/* --- keyboard ------------------------------------------------------------- */

AgpPlayer.prototype.handleKey = function (event) {
    var target = event.target;
    if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'SELECT' ||
        target.isContentEditable)) {
        return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey) { return; }

    var video = this.video;
    var key = event.key;

    /* Space and Enter belong to whatever the viewer has focused: taking them
       globally left no button on the page pressable with the keyboard. */
    if ((key === ' ' || key === 'Enter') && target && target.closest &&
        target.closest('button, [role="button"], summary, a[href], label')) {
        return;
    }
    /* The keys that scroll a page only drive the player while the player, or
       nothing in particular, holds focus — otherwise the episode grid and the
       rails below it cannot be reached with the normal scroll keys. */
    if (PAGE_SCROLL_KEYS.indexOf(key) !== -1 && target && target !== document.body &&
        !this.shell.contains(target)) {
        return;
    }

    var handled = true;

    switch (key) {
        case ' ':
        case 'k': case 'K': this.toggle(); break;
        case 'ArrowLeft': this.nudge(-5); break;
        case 'ArrowRight': this.nudge(5); break;
        case 'j': case 'J': this.nudge(-SKIP_SECONDS); break;
        case 'l': case 'L': this.nudge(SKIP_SECONDS); break;
        case 'ArrowUp':
            video.volume = Math.min(1, video.volume + 0.05);
            this.flash('音量 ' + Math.round(video.volume * 100) + '%');
            break;
        case 'ArrowDown':
            video.volume = Math.max(0, video.volume - 0.05);
            this.flash('音量 ' + Math.round(video.volume * 100) + '%');
            break;
        case 'm': case 'M': this.toggleMute(); break;
        case 'f': case 'F': this.toggleFullscreen(); break;
        case 'd': case 'D': this.setDanmaku(!this.danmakuEnabled); break;
        case 'i': case 'I': this.togglePip(); break;
        case 'b': case 'B': this.cycleBrightness(); break;
        case '<': case ',': this.stepRate(-1); break;
        case '>': case '.': this.stepRate(1); break;
        case 'Home': video.currentTime = 0; break;
        case 'End': if (video.duration) { video.currentTime = video.duration; } break;
        case '?': this.openSettings('shortcuts'); break;
        case 'Escape': this.closeMenus(); this.cancelNextEpisode(); handled = false; break;
        default: handled = false;
    }

    if (handled) {
        event.preventDefault();
        this.showControls();
    }
};

AgpPlayer.prototype.cycleBrightness = function () {
    var current = Math.round(this.brightness * 100);
    var index = BRIGHTNESS_LEVELS.indexOf(current);
    var next = BRIGHTNESS_LEVELS[(index + 1) % BRIGHTNESS_LEVELS.length];
    this.setBrightness(next / 100);
    this.flash('畫面亮度 ' + next + '%');
};

AgpPlayer.prototype.stepRate = function (direction) {
    var index = PLAYBACK_RATES.indexOf(this.rate);
    if (index === -1) { index = PLAYBACK_RATES.indexOf(1); }
    var next = PLAYBACK_RATES[Math.min(PLAYBACK_RATES.length - 1, Math.max(0, index + direction))];
    this.applySettingRate(next);
};

AgpPlayer.prototype.applySettingRate = function (rate) {
    this.rate = rate;
    this.video.playbackRate = rate;
    writeStore('agp-rate', rate);
    this.flash('播放速度 ' + (rate === 1 ? '正常' : rate + '×'));
};

/* --- page ----------------------------------------------------------------- */

var page = {
    player: null,
    videoData: null,
    series: [],
    danmaku: [],
    times: {}
};

function renderTitleBar(video, series) {
    var host = document.getElementById('watchTitleBar');
    if (!host) { return; }
    var favKey = 'agp-fav-' + AGP.hashString(video.anime_name);
    var favourite = readStore(favKey, '0') === '1';

    host.innerHTML = '<div class="watch-titlebar-main">' +
        '<h1>' + AGP.escapeHtml(video.anime_name) +
        (video.resolution ? '<span class="watch-rating">' + AGP.escapeHtml(video.resolution) + 'P</span>' : '') +
        '</h1>' +
        '<p class="watch-subtitle">' +
        '<span>' + AGP.escapeHtml(episodeLabel(video)) + '</span>' +
        '<span>' + AGP.icon('list', 14) + '共 ' + series.length + ' 集</span>' +
        (video.timestamp ? '<span>' + AGP.icon('clock', 14) +
            AGP.dayLabel(video.timestamp).title + ' ' + AGP.clockOf(video.timestamp) + '</span>' : '') +
        (video.danmu ? '<span>' + AGP.icon('danmaku', 14) + '有彈幕</span>' : '') +
        '</p></div>' +
        '<button class="watch-subscribe' + (favourite ? ' is-on' : '') + '" type="button" id="favButton">' +
        AGP.icon('heart', 15) + '<span>' + (favourite ? '已收藏' : '收藏') + '</span></button>';

    document.getElementById('favButton').addEventListener('click', function () {
        favourite = !favourite;
        writeStore(favKey, favourite ? '1' : '0');
        this.classList.toggle('is-on', favourite);
        this.querySelector('span').textContent = favourite ? '已收藏' : '收藏';
    });
}

function renderEpisodeGrid(video, series, times) {
    var host = document.getElementById('episodeGrid');
    if (!host) { return; }
    var sorted = series.slice().sort(function (a, b) { return episodeNumber(a) - episodeNumber(b); });

    host.innerHTML = '<div class="watch-episodes-head"><h2>選集</h2>' +
        '<span>共 ' + sorted.length + ' 集</span></div>' +
        '<div class="watch-episode-grid">' + sorted.map(function (item) {
            var entry = times[String(item.sn)];
            var classes = ['watch-episode-btn'];
            if (String(item.sn) === String(video.sn)) { classes.push('is-current'); }
            if (entry && (entry.ended || Number(entry.time) > 0)) { classes.push('is-watched'); }
            var label = String(item.episode === undefined || item.episode === null ? '' : item.episode).trim() || '單集';
            return '<a class="' + classes.join(' ') + '" href="' + AGP.escapeHtml(watchUrl(item)) +
                '" title="' + AGP.escapeHtml(item.title || item.anime_name) + '">' +
                AGP.escapeHtml(label) + '</a>';
        }).join('') + '</div>';
}

function renderInfoCard(video, series) {
    var host = document.getElementById('animeInfo');
    if (!host) { return; }
    var newest = series.reduce(function (best, item) {
        return (item.timestamp || 0) > (best.timestamp || 0) ? item : best;
    }, series[0] || video);
    var fileName = String(video.path || '').split(/[\\/]/).pop();

    function field(term, value) {
        return '<div><dt>' + AGP.escapeHtml(term) + '</dt><dd>' + AGP.escapeHtml(value) + '</dd></div>';
    }

    host.innerHTML =
        '<div class="watch-info-cover" style="background:' + AGP.artFor(video.anime_name) + '">' +
        '<span class="agp-card-art-glyph">' + AGP.escapeHtml(AGP.initials(video.anime_name)) + '</span>' +
        thumbImg(video) + '</div>' +
        '<div class="watch-info-body">' +
        '<h2>' + AGP.escapeHtml(video.anime_name) + '</h2>' +
        '<dl class="watch-info-meta">' +
        (newest.timestamp ? field('最後更新', new Date(newest.timestamp * 1000).toLocaleString('zh-TW')) : '') +
        field('來源', video.source || '本機片庫') +
        field('集數', series.length + ' 集，目前為 ' + episodeLabel(video)) +
        (video.resolution ? field('畫質', video.resolution + 'P') : '') +
        field('彈幕', video.danmu ? '支援' : '此集無彈幕檔') +
        (fileName ? field('檔案', fileName) : '') +
        '</dl>' +
        '<div class="watch-tags">' +
        '<span class="watch-tag">' + AGP.escapeHtml(video.source || '本機片庫') + '</span>' +
        (video.resolution ? '<span class="watch-tag">' + AGP.escapeHtml(video.resolution) + 'P</span>' : '') +
        (video.danmu ? '<span class="watch-tag">彈幕</span>' : '') +
        '<span class="watch-tag">' + series.length + ' 集</span>' +
        '</div>' +
        '<p class="watch-info-desc">《' + AGP.escapeHtml(video.anime_name) + '》目前收錄 ' + series.length +
        ' 集，由 aniGamerPlus+ 直接從本機片庫串流播放，無須再次下載。' +
        (video.danmu ? '本集附有彈幕軌，可在播放器右下角的設定中調整透明度與顯示區域。' : '') +
        '</p></div>';
}

function renderDanmakuList(rows) {
    var host = document.getElementById('danmakuList');
    if (!host) { return; }
    if (!rows.length) {
        host.innerHTML = '<p class="watch-side-empty">這一集沒有彈幕。</p>';
        return;
    }
    host.innerHTML = rows.map(function (row, index) {
        /* A popular episode carries thousands of these. One tab stop for the
           whole list, walked with the arrow keys, keeps the library rail below
           the sidebar reachable. */
        return '<button class="danmaku-row" type="button" tabindex="' + (index ? '-1' : '0') +
            '" data-time="' + row.time + '" data-index="' + index + '">' +
            '<time>' + AGP.formatClock(row.time) + '</time><span>' + AGP.escapeHtml(row.text) + '</span></button>';
    }).join('');

    host.addEventListener('click', function (event) {
        var button = event.target.closest('.danmaku-row');
        if (!button || !page.player) { return; }
        page.player.video.currentTime = Number(button.dataset.time);
        page.player.showControls();
    });

    host.addEventListener('keydown', function (event) {
        var step = event.key === 'ArrowDown' ? 1 : (event.key === 'ArrowUp' ? -1 : 0);
        var focused = document.activeElement;
        if (!step || !focused || !focused.classList.contains('danmaku-row')) { return; }
        var all = host.querySelectorAll('.danmaku-row');
        var target = all[Math.min(all.length - 1, Math.max(0, Number(focused.dataset.index) + step))];
        if (!target) { return; }
        focusDanmakuRow(target);
        event.preventDefault();
    });

    var summary = document.getElementById('danmakuCount');
    if (summary) { summary.textContent = rows.length + ' 則'; }
}

/* The list's single tab stop travels: to the row the reader walked to, or to
   the line that is playing while they are elsewhere on the page. */
function setDanmakuTabStop(row) {
    var host = row && row.parentElement;
    if (!host) { return; }
    var current = host.querySelector('.danmaku-row[tabindex="0"]');
    if (current && current !== row) { current.tabIndex = -1; }
    row.tabIndex = 0;
}

function focusDanmakuRow(row) {
    setDanmakuTabStop(row);
    row.focus();
}

/* Keeping the list pinned to playback is the whole point of the panel, but a
   scroll on every timeupdate fights the user — only move when the row changes
   and the panel is the visible one. */
var lastLiveIndex = -1;

function syncDanmakuList(currentTime) {
    var host = document.getElementById('danmakuList');
    if (!host || !host.parentElement.classList.contains('is-active') || !page.danmaku.length) { return; }

    var index = -1;
    for (var i = 0; i < page.danmaku.length; i++) {
        if (page.danmaku[i].time <= currentTime) { index = i; } else { break; }
    }
    if (index === lastLiveIndex) { return; }
    lastLiveIndex = index;

    var previous = host.querySelector('.danmaku-row.is-live');
    if (previous) {
        previous.classList.remove('is-live');
        previous.removeAttribute('aria-current');
    }
    if (index < 0) { return; }
    var row = host.querySelector('[data-index="' + index + '"]');
    if (row) {
        row.classList.add('is-live');
        row.setAttribute('aria-current', 'true');
        if (!host.contains(document.activeElement)) { setDanmakuTabStop(row); }
        /* scrollIntoView() walks up to the document, so following the live
           comment dragged the whole page -- and the player with it -- a few
           lines every second. Scroll the panel's own box, and only when the row
           has actually left it. The list itself is display:contents and has no
           box to measure or to scroll. */
        var scroller = host.closest('.watch-side-panel');
        if (!scroller) { return; }
        var rowBox = row.getBoundingClientRect();
        var box = scroller.getBoundingClientRect();
        /* Land it a line inside the edge, so the comment after this one is
           already on screen. */
        var margin = rowBox.height;
        if (rowBox.top < box.top + margin) {
            scroller.scrollTop += rowBox.top - box.top - margin;
        } else if (rowBox.bottom > box.bottom - margin) {
            scroller.scrollTop += rowBox.bottom - box.bottom + margin;
        }
    }
}

function renderAdvancedPanel(player) {
    var host = document.getElementById('advancedPanel');
    if (!host) { return; }

    host.innerHTML =
        '<div class="watch-setting-row"><label for="setAspect">畫面比例</label>' +
        '<select id="setAspect">' + ASPECT_MODES.map(function (mode) {
            return '<option value="' + mode.key + '"' + (player.aspectMode === mode.key ? ' selected' : '') +
                '>' + mode.label + '</option>';
        }).join('') + '</select></div>' +
        '<div class="watch-setting-row"><label for="setRate">播放速度</label>' +
        '<select id="setRate">' + PLAYBACK_RATES.map(function (rate) {
            return '<option value="' + rate + '"' + (player.rate === rate ? ' selected' : '') +
                '>' + (rate === 1 ? '正常' : rate + '×') + '</option>';
        }).join('') + '</select></div>' +
        '<div class="watch-setting-row"><label for="setDanmakuOpacity">彈幕透明度</label>' +
        '<input id="setDanmakuOpacity" type="range" min="10" max="100" step="5" value="' +
        player.danmakuOpacity + '"><output id="opacityOut">' + player.danmakuOpacity + '%</output></div>' +
        '<div class="watch-setting-row"><label for="setDanmakuArea">彈幕區域</label>' +
        '<select id="setDanmakuArea">' + DANMAKU_AREAS.map(function (area) {
            return '<option value="' + area.value + '"' + (player.danmakuArea === area.value ? ' selected' : '') +
                '>' + area.label + '</option>';
        }).join('') + '</select></div>' +
        '<div class="watch-setting-row"><label for="setBrightness">畫面亮度</label>' +
        '<input id="setBrightness" type="range" min="20" max="100" step="5" value="' +
        Math.round(player.brightness * 100) + '"><output id="brightnessOut">' +
        Math.round(player.brightness * 100) + '%</output></div>' +
        '<div class="watch-setting-row"><label for="setAutoNext">自動播放</label>' +
        '<select id="setAutoNext">' +
        '<option value="1"' + (player.autoNext ? ' selected' : '') + '>播完自動下一集</option>' +
        '<option value="0"' + (player.autoNext ? '' : ' selected') + '>停在片尾</option>' +
        '</select></div>' +
        '<p class="watch-setting-note">設定會保存在這個瀏覽器，下次開啟時自動套用。</p>' +
        '<p class="watch-setting-note">手機手勢：畫面右半邊上下滑動調音量、左半邊上下滑動調畫面亮度、' +
        '左右滑動快轉倒轉，左右兩側連點兩下可跳 10 秒。' +
        '（iOS 的系統音量與螢幕亮度只能由實體按鍵與控制中心變更，網頁無法代勞。）</p>';

    document.getElementById('setAspect').addEventListener('change', function () {
        player.aspectMode = this.value;
        player.applyAspect();
    });
    document.getElementById('setRate').addEventListener('change', function () {
        player.applySettingRate(Number(this.value));
    });
    document.getElementById('setDanmakuOpacity').addEventListener('input', function () {
        player.danmakuOpacity = Number(this.value);
        player.applyDanmakuStyle();
        document.getElementById('opacityOut').textContent = this.value + '%';
    });
    document.getElementById('setDanmakuArea').addEventListener('change', function () {
        player.danmakuArea = this.value;
        player.applyDanmakuStyle();
    });
    document.getElementById('setBrightness').addEventListener('input', function () {
        player.setBrightness(Number(this.value) / 100);
        document.getElementById('brightnessOut').textContent = this.value + '%';
    });
    document.getElementById('setAutoNext').addEventListener('change', function () {
        player.autoNext = this.value === '1';
        writeStore('agp-auto-next', player.autoNext ? '1' : '0');
    });
}

function wireSideTabs() {
    var tabs = document.querySelectorAll('.watch-side-tab');
    tabs.forEach(function (tab) {
        tab.addEventListener('click', function () {
            tabs.forEach(function (other) {
                other.classList.toggle('is-active', other === tab);
                other.setAttribute('aria-selected', other === tab ? 'true' : 'false');
            });
            document.querySelectorAll('.watch-side-panel').forEach(function (panel) {
                panel.classList.toggle('is-active', panel.id === tab.dataset.panel);
            });
            lastLiveIndex = -1;
        });
    });
}

function renderLibrary(videos, times, currentSn) {
    var host = document.getElementById('watchLibrary');
    if (!host) { return; }

    var recent = videos.slice().sort(function (a, b) {
        return (b.timestamp || 0) - (a.timestamp || 0);
    }).filter(function (video) { return String(video.sn) !== String(currentSn); }).slice(0, 18);

    if (!recent.length) {
        host.innerHTML = '';
        return;
    }

    var cards = recent.map(function (video) {
        var entry = times[String(video.sn)];
        var ratio = 0;
        if (entry && !entry.ended && Number(entry.time) > 0) {
            var total = Number(entry.duration) || 24 * 60;
            ratio = Math.min(0.98, Number(entry.time) / total);
        }
        return '<a class="agp-card" href="' + AGP.escapeHtml(watchUrl(video)) + '">' +
            '<span class="agp-card-art" style="background:' + AGP.artFor(video.anime_name) + '">' +
            '<span class="agp-card-art-glyph">' + AGP.escapeHtml(AGP.initials(video.anime_name)) + '</span>' +
            thumbImg(video) +
            '<span class="agp-card-ep">' + AGP.escapeHtml(episodeLabel(video)) + '</span>' +
            (video.timestamp ? '<span class="agp-card-badge">' + AGP.escapeHtml(AGP.clockOf(video.timestamp)) +
                '</span>' : '') +
            (ratio ? '<span class="agp-card-progress"><i style="width:' + (ratio * 100).toFixed(1) +
                '%"></i></span>' : '') +
            '</span>' +
            '<span class="agp-card-title">' + AGP.escapeHtml(video.anime_name) + '</span>' +
            '<span class="agp-card-meta"><span>' + AGP.escapeHtml(video.source || '本機片庫') + '</span></span>' +
            '</a>';
    }).join('');

    host.innerHTML = '<div class="agp-section-head"><h2>片庫最新更新</h2>' +
        '<a class="agp-section-more" href="./">回首頁 ' + AGP.icon('chevronRight', 13) + '</a></div>' +
        '<div class="agp-rail-wrap">' +
        '<button class="agp-rail-nav" data-dir="prev" type="button" aria-label="上一頁">' +
        AGP.icon('chevronLeft', 18) + '</button>' +
        '<div class="agp-rail">' + cards + '</div>' +
        '<button class="agp-rail-nav" data-dir="next" type="button" aria-label="下一頁">' +
        AGP.icon('chevronRight', 18) + '</button></div>';

    host.querySelectorAll('.agp-rail-wrap').forEach(AGP.wireRail);
}

function showFatal(message) {
    var shell = document.getElementById('playerShell');
    if (shell) {
        shell.classList.remove('is-custom-player');
        shell.innerHTML = '<p class="agp-empty" style="margin:0;border:0">' + AGP.escapeHtml(message) + '</p>';
    }
}

async function main() {
    var params = new URLSearchParams(window.location.search);
    var sn = params.get('id');

    wireSideTabs();

    var list = await getVideoList();
    var videos = Array.isArray(list.videos) ? list.videos : [];
    var times = await getAllTimes();
    page.times = times;

    if (!sn) {
        /* No episode asked for: land on the newest thing in the library rather
           than an empty player. */
        var newest = videos.slice().sort(function (a, b) {
            return (b.timestamp || 0) - (a.timestamp || 0);
        })[0];
        if (newest) {
            window.location.replace(watchUrl(newest));
            return;
        }
        showFatal('片庫是空的，請先到主控台加入追番清單。');
        renderLibrary(videos, times, null);
        return;
    }

    var video = await fetchVideoData(sn);
    if (!video) {
        showFatal('找不到這一集影片，它可能已從片庫移除。');
        renderLibrary(videos, times, sn);
        return;
    }

    var series = await getVideoSeries(video);
    page.videoData = video;
    page.series = series;

    document.title = video.anime_name + ' ' + episodeLabel(video) + ' - aniGamerPlus+';

    renderTitleBar(video, series);
    renderEpisodeGrid(video, series, times);
    renderInfoCard(video, series);
    renderLibrary(videos, times, sn);

    var shell = document.getElementById('playerShell');
    page.player = new AgpPlayer(shell, {
        videoData: video,
        series: series,
        onTimeUpdate: function (currentTime) { syncDanmakuList(currentTime); },
        onDanmakuLoaded: function (rows) {
            page.danmaku = rows;
            renderDanmakuList(rows);
        }
    });

    renderAdvancedPanel(page.player);

    var resume = await getTime(sn);
    if (resume > 5) {
        page.player.video.currentTime = resume;
        page.player.flash('已從 ' + AGP.formatClock(resume) + ' 繼續播放');
    }
}

document.addEventListener('DOMContentLoaded', main);
