/* Flutter DiscordPlayback's template, published through the Embedded App SDK. */
(function (global) {
    'use strict';

    var UPDATE_INTERVAL = 5000;

    function text(value) { return Array.from(String(value == null ? '' : value)).slice(0, 128).join(''); }
    function number(value, fallback) { return Number.isFinite(value) ? value : fallback; }
    function episodeLabel(value) {
        var label = String(value == null ? '' : value).trim();
        if (!label) { return '單集'; }
        if (/^\d+(\.\d+)?$/.test(label)) {
            return '第 ' + (Number.isInteger(Number(label)) ? Number(label) : label) + ' 集';
        }
        return label;
    }
    function publicImage(value) {
        if (typeof value !== 'string' || !value) { return ''; }
        try {
            var url = new URL(value);
            if (url.protocol !== 'https:' || url.username || url.password) { return ''; }
            // A private playback capability is never an image or join URL.
            for (var key of url.searchParams.keys()) {
                if (/^(ag|ct|token|access_token|client_secret|bot_token)$/i.test(key)) { return ''; }
            }
            return url.href;
        } catch (_) { return ''; }
    }

    function playback(payload) {
        var state = payload && payload.state;
        if (!state || state.can_watch !== true || !state.sn || !payload.identity || !payload.identity.user) { return null; }
        var sn = String(state.sn);
        var player = payload.player && String(payload.player.sn) === sn ? payload.player : {};
        var video = payload.video && String(payload.video.sn) === sn ? payload.video : {};
        var title = text(player.title || video.anime_name || video.title || ('sn ' + sn));
        var rate = number(state.rate, 1);
        if (rate <= 0) { rate = 1; }
        var position = Math.max(0, number(state.position, 0));
        var playing = state.paused === false;
        if (playing && Number.isFinite(state.server_time) && Number.isFinite(state.updated_at)) {
            position += Math.max(0, state.server_time - state.updated_at) * rate;
        }
        return {
            sn: sn,
            title: title,
            episode: text(episodeLabel(player.episode == null ? video.episode : player.episode)),
            position: position,
            duration: Math.max(0, number(player.duration, number(video.duration, 0))),
            playing: playing,
            rate: rate,
            image: publicImage(player.cover || video.cover || ''),
            receivedAt: Date.now()
        };
    }

    function activity(value, now) {
        if (!value) { return null; }
        var result = { type: 3, details: value.title,
            state: text(value.playing ? value.episode : value.episode + ' · 已暫停') };
        var position = value.position + (value.playing ? Math.max(0, now - value.receivedAt) / 1000 * value.rate : 0);
        if (value.playing && value.duration > position) {
            // The Activity SDK takes Unix seconds; Flutter's Gateway uses ms.
            result.timestamps = {
                start: Math.floor((now - position / value.rate * 1000) / 1000),
                end: Math.floor((now + (value.duration - position) / value.rate * 1000) / 1000)
            };
        }
        if (value.image) { result.assets = { large_image: value.image, large_text: value.title }; }
        return result;
    }

    function changed(value, previous, now) {
        if (!value || !previous) { return value !== previous; }
        var expected = previous.position + (previous.playing ? Math.max(0, now - previous.receivedAt) / 1000 * previous.rate : 0);
        var current = value.position + (value.playing ? Math.max(0, now - value.receivedAt) / 1000 * value.rate : 0);
        return value.sn !== previous.sn || value.title !== previous.title || value.episode !== previous.episode ||
            value.image !== previous.image || value.playing !== previous.playing || value.rate !== previous.rate ||
            Math.abs(value.duration - previous.duration) > 1 || Math.abs(current - expected) > 2;
    }

    function create(options) {
        options = options || {};
        var sdk = options.sdk;
        var enabled = false;
        var destroyed = false;
        var generation = 0;
        var latest = null;
        var desired = null;
        var previous = null;
        var lastWrite = -Infinity;
        var sent = false;
        var inFlight = false;
        var timer = 0;
        var urgent = false;
        var retries = 0;
        var retryPending = false;

        function notify() {
            if (typeof options.onChange === 'function') { options.onChange(enabled); }
        }
        function report(error) {
            // SDK errors can contain credentials or response bodies. Only the
            // numeric RPC code may leave this module.
            var code = error && Number.isInteger(error.code) ? '（Discord 錯誤碼 ' + error.code + '）' : '';
            if (typeof options.onError === 'function') { options.onError('無法更新 Discord 播放動態' + code + '，觀看不受影響。'); }
        }
        function flush() {
            clearTimeout(timer);
            timer = 0;
            if (inFlight || !sdk || !sdk.commands || typeof sdk.commands.setActivity !== 'function') { return; }
            var now = Date.now();
            if (sent && !retryPending && !changed(desired, previous, now)) { return; }
            if (!urgent && now - lastWrite < UPDATE_INTERVAL) {
                timer = setTimeout(flush, UPDATE_INTERVAL - (now - lastWrite));
                return;
            }
            urgent = false;
            retryPending = false;
            var value = desired;
            var payload = activity(value, now);
            inFlight = true;
            lastWrite = now;
            Promise.resolve().then(function () { return sdk.commands.setActivity({ activity: payload }); })
                .then(function () {
                    sent = true;
                    previous = value;
                    retries = 0;
                }).catch(function (error) {
                    sent = true;
                    previous = value;
                    report(error);
                    // Recover a transient RPC failure once, respecting the
                    // same rate limit as normal updates and later room polls.
                    if (retries < 1 && !changed(desired, value, Date.now())) {
                        retries += 1;
                        retryPending = true;
                        timer = setTimeout(flush, UPDATE_INTERVAL);
                    }
                }).finally(function () {
                    inFlight = false;
                    if (desired !== value) { flush(); }
                });
        }
        function queue(value, immediate) {
            if (changed(value, desired, Date.now())) { retries = 0; retryPending = false; }
            desired = value;
            urgent = urgent || immediate;
            if (!sent && value === null && !inFlight) { return; }
            flush();
        }

        return {
            get enabled() { return enabled; },
            update: function (payload) {
                if (destroyed) { return; }
                latest = payload;
                if (!enabled) { return; }
                var value = playback(payload);
                queue(value, value === null);
            },
            setEnabled: async function (value) {
                if (destroyed) { return false; }
                if (value && enabled) { return true; }
                var current = ++generation;
                if (!value) {
                    enabled = false;
                    notify();
                    queue(null, true);
                    return false;
                }
                try {
                    if (typeof options.authorize === 'function') { await options.authorize(); }
                    if (destroyed || current !== generation) { return false; }
                    enabled = true;
                    notify();
                    var next = playback(latest);
                    queue(next, next === null);
                    return true;
                } catch (_) {
                    if (current === generation && !destroyed) { enabled = false; notify(); queue(null, true); }
                    throw new Error('無法啟用 Discord 播放動態，請重新授權後再試。');
                }
            },
            clear: function () {
                latest = null;
                queue(null, true);
            },
            destroy: function () {
                if (destroyed) { return; }
                ++generation;
                enabled = false;
                destroyed = true;
                latest = null;
                queue(null, true);
            }
        };
    }

    global.AgpDiscordPresence = { create: create };
}(window));
