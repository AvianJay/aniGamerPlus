/* ---------------------------------------------------------------------------
   aniGamerPlus+ — shared shell helpers
   Artwork synthesis, small formatters, the inline icon set, and the
   add-to-home-screen plumbing. Every page loads this before its own script.
   --------------------------------------------------------------------------- */
(function (global) {
    'use strict';

    var ICONS = {
        search: '<path d="M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16Z"/><path d="m21 21-4.3-4.3"/>',
        play: '<polygon points="6 3 20 12 6 21 6 3" fill="currentColor" stroke="none"/>',
        pause: '<rect x="6" y="4" width="4" height="16" fill="currentColor" stroke="none"/><rect x="14" y="4" width="4" height="16" fill="currentColor" stroke="none"/>',
        heart: '<path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>',
        eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>',
        clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        chevronLeft: '<path d="m15 18-6-6 6-6"/>',
        chevronRight: '<path d="m9 18 6-6-6-6"/>',
        chevronDown: '<path d="m6 9 6 6 6-6"/>',
        check: '<path d="m20 6-11 11-5-5"/>',
        share: '<path d="M4 12v7a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7"/><path d="M16 6l-4-4-4 4"/><path d="M12 2v14"/>',
        plusSquare: '<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M12 8v8M8 12h8"/>',
        volume: '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" fill="currentColor" stroke="none"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/>',
        volumeOff: '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" fill="currentColor" stroke="none"/><path d="m17 9 5 6M22 9l-5 6"/>',
        captions: '<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M8 11.5a2 2 0 1 0 0 3M16 11.5a2 2 0 1 0 0 3"/>',
        danmaku: '<path d="M21 12a8 8 0 0 1-8 8H4l2.2-2.6A8 8 0 1 1 21 12Z"/><path d="M8 10h8M8 14h4"/>',
        settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 9 19.4a1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 4.6 9a1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1Z"/>',
        pip: '<rect x="2" y="4" width="20" height="16" rx="3"/><rect x="12" y="12" width="8" height="6" rx="1.5" fill="currentColor" stroke="none"/>',
        expand: '<path d="M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3"/>',
        compress: '<path d="M8 3v3a2 2 0 0 1-2 2H3M16 3v3a2 2 0 0 0 2 2h3M8 21v-3a2 2 0 0 0-2-2H3M16 21v-3a2 2 0 0 1 2-2h3"/>',
        skipBack: '<path d="M11 19 2 12l9-7v14Z" fill="currentColor" stroke="none"/><path d="M22 19l-9-7 9-7v14Z" fill="currentColor" stroke="none"/>',
        skipForward: '<path d="m13 5 9 7-9 7V5Z" fill="currentColor" stroke="none"/><path d="M2 5l9 7-9 7V5Z" fill="currentColor" stroke="none"/>',
        rotateCcw: '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/>',
        rotateCw: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
        loader: '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M18.4 5.6l-2.8 2.8M8.4 15.6l-2.8 2.8"/>',
        x: '<path d="M18 6 6 18M6 6l12 12"/>',
        list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
        star: '<polygon points="12 2 15.1 8.6 22 9.6 17 14.5 18.2 21.5 12 18.2 5.8 21.5 7 14.5 2 9.6 8.9 8.6 12 2"/>',
        home: '<path d="m3 10.5 9-7.5 9 7.5"/><path d="M5.5 9.2V21h13V9.2"/>',
        grid: '<rect x="3" y="3" width="7.5" height="7.5" rx="1.6"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.6"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.6"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.6"/>',
        history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6L3 8.5"/><path d="M3 3.5V9h5.5"/><path d="M12 7.5V12l3.2 1.9"/>',
        user: '<circle cx="12" cy="8" r="4"/><path d="M4.5 20.5c0-3.6 3.4-5.5 7.5-5.5s7.5 1.9 7.5 5.5"/>',
        keyboard: '<rect x="2" y="6" width="20" height="12" rx="2.5"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M8 14h8"/>'
    };

    /* A single 24-box lucide-style icon factory: every glyph in the app comes
       from here so stroke weight and sizing stay consistent. */
    function icon(name, size) {
        var body = ICONS[name];
        if (!body) { return ''; }
        var px = size || 20;
        return '<svg viewBox="0 0 24 24" width="' + px + '" height="' + px + '" fill="none" stroke="currentColor" ' +
            'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + body + '</svg>';
    }

    function escapeHtml(value) {
        return String(value === null || value === undefined ? '' : value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function hashString(value) {
        var str = String(value || '');
        var hash = 5381;
        for (var i = 0; i < str.length; i++) {
            hash = ((hash << 5) + hash + str.charCodeAt(i)) | 0;
        }
        return Math.abs(hash);
    }

    /* video_list.json has no cover art. Rather than ship a grey placeholder for
       every card, derive a stable two-stop plate from the title: the same anime
       always looks the same, and a wall of cards still reads as distinct rows. */
    function artFor(name) {
        var hash = hashString(name);
        var hue = hash % 360;
        var hue2 = (hue + 38 + (hash % 40)) % 360;
        return 'linear-gradient(135deg, hsl(' + hue + ' 58% 26%), hsl(' + hue2 + ' 62% 15%))';
    }

    function initials(name) {
        var str = String(name || '').trim();
        if (!str) { return '?'; }
        /* CJK titles read best as their first two characters; latin ones as
           the initials of the first two words. */
        if (/[\u3000-\u9fff\uac00-\ud7af\uff00-\uffef]/.test(str.charAt(0))) {
            return str.slice(0, 2);
        }
        var words = str.split(/\s+/).slice(0, 2);
        return words.map(function (word) { return word.charAt(0).toUpperCase(); }).join('');
    }

    function pad2(value) {
        return (value < 10 ? '0' : '') + value;
    }

    function formatClock(seconds) {
        var total = Math.max(0, Math.floor(Number(seconds) || 0));
        var h = Math.floor(total / 3600);
        var m = Math.floor((total % 3600) / 60);
        var s = total % 60;
        return h > 0 ? h + ':' + pad2(m) + ':' + pad2(s) : m + ':' + pad2(s);
    }

    function formatCount(value) {
        var n = Number(value) || 0;
        if (n >= 10000) { return (n / 10000).toFixed(1).replace(/\.0$/, '') + '萬'; }
        if (n >= 1000) { return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'K'; }
        return String(n);
    }

    var WEEKDAYS = ['週日', '週一', '週二', '週三', '週四', '週五', '週六'];

    function dayKey(timestamp) {
        var date = new Date((Number(timestamp) || 0) * 1000);
        return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate());
    }

    function dayLabel(timestamp) {
        var date = new Date((Number(timestamp) || 0) * 1000);
        var today = new Date();
        var diffDays = Math.round((new Date(today.getFullYear(), today.getMonth(), today.getDate()) -
            new Date(date.getFullYear(), date.getMonth(), date.getDate())) / 86400000);
        var stamp = (date.getMonth() + 1) + '/' + date.getDate();
        if (diffDays === 0) { return { title: '今天', sub: stamp + ' ' + WEEKDAYS[date.getDay()] }; }
        if (diffDays === 1) { return { title: '昨天', sub: stamp + ' ' + WEEKDAYS[date.getDay()] }; }
        return { title: stamp, sub: WEEKDAYS[date.getDay()] };
    }

    function clockOf(timestamp) {
        var date = new Date((Number(timestamp) || 0) * 1000);
        return pad2(date.getHours()) + ':' + pad2(date.getMinutes());
    }

    /* --- add to home screen ------------------------------------------------ */

    function isStandalone() {
        /* The native shell is neither: WKWebView reports display-mode browser
           and has no navigator.standalone at all, so without the bridge check
           the app would offer to install the app the viewer is already in. */
        return !!global.AgpNative ||
            global.navigator.standalone === true ||
            (global.matchMedia && global.matchMedia('(display-mode: standalone)').matches);
    }

    function isIos() {
        var ua = global.navigator.userAgent || '';
        /* iPadOS 13+ reports itself as a Mac; the touch-point count is what
           still separates it from a desktop Safari. */
        return /iPad|iPhone|iPod/.test(ua) ||
            (/Macintosh/.test(ua) && global.navigator.maxTouchPoints > 1);
    }

    var HINT_KEY = 'agp-a2hs-dismissed';

    function mountInstallHint() {
        if (!isIos() || isStandalone()) { return; }
        try {
            if (global.localStorage && global.localStorage.getItem(HINT_KEY) === '1') { return; }
        } catch (error) { /* private mode: just show it */ }

        var hint = document.createElement('aside');
        hint.className = 'agp-a2hs';
        hint.id = 'agpA2HS';
        hint.setAttribute('role', 'note');
        hint.innerHTML =
            '<img src="./static/img/pwa/icon-192.png" alt="">' +
            '<div class="agp-a2hs-copy">' +
            '<strong>加入主畫面</strong>' +
            '<p>點選分享 ' + icon('share', 13) + ' 後選擇「加入主畫面」' + icon('plusSquare', 13) +
            '，即可全螢幕使用 aniGamerPlus+。</p>' +
            '</div>' +
            '<button type="button" aria-label="關閉提示">&times;</button>';
        hint.querySelector('button').addEventListener('click', function () {
            hint.hidden = true;
            try { global.localStorage.setItem(HINT_KEY, '1'); } catch (error) { /* ignore */ }
        });
        document.body.appendChild(hint);
    }

    /* Standalone iOS has no browser chrome, so a plain <a> to another origin —
       or any target that opens a new context — kicks the user out to Safari and
       never comes back. Keep same-origin navigation inside the app window. */
    function keepNavigationInApp() {
        if (!isStandalone()) { return; }
        document.addEventListener('click', function (event) {
            var link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
            if (!link || link.target === '_blank' || link.hasAttribute('download')) { return; }
            var url = new URL(link.href, global.location.href);
            if (url.origin !== global.location.origin) { return; }
            if (url.href === global.location.href) { return; }
            event.preventDefault();
            global.location.href = url.href;
        });
    }

    function registerServiceWorker() {
        if (!('serviceWorker' in global.navigator)) { return; }
        if (global.location.protocol !== 'https:' && global.location.hostname !== 'localhost' &&
            global.location.hostname !== '127.0.0.1') {
            /* Service workers are refused on plain http outside localhost, and
               the console error is noise the user cannot act on. */
            return;
        }
        global.addEventListener('load', function () {
            global.navigator.serviceWorker.register('./sw.js', { scope: './' }).catch(function (error) {
                console.warn('Service worker registration failed:', error);
            });
        });
    }

    function initPwa() {
        registerServiceWorker();
        keepNavigationInApp();
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', mountInstallHint);
        } else {
            mountInstallHint();
        }
    }

    /* --- rails ------------------------------------------------------------- */

    function wireRail(wrap) {
        var rail = wrap.querySelector('.agp-rail');
        if (!rail) { return; }
        wrap.querySelectorAll('.agp-rail-nav').forEach(function (button) {
            button.addEventListener('click', function () {
                var step = Math.max(240, Math.round(rail.clientWidth * 0.8));
                rail.scrollBy({ left: button.dataset.dir === 'prev' ? -step : step, behavior: 'smooth' });
            });
        });
    }

    /* --- section chrome ---------------------------------------------------- */

    /* The home page and the catalog draw the same furniture around different
       data, and two copies of it drift apart the first time one grows a class. */
    function railHtml(cardsHtml, railId) {
        return '<div class="agp-rail-wrap">' +
            '<button class="agp-rail-nav" data-dir="prev" type="button" aria-label="上一頁">' +
            icon('chevronLeft', 18) + '</button>' +
            '<div class="agp-rail" id="' + railId + '">' + cardsHtml + '</div>' +
            '<button class="agp-rail-nav" data-dir="next" type="button" aria-label="下一頁">' +
            icon('chevronRight', 18) + '</button>' +
            '</div>';
    }

    function sectionHtml(id, title, bodyHtml, moreHref, moreLabel) {
        return '<section class="agp-section" id="' + id + '">' +
            '<div class="agp-section-head"><h2>' + escapeHtml(title) + '</h2>' +
            (moreHref ? '<a class="agp-section-more" href="' + escapeHtml(moreHref) + '">' +
                escapeHtml(moreLabel || '看更多') + ' ' + icon('chevronRight', 13) + '</a>' : '') +
            '</div>' + bodyHtml + '</section>';
    }

    /* --- 收藏 -------------------------------------------------------------- */

    /* 以前一部作品收藏與否是一個 'agp-fav-<雜湊>' 的布林值. 要列出收藏清單的
       時候就卡住了: 雜湊回不去片名, 除非把認識的片名全部算一遍去猜。改成一份
       清單, 順便把封面跟入口那一集記著 —— 收藏的作品不一定在片庫裡, 邊看邊
       下載按下收藏的那一刻硬碟上還沒有檔案 */
    var FAV_KEY = 'agp-favs';

    function readStore(key, fallback) {
        try {
            var value = global.localStorage.getItem(key);
            return value === null ? fallback : value;
        } catch (error) {
            return fallback;
        }
    }

    function writeStore(key, value) {
        try {
            global.localStorage.setItem(key, String(value));
        } catch (error) { /* 無痕模式寫不進去, 收藏丟了也不該弄壞整頁 */ }
    }

    function favList() {
        var list;
        try {
            list = JSON.parse(readStore(FAV_KEY, '[]'));
        } catch (error) {
            return [];
        }
        return Array.isArray(list) ? list.filter(function (item) {
            return item && item.name;
        }) : [];
    }

    function favSave(list) {
        writeStore(FAV_KEY, JSON.stringify(list));
    }

    /* 播放頁看到的片名是官方的作品名, 片庫看到的是資料夾名, 兩邊未必一樣.
       兩個都比對過才不會同一部作品收藏兩次 */
    function favSame(item, name) {
        return item.name === name || (!!item.alias && item.alias === name);
    }

    function favHas(name) {
        return favList().some(function (item) { return favSame(item, name); });
    }

    function favRemove(name) {
        favSave(favList().filter(function (item) { return !favSame(item, name); }));
    }

    function favAdd(entry) {
        if (!entry || !entry.name) { return; }
        var list = favList().filter(function (item) { return !favSame(item, entry.name); });
        list.unshift({
            name: entry.name,
            alias: entry.alias && entry.alias !== entry.name ? entry.alias : '',
            sn: entry.sn ? String(entry.sn) : '',
            res: entry.res ? String(entry.res) : '',
            cover: entry.cover || '',
            added: entry.added || Math.floor(new Date().getTime() / 1000)
        });
        favSave(list);
    }

    /* 舊的那些 key 還躺在瀏覽器裡. 拿現在認得的片名回頭比對一次就搬得回來 ——
       猜不到名字的就留在原地, 反正也沒有人再讀它 */
    function favAdopt(entries) {
        (entries || []).forEach(function (entry) {
            if (!entry || !entry.name) { return; }
            var key = 'agp-fav-' + hashString(entry.name);
            if (readStore(key, '0') !== '1') { return; }
            writeStore(key, '0');
            if (!favHas(entry.name)) { favAdd(entry); }
        });
    }

    /* --- 底部頁籤 ---------------------------------------------------------- */

    var TABBAR = [
        ['home', '首頁', 'home'],
        ['all', '所有動畫', 'grid'],
        ['fav', '收藏', 'heart'],
        ['history', '紀錄', 'history'],
        ['mine', '我的', 'user']
    ];

    var paneListeners = [];
    var openPane = '';

    function paneNodes() {
        return Array.prototype.slice.call(document.querySelectorAll('.agp-pane'));
    }

    /* 切分頁只有這一條路. 打字要跳到「所有動畫」, 點下面那排也是, 兩邊各寫一次
       遲早會有一邊忘了把頁籤點亮 */
    function showPane(name, options) {
        var opts = options || {};
        var nodes = paneNodes();
        var wanted = nodes.filter(function (node) { return node.dataset.pane === name; })[0];
        if (!wanted) { return; }
        var changed = openPane !== name;
        openPane = name;
        nodes.forEach(function (node) { node.hidden = node !== wanted; });
        document.querySelectorAll('.agp-tabbar-btn').forEach(function (button) {
            var on = button.dataset.pane === name;
            button.classList.toggle('is-on', on);
            /* aria-current 而不是 aria-selected: 這排是導覽連結, 不是 tablist */
            if (on) { button.setAttribute('aria-current', 'page'); }
            else { button.removeAttribute('aria-current'); }
        });
        /* 捲回頂端只在「人自己按了下面那一排」的時候做. 打字時跟著捲, 就又變回
           畫面在指頭底下自己跑的那個毛病 */
        if (opts.top) { global.scrollTo(0, 0); }
        paneListeners.forEach(function (listener) { listener(name, changed, opts); });
    }

    function currentPane() {
        return openPane;
    }

    function onPane(listener) {
        paneListeners.push(listener);
    }

    function mountTabbar() {
        var bar = document.querySelector('.agp-tabbar');
        if (!bar) { return; }
        bar.innerHTML = TABBAR.map(function (tab) {
            return '<a class="agp-tabbar-btn" href="./?tab=' + tab[0] + '" data-pane="' + tab[0] + '">' +
                icon(tab[2], 21) + '<span>' + escapeHtml(tab[1]) + '</span></a>';
        }).join('');
        bar.addEventListener('click', function (event) {
            var button = event.target.closest('.agp-tabbar-btn');
            if (!button) { return; }
            event.preventDefault();
            showPane(button.dataset.pane, { top: true, tap: true });
        });
        if (!openPane) { showPane('home'); }
    }

    document.addEventListener('DOMContentLoaded', mountTabbar);

    /* --- toast ------------------------------------------------------------- */

    /* 排下載這件事沒有畫面可以看: 按下去之後不是跳走就是什麼都沒發生, 而「什麼
       都沒發生」正是失敗的樣子. 片單跟首頁都需要一句話, 所以放在這裡 */
    var toastTimer = 0;

    function toast(message, ms) {
        var host = document.getElementById('agpToast');
        if (!host) {
            host = document.createElement('div');
            host.id = 'agpToast';
            host.className = 'agp-toast';
            host.setAttribute('role', 'status');
            document.body.appendChild(host);
        }
        host.textContent = message;
        host.classList.add('is-on');
        global.clearTimeout(toastTimer);
        toastTimer = global.setTimeout(function () {
            host.classList.remove('is-on');
        }, ms || 3200);
    }

    global.AGP = {
        icon: icon,
        icons: ICONS,
        escapeHtml: escapeHtml,
        hashString: hashString,
        artFor: artFor,
        initials: initials,
        formatClock: formatClock,
        formatCount: formatCount,
        dayKey: dayKey,
        dayLabel: dayLabel,
        clockOf: clockOf,
        weekdays: WEEKDAYS,
        isStandalone: isStandalone,
        isIos: isIos,
        initPwa: initPwa,
        wireRail: wireRail,
        railHtml: railHtml,
        sectionHtml: sectionHtml,
        readStore: readStore,
        writeStore: writeStore,
        favourites: {
            list: favList,
            has: favHas,
            add: favAdd,
            remove: favRemove,
            adopt: favAdopt
        },
        showPane: showPane,
        currentPane: currentPane,
        onPane: onPane,
        toast: toast
    };

    initPwa();
}(window));
