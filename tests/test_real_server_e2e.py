"""End-to-end coverage against a *real* aniGamerPlus server and a *real*
Bahamut download -- no fixtures, no stub app.

Unlike ``test_web_ui.py`` (which serves the templates from ``ui_harness.py``
against synthetic data), this module drives the whole product the way a person
would: it logs into the dashboard in a browser, queues the download from the
"手動添加任務" dialog, waits for the episode to actually land on disk, and then
plays that file through the redesigned player.

Prerequisites (see tests/README-real-e2e.md):

*   ``python aniGamerPlus.py`` running with ``dashboard.online_watch`` and
    ``dashboard.user_control.enabled`` turned on.
*   A valid ``cookie.txt`` for an account that can reach the target episode.

Run with::

    python -m pytest tests/test_real_server_e2e.py -s

The browser is visible by default because this suite is meant to be watched;
set ``AGP_HEADLESS=1`` for an unattended run.
"""

import os
import re
import time

import pytest

playwright_api = pytest.importorskip('playwright.sync_api')
sync_playwright = playwright_api.sync_playwright
expect = playwright_api.expect

BASE_URL = os.environ.get('AGP_SERVER', 'http://127.0.0.1:5000')
DASH_USER = os.environ.get('AGP_DASH_USER', 'admin')
DASH_PASS = os.environ.get('AGP_DASH_PASS', 'admin')

# Re：從零開始的異世界生活 第四季 [1] -- the first hit for the keyword "RE:" on
# ani.gamer.com.tw, resolved from animeRef.php?sn=114044.
TARGET_SN = os.environ.get('AGP_SN', '48502')
TARGET_NAME = os.environ.get('AGP_ANIME', 'Re：從零開始的異世界生活')
TARGET_RESOLUTION = os.environ.get('AGP_RES', '1080P')

DOWNLOAD_TIMEOUT = int(os.environ.get('AGP_DOWNLOAD_TIMEOUT', '1800'))
IPHONE_VIEWPORT = {'width': 390, 'height': 844}
IOS_UA = ('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1')


# --------------------------------------------------------------------- setup

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
    headless = os.environ.get('AGP_HEADLESS') == '1'
    slow_mo = int(os.environ.get('AGP_SLOWMO') or (0 if headless else 120))
    with sync_playwright() as p:
        instance = launch_chromium(p, headless=headless, slow_mo=slow_mo)
        yield instance
        instance.close()


@pytest.fixture(scope='session')
def live_server():
    """Skip the whole module rather than fail if the server is not running."""
    import urllib.error
    import urllib.request
    try:
        urllib.request.urlopen(BASE_URL + '/get_server_info', timeout=5).read()
    except urllib.error.HTTPError:
        pass                                  # a 401/403 still means it is up
    except Exception as error:
        pytest.skip('no aniGamerPlus server on %s (%s)' % (BASE_URL, error))
    return BASE_URL


def sign_in(page):
    page.goto(BASE_URL + '/login')
    if page.locator('#username').count():
        page.fill('#username', DASH_USER)
        page.fill('#password', DASH_PASS)
        page.click('button[type="submit"]')
        # Not networkidle: the dashboard holds a websocket open, so the network
        # never goes quiet and that wait just burns the whole timeout.
        page.wait_for_url(lambda url: '/login' not in url, timeout=30000)
        page.wait_for_load_state('domcontentloaded')


@pytest.fixture(scope='session')
def signed_in_context(browser, live_server):
    context = browser.new_context(locale='zh-TW', viewport={'width': 1440, 'height': 900})
    page = context.new_page()
    sign_in(page)
    yield context
    context.close()


@pytest.fixture
def page(signed_in_context):
    page = signed_in_context.new_page()
    page.errors = []
    page.on('pageerror', lambda error: page.errors.append(str(error)))
    yield page
    page.close()


def video_list(page):
    response = page.request.get(BASE_URL + '/video_list.json')
    if not response.ok:
        return []
    return response.json().get('videos', [])


def downloaded_entry(page, sn=TARGET_SN):
    for video in video_list(page):
        if str(video.get('sn')) == str(sn):
            return video
    return None


# ------------------------------------------------- the download, via the UI

