/* ---------------------------------------------------------------------------
   aniGamerPlus+ — 動畫瘋片單
   home.js draws what is on disk; this draws what is on 動畫瘋. The sections
   mirror the site's own front page — 本季新番, 更新時間表, 近期熱播, 最新上架,
   所有動畫 — and behind every card sits a detail sheet that lists the whole
   series, marks the episodes already downloaded, and can queue the rest.
   --------------------------------------------------------------------------- */
(function (global) {
    'use strict';

    var AGP = global.AGP;
    var dashboardApi = global.dashboardApi || {};

    var HASH_PREFIX = '#anime-';
    /* 名偵探柯南 carries 986 episodes in one group. Painting all of them costs
       far more than anybody reads before scrolling past, so a group opens short
       and grows only when asked. */
    var EPISODES_SHOWN = 120;
    var SEARCH_DEBOUNCE = 260;
    var SYNOPSIS_CLAMP = 140;
    var RESOLUTIONS = ['1080', '720', '540', '480', '360'];

    var state = {
        index: null,
        page: 1,
        pages: 1,
        total: 0,
        query: '',
        weekday: 1,
        sheetSn: '',
        pushed: false,
        detail: null,
        expanded: {},
        synopsis: false,
        details: {},
        queued: {}
    };

    function el(id) {
        return document.getElementById(id);
    }

    /* Downloads go through /manualTask, which is admin-only whenever the user
       system is on. Offering a button the server will refuse is worse than
       offering none. */
    function canDownload() {
        var info = dashboardApi.getServerInfoSnapshot ? dashboardApi.getServerInfoSnapshot() : null;
        if (!info || !info.user_control) { return true; }
        var user = dashboardApi.getCurrentUserSnapshot ? dashboardApi.getCurrentUserSnapshot() : null;
        return !!(user && user.role === 'admin');
    }

    async function getJson(url) {
        var response = await fetch(url);
        if (!response.ok) { throw response.status; }
        return response.json();
    }

    /* --- markup ------------------------------------------------------------ */

    /* The generated plate is what shows while the cover loads and what stays if
       巴哈 stops serving it: home.js drops any .agp-art-img that errors, which
       uncovers the plate again. */
    function coverArt(item) {
        return '<span class="agp-card-art-fill" style="background:' + AGP.artFor(item.title) + '"></span>' +
            '<span class="agp-card-art-glyph">' + AGP.escapeHtml(AGP.initials(item.title)) + '</span>' +
            (item.cover ? '<img class="agp-art-img" alt="" loading="lazy" src="' +
                AGP.escapeHtml(item.cover) + '">' : '');
    }

    /* Every card is a real link to #anime-<sn>, so it survives a middle click,
       a shared URL and the iOS app's back gesture. onClick() only takes over
       the plain left click. */
    function cardAttrs(item) {
        return ' href="' + HASH_PREFIX + AGP.escapeHtml(item.animeSn) +
            '" data-anime-sn="' + AGP.escapeHtml(item.animeSn) + '"';
    }

    /* 本季新番 ships the wide episode banner; the catalogue grids ship the 3:4
       ACG cover. Two card shapes rather than one letterboxed compromise. */
    function catalogCard(item) {
        return '<a class="agp-card"' + cardAttrs(item) + '>' +
            '<span class="agp-card-art">' + coverArt(item) +
            (item.volume ? '<span class="agp-card-ep">' + AGP.escapeHtml(item.volume) + '</span>' : '') +
            (item.popular ? '<span class="agp-card-badge">' + AGP.icon('eye', 12) + ' ' +
                AGP.escapeHtml(item.popular) + '</span>' : '') +
            '</span>' +
            '<span class="agp-card-title">' + AGP.escapeHtml(item.title) + '</span>' +
            '<span class="agp-card-meta"><span>' + AGP.escapeHtml(item.info) + '</span></span>' +
            '</a>';
    }

    function catalogPoster(item, rank) {
        return '<a class="agp-poster"' + cardAttrs(item) + '>' +
            '<span class="agp-poster-art">' + coverArt(item) +
            (rank ? '<span class="agp-poster-rank">' + rank + '</span>' : '') +
            '</span>' +
            '<span class="agp-poster-foot"><strong>' + AGP.escapeHtml(item.title) + '</strong>' +
            '<small>' + AGP.escapeHtml(item.info || item.volume || '') +
            (item.popular ? ' · ' + AGP.escapeHtml(item.popular) : '') + '</small>' +
            '</span></a>';
    }

    function posterGrid(items, ranked) {
        return '<div class="agp-poster-grid">' + items.map(function (item, i) {
            return catalogPoster(item, ranked ? i + 1 : 0);
        }).join('') + '</div>';
    }

    /* --- sections ---------------------------------------------------------- */

    function renderSeason() {
        var host = el('homeSeason');
        if (!host) { return; }
        var items = (state.index && state.index.season) || [];
        if (!items.length) {
            host.innerHTML = '';
            return;
        }
        host.innerHTML = AGP.sectionHtml('season', '本季新番',
            AGP.railHtml(items.map(catalogCard).join(''), 'railSeason'));
        host.querySelectorAll('.agp-rail-wrap').forEach(AGP.wireRail);
    }

    function renderSchedule() {
        var host = el('homeSchedule');
        if (!host) { return; }
        var days = (state.index && state.index.schedule) || [];
        if (!days.length) {
            host.innerHTML = '';
            return;
        }

        var tabs = days.map(function (day) {
            return '<button class="agp-daytab' + (day.weekday === state.weekday ? ' is-on' : '') +
                '" type="button" data-weekday="' + day.weekday + '">' +
                AGP.escapeHtml(day.label) + '<em>' + day.episodes.length + '</em></button>';
        }).join('');

        var today = days.filter(function (day) { return day.weekday === state.weekday; })[0] || days[0];
        var rows = today.episodes.map(function (episode) {
            /* Only the rows 本季新番 also lists carry an animeSn, and without
               one there is no detail sheet to open -- so those stay plain text
               rather than becoming a link that goes nowhere. */
            var tag = episode.animeSn ? 'a' : 'div';
            return '<' + tag + ' class="agp-slot"' + (episode.animeSn ? cardAttrs(episode) : '') + '>' +
                '<span class="agp-slot-time">' + AGP.escapeHtml(episode.time) + '</span>' +
                '<span class="agp-slot-art">' + coverArt(episode) + '</span>' +
                '<span class="agp-slot-body">' +
                '<strong>' + AGP.escapeHtml(episode.title) + '</strong>' +
                '<small>' + AGP.escapeHtml(episode.volume) + '</small></span>' +
                '</' + tag + '>';
        }).join('');

        host.innerHTML = AGP.sectionHtml('weekly', '更新時間表',
            '<div class="agp-daytabs">' + tabs + '</div>' +
            (rows ? '<div class="agp-slots">' + rows + '</div>'
                : '<p class="agp-empty">這天沒有排定更新。</p>'));
    }

    function renderHot() {
        var host = el('homeCatalogHot');
        if (!host) { return; }
        var items = (state.index && state.index.hot) || [];
        host.innerHTML = items.length
            ? AGP.sectionHtml('hot', '近期熱播', posterGrid(items, true))
            : '';
    }

    function renderNewAdded() {
        var host = el('homeCatalogNew');
        if (!host) { return; }
        var items = (state.index && state.index.newAdded) || [];
        host.innerHTML = items.length
            ? AGP.sectionHtml('newadded', '最新上架', posterGrid(items, false))
            : '';
    }

    function pagerHtml() {
        if (state.pages < 2) { return ''; }
        return '<div class="agp-pager">' +
            '<button class="agp-btn agp-btn--ghost" type="button" data-page="' + (state.page - 1) +
            '"' + (state.page <= 1 ? ' disabled' : '') + '>' + AGP.icon('chevronLeft', 14) + ' 上一頁</button>' +
            '<span>第 ' + state.page + ' / ' + state.pages + ' 頁</span>' +
            '<button class="agp-btn agp-btn--ghost" type="button" data-page="' + (state.page + 1) +
            '"' + (state.page >= state.pages ? ' disabled' : '') + '>下一頁 ' +
            AGP.icon('chevronRight', 14) + '</button>' +
            '</div>';
    }

    function renderCatalog(payload) {
        var host = el('homeCatalog');
        if (!host) { return; }
        var query = state.query.trim();
        var body;

        if (!payload) {
            /* 每敲一個字就把整片格子換成骨架, 頁面高度跟著一縮一放, 底下的東西
               就在腳下彈上彈下. 畫面上已經有東西的話, 讓它留著等新的接手 */
            if (host.dataset.filled === '1') {
                host.classList.add('is-loading');
                return;
            }
            body = '<div class="agp-poster-grid">' +
                new Array(15).join('<div class="agp-skeleton agp-poster-skeleton"></div>') + '</div>';
        } else if (!payload.items.length) {
            body = '<p class="agp-empty">' + (query
                ? '找不到符合「' + AGP.escapeHtml(query) + '」的作品。'
                : '目前拿不到動畫瘋的片單。') + '</p>';
        } else {
            body = '<p class="agp-count">' + (query ? '找到 ' : '共 ') + state.total + ' 部作品</p>' +
                posterGrid(payload.items, false) + pagerHtml();
        }

        host.classList.remove('is-loading');
        host.innerHTML = AGP.sectionHtml('all', query ? '搜尋結果' : '所有動畫', body);
        if (payload) { host.dataset.filled = '1'; }
    }

    /* --- catalogue data ---------------------------------------------------- */

    var catalogToken = 0;

    async function loadCatalog() {
        /* Every keystroke starts a request and they do not come back in order;
           a slow page 1 landing after a fast page 2 would silently replace the
           grid the reader is looking at. */
        var token = ++catalogToken;
        renderCatalog(null);
        var url = './catalog/all.json?page=' + state.page +
            (state.query.trim() ? '&q=' + encodeURIComponent(state.query.trim()) : '');
        var payload;
        try {
            payload = await getJson(url);
        } catch (error) {
            payload = { items: [], page: 1, pages: 1, total: 0 };
        }
        if (token !== catalogToken) { return; }
        state.page = payload.page || 1;
        state.pages = payload.pages || 1;
        state.total = payload.total || 0;
        renderCatalog(payload);
        AGP.syncTabs();
    }

    /* --- detail sheet ------------------------------------------------------ */

    function sheetHost() {
        var host = el('catalogSheet');
        if (host) { return host; }
        host = document.createElement('div');
        host.id = 'catalogSheet';
        host.className = 'agp-sheet';
        host.hidden = true;
        host.innerHTML = '<div class="agp-sheet-backdrop" data-sheet-close="1"></div>' +
            '<div class="agp-sheet-panel" role="dialog" aria-modal="true" aria-label="作品資訊">' +
            '<button class="agp-sheet-x" type="button" data-sheet-close="1" aria-label="關閉">' +
            AGP.icon('x', 18) + '</button>' +
            '<div class="agp-sheet-body" id="catalogSheetBody"></div></div>';
        document.body.appendChild(host);
        return host;
    }

    function chip(iconName, text) {
        if (!text) { return ''; }
        return '<span class="agp-chip">' + (iconName ? AGP.icon(iconName, 13) : '') +
            AGP.escapeHtml(String(text)) + '</span>';
    }

    function firstLocalEpisode(detail) {
        var groups = detail.groups || [];
        for (var g = 0; g < groups.length; g++) {
            var episodes = groups[g].episodes;
            for (var e = 0; e < episodes.length; e++) {
                if (episodes[e].local) { return episodes[e]; }
            }
        }
        return null;
    }

    function episodeBySn(detail, videoSn) {
        var groups = detail.groups || [];
        for (var g = 0; g < groups.length; g++) {
            var episodes = groups[g].episodes;
            for (var e = 0; e < episodes.length; e++) {
                if (String(episodes[e].videoSn) === String(videoSn)) { return episodes[e]; }
            }
        }
        return null;
    }

    function episodeHtml(episode) {
        var label = episode.episode || '?';
        if (episode.local) {
            return '<a class="agp-ep is-local" href="./watch?id=' +
                AGP.escapeHtml(encodeURIComponent(episode.videoSn)) + '">' +
                AGP.icon('check', 12) + AGP.escapeHtml(label) + '</a>';
        }
        var queued = state.queued[episode.videoSn];
        if (queued) {
            /* 排進去的那一刻就能看了, 沒有理由讓它繼續是一個按不動的灰格子.
               streaming=1 是給 /watch 的憑據 —— 任務剛送出去、進度紀錄還沒建立的
               那幾秒, 有它播放頁才會擺出播放器等分片, 而不是回一句找不到 */
            return '<a class="agp-ep is-queued" title="邊看邊下載" href="./watch?id=' +
                AGP.escapeHtml(encodeURIComponent(episode.videoSn)) + '&streaming=1">' +
                AGP.icon('play', 12) + AGP.escapeHtml(label) + '</a>';
        }
        return '<button class="agp-ep" type="button" data-episode="' +
            AGP.escapeHtml(episode.videoSn) + '">' + AGP.escapeHtml(label) + '</button>';
    }

    function groupHtml(group, index) {
        var episodes = group.episodes;
        var shown = state.expanded[index] ? episodes : episodes.slice(0, EPISODES_SHOWN);
        var more = episodes.length - shown.length;
        return '<div class="agp-epgroup">' +
            '<h4>' + AGP.escapeHtml(group.name) + '<em>' + episodes.length + ' 集</em></h4>' +
            '<div class="agp-eps">' + shown.map(episodeHtml).join('') + '</div>' +
            (more > 0 ? '<button class="agp-btn agp-btn--ghost agp-epmore" type="button" data-group="' +
                index + '">顯示其餘 ' + more + ' 集</button>' : '') +
            '</div>';
    }

    function actionsHtml(detail) {
        var local = firstLocalEpisode(detail);
        /* 「這一集下載過了嗎」跟「這部下載過了嗎」是兩件事. 按下去播的是
           detail.videoSn 那一集, 所以要問的也是那一集 -- 不然看完第 41 集,
           第 42 集的邊看邊下載就跟著消失了 */
        var current = episodeBySn(detail, detail.videoSn);
        var buttons = [];

        if (local) {
            buttons.push('<a class="agp-btn" href="./watch?id=' +
                AGP.escapeHtml(encodeURIComponent(local.videoSn)) + '">' +
                AGP.icon('play', 16) + ' 立即觀看</a>');
        }
        if (canDownload()) {
            /* 邊看邊下載: 下載一開始, temp 裡就是一份 HLS 串流, 播放器直接吃那個.
               對動畫瘋來說跟單純按下載完全一樣, 不會多開一條連線去搶頻寬 */
            if (!(current && current.local)) {
                buttons.push('<button class="agp-btn" type="button" data-stream="' +
                    AGP.escapeHtml(detail.videoSn) + '">' +
                    AGP.icon('play', 16) + ' 邊看邊下載</button>');
            }
            buttons.push('<button class="agp-btn agp-btn--ghost" type="button" data-download="all">' +
                AGP.icon('plusSquare', 16) + ' 加入下載</button>');
            buttons.push('<select class="agp-select" id="catalogResolution" aria-label="下載畫質">' +
                RESOLUTIONS.map(function (value) {
                    return '<option value="' + value + '">' + value + 'P</option>';
                }).join('') + '</select>');
        }
        buttons.push('<a class="agp-btn agp-btn--ghost" target="_blank" rel="noopener"' +
            ' href="https://ani.gamer.com.tw/animeVideo.php?sn=' +
            AGP.escapeHtml(encodeURIComponent(detail.videoSn)) + '">' +
            AGP.icon('share', 15) + ' 在動畫瘋開啟</a>');

        return '<div class="agp-sheet-actions">' + buttons.join('') + '</div>' +
            (local ? '' : '<p class="agp-sheet-hint">這部作品還沒有下載到片庫，' +
                (canDownload() ? '「邊看邊下載」會立刻開始播放，檔案在背景繼續下載。'
                    : '請聯絡站台管理員加入下載。') + '</p>');
    }

    function renderSheet() {
        var body = el('catalogSheetBody');
        if (!body) { return; }
        var detail = state.detail;

        if (!detail) {
            body.innerHTML = '<div class="agp-sheet-loading">' + AGP.icon('loader', 22) + ' 載入中…</div>';
            return;
        }
        if (detail.error) {
            body.innerHTML = '<div class="agp-sheet-loading">' + AGP.escapeHtml(detail.error) + '</div>';
            return;
        }

        var meta = chip('star', detail.score || '') + chip('eye', detail.popular) +
            chip('clock', detail.seasonStart) +
            chip('', detail.totalEpisode ? '共 ' + detail.totalEpisode + ' 集' : '') +
            chip('', detail.publisher) + chip('', detail.director);

        body.innerHTML =
            '<div class="agp-sheet-hero">' +
            '<span class="agp-sheet-cover">' + coverArt(detail) + '</span>' +
            '<div class="agp-sheet-head">' +
            '<h3>' + AGP.escapeHtml(detail.title) + '</h3>' +
            '<div class="agp-chips">' + meta + '</div>' +
            ((detail.tags || []).length ? '<div class="agp-chips agp-chips--tag">' +
                detail.tags.map(function (tag) { return chip('', tag); }).join('') + '</div>' : '') +
            actionsHtml(detail) +
            '</div></div>' +
            synopsisHtml(detail.content) +
            (detail.groups || []).map(groupHtml).join('');
    }

    function synopsisHtml(content) {
        if (!content) { return ''; }
        if (content.length <= SYNOPSIS_CLAMP || state.synopsis) {
            return '<p class="agp-sheet-text">' + AGP.escapeHtml(content) + '</p>';
        }
        return '<div class="agp-synopsis">' +
            '<p class="agp-sheet-text is-clamped">' + AGP.escapeHtml(content) + '</p>' +
            '<button class="agp-synopsis-more" type="button" data-synopsis="1">展開 ' +
            AGP.icon('chevronDown', 13) + '</button></div>';
    }

    async function loadDetail(animeSn) {
        if (state.details[animeSn]) {
            state.detail = state.details[animeSn];
            renderSheet();
            return;
        }
        state.detail = null;
        renderSheet();
        var detail;
        try {
            detail = await getJson('./catalog/anime.json?sn=' + encodeURIComponent(animeSn));
        } catch (status) {
            detail = { error: status === 403 ? '請先登入再瀏覽作品資訊。' : '拿不到這部作品的資訊。' };
        }
        /* The reader may have closed the sheet, or opened another title, while
           this was in flight. */
        if (state.sheetSn !== animeSn) { return; }
        state.details[animeSn] = detail;
        state.detail = detail;
        renderSheet();
    }

    function openSheet(animeSn) {
        var host = sheetHost();
        state.sheetSn = animeSn;
        state.expanded = {};
        state.synopsis = false;
        state.detail = state.details[animeSn] || null;
        host.hidden = false;
        document.body.classList.add('agp-sheet-open');
        renderSheet();
        loadDetail(animeSn);
    }

    function closeSheet() {
        var host = el('catalogSheet');
        state.sheetSn = '';
        state.detail = null;
        if (host) { host.hidden = true; }
        document.body.classList.remove('agp-sheet-open');
    }

    function snFromHash() {
        var hash = global.location.hash || '';
        return hash.indexOf(HASH_PREFIX) === 0 ? hash.slice(HASH_PREFIX.length) : '';
    }

    /* The hash is the single source of truth for what is open, so Back, the
       iOS swipe-back gesture and a pasted link all land in the same place. */
    function syncSheetToHash() {
        var sn = snFromHash();
        if (sn === state.sheetSn) { return; }
        if (sn) {
            openSheet(sn);
        } else {
            closeSheet();
        }
    }

    /* Back is the right way out of a sheet this page pushed. Arriving on a
       shared #anime- link pushed nothing, though, and going back from there
       leaves the site -- so that case rewrites the URL in place. */
    function dismissSheet() {
        if (state.pushed) {
            state.pushed = false;
            global.history.back();
            return;
        }
        try {
            global.history.replaceState(global.history.state, '',
                global.location.pathname + global.location.search);
        } catch (error) {
            /* An unchanged hash is a cosmetic problem; a stuck sheet is not. */
        }
        closeSheet();
    }

    /* --- downloads --------------------------------------------------------- */

    var toastTimer = 0;

    function toast(message) {
        var host = el('catalogToast');
        if (!host) {
            host = document.createElement('div');
            host.id = 'catalogToast';
            host.className = 'agp-toast';
            host.setAttribute('role', 'status');
            document.body.appendChild(host);
        }
        host.textContent = message;
        host.classList.add('is-on');
        global.clearTimeout(toastTimer);
        toastTimer = global.setTimeout(function () {
            host.classList.remove('is-on');
        }, 3200);
    }

    async function queueDownload(videoSn, mode) {
        var picker = el('catalogResolution');
        var payload = {
            sn: videoSn,
            resolution: picker ? picker.value : '1080',
            mode: mode,
            thread: 1,
            classify: true,
            danmu: true
        };
        try {
            var response = await fetch('./manualTask', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json;charset=utf-8' },
                body: JSON.stringify(payload)
            });
            if (!response.ok) { throw response.status; }
        } catch (status) {
            toast(status === 401 || status === 403 ? '需要管理員權限才能下載。' : '加入下載失敗。');
            return false;
        }
        state.queued[videoSn] = true;
        toast(mode === 'all' ? '已加入下載佇列，整部作品開始排隊。' : '已加入下載佇列。');
        renderSheet();
        return true;
    }

    /* 排下載, 然後就走. 失敗的話 queueDownload 已經吐過 toast 說明原因了, 這裡再
       跳過去只會讓人對著一個永遠不會開始的播放器等 */
    async function startStreaming(videoSn) {
        if (!state.queued[videoSn] && !await queueDownload(videoSn, 'single')) { return; }
        global.location.href = './watch?id=' + encodeURIComponent(videoSn) + '&streaming=1';
    }

    /* --- wiring ------------------------------------------------------------ */

    function onClick(event) {
        if (event.defaultPrevented) { return; }

        if (event.target.closest('[data-sheet-close]')) {
            event.preventDefault();
            dismissSheet();
            return;
        }

        var card = event.target.closest('[data-anime-sn]');
        /* Modified clicks stay with the browser: they are how somebody opens a
           title in a second tab, and the href is a real URL. */
        if (card && !event.metaKey && !event.ctrlKey && !event.shiftKey && event.button === 0) {
            event.preventDefault();
            var sn = card.dataset.animeSn;
            if (sn === state.sheetSn) { return; }
            global.history.pushState({ agpSheet: sn }, '',
                global.location.pathname + global.location.search + HASH_PREFIX + sn);
            state.pushed = true;
            openSheet(sn);
            return;
        }

        var day = event.target.closest('[data-weekday]');
        if (day) {
            state.weekday = Number(day.dataset.weekday);
            renderSchedule();
            return;
        }

        var page = event.target.closest('[data-page]');
        if (page && !page.disabled) {
            state.page = Number(page.dataset.page);
            loadCatalog();
            var host = el('homeCatalog');
            if (host) { host.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
            return;
        }

        if (event.target.closest('[data-synopsis]')) {
            state.synopsis = true;
            renderSheet();
            return;
        }

        var group = event.target.closest('[data-group]');
        if (group) {
            state.expanded[group.dataset.group] = true;
            renderSheet();
            return;
        }

        var stream = event.target.closest('[data-stream]');
        if (stream) {
            startStreaming(stream.dataset.stream);
            return;
        }

        var episode = event.target.closest('[data-episode]');
        if (episode && !episode.disabled) {
            queueDownload(episode.dataset.episode, 'single');
            return;
        }

        var download = event.target.closest('[data-download]');
        if (download && state.detail && state.detail.videoSn) {
            queueDownload(state.detail.videoSn, download.dataset.download);
        }
    }

    function wireSearch() {
        var input = el('homeSearch');
        if (!input) { return; }
        var timer = 0;
        input.addEventListener('input', function () {
            global.clearTimeout(timer);
            timer = global.setTimeout(function () {
                state.query = input.value;
                state.page = 1;
                loadCatalog();
            }, SEARCH_DEBOUNCE);
        });
    }

    /* Nothing here can run without the routes, which exist only when
       dashboard.online_watch is on. Leaving the hosts empty rather than filling
       them with apologies is what lets AGP.syncTabs() retire their tabs. */
    function hideCatalog() {
        ['homeSeason', 'homeSchedule', 'homeCatalogHot', 'homeCatalogNew', 'homeCatalog']
            .forEach(function (id) {
                var host = el(id);
                if (host) { host.innerHTML = ''; }
            });
        AGP.syncTabs();
    }

    async function boot() {
        if (!el('homeCatalog')) { return; }

        /* 巴哈 numbers the week 1..7 from Monday; JavaScript numbers it 0..6
           from Sunday. */
        var jsDay = new Date().getDay();
        state.weekday = jsDay === 0 ? 7 : jsDay;

        /* The watch page's search box is a GET form aimed at this page, so a
           search can arrive in the URL rather than through the input. */
        try {
            state.query = new URLSearchParams(global.location.search).get('q') || '';
        } catch (error) {
            state.query = '';
        }

        try {
            state.index = await getJson('./catalog/index.json');
        } catch (error) {
            hideCatalog();
            return;
        }

        renderSeason();
        renderSchedule();
        renderHot();
        renderNewAdded();
        await loadCatalog();
        syncSheetToHash();
    }

    document.addEventListener('click', onClick);
    global.addEventListener('popstate', syncSheetToHash);
    document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape' && state.sheetSn) { dismissSheet(); }
    });

    document.addEventListener('DOMContentLoaded', function () {
        wireSearch();
        boot();
    });
}(window));
