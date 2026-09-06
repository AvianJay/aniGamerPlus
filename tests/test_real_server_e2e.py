"""End-to-end coverage against a *real* aniGamerPlus server and a *real*
Bahamut download -- no fixtures, no stub app.

Unlike ``test_web_ui.py`` (which serves the templates from ``ui_harness.py``
against synthetic data), this module drives the whole product the way a person
would: it logs into the dashboard in a browser, queues the download from the
"手動添加任務" dialog, waits for the episode to actually land on disk, and then
plays that file through the redesigned player.

Prerequisites:

*   ``python aniGamerPlus.py`` running with ``dashboard.online_watch`` and
    ``dashboard.user_control.enabled`` turned on.
*   A valid ``cookie.txt`` for an account that can reach the target episode.

Run with::

    python -m pytest tests/test_real_server_e2e.py -s

The 邊看邊下載 tests at the bottom stay skipped until they are pointed at an
episode by hand, because they queue a real download and there is no route that
can call one back::

    AGP_STREAM_KEYWORD=葬送的芙莉蓮 AGP_STREAM_SN=123456 python -m pytest         tests/test_real_server_e2e.py -s -k stream

Pick an episode that is *not* in the library yet -- a finished one has a file to
play and nothing to stream. ``segment_download_mode`` has to be on, since the
chunks it writes are the stream.

The browser is visible by default because this suite is meant to be watched;
set ``AGP_HEADLESS=1`` for an unattended run.
"""

import os
import re
import time

import pytest

playwright_api = pytest.importorskip('playwright.sync_api')
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

@pytest.fixture(scope='session')
def browser(chromium_launcher):
    headless = os.environ.get('AGP_HEADLESS') == '1'
    slow_mo = int(os.environ.get('AGP_SLOWMO') or (0 if headless else 120))
    instance = chromium_launcher(headless=headless, slow_mo=slow_mo)
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


def series_info(page, sn=TARGET_SN):
    response = page.request.get('%s/watch/series.json?id=%s' % (BASE_URL, sn))
    assert response.ok, 'series.json says %d for sn=%s' % (response.status, sn)
    return response.json()


def test_the_watch_page_shows_bahamut_own_description_and_cover(page, downloaded_episode):
    """作品資訊 used to write its own blurb over a frame ffmpeg pulled out of the
    episode. The blurb was about this website rather than about the anime, and
    the frame was whatever happened to be on screen a few seconds in."""
    open_player(page)
    info = series_info(page)
    assert len(info['content']) > 80, info['content']

    desc = page.locator('#animeInfo .watch-info-desc').inner_text()
    assert desc.startswith(info['content'][:40]), desc[:80]
    assert 'aniGamerPlus+' not in desc

    # 巴哈's 作品介紹 carries the staff credits, so the real one is always long
    # enough to fold. Six lines of synopsis, the credits behind 展開.
    body = page.locator('#animeInfo .watch-info-desc')
    folded = body.bounding_box()['height']
    assert body.evaluate('el => el.scrollHeight') > folded + 2, 'nothing was folded away'
    page.locator('#animeInfo .watch-info-more').click()
    expect(page.locator('#animeInfo .watch-info-more')).to_have_text('收合')
    assert body.bounding_box()['height'] > folded

    cover = page.locator('#animeInfo .watch-info-cover img')
    expect(cover).to_have_attribute('src', info['cover'])
    # And it is a URL a browser can really fetch -- a 403 from p2.bahamut.com.tw
    # would leave the gradient plate showing and look exactly like no fix at all.
    page.wait_for_function(
        """() => {
            const img = document.querySelector('#animeInfo .watch-info-cover img');
            return img && img.complete && img.naturalWidth > 0;
        }""", timeout=30000)
    assert page.errors == []


