// Helper Functions
function parseCookie() {
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
    var value = parseCookie()[name];
    if (value) {
        value = decodeURIComponent(value);
    }
    return value;
}

async function getTime(sn) {
    if (getCookieByName('logined') == 'true') {
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
    if (getCookieByName('logined') == 'true') {
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
    if (getCookieByName('logined') == 'true') {
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

async function getVideoList() {
    try {
        let response = await fetch('./video_list.json');
        let data = await response.json();
        return data;
    } catch (error) {
        console.error("發生錯誤：", error);
        alert("無法載入影片清單！");
        return {};
    }
}

async function fetchVideoData(sn) {
    let vl = await getVideoList();
    let videolist = vl.videos;
    let videodata = videolist.find(value => value.sn == sn);

    if (!videodata) {
        alert("影片不存在！");
        history.back();
        return;
    }
    return videodata;
}

async function getVideoSeries(sn) {
    let vd = await fetchVideoData(sn);
    let fullList = await getVideoList();
    let series = fullList.videos.filter(value => value.anime_name == vd.anime_name);
    return series;
}

function convertTime(duration) {
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

        this.speeds.forEach(speed => {
            const item = document.createElement('div');
            item.className = 'settings-item';
            item.innerText = speed + 'x';
            item.onclick = () => {
                this.video.playbackRate = speed;
                this.settingsMenu.classList.remove('active');
            };
            this.settingsMenu.appendChild(item);
        });

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
            });
    }

    attachEvents() {
        // Video Events
        this.video.addEventListener('click', () => this.togglePlay());
        this.video.addEventListener('play', () => this.onPlay());
        this.video.addEventListener('pause', () => this.onPause());
        this.video.addEventListener('timeupdate', () => this.onTimeUpdate());
        this.video.addEventListener('loadedmetadata', () => this.onLoadedMetadata());
        this.video.addEventListener('waiting', () => this.loadingSpinner.style.display = 'block');
        this.video.addEventListener('playing', () => this.loadingSpinner.style.display = 'none');
        this.video.addEventListener('canplay', () => this.loadingSpinner.style.display = 'none');
        this.video.addEventListener('ended', () => this.onEnded());

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

        // Mouse/Touch Interaction for Controls Visibility
        this.container.addEventListener('mousemove', () => this.showControls());
        this.container.addEventListener('mouseleave', () => this.hideControls());
        this.container.addEventListener('touchstart', () => this.showControls());

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
            this.showCenterIcon(this.getIcon('play'), true);
        } else {
            this.video.pause();
            this.showCenterIcon(this.getIcon('pause'), true);
        }
    }

    onPlay() {
        this.playBtn.innerHTML = this.getIcon('pause');
        this.showControls();
        this.centerIcon.style.opacity = '0';
    }

    onPause() {
        this.playBtn.innerHTML = this.getIcon('play');
        this.showControls();
        setTime(this.videoData.sn, this.video.currentTime, false, true);
        this.showCenterIcon(this.getIcon('play'), false);
        this.centerIcon.style.opacity = '1';
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
    }

    hideControls() {
        if (!this.video.paused) {
            this.container.classList.remove('show-controls');
            this.container.style.cursor = 'none';
            this.settingsMenu.classList.remove('active');
        }
    }

    toggleFullscreen() {
        if (!document.fullscreenElement) {
            this.container.requestFullscreen().catch(err => {
                console.log(`Error attempting to enable full-screen mode: ${err.message} (${err.name})`);
            });
            this.container.classList.add('fullscreen');
            try { screen.orientation.lock("landscape-primary"); } catch (e) { }
        } else {
            document.exitFullscreen();
            this.container.classList.remove('fullscreen');
            try { screen.orientation.unlock(); } catch (e) { }
        }
    }

    toggleSettings() {
        this.settingsMenu.classList.toggle('active');
    }

    toggleDanmu() {
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
            this.showCenterIcon(this.getIcon('rewind'), true);
        } else if (touchX > width * 2 / 3) {
            this.video.currentTime += 10;
            this.showCenterIcon(this.getIcon('forward'), true);
        } else {
            this.togglePlay();
        }
    }

    showCenterIcon(svg, animate) {
        this.centerIcon.innerHTML = svg;
        this.centerIcon.style.opacity = '1';
        if (animate) {
            this.centerIcon.classList.remove('animate');
            void this.centerIcon.offsetWidth; // Trigger reflow
            this.centerIcon.classList.add('animate');
            setTimeout(() => {
                this.centerIcon.style.opacity = '0';
                this.centerIcon.classList.remove('animate');
            }, 500);
        }
    }

    handleKeydown(e) {
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
                break;
            case 'ArrowRight':
                this.video.currentTime += 5;
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
            speed: '<svg viewBox="0 0 24 24"><path d="M20.38 8.57l-1.23 1.85a8 8 0 0 1-.22 7.58H5.07A8 8 0 0 1 15.58 6.85l1.85-1.23A10 10 0 0 0 3.35 19a2 2 0 0 0 1.72 1h13.85a2 2 0 0 0 1.74-1 10 10 0 0 0-.27-10.44zm-9.79 6.84a2 2 0 0 0 2.83 0l5.66-8.49-8.49 5.66a2 2 0 0 0 0 2.83z"/></svg>',
            danmuOn: '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H5.17L4 17.17V4h16v12z"/></svg>',
            rewind: '<svg viewBox="0 0 24 24"><path d="M11 18V6l-8.5 6 8.5 6zm.5-6l8.5 6V6l-8.5 6z"/></svg>',
            forward: '<svg viewBox="0 0 24 24"><path d="M4 18l8.5-6L4 6v12zm9-12v12l8.5-6L13 6z"/></svg>'
        };
        return icons[name] || '';
    }
}

