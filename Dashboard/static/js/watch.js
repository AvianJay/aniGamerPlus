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

var videoList;

async function getVideoList() {
    if (!videoList) {
        try {
            let response = await fetch('./video_list.json');
            let data = await response.json();
            videoList = data;
        } catch (error) {
            console.error("發生錯誤：", error);
            alert("無法載入影片清單！");
            return {};
        }
    }
    return videoList
}

async function fetchVideoData(sn) {
    let vl = await getVideoList();
    let videolist = vl.videos;
    let videodata = videolist.find(value => value.sn == sn);

    // check video exists
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
    series = fullList.videos.filter(value => value.anime_name == vd.anime_name);
    return series;
}

function convertTime(duration) {
    const h = Math.floor(duration / 60);
    const m = Math.round(duration % 60);
    const result = `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}`;
    return result;
}

async function main() {
    var urlParams = new URLSearchParams(window.location.search);
    var videoId = urlParams.get('id');
    var videoResolution = urlParams.get('res');
    if (videoId && videoResolution) {
        var videoData = await fetchVideoData(videoId);
        var videoSeries = await getVideoSeries(videoId);
        var videoSrc = './get_video.mp4?id=' + encodeURIComponent(videoId) + '&res=' + videoResolution;
        var subtitleSrc = './get_danmu.ass?id=' + encodeURIComponent(videoId) + "&t=" + new Date().getTime();
        var videoPlayer = document.getElementById('videobox');
        var video = document.createElement('video');
        var ctrldiv = document.createElement('div');
        var playPauseButton = document.createElement('button');
        playPauseButton.setAttribute("id", "playPauseButton");
        playPauseButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%"><path d="M 12,26 18.5,22 18.5,14 12,10 z M 18.5,22 25,18 25,18 18.5,14 z"></path></svg>';
        var fullscreenButton = document.createElement('button');
        fullscreenButton.setAttribute("id", "fullscreenButton");
        fullscreenButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%"><g class="ytp-fullscreen-button-corner-0"><use class="ytp-svg-shadow" xlink:href="#ytp-id-7"></use><path class="ytp-svg-fill" d="m 10,16 2,0 0,-4 4,0 0,-2 L 10,10 l 0,6 0,0 z" id="ytp-id-7"></path></g><g class="ytp-fullscreen-button-corner-1"><use class="ytp-svg-shadow" xlink:href="#ytp-id-8"></use><path class="ytp-svg-fill" d="m 20,10 0,2 4,0 0,4 2,0 L 26,10 l -6,0 0,0 z" id="ytp-id-8"></path></g><g class="ytp-fullscreen-button-corner-2"><use class="ytp-svg-shadow" xlink:href="#ytp-id-9"></use><path class="ytp-svg-fill" d="m 24,24 -4,0 0,2 L 26,26 l 0,-6 -2,0 0,4 0,0 z" id="ytp-id-9"></path></g><g class="ytp-fullscreen-button-corner-3"><path class="ytp-svg-fill" d="M 12,20 10,20 10,26 l 6,0 0,-2 -4,0 0,-4 0,0 z"></path></g></svg>';
        fullscreenButton.setAttribute("aria-label", "全螢幕");
        fullscreenButton.setAttribute("title", "全螢幕");
        var playrateButton = document.createElement('button');
        playrateButton.innerHTML = '<svg width="800px" height="800px" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2" stroke="#1C274C" stroke-width="1.5" stroke-linecap="round"/><path opacity="0.5" d="M12 22C6.47715 22 2 17.5228 2 12C2 6.47715 6.97715 2 12.5 2" stroke="#1C274C" stroke-width="1.5" stroke-linecap="round" stroke-dasharray="4 3"/><path d="M15.4137 10.941C16.1954 11.4026 16.1954 12.5974 15.4137 13.059L10.6935 15.8458C9.93371 16.2944 9 15.7105 9 14.7868L9 9.21316C9 8.28947 9.93371 7.70561 10.6935 8.15419L15.4137 10.941Z" stroke="#1C274C" stroke-width="1.5"/></svg>';
        playrateButton.setAttribute("id", "playrateButton");
        playrateButton.setAttribute("aria-label", "播放速度");
        var timeSlider = document.createElement('input');
        timeSlider.setAttribute("id", "timeSlider");
        timeSlider.setAttribute("type", "range");
        timeSlider.setAttribute("min", "0");
        timeSlider.setAttribute("max", "100");
        timeSlider.setAttribute("step", "1");
        timeSlider.value = 0;
        var timetext = document.createElement('a');
        timetext.innerText = "..."
        var isFullscreen = false;
        ctrldiv.setAttribute("id", "controls");
        video.controls = false;
        video.autoplay = true;
        video.setAttribute("preload", "metadata");
        video.setAttribute("id", "player");
        video.setAttribute("src", videoSrc);
        videoPlayer.appendChild(video);
        var assContainer = document.createElement("div");
        assContainer.setAttribute("id", "ass-container");
        videoPlayer.appendChild(assContainer);
        var loadingSpinner = document.createElement("div")
        loadingSpinner.setAttribute("id", "loading-spinner")
        videoPlayer.appendChild(loadingSpinner)
        loadingSpinner.style.display = 'block';
        ctrldiv.appendChild(playPauseButton);
        if (!isMobileDevice()) {
            var volumeSlider = document.createElement('input');
            volumeSlider.setAttribute("id", "volumeSlider");
            volumeSlider.setAttribute("type", "range");
            volumeSlider.setAttribute("min", "0");
            volumeSlider.setAttribute("max", "1");
            volumeSlider.setAttribute("step", "0.01");
            volumeSlider.setAttribute("value", "1");
            volumeSlider.setAttribute("type", "range");
            volumeSlider.setAttribute("min", "0");
            ctrldiv.appendChild(volumeSlider);
        }
        ctrldiv.appendChild(timeSlider);
        ctrldiv.appendChild(timetext);
        if (videoData.danmu) {
            var danmuButton = document.createElement('button');
            danmuButton.setAttribute("id", "danmuButton");
            danmuButton.innerHTML = '<svg class="ytp-subtitles-button-icon" height="100%" version="1.1" viewBox="0 0 36 36" width="100%" fill-opacity="1"><use class="ytp-svg-shadow" xlink:href="#ytp-id-68"></use><path d="M11,11 C9.9,11 9,11.9 9,13 L9,23 C9,24.1 9.9,25 11,25 L25,25 C26.1,25 27,24.1 27,23 L27,13 C27,11.9 26.1,11 25,11 L11,11 Z M11,17 L14,17 L14,19 L11,19 L11,17 L11,17 Z M20,23 L11,23 L11,21 L20,21 L20,23 L20,23 Z M25,23 L22,23 L22,21 L25,21 L25,23 L25,23 Z M25,19 L16,19 L16,17 L25,17 L25,19 L25,19 Z" fill="#fff" id="ytp-id-68"></path></svg>';
            ctrldiv.appendChild(danmuButton);
        }
        ctrldiv.appendChild(playrateButton);

        // 創建速度選單
        var speedDropdown = document.createElement('select');
        speedDropdown.setAttribute("id", "speedDropdown");
        speedDropdown.style.display = 'none'; // 預設隱藏

        // 添加速度選項
        var speeds = [0.25, 0.5, 1, 1.25, 1.5, 2];
        speeds.forEach(function (speed) {
            var option = document.createElement('option');
            option.value = speed;
            option.textContent = `${speed}x`;
            if (speed === 1) {
                option.selected = true; // 預設為 1x
            }
            speedDropdown.appendChild(option);
        });

        // 當選擇速度時，調整影片播放速度
        speedDropdown.addEventListener('change', function () {
            video.playbackRate = parseFloat(speedDropdown.value);
            speedDropdown.style.display = 'none'; // 選擇後隱藏選單
        });

        // 點擊播放速度按鈕時顯示或隱藏速度選單
        playrateButton.addEventListener('click', function () {
            if (speedDropdown.style.display === 'none') {
                // 顯示選單並調整位置
                const rect = playrateButton.getBoundingClientRect();
                speedDropdown.style.top = '-30px';
                speedDropdown.style.left = `${rect.left - 12}px`;
                speedDropdown.style.display = 'block';
            } else {
                // 隱藏選單
                speedDropdown.style.display = 'none';
            }
        });

        // 將速度選單加入控制列
        ctrldiv.appendChild(speedDropdown);
        ctrldiv.appendChild(fullscreenButton);

        var overlay = document.createElement('div');
        overlay.setAttribute("id", "overlay");
        overlay.style.display = 'none'; // 預設隱藏
        videoPlayer.appendChild(overlay);
        var endBox = document.createElement('div');
        endBox.setAttribute("id", "endBox");
        endBox.style.display = 'none'; // 預設隱藏
        var endText = document.createElement('h2');
        endBox.appendChild(endText);
        var endButtonContainer = document.createElement('div');
        endButtonContainer.classList.add('button-container');
        var endCancelButton = document.createElement('button');
        endCancelButton.innerText = "取消";
        var endNextButton = document.createElement('button');
        endNextButton.innerText = "下一集";
        endButtonContainer.appendChild(endCancelButton);
        endButtonContainer.appendChild(endNextButton);
        endBox.appendChild(endButtonContainer);
        videoPlayer.appendChild(endBox);

        videoPlayer.appendChild(ctrldiv);
        var controlsTimeout;
        var widthsize;
        var danmuEnabled = true;
        var ass;
        var ended = false;
        var webTime = await getTime(videoId);

        playPauseButton.addEventListener('click', function () {
            if (video.paused) {
                video.play();
            } else {
                video.pause();
            }
        });

        if (!isMobileDevice()) {
            volumeSlider.addEventListener('input', function () {
                video.volume = volumeSlider.value;
            });
        }

        video.addEventListener('timeupdate', function () {
            timeSlider.value = video.currentTime;
            syncTime(video.currentTime);
        });

        timeSlider.addEventListener('input', function () {
            video.currentTime = timeSlider.value;
            syncTime(video.currentTime);
        });

        document.addEventListener('keydown', function (event) {
            if (event.code === 'Space' || event.key === 'p' || event.key === 'P') {
                togglePlayPause();
            } else if (event.key === 'ArrowLeft') {
                skipBackward();
            } else if (event.key === 'ArrowRight') {
                skipForward();
            } else if (event.key === 'f' || event.key === 'F') {
                toggleFullscreen();
            } else if (event.key === 'Escape') {
                if (isFullscreen) {
                    toggleFullscreen();
                }
            } else if (event.key === '<') {
                // playrate down
                let currentRate = parseFloat(video.playbackRate);
                for (let i = 0; i < speeds.length; i++) {
                    if (speeds[i] === currentRate) {
                        if (i > 0) {
                            video.playbackRate = speeds[i - 1];
                            speedDropdown.value = speeds[i - 1];
                        }
                        break;
                    }
                }
            } else if (event.key === '>') {
                // playrate up
                let currentRate = parseFloat(video.playbackRate);
                for (let i = 0; i < speeds.length; i++) {
                    if (speeds[i] === currentRate) {
                        if (i < speeds.length - 1) {
                            video.playbackRate = speeds[i + 1];
                            speedDropdown.value = speeds[i + 1];
                        }
                        break;
                    }
                }
            }
        });

        function togglePlayPause() {
            if (video.paused) {
                video.play();
            } else {
                video.pause();
            }
        }

        // anti lag
        var skipTimeout;
        var _skipTime = 0;
        var videoPreviousStatus; // !video.paused

        function _skipVideoTime() {
            video.currentTime += _skipTime;
            _skipTime = 0;
            timeSlider.value = video.currentTime;
            if (videoPreviousStatus) {
                video.play();
            }
            syncTime(video.currentTime);
        }
        function skipBackward() {
            _skipTime -= 10;
            clearTimeout(skipTimeout);
            videoPreviousStatus = !video.paused;
            loadingSpinner.style.display = 'block';
            video.pause();
            skipTimeout = setTimeout(_skipVideoTime, 300);
        }

        function skipForward() {
            _skipTime += 10;
            clearTimeout(skipTimeout);
            videoPreviousStatus = !video.paused;
            loadingSpinner.style.display = 'block';
            video.pause();
            skipTimeout = setTimeout(_skipVideoTime, 300);
        }


        video.addEventListener('loadedmetadata', async function () {
            timeSlider.max = video.duration;
            timeSlider.value = 0;
            const dh = Math.floor(video.duration / 60);
            const dm = Math.round(video.duration % 60);
            const dt = `${dh.toString().padStart(2, '0')}:${dm.toString().padStart(2, '0')}`;
            const ch = Math.floor(video.currentTime / 60);
            const cm = Math.round(video.currentTime % 60);
            const ct = `${ch.toString().padStart(2, '0')}:${cm.toString().padStart(2, '0')}`;
            timetext.innerHTML = ct + '/' + dt;
            video.currentTime = webTime;
            timeSlider.value = webTime;
            syncTime(webTime);

            window.addEventListener('beforeunload', function () {
                // 使用 navigator.sendBeacon 發送資料
                navigator.sendBeacon('./watch/time', JSON.stringify({
                    type: 'set',
                    sn: videoData.sn,
                    time: video.currentTime,
                    ended: ended
                }));
            });
        });

        video.addEventListener('canplay', function () {
            loadingSpinner.style.display = 'none';
        });

        video.addEventListener('playing', function () {
            loadingSpinner.style.display = 'none';
        });

        video.addEventListener('waiting', function () {
            loadingSpinner.style.display = 'block';
        });

        video.addEventListener('play', function () {
            playPauseButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%"><path d="M 12,26 16,26 16,10 12,10 z M 21,26 25,26 25,10 21,10 z"></path></svg>';
        });

        video.addEventListener('pause', function () {
            playPauseButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%"><path d="M 12,26 18.5,22 18.5,14 12,10 z M 18.5,22 25,18 25,18 18.5,14 z"></path></svg>';
            showControls();
            ended = (video.currentTime >= video.duration - 10)
            setTime(videoData.sn, video.currentTime, ended, true);
        })
        if (videoData.danmu) {
            danmuButton.addEventListener('click', function () {
                if (danmuEnabled) {
                    ass.hide();
                    danmuEnabled = false;
                    // stolen from yt lol
                    danmuButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%" fill-opacity="1"><path d="M11,11 C9.9,11 9,11.9 9,13 L9,23 C9,24.1 9.9,25 11,25 L25,25 C26.1,25 27,24.1 27,23 L27,13 C27,11.9 26.1,11 25,11 L11,11 Z M11,17 L14,17 L14,19 L11,19 L11,17 L11,17 Z M20,23 L11,23 L11,21 L20,21 L20,23 L20,23 Z M25,23 L22,23 L22,21 L25,21 L25,23 L25,23 Z M25,19 L16,19 L16,17 L25,17 L25,19 L25,19 Z" id="ytp-id-68"></path></svg>';
                } else {
                    ass.show();
                    danmuEnabled = true;
                    danmuButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%" fill-opacity="1"><path d="M11,11 C9.9,11 9,11.9 9,13 L9,23 C9,24.1 9.9,25 11,25 L25,25 C26.1,25 27,24.1 27,23 L27,13 C27,11.9 26.1,11 25,11 L11,11 Z M11,17 L14,17 L14,19 L11,19 L11,17 L11,17 Z M20,23 L11,23 L11,21 L20,21 L20,23 L20,23 Z M25,23 L22,23 L22,21 L25,21 L25,23 L25,23 Z M25,19 L16,19 L16,17 L25,17 L25,19 L25,19 Z" fill="#fff"></path></svg>';
                }
            });

            fetch(subtitleSrc)
                .then(res => res.text())
                .then((text) => {
                    ass = new ASS(text, video, {
                        container: assContainer,
                        resampling: 'video_width',
                    });
                });
        }
        // i like yt

        video.addEventListener("ended", async function (event) {
            await setTime(videoData, 0, true, true);
            ended = true;
            var nextEpisode = (Number(videoData.episode) + 1).toString();
            var nextObj = videoSeries.find(value => value.episode == nextEpisode);
            if (nextObj) {
                // todo: display message and countdown
                endText.innerText = "5秒後自動播放下一集"
                endNextButton.addEventListener("click", () => {
                    window.location.href = "./watch?id=" + nextObj.sn + "&res=" + nextObj.resolution;
                })
                endNextButton.style.display = "block";
                endCancelButton.addEventListener("click", () => {
                    endBox.style.display = "none";
                    overlay.style.display = "none";
                    clearInterval(countdownInterval);
                })
                endCancelButton.style.display = "block";
                var countdown = 5;
                var countdownInterval = setInterval(() => {
                    countdown--;
                    endText.innerText = countdown + "秒後自動播放下一集";
                    if (countdown <= 0) {
                        clearInterval(countdownInterval);
                        endText.innerText = "正在載入下一集...";
                        window.location.href = "./watch?id=" + nextObj.sn + "&res=" + nextObj.resolution;
                    }
                }, 1000);
            } else {
                endText.innerText = "您已播放至最後一集。";
                endNextButton.style.display = "none";
                endCancelButton.addEventListener("click", () => {
                    endBox.style.display = "none";
                    overlay.style.display = "none";
                })
                endCancelButton.innerText = "關閉";
                endCancelButton.style.display = "block";
            }
            endBox.style.display = "block";
            overlay.style.display = "block";
        });

        if (isMobileDevice()) {
            widthsize = '100';
        } else {
            widthsize = '70';
        }
        videoPlayer.style.width = widthsize + '%';
        video.style.width = '100%';

        document.addEventListener('fullscreenchange', function () {
            speedDropdown.style.display = 'none';
            isFullscreen = !isFullscreen;
            if (isFullscreen) {
                videoPlayer.classList.add('fullscreen');
                video.style.width = '100%';
                video.style.height = '100%';
            } else {
                videoPlayer.classList.remove('fullscreen');
                var finalWidth = window.innerWidth * (widthsize / 100);
                var finalHeight = finalWidth / 16 * 9;
                video.style.width = finalWidth + 'px';
                video.style.height = finalHeight + 'px';
            }
        });


        function showControls() {
            clearTimeout(controlsTimeout);
            videoPlayer.classList.add('show-controls');
            controlsTimeout = setTimeout(hideControls, 5000);
            videoPlayer.style.cursor = 'auto';
        }

        function hideControls() {
            if (!video.paused) {
                videoPlayer.classList.remove('show-controls');
                videoPlayer.style.cursor = 'none';
            }
        }

        var finalWidth = window.innerWidth * (widthsize / 100);
        var finalHeight = finalWidth / 16 * 9;
        video.style.width = finalWidth + 'px';
        video.style.height = finalHeight + 'px';
        window.addEventListener("resize", function () {
            speedDropdown.style.display = 'none';
            if (isFullscreen) {
                video.style.width = '100%';
                video.style.height = '100%';
            } else {
                var finalWidth = window.innerWidth * (widthsize / 100);
                var finalHeight = finalWidth / 16 * 9;
                video.style.width = finalWidth + 'px';
                video.style.height = finalHeight + 'px';
            }
            //videoPlayer.style.width = finalWidth + 'px';
            //videoPlayer.style.height = finalHeight + 'px';
        });

        let lastFullscreen = 0;

        function toggleFullscreen() {
            const currentTime = new Date().getTime();
            lastFullscreen = currentTime;
            if (!isFullscreen) {
                if (videoPlayer.requestFullscreen) {
                    videoPlayer.requestFullscreen();
                } else if (videoPlayer.mozRequestFullScreen) {
                    videoPlayer.mozRequestFullScreen();
                } else if (videoPlayer.webkitRequestFullscreen) {
                    videoPlayer.webkitRequestFullscreen();
                } else if (videoPlayer.msRequestFullscreen) {
                    videoPlayer.msRequestFullscreen();
                }
                try {
                    screen.orientation.lock("landscape-primary");
                } catch (e) { }
            } else {
                // try {
                //     screen.orientation.lock("portrait-primary");
                // } catch (e) { }
                if (document.exitFullscreen) {
                    document.exitFullscreen();
                } else if (document.mozCancelFullScreen) {
                    document.mozCancelFullScreen();
                } else if (document.webkitExitFullscreen) {
                    document.webkitExitFullscreen();
                } else if (document.msExitFullscreen) {
                    document.msExitFullscreen();
                }
                video.style.height = null;
                video.style.width = '100%';
            }
        };

        fullscreenButton.addEventListener('click', function () {
            toggleFullscreen();
        });

        function handleMouseEnter() {
            if (!isMobileDevice()) {
                showControls();
            }
        }

        function handleMouseLeave() {
            if (!isMobileDevice()) {
                hideControls();
            }
        }

        function handleTouchStart(event) {
            if (isMobileDevice()) {
                // Prevent hiding controls if the touch is on a button
                if (event.target.tagName === 'BUTTON' || event.target.closest('button')) {
                    return;
                }
                if (videoPlayer.classList.contains('show-controls')) {
                    hideControls();
                } else {
                    showControls();
                }
            }
        }

        function handleMouseMove() {
            if (!isMobileDevice()) {
                showControls();
            }
        }

        function sleep(ms) {
            return new Promise(resolve => setTimeout(resolve, ms));
        }

        function isMobileDevice() {
            return /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
        }

        function syncTime(time) {
            const dt = convertTime(video.duration);
            const ct = convertTime(video.currentTime);
            timetext.innerHTML = ct + '/' + dt;
            ended = (video.currentTime >= video.duration - 10)
            setTime(videoData.sn, time, ended);
        }

        videoPlayer.addEventListener('mouseenter', handleMouseEnter);
        videoPlayer.addEventListener('mousemove', handleMouseMove);
        videoPlayer.addEventListener('mouseleave', handleMouseLeave);
        videoPlayer.addEventListener('touchstart', handleTouchStart);

        // 定義雙擊事件的處理邏輯
        let lastTap = 0; // 用於記錄上次點擊的時間
        const doubleTapThreshold = 300; // 雙擊的時間間隔（毫秒）

        videoPlayer.addEventListener('touchend', function (event) {
            const currentTime = new Date().getTime();
            const tapInterval = currentTime - lastTap;

            if (tapInterval < doubleTapThreshold && tapInterval > 0) {
                // 確定點擊位置
                const touchX = event.changedTouches[0].clientX;
                const screenWidth = window.innerWidth;

                if (touchX < screenWidth / 3) {
                    // 點擊左側，執行 skipBackward
                    skipBackward();
                } else if (touchX < screenWidth / 3 * 2) {
                    // middle toggle play
                    togglePlayPause();
                } else {
                    // 點擊右側，執行 skipForward
                    skipForward();
                }
            }

            lastTap = currentTime; // 更新上次點擊的時間
        });

        // mobile fullscreen things
        // https://stackoverflow.com/a/6603537
        if (isMobileDevice()) {
            function getOrientation() {
                if (screen.orientation) {
                    var windowOrientation = screen.orientation.angle;
                } else {
                    var windowOrientation = window.orientation;
                }
                return windowOrientation;
            }

            var previousOrientation = getOrientation();
            var checkOrientation = function () {
                if (getOrientation !== previousOrientation) {
                    previousOrientation = getOrientation();
                    if (Math.abs(previousOrientation) == 90) {
                        const currentTime = new Date().getTime();
                        if (!isFullscreen && currentTime - lastFullscreen >= 300) {
                            toggleFullscreen();
                        }
                    }
                }
            };

            window.addEventListener("resize", checkOrientation, false);
            window.addEventListener("orientationchange", checkOrientation, false);

        }

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
            videoListItem.appendChild(videoLink);
            videoListe.appendChild(videoListItem);
        }

        categorybox.appendChild(videoListe);
        if (isMobileDevice()) {
            document.body.appendChild(categorybox);
            document.querySelectorAll('.animeCategoryTitle').forEach(title => {
                title.addEventListener('click', function () {
                    var list = this.nextElementSibling;

                    if (list.style.display === "block") {
                        list.style.display = "none";
                    } else {
                        list.style.display = "block";
                    }
                });
            });
        } else {
            categorybox.classList.add('animeWatchingCategory');
            categoryTitle.classList.add('animeWatchingTitle');
            videoListe.classList.add('animeWatchingEpisodeList');
            document.getElementById("anotherVideoBox").appendChild(categorybox);
            videoListe.style.display = "block";
            var finalWidth = window.innerWidth * (widthsize / 100);
            var finalHeight = (finalWidth / 16 * 9) - 75;
            videoListe.style.height = finalHeight + "px";
            window.addEventListener("resize", function () {
                var finalWidth = window.innerWidth * (widthsize / 100);
                var finalHeight = (finalWidth / 16 * 9) - 75;
                videoListe.style.height = finalHeight + "px";
            });
        }

        var videoDetail = document.createElement("div");
        var videoTitle = document.createElement("h2");
        var videoSource = document.createElement("p");
        videoTitle.innerText = videoData.title;
        document.title = videoData.title + " | aGP+";
        if (videoData.source == "巴哈姆特動畫瘋") {
            videoSource.innerHTML = '來源：<a href="https://ani.gamer.com.tw/animeVideo.php?sn=' + videoData.sn + '">巴哈姆特動畫瘋</a>';
        } else {
            videoSource.innerText = '來源：' + videoData.source;
        }
        videoDetail.appendChild(videoTitle);
        videoDetail.appendChild(videoSource);
        document.body.appendChild(videoDetail);
    } else {
        var searchBox = document.createElement("div");
        searchBox.classList.add('row');
        searchBox.classList.add('setting-content');
        var searchInput = document.createElement("input");
        searchInput.type = "search";
        searchInput.classList.add('form-control');
        searchInput.placeholder = "搜尋動漫...";
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
        document.body.appendChild(searchBox);

        document.body.appendChild(document.createElement("hr"));

        var loadingBar = document.createElement("div");
        loadingBar.classList.add('row');
        loadingBar.classList.add('setting-content');
        loadingBar.style.display = "flex";
        loadingBar.style.justifyContent = "center";
        loadingBar.innerHTML = '<div id="progdiv" class="progress"><div id="prog" class="progress-bar progress-bar-striped progress-bar-animated" role="progressbar" aria-valuenow="1" aria-valuemin="0" aria-valuemax="1" style="width: 100%">載入清單中...</div></div>';
        document.body.appendChild(loadingBar);

        // get watched time
        var watchedTimes = await getAllTimes();

        // 載入影片清單
        var data = await getVideoList();
        var videos = data.videos;

        // get "巴哈姆特動畫瘋" source last 10 videos
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
        // get user watched videos if exists
        var lastBahamutWatchedVideos = []
        for (var i = 0; i < lastBahamutVideos.length; i++) {
            var videoItem = lastBahamutVideos[i];
            var videoSeries = await getVideoSeries(videoItem.sn);
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
            })
            lastWatchAnimeGroups = Object.values(lastWatchAnimeGroups);
            var foundVideo;
            for (var j = 0; j < videoSeries.length; j++) {
                var videoSeriesItem = videoSeries[j];
                foundVideo = userWatchedVideos.find(video => video.sn == videoSeriesItem.sn);
                if (foundVideo) {
                    break;
                }
            }
            if (foundVideo) {
                foundVideo.originalEpisode = videoItem.episode;
                lastBahamutWatchedVideos.push(foundVideo);
            } else {
                videoItem.originalEpisode = videoItem.episode;
                lastBahamutWatchedVideos.push(videoItem);
            }
        }

        // get user watched videos
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
            })
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
            document.body.appendChild(watchedVideoBox);
            var limit = 10;
            for (var anime in lastWatchAnimeGroups) {
                limit--;
                if (limit < 0) {
                    break;
                }
                var videoItem = lastWatchAnimeGroups[anime];
                if (!videoItem) {
                    break;
                }
                var videoId = videoItem.sn;
                var videoTitle = videoItem.anime_name;

                // 創建影片清單項目
                var videoListItem = document.createElement('li');
                videoListItem.classList.add('animeEpisodeItem');

                // 創建影片連結
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
                            //watchedText.textContent = "看完了";
                            limit++;
                            videoListItem.remove();
                            watchedText.remove();
                            continue;
                        }
                    } else {
                        watchedText.textContent = "看到第 " + videoItem.episode + " 集 " + convertTime(watchedTimes[videoId].time);
                    }
                    videoListItem.appendChild(watchedText);
                }

                watchedVideoList.appendChild(videoListItem);
            }
            if (!lastBahamutVideos) {
                document.body.appendChild(document.createElement("hr"));
            }
        }

        // 顯示巴哈姆特動畫瘋的最新影片
        if (lastBahamutWatchedVideos && lastBahamutVideos.length > 0) {
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
            document.body.appendChild(lastBahamutBox);
            for (var i = 0; i < lastBahamutVideos.length; i++) {
                var videoItem = lastBahamutVideos[i];
                var videoId = videoItem.sn;
                var videoTitle = videoItem.anime_name;

                // 創建影片清單項目
                var videoListItem = document.createElement('li');
                videoListItem.classList.add('animeEpisodeItem');

                // 創建影片連結
                var videoLink = document.createElement('a');
                videoLink.href = './watch?id=' + encodeURIComponent(videoId) + '&res=' + encodeURIComponent(videoItem.resolution);
                videoLink.textContent = `${videoTitle}`;
                videoListItem.appendChild(videoLink);

                var watchedText = document.createElement('p');
                watchedText.classList.add('watchedText');
                if (watchedTimes[videoId]) {
                    if (watchedTimes[videoId].ended) {
                        var videoSeries = await getVideoSeries(videoId);
                        var nextEpisode = (Number(videoItem.episode) + 1).toString();
                        var videoSeriesItem = videoSeries.find(video => video.episode == nextEpisode);
                        if (videoSeriesItem) {
                            videoLink.href = './watch?id=' + encodeURIComponent(videoSeriesItem.sn) + '&res=' + encodeURIComponent(videoSeriesItem.resolution);
                            if (videoSeriesItem.episode == videoItem.episode && videoItem.episode == videoItem.originalEpisode) {
                                watchedText.textContent = "更新至第 " + videoItem.originalEpisode + " 集";
                            } else {
                                watchedText.textContent = "更新至 " + videoItem.originalEpisode + " 集，看到 " + videoSeriesItem.episode + " 集";
                            }
                        } else {
                            watchedText.textContent = "看完了";
                        }
                    } else {
                        if (videoItem.episode == videoItem.originalEpisode) {
                            watchedText.textContent = "看到第 " + videoItem.episode + " 集 " + convertTime(watchedTimes[videoId].time);
                        } else {
                            watchedText.textContent = "更新至 " + videoItem.originalEpisode + " 集，看到 " + videoItem.episode + " 集 " + convertTime(watchedTimes[videoId].time);
                        }
                    }
                } else {
                    watchedText.textContent = "更新至 " + videoItem.originalEpisode + " 集";
                }
                videoListItem.appendChild(watchedText);
                lastBahamutList.appendChild(videoListItem);
            }
            document.body.appendChild(document.createElement("hr"));
        }


        // 分類影片
        var videoGroups = {};
        for (var i = 0; i < videos.length; i++) {
            var video = videos[i];
            var category = video.anime_name;

            if (!videoGroups[category]) {
                videoGroups[category] = [];
            }

            videoGroups[category].push(video);
        }

        // 顯示影片清單
        for (var category in videoGroups) {
            var videosInCategory = videoGroups[category];
            videosInCategory.sort((a, b) => a.episode - b.episode);
            var categorybox = document.createElement('div');
            categorybox.classList.add('animeCategory');
            categorybox.classList.add('row');

            // 創建分類標題
            var categoryTitle = document.createElement('h2');
            categoryTitle.classList.add('animeCategoryTitle');
            categoryTitle.textContent = category;
            categorybox.appendChild(categoryTitle);

            // 創建影片清單
            var videoList = document.createElement('ul');
            videoList.classList.add('animeEpisodeList');


            for (var j = 0; j < videosInCategory.length; j++) {
                var videoItem = videosInCategory[j];
                var videoId = videoItem.sn;
                var videoTitle = videoItem.title;

                // 創建影片清單項目
                var videoListItem = document.createElement('li');
                videoListItem.classList.add('animeEpisodeItem');

                // 創建影片連結
                var videoLink = document.createElement('a');
                videoLink.href = './watch?id=' + encodeURIComponent(videoId) + '&res=' + encodeURIComponent(videoItem.resolution);
                videoLink.textContent = `第 ${videoItem.episode} 集`;
                videoListItem.appendChild(videoLink);

                if (watchedTimes[videoId]) {
                    var watchedText = document.createElement('p');
                    watchedText.classList.add('watchedText');
                    if (watchedTimes[videoId].ended) {
                        watchedText.textContent = "看完了";
                    } else {
                        watchedText.textContent = "看到 " + convertTime(watchedTimes[videoId].time);
                    }
                    videoListItem.appendChild(watchedText);
                }

                videoList.appendChild(videoListItem);
            }

            // 將影片清單加入分類
            categorybox.appendChild(videoList);
            document.body.appendChild(categorybox)
        }
        document.querySelectorAll('.animeCategoryTitle').forEach(title => {
            title.addEventListener('click', function () {
                var list = this.nextElementSibling;

                if (list.style.display === "block") {
                    list.style.display = "none";
                } else {
                    list.style.display = "block";
                }
            });
        });
        loadingBar.remove();
    }
}