def test_the_episode_list_is_the_whole_series_not_the_library(page, downloaded_episode):
    """One episode downloaded out of fifteen, and 選集 said 共 1 集."""
    open_player(page)
    info = series_info(page)
    episodes = [episode for group in info['groups'] for episode in group['episodes']]
    on_disk = [episode for episode in episodes if episode['local']]
    if len(episodes) <= len(on_disk):
        pytest.skip('the whole series is already downloaded; nothing to tell apart')

    expect(page.locator('#episodeGrid .watch-episodes-head span')).to_have_text(
        '共 %d 集' % len(episodes))
    expect(page.locator('#episodeGrid .watch-episode-btn')).to_have_count(len(episodes))
    # What is not on disk is still listed -- as a button, because tapping it has
    # to queue the download before there is anything at that address to play.
    expect(page.locator('#episodeGrid button[data-stream]')).to_have_count(
        len(episodes) - len(on_disk))
    expect(page.locator('#episodeGrid .watch-episode-btn.is-current')).to_have_count(1)
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


# ------------------------------------------------------------- 邊看邊下載

# No default sn here, unlike TARGET_SN above. This fixture starts a download
# that nothing can call back -- there is no cancel route -- so it only runs
# against an episode somebody deliberately named.
STREAM_KEYWORD = os.environ.get('AGP_STREAM_KEYWORD', '')
STREAM_SN = os.environ.get('AGP_STREAM_SN', '')
STREAM_READY_TIMEOUT = int(os.environ.get('AGP_STREAM_TIMEOUT', '300'))

needs_stream_target = pytest.mark.skipif(
    not (STREAM_KEYWORD and STREAM_SN),
    reason='set AGP_STREAM_KEYWORD and AGP_STREAM_SN to an episode that is not '
           'downloaded yet; this starts a real download and cannot undo it')


def hls_status(page, sn=None):
    response = page.request.get('%s/hls/status.json?id=%s' % (BASE_URL, sn or STREAM_SN))
    return response.json() if response.ok else {'mode': 'error'}


@pytest.fixture(scope='session')
def streaming_episode(signed_in_context):
    """Queue the download the way the feature is meant to be reached.

    Home page, search box, the sheet, 邊看邊下載 -- every step a person takes.
    Returns once the server says there is something to play, which is the first
    moment the rest of these tests have any subject.
    """
    page = signed_in_context.new_page()
    try:
        if downloaded_entry(page, STREAM_SN):
            pytest.skip('sn=%s is already in the library, nothing to stream'
                        % STREAM_SN)
        config = page.request.get(BASE_URL + '/data/config.json')
        if config.ok and not config.json().get('segment_download_mode'):
            # Without it Anime.py writes one growing .mp4 and there are no
            # chunks to publish. The feature is off, not broken.
            pytest.skip('segment_download_mode is off on this server')

        page.goto(BASE_URL + '/')
        page.wait_for_selector('#homeSearch')
        page.fill('#homeSearch', STREAM_KEYWORD)
        # #homeCatalog is already full of 所有動畫 before anybody types, so waiting
        # for "a poster" is waiting for something that is already there -- the
        # click then lands on whatever was on screen, not on what was searched
        # for. The heading is what actually changes when results arrive.
        page.wait_for_selector('#homeCatalog .agp-section-head:has-text("搜尋結果")',
                               timeout=60000)
        poster = page.locator('#homeCatalog .agp-poster', has_text=STREAM_KEYWORD).first
        poster.wait_for(timeout=60000)
        poster.click()
        page.wait_for_selector('#catalogSheet .agp-epgroup', timeout=60000)

        stream = page.locator('#catalogSheet button[data-stream]')
        if not stream.count():
            pytest.skip('the sheet for 「%s」 offers no stream; it is already downloaded'
                        % STREAM_KEYWORD)
        # A keyword that opened the wrong title would stream one episode and then
        # poll another forever, which reads as "the feature is broken".
        assert stream.get_attribute('data-stream') == STREAM_SN, (
            'AGP_STREAM_KEYWORD opened sn=%s, not the requested sn=%s'
            % (stream.get_attribute('data-stream'), STREAM_SN))
        stream.click()
        page.wait_for_url(lambda url: 'streaming=1' in url, timeout=30000)

        deadline = time.time() + STREAM_READY_TIMEOUT
        status = {}
        while time.time() < deadline:
            status = hls_status(page)
            if status.get('mode') in ('streaming', 'finalising') and status.get('ready'):
                return status
            if status.get('mode') == 'file':
                pytest.skip('sn=%s finished downloading before the test could watch it'
                            % STREAM_SN)
            page.wait_for_timeout(3000)
        pytest.fail('sn=%s never became playable within %ds (last status: %r)'
                    % (STREAM_SN, STREAM_READY_TIMEOUT, status))
    finally:
        page.close()