// Main Initialization
async function main() {
    var urlParams = new URLSearchParams(window.location.search);
    var videoId = urlParams.get('id');
    var videoResolution = urlParams.get('res');

    if (videoId && videoResolution) {
        var videoData = await fetchVideoData(videoId);
        var videoSeries = await getVideoSeries(videoId);

        // Initialize Player
        new VideoPlayer('videobox', videoData, videoSeries);

        // Update Page Title and Info
        document.title = videoData.title + " | aGP+";

        // Create Info Section
        var videoDetail = document.createElement("div");
        var videoTitle = document.createElement("h2");
        var videoSource = document.createElement("p");
        videoTitle.innerText = videoData.title;

        if (videoData.source == "巴哈姆特動畫瘋") {
            videoSource.innerHTML = '來源：<a href="https://ani.gamer.com.tw/animeVideo.php?sn=' + videoData.sn + '">巴哈姆特動畫瘋</a>';
        } else {
            videoSource.innerText = '來源：' + videoData.source;
        }
        videoDetail.appendChild(videoTitle);
        videoDetail.appendChild(videoSource);
        document.body.appendChild(videoDetail);

        // Create Episode List
        createEpisodeList(videoSeries);
    } else {
        // Hide video box in list mode
        const videobox = document.getElementById('videobox');
        if (videobox) videobox.style.display = 'none';

        renderFullVideoList();
    }
}

async function renderFullVideoList() {
    try {
        const container = document.querySelector('.container') || document.body;

        // Search Box
        var searchBox = document.createElement("div");
        searchBox.classList.add('row');
        searchBox.classList.add('setting-content');
        var searchInput = document.createElement("input");
        searchInput.type = "search";
        searchInput.classList.add('form-control');
        searchInput.placeholder = "搜尋動漫...";
        searchInput.style.width = "100%";
        searchInput.style.padding = "10px";
        searchInput.style.marginBottom = "20px";
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
        loadingBar.classList.add('row');
        loadingBar.classList.add('setting-content');
        loadingBar.style.display = "flex";
        loadingBar.style.justifyContent = "center";
        loadingBar.style.color = "white";
        loadingBar.innerText = "載入清單中...";
        container.appendChild(loadingBar);

        // Get Data
        var watchedTimes = await getAllTimes();
        var data = await getVideoList();
        var videos = data.videos || [];

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
        const animeGroups = {};
        videos.forEach(video => {
            if (!animeGroups[video.anime_name]) {
                animeGroups[video.anime_name] = [];
            }
            animeGroups[video.anime_name].push(video);
        });

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
    }
}

function createEpisodeList(videoSeries) {
    videoSeries.sort((a, b) => a.episode - b.episode);

    var categorybox = document.createElement('div');
    categorybox.classList.add('animeCategory');
    categorybox.classList.add('row');

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
        videoListItem.appendChild(videoLink);
        videoListe.appendChild(videoListItem);
    }

    categorybox.appendChild(videoListe);

    if (isMobileDevice()) {
        document.body.appendChild(categorybox);
        categoryTitle.addEventListener('click', function () {
            if (videoListe.style.display === "grid") {
                videoListe.style.display = "none";
            } else {
                videoListe.style.display = "grid";
            }
        });
    } else {
        document.getElementById("videobox").style.width = "70%";
        categorybox.classList.add('animeWatchingCategory');
        categoryTitle.classList.add('animeWatchingTitle');
        videoListe.classList.add('animeWatchingEpisodeList');
        document.getElementById("anotherVideoBox").appendChild(categorybox);
        videoListe.style.display = "grid";

        // Resize logic
        const resizeList = () => {
            var widthsize = 70; // Desktop width percentage
            var finalWidth = window.innerWidth * (widthsize / 100);
            var finalHeight = (finalWidth / 16 * 9) - 75;
            categorybox.style.height = finalHeight + 'px';
        };
        resizeList();
        window.addEventListener("resize", resizeList);
    }
}