@pytest.fixture(scope='session')
def downloaded_episode(signed_in_context):
    """Queue the real download through the dashboard UI and wait for the file.

    Session-scoped so the episode is fetched once even though several tests
    depend on it. If it is already on disk from an earlier run the dialog is
    skipped entirely.
    """
    page = signed_in_context.new_page()
    try:
        existing = downloaded_entry(page)
        if existing:
            return existing

        page.goto(BASE_URL + '/control')
        page.wait_for_selector('button[data-target="#manualTasks"]', timeout=30000)

        page.click('button[data-target="#manualTasks"]')
        dialog = page.locator('#manualTasks')
        expect(dialog).to_be_visible()

        page.fill('#manual_link', 'https://ani.gamer.com.tw/animeVideo.php?sn=' + TARGET_SN)
        page.select_option('#manual_mode', 'single')
        page.select_option('#manual_resolution', TARGET_RESOLUTION)
        # 下載彈幕 is a bootstrap-switch: the real <input> is hidden behind the
        # widget, so readManualConfig()'s .is(":checked") is what has to be set.
        page.evaluate("() => { document.querySelector('#manual_danmu').checked = true; }")
        page.once('dialog', lambda d: d.accept())
        page.click('#manualTasks .modal-footer button.btn-success')

        deadline = time.time() + DOWNLOAD_TIMEOUT
        entry = None
        while time.time() < deadline:
            entry = downloaded_entry(page)
            if entry:
                break
            page.wait_for_timeout(5000)
        assert entry, ('sn=%s did not finish downloading within %ds'
                       % (TARGET_SN, DOWNLOAD_TIMEOUT))
        return entry
    finally:
        page.close()


def test_manual_download_produces_a_real_episode(downloaded_episode):
    entry = downloaded_episode
    assert TARGET_NAME in entry['anime_name'], entry['anime_name']
    assert int(entry['resolution']) == int(TARGET_RESOLUTION.rstrip('Pp'))
    assert entry.get('danmu'), 'danmaku was requested but not recorded'

    path = entry['path']
    assert os.path.exists(path), path
    # A real ~24 minute 1080p episode, not a placeholder.
    assert os.path.getsize(path) > 50 * 1024 * 1024, os.path.getsize(path)


# ----------------------------------------------------- the redesigned pages

def test_home_page_lists_the_downloaded_anime(page, downloaded_episode):
    page.goto(BASE_URL + '/')
    page.wait_for_selector('#homeLibrary .agp-poster')

    expect(page.locator('.agp-topbar .agp-brand')).to_be_visible()
    expect(page.locator('#homeLibrary')).to_contain_text(TARGET_NAME)

    # The timetable groups the real download by its real air date.
    expect(page.locator('#homeTimetable .agp-card').first).to_be_visible()
    expect(page.locator('#homeTimetable')).to_contain_text(TARGET_NAME)
    assert page.errors == []


def open_player(page, sn=TARGET_SN):
    page.goto('%s/watch?id=%s' % (BASE_URL, sn))
    page.wait_for_selector('#playerShell.is-custom-player')
    page.wait_for_function(
        "() => document.querySelector('#playerShell video')?.readyState >= 1",
        timeout=60000)
    return page


def test_player_plays_the_real_1080p_file(page, downloaded_episode):
    open_player(page)

    meta = page.evaluate("""() => {
        const v = document.querySelector('#playerShell video');
        return {duration: v.duration, width: v.videoWidth, height: v.videoHeight};
    }""")
    assert meta['width'] == 1920 and meta['height'] == 1080, meta
    assert meta['duration'] > 600, meta        # a full episode, not a clip

    expect(page.locator('#episodeChipLabel')).to_contain_text(TARGET_NAME)
    expect(page.locator('#timeTotal')).not_to_have_text('0:00')

    page.locator('#playToggle').click()
    page.wait_for_function(
        "() => document.querySelector('#playerShell video').currentTime > 0.3",
        timeout=30000)
    assert page.errors == []


def test_real_danmaku_loads_and_seeks(page, downloaded_episode):
    open_player(page)
    page.wait_for_selector('#danmakuList .danmaku-row', timeout=60000)

    rows = page.locator('#danmakuList .danmaku-row')
    count = rows.count()
    assert count > 5, 'expected real viewer comments, got %d rows' % count
    expect(page.locator('#danmakuCount')).to_contain_text('則')

    # Clicking a comment seeks to the moment it was posted.
    target = rows.nth(min(count - 1, 4))
    stamp = target.locator('time').inner_text()
    minutes, seconds = stamp.split(':')[-2:]
    expected = int(minutes) * 60 + int(seconds)
    target.click()
    page.wait_for_function(
        "(t) => Math.abs(document.querySelector('#playerShell video').currentTime - t) < 1.5",
        arg=expected, timeout=15000)