def open_stream(page):
    page.goto('%s/watch?id=%s&streaming=1' % (BASE_URL, STREAM_SN))
    page.wait_for_selector('#playerShell.is-custom-player')
    # readyState 2 is a decoded frame, which for this stream means the key was
    # fetched, the chunks were decrypted and hls.js transmuxed them.
    page.wait_for_function(
        "() => document.querySelector('#playerShell video')?.readyState >= 2",
        timeout=90000)
    return page


@needs_stream_target
def test_the_real_temp_directory_serves_a_playlist_a_browser_accepts(page, streaming_episode):
    body = page.request.get('%s/hls/playlist.m3u8?id=%s' % (BASE_URL, STREAM_SN)).text()
    lines = [line for line in body.splitlines() if line]

    assert lines[0] == '#EXTM3U', lines[:3]
    # Renumbering a segment would change its implicit IV and break decryption,
    # so the sequence always starts at 0 no matter how much has landed.
    assert '#EXT-X-MEDIA-SEQUENCE:0' in lines
    key = [line for line in lines if line.startswith('#EXT-X-KEY')]
    assert key, lines
    assert 'METHOD=AES-128' in key[0], key[0]
    # The key comes off this server, not off 動畫瘋 -- a player pointed at the
    # original URI would open a second connection to the account.
    assert 'key.bin?id=%s' % STREAM_SN in key[0], key[0]
    if 'IV=' not in key[0]:
        # No explicit IV means the segment index IS the IV, so the numbering may
        # never be shifted. 動畫瘋 usually sends one; the fixture does not.
        assert '#EXT-X-MEDIA-SEQUENCE:0' in lines, lines[:8]

    segments = [line for line in lines if line.startswith('segment.ts?')]
    assert segments, body
    assert len(segments) >= streaming_episode['ready'], (len(segments), streaming_episode)
    assert [int(line.rsplit('n=', 1)[1]) for line in segments] == list(range(len(segments)))
    if hls_status(page)['mode'] == 'streaming':
        # Still downloading: hls.js has to keep coming back for more.
        assert '#EXT-X-ENDLIST' not in lines


@needs_stream_target
def test_the_real_stream_still_lists_the_whole_series(page, streaming_episode):
    """The screenshot that started this: 邊看邊下載 running, 選集 showing 共 1 集.

    Mid-download the library holds exactly one episode of the series -- the one
    being fetched -- so the library was never the right thing to ask."""
    open_stream(page)
    info = series_info(page, STREAM_SN)
    total = sum(len(group['episodes']) for group in info['groups'])
    assert total > 1, 'a one-episode series cannot show this'

    expect(page.locator('#episodeGrid .watch-episodes-head span')).to_have_text(
        '共 %d 集' % total)
    expect(page.locator('#episodeGrid .watch-episode-btn.is-current')).to_have_count(1)
    assert page.errors == []


