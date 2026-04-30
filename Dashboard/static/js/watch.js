// Helper Functions
const dashboardApi = window.dashboardApi || {};

function fallbackParseCookie() {
    var cookieObj = {};
    var cookieAry = document.cookie.split(';');
    var cookie;

    for (var i = 0, l = cookieAry.length; i < l; ++i) {
        cookie = jQuery.trim(cookieAry[i]);
        cookie = cookie.split('=');
        cookieObj[cookie[0]] = cookie[1];
    }

    return cookieObj;
}

function getCookieByName(name) {
    if (dashboardApi.getCookieByName) {
        return dashboardApi.getCookieByName(name);
    }
    var value = fallbackParseCookie()[name];
    if (value) {
        value = decodeURIComponent(value);
    }
    return value;
}

function isLoggedIn() {
    if (dashboardApi.isLoggedIn) {
        return dashboardApi.isLoggedIn();
    }
    return getCookieByName('logined') == 'true';
}

function getWatchBootstrap() {
    var bootstrapElement;
    var bootstrap = window.__AGP_WATCH_BOOTSTRAP__;
    if (bootstrap && typeof bootstrap === 'object') {
        return bootstrap;
    }

    bootstrapElement = document.getElementById('agp-watch-bootstrap');
    if (bootstrapElement) {
        try {
            bootstrap = JSON.parse(bootstrapElement.textContent || '{}');
            window.__AGP_WATCH_BOOTSTRAP__ = bootstrap;
            return bootstrap;
        } catch (error) {
            console.warn('Failed to parse watch bootstrap:', error);
        }
    }

    return {};
}

function getBootstrappedVideoData(sn) {
    var bootstrap = getWatchBootstrap();
    var videoData = bootstrap.initialVideoData;
    if (videoData && String(videoData.sn) === String(sn)) {
        return videoData;
    }
    return null;
}

function getBootstrappedSeries(sn) {
    var bootstrap = getWatchBootstrap();
    if (getBootstrappedVideoData(sn) && Array.isArray(bootstrap.initialVideoSeries) && bootstrap.initialVideoSeries.length > 0) {
        return bootstrap.initialVideoSeries;
    }
    return [];
}

function getBootstrappedResumeTime(sn) {
    var bootstrap = getWatchBootstrap();
    if (String(bootstrap.requestedVideoId || '') !== String(sn)) {
        return null;
    }
    var resumeTime = Number(bootstrap.resumeTime);
    return Number.isFinite(resumeTime) ? resumeTime : null;
}

function setWatchStatusChip(text) {
    var statusChip = document.getElementById('watchStatusChip');
    if (statusChip) {
        statusChip.textContent = text;
    }
}

