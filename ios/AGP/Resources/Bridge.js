/* ---------------------------------------------------------------------------
   aniGamerPlus+ — native bridge
   Injected into every page the app loads, before any of the page's own scripts
   run. It hands the page the two levels a browser refuses to give it: the
   device's screen brightness and the system output volume. Everything else the
   app does is what Safari would have done anyway.
   --------------------------------------------------------------------------- */
(function (global) {
    'use strict';

    var seed = global.__AGP_NATIVE_SEED__ || {};
    var state = {
        brightness: typeof seed.brightness === 'number' ? seed.brightness : 1,
        volume: typeof seed.volume === 'number' ? seed.volume : 1
    };

    function clamp(value) {
        var level = Number(value);
        if (isNaN(level)) { return 0; }
        return Math.min(1, Math.max(0, level));
    }

    function post(payload) {
        try {
            global.webkit.messageHandlers.agpNative.postMessage(payload);
        } catch (error) {
            /* No handler: the page keeps whatever web fallback it has. */
        }
    }

    function announce() {
        var detail = { brightness: state.brightness, volume: state.volume };
        var event;
        try {
            event = new CustomEvent('agpnativechange', { detail: detail });
        } catch (error) {
            event = document.createEvent('CustomEvent');
            event.initCustomEvent('agpnativechange', false, false, detail);
        }
        global.dispatchEvent(event);
    }

    global.AgpNative = {
        version: 1,
        platform: 'ios',

        /* Read synchronously so a gesture handler can start from the level the
           device is actually at. The host keeps them current through _update. */
        get brightness() { return state.brightness; },
        get volume() { return state.volume; },

        setBrightness: function (value) {
            state.brightness = clamp(value);
            post({ name: 'brightness', value: state.brightness });
            return state.brightness;
        },

        setVolume: function (value) {
            state.volume = clamp(value);
            post({ name: 'volume', value: state.volume });
            return state.volume;
        },

        openSettings: function () { post({ name: 'settings' }); },

        /* Called by the host when the hardware buttons, Control Centre or
           auto-brightness move a level behind the page's back. */
        _update: function (patch) {
            if (!patch) { return; }
            if (typeof patch.brightness === 'number') { state.brightness = clamp(patch.brightness); }
            if (typeof patch.volume === 'number') { state.volume = clamp(patch.volume); }
            announce();
        }
    };
}(window));