@needs_stream_target
def test_the_real_stream_never_asks_bahamut_for_anything(page, streaming_episode):
    outbound = []
    page.on('request', lambda request: outbound.append(request.url))
    open_stream(page)

    # The whole point of serving the temp directory instead of proxying: however
    # many people watch, 動畫瘋 sees exactly the one download it was already
    # sending. Nothing here opens a second connection to the account.
    strays = [url for url in outbound if 'gamer.com.tw' in url or 'gamer2-cds' in url]
    assert strays == [], strays
    assert any('/hls/key.bin' in url for url in outbound)
    assert any('/hls/segment.ts' in url for url in outbound)
    assert page.errors == []


@needs_stream_target
def test_the_real_stream_decodes_and_plays_while_it_downloads(page, streaming_episode):
    open_stream(page)

    expect(page.locator('#playerDownloading')).to_be_visible()
    expect(page.locator('#playerDownloading')).to_contain_text('邊看邊下載')
    # The clock spans the episode, not the part that happens to be on disk --
    # otherwise the right-hand end of the bar crawls while you watch.
    expect(page.locator('#timeTotal')).not_to_have_text('0:00')

    meta = page.evaluate("""() => {
        const v = document.querySelector('#playerShell video');
        v.muted = true;
        v.play();
        return {width: v.videoWidth, duration: v.duration};
    }""")
    assert meta['width'] >= 640, meta
    assert meta['duration'] < streaming_episode['totalDuration'], (meta, streaming_episode)

    page.wait_for_function(
        "() => document.querySelector('#playerShell video').currentTime > 0.6",
        timeout=60000)
    assert page.errors == []


@needs_stream_target
def test_the_real_server_refuses_a_chunk_it_has_not_published(page, streaming_episode):
    # A player working from a stale playlist, or one guessing ahead: either way
    # the answer is 404, because the file on disk may be half-written.
    ahead = page.request.get('%s/hls/segment.ts?id=%s&n=%d'
                             % (BASE_URL, STREAM_SN, streaming_episode['total'] + 200))
    assert ahead.status == 404, ahead.status
    landed = page.request.get('%s/hls/segment.ts?id=%s&n=0' % (BASE_URL, STREAM_SN))
    assert landed.ok and landed.body(), landed.status
    # Chunks go out encrypted, so the raw length is a multiple of the AES block.
    assert len(landed.body()) % 16 == 0, len(landed.body())

    # Decrypt it the way hls.js will: 188 is the transport-stream packet size and
    # 0x47 its sync byte, so a chunk that fails this was published half-written
    # and would have played as a stall or a burst of macroblocks.
    from Crypto.Cipher import AES
    key_bytes = page.request.get('%s/hls/key.bin?id=%s' % (BASE_URL, STREAM_SN)).body()
    playlist = page.request.get('%s/hls/playlist.m3u8?id=%s' % (BASE_URL, STREAM_SN)).text()
    key_line = [line for line in playlist.splitlines() if line.startswith('#EXT-X-KEY')][0]
    if 'IV=' in key_line:
        iv = bytes(bytearray.fromhex(key_line.split('IV=0x', 1)[1].split(',')[0].strip()))
    else:
        iv = b'\x00' * 16
    plain = AES.new(key_bytes, AES.MODE_CBC, iv).decrypt(landed.body())
    plain = plain[:-plain[-1]] if 0 < plain[-1] <= 16 else plain
    assert plain[:1] == b'\x47', plain[:8]
    assert len(plain) % 188 == 0, len(plain)


@needs_stream_target
def test_the_real_seek_bar_stops_at_what_has_landed(page, streaming_episode):
    open_stream(page)

    page.locator('#playerSeek').evaluate(
        "(el) => { el.value = el.max;"
        " el.dispatchEvent(new Event('change', {bubbles: true})); }")
    page.wait_for_timeout(600)

    current = page.evaluate(
        "() => document.querySelector('#playerShell video').currentTime")
    buffered = hls_status(page)['readyDuration']
    # Dragging to the far end of a bar that spans the whole episode must land
    # inside the downloaded part, not on a black frame that never resolves.
    assert current <= buffered + 1.0, (current, buffered)
    assert page.errors == []
