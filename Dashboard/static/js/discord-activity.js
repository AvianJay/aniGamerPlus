(function () {
    'use strict';

    var proxy = /(^|\.)discordsays\.com$/.test(window.location.hostname) ? '/.proxy' : '';
    var root = proxy + '/';
    document.documentElement.classList.toggle('activity-mobile',
        new URLSearchParams(window.location.search).get('platform') === 'mobile');
    var endpoint = root + 'discord/activity/';
    var sdk = null;
    var config = null;
    var identity = null;
    var csrf = '';
    var instanceId = '';
    var currentState = null;
    var videos = [];
    var joined = false;
    var starting = false;
    var libraryLoaded = false;
    var currentVideo = '';
    var currentWatchToken = '';
    var grantExpiryTimer = 0;
    var memberSignature = '';
    var accessRequests = new Set();
    var pollTimer = 0;
    var toastTimer = 0;
    var pollFailures = 0;
    var pollInFlight = false;
    var snapshotReceivedAt = 0;
    var lastSync = 0;
    var controlChain = Promise.resolve();
    var controlEpoch = 0;
    var expanded = false;
    var autoGrantPending = false;
    var presence = null;
    var presencePending = false;
    var presenceScopeGranted = false;
    var playbackMetadata = null;
    var layoutSubscribed = false;
    var frame = document.getElementById('activityPlayer');
    var elements = {};
    [
        'connectionStatus', 'accountToggle', 'accountPanel', 'accountClose',
        'accountDescription', 'accountIdentity', 'accountForm', 'accountUsername',
        'accountPassword', 'accountLogin', 'accountActions', 'accountLink',
        'accountUnlink', 'accountSwitch', 'accountFeedback', 'activityNotice',
        'playerPlaceholder', 'lobbyTitle', 'lobbyDescription', 'connectButton',
        'playingTitle', 'playingEpisode', 'playbackRole', 'controlDescription',
        'memberCount', 'memberList', 'refreshLibrary', 'librarySearch',
        'libraryHint', 'libraryList', 'activityToast', 'activityExpandedExit',
        'autoGrantControls', 'autoGrantToggle', 'activityPresenceToggle', 'activityLoginPrompt',
        'accountRemember'
    ].forEach(function (id) { elements[id] = document.getElementById(id); });

    function status(text, state) {
        elements.connectionStatus.textContent = text;
        elements.connectionStatus.dataset.state = state || '';
    }

    function notice(message) {
        elements.activityNotice.textContent = message || '';
        elements.activityNotice.hidden = !message;
    }

    function toast(message) {
        clearTimeout(toastTimer);
        elements.activityToast.textContent = message;
        elements.activityToast.hidden = false;
        toastTimer = setTimeout(function () { elements.activityToast.hidden = true; }, 4500);
    }

    function postExpanded() {
        if (frame.contentWindow) {
            frame.contentWindow.postMessage({ type: 'agp:activity-fullscreen-state', expanded: expanded }, window.location.origin);
        }
    }

    function subscribeLayout() {
        if (layoutSubscribed || !sdk || typeof sdk.subscribe !== 'function') { return; }
        layoutSubscribed = true;
        var change = function (value) {
            if (!value || [0, 1, 2].indexOf(value.layout_mode) === -1) { return; }
            document.body.classList.toggle('activity-client-compact', value.layout_mode !== 0);
        };
        try {
            Promise.resolve(sdk.subscribe('ACTIVITY_LAYOUT_MODE_UPDATE', change)).catch(function () {
                layoutSubscribed = false;
            });
        } catch (_) { layoutSubscribed = false; }
    }

    function renderPresence() {
        elements.activityPresenceToggle.hidden = !presence;
        elements.activityPresenceToggle.disabled = presencePending || !identity || !identity.user;
        var enabled = !!(presence && presence.enabled);
        elements.activityPresenceToggle.setAttribute('aria-pressed', String(enabled));
        elements.activityPresenceToggle.textContent = '顯示播放動態：' + (enabled ? '開啟' : '關閉');
    }

    function updatePresence() {
        if (!presence) { return; }
        if (!joined || !currentState || !currentState.can_watch || !currentVideo) {
            presence.clear();
            return;
        }
        var state = Object.assign({}, currentState);
        state.server_time += Math.max(0, performance.now() - snapshotReceivedAt) / 1000;
        presence.update({ state: state, identity: identity,
            video: findVideo(currentVideo), player: playbackMetadata });
    }

    async function authorizePresence() {
        if (presenceScopeGranted) { return; }
        if (!sdk || !identity || !identity.user) { throw new Error('請先連線 Discord。'); }
        var userId = String(identity.user.id);
        var authorized = await sdk.commands.authorize({
            client_id: config.client_id, response_type: 'code', state: csrf,
            prompt: 'none', scope: ['identify', 'applications.commands', 'rpc.activities.write']
        });
        var exchanged = await api('presence-token', { code: authorized.code });
        var auth = await sdk.commands.authenticate({ access_token: exchanged.access_token });
        delete exchanged.access_token;
        if (!auth || !auth.user || String(auth.user.id) !== userId ||
            !identity || String(identity.user.id) !== userId) {
            throw new Error('Discord 身分已變更，請重新連線。');
        }
        presenceScopeGranted = true;
    }

    function setupPresence() {
        if (!window.AgpDiscordPresence) { return; }
        if (!presence) {
            presence = window.AgpDiscordPresence.create({ sdk: sdk, authorize: authorizePresence,
                onChange: renderPresence,
                onError: function () { toast('無法更新 Discord 播放動態，觀看不受影響。'); }
            });
        }
        renderPresence();
    }

    async function togglePresence() {
        if (!presence || presencePending) { return; }
        presencePending = true;
        renderPresence();
        try {
            await presence.setEnabled(!presence.enabled);
            updatePresence();
        } catch (_) {
            toast('未能啟用播放動態，請確認 Discord 已允許播放動態權限。');
        } finally {
            presencePending = false;
            renderPresence();
        }
    }

    function setExpanded(on) {
        expanded = !!on && joined && !!currentVideo && !frame.hidden;
        document.body.classList.toggle('activity-player-expanded', expanded);
        elements.activityExpandedExit.hidden = !expanded;
        postExpanded();
        if (expanded) { frame.focus(); }
    }

    function renderAutoGrant() {
        var available = !!(joined && currentState && currentState.auto_grant_available &&
            currentState.is_host && identity && identity.account && config && config.requires_login);
        elements.autoGrantControls.hidden = !available;
        elements.autoGrantToggle.disabled = !available || autoGrantPending;
        var enabled = !!(currentState && currentState.auto_grant);
        elements.autoGrantToggle.setAttribute('aria-pressed', String(enabled));
        elements.autoGrantToggle.textContent = '自動授權訪客：' + (enabled ? '開啟' : '關閉');
    }

    async function toggleAutoGrant() {
        if (autoGrantPending || !joined || !currentState || !currentState.auto_grant_available ||
            !currentState.is_host || !identity || !identity.account) { return; }
        var enable = !currentState.auto_grant;
        autoGrantPending = true;
        renderAutoGrant();
        try {
            acceptState(await api('auto-grant', { instance_id: instanceId, enabled: enable }));
            toast(enable ? '已開啟自動授權，每集都會使用新的觀看授權。' : '已關閉自動授權，手動授權仍然保留。');
        } catch (error) {
            toast(errorMessage(error, '無法更新自動授權，請稍後再試。'));
        } finally {
            autoGrantPending = false;
            renderAutoGrant();
        }
    }

    function errorMessage(error, fallback) {
        return error && error.message ? error.message : fallback;
    }

    async function api(path, body, options) {
        options = options || {};
        var controller = new AbortController();
        var timeout = setTimeout(function () { controller.abort(); }, 15000);
        var headers = { 'Accept': 'application/json' };
        if (body !== undefined) {
            headers['Content-Type'] = 'application/json';
            headers['X-Activity-CSRF'] = csrf;
        }
        var response;
        try {
            response = await fetch(options.absolute || endpoint + path, {
                method: body === undefined ? 'GET' : 'POST',
                headers: headers,
                body: body === undefined ? undefined : JSON.stringify(body),
                credentials: 'same-origin',
                cache: 'no-store',
                signal: controller.signal,
                keepalive: !!options.keepalive
            });
            var data;
            try { data = await response.json(); } catch (_) { data = {}; }
            if (!response.ok) {
                var failure = new Error(data.message || '暫時無法連線，請稍後再試。');
                failure.status = response.status;
                failure.code = data.error;
                throw failure;
            }
            return data;
        } catch (error) {
            if (error.name === 'AbortError') { throw new Error('連線逾時，請稍後再試。'); }
            if (error instanceof TypeError) { throw new Error('無法連到伺服器，正在等候網路恢復。'); }
            throw error;
        } finally {
            clearTimeout(timeout);
        }
    }

    function openAccount(open) {
        if (open && expanded) { setExpanded(false); }
        elements.accountPanel.hidden = !open;
        document.body.classList.toggle('activity-account-open', open);
        elements.accountToggle.setAttribute('aria-expanded', String(open));
        if (open) {
            requestAnimationFrame(function () {
                if (elements.accountPanel.hidden) { return; }
                if (!elements.accountForm.hidden) { elements.accountUsername.focus(); }
                else { elements.accountClose.focus(); }
            });
        }
    }

    function accountFeedback(message, success) {
        elements.accountFeedback.textContent = message || '';
        elements.accountFeedback.classList.toggle('is-success', !!success);
    }

    function renderIdentity() {
        var account = identity && identity.account;
        var user = identity && identity.user;
        var linked = !!(identity && identity.linked);
        var accountsEnabled = !!(config && config.accounts_enabled);
        elements.accountToggle.disabled = !user || !accountsEnabled;
        elements.accountToggle.hidden = !!config && !accountsEnabled;
        elements.activityLoginPrompt.hidden = !user || !accountsEnabled || !!account;
        elements.accountToggle.textContent = account ? account.username : '登入帳號';
        elements.accountToggle.dataset.initial = account ? Array.from(account.username)[0].toUpperCase() : '?';
        elements.accountToggle.dataset.linked = String(linked);
        elements.accountToggle.title = account ? (linked ? '已綁定 Discord，會自動登入' : '尚未綁定 Discord') : '';
        elements.accountIdentity.hidden = !account;
        elements.accountActions.hidden = !account;
        elements.accountForm.hidden = !!account || !accountsEnabled;
        elements.accountLink.hidden = linked;
        elements.accountUnlink.hidden = !linked;
        if (account) {
            elements.accountIdentity.textContent = account.username + (linked ? ' · 已綁定 Discord' : ' · 尚未綁定 Discord');
        }
        var discordName = user ? String(user.global_name || user.username || '') : '';
        if (!accountsEnabled) {
            elements.accountDescription.textContent = '這台伺服器未啟用網站帳號，將以 Discord 身分加入。';
        } else if (linked) {
            elements.accountDescription.textContent = '此 Discord 帳號已綁定，之後開啟活動會自動登入。解除綁定後需要重新輸入密碼。';
        } else if (account) {
            elements.accountDescription.textContent = '綁定後，' + (discordName || '這個 Discord 帳號') + ' 下次開啟活動就會自動登入。';
        } else {
            elements.accountDescription.textContent = config && config.requires_login
                ? '登入後即可選片與觀看；未登入也可以等主辦人授權觀看目前這集。'
                : '登入後會使用你的網站帳號；不登入也能以 Discord 身分觀看。';
        }
    }

    function hasLibraryAccess() {
        return !!(identity && identity.account) || !!(config && !config.requires_login);
    }

    function memberName(member) {
        return String(member.name || member.username || 'Discord 使用者');
    }

    function renderMembers(state) {
        var members = Array.isArray(state.members) ? state.members : [];
        elements.memberCount.textContent = String(members.length);
        var fragment = document.createDocumentFragment();
        members.forEach(function (member) {
            var row = document.createElement('li');
            row.className = 'activity-member';
            var avatar = document.createElement('span');
            avatar.className = 'activity-avatar';
            avatar.setAttribute('aria-hidden', 'true');
            avatar.textContent = Array.from(memberName(member))[0].toUpperCase();
            var name = document.createElement('span');
            name.className = 'activity-member-name';
            var isSelf = identity && identity.user && String(member.id) === String(identity.user.id);
            name.textContent = memberName(member) + (isSelf ? '（你）' : '');
            var role = document.createElement('span');
            var isHost = String(member.id) === String(state.host_id);
            role.className = 'activity-member-label' + (isHost ? '' : ' is-viewer');
            role.textContent = isHost ? '主控' : member.requires_approval ? '等待授權' : member.is_guest && member.authorized ? '本片訪客' : '觀看中';
            row.append(avatar, name, role);
            if (state.is_host && identity && identity.account && config && config.requires_login && state.sn && !isSelf && member.is_guest) {
                var permission = document.createElement('button');
                permission.type = 'button';
                permission.className = 'activity-button activity-member-permission' + (member.authorized ? ' is-revoke' : '');
                permission.dataset.accessAction = member.authorized ? 'revoke' : 'grant';
                permission.dataset.userId = String(member.id);
                permission.dataset.sn = String(state.sn);
                permission.disabled = accessRequests.has(String(member.id));
                permission.textContent = member.authorized ? '撤銷授權' : '授權看這集';
                permission.setAttribute('aria-label', (member.authorized ? '撤銷 ' : '授權 ') + memberName(member) + ' 觀看目前這集');
                row.appendChild(permission);
            }
            fragment.appendChild(row);
        });
        elements.memberList.replaceChildren(fragment);
    }

    function episodeLabel(video) {
        var episode = String(video.episode || video.episode_name || '');
        return episode ? (/^第|集$|話$/.test(episode) ? episode : '第 ' + episode + ' 集') : 'SN ' + String(video.sn);
    }

    function findVideo(sn) {
        return videos.find(function (video) { return String(video.sn) === String(sn); });
    }

    function renderPlaying() {
        var sn = currentState && currentState.sn;
        var video = sn ? findVideo(sn) : null;
        elements.playingTitle.textContent = video ? String(video.anime_name || video.title || '未命名作品') : (sn ? '共同播放中' : '尚未選片');
        elements.playingEpisode.textContent = video ? episodeLabel(video) : (sn ? '主辦人目前選擇的這一集' : '等主控選一集，就可以開始了。');
    }

    function renderLibrary() {
        if (!hasLibraryAccess()) {
            elements.libraryList.replaceChildren();
            elements.librarySearch.disabled = true;
            elements.refreshLibrary.disabled = true;
            elements.libraryHint.textContent = '訪客只能觀看主辦人授權的這一集，換片後需重新授權。';
            return;
        }
        var term = elements.librarySearch.value.trim().toLocaleLowerCase();
        var filtered = videos.filter(function (video) {
            return (String(video.anime_name || video.title || '') + ' ' + episodeLabel(video)).toLocaleLowerCase().includes(term);
        });
        var isHost = !!(joined && currentState && currentState.is_host);
        var selected = currentState && String(currentState.sn || '');
        var fragment = document.createDocumentFragment();
        if (!filtered.length && libraryLoaded) {
            var empty = document.createElement('p');
            empty.className = 'activity-empty';
            empty.textContent = term ? '沒有符合的作品，換個關鍵字試試。' : '片庫目前沒有影片，請先在主控台加入下載。';
            fragment.appendChild(empty);
        }
        // Keep large personal libraries responsive; searching still covers every episode.
        filtered.slice(0, 200).forEach(function (video) {
            var sn = String(video.sn);
            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'activity-episode' + (selected === sn ? ' is-selected' : '');
            button.disabled = !isHost || selected === sn;
            button.dataset.sn = sn;
            button.setAttribute('aria-label', String(video.anime_name || video.title || '未命名作品') + '，' + episodeLabel(video) + (selected === sn ? '，正在播放' : ''));
            var art = document.createElement('span');
            art.className = 'activity-episode-art';
            art.setAttribute('aria-hidden', 'true');
            art.textContent = selected === sn ? '▶' : '▷';
            var details = document.createElement('span');
            details.className = 'activity-episode-details';
            var title = document.createElement('span');
            title.className = 'activity-episode-title';
            title.textContent = String(video.anime_name || video.title || '未命名作品');
            title.title = title.textContent;
            var meta = document.createElement('span');
            meta.className = 'activity-episode-meta';
            meta.textContent = episodeLabel(video) + (video.resolution ? ' · ' + String(video.resolution) + 'P' : '');
            details.append(title, meta);
            button.append(art, details);
            if (selected === sn) {
                var playing = document.createElement('span');
                playing.className = 'activity-episode-indicator';
                playing.textContent = '播放中';
                button.appendChild(playing);
            }
            fragment.appendChild(button);
        });
        if (filtered.length > 200) {
            var more = document.createElement('p');
            more.className = 'activity-empty';
            more.textContent = '共 ' + filtered.length + ' 集，請搜尋作品以縮小範圍。';
            fragment.appendChild(more);
        }
        elements.libraryList.replaceChildren(fragment);
        if (libraryLoaded) {
            elements.libraryHint.textContent = isHost ? '你是主控，選一集讓大家一起看。' : '由主控選片，所有人同步觀看。';
        }
    }

    async function loadLibrary() {
        if (!joined || !hasLibraryAccess()) { renderLibrary(); return; }
        elements.refreshLibrary.disabled = true;
        elements.libraryHint.textContent = '正在載入片庫…';
        try {
            var data = await api('', undefined, { absolute: root + 'video_list.json' });
            videos = Array.isArray(data.videos) ? data.videos.filter(function (video) { return video && video.sn != null; }) : [];
            videos.sort(function (a, b) {
                var timestamp = (Number(b.timestamp) || 0) - (Number(a.timestamp) || 0);
                if (timestamp) { return timestamp; }
                return String(a.anime_name || '').localeCompare(String(b.anime_name || ''), 'zh-Hant', { numeric: true }) || String(a.episode || '').localeCompare(String(b.episode || ''), 'zh-Hant', { numeric: true });
            });
            libraryLoaded = true;
            elements.librarySearch.disabled = false;
            renderLibrary();
            renderPlaying();
        } catch (error) {
            elements.libraryHint.textContent = errorMessage(error, '載入片庫失敗，請重新整理。');
        } finally {
            elements.refreshLibrary.disabled = !joined || !hasLibraryAccess();
        }
    }

    function postState() {
        if (!frame.contentWindow || !currentState || !currentVideo || !joined || !currentState.can_watch) { return; }
        var projected = Object.assign({}, currentState);
        if (!projected.paused) {
            var elapsed = Math.max(0, Number(projected.server_time) - Number(projected.updated_at)) +
                Math.max(0, performance.now() - snapshotReceivedAt) / 1000;
            projected.position = Number(projected.position) + elapsed * Number(projected.rate);
        }
        frame.contentWindow.postMessage({
            type: 'agp:activity-state',
            state: projected,
            isHost: !!currentState.is_host
        }, window.location.origin);
    }

    function clearPlayer() {
        playbackMetadata = null;
        if (presence) { presence.clear(); }
        setExpanded(false);
        clearTimeout(grantExpiryTimer);
        if (frame.contentWindow) {
            frame.contentWindow.postMessage({ type: 'agp:activity-disconnect' }, window.location.origin);
        }
        frame.hidden = true;
        frame.removeAttribute('src');
        elements.playerPlaceholder.hidden = false;
        currentVideo = '';
        currentWatchToken = '';
    }

    function waitingForAccess(expired) {
        status('等待授權', '');
        elements.playbackRole.hidden = true;
        elements.lobbyTitle.textContent = expired ? '本集授權已到期' : '等候主辦人授權';
        elements.lobbyDescription.textContent = '你已加入房間。主辦人可以授權你觀看目前這集；也可以登入網站帳號繼續。';
        notice(expired ? '本集授權已到期，請主辦人重新授權。' : '訪客授權只對目前這集有效，換片或撤銷後會停止播放。');
    }

    function acceptState(state) {
        if (!joined || !state || state.instance_id !== instanceId) { return; }
        if (currentState && (Number(state.revision) < Number(currentState.revision) ||
            (Number(state.revision) === Number(currentState.revision) && Number(state.server_time) < Number(currentState.server_time)))) { return; }
        var roleChanged = !currentState || !!state.is_host !== !!currentState.is_host;
        var signature = JSON.stringify([state.members, state.host_id, state.is_host, !!(identity && identity.account), state.sn]);
        var membershipChanged = signature !== memberSignature;
        var oldHost = currentState && currentState.host_id;
        var canWatch = state.can_watch === true;
        var accessExpired = false;
        var nextVideo = canWatch ? String(state.sn || '') : '';
        var nextToken = canWatch ? String(state.watch_token || '') : '';
        var videoChanged = currentVideo !== nextVideo || currentWatchToken !== nextToken;
        currentState = state;
        snapshotReceivedAt = performance.now();
        renderAutoGrant();
        if (membershipChanged) { memberSignature = signature; renderMembers(state); }
        if (roleChanged) {
            elements.playbackRole.hidden = false;
            elements.playbackRole.dataset.role = state.is_host ? 'host' : 'viewer';
            elements.playbackRole.textContent = state.is_host ? '你是主控' : '同步觀看';
            elements.controlDescription.textContent = state.is_host ? '你控制大家的播放、暫停、快轉與倍速。音量與字幕可各自調整。' : '播放進度跟隨主控。你可以自行調整音量、字幕與全螢幕。';
            if (oldHost && state.is_host) { toast('主控已離開，現在由你控制播放。'); }
        }
        elements.playbackRole.hidden = !canWatch;
        if (canWatch && nextToken) {
            elements.playbackRole.textContent = '本片訪客';
            elements.controlDescription.textContent = '主辦人已授權你觀看這一集。換片後需要重新授權，音量與彈幕可各自調整。';
        }
        if (videoChanged) {
            clearPlayer();
            currentVideo = nextVideo;
            currentWatchToken = nextToken;
            frame.hidden = !nextVideo;
            elements.playerPlaceholder.hidden = !!nextVideo;
            if (nextVideo) {
                frame.src = root + 'watch?id=' + encodeURIComponent(nextVideo) + '&activity=1' +
                    (nextToken ? '&ag=' + encodeURIComponent(nextToken) : '');
            } else {
                frame.removeAttribute('src');
            }
        }
        clearTimeout(grantExpiryTimer);
        if (canWatch && nextToken && Number.isFinite(state.grant_expires_at)) {
            var remaining = (state.grant_expires_at - state.server_time) * 1000;
            if (remaining <= 0) {
                clearPlayer();
                currentState.can_watch = false;
                canWatch = false;
                accessExpired = true;
            } else {
                grantExpiryTimer = setTimeout(function () {
                    clearPlayer();
                    if (currentState) { currentState.can_watch = false; }
                    waitingForAccess(true);
                }, Math.min(remaining, 2147483647));
            }
        }
        if (videoChanged || roleChanged) {
            renderPlaying();
            renderLibrary();
        }
        if (!canWatch) {
            controlEpoch += 1;
            clearPlayer();
            waitingForAccess(accessExpired);
        } else {
            notice('');
        }
        if (canWatch && !nextVideo) {
            elements.lobbyTitle.textContent = state.is_host ? '選一集，大家一起看' : '等主控選一集';
            elements.lobbyDescription.textContent = state.is_host ? '從旁邊的片庫挑選，播放進度會自動同步給所有人。' : '主控選片後，畫面和播放進度會自動同步。';
        }
        postState();
        updatePresence();
    }

    function haltPlayback() {
        clearTimeout(pollTimer);
        controlEpoch += 1;
        clearPlayer();
        joined = false;
        currentState = null;
        renderAutoGrant();
        elements.playbackRole.hidden = true;
        elements.refreshLibrary.disabled = true;
        elements.librarySearch.disabled = true;
        renderLibrary();
    }

    function requireAccount(message) {
        haltPlayback();
        status('等待登入', '');
        notice(message || '這台伺服器要求登入網站帳號才能觀看。請在活動內登入後繼續。');
        elements.lobbyTitle.textContent = '登入後，就能一起看';
        elements.lobbyDescription.textContent = '登入網站帳號並綁定 Discord，下次開啟就會自動加入。';
        openAccount(true);
    }

    async function pollRoom() {
        if (!joined || pollInFlight) { return; }
        pollInFlight = true;
        try {
            var state = await api('state?instance_id=' + encodeURIComponent(instanceId));
            if (!joined) { return; }
            pollFailures = 0;
            status('已同步', 'connected');
            acceptState(state);
        } catch (error) {
            if (!joined) { return; }
            if (presence) { presence.clear(); }
            if (error.code === 'join_required') {
                try { await joinRoom(); return; } catch (joinError) { error = joinError; }
            }
            if (error.code === 'login_required') {
                try { identity = await api('me'); renderIdentity(); } catch (_) { /* Reconnect will reauthenticate. */ }
                requireAccount(error.message);
                return;
            }
            pollFailures += 1;
            status('重新連線中', 'error');
            if (frame.contentWindow) {
                frame.contentWindow.postMessage({ type: 'agp:activity-disconnect' }, window.location.origin);
            }
            if (error.status === 401 || error.status === 403 || error.status === 404 || pollFailures >= 3) {
                haltPlayback();
                notice(errorMessage(error, '與活動的連線中斷，請重新連線。'));
                elements.lobbyTitle.textContent = '連線暫時中斷';
                elements.lobbyDescription.textContent = '重新連線後會恢復目前的共同播放進度。';
                elements.connectButton.hidden = false;
                return;
            }
        } finally {
            pollInFlight = false;
        }
        clearTimeout(pollTimer);
        pollTimer = setTimeout(pollRoom, 1000);
    }

    async function joinRoom() {
        if (!identity || !identity.user || !instanceId) { return; }
        clearTimeout(pollTimer);
        try {
            var state = await api('join', { instance_id: instanceId });
            joined = true;
            currentState = null;
            pollFailures = 0;
            notice('');
            status('已同步', 'connected');
            elements.connectButton.hidden = true;
            acceptState(state);
            pollTimer = setTimeout(pollRoom, 1000);
            loadLibrary();
        } catch (error) {
            if (error.code === 'login_required') { requireAccount(error.message); return; }
            throw error;
        }
    }

    function sendControl(payload) {
        if (!joined || !currentState || !currentState.is_host) { return; }
        var targetVideo = currentVideo;
        var epoch = controlEpoch;
        if (payload.action !== 'select') { payload.expected_sn = targetVideo; }
        payload.instance_id = instanceId;
        controlChain = controlChain.then(async function () {
            if (!joined || !currentState || !currentState.is_host) { return; }
            if (controlEpoch !== epoch) { return; }
            if (payload.action !== 'select' && currentVideo !== targetVideo) { return; }
            try {
                var state = await api('control', payload);
                acceptState(state);
            } catch (error) {
                toast(errorMessage(error, '無法更新播放狀態，請稍後再試。'));
                if (error.code === 'login_required') { requireAccount(error.message); }
                else { pollRoom(); }
            }
        });
    }

    async function authorizeMember(action, userId, sn) {
        if (!joined || !currentState || !currentState.is_host || !identity || !identity.account ||
            String(currentState.sn || '') !== sn || accessRequests.has(userId)) { return; }
        accessRequests.add(userId);
        renderMembers(currentState);
        try {
            var state = await api(action, { instance_id: instanceId, user_id: userId, sn: sn });
            acceptState(state);
            toast(action === 'grant' ? '已授權觀看這一集，換片後需要重新授權。' : '已撤銷這一集的觀看授權。');
        } catch (error) {
            toast(errorMessage(error, '無法更新觀看授權，請稍後再試。'));
            pollRoom();
        } finally {
            accessRequests.delete(userId);
            if (currentState) { renderMembers(currentState); }
        }
    }

    async function start() {
        if (starting) { return; }
        starting = true;
        elements.connectButton.disabled = true;
        status('正在連線', '');
        notice('');
        try {
            if (presence) {
                await presence.setEnabled(false);
                renderPresence();
            }
            var params = new URLSearchParams(window.location.search);
            if (!params.get('frame_id') || !params.get('instance_id') || !params.get('platform')) {
                elements.lobbyTitle.textContent = '從 Discord 開始一起看';
                elements.lobbyDescription.textContent = '進入 Discord 語音頻道，從「活動」開啟 aniGamerPlus，就能和朋友一起觀看。';
                status('等待 Discord', '');
                return;
            }
            config = await api('config');
            csrf = config.csrf_token || '';
            if (!config.configured) {
                elements.lobbyTitle.textContent = '一起看活動尚未設定完成';
                elements.lobbyDescription.textContent = '請伺服器管理員完成 Discord Activity 設定後，再從語音頻道開啟。';
                status('尚未啟用', '');
                return;
            }
            var SDK = window.DiscordEmbeddedAppSDK && window.DiscordEmbeddedAppSDK.DiscordSDK;
            if (!SDK) { throw new Error('活動元件載入失敗，請關閉活動後重新開啟。'); }
            if (!sdk) { sdk = new SDK(config.client_id, { disableConsoleLogOverride: true }); }
            await Promise.race([
                sdk.ready(),
                new Promise(function (_, reject) { setTimeout(function () { reject(new Error('未能連到 Discord，請從語音頻道重新開啟活動。')); }, 15000); })
            ]);
            subscribeLayout();
            var authorized = await sdk.commands.authorize({
                client_id: config.client_id,
                response_type: 'code',
                state: csrf,
                prompt: 'none',
                scope: ['identify', 'applications.commands']
            });
            identity = await api('token', { code: authorized.code });
            presenceScopeGranted = false;
            if (identity.csrf_token) { csrf = identity.csrf_token; }
            var auth = await sdk.commands.authenticate({ access_token: identity.access_token });
            delete identity.access_token;
            if (!auth || !auth.user || String(auth.user.id) !== String(identity.user.id)) {
                throw new Error('Discord 身分驗證未完成，請重新開啟活動。');
            }
            instanceId = sdk.instanceId;
            setupPresence();
            renderIdentity();
            await joinRoom();
        } catch (error) {
            haltPlayback();
            status('連線失敗', 'error');
            notice(errorMessage(error, '活動連線失敗，請稍後重試。'));
            elements.lobbyTitle.textContent = '還沒連上一起看';
            elements.lobbyDescription.textContent = '請確認你仍在 Discord 語音頻道中，再試一次。';
            elements.connectButton.hidden = false;
        } finally {
            starting = false;
            elements.connectButton.disabled = false;
        }
    }

    async function accountAction(button, action, body, success) {
        if (!identity || !identity.user) { return; }
        button.disabled = true;
        accountFeedback('');
        try {
            identity = await api(action, body);
            if (identity.csrf_token) { csrf = identity.csrf_token; }
            renderIdentity();
            var message = typeof success === 'function' ? success(identity) : success;
            if (identity.link_error) {
                accountFeedback('已登入，但未能綁定：' + identity.link_error);
            } else if (action === 'login' && identity.linked) {
                openAccount(false);
                toast(message);
            } else {
                accountFeedback(message, true);
            }
            // Refresh room authorization immediately after login, unlink or logout.
            controlEpoch += 1;
            clearPlayer();
            currentState = null;
            if (!hasLibraryAccess()) { videos = []; libraryLoaded = false; }
            await joinRoom();
        } catch (error) {
            accountFeedback(errorMessage(error, '帳號操作失敗，請稍後重試。'));
        } finally {
            button.disabled = false;
        }
    }

    elements.accountToggle.addEventListener('click', function () { openAccount(elements.accountPanel.hidden); });
    elements.activityLoginPrompt.addEventListener('click', function () { openAccount(true); });
    elements.accountClose.addEventListener('click', function () { openAccount(false); });
    elements.accountPanel.addEventListener('click', function (event) {
        if (event.target === elements.accountPanel) { openAccount(false); }
    });
    elements.accountForm.addEventListener('submit', async function (event) {
        event.preventDefault();
        var password = elements.accountPassword.value;
        elements.accountPassword.value = '';
        await accountAction(elements.accountLogin, 'login', {
            username: elements.accountUsername.value.trim(), password: password,
            link: elements.accountRemember.checked
        }, function (result) {
            return result.linked ? '已登入並綁定 Discord，下次開啟活動會自動登入。' : '已登入。可以在這裡綁定 Discord，之後自動登入。';
        });
        password = '';
    });
    elements.accountLink.addEventListener('click', function () {
        accountAction(elements.accountLink, 'link', {}, '已綁定 Discord，下次開啟活動會直接登入。');
    });
    elements.accountUnlink.addEventListener('click', function () {
        accountAction(elements.accountUnlink, 'unlink', {}, '已解除 Discord 綁定並登出網站帳號。');
    });
    elements.accountSwitch.addEventListener('click', function () {
        elements.accountForm.hidden = false;
        elements.accountActions.hidden = true;
        accountFeedback('');
        elements.accountUsername.focus();
    });
    elements.librarySearch.addEventListener('input', renderLibrary);
    elements.refreshLibrary.addEventListener('click', loadLibrary);
    elements.libraryList.addEventListener('click', function (event) {
        var button = event.target.closest('button[data-sn]');
        if (!button || button.disabled) { return; }
        sendControl({ action: 'select', sn: button.dataset.sn });
    });
    elements.memberList.addEventListener('click', function (event) {
        var button = event.target.closest('button[data-access-action]');
        if (!button || button.disabled) { return; }
        authorizeMember(button.dataset.accessAction, button.dataset.userId, button.dataset.sn);
    });
    elements.connectButton.addEventListener('click', start);
    elements.autoGrantToggle.addEventListener('click', toggleAutoGrant);
    elements.activityPresenceToggle.addEventListener('click', togglePresence);
    elements.activityExpandedExit.addEventListener('click', function () { setExpanded(false); });
    document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape' && !elements.accountPanel.hidden) { openAccount(false); event.preventDefault(); return; }
        if (event.key === 'Escape' && expanded) { setExpanded(false); event.preventDefault(); }
    });
    frame.addEventListener('load', function () { postState(); postExpanded(); });
    window.addEventListener('message', function (event) {
        if (event.origin !== window.location.origin || event.source !== frame.contentWindow || !event.data) { return; }
        var data = event.data;
        if (data.type === 'agp:activity-playback') {
            if (!joined || !currentState || !currentState.can_watch || String(data.sn) !== currentVideo) { return; }
            playbackMetadata = {
                sn: currentVideo,
                title: typeof data.title === 'string' ? data.title : '',
                episode: typeof data.episode === 'string' ? data.episode : '',
                position: Number.isFinite(data.position) ? data.position : 0,
                duration: Number.isFinite(data.duration) ? data.duration : 0,
                paused: data.paused !== false,
                rate: Number.isFinite(data.rate) ? data.rate : 1,
                cover: typeof data.cover === 'string' ? data.cover : ''
            };
            updatePresence();
            return;
        }
        if (data.type === 'agp:activity-ready') { postState(); postExpanded(); return; }
        if (data.type === 'agp:activity-fullscreen') {
            if (typeof data.expanded === 'boolean') { setExpanded(data.expanded); }
            return;
        }
        if (data.type === 'agp:activity-autoplay-blocked') { toast('點一下播放器開始播放，之後會自動跟上主控進度。'); return; }
        if (data.type !== 'agp:activity-control' || !joined || !currentState || !currentState.is_host) { return; }
        if (['select', 'play', 'pause', 'seek', 'rate', 'sync'].indexOf(data.action) < 0) { return; }
        if (data.action !== 'select' && data.sn && String(data.sn) !== currentVideo) { return; }
        if (data.action === 'select') {
            if (typeof data.sn !== 'string' || !findVideo(data.sn)) { return; }
            sendControl({ action: 'select', sn: data.sn });
            return;
        }
        if (data.action === 'sync') {
            if (Date.now() - lastSync < 3000) { return; }
            lastSync = Date.now();
        }
        var payload = { action: data.action };
        if (Number.isFinite(data.position)) { payload.position = data.position; }
        if (Number.isFinite(data.rate)) { payload.rate = data.rate; }
        if (typeof data.paused === 'boolean') { payload.paused = data.paused; }
        sendControl(payload);
    });
    window.addEventListener('pagehide', function () {
        if (presence) { presence.clear(); }
        clearTimeout(pollTimer);
        if (joined && csrf) {
            api('leave', { instance_id: instanceId }, { keepalive: true }).catch(function () {});
        }
    });
    document.addEventListener('visibilitychange', function () {
        if (!document.hidden && joined) { clearTimeout(pollTimer); pollRoom(); }
    });
    elements.accountToggle.disabled = true;
    start();
}());
