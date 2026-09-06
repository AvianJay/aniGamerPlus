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
        bySn: {},
        /* 線上看過但片庫裡沒有的那幾集: videoSn -> 官方集數表查回來的作品資料 */
        remote: {},
        times: {},
        query: '',
        paneBeforeSearch: '',
        resolving: false
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

    /* 卡片底下那塊漸層底板 + 縮圖. 收藏頁跟紀錄頁都有片庫以外的東西要畫,
       所以縮圖的來源要能換成官方封面 */
    function plateOf(name, imgHtml) {
        return '<span class="agp-card-art-fill" style="' + artStyle(name) + '"></span>' +
            '<span class="agp-card-art-glyph">' + AGP.escapeHtml(AGP.initials(name)) + '</span>' +
            (imgHtml || '');
    }

    function coverImg(url) {
        return url ? '<img class="agp-art-img" alt="" loading="lazy" src="' +
            AGP.escapeHtml(url) + '">' : '';
    }

    function pad2(value) {
        return (value < 10 ? '0' : '') + value;
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

    /* --- 收藏 -------------------------------------------------------------- */

    function favEntryOf(anime) {
        return {
            name: anime.name,
            sn: anime.latest ? anime.latest.sn : '',
            res: anime.latest ? anime.latest.resolution : ''
        };
    }

    function favAnime(item) {
        return state.byAnime[item.name] || (item.alias ? state.byAnime[item.alias] : null);
    }

    function favPoster(item) {
        var anime = favAnime(item);
        /* 收藏的作品不一定下載過. 沒有檔案就走線上看那條路, 入口那一集是按下
           收藏的時候一起記下來的 */
        var href = anime ? watchUrl(anime.latest)
            : './watch?id=' + encodeURIComponent(item.sn) +
                (item.res ? '&res=' + encodeURIComponent(item.res) : '');
        var art = anime ? thumbImg(anime.latest) : coverImg(item.cover);
        var foot = anime
            ? '共 ' + anime.videos.length + ' 集 · 更新至 ' + episodeLabel(anime.latest)
            : '片庫沒有這部，點開直接線上看';

        return '<div class="agp-fav-item">' +
            '<a class="agp-poster" href="' + AGP.escapeHtml(href) + '">' +
            '<span class="agp-poster-art" style="' + artStyle(item.name) + '">' +
            '<span class="agp-card-art-glyph">' + AGP.escapeHtml(AGP.initials(item.name)) + '</span>' +
            art + '</span>' +
            '<span class="agp-poster-foot"><strong>' + AGP.escapeHtml(item.name) + '</strong>' +
            '<small>' + AGP.escapeHtml(foot) + '</small></span></a>' +
            '<button class="agp-fav-drop" type="button" data-unfav="' + AGP.escapeHtml(item.name) +
            '" aria-label="取消收藏 ' + AGP.escapeHtml(item.name) + '">' + AGP.icon('x', 15) +
            '</button></div>';
    }

    function renderFavourites() {
        var host = document.getElementById('homeFavourites');
        if (!host) { return; }
        /* 舊版一部作品一個 localStorage key, 名字換算成雜湊回不去. 片庫的片名
           現在都在手上, 趁這時候把認得出來的搬進清單 */
        AGP.favourites.adopt(state.animes.map(favEntryOf));

        var list = AGP.favourites.list();
        var body = list.length
            ? '<p class="agp-count">共 ' + list.length + ' 部作品</p>' +
                '<div class="agp-poster-grid">' + list.map(favPoster).join('') + '</div>'
            : '<p class="agp-empty">還沒有收藏任何作品。<br>' +
                '在播放頁按下標題旁的「收藏」，作品就會留在這裡。</p>';
        host.innerHTML = sectionHtml('favourites', '收藏', body);
    }

    /* --- 紀錄 -------------------------------------------------------------- */

    /* 一次問一部作品: /watch/series.json 回的是整份集數表, 所以同一部作品裡
       其他看過的集數會一起認出來. 上限擋的是「紀錄裡有幾十部沒下載的作品」
       這種情況, 不是一集一個請求 */
    var HISTORY_LOOKUPS = 8;
    var HISTORY_ROWS = 200;

    function describeRow(row) {
        var video = state.bySn[row.sn];
        if (video) {
            return {
                name: animeKey(video),
                label: episodeLabel(video),
                href: watchUrl(video),
                img: thumbImg(video),
                local: true
            };
        }
        var remote = state.remote[row.sn];
        if (remote) {
            return {
                name: remote.name,
                label: episodeLabel({ episode: remote.episode }),
                href: '',
                img: coverImg(remote.cover),
                local: false
            };
        }
        return null;
    }

    function indexSeries(detail) {
        if (!detail || !detail.groups) { return; }
        detail.groups.forEach(function (group) {
            (group.episodes || []).forEach(function (episode) {
                state.remote[String(episode.videoSn)] = {
                    name: detail.title,
                    episode: episode.episode,
                    cover: detail.cover || episode.cover || ''
                };
            });
        });
    }

    async function resolveHistory(rows) {
        if (state.resolving) { return false; }
        state.resolving = true;
        var found = false;
        var tries = 0;
        try {
            while (tries < HISTORY_LOOKUPS) {
                var pending = rows.filter(function (row) { return !describeRow(row); });
                if (!pending.length) { break; }
                tries += 1;
                var sn = pending[0].sn;
                try {
                    var response = await fetch('./watch/series.json?id=' + encodeURIComponent(sn));
                    if (response.ok) {
                        indexSeries(await response.json());
                        found = true;
                    }
                } catch (error) { /* 認不出來就認不出來, 那一列還是列得出日期 */ }
                /* 問過了就標記, 不然這一集永遠排在隊伍最前面把次數用光 */
                if (!state.remote[sn]) { state.remote[sn] = null; }
            }
        } finally {
            state.resolving = false;
        }
        return found;
    }

    function historyRows() {
        var rows = [];
        Object.keys(state.times).forEach(function (sn) {
            var entry = state.times[sn];
            if (!entry) { return; }
            rows.push({ sn: String(sn), entry: entry, updated: Number(entry.timestamp) || 0 });
        });
        rows.sort(function (a, b) { return b.updated - a.updated; });
        return rows.slice(0, HISTORY_ROWS);
    }

    function monthLabel(timestamp) {
        if (!timestamp) { return '更早以前'; }
        var date = new Date(timestamp * 1000);
        return date.getFullYear() + '年' + pad2(date.getMonth() + 1) + '月';
    }

    function dayStamp(timestamp) {
        if (!timestamp) { return ''; }
        var date = new Date(timestamp * 1000);
        return pad2(date.getMonth() + 1) + '/' + pad2(date.getDate());
    }

    function historyRowHtml(row) {
        var about = describeRow(row);
        var entry = row.entry;
        var seconds = Number(entry.time) || 0;
        var duration = Number(entry.duration) || 0;
        var name = about ? about.name : '未知作品';
        var ratio = entry.ended ? 1 : (duration > 0 ? Math.min(0.99, seconds / duration) : 0);
        var stamp = dayStamp(row.updated);
        var where = entry.ended
            ? '已看完' + (about ? ' ' + about.label : '')
            : (about ? '觀看至 ' + about.label : '觀看至 ' + AGP.formatClock(seconds));
        /* 片庫有檔就是一條連結; 沒檔的那一集要先排下載才有東西可播, 所以是按鈕 */
        var play = about && about.local
            ? '<a href="' + AGP.escapeHtml(about.href) + '" aria-label="繼續播放">' +
                AGP.icon('play', 15) + '</a>'
            : '<button type="button" data-stream="' + AGP.escapeHtml(row.sn) +
                '" aria-label="邊看邊下載">' + AGP.icon('play', 15) + '</button>';
        var art = about && about.local
            ? '<a class="agp-history-art" href="' + AGP.escapeHtml(about.href) + '">' +
                plateOf(name, about.img) + '</a>'
            : '<span class="agp-history-art">' + plateOf(name, about ? about.img : '') + '</span>';

        return '<div class="agp-history-row" data-history="' + AGP.escapeHtml(row.sn) + '">' +
            art +
            '<div class="agp-history-body">' +
            '<strong>' + AGP.escapeHtml(name) + '</strong>' +
            '<small>' + AGP.escapeHtml((stamp ? stamp + ' ' : '') + where) + '</small>' +
            '<span class="agp-history-bar"><i style="width:' + (ratio * 100).toFixed(1) +
            '%"></i></span></div>' +
            '<div class="agp-history-acts">' +
            '<button type="button" data-drop="' + AGP.escapeHtml(row.sn) +
            '" aria-label="刪除這筆紀錄">' + AGP.icon('x', 16) + '</button>' + play +
            '</div></div>';
    }

    function renderHistory() {
        var host = document.getElementById('homeHistory');
        if (!host) { return; }
        if (!isLoggedIn()) {
            host.innerHTML = sectionHtml('history', '觀看紀錄',
                '<p class="agp-empty">觀看紀錄跟著帳號走。' +
                (hasLoginPage() ? '<br><a class="agp-btn" href="./login" style="margin-top:14px">前往登入</a>'
                    : '') + '</p>');
            return;
        }

        var rows = historyRows();
        if (!rows.length) {
            host.innerHTML = sectionHtml('history', '觀看紀錄',
                '<p class="agp-empty">還沒有任何觀看紀錄。</p>');
            return;
        }

        var body = '';
        var month = '';
        rows.forEach(function (row) {
            var label = monthLabel(row.updated);
            if (label !== month) {
                month = label;
                body += '<p class="agp-history-month">' + AGP.escapeHtml(label) + '</p>';
            }
            body += historyRowHtml(row);
        });
        host.innerHTML = sectionHtml('history', '觀看紀錄', body);

        /* 認不出來的那幾集去問一次官方集數表, 問到了就重畫. 先畫再問是因為
           日期跟進度本來就知道, 沒必要讓整頁等網路 */
        if (rows.some(function (row) { return !describeRow(row); })) {
            resolveHistory(rows).then(function (found) {
                if (found) { renderSection('homeHistory', renderHistory); }
            });
        }
    }

    async function dropHistory(sn) {
        delete state.times[String(sn)];
        renderSection('homeHistory', renderHistory);
        renderSection('homeContinue', renderContinue);
        try {
            await fetch('./watch/time?type=del&sn=' + encodeURIComponent(sn));
        } catch (error) { /* 伺服器沒收到, 下次重新整理就會再出現 */ }
    }

    /* --- 我的 -------------------------------------------------------------- */

    function accountRows(user, info) {
        var rows = [];
        if (info && info.online_watch) {
            rows.push(['./watch', '線上看', 'play']);
        }
        if (user) {
            if (user.role === 'admin') {
                rows.push(['./control', '主控台', 'settings']);
                rows.push(['./usermanage', '用戶管理', 'user']);
            }
            rows.push(['./userinfo', '帳號資訊', 'list']);
            rows.push(['./logout', '登出', 'x']);
            return rows;
        }
        if (info && info.user_control) {
            rows.push(['./login', '登入', 'user']);
            if (info.user_control_allow_register === true) {
                rows.push(['./register', '註冊', 'plusSquare']);
            }
            return rows;
        }
        /* 沒開用戶系統的站台人人都是管理員, 主控台就是這一頁唯一有用的東西 */
        rows.push(['./control', '主控台', 'settings']);
        return rows;
    }

    function renderAccount() {
        var host = document.getElementById('homeAccount');
        if (!host) { return; }
        var info = dashboardApi.getServerInfoSnapshot ? dashboardApi.getServerInfoSnapshot() : null;
        var user = dashboardApi.getCurrentUserSnapshot ? dashboardApi.getCurrentUserSnapshot() : null;
        var name = (user && user.username) || '訪客';
        var role = user
            ? (user.role === 'admin' ? '管理員' : '一般用戶')
            : (info && info.user_control ? '尚未登入' : '未啟用用戶系統');

        var rows = accountRows(user, info).map(function (row) {
            return '<a class="agp-account-row" href="' + AGP.escapeHtml(row[0]) + '">' +
                AGP.icon(row[2], 17) + '<span>' + AGP.escapeHtml(row[1]) + '</span>' +
                AGP.icon('chevronRight', 15) + '</a>';
        }).join('');

        host.innerHTML = sectionHtml('account', '我的',
            '<div class="agp-account-card">' +
            '<span class="agp-account-avatar">' +
            AGP.escapeHtml(String(name).trim().charAt(0).toUpperCase()) + '</span>' +
            '<div><strong>' + AGP.escapeHtml(name) + '</strong>' +
            '<small>' + AGP.escapeHtml(role + ' · 片庫 ' + state.animes.length + ' 部 ' +
                state.videos.length + ' 集 · 收藏 ' + AGP.favourites.list().length + ' 部') +
            '</small></div></div>' +
            '<div class="agp-account-list">' + rows + '</div>');
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
        renderSection('homeFavourites', renderFavourites);
        renderSection('homeHistory', renderHistory);
        renderSection('homeAccount', renderAccount);
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
        /* 這三頁不靠 /video_list.json: 收藏在瀏覽器裡, 紀錄跟帳號是另外的路由 */
        renderSection('homeFavourites', renderFavourites);
        renderSection('homeHistory', renderHistory);
        renderSection('homeAccount', renderAccount);

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
        state.bySn = {};
        videos.forEach(function (video) { state.bySn[String(video.sn)] = video; });
        state.times = results[1];

        document.body.classList.remove('is-loading');
        if (failure !== null) {
            renderProblem(failure);
            return;
        }
        renderAll();
        /* Arriving with ?q= from the watch page: the answer lives on 所有動畫,
           so that is the page that opens. */
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

    /* 分頁跟搜尋都寫進網址: 重新整理回得到同一頁, 播放頁那顆「所有動畫」也
       只要指到 ./?tab=all 就行 */
    function pushUrl() {
        if (!global.history || !global.history.replaceState) { return; }
        var params = [];
        var pane = AGP.currentPane();
        if (pane && pane !== 'home') { params.push('tab=' + pane); }
        var query = state.query.trim();
        if (query) { params.push('q=' + encodeURIComponent(query)); }
        try {
            global.history.replaceState(global.history.state, '',
                global.location.pathname + (params.length ? '?' + params.join('&') : '') +
                global.location.hash);
        } catch (error) {
            /* Safari rate-limits replaceState: the address bar is a nicety, the
               results the user is typing towards are not. */
        }
    }

    /* 每敲一個字都會跑到這裡. 以前是把結果捲進畫面 —— iPad 上鍵盤一升起來
       視窗就矮一截, 清單又每打一個字重排一次, 捲完停在哪裡沒人說得準, 畫面就
       自己往下跑。現在片庫比對跟片單本來就同在「所有動畫」那一頁, 切過去就好,
       捲軸一步都不用動; 清空搜尋再切回原本待著的那一頁 */
    function applySearchMode() {
        var searching = !!state.query.trim();
        document.body.classList.toggle('is-searching', searching);
        if (searching) {
            if (AGP.currentPane() !== 'all') {
                state.paneBeforeSearch = AGP.currentPane();
                AGP.showPane('all');
            }
        } else if (state.paneBeforeSearch) {
            AGP.showPane(state.paneBeforeSearch);
            state.paneBeforeSearch = '';
        }
        pushUrl();
    }

    function paneFromUrl() {
        try {
            return new URLSearchParams(global.location.search).get('tab') || '';
        } catch (error) {
            return '';
        }
    }

    /* 收藏在別的分頁按掉的、紀錄在別的裝置上多出來的, 切回來的時候都該是新的 */
    function onPaneShown(name, changed) {
        if (!changed) { return; }
        if (name === 'fav') { renderSection('homeFavourites', renderFavourites); }
        if (name === 'history') { renderSection('homeHistory', renderHistory); }
        if (name === 'mine') { renderSection('homeAccount', renderAccount); }
        pushUrl();
    }

    /* 排下載, 然後才走. 沒排就跳過去只會讓人對著一個永遠不會開始的播放器等 */
    async function startStreaming(sn) {
        try {
            var response = await fetch('./manualTask', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json;charset=utf-8' },
                body: JSON.stringify({
                    sn: sn, resolution: '1080', mode: 'single',
                    thread: 1, classify: true, danmu: true
                })
            });
            if (!response.ok) { throw response.status; }
        } catch (status) {
            /* 排不進佇列還跳過去, 只會讓人對著一個永遠不會開始的播放器等 */
            AGP.toast(status === 401 || status === 403
                ? '需要管理員權限才能下載。' : '加入下載失敗。');
            return;
        }
        AGP.toast('已加入下載佇列，開始邊看邊下載。');
        global.location.href = './watch?id=' + encodeURIComponent(sn) + '&streaming=1';
    }

    function onClick(event) {
        if (event.defaultPrevented) { return; }

        var unfav = event.target.closest('[data-unfav]');
        if (unfav) {
            AGP.favourites.remove(unfav.dataset.unfav);
            renderSection('homeFavourites', renderFavourites);
            renderSection('homeAccount', renderAccount);
            return;
        }

        var drop = event.target.closest('[data-drop]');
        if (drop) {
            dropHistory(drop.dataset.drop);
            return;
        }

        var stream = event.target.closest('.agp-history-row [data-stream]');
        if (stream) {
            startStreaming(stream.dataset.stream);
        }
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
        AGP.onPane(onPaneShown);
        AGP.showPane(paneFromUrl() || 'home');
        wireSearch();
        boot();
    });

    document.addEventListener('click', onClick);
}(window));