def test_watch_progress_round_trips_through_the_server(page, downloaded_episode):
    open_player(page)

    # The position is only reported when playback actually stops, so it has to
    # be running first -- pausing an already-paused video fires no ``pause``
    # event. The desktop player autoplays, so only nudge it if that was refused.
    if page.evaluate("() => document.querySelector('#playerShell video').paused"):
        page.locator('#playToggle').click()
    page.wait_for_function(
        "() => !document.querySelector('#playerShell video').paused", timeout=30000)

    with page.expect_request(re.compile(r'/watch/time\?type=set'), timeout=30000) as caught:
        page.evaluate("""() => {
            const v = document.querySelector('#playerShell video');
            v.currentTime = 125;
            v.pause();
        }""")
    assert 'duration=' in caught.value.url

    stored = page.evaluate("""async (sn) => {
        const r = await fetch('./watch/time?type=get&sn=' + sn);
        return r.json();
    }""", TARGET_SN)
    assert stored['duration'] > 600, stored
    assert 120 <= stored['time'] <= 130, stored

    # And the home page turns that into a real progress bar.
    page.goto(BASE_URL + '/')
    page.wait_for_selector('#homeContinue .agp-continue-item')
    width = page.locator('#homeContinue .agp-card-progress i').first.evaluate(
        '(el) => parseFloat(el.style.width)')
    assert 0 < width < 100, width


# --------------------------------------------------------- mobile gestures

@pytest.fixture
def phone(signed_in_context, browser, live_server):
    context = browser.new_context(
        locale='zh-TW', viewport=IPHONE_VIEWPORT, device_scale_factor=3,
        is_mobile=True, has_touch=True, user_agent=IOS_UA,
        storage_state=signed_in_context.storage_state())
    page = context.new_page()
    page.errors = []
    page.on('pageerror', lambda error: page.errors.append(str(error)))
    yield page
    context.close()


def drag(page, x_from, y_from, x_to, y_to, steps=14):
    page.mouse.move(x_from, y_from)
    page.mouse.down()
    for i in range(1, steps + 1):
        page.mouse.move(x_from + (x_to - x_from) * i / steps,
                        y_from + (y_to - y_from) * i / steps)
    page.mouse.up()


def surface_box(page):
    return page.locator('#playerShell .desktop-player-surface').bounding_box()


def test_gestures_work_on_the_real_episode(phone, downloaded_episode):
    open_player(phone)
    expect(phone.locator('#playerShell')).to_have_class(re.compile('is-touch-player'))

    box = surface_box(phone)
    # Stay in the picture. On a phone the control block is the bottom ~38% of
    # the player, and a drag that starts on the fullscreen button belongs to
    # that button -- which is why these coordinates hug the top of the frame.
    bottom = box['y'] + box['height'] * 0.55
    top = box['y'] + box['height'] * 0.08

    # Right half: volume up.
    phone.evaluate("() => { document.querySelector('#playerShell video').volume = 0.4; }")
    drag(phone, box['x'] + box['width'] * 0.78, bottom, box['x'] + box['width'] * 0.78, top)
    volume = phone.evaluate("() => document.querySelector('#playerShell video').volume")
    assert volume > 0.85, volume

    # Left half: picture brightness down.
    drag(phone, box['x'] + box['width'] * 0.22, top, box['x'] + box['width'] * 0.22, bottom)
    opacity = phone.locator('#playerDim').evaluate('(el) => Number(el.style.opacity || 0)')
    assert opacity > 0.3, opacity

    # Horizontal: scrub. A full episode gives the gesture room to move.
    phone.evaluate("() => { document.querySelector('#playerShell video').currentTime = 300; }")
    y = box['y'] + box['height'] * 0.35
    drag(phone, box['x'] + box['width'] * 0.25, y, box['x'] + box['width'] * 0.60, y)
    current = phone.evaluate("() => document.querySelector('#playerShell video').currentTime")
    assert current > 305, current
