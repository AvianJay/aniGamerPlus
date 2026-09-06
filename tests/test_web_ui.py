"""Playwright coverage for the redesigned dashboard: home page, player,
mobile gestures and the iOS add-to-home-screen plumbing.

Run with::

    python -m pytest tests/test_web_ui.py

The pages are served by ``tests/ui_harness.py`` rather than by
``Dashboard/Server.py``; see that module for why.
"""

import json
import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ui_harness import (  # noqa: E402
    ROOT,
    STATIC_PATH,
    VIDEO_LIST,
    HarnessServer,
)

playwright_api = pytest.importorskip('playwright.sync_api')
sync_playwright = playwright_api.sync_playwright
expect = playwright_api.expect

FIRST_SN = VIDEO_LIST['videos'][0]['sn']
FIRST_ANIME = VIDEO_LIST['videos'][0]['anime_name']
IPHONE_VIEWPORT = {'width': 390, 'height': 844}


# --------------------------------------------------------------------- setup

@pytest.fixture(scope='session')
def server():
    with HarnessServer() as running:
        yield running


def launch_chromium(playwright, **kwargs):
    """Launch a browser that can actually decode the library.

    Playwright's bundled Chromium ships without the proprietary codecs, so a
    real 1080p H.264/AAC episode never fires ``loadedmetadata`` in it -- the
    picture stays black and ``duration`` reads 0. Installed Chrome and Edge do
    carry them, so prefer those and fall back to the bundle (fine for the
    WebM fixtures, useless for the real files).
    """
    for channel in ('chrome', 'msedge'):
        try:
            return playwright.chromium.launch(channel=channel, **kwargs)
        except Exception:
            continue
    return playwright.chromium.launch(**kwargs)


@pytest.fixture(scope='session')
def browser():
    """Headless by default; set ``AGP_HEADED=1`` to watch the run in a real
    window (``AGP_SLOWMO`` milliseconds between actions makes it followable)."""
    headed = os.environ.get('AGP_HEADED') == '1'
    slow_mo = int(os.environ.get('AGP_SLOWMO') or (250 if headed else 0))
    with sync_playwright() as p:
        instance = launch_chromium(p, headless=not headed, slow_mo=slow_mo)
        yield instance
        instance.close()


@pytest.fixture
def page(browser):
    context = browser.new_context(locale='zh-TW')
    page = context.new_page()
    page.errors = []
    page.on('pageerror', lambda error: page.errors.append(str(error)))
    yield page
    context.close()


