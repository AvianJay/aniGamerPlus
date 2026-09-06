/* ---------------------------------------------------------------------------
   aniGamerPlus+ — home page
   Turns video_list.json plus the per-user watch positions into the banner,
   the "continue watching" rail, the update timetable and the library grids.
   --------------------------------------------------------------------------- */
(function (global) {
    'use strict';

    var AGP = global.AGP;
    var dashboardApi = global.dashboardApi || {};
    /* Shared with catalog.js -- see AGP.sectionHtml in agp-shell.js. */
    var sectionHtml = AGP.sectionHtml;
    var railHtml = AGP.railHtml;

    var TIMETABLE_DAYS = 7;

    var state = {
        videos: [],
        animes: [],
        byAnime: {},
        times: {},
        query: ''
    };

    function isLoggedIn() {
        return dashboardApi.isLoggedIn ? dashboardApi.isLoggedIn() : false;
    }

    /* ./login is only registered when dashboard.user_control is on. A site that
       gates the library with online_watch_requires_login alone has no login page
       to send anyone to, and a 404 is a worse dead end than no button. */
    function hasLoginPage() {
        var info = dashboardApi.getServerInfoSnapshot ? dashboardApi.getServerInfoSnapshot() : null;
        return !!(info && info.user_control);
    }

    /* groupByAnime() files every episode under this key, so anything looking a
       title back up has to derive the key the same way or it misses the group. */
    function animeKey(video) {
        return video.anime_name || '未命名';
    }

    function episodeNumber(video) {
        var value = parseFloat(video.episode);
        return isNaN(value) ? 0 : value;
    }

    function episodeLabel(video) {
        var value = String(video.episode === undefined || video.episode === null ? '' : video.episode).trim();
        if (!value) { return '單集'; }
        return /^[0-9.]+$/.test(value) ? '第 ' + value + ' 集' : value;
    }

    function watchUrl(video) {
        return './watch?id=' + encodeURIComponent(video.sn) +
            (video.resolution ? '&res=' + encodeURIComponent(video.resolution) : '');
    }

    function progressOf(video) {
        var entry = state.times[String(video.sn)];
        if (!entry) { return null; }
        var seconds = Number(entry.time) || 0;
        if (entry.ended) { return { seconds: 0, ratio: 1, done: true, updated: entry.timestamp || 0 }; }
        if (seconds <= 0) { return null; }
        var duration = Number(entry.duration) || 0;
        /* Positions saved before the player reported durations carry no total,
           and a guessed one draws a bar that is confidently wrong -- a 40 minute
           mark in a 劇場版 would look finished. No total, no bar. */
        return {
            seconds: seconds,
            duration: duration,
            ratio: duration > 0 ? Math.min(0.98, seconds / duration) : null,
            remaining: duration > 0 ? Math.max(0, duration - seconds) : null,
            done: false,
            updated: entry.timestamp || 0
        };
    }

    /* --- markup ------------------------------------------------------------ */

    function artStyle(name) {
        return 'background:' + AGP.artFor(name) + ';';
    }

    /* video_list.json carries no artwork, so a title starts as a generated
       gradient plate. /thumbnail.jpg pulls a real frame out of the episode on
       disk and layers it over that plate; anything the server cannot grab a
       frame for 404s, the <img> is dropped, and the plate stays visible. */
    function thumbImg(video) {
        if (!video || !video.sn) { return ''; }
        return '<img class="agp-art-img" alt="" loading="lazy" src="./thumbnail.jpg?id=' +
            AGP.escapeHtml(encodeURIComponent(video.sn)) + '">';
    }

    function plate(video, name) {
        return '<span class="agp-card-art-fill" style="' + artStyle(name) + '"></span>' +
            '<span class="agp-card-art-glyph">' + AGP.escapeHtml(AGP.initials(name)) + '</span>' +
            thumbImg(video);
    }

    function episodeCard(video, options) {
        var opts = options || {};
        var progress = opts.progress === undefined ? progressOf(video) : opts.progress;
        var meta = [];

        if (video.resolution) {
            meta.push('<span>' + AGP.escapeHtml(video.resolution) + 'P</span>');
        }
        if (video.danmu) {
            meta.push('<span>' + AGP.icon('danmaku', 13) + '彈幕</span>');
        }
        if (video.timestamp) {
            meta.push('<span>' + AGP.icon('clock', 13) + AGP.dayLabel(video.timestamp).title + '</span>');
        }

        var overlay = '';
        if (progress && !progress.done && progress.ratio !== null) {
            overlay = '<span class="agp-card-progress"><i style="width:' +
                (progress.ratio * 100).toFixed(1) + '%"></i></span>';
        }

        var badge = opts.badge !== undefined ? opts.badge : AGP.clockOf(video.timestamp);

        return '<a class="agp-card" href="' + AGP.escapeHtml(watchUrl(video)) + '" data-sn="' +
            AGP.escapeHtml(video.sn) + '">' +
            '<span class="agp-card-art">' + plate(video, animeKey(video)) +
            '<span class="agp-card-ep">' + AGP.escapeHtml(episodeLabel(video)) + '</span>' +
            (badge ? '<span class="agp-card-badge">' + AGP.escapeHtml(badge) + '</span>' : '') +
            overlay +
            '</span>' +
            '<span class="agp-card-title">' + AGP.escapeHtml(animeKey(video)) + '</span>' +
            '<span class="agp-card-meta">' + meta.join('') + '</span>' +
            '</a>';
    }

    function posterCard(anime, rank) {
        var latest = anime.latest;
        return '<a class="agp-poster" href="' + AGP.escapeHtml(watchUrl(latest)) + '">' +
            '<span class="agp-poster-art" style="' + artStyle(anime.name) + '">' +
            '<span class="agp-card-art-glyph">' + AGP.escapeHtml(AGP.initials(anime.name)) + '</span>' +
            thumbImg(latest) +
            (rank ? '<span class="agp-poster-rank">' + rank + '</span>' : '') +
            '</span>' +
            '<span class="agp-poster-foot"><strong>' + AGP.escapeHtml(anime.name) + '</strong>' +
            '<small>共 ' + anime.videos.length + ' 集 · 更新至 ' + AGP.escapeHtml(episodeLabel(latest)) + '</small>' +
            '</span></a>';
    }

    /* --- sections ---------------------------------------------------------- */

    function renderBanner() {
        var host = document.getElementById('homeBanner');
        if (!host) { return; }
        var anime = state.animes[0];
        if (!anime) {
            host.innerHTML = '';
            return;
        }
        host.innerHTML = '<a class="agp-banner" href="' + AGP.escapeHtml(watchUrl(anime.latest)) + '">' +
            '<span class="agp-banner-art" style="' + artStyle(anime.name) + '">' +
            thumbImg(anime.latest) + '</span>' +
            '<span class="agp-banner-body">' +
            '<span class="agp-eyebrow" style="display:block">最新更新</span>' +
            '<h2>' + AGP.escapeHtml(anime.name) + '</h2>' +
            '<span class="agp-banner-sub" style="display:block">更新至 ' +
            AGP.escapeHtml(episodeLabel(anime.latest)) + ' · 共 ' + anime.videos.length + ' 集 · ' +
            AGP.escapeHtml(anime.latest.source || '本機片庫') + '</span>' +
            '<span class="agp-btn">' + AGP.icon('play', 16) + ' 立即觀看</span>' +
            '</span></a>';
    }

    function renderNotice() {
        var host = document.getElementById('homeNotice');
        if (!host) { return; }
        var newest = state.videos.length ? state.videos[0].timestamp : 0;
        var label = newest ? AGP.dayLabel(newest) : null;
        host.querySelector('span').textContent = '片庫收錄 ' + state.animes.length + ' 部作品、' +
            state.videos.length + ' 集' + (label ? ('，最後更新於 ' + label.title + ' ' + AGP.clockOf(newest)) : '') + '。';
    }

    function renderContinue() {
        var host = document.getElementById('homeContinue');
        if (!host) { return; }

        var items = state.videos
            .map(function (video) { return { video: video, progress: progressOf(video) }; })
            .filter(function (item) { return item.progress && !item.progress.done; })
            .sort(function (a, b) { return b.progress.updated - a.progress.updated; })
            .slice(0, 20);

        /* The tab strip always links to #continue, so the section has to exist
           even when there is nothing in it. */
        if (!items.length) {
            host.innerHTML = sectionHtml('continue', '繼續觀看',
                '<p class="agp-empty">' + (isLoggedIn()
                    ? '還沒有看到一半的影片。'
                    : '登入後即可跨裝置同步觀看進度。') + '</p>');
            return;
        }

        var cards = items.map(function (item) {
            var video = item.video;
            var progress = item.progress;
            var remaining = progress.remaining !== null
                ? '剩餘 ' + Math.max(1, Math.round(progress.remaining / 60)) + ' 分'
                : '已看到 ' + AGP.formatClock(progress.seconds);
            var anime = state.byAnime[animeKey(video)];
            var next = (anime ? anime.videos : []).filter(function (candidate) {
                return episodeNumber(candidate) > episodeNumber(video);
            }).sort(function (a, b) { return episodeNumber(a) - episodeNumber(b); })[0];

            return '<div class="agp-continue-item">' +
                episodeCard(video, { progress: progress, badge: remaining }) +
                (next ? '<a class="agp-continue-next" href="' + AGP.escapeHtml(watchUrl(next)) + '">下一集 ' +
                    AGP.icon('play', 12) + '</a>' : '') +
                '</div>';
        }).join('');

        host.innerHTML = sectionHtml('continue', '繼續觀看', railHtml(cards, 'railContinue'));
        host.querySelectorAll('.agp-rail-wrap').forEach(AGP.wireRail);
    }

    function renderTimetable() {
        var host = document.getElementById('homeTimetable');
        if (!host) { return; }

        var groups = [];
        var index = {};
        state.videos.forEach(function (video) {
            var key = AGP.dayKey(video.timestamp);
            if (!index[key]) {
                index[key] = { key: key, timestamp: video.timestamp, videos: [] };
                groups.push(index[key]);
            }
            index[key].videos.push(video);
        });

        var body = groups.slice(0, TIMETABLE_DAYS).map(function (group) {
            var label = AGP.dayLabel(group.timestamp);
            var cards = group.videos.slice(0, 20).map(function (video) {
                return episodeCard(video);
            }).join('');
            return '<div class="agp-day">' +
                '<div class="agp-day-head"><strong>' + AGP.escapeHtml(label.title) + '</strong>' +
                '<em>' + AGP.escapeHtml(label.sub) + '</em>' +
                '<span>' + group.videos.length + ' 集更新</span></div>' +
                railHtml(cards, 'rail-' + group.key) +
                '</div>';
        }).join('');

        host.innerHTML = sectionHtml('library-updates', '片庫更新',
            body || '<p class="agp-empty">片庫還沒有任何影片，先到主控台加入追番清單吧。</p>',
            './control', '前往主控台');
        host.querySelectorAll('.agp-rail-wrap').forEach(AGP.wireRail);
    }

    function renderHot() {
        var host = document.getElementById('homeHot');
        if (!host) { return; }
        var top = state.animes.slice()
            .sort(function (a, b) { return b.videos.length - a.videos.length || b.updated - a.updated; })
            .slice(0, 12);
        var body = top.length
            ? '<div class="agp-poster-grid">' + top.map(function (anime, i) {
                return posterCard(anime, i + 1);
            }).join('') + '</div>'
            : '<p class="agp-empty">尚無資料。</p>';
        host.innerHTML = sectionHtml('library-hot', '片庫熱門', body);
    }

    function renderLibrary() {
        var host = document.getElementById('homeLibrary');
        if (!host) { return; }
        var query = state.query.trim().toLowerCase();
        var list = state.animes;
        if (query) {
            list = list.filter(function (anime) {
                return anime.name.toLowerCase().indexOf(query) !== -1;
            });
        }
        /* An empty library and a search that found nothing look the same in the
           DOM but mean very different things -- do not tell someone with no
           downloads that nothing matches their (empty) query. */
        var empty = query
            ? '<p class="agp-empty">找不到符合「' + AGP.escapeHtml(state.query) + '」的作品。</p>'
            : '<p class="agp-empty">片庫還沒有任何影片，先到主控台下載幾集吧。</p>';
        var body = list.length
            ? '<div class="agp-poster-grid">' + list.map(function (anime) {
                return posterCard(anime, 0);
            }).join('') + '</div>'
            : empty;
        host.innerHTML = sectionHtml('library', query ? '片庫搜尋結果' : '片庫', body);
    }

    /* #homeNotice is a fixed banner with its own markup; everything else is a
       section host we own outright and can replace wholesale. */
    function noticeOrEmpty(hostId, message) {
        var host = document.getElementById(hostId);
        if (!host) { return; }
        var span = hostId === 'homeNotice' ? host.querySelector('span') : null;
        if (span) {
            span.textContent = message;
        } else {
            host.innerHTML = '<p class="agp-empty">' + AGP.escapeHtml(message) + '</p>';
        }
    }

    /* boot() is never awaited, so an exception escaping one section would leave
       every section after it blank with the loading state already cleared. */
    function renderSection(hostId, render) {
        try {
            render();
        } catch (error) {
            console.error('home section failed: ' + hostId, error);
            noticeOrEmpty(hostId, '這個區塊載入失敗，請重新整理頁面。');
        }
    }

    function renderAll() {
        renderSection('homeNotice', renderNotice);
        renderSection('homeBanner', renderBanner);
        renderSection('homeContinue', renderContinue);
        renderSection('homeTimetable', renderTimetable);
        renderSection('homeHot', renderHot);
        renderSection('homeLibrary', renderLibrary);
        AGP.syncTabs();
    }

    /* An anonymous visitor gets a 403 from /video_list.json whenever
       online_watch_requires_login is on. Falling back to an empty list would
       tell them they own no downloads instead of that they have to log in. */
    function renderProblem(status) {
        var needsLogin = status === 401 || status === 403;
        noticeOrEmpty('homeNotice', needsLogin ? '登入後即可瀏覽片庫。' : '目前無法讀取片庫。');
        ['homeBanner', 'homeContinue', 'homeTimetable', 'homeHot'].forEach(function (id) {
            var host = document.getElementById(id);
            if (host) { host.innerHTML = ''; }
        });

        var library = document.getElementById('homeLibrary');
        if (!library) { return; }
        library.innerHTML = needsLogin
            ? sectionHtml('library', '需要登入',
                '<p class="agp-empty">這個站台限定登入後瀏覽片庫。<br>' +
                (hasLoginPage()
                    ? '<a class="agp-btn" href="./login" style="margin-top:14px">前往登入</a>'
                    : '請聯絡站台管理員開通帳號。') + '</p>')
            : sectionHtml('library', '片庫',
                '<p class="agp-empty">片庫讀取失敗（' +
                AGP.escapeHtml(status ? 'HTTP ' + status : '連線中斷') + '）。<br>' +
                '<button class="agp-btn" id="homeRetry" type="button" style="margin-top:14px">重新載入</button></p>');

        var retry = document.getElementById('homeRetry');
        if (retry) {
            retry.addEventListener('click', function () { global.location.reload(); });
        }

        AGP.syncTabs();
    }

    /* --- data -------------------------------------------------------------- */

    function groupByAnime(videos) {
        var byAnime = {};
        var animes = [];
        videos.forEach(function (video) {
            var name = animeKey(video);
            if (!byAnime[name]) {
                byAnime[name] = { name: name, videos: [], updated: 0, latest: video };
                animes.push(byAnime[name]);
            }
            var anime = byAnime[name];
            anime.videos.push(video);
            if ((video.timestamp || 0) >= anime.updated) {
                anime.updated = video.timestamp || 0;
            }
            if (episodeNumber(video) > episodeNumber(anime.latest)) {
                anime.latest = video;
            }
        });
        animes.sort(function (a, b) { return b.updated - a.updated; });
        return { byAnime: byAnime, animes: animes };
    }

    async function loadTimes() {
        if (!isLoggedIn()) { return {}; }
        try {
            var response = await fetch('./watch/time?type=get');
            var data = await response.json();
            return data && typeof data === 'object' ? data : {};
        } catch (error) {
            console.warn('watch positions unavailable:', error);
            return {};
        }
    }

    async function boot() {
        var failure = null;
        var results = await Promise.all([
            fetch('./video_list.json').then(function (response) {
                if (!response.ok) { return Promise.reject(response.status); }
                return response.json();
            }).catch(function (error) {
                console.warn('video list unavailable:', error);
                failure = typeof error === 'number' ? error : 0;
                return { videos: [] };
            }),
            loadTimes()
        ]);

        var videos = Array.isArray(results[0].videos) ? results[0].videos.slice() : [];
        videos.sort(function (a, b) { return (b.timestamp || 0) - (a.timestamp || 0); });

        var grouped = groupByAnime(videos);
        state.videos = videos;
        state.animes = grouped.animes;
        state.byAnime = grouped.byAnime;
        state.times = results[1];

        document.body.classList.remove('is-loading');
        if (failure !== null) {
            renderProblem(failure);
            return;
        }
        renderAll();
        /* Arriving with ?q= from the watch page: the sections that are not
           results fold away, so the grid is already the first thing showing. */
        applySearchMode();
    }

    /* The watch page's search box is a plain GET form pointed at this page, so
       ?q= has to be read here -- and keeping it in the URL while the user types
       makes a search survive a reload and stay linkable. */
    function queryFromUrl() {
        try {
            return new URLSearchParams(global.location.search).get('q') || '';
        } catch (error) {
            return '';
        }
    }

    function pushQueryToUrl() {
        if (!global.history || !global.history.replaceState) { return; }
        var query = state.query.trim();
        try {
            global.history.replaceState(global.history.state, '',
                global.location.pathname + (query ? '?q=' + encodeURIComponent(query) : '') +
                global.location.hash);
        } catch (error) {
            /* Safari rate-limits replaceState: the address bar is a nicety, the
               results the user is typing towards are not. */
        }
    }

    /* 搜尋的時候這幾塊跟結果沒關係, 收起來它們就不占位置.
       #homeLibrary 跟 #homeCatalog 不在裡面 —— 那兩塊就是結果 */
    var SEARCH_HIDDEN = ['homeBanner', 'homeContinue', 'homeSeason', 'homeSchedule',
        'homeCatalogHot', 'homeCatalogNew', 'homeTimetable', 'homeHot'];

    /* 每敲一個字都會跑到這裡. 以前是把結果捲進畫面 —— iPad 上鍵盤一升起來
       視窗就矮一截, 清單又每打一個字重排一次, 捲完停在哪裡沒人說得準, 畫面就
       自己往下跑. 改成把不是結果的區塊收起來: 結果自己浮上來, 頁面不必動 */
    function applySearchMode() {
        var searching = !!state.query.trim();
        document.body.classList.toggle('is-searching', searching);
        SEARCH_HIDDEN.forEach(function (id) {
            var host = document.getElementById(id);
            if (host) { host.hidden = searching; }
        });
        AGP.syncTabs();
    }

    function wireSearch() {
        var input = document.getElementById('homeSearch');
        if (!input) { return; }
        var seed = queryFromUrl();
        if (seed) {
            input.value = seed;
            state.query = seed;
        }
        var form = input.closest('form');
        if (form) {
            form.addEventListener('submit', function (event) { event.preventDefault(); });
        }
        input.addEventListener('input', function () {
            state.query = input.value;
            renderLibrary();
            pushQueryToUrl();
            applySearchMode();
        });
    }

    document.addEventListener('error', function (event) {
        var target = event.target;
        if (target && target.classList && target.classList.contains('agp-art-img')) {
            target.remove();
        }
    }, true);

    document.addEventListener('DOMContentLoaded', function () {
        wireSearch();
        boot();
    });
}(window));
