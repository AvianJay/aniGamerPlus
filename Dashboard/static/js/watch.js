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

try {
    var login = getCookieByName('logined');
    if (login = 'true') {

    } else if (login = 'false') {

    } else {
        document.cookie = 'logined=false';
    }
} catch (err) {
    document.cookie = 'logined=false';
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

async function main() {
    var urlParams = new URLSearchParams(window.location.search);
    var videoId = urlParams.get('id');
    var videoResolution = urlParams.get('res');
    if (videoId && videoResolution) {
        var videoData = await fetchVideoData(videoId);
        var videoSrc = './getvid.mp4?id=' + encodeURIComponent(videoId) + '&res=' + videoResolution;
        var subtitleSrc = './getsub.ass?id=' + encodeURIComponent(videoId);
        var videoPlayer = document.getElementById('videobox');
        var video = document.createElement('video');
        var ctrldiv = document.createElement('div');
        var playPauseButton = document.createElement('button');
        playPauseButton.setAttribute("id", "playPauseButton");
        playPauseButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%"><path d="M 12,26 18.5,22 18.5,14 12,10 z M 18.5,22 25,18 25,18 18.5,14 z"></path></svg>';
        var fullscreenButton = document.createElement('button');
        fullscreenButton.setAttribute("id", "fullscreenButton");
        fullscreenButton.innerHTML = '<svg height="100%" version="1.1" viewBox="0 0 36 36" width="100%"><g class="ytp-fullscreen-button-corner-0"><use class="ytp-svg-shadow" xlink:href="#ytp-id-7"></use><path class="ytp-svg-fill" d="m 10,16 2,0 0,-4 4,0 0,-2 L 10,10 l 0,6 0,0 z" id="ytp-id-7"></path></g><g class="ytp-fullscreen-button-corner-1"><use class="ytp-svg-shadow" xlink:href="#ytp-id-8"></use><path class="ytp-svg-fill" d="m 20,10 0,2 4,0 0,4 2,0 L 26,10 l -6,0 0,0 z" id="ytp-id-8"></path></g><g class="ytp-fullscreen-button-corner-2"><use class="ytp-svg-shadow" xlink:href="#ytp-id-9"></use><path class="ytp-svg-fill" d="m 24,24 -4,0 0,2 L 26,26 l 0,-6 -2,0 0,4 0,0 z" id="ytp-id-9"></path></g><g class="ytp-fullscreen-button-corner-3"><path class="ytp-svg-fill" d="M 12,20 10,20 10,26 l 6,0 0,-2 -4,0 0,-4 0,0 z"></path></g></svg>';
        var volumeSlider = document.createElement('input');
        volumeSlider.setAttribute("id", "volumeSlider");
        volumeSlider.setAttribute("type", "range");
        volumeSlider.setAttribute("min", "0");
        volumeSlider.setAttribute("max", "1");
        volumeSlider.setAttribute("step", "0.01");
        volumeSlider.setAttribute("value", "1");
        var timeSlider = document.createElement('input');
        timeSlider.setAttribute("id", "timeSlider");
        timeSlider.setAttribute("type", "range");
        timeSlider.setAttribute("min", "0");
        timeSlider.setAttribute("max", "100");
        timeSlider.setAttribute("step", "1");
        timeSlider.value = 0;
        volumeSlider.setAttribute("type", "range");
        volumeSlider.setAttribute("min", "0");
        var timetext = document.createElement('a');
        timetext.innerText = "..."
        var isFullscreen = false;
        ctrldiv.setAttribute("id", "controls");
        video.setAttribute("id", "player");
        video.setAttribute("src", videoSrc);
        video.controls = false;
        video.setAttribute("preload", "metadata");
        videoPlayer.appendChild(video);
        var assContainer = document.createElement("div");
        assContainer.setAttribute("id", "ass-container");
        videoPlayer.appendChild(assContainer);
        var loadingSpinner = document.createElement("div")
        loadingSpinner.setAttribute("id", "loading-spinner")
        videoPlayer.appendChild(loadingSpinner)
        loadingSpinner.style.display = 'block';
        ctrldiv.appendChild(playPauseButton);
        ctrldiv.appendChild(volumeSlider);
        ctrldiv.appendChild(timeSlider);
        ctrldiv.appendChild(timetext);
        if (videoData.danmu) {
        var danmuButton = document.createElement('button');
        danmuButton.setAttribute("id", "danmuButton");
        danmuButton.innerHTML = '<svg class="ytp-subtitles-button-icon" height="100%" version="1.1" viewBox="0 0 36 36" width="100%" fill-opacity="1"><use class="ytp-svg-shadow" xlink:href="#ytp-id-68"></use><path d="M11,11 C9.9,11 9,11.9 9,13 L9,23 C9,24.1 9.9,25 11,25 L25,25 C26.1,25 27,24.1 27,23 L27,13 C27,11.9 26.1,11 25,11 L11,11 Z M11,17 L14,17 L14,19 L11,19 L11,17 L11,17 Z M20,23 L11,23 L11,21 L20,21 L20,23 L20,23 Z M25,23 L22,23 L22,21 L25,21 L25,23 L25,23 Z M25,19 L16,19 L16,17 L25,17 L25,19 L25,19 Z" fill="#fff" id="ytp-id-68"></path></svg>';
        ctrldiv.appendChild(danmuButton);
        }
        ctrldiv.appendChild(fullscreenButton);
        videoPlayer.appendChild(ctrldiv);
        var controlsTimeout;
        var widthsize;
        var danmuEnabled = true;
        var ass;


        playPauseButton.addEventListener('click', function () {
            if (video.paused) {
                video.play();
            } else {
                video.pause();
            }
        });


        volumeSlider.addEventListener('input', function () {
            video.volume = volumeSlider.value;
        });

        video.addEventListener('timeupdate', function () {
            timeSlider.value = video.currentTime;
            const dh = Math.floor(video.duration / 60);
            const dm = Math.round(video.duration % 60);
            const dt = `${dh.toString().padStart(2, '0')}:${dm.toString().padStart(2, '0')}`;
            const ch = Math.floor(video.currentTime / 60);
            const cm = Math.round(video.currentTime % 60);
            const ct = `${ch.toString().padStart(2, '0')}:${cm.toString().padStart(2, '0')}`;
            timetext.innerHTML = ct + '/' + dt
            syncTime(video.currentTime);
        });

        timeSlider.addEventListener('input', function () {
            video.currentTime = timeSlider.value;
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
            }
        });

        function togglePlayPause() {
            if (video.paused) {
                video.play();
            } else {
                video.pause();
            }
        }

        function skipBackward() {
            video.currentTime -= 10; // 倒退10秒
        }

        function skipForward() {
            video.currentTime += 10; // 快轉10秒
        }


        video.addEventListener('loadedmetadata', function () {
            timeSlider.max = video.duration;
            timeSlider.value = 0;
            const dh = Math.floor(video.duration / 60);
            const dm = Math.round(video.duration % 60);
            const dt = `${dh.toString().padStart(2, '0')}:${dm.toString().padStart(2, '0')}`;
            const ch = Math.floor(video.currentTime / 60);
            const cm = Math.round(video.currentTime % 60);
            const ct = `${ch.toString().padStart(2, '0')}:${cm.toString().padStart(2, '0')}`;
            timetext.innerHTML = ct + '/' + dt
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

        if (isMobileDevice()) {
            widthsize = '100';
        } else {
            widthsize = '70';
        }
        videoPlayer.style.width = widthsize + '%';
        video.style.width = '100%';

        document.addEventListener('fullscreenchange', function () {
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
            videoPlayer.classList.remove('show-controls');
            videoPlayer.style.cursor = 'none';
        }

        window.addEventListener("resize", function () {
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

        function toggleFullscreen() {
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
                try {
                    screen.orientation.lock("portrait-primary");
                } catch (e) { }
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

        function handleTouchStart() {
            if (isMobileDevice()) {
                showControls();
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
            if (getCookieByName('logined') == 'true') {
                fetch('/time?id=' + videoId + '&type=send&time=' + time);
            };
        }

        videoPlayer.addEventListener('mouseenter', handleMouseEnter);
        videoPlayer.addEventListener('mousemove', handleMouseMove);
        videoPlayer.addEventListener('mouseleave', handleMouseLeave);
        videoPlayer.addEventListener('touchstart', handleTouchStart);

        // mobile fullscreen things
        // https://stackoverflow.com/a/6603537
        if (isMobileDevice()) {
        var previousOrientation = window.orientation;
var checkOrientation = function(){
    if(window.orientation !== previousOrientation){
        previousOrientation = window.orientation;
        if (Math.abs(previousOrientation) == 90) {
            if (!isFullscreen) {
                toggleFullscreen();
            }
        }
    }
};

window.addEventListener("resize", checkOrientation, false);
window.addEventListener("orientationchange", checkOrientation, false);

        }

        videoDetail = document.createElement("div");
        videoTitle = document.createElement("h2");
        videoSource = document.createElement("p");
            videoTitle.innerText = videodata.title;
            document.title = videodata.title + " | aGP+";
            if (videodata.source == "巴哈姆特動畫瘋") {
                videoSource.innerHTML = '來源：<a href="https://ani.gamer.com.tw/animeVideo.php?sn=' + videodata.sn + '">巴哈姆特動畫瘋</a>';
            } else {
                videoSource.innerText = '來源：' + videodata.source;
            }
            videoDetail.appendChild(videoTitle);
            videoDetail.appendChild(videoSource);
            document.body.appendChild(document.createElement("br"));
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
                var query = event.target.value;
                Array.prototype.forEach.call(document.getElementsByClassName("animeCategory"), (category) => {
                    var name = category.getElementsByTagName("h2")[0].textContent;
                    if (name.includes(query)) {
                        category.style.display = "block";
                    } else {
                        category.style.display = "none";
                    }
                });
            });
        searchBox.appendChild(searchInput);
        document.body.appendChild(searchBox);
        // 載入影片清單
        var data = await getVideoList();
        var videos = data.videos;

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

                // 創建影片連結
                var videoLink = document.createElement('a');
                videoLink.href = './watch?id=' + encodeURIComponent(videoId) + '&res=' + encodeURIComponent(videoItem.resolution);
                videoLink.textContent = videoTitle;
                // var videodlLink = document.createElement('a');
                // videodlLink.href = '/getvid.mp4?id=' + encodeURIComponent(videoId) + '&res=' + encodeURIComponent(videoItem.resolution);
                // videodlLink.textContent = '[下載]';

                // 創建影片清單項目
                var videoListItem = document.createElement('li');
                videoListItem.appendChild(videoLink);
                // videoListItem.appendChild(videodlLink);
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
    }
}