async function getTime(sn) {
    var bootstrappedResumeTime = getBootstrappedResumeTime(sn);
    if (bootstrappedResumeTime !== null) {
        return bootstrappedResumeTime;
    }

    if (isLoggedIn()) {
        let res = await fetch('./watch/time?sn=' + sn + '&type=get');
        let data = await res.json();
        if (data.time) {
            if (data.ended) {
                return 0;
            }
            return data.time;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}

async function getAllTimes() {
    if (isLoggedIn()) {
        let res = await fetch('./watch/time?type=get');
        let data = await res.json();
        return data;
    } else {
        return {};
    }
}

let lastSetTime = 0;
async function setTime(sn, time, ended, force = false) {
    let currentTime = new Date().getTime();
    if (!force) {
        if (currentTime - lastSetTime < 10000) {
            return;
        }
    }
    lastSetTime = currentTime;
    if (isLoggedIn()) {
        if (ended) {
            await fetch('./watch/time?sn=' + sn + '&type=set&time=0&ended=true');
            return;
        } else {
            await fetch('./watch/time?sn=' + sn + '&type=set&time=' + time);
            return;
        }
    }
    return 0;
}

let videoList = null;

async function getVideoList() {
    try {
        if (videoList) {
            return videoList;
        }
        let response = await fetch('./video_list.json');
        let data = await response.json();
        videoList = data;
        return data;
    } catch (error) {
        console.error("發生錯誤：", error);
        alert("無法載入影片清單！");
        return {};
    }
}

async function fetchVideoData(sn) {
    let bootstrappedVideo = getBootstrappedVideoData(sn);
    if (bootstrappedVideo) {
        return bootstrappedVideo;
    }

    let vl = await getVideoList();
    let videolist = Array.isArray(vl.videos) ? vl.videos : [];
    let videodata = videolist.find(value => value.sn == sn);

    if (!videodata) {
        alert("影片不存在！");
        history.back();
        return;
    }
    return videodata;
}

async function getVideoSeries(sn) {
    let bootstrappedSeries = getBootstrappedSeries(sn);
    if (bootstrappedSeries.length > 0) {
        return bootstrappedSeries;
    }

    let vd = await fetchVideoData(sn);
    if (!vd) {
        return [];
    }
    let fullList = await getVideoList();
    let series = (fullList.videos || []).filter(value => value.anime_name == vd.anime_name);
    return series;
}

function convertTime(duration) {
    if (!Number.isFinite(duration) || duration < 0) {
        return '00:00';
    }
    const h = Math.floor(duration / 60);
    const m = Math.round(duration % 60);
    const result = `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}`;
    return result;
}

function isMobileDevice() {
    return /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
}

// Video Player Class
class VideoPlayer {
    constructor(containerId, videoData, videoSeries) {
        this.container = document.getElementById(containerId);
        this.videoData = videoData;
        this.videoSeries = videoSeries;
        this.video = null;
        this.controls = null;
        this.ass = null;
        this.danmuEnabled = getCookieByName("disableDanmu") == "true" ? false : true;
        this.isFullscreen = false;
        this.controlsTimeout = null;
        this.speeds = [0.25, 0.5, 1, 1.25, 1.5, 2];
        this.aspectModes = [
            { key: 'contain', label: '原始比例' },
            { key: 'cover', label: '裁切填滿' },
            { key: 'fill', label: '完整填滿' }
        ];
        this.centerIconResetTimer = null;
        this.currentAspectMode = 'contain';

        this.init();
    }

    async init() {
        this.container.innerHTML = ''; // Clear container

        // Create Video Element
        this.video = document.createElement('video');
        this.video.id = 'player';
        this.video.autoplay = true;
        this.video.controls = false;
        this.video.preload = 'metadata';
        this.video.src = './get_video.mp4?id=' + encodeURIComponent(this.videoData.sn) + '&res=' + this.videoData.resolution;
        this.video.style.objectFit = this.currentAspectMode;
        this.container.appendChild(this.video);

        // Create UI Elements
        this.createOverlay();
        this.createControls();
        this.createEndBox();

        // Initialize Danmu
        if (this.videoData.danmu) {
            this.initDanmu();
        }

        // Event Listeners
        this.attachEvents();

        // Restore Time
        const webTime = await getTime(this.videoData.sn);
        this.video.currentTime = webTime;

        // Show controls initially
        this.showControls();

        // If autoplay is blocked or paused, show play button
        if (this.video.paused) {
            this.showCenterIcon(this.getIcon('play'), false);
            this.centerIcon.style.opacity = '1';
            this.playBtn.innerHTML = this.getIcon('play');
        }
    }

    createOverlay() {
        // Loading Spinner
        this.loadingSpinner = document.createElement('div');
        this.loadingSpinner.id = 'loading-spinner';
        this.container.appendChild(this.loadingSpinner);

        // Center Play/Pause Animation
        this.centerOverlay = document.createElement('div');
        this.centerOverlay.className = 'center-overlay';
        this.centerIcon = document.createElement('div');
        this.centerIcon.className = 'center-icon';
        this.centerOverlay.appendChild(this.centerIcon);
        if (isMobileDevice()) {
            this.centerOverlay.classList.add('mobile-center-overlay');
        }
        this.container.appendChild(this.centerOverlay);

        // ASS Container
        this.assContainer = document.createElement('div');
        this.assContainer.id = 'ass-container';
        this.container.appendChild(this.assContainer);
    }

    createControls() {
        this.controls = document.createElement('div');
        this.controls.id = 'controls';

        // Time Slider Row
        const timeRow = document.createElement('div');
        timeRow.className = 'time-control';

        this.timeSlider = document.createElement('input');
        this.timeSlider.type = 'range';
        this.timeSlider.id = 'timeSlider';
        this.timeSlider.min = 0;
        this.timeSlider.value = 0;

        this.timeText = document.createElement('span');
        this.timeText.className = 'time-text';
        this.timeText.innerText = '00:00 / 00:00';

        timeRow.appendChild(this.timeSlider);
        timeRow.appendChild(this.timeText);
        this.controls.appendChild(timeRow);

        // Buttons Row
        const btnRow = document.createElement('div');
        btnRow.className = 'controls-row';

        // Left Controls
        const leftControls = document.createElement('div');
        leftControls.className = 'controls-left';

        this.playBtn = this.createButton('playPauseButton', this.getIcon('pause'));
        leftControls.appendChild(this.playBtn);

        if (!isMobileDevice()) {
            const volContainer = document.createElement('div');
            volContainer.className = 'volume-container';
            this.volSlider = document.createElement('input');
            this.volSlider.type = 'range';
            this.volSlider.id = 'volumeSlider';
            this.volSlider.min = 0;
            this.volSlider.max = 1;
            this.volSlider.step = 0.01;
            this.volSlider.value = 1;
            volContainer.appendChild(this.volSlider);
            leftControls.appendChild(volContainer);
        }

        btnRow.appendChild(leftControls);

        // Right Controls
        const rightControls = document.createElement('div');
        rightControls.className = 'controls-right';

        if (this.videoData.danmu) {
            this.danmuBtn = this.createButton('danmuButton', this.getIcon('danmuOn'));
            rightControls.appendChild(this.danmuBtn);
        }

        this.speedBtn = this.createButton('playrateButton', this.getIcon('speed'));
        rightControls.appendChild(this.speedBtn);

        this.fullscreenBtn = this.createButton('fullscreenButton', this.getIcon('fullscreen'));
        rightControls.appendChild(this.fullscreenBtn);

        btnRow.appendChild(rightControls);
        this.controls.appendChild(btnRow);

        // Settings Menu (Speed)
        this.createSettingsMenu();

        this.container.appendChild(this.controls);
    }

    createButton(id, svgContent) {
        const btn = document.createElement('button');
        btn.id = id;
        btn.className = 'control-btn';
        btn.innerHTML = svgContent;
        return btn;
    }

    createSettingsMenu() {
        this.settingsMenu = document.createElement('div');
        this.settingsMenu.className = 'settings-menu';

        const speedTitle = document.createElement('div');
        speedTitle.className = 'settings-group-title';
        speedTitle.innerText = '播放速度';
        this.settingsMenu.appendChild(speedTitle);

        this.speeds.forEach(speed => {
            const item = document.createElement('div');
            item.className = 'settings-item';
            item.dataset.type = 'speed';
            item.dataset.value = speed;
            item.innerText = speed + 'x';
            item.onclick = () => {
                this.applyPlaybackRate(speed);
                this.settingsMenu.classList.remove('active');
            };
            this.settingsMenu.appendChild(item);
        });

        const aspectTitle = document.createElement('div');
        aspectTitle.className = 'settings-group-title';
        aspectTitle.innerText = '畫面比例';
        this.settingsMenu.appendChild(aspectTitle);

        this.aspectModes.forEach(mode => {
            const item = document.createElement('div');
            item.className = 'settings-item';
            item.dataset.type = 'aspect';
            item.dataset.value = mode.key;
            item.innerText = mode.label;
            item.onclick = () => {
                this.applyAspectMode(mode.key);
                this.settingsMenu.classList.remove('active');
            };
            this.settingsMenu.appendChild(item);
        });

        this.applyPlaybackRate(1);
        this.applyAspectMode(this.currentAspectMode);
        this.container.appendChild(this.settingsMenu);
    }

    createEndBox() {
        this.endBox = document.createElement('div');
        this.endBox.id = 'endBox';

        this.endText = document.createElement('h2');
        this.endBox.appendChild(this.endText);

        const btnContainer = document.createElement('div');
        btnContainer.className = 'end-buttons';

        this.cancelBtn = document.createElement('button');
        this.cancelBtn.className = 'end-btn secondary';
        this.cancelBtn.innerText = '取消';

        this.nextBtn = document.createElement('button');
        this.nextBtn.className = 'end-btn primary';
        this.nextBtn.innerText = '下一集';

        btnContainer.appendChild(this.cancelBtn);
        btnContainer.appendChild(this.nextBtn);
        this.endBox.appendChild(btnContainer);

        this.container.appendChild(this.endBox);
    }

    initDanmu() {
        const subtitleSrc = './get_danmu.ass?id=' + encodeURIComponent(this.videoData.sn) + "&t=" + new Date().getTime();
        fetch(subtitleSrc)
            .then(res => res.text())
            .then((text) => {
                this.ass = new ASS(text, this.video, {
                    container: this.assContainer,
                    resampling: 'video_width',
                });
                if (this.danmuEnabled) {
                    this.ass.show();
                } else {
                    this.ass.hide();
                }
            })
            .catch((error) => {
                console.warn('Danmu load failed:', error);
                if (this.danmuBtn) {
                    this.danmuBtn.style.display = 'none';
                }
            });
    }

    attachEvents() {
        // Video Events
        this.video.addEventListener('play', () => this.onPlay());
        this.video.addEventListener('pause', () => this.onPause());
        this.video.addEventListener('timeupdate', () => this.onTimeUpdate());
        this.video.addEventListener('loadedmetadata', () => this.onLoadedMetadata());
        this.video.addEventListener('waiting', () => {
            this.loadingSpinner.style.display = 'block';
            setWatchStatusChip('緩衝中');
        });
        this.video.addEventListener('playing', () => {
            this.loadingSpinner.style.display = 'none';
            setWatchStatusChip('正在播放');
        });
        this.video.addEventListener('canplay', () => {
            this.loadingSpinner.style.display = 'none';
            if (!this.video.paused) {
                setWatchStatusChip('正在播放');
            }
        });
        this.video.addEventListener('ended', () => this.onEnded());
        document.addEventListener('fullscreenchange', () => this.syncFullscreenState());
        if (!isMobileDevice()) {
            this.video.addEventListener('click', () => this.togglePlay());
        }

        // Control Events
        this.playBtn.addEventListener('click', (e) => { e.stopPropagation(); this.togglePlay(); });
        this.fullscreenBtn.addEventListener('click', (e) => { e.stopPropagation(); this.toggleFullscreen(); });
        this.speedBtn.addEventListener('click', (e) => { e.stopPropagation(); this.toggleSettings(); });

        if (this.danmuBtn) {
            this.danmuBtn.addEventListener('click', (e) => { e.stopPropagation(); this.toggleDanmu(); });
        }

        this.timeSlider.addEventListener('input', () => {
            this.video.currentTime = this.timeSlider.value;
            this.updateTimeText();
        });

        if (this.volSlider) {
            this.volSlider.addEventListener('input', () => {
                this.video.volume = this.volSlider.value;
            });
        }

        if (isMobileDevice()) {
            this.centerIcon.addEventListener('click', (e) => { e.stopPropagation(); this.togglePlay(); });
        }

        // Mouse/Touch Interaction for Controls Visibility
        this.container.addEventListener('mousemove', () => this.showControls());
        this.container.addEventListener('mouseleave', () => this.hideControls());
        this.container.addEventListener('touchstart', (e) => { e.stopPropagation(); this.toggleControls(); });

        // Double Tap Handling
        let lastTap = 0;
        this.container.addEventListener('touchend', (e) => {
            const currentTime = new Date().getTime();
            const tapLength = currentTime - lastTap;
            if (tapLength < 300 && tapLength > 0) {
                this.handleDoubleTap(e);
            }
            lastTap = currentTime;
        });

        // Keyboard Shortcuts
        document.addEventListener('keydown', (e) => this.handleKeydown(e));

        // Before Unload
        window.addEventListener('beforeunload', () => {
            const data = JSON.stringify({
                type: 'set',
                sn: this.videoData.sn,
                time: this.video.currentTime,
                ended: this.video.ended
            });
            const blob = new Blob([data], { type: 'application/json' });
            navigator.sendBeacon('./watch/time', blob);
        });
    }

    togglePlay() {
        if (this.video.paused) {
            this.video.play();
            if (!isMobileDevice()) {
                this.showCenterIcon(this.getIcon('play'), true);
            }
        } else {
            this.video.pause();
            if (!isMobileDevice()) {
                this.showCenterIcon(this.getIcon('pause'), true);
            }
        }
    }

    onPlay() {
        clearTimeout(this.centerIconResetTimer);
        this.playBtn.innerHTML = this.getIcon('pause');
        this.showControls();
        this.centerIcon.style.opacity = '0';
        setWatchStatusChip('正在播放');
        if (isMobileDevice()) {
            this.showCenterIcon(this.getIcon('pause'), false);
            this.centerIcon.style.opacity = '1';
        }
    }

    onPause() {
        clearTimeout(this.centerIconResetTimer);
        this.playBtn.innerHTML = this.getIcon('play');
        this.showControls();
        setTime(this.videoData.sn, this.video.currentTime, false, true);
        setWatchStatusChip('已暫停');
        if (isMobileDevice()) {
            this.showCenterIcon(this.getIcon('play'), false);
            this.centerIcon.style.opacity = '1';
        }
    }

    onTimeUpdate() {
        this.timeSlider.value = this.video.currentTime;
        this.updateTimeText();
        setTime(this.videoData.sn, this.video.currentTime, false);
    }

    onLoadedMetadata() {
        this.timeSlider.max = this.video.duration;
        this.updateTimeText();
    }

    onEnded() {
        setTime(this.videoData.sn, 0, true, true);
        setWatchStatusChip('播放完成');
        this.showEndScreen();
    }

    updateTimeText() {
        const current = convertTime(this.video.currentTime);
        const total = convertTime(this.video.duration);
        this.timeText.innerText = `${current} / ${total}`;
    }

    showControls() {
        this.container.classList.add('show-controls');
        clearTimeout(this.controlsTimeout);
        this.controlsTimeout = setTimeout(() => this.hideControls(), 3000);
        this.container.style.cursor = 'auto';
        if (isMobileDevice()) {
            this.centerIcon.style.opacity = '1';
        }
    }

    hideControls() {
        if (!this.video.paused) {
            this.container.classList.remove('show-controls');
            this.container.style.cursor = 'none';
            this.settingsMenu.classList.remove('active');
            if (isMobileDevice()) {
                this.centerIcon.style.opacity = '0';
            }
        }
    }

    toggleControls() {
        if (this.container.classList.contains('show-controls')) {
            this.hideControls();
        } else {
            this.showControls();
        }
    }

    toggleFullscreen() {
        if (!document.fullscreenElement) {
            this.container.requestFullscreen().catch(err => {
                console.log(`Error attempting to enable full-screen mode: ${err.message} (${err.name})`);
            });
            try { screen.orientation.lock("landscape-primary"); } catch (e) { }
        } else {
            document.exitFullscreen().catch(() => { });
            try { screen.orientation.unlock(); } catch (e) { }
        }
    }

    syncFullscreenState() {
        this.isFullscreen = document.fullscreenElement === this.container;
        this.container.classList.toggle('fullscreen', this.isFullscreen);
        this.fullscreenBtn.innerHTML = this.getIcon(this.isFullscreen ? 'fullscreenExit' : 'fullscreen');
        this.applyAspectMode(this.currentAspectMode, false);
        if (this.ass) {
            if (this.danmuEnabled) {
                this.ass.show();
            } else {
                this.ass.hide();
            }
        }
    }

    applyPlaybackRate(speed) {
        this.video.playbackRate = speed;
        this.settingsMenu.querySelectorAll('[data-type="speed"]').forEach(item => {
            item.classList.toggle('active', Number(item.dataset.value) === Number(speed));
        });
    }

    applyAspectMode(mode, refreshSubtitle = true) {
        this.currentAspectMode = mode;
        if (this.video) {
            this.video.style.objectFit = mode;
        }
        if (this.settingsMenu) {
            this.settingsMenu.querySelectorAll('[data-type="aspect"]').forEach(item => {
                item.classList.toggle('active', item.dataset.value === mode);
            });
        }
        if (refreshSubtitle && this.ass) {
            if (this.danmuEnabled) {
                this.ass.show();
            } else {
                this.ass.hide();
            }
        }
    }

    toggleSettings() {
        this.settingsMenu.classList.toggle('active');
    }

    toggleDanmu() {
        if (!this.ass) {
            this.danmuEnabled = !this.danmuEnabled;
            if (this.danmuBtn) {
                this.danmuBtn.style.opacity = this.danmuEnabled ? '1' : '0.5';
            }
            document.cookie = 'disableDanmu=' + (!this.danmuEnabled) + '; path=/; expires=' + new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toUTCString();
            return;
        }

        if (this.danmuEnabled) {
            this.ass.hide();
            this.danmuEnabled = false;
            this.danmuBtn.style.opacity = '0.5';
            document.cookie = "disableDanmu=true; path=/; expires=" + new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toUTCString();
        } else {
            this.ass.show();
            this.danmuEnabled = true;
            this.danmuBtn.style.opacity = '1';
            document.cookie = "disableDanmu=false; path=/; expires=" + new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toUTCString();
        }
    }

    handleDoubleTap(e) {
        const touchX = e.changedTouches[0].clientX;
        const width = window.innerWidth;

        if (touchX < width / 3) {
            this.video.currentTime -= 10;
            this.showCenterIcon(this.getIcon('rewind'), true, true);
        } else if (touchX > width * 2 / 3) {
            this.video.currentTime += 10;
            this.showCenterIcon(this.getIcon('forward'), true, true);
        } else {
            this.togglePlay();
        }
    }

    showCenterIcon(svg, animate, restoreState = false) {
        clearTimeout(this.centerIconResetTimer);
        this.centerIcon.innerHTML = svg;
        this.centerIcon.style.opacity = '1';
        if (animate) {
            this.centerIcon.classList.remove('animate');
            void this.centerIcon.offsetWidth; // Trigger reflow
            this.centerIcon.classList.add('animate');
            this.centerIconResetTimer = setTimeout(() => {
                if (restoreState) {
                    this.centerIcon.innerHTML = this.getIcon(this.video.paused ? 'play' : 'pause');
                    this.centerIcon.classList.remove('animate');
                    if (!isMobileDevice() && !this.video.paused) {
                        this.centerIcon.style.opacity = '0';
                    }
                    return;
                }
                this.centerIcon.style.opacity = '0';
                this.centerIcon.classList.remove('animate');
            }, 500);
        }
    }

    handleKeydown(e) {
        var activeTag = document.activeElement ? document.activeElement.tagName : '';
        if (activeTag === 'INPUT' || activeTag === 'TEXTAREA') {
            return;
        }

        if ([' ', 'k', 'f', 'ArrowLeft', 'ArrowRight'].includes(e.key)) {
            e.preventDefault();
        }

        switch (e.key) {
            case ' ':
            case 'k':
                this.togglePlay();
                break;
            case 'f':
                this.toggleFullscreen();
                break;
            case 'ArrowLeft':
                this.video.currentTime -= 5;
                this.showCenterIcon(this.getIcon('rewind'), true, true);
                break;
            case 'ArrowRight':
                this.video.currentTime += 5;
                this.showCenterIcon(this.getIcon('forward'), true, true);
                break;
        }
    }

    showEndScreen() {
        const nextEpisode = (Number(this.videoData.episode) + 1).toString();
        const nextObj = this.videoSeries.find(value => value.episode == nextEpisode);

        this.endBox.style.display = 'block';

        if (nextObj) {
            this.endText.innerText = "5秒後自動播放下一集";
            this.nextBtn.style.display = 'block';
            this.nextBtn.onclick = () => {
                window.location.href = "./watch?id=" + nextObj.sn + "&res=" + nextObj.resolution;
            };

            let countdown = 5;
            const interval = setInterval(() => {
                countdown--;
                this.endText.innerText = `${countdown}秒後自動播放下一集`;
                if (countdown <= 0) {
                    clearInterval(interval);
                    window.location.href = "./watch?id=" + nextObj.sn + "&res=" + nextObj.resolution;
                }
            }, 1000);

            this.cancelBtn.onclick = () => {
                clearInterval(interval);
                this.endBox.style.display = 'none';
            };
        } else {
            this.endText.innerText = "您已播放至最後一集";
            this.nextBtn.style.display = 'none';
            this.cancelBtn.innerText = "關閉";
            this.cancelBtn.onclick = () => this.endBox.style.display = 'none';
        }
    }

    getIcon(name) {
        const icons = {
            play: '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>',
            pause: '<svg viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>',
            fullscreen: '<svg viewBox="0 0 24 24"><path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/></svg>',
            fullscreenExit: '<svg viewBox="0 0 24 24"><path d="M5 16h2v3h3v2H5v-5zm12 3v-3h2v5h-5v-2h3zM7 5v3H5V3h5v2H7zm12 3V5h-3V3h5v5h-2z"/></svg>',
            speed: '<svg viewBox="0 0 24 24"><path d="M20.38 8.57l-1.23 1.85a8 8 0 0 1-.22 7.58H5.07A8 8 0 0 1 15.58 6.85l1.85-1.23A10 10 0 0 0 3.35 19a2 2 0 0 0 1.72 1h13.85a2 2 0 0 0 1.74-1 10 10 0 0 0-.27-10.44zm-9.79 6.84a2 2 0 0 0 2.83 0l5.66-8.49-8.49 5.66a2 2 0 0 0 0 2.83z"/></svg>',
            danmuOn: '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H5.17L4 17.17V4h16v12z"/></svg>',
            rewind: '<svg viewBox="0 0 24 24"><path d="M11 18V6l-8.5 6 8.5 6zm.5-6l8.5 6V6l-8.5 6z"/></svg>',
            forward: '<svg viewBox="0 0 24 24"><path d="M4 18l8.5-6L4 6v12zm9-12v12l8.5-6L13 6z"/></svg>'
        };
        return icons[name] || '';
    }
}

function getWatchUserLabel() {
    var currentUser = dashboardApi.getCurrentUserSnapshot ? dashboardApi.getCurrentUserSnapshot() : null;
    if (currentUser && currentUser.username) {
        if (currentUser.role === 'admin') {
            return currentUser.username + ' / admin';
        }
        return currentUser.username;
    }
    return isLoggedIn() ? '已登入使用者' : '訪客模式';
}

function createMetaCard(label, value, link) {
    var item = document.createElement('div');
    item.className = 'watch-meta-card';

    var labelNode = document.createElement('span');
    labelNode.className = 'watch-meta-label';
    labelNode.textContent = label;
    item.appendChild(labelNode);

    if (link) {
        var anchor = document.createElement('a');
        anchor.className = 'watch-meta-value watch-meta-link';
        anchor.href = link.href;
        anchor.target = '_blank';
        anchor.rel = 'noreferrer';
        anchor.textContent = link.text;
        item.appendChild(anchor);
    } else {
        var valueNode = document.createElement('strong');
        valueNode.className = 'watch-meta-value';
        valueNode.textContent = value;
        item.appendChild(valueNode);
    }

    return item;
}

function renderWatchMeta(videoData, videoSeries) {
    var metaPanel = document.getElementById('video-meta-panel');
    if (!metaPanel || !videoData) {
        return;
    }

    metaPanel.classList.remove('watch-panel--hidden');
    metaPanel.innerHTML = '';

    var panelHeader = document.createElement('div');
    panelHeader.className = 'watch-panel-header';

    var titleGroup = document.createElement('div');
    var title = document.createElement('h2');
    title.textContent = videoData.title || videoData.anime_name || '線上播放器';
    var subtitle = document.createElement('p');
    subtitle.textContent = (videoData.anime_name || '未分類作品') + ' · 第 ' + videoData.episode + ' 集';

    titleGroup.appendChild(title);
    titleGroup.appendChild(subtitle);
    panelHeader.appendChild(titleGroup);
    metaPanel.appendChild(panelHeader);

    var grid = document.createElement('div');
    grid.className = 'watch-meta-grid';
    grid.appendChild(createMetaCard('來源', videoData.source || '未知來源', videoData.source == '巴哈姆特動畫瘋' ? {
        href: 'https://ani.gamer.com.tw/animeVideo.php?sn=' + videoData.sn,
        text: '巴哈姆特動畫瘋'
    } : null));
    grid.appendChild(createMetaCard('解析度', String(videoData.resolution || '未知') + 'P'));
    grid.appendChild(createMetaCard('集數數量', String(videoSeries.length || 0) + ' 集'));
    grid.appendChild(createMetaCard('影片編號', String(videoData.sn)));
    metaPanel.appendChild(grid);
}

function updateWatchShellState(mode, videoData, videoSeries) {
    var watchLayout = document.getElementById('watchLayout');
    var watchLibrary = document.getElementById('watch-library');
    var watchHeadline = document.getElementById('watchHeadline');
    var watchSubtitle = document.getElementById('watchSubtitle');
    var watchUserChip = document.getElementById('watchUserChip');
    var episodeSummary = document.getElementById('episodeSummary');
    var librarySummary = document.getElementById('librarySummary');

    if (watchUserChip) {
        watchUserChip.textContent = getWatchUserLabel();
    }

    if (mode === 'player' && videoData) {
        if (watchLayout) {
            watchLayout.style.display = 'grid';
        }
        if (watchLibrary) {
            watchLibrary.classList.add('watch-library--collapsed');
        }
        if (watchHeadline) {
            watchHeadline.textContent = videoData.anime_name || videoData.title || '線上播放器';
        }
        if (watchSubtitle) {
            watchSubtitle.textContent = '第 ' + videoData.episode + ' 集 · ' + (videoData.title || '已啟動播放器與續播資料');
        }
        if (episodeSummary) {
            episodeSummary.textContent = '共 ' + videoSeries.length + ' 集';
        }
        setWatchStatusChip('播放器已就緒');
        return;
    }

    if (watchLayout) {
        watchLayout.style.display = 'none';
    }
    if (watchLibrary) {
        watchLibrary.classList.remove('watch-library--collapsed');
    }
    if (watchHeadline) {
        watchHeadline.textContent = '動畫片庫';
    }
    if (watchSubtitle) {
        watchSubtitle.textContent = '可搜尋全部作品、查看近期更新，並從觀看紀錄直接續播。';
    }
    if (librarySummary) {
        librarySummary.textContent = '支援搜尋、近期更新與續看紀錄。';
    }
    setWatchStatusChip('瀏覽片庫中');
}

// Main Initialization
async function main() {
    var bootstrap = getWatchBootstrap();
    var urlParams = new URLSearchParams(window.location.search);
    var videoId = urlParams.get('id') || bootstrap.requestedVideoId;
    var videoResolution = urlParams.get('res') || bootstrap.requestedResolution || (bootstrap.initialVideoData ? bootstrap.initialVideoData.resolution : null);

    if (videoId && videoResolution) {
        var videoData = await fetchVideoData(videoId);
        var videoSeries = await getVideoSeries(videoId);

        updateWatchShellState('player', videoData, videoSeries);

        // Initialize Player
        window.videoPlayer = new VideoPlayer('videobox', videoData, videoSeries);

        // Update Page Title and Info
        document.title = (videoData.title || videoData.anime_name || 'aGP+ Watch') + " | aGP+";
        renderWatchMeta(videoData, videoSeries);

        // Create Episode List
        createEpisodeList(videoSeries);
    } else {
        updateWatchShellState('library');
        renderFullVideoList();
    }
}

async function renderFullVideoList() {
    try {
        const container = document.getElementById('watch-library-content') || document.body;
        container.innerHTML = '';

        // Search Box
        var searchBox = document.createElement("div");
        searchBox.classList.add('watch-search-row');
        var searchInput = document.createElement("input");
        searchInput.type = "search";
        searchInput.classList.add('form-control');
        searchInput.classList.add('watch-search-input');
        searchInput.placeholder = "搜尋動畫名稱...";
        searchInput.addEventListener("input", (event) => {
            var query = event.target.value.toLowerCase();
            Array.prototype.forEach.call(document.getElementsByClassName("animeCategory"), (category) => {
                var name = category.getElementsByTagName("h2")[0].textContent.toLowerCase();
                if (name.includes(query)) {
                    category.style.display = "block";
                } else {
                    category.style.display = "none";
                }
            });
        });
        searchBox.appendChild(searchInput);
        container.appendChild(searchBox);
        container.appendChild(document.createElement("hr"));

        // Loading Bar
        var loadingBar = document.createElement("div");
        loadingBar.classList.add('watch-loading');
        loadingBar.innerHTML = '<div id="progdiv" class="progress"><div id="prog" class="progress-bar progress-bar-striped progress-bar-animated" role="progressbar" aria-valuenow="1" aria-valuemin="0" aria-valuemax="1" style="width: 100%">載入片庫中...</div></div>';
        container.appendChild(loadingBar);

        // Get Data
        var watchedTimes = await getAllTimes();
        var data = await getVideoList();
        var videos = data.videos || [];

        const animeGroups = {};
        videos.forEach(video => {
            if (!animeGroups[video.anime_name]) {
                animeGroups[video.anime_name] = [];
            }
            animeGroups[video.anime_name].push(video);
        });

        var librarySummary = document.getElementById('librarySummary');
        if (librarySummary) {
            librarySummary.textContent = '共 ' + Object.keys(animeGroups).length + ' 部作品 / ' + videos.length + ' 集';
        }

        // --- Recently Updated (Bahamut Source) ---
        var bahamutVideos = videos.filter(video => video.source == "巴哈姆特動畫瘋");
        var lastBahamutVideos = {};
        for (var i = bahamutVideos.length - 1; i >= 0; i--) {
            if (Object.keys(lastBahamutVideos).length >= 10) {
                break;
            }
            if (!lastBahamutVideos[bahamutVideos[i].anime_name]) {
                lastBahamutVideos[bahamutVideos[i].anime_name] = bahamutVideos[i];
            } else {
                if (lastBahamutVideos[bahamutVideos[i].anime_name].episode < bahamutVideos[i].episode) {
                    lastBahamutVideos[bahamutVideos[i].anime_name] = bahamutVideos[i];
                }
            }
        }
        lastBahamutVideos = Object.values(lastBahamutVideos);

        // --- Recently Watched ---
        if (watchedTimes && Object.keys(watchedTimes).length > 0) {
            var userWatchedVideos = videos.filter(video => watchedTimes[video.sn]);
            userWatchedVideos.sort((a, b) => watchedTimes[b.sn].timestamp - watchedTimes[a.sn].timestamp);

            var lastWatchAnimeGroups = {};
            userWatchedVideos.forEach(video => {
                video.timestamp = watchedTimes[video.sn].timestamp;
                if (lastWatchAnimeGroups[video.anime_name]) {
                    if (lastWatchAnimeGroups[video.anime_name].timestamp < video.timestamp) {
                        lastWatchAnimeGroups[video.anime_name] = video;
                    }
                } else {
                    lastWatchAnimeGroups[video.anime_name] = video;
                }
            });

            var watchedVideoBox = document.createElement('div');
            watchedVideoBox.classList.add('row');
            watchedVideoBox.classList.add('animeCategory');

            var watchedVideoTitle = document.createElement('h2');
            watchedVideoTitle.classList.add('animeCategoryTitle');
            watchedVideoTitle.textContent = "繼續觀看";
            watchedVideoBox.appendChild(watchedVideoTitle);

            var watchedVideoList = document.createElement('ul');
            watchedVideoList.classList.add('animeEpisodeList');
            watchedVideoBox.appendChild(watchedVideoList);
            container.appendChild(watchedVideoBox);

            var limit = 10;
            for (var anime in lastWatchAnimeGroups) {
                limit--;
                if (limit < 0) break;

                var videoItem = lastWatchAnimeGroups[anime];
                if (!videoItem) break;

                var videoId = videoItem.sn;
                var videoTitle = videoItem.anime_name;

                var videoListItem = document.createElement('li');
                videoListItem.classList.add('animeEpisodeItem');

                var videoLink = document.createElement('a');
                videoLink.href = './watch?id=' + encodeURIComponent(videoId) + '&res=' + encodeURIComponent(videoItem.resolution);
                videoLink.textContent = `${videoTitle}`;
                videoListItem.appendChild(videoLink);

                if (watchedTimes[videoId]) {
                    var watchedText = document.createElement('p');
                    watchedText.classList.add('watchedText');
                    if (watchedTimes[videoId].ended) {
                        var videoSeries = await getVideoSeries(videoId);
                        var nextEpisode = (Number(videoItem.episode) + 1).toString();
                        var videoSeriesItem = videoSeries.find(video => video.episode == nextEpisode);
                        if (videoSeriesItem) {
                            videoLink.href = './watch?id=' + encodeURIComponent(videoSeriesItem.sn) + '&res=' + encodeURIComponent(videoSeriesItem.resolution);
                            watchedText.textContent = "看到第 " + videoSeriesItem.episode + " 集";
                        } else {
                            limit++;
                            videoListItem.remove();
                            continue;
                        }
                    } else {
                        watchedText.textContent = "看到第 " + videoItem.episode + " 集 " + convertTime(watchedTimes[videoId].time);
                    }
                    videoListItem.appendChild(watchedText);
                }
                watchedVideoList.appendChild(videoListItem);
            }
            watchedVideoTitle.addEventListener('click', function () {
                if (watchedVideoList.style.display === "grid") {
                    watchedVideoList.style.display = "none";
                } else {
                    watchedVideoList.style.display = "grid";
                }
            });
        }

        // --- Render Recently Updated ---
        if (lastBahamutVideos.length > 0) {
            var lastBahamutBox = document.createElement('div');
            lastBahamutBox.classList.add('row');
            lastBahamutBox.classList.add('animeCategory');

            var lastBahamutTitle = document.createElement('h2');
            lastBahamutTitle.classList.add('animeCategoryTitle');
            lastBahamutTitle.textContent = "近期更新";
            lastBahamutBox.appendChild(lastBahamutTitle);

            var lastBahamutList = document.createElement('ul');
            lastBahamutList.classList.add('animeEpisodeList');
            lastBahamutBox.appendChild(lastBahamutList);
            container.appendChild(lastBahamutBox);

            for (var i = 0; i < lastBahamutVideos.length; i++) {
                var videoItem = lastBahamutVideos[i];
                var videoId = videoItem.sn;
                var videoTitle = videoItem.anime_name;

                var videoListItem = document.createElement('li');
                videoListItem.classList.add('animeEpisodeItem');

                var videoLink = document.createElement('a');
                videoLink.href = './watch?id=' + encodeURIComponent(videoId) + '&res=' + encodeURIComponent(videoItem.resolution);
                videoLink.textContent = `${videoTitle}`;
                videoListItem.appendChild(videoLink);

                var watchedText = document.createElement('p');
                watchedText.classList.add('watchedText');
                watchedText.textContent = "更新至第 " + videoItem.episode + " 集";
                videoListItem.appendChild(watchedText);

                lastBahamutList.appendChild(videoListItem);
            }
            lastBahamutTitle.addEventListener('click', function () {
                if (lastBahamutList.style.display === "grid") {
                    lastBahamutList.style.display = "none";
                } else {
                    lastBahamutList.style.display = "grid";
                }
            });
        }

        container.appendChild(document.createElement("hr"));

        // --- Render Full List ---
        for (const [animeName, series] of Object.entries(animeGroups)) {
            series.sort((a, b) => a.episode - b.episode);

            const categorybox = document.createElement('div');
            categorybox.className = 'animeCategory row';

            const categoryTitle = document.createElement('h2');
            categoryTitle.className = 'animeCategoryTitle';
            categoryTitle.textContent = animeName;
            categorybox.appendChild(categoryTitle);

            const videoList = document.createElement('ul');
            videoList.className = 'animeEpisodeList';
            videoList.style.display = 'none';

            series.forEach(video => {
                const li = document.createElement('li');
                li.className = 'animeEpisodeItem';

                const a = document.createElement('a');
                a.href = `./watch?id=${video.sn}&res=${video.resolution}`;
                a.textContent = `第 ${video.episode} 集`;
                li.appendChild(a);

                if (watchedTimes[video.sn]) {
                    var watchedText = document.createElement('p');
                    watchedText.classList.add('watchedText');
                    if (watchedTimes[video.sn].ended) {
                        watchedText.textContent = "看完了";
                    } else {
                        watchedText.textContent = "看到 " + convertTime(watchedTimes[video.sn].time);
                    }
                    li.appendChild(watchedText);
                }

                videoList.appendChild(li);
            });

            categorybox.appendChild(videoList);
            container.appendChild(categorybox);

            // Toggle functionality
            categoryTitle.addEventListener('click', function () {
                if (videoList.style.display === "grid") {
                    videoList.style.display = "none";
                } else {
                    videoList.style.display = "grid";
                }
            });
        }

        loadingBar.remove();

    } catch (e) {
        console.error("Error in renderFullVideoList:", e);
        const container = document.getElementById('watch-library-content');
        const librarySummary = document.getElementById('librarySummary');
        if (librarySummary) {
            librarySummary.textContent = '片庫載入失敗';
        }
        if (container) {
            container.innerHTML = '<p class="watch-empty-state">無法載入片庫，請稍後再試。</p>';
        }
    }
}

function createEpisodeList(videoSeries) {
    videoSeries.sort((a, b) => a.episode - b.episode);

    var panel = document.getElementById('episode-list-panel');
    var sidebar = document.getElementById('watch-sidebar');
    var episodeSummary = document.getElementById('episodeSummary');
    var currentVideoId = new URLSearchParams(window.location.search).get('id') || getWatchBootstrap().requestedVideoId;
    if (!panel || !sidebar) {
        return;
    }

    panel.innerHTML = '';
    sidebar.classList.remove('watch-panel--hidden');
    if (episodeSummary) {
        episodeSummary.textContent = '共 ' + videoSeries.length + ' 集';
    }

    var categorybox = document.createElement('div');
    categorybox.classList.add('animeCategory');

    var categoryTitle = document.createElement('h2');
    categoryTitle.classList.add('animeCategoryTitle');
    categoryTitle.textContent = "集數列表";
    categorybox.appendChild(categoryTitle);

    var videoListe = document.createElement('ul');
    videoListe.classList.add('animeEpisodeList');

    for (var j = 0; j < videoSeries.length; j++) {
        var videoItem = videoSeries[j];
        var videoId = videoItem.sn;

        var videoLink = document.createElement('a');
        videoLink.href = './watch?id=' + encodeURIComponent(videoId) + '&res=' + encodeURIComponent(videoItem.resolution);
        videoLink.textContent = `第 ${videoItem.episode} 集`;

        var videoListItem = document.createElement('li');
        videoListItem.classList.add('animeEpisodeItem');
        if (String(videoId) === String(currentVideoId)) {
            videoListItem.classList.add('animeEpisodeItem--active');
        }
        videoListItem.appendChild(videoLink);
        videoListe.appendChild(videoListItem);
    }

    categorybox.appendChild(videoListe);

    panel.appendChild(categorybox);

    if (isMobileDevice()) {
        videoListe.style.display = 'none';
        categoryTitle.addEventListener('click', function () {
            if (videoListe.style.display === "grid") {
                videoListe.style.display = "none";
            } else {
                videoListe.style.display = "grid";
            }
        });
    } else {
        categorybox.classList.add('animeWatchingCategory');
        categoryTitle.classList.add('animeWatchingTitle');
        videoListe.classList.add('animeWatchingEpisodeList');
        videoListe.style.display = "grid";
    }
}