@pytest.fixture
def phone(browser):
    """A coarse-pointer context so the player takes its touch branch."""
    context = browser.new_context(
        locale='zh-TW',
        viewport=IPHONE_VIEWPORT,
        device_scale_factor=3,
        is_mobile=True,
        has_touch=True,
        user_agent=('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    )
    page = context.new_page()
    page.errors = []
    page.on('pageerror', lambda error: page.errors.append(str(error)))
    yield page
    context.close()


def goto_watch(page, server, sn=FIRST_SN):
    page.goto('%s/watch?id=%s' % (server.url, sn))
    page.wait_for_selector('#playerShell.is-custom-player')
    page.wait_for_function("() => document.querySelector('#playerShell video')?.readyState >= 1")
    return page


# ----------------------------------------------------------------- home page

def test_home_renders_bahamut_style_sections(page, server):
    page.goto(server.url)
    page.wait_for_selector('#homeTimetable .agp-day')

    expect(page.locator('.agp-topbar .agp-brand')).to_be_visible()
    expect(page.locator('#homeSearch')).to_be_visible()
    expect(page.locator('.agp-tabs .agp-tab.is-active')).to_have_text('首頁')
    expect(page.locator('#homeBanner .agp-banner')).to_be_visible()

    # 本季新番 is grouped by day, exactly like the timetable it is modelled on.
    days = page.locator('#homeTimetable .agp-day')
    assert days.count() >= 2
    expect(days.first.locator('.agp-day-head strong')).to_have_text('今天')

    # Every episode card carries the red 第 N 集 chip and a 16:9 plate.
    card = page.locator('#homeTimetable .agp-card').first
    expect(card.locator('.agp-card-ep')).to_be_visible()
    ratio = card.locator('.agp-card-art').evaluate(
        '(el) => { const r = el.getBoundingClientRect(); return r.width / r.height; }')
    assert 1.7 < ratio < 1.83

    expect(page.locator('#homeHot .agp-poster-grid .agp-poster').first).to_be_visible()
    expect(page.locator('#homeLibrary .agp-poster').first).to_be_visible()
    assert page.errors == []


def test_home_continue_watching_shows_real_progress(page, server):
    page.goto(server.url)
    page.wait_for_selector('#homeContinue .agp-continue-item')

    item = page.locator('#homeContinue .agp-continue-item').first
    bar = item.locator('.agp-card-progress i')
    expect(bar).to_be_visible()

    # 420s watched of a 1440s episode reported by the player => ~29%.
    width = bar.evaluate('(el) => el.style.width')
    assert 25 < float(width.rstrip('%')) < 34

    expect(item.locator('.agp-card-badge')).to_contain_text('剩餘')
    expect(item.locator('.agp-continue-next')).to_contain_text('下一集')


def test_home_search_filters_the_library(page, server):
    page.goto(server.url)
    page.wait_for_selector('#homeLibrary .agp-poster')

    total = page.locator('#homeLibrary .agp-poster').count()
    page.fill('#homeSearch', '迷宮')
    page.wait_for_function(
        "() => document.querySelectorAll('#homeLibrary .agp-poster').length === 1")
    assert total > 1
    expect(page.locator('#homeLibrary .agp-poster-foot strong')).to_have_text('迷宮飯')

    page.fill('#homeSearch', 'zzzz-no-such-anime')
    expect(page.locator('#homeLibrary .agp-empty')).to_contain_text('找不到')


# -------------------------------------------------------------------- player

def test_player_chrome_matches_reference_layout(page, server):
    goto_watch(page, server)

    expect(page.locator('#playerShell .desktop-player-controls')).to_be_attached()
    expect(page.locator('#playerSeek')).to_be_attached()
    expect(page.locator('#timeCurrent')).to_have_text('0:00')
    expect(page.locator('#episodeChipLabel')).to_contain_text(FIRST_ANIME)

    for control in ['#playToggle', '#muteToggle', '#danmakuToggle',
                    '#settingsToggle', '#pipToggle', '#fullscreenToggle']:
        expect(page.locator(control)).to_be_attached()

    # The progress track is painted red up to the played point (the browser
    # reports the inline #ff0033 back as rgb(255, 0, 51)).
    background = page.locator('#playerSeek').evaluate('(el) => el.style.background')
    assert background.startswith('linear-gradient(to right,')
    assert 'rgb(255, 0, 51)' in background

    # An active icon gets the red underline the reference player uses. Danmaku
    # starts on, so it takes two clicks to get back to the active state.
    page.locator('#danmakuToggle').click()
    page.locator('#danmakuToggle').click()
    page.wait_for_timeout(120)
    expect(page.locator('#danmakuToggle')).to_have_class(re.compile('(^| )active( |$)'))
    underline = page.locator('#danmakuToggle').evaluate(
        "(el) => getComputedStyle(el, '::after').backgroundColor")
    assert underline in ('rgb(255, 0, 51)', 'rgba(255, 0, 51, 1)')
    assert page.errors == []


def test_settings_menu_nests_and_applies(page, server):
    goto_watch(page, server)

    page.locator('#settingsToggle').click()
    menu = page.locator('#settingsMenu')
    expect(menu).to_be_visible()
    expect(menu.locator('header strong')).to_have_text('設定')

    for label in ['播放速度', '彈幕', '畫面比例', '畫面亮度', '鍵盤快速鍵']:
        expect(menu.locator('button', has_text=label).first).to_be_visible()

    page.locator('#settingsMenu button[data-view="speed"]').click()
    expect(menu.locator('header strong')).to_have_text('播放速度')
    page.locator('#settingsMenu button[data-value="1.5"]').click()

    assert page.evaluate("() => document.querySelector('#playerShell video').playbackRate") == 1.5
    # Choosing a value walks back to the parent view, as in the reference.
    expect(menu.locator('header strong')).to_have_text('設定')

    page.locator('#settingsMenu button[data-view="shortcuts"]').click()
    expect(menu.locator('dl kbd').first).to_be_visible()
    page.locator('#settingsMenu .desktop-player-menu-back').click()
    expect(menu.locator('header strong')).to_have_text('設定')


def test_episode_grid_and_menu_navigate(page, server):
    goto_watch(page, server)

    grid = page.locator('#episodeGrid .watch-episode-grid')
    expect(grid).to_be_visible()
    buttons = grid.locator('.watch-episode-btn')
    assert buttons.count() == 4  # 葬送的芙莉蓮 has four fixture episodes
    expect(grid.locator('.watch-episode-btn.is-current')).to_have_text('1')

    page.locator('#episodeChip').click()
    expect(page.locator('#episodeMenu')).to_be_visible()
    page.locator('#episodeMenu button[data-sn]').nth(1).click()
    page.wait_for_url(re.compile(r'/watch\?id='))
    page.wait_for_selector('.watch-episode-btn.is-current')
    expect(page.locator('.watch-episode-btn.is-current')).to_have_text('2')


def test_danmaku_sidebar_lists_and_seeks(page, server):
    goto_watch(page, server)
    page.wait_for_selector('#danmakuList .danmaku-row')

    rows = page.locator('#danmakuList .danmaku-row')
    assert rows.count() == 5
    expect(page.locator('#danmakuCount')).to_have_text('5 則')
    expect(rows.first.locator('time')).to_have_text('0:00')
    # \N is a line break in ASS, not literal text.
    expect(rows.nth(2).locator('span')).to_have_text('前方高能 注意')

    rows.nth(3).click()
    current = page.evaluate("() => document.querySelector('#playerShell video').currentTime")
    assert 3.9 < current < 4.1


def test_advanced_panel_controls_the_player(page, server):
    goto_watch(page, server)

    page.locator('.watch-side-tab', has_text='進階設定').click()
    expect(page.locator('#advancedTab')).to_have_class(re.compile('is-active'))

    page.select_option('#setAspect', 'cover')
    expect(page.locator('#playerShell')).to_have_class(re.compile('aspect-cover'))

    page.locator('#setBrightness').fill('40')
    page.locator('#setBrightness').dispatch_event('input')
    opacity = page.locator('#playerDim').evaluate('(el) => Number(el.style.opacity)')
    assert abs(opacity - 0.6) < 0.01


def test_watch_position_is_reported_with_duration(page, server):
    goto_watch(page, server)

    # pause() on an already-paused element fires nothing, and the position is
    # reported from the pause handler.
    with page.expect_request(re.compile(r'/watch/time\?type=set')) as caught:
        page.evaluate("""async () => {
            const v = document.querySelector('#playerShell video');
            await v.play().catch(() => {});
            v.currentTime = 2;
            v.pause();
        }""")
    assert 'duration=' in caught.value.url

    stored = page.evaluate("""async () => {
        const r = await fetch('./watch/time?type=get&sn=%s');
        return r.json();
    }""" % FIRST_SN)
    assert stored['duration'] > 0


# ------------------------------------------------------------------- gestures

def drag(page, x_from, y_from, x_to, y_to, steps=12):
    page.mouse.move(x_from, y_from)
    page.mouse.down()
    for i in range(1, steps + 1):
        page.mouse.move(x_from + (x_to - x_from) * i / steps,
                        y_from + (y_to - y_from) * i / steps)
    page.mouse.up()


def tap(page, fraction_x, fraction_y, delay=0):
    """Tap a point on the picture, re-measuring first.

    Tapping focuses the surface, and focusing a partly-visible element scrolls
    the page, so a box measured before the previous tap is already stale.
    """
    box = surface_box(page)
    x = box['x'] + box['width'] * fraction_x
    y = box['y'] + box['height'] * fraction_y
    landed = page.evaluate(
        """([x, y]) => {
            const el = document.elementFromPoint(x, y);
            return el ? el.className.toString() : null;
        }""", [x, y])
    assert landed and 'desktop-player-surface' in landed, landed
    page.mouse.click(x, y, delay=delay)


def surface_box(page):
    """The picture's box, once the page has stopped moving underneath it.

    The iOS install hint is inserted at the top of the document a moment after
    load and shifts everything down, so a box measured too early aims the tap
    at the nav tabs.
    """
    # Loading the episode grid scrolls the current episode into view, which can
    # take the player off the top of the screen; scrolling into view instead
    # parks it under the sticky topbar, so go all the way back to the top.
    page.evaluate('() => window.scrollTo(0, 0)')
    page.wait_for_function("""() => {
        const el = document.querySelector('.desktop-player-surface');
        if (!el) { return false; }
        const top = el.getBoundingClientRect().top;
        const settled = window.__agpLastTop === top;
        window.__agpLastTop = top;
        return settled;
    }""", polling=150)
    return page.locator('#playerShell .desktop-player-surface').bounding_box()


def test_touch_player_uses_the_touch_branch(phone, server):
    goto_watch(phone, server)
    expect(phone.locator('#playerShell')).to_have_class(re.compile('is-touch-player'))
    expect(phone.locator('#touchCenter')).to_be_visible()
    assert phone.locator('#playerShell .desktop-player-surface').evaluate(
        "(el) => getComputedStyle(el).touchAction") == 'none'


def test_right_side_vertical_drag_changes_volume(phone, server):
    goto_watch(phone, server)
    phone.evaluate("() => { document.querySelector('#playerShell video').volume = 0.4; }")

    box = surface_box(phone)
    x = box['x'] + box['width'] * 0.78
    drag(phone, x, box['y'] + box['height'] * 0.52, x, box['y'] + box['height'] * 0.06)

    volume = phone.evaluate("() => document.querySelector('#playerShell video').volume")
    assert volume > 0.85, volume
    expect(phone.locator('#playerHud')).to_contain_text('音量')


def test_left_side_vertical_drag_changes_picture_brightness(phone, server):
    goto_watch(phone, server)

    box = surface_box(phone)
    x = box['x'] + box['width'] * 0.22
    drag(phone, x, box['y'] + box['height'] * 0.25, x, box['y'] + box['height'] * 0.72)

    opacity = phone.locator('#playerDim').evaluate('(el) => Number(el.style.opacity || 0)')
    assert opacity > 0.3, opacity
    expect(phone.locator('#playerHud')).to_contain_text('畫面亮度')

    # It dims the picture only; the control bar must stay readable.
    dim_z = phone.locator('#playerDim').evaluate("(el) => getComputedStyle(el).zIndex")
    controls_z = phone.locator('#playerControls').evaluate("(el) => getComputedStyle(el).zIndex")
    assert int(dim_z) < int(controls_z)


def test_horizontal_drag_scrubs(phone, server):
    goto_watch(phone, server)
    phone.evaluate("() => { document.querySelector('#playerShell video').currentTime = 0; }")

    box = surface_box(phone)
    y = box['y'] + box['height'] * 0.5
    drag(phone, box['x'] + box['width'] * 0.25, y, box['x'] + box['width'] * 0.60, y)

    current = phone.evaluate("() => document.querySelector('#playerShell video').currentTime")
    assert current > 1.0, current


def test_double_tap_skips_ten_seconds(phone, server):
    goto_watch(phone, server)
    phone.evaluate("() => { document.querySelector('#playerShell video').currentTime = 0.5; }")

    # Clear of both the centre buttons and the control bar: this has to be the
    # gesture, not a button press.
    tap(phone, 0.92, 0.3)
    tap(phone, 0.92, 0.3, delay=10)

    # Right half: forward. 0.5s + 10s, well inside the 20s fixture clip.
    current = phone.evaluate("() => document.querySelector('#playerShell video').currentTime")
    assert current == pytest.approx(10.5, abs=0.4), current
    expect(phone.locator('#playerHud')).to_contain_text('10')


def test_a_cancelled_touch_leaves_the_chrome_alone(phone, server):
    """iPad Safari cancels the pointer the moment it claims a touch for a page
    pan. Running the tap branch on that is what made the control bar blink away
    while scrolling -- a cancel has to leave the chrome exactly as it was."""
    goto_watch(phone, server)
    box = surface_box(phone)
    x = box['x'] + box['width'] * 0.5
    y = box['y'] + box['height'] * 0.3

    for visible in (True, False):
        phone.evaluate(
            "(v) => document.querySelector('#playerShell')"
            ".classList.toggle('controls-visible', v)", visible)
        phone.evaluate("""([x, y]) => {
            const shell = document.querySelector('#playerShell');
            const opts = {pointerId: 7, pointerType: 'touch', isPrimary: true,
                          clientX: x, clientY: y, bubbles: true};
            document.elementFromPoint(x, y)
                .dispatchEvent(new PointerEvent('pointerdown', opts));
            shell.dispatchEvent(new PointerEvent('pointercancel', opts));
        }""", [x, y])
        assert phone.locator('#playerShell').evaluate(
            "(el) => el.classList.contains('controls-visible')") is visible


def test_the_bar_does_not_fade_out_from_under_a_finger_on_a_widget(phone, server):
    """The complaint this pass started from: on an iPad the control bar kept
    vanishing and had to be summoned again and again. A press on one of the
    bar's own widgets left the idle countdown running, so the bar faded out
    from under the finger that was reaching for it."""
    goto_watch(phone, server)
    # The countdown only runs while the clip does; muted so autoplay is allowed.
    phone.evaluate("""() => {
        const v = document.querySelector('#playerShell video');
        v.muted = true;
        return v.play();
    }""")
    phone.wait_for_function("() => !document.querySelector('#playerShell video').paused")
    phone.evaluate("() => window.page.player.showControls()")

    shell = phone.locator('#playerShell')
    visible = "(el) => el.classList.contains('controls-visible')"
    # Not the mute button: a narrow player drops the volume control entirely.
    box = phone.locator('#danmakuToggle').bounding_box()
    phone.mouse.move(box['x'] + box['width'] / 2, box['y'] + box['height'] / 2)
    phone.mouse.down()

    # A touch bar gives up after TOUCH_CONTROLS_IDLE_MS; hold well past it.
    phone.wait_for_timeout(9000)
    assert shell.evaluate(visible), 'the bar hid while a finger was still on it'

    # Widgets never reach the surface's own pointerup handler, so lifting off
    # one has to restart the countdown by itself rather than leave it unarmed.
    phone.mouse.up()
    phone.wait_for_timeout(700)
    assert shell.evaluate(visible)


def test_a_run_of_taps_keeps_skipping_instead_of_blinking_the_bar(phone, server):
    """Tapping quickly used to alternate summon, skip, hide, summon: the second
    tap of a pair cleared the stamp, so the third read as a fresh single tap
    and took the bar away again instead of skipping."""
    goto_watch(phone, server)
    phone.evaluate("() => { document.querySelector('#playerShell video').currentTime = 18; }")

    box = surface_box(phone)
    x = box['x'] + box['width'] * 0.08
    y = box['y'] + box['height'] * 0.3
    landed = phone.evaluate(
        "([x, y]) => document.elementFromPoint(x, y).className.toString()", [x, y])
    assert 'desktop-player-surface' in landed, landed

    # Three taps inside one double-tap window, so nothing slow may happen
    # between them -- the box is measured once, up front.
    for _ in range(3):
        phone.mouse.click(x, y, delay=10)

    # Taps 2 and 3 each pair with the one before, so the clip rewinds twice
    # (18 -> 8 -> 0). A third tap read as a single one rewinds once and hides.
    current = phone.evaluate("() => document.querySelector('#playerShell video').currentTime")
    assert current < 1.0, current
    assert phone.locator('#playerShell').evaluate(
        "(el) => el.classList.contains('controls-visible')")


def test_danmaku_fades_back_while_the_chrome_is_up(page, server):
    """A popular episode floods the picture, and the flood runs straight through
    the buttons. The layer drops back while the bar is up and returns to the
    viewer's own opacity setting once it fades."""
    goto_watch(page, server)
    layer = page.locator('#danmakuLayer')
    shell = page.locator('#playerShell')

    shell.evaluate("(el) => el.classList.add('controls-visible')")
    page.wait_for_timeout(300)
    dimmed = layer.evaluate('(el) => Number(getComputedStyle(el).opacity)')

    shell.evaluate("(el) => el.classList.remove('controls-visible')")
    page.wait_for_timeout(300)
    full = layer.evaluate('(el) => Number(getComputedStyle(el).opacity)')

    assert full == pytest.approx(1.0, abs=0.01), full
    assert dimmed < 0.5, dimmed


# -------------------------------------------------------- add to home screen

def test_manifest_is_root_scoped_and_valid(page, server):
    response = page.request.get('%s/manifest.webmanifest' % server.url)
    assert response.ok
    assert 'application/manifest+json' in response.headers['content-type']

    manifest = json.loads(response.text())
    assert manifest['display'] == 'standalone'
    assert manifest['start_url'] == './'
    assert manifest['scope'] == './'
    assert manifest['background_color'] == '#0b0c0e'

    sizes = {icon['sizes'] for icon in manifest['icons']}
    assert {'192x192', '512x512'} <= sizes
    assert any(icon.get('purpose') == 'maskable' for icon in manifest['icons'])

    for icon in manifest['icons']:
        asset = page.request.get('%s/%s' % (server.url, icon['src'].lstrip('./')))
        assert asset.ok, icon['src']


@pytest.mark.parametrize('path', ['/', '/watch?id=%s' % FIRST_SN])
def test_pages_carry_ios_home_screen_meta(page, server, path):
    page.goto(server.url + path)

    assert page.get_attribute('link[rel="manifest"]', 'href') == './manifest.webmanifest'
    assert page.get_attribute('meta[name="apple-mobile-web-app-capable"]', 'content') == 'yes'
    assert page.get_attribute(
        'meta[name="apple-mobile-web-app-status-bar-style"]', 'content') == 'black-translucent'
    assert page.get_attribute('meta[name="apple-mobile-web-app-title"]', 'content') == 'aniGamerPlus+'
    assert 'viewport-fit=cover' in page.get_attribute('meta[name="viewport"]', 'content')

    touch_icon = page.get_attribute('link[rel="apple-touch-icon"]', 'href')
    assert page.request.get('%s/%s' % (server.url, touch_icon.lstrip('./'))).ok


def test_apple_touch_icon_is_180_square():
    from PIL import Image
    with Image.open(os.path.join(STATIC_PATH, 'img', 'pwa', 'apple-touch-icon.png')) as image:
        assert image.size == (180, 180)
        # iOS composites the icon over its own mask and shows alpha as black.
        assert image.mode == 'RGB'


def test_install_hint_appears_only_for_ios_browsers(phone, page, server):
    phone.goto(server.url)
    phone.wait_for_selector('#agpA2HS')
    expect(phone.locator('#agpA2HS')).to_contain_text('加入主畫面')

    phone.locator('#agpA2HS button').click()
    expect(phone.locator('#agpA2HS')).to_be_hidden()
    # The dismissal sticks across reloads.
    phone.reload()
    phone.wait_for_selector('#homeTimetable .agp-day')
    assert phone.locator('#agpA2HS').count() == 0

    # A desktop browser never sees the iOS-specific hint.
    page.goto(server.url)
    page.wait_for_selector('#homeTimetable .agp-day')
    assert page.locator('#agpA2HS').count() == 0


def test_standalone_launch_keeps_navigation_in_the_app(browser, server):
    context = browser.new_context(
        locale='zh-TW',
        viewport=IPHONE_VIEWPORT,
        has_touch=True,
        is_mobile=True,
        user_agent=('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    )
    # navigator.standalone is what iOS sets on a home-screen launch.
    context.add_init_script('Object.defineProperty(navigator, "standalone", { value: true });')
    page = context.new_page()
    page.goto(server.url)
    page.wait_for_selector('#homeTimetable .agp-day')

    # No install hint once it is already installed.
    assert page.locator('#agpA2HS').count() == 0

    page.locator('#homeTimetable .agp-card').first.click()
    page.wait_for_url(re.compile(r'/watch\?id='))
    assert len(context.pages) == 1, 'standalone navigation must not open a new context'
    context.close()


def test_service_worker_never_intercepts_video_or_watch_state(server):
    with open(os.path.join(STATIC_PATH, 'sw.js'), encoding='utf-8') as handle:
        source = handle.read()
    for path in ['/get_video.mp4', '/get_danmu.ass', '/video_list.json', '/watch/time']:
        assert "'%s'" % path in source, path
    assert "request.headers.has('range')" in source


def test_no_stale_framework_assets_are_referenced():
    """The redesign drops Bootstrap/FontAwesome/layui; nothing may still ask for
    a file that is not in the repo."""
    missing = []
    for name in ['index.html', 'watch.html']:
        path = os.path.join(ROOT, 'Dashboard', 'templates', name)
        with open(path, encoding='utf-8') as handle:
            html = handle.read()
        for asset in sorted(set(re.findall(r'(?:href|src)="\./(static/[^"?]+)', html))):
            if not os.path.exists(os.path.join(ROOT, 'Dashboard', asset)):
                missing.append('%s -> %s' % (name, asset))
    assert missing == [], missing


# ------------------------------------------------------------- native (iOS) shell

IOS_DIR = os.path.join(ROOT, 'ios')
BRIDGE_JS = os.path.join(IOS_DIR, 'AGP', 'Resources', 'Bridge.js')

# What the host does with a message, so the page can be exercised without a
# device: WebViewController hands the value to SystemControls, which moves the
# real level and reports the new one back through _update.
FAKE_HOST = """
window.__agpDevice = { brightness: 0.5, volume: 0.5, calls: [] };
window.__AGP_NATIVE_SEED__ = { brightness: 0.5, volume: 0.5 };
window.webkit = { messageHandlers: { agpNative: { postMessage: function (message) {
    window.__agpDevice.calls.push(message);
    if (message.name === 'brightness') { window.__agpDevice.brightness = message.value; }
    if (message.name === 'volume') { window.__agpDevice.volume = message.value; }
} } } };
"""


@pytest.fixture
def native(browser):
    """A phone running the real bridge the iOS app injects."""
    with open(BRIDGE_JS, encoding='utf-8') as handle:
        bridge = handle.read()
    context = browser.new_context(
        locale='zh-TW',
        viewport=IPHONE_VIEWPORT,
        device_scale_factor=3,
        is_mobile=True,
        has_touch=True,
        user_agent=('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    )
    # Same order and timing as WKUserScript at .atDocumentStart.
    context.add_init_script(FAKE_HOST)
    context.add_init_script(bridge)
    page = context.new_page()
    page.errors = []
    page.on('pageerror', lambda error: page.errors.append(str(error)))
    yield page
    context.close()


def test_bridge_hands_the_page_both_levels(native, server):
    goto_watch(native, server)

    state = native.evaluate("""() => ({
        version: window.AgpNative.version,
        platform: window.AgpNative.platform,
        brightness: window.AgpNative.brightness,
        volume: window.AgpNative.volume,
    })""")
    assert state == {'version': 1, 'platform': 'ios', 'brightness': 0.5, 'volume': 0.5}

    # Setters clamp, report the level applied, and reach the host.
    assert native.evaluate("() => window.AgpNative.setVolume(2)") == 1
    assert native.evaluate("() => window.AgpNative.setBrightness(-1)") == 0
    assert native.evaluate("() => window.__agpDevice.calls.slice(-2)") == [
        {'name': 'volume', 'value': 1},
        {'name': 'brightness', 'value': 0},
    ]


def test_native_volume_drag_moves_the_system_level(native, server):
    goto_watch(native, server)
    before = native.evaluate("() => document.querySelector('#playerShell video').volume")

    box = surface_box(native)
    x = box['x'] + box['width'] * 0.78
    drag(native, x, box['y'] + box['height'] * 0.52, x, box['y'] + box['height'] * 0.06)

    assert native.evaluate("() => window.__agpDevice.volume") > 0.85
    # The element is left alone: iOS refuses writes to it, and routing round
    # that through a gain node is exactly what the app makes unnecessary.
    assert native.evaluate("() => document.querySelector('#playerShell video').volume") == before
    expect(native.locator('#playerHud')).to_contain_text('音量')


def test_native_brightness_drag_dims_the_screen_not_the_picture(native, server):
    goto_watch(native, server)

    box = surface_box(native)
    x = box['x'] + box['width'] * 0.22
    drag(native, x, box['y'] + box['height'] * 0.35, x, box['y'] + box['height'] * 0.60)

    level = native.evaluate("() => window.__agpDevice.brightness")
    # Below the overlay's floor, which is the point: that floor only exists so a
    # web viewer cannot black out the picture with no way back.
    assert 0 < level < 0.2, level
    assert native.locator('#playerDim').evaluate('(el) => Number(el.style.opacity || 0)') == 0
    expect(native.locator('#playerHud')).to_contain_text('螢幕亮度')


def test_hardware_buttons_reach_the_player(native, server):
    goto_watch(native, server)
    native.evaluate("() => window.AgpNative._update({ volume: 0.28, brightness: 0.9 })")

    expect(native.locator('#playerVolume')).to_have_value('28')
    native.locator('#settingsToggle').click()
    expect(native.locator('#settingsMenu [data-view="brightness"]')).to_contain_text('90%')


def test_native_settings_menu_names_the_real_thing(native, server):
    goto_watch(native, server)
    native.locator('#settingsToggle').click()
    menu = native.locator('#settingsMenu')
    expect(menu).to_contain_text('螢幕亮度')
    assert '畫面亮度' not in menu.inner_text()

    menu.locator('[data-view="brightness"]').click()
    expect(menu).to_contain_text('這會直接調整裝置的螢幕亮度')


def test_the_app_is_not_offered_the_install_banner(native, server):
    native.goto(server.url)
    native.wait_for_selector('#homeTimetable .agp-day')
    assert native.locator('#agpA2HS').count() == 0
    assert native.errors == []


def test_the_ios_shell_and_the_page_agree_on_the_contract():
    """Nothing but these two files links the app to the player, so a rename on
    one side has to fail here rather than on a device."""
    with open(BRIDGE_JS, encoding='utf-8') as handle:
        bridge = handle.read()
    with open(os.path.join(IOS_DIR, 'AGP', 'WebViewController.swift'), encoding='utf-8') as handle:
        host = handle.read()
    with open(os.path.join(ROOT, 'Dashboard', 'static', 'js', 'watch.js'), encoding='utf-8') as handle:
        player = handle.read()

    for token in ['__AGP_NATIVE_SEED__', 'agpNative']:
        assert token in bridge and token in host, token
    for token in ['AgpNative', 'agpnativechange']:
        assert token in bridge and token in player, token
    # Bridge.js is read out of the bundle by name, and only lands there because
    # its directory is declared as a resources build phase.
    with open(os.path.join(IOS_DIR, 'project.yml'), encoding='utf-8') as handle:
        spec = handle.read()
    assert 'buildPhase: resources' in spec
    assert 'forResource: "Bridge"' in host
