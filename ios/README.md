# aniGamerPlus+ for iOS

A thin native shell around the dashboard's own web UI. It is not a second
client — it loads the same pages your browser does, from the same server. It
exists for the two things a web page on iOS is not allowed to touch:

| | in Safari | in this app |
|---|---|---|
| Screen brightness | dims a black overlay over the video | moves the device's actual backlight |
| Volume | read-only; iOS ignores writes to `video.volume` | moves the system output level, the one the hardware buttons move |

A handful of smaller things come with it: `Element.requestFullscreen` works, so
fullscreen keeps the danmaku layer instead of falling back to the video
element's own fullscreen; links stay in the app; and the "加入主畫面" banner
stops being offered, since you are already past it.

Everything else — playback, danmaku, the library, downloads — is the web UI,
unchanged. Fix a bug there and the app has it on next load.

## Getting it onto a device

Releases carry `aniGamerPlus-<version>-<build>-unsigned.ipa`, built by
[`.github/workflows/iOS-build.yml`](../.github/workflows/iOS-build.yml). Every
push to `ios/**` also leaves one as a run artifact.

**It is unsigned, deliberately.** Signing needs an Apple Developer identity,
and an identity in a public repository is an identity anybody can use. Every
sideloading tool re-signs with your own identity anyway, so a signature here
would only be thrown away:

- **[AltStore](https://altstore.io) / [SideStore](https://sidestore.io)** —
  free Apple ID, refreshes itself over Wi-Fi. Apps expire after 7 days, which
  matters only if you stop opening AltStore.
- **[Sideloadly](https://sideloadly.io)** — plug the phone into a computer.
  Same 7 days on a free account, a year on a paid one.
- **TrollStore** — permanent, on the iOS versions it supports.
- **A paid developer account** — `xcodebuild` in the workflow already produces
  the `.app`; re-sign it yourself and skip all of the above.

## First run

The app opens `https://agpp.avianjay.sbs` by default. To point it somewhere
else — a machine on your own network, a tunnel, a different port — **shake the
device** to open the address prompt. There is no settings button: the dashboard
fills the screen and none of it belongs to the app, so a floating button would
sit on top of the thing you came to watch.

The address is remembered, and `192.168.1.10:5000` is a perfectly good answer;
the scheme is filled in for you. Plain HTTP to a local server is allowed
(`NSAllowsLocalNetworking`), so a LAN dashboard does not need a certificate.

If the dashboard is not answering, the app says so and offers both a retry and
the address prompt — for a front end to your own server, "the machine is off"
is a normal state, not an error.

## How the bridge works

`AGP/Resources/Bridge.js` is injected at document start into every page, and
defines `window.AgpNative`. The player checks for it once:

```js
var NATIVE = (window.AgpNative && window.AgpNative.version >= 1) ? window.AgpNative : null;
```

and, where it exists, drives the device instead of the overlay — see
`Dashboard/static/js/watch.js`. Reads are synchronous, because a gesture
handler has to start from the level the device is at right now: the current
levels are seeded into a per-navigation user script, and
`WebViewController.pushLevelsToPage()` pushes new ones whenever the hardware
buttons, Control Centre or auto-brightness move something behind the page's
back.

Brightness is *borrowed*, not taken: the level from before the app touched it
is restored when the app goes to the background, and re-applied when it comes
forward. If you move brightness yourself while the app is open, it lets go.

Both halves of the contract are tested — `tests/test_web_ui.py` runs the real
`Bridge.js` behind a fake host, so the shipped file is what the player is
tested against.

## Building it yourself

```sh
brew install xcodegen
cd ios
xcodegen generate
open aniGamerPlus.xcodeproj
```

The project file is generated rather than committed; `project.yml` is the
source of truth. Anything dropped into `AGP/` is compiled, and anything in
`AGP/Resources/` is copied into the bundle — `Bridge.js` is read out of the
bundle by name at runtime, so it has to be a resource and not a source file.
CI asserts it is actually in there, because getting that wrong builds cleanly
and only fails on a device.
