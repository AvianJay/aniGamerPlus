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
    CATALOG_ALL,
    CATALOG_LANDING_LOCAL_SN,
    CATALOG_LOCAL_SN,
    CATALOG_SEASON,
    HLS_ANIME,
    HLS_DURATIONS,
    HLS_SEGMENTS,
    HLS_SN,
    HLS_STATE,
    HLS_STATE_DEFAULT,
    MANUAL_TASKS,
    NO_SERIES_INFO_ANIME,
    WATCH_TIMES,
    WATCH_SERIES_STREAMING,
    WATCH_SERIES_TOTAL,
    WATCH_SYNOPSIS,
    HarnessServer,
)

playwright_api = pytest.importorskip('playwright.sync_api')
expect = playwright_api.expect

FIRST_SN = VIDEO_LIST['videos'][0]['sn']
FIRST_ANIME = VIDEO_LIST['videos'][0]['anime_name']
IPHONE_VIEWPORT = {'width': 390, 'height': 844}


# --------------------------------------------------------------------- setup

@pytest.fixture(scope='session')
def server():
    with HarnessServer() as running:
        yield running


@pytest.fixture(scope='session')
def server_without_catalog():
    """A dashboard with ``online_watch`` off, where /catalog/* does not exist."""
    with HarnessServer(catalog=False) as running:
        yield running


@pytest.fixture(scope='session')
def browser(chromium_launcher):
    """Headless by default; set ``AGP_HEADED=1`` to watch the run in a real
    window (``AGP_SLOWMO`` milliseconds between actions makes it followable)."""
    headed = os.environ.get('AGP_HEADED') == '1'
    slow_mo = int(os.environ.get('AGP_SLOWMO') or (250 if headed else 0))
    instance = chromium_launcher(headless=not headed, slow_mo=slow_mo)
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


def open_tab(page, name):
    """Switch the home page to one of the five bottom tabs.

    片庫 and 所有動畫 live on the 所有動畫 pane, and a pane that is not open is
    ``hidden`` -- so anything looking at them has to say so first.
    """
    page.wait_for_selector('.agp-tabbar-btn[data-pane="%s"]' % name)
    if page.locator('#catalogSheet').is_visible():
        # 片單詳情是全螢幕的 sheet, 它的 backdrop 蓋著整排頁籤. 從網址冷開
        # sheet 的測試按不到那顆鈕, 但底下那一頁還是要切 —— 那就照 shell 自己
        # 的路走. 頁籤按起來會怎樣有它自己的測試.
        page.evaluate('(name) => window.AGP.showPane(name)', name)
    else:
        page.locator('.agp-tabbar-btn[data-pane="%s"]' % name).click()
    page.wait_for_selector('.agp-pane[data-pane="%s"]:not([hidden])' % name)
    return page


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
    expect(page.locator('.agp-tabbar-btn[aria-current="page"]')).to_have_text('首頁')

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
    open_tab(page, 'all')
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
    open_tab(page, 'all')
    page.wait_for_selector('#homeLibrary .agp-poster')

    total = page.locator('#homeLibrary .agp-poster').count()
    page.fill('#homeSearch', '迷宮')
    page.wait_for_function(
        "() => document.querySelectorAll('#homeLibrary .agp-poster').length === 1")
    assert total > 1
    expect(page.locator('#homeLibrary .agp-poster-foot strong')).to_have_text('迷宮飯')

    page.fill('#homeSearch', 'zzzz-no-such-anime')
    expect(page.locator('#homeLibrary .agp-empty')).to_contain_text('找不到')


# ------------------------------------------------------------------- 片單

def open_home(page, server, path='/'):
    page.goto(server.url + path)
    # 片庫比對的結果跟動畫瘋的整份片單同在「所有動畫」那一頁, 首頁看不到它們
    open_tab(page, 'all')
    page.wait_for_selector('#homeCatalog .agp-poster')
    return page


def open_sheet(page, server, anime_sn):
    open_home(page, server, '/#anime-%s' % anime_sn)
    page.wait_for_selector('#catalogSheet .agp-epgroup')
    return page.locator('#catalogSheet')


def test_catalog_draws_the_bahamut_front_page(page, server):
    open_home(page, server)

    # 本季新番 keeps the wide episode banner 動畫瘋 ships it as; the catalogue
    # grids below it are the 3:4 cover, and one shape would letterbox the other.
    open_tab(page, 'home')
    card = page.locator('#homeSeason .agp-card').first
    ratio = card.locator('.agp-card-art').evaluate(
        '(el) => { const r = el.getBoundingClientRect(); return r.width / r.height; }')
    assert 1.7 < ratio < 1.83
    assert page.locator('#homeSeason .agp-card').count() == 6

    expect(page.locator('#homeSchedule .agp-daytab')).to_have_count(7)
    expect(page.locator('#homeCatalogHot .agp-poster-rank').first).to_have_text('1')
    assert page.locator('#homeCatalogNew .agp-poster').count() == 4

    open_tab(page, 'all')
    expect(page.locator('#homeCatalog .agp-count')).to_have_text(
        '共 %d 部作品' % len(CATALOG_ALL))
    expect(page.locator('#homeCatalog .agp-pager span')).to_have_text('第 1 / 3 頁')
    assert page.locator('#homeCatalog .agp-poster').count() == 28

    # 片庫 is still there, and still counts only what is actually on disk.
    expect(page.locator('#homeLibrary .agp-section-head h2')).to_have_text('片庫')
    assert page.locator('#homeLibrary .agp-poster').count() == len(
        set(video['anime_name'] for video in VIDEO_LIST['videos']))
    assert page.errors == []


def test_catalog_poster_leaves_the_whole_cover_visible(page, server):
    """The title used to ride on the artwork as a gradient overlay, which took
    the bottom quarter of every cover with it."""
    open_home(page, server)
    open_tab(page, 'home')
    poster = page.locator('#homeCatalogHot .agp-poster').first
    art = poster.locator('.agp-poster-art').bounding_box()
    foot = poster.locator('.agp-poster-foot').bounding_box()

    # Nothing is painted over the cover: the caption starts where the art ends.
    assert foot['y'] >= art['y'] + art['height'] - 1

    # And the tile is the shape 動畫瘋 draws its covers at, so the cover-fit has
    # nothing left to crop off the top and bottom.
    assert abs(art['width'] / art['height'] - 227 / 320) < 0.01

    # The image itself still fills that tile edge to edge, give or take the
    # tile's own 1px border.
    image = poster.locator('.agp-art-img').bounding_box()
    assert abs(image['width'] - art['width']) <= 2.5
    assert abs(image['height'] - art['height']) <= 2.5
    assert page.errors == []


def test_catalog_timetable_switches_weekday(page, server):
    open_home(page, server)
    open_tab(page, 'home')
    tabs = page.locator('#homeSchedule .agp-daytab')

    tabs.nth(1).click()
    expect(page.locator('#homeSchedule .agp-slot')).to_have_count(2)
    expect(tabs.nth(1)).to_have_class(re.compile(r'(^| )is-on( |$)'))

    # 週日 has nothing scheduled, which is a thing to say rather than a blank.
    tabs.nth(6).click()
    expect(page.locator('#homeSchedule .agp-empty')).to_contain_text('沒有排定更新')

    # A row 本季新番 does not also list carries no animeSn, so there is no sheet
    # to open and it must not pretend to be a link.
    tabs.nth(0).click()
    expect(page.locator('#homeSchedule .agp-slot')).to_have_count(1)
    assert page.locator('#homeSchedule a.agp-slot').count() == 0
    assert page.errors == []


def test_catalog_pager_walks_the_whole_list(page, server):
    open_home(page, server)
    expect(page.locator('#homeCatalog .agp-pager button[data-page="0"]')).to_be_disabled()

    page.locator('#homeCatalog .agp-pager button[data-page="2"]').click()
    expect(page.locator('#homeCatalog .agp-pager span')).to_have_text('第 2 / 3 頁')

    page.locator('#homeCatalog .agp-pager button[data-page="3"]').click()
    expect(page.locator('#homeCatalog .agp-pager span')).to_have_text('第 3 / 3 頁')
    # 70 titles at 28 a page leaves 14 on the last one, and no way forward.
    expect(page.locator('#homeCatalog .agp-poster')).to_have_count(14)
    expect(page.locator('#homeCatalog .agp-pager button[data-page="4"]')).to_be_disabled()
    assert page.errors == []


def test_catalog_search_reaches_past_the_library(page, server):
    open_home(page, server)

    page.fill('#homeSearch', '所有動畫 1')
    expect(page.locator('#homeCatalog .agp-section-head h2')).to_have_text('搜尋結果')
    # 10 through 19: ten titles, none of them downloaded, which is exactly the
    # reach the 片庫-only search never had.
    expect(page.locator('#homeCatalog .agp-count')).to_have_text('找到 10 部作品')
    expect(page.locator('#homeLibrary .agp-empty')).to_contain_text('找不到')

    page.fill('#homeSearch', 'zzzz-no-such-anime')
    expect(page.locator('#homeCatalog .agp-empty')).to_contain_text('找不到符合')
    assert page.errors == []


def test_searching_does_not_walk_the_page_up_and_down(page, server):
    """An iPad screenshot: one character typed, and 片庫熱門 had jumped to the top
    of the screen. The page used to scroll the results into view -- on a tablet
    that happens as the keyboard shrinks the viewport and the list re-flows with
    every character, so "scroll the results up" landed nowhere anyone asked for.

    Nothing moves the page now. Typing switches to 所有動畫 -- where the answer
    was always going to be -- and a pane switch replaces what is on screen
    without touching the scroll position.
    """
    page.goto(server.url)
    page.wait_for_selector('#homeTimetable .agp-day')
    page.locator('#homeSearch').click()
    assert page.evaluate('() => window.scrollY') == 0

    # A scroll listener, not a before/after reading: the old code scrolled
    # smoothly and could have come back to rest anywhere by the time we looked.
    page.evaluate("""() => {
        window.__scrolls = 0;
        window.__skeletons = 0;
        addEventListener('scroll', () => { window.__scrolls += 1; }, {passive: true});
        // Nor may the grid flash skeletons: the height collapses, everything
        // below jumps, and that reads as the page bouncing too.
        const host = document.getElementById('homeCatalog');
        new MutationObserver(() => {
            if (host.querySelector('.agp-poster-skeleton')) { window.__skeletons += 1; }
        }).observe(host, {childList: true, subtree: true});
    }""")

    for text in ('所', '所有', '所有動', '所有動畫', '所有動畫 1'):
        page.fill('#homeSearch', text)
        page.wait_for_timeout(400)
    page.wait_for_timeout(1200)

    expect(page.locator('#homeCatalog .agp-count')).to_have_text('找到 10 部作品')
    assert page.evaluate('() => window.scrollY') == 0
    assert page.evaluate('() => window.__scrolls') == 0
    assert page.evaluate('() => window.__skeletons') == 0

    # 本季新番 and the timetable are not answers to a search, so the whole 首頁
    # pane steps aside and the bottom bar says where the reader ended up.
    expect(page.locator('#homeSeason')).to_be_hidden()
    expect(page.locator('#homeCatalog')).to_be_visible()
    expect(page.locator('.agp-tabbar-btn[aria-current="page"]')).to_have_text('所有動畫')
    top = page.evaluate(
        "() => document.getElementById('homeCatalog').getBoundingClientRect().top")
    assert 0 < top < page.viewport_size['height'], top

    # And clearing the box puts the reader back on the tab they were on.
    page.fill('#homeSearch', '')
    page.wait_for_timeout(400)
    expect(page.locator('#homeSeason')).to_be_visible()
    expect(page.locator('.agp-tabbar-btn[aria-current="page"]')).to_have_text('首頁')
    assert page.errors == []


def test_the_main_menu_is_five_tabs_and_one_account_button(page, server):
    """主選單太花了 -- nine anchors scrolling around one endless page, plus five
    top-right links with 線上看 written into both rows. 動畫瘋's own app splits
    the same material into five bottom tabs, and that is what this is."""
    open_home(page, server)

    tabs = [tab.inner_text() for tab in page.locator('.agp-tabbar-btn').all()]
    assert tabs == ['首頁', '所有動畫', '收藏', '紀錄', '我的']

    # One pane at a time: the point of the split is that 紀錄 is not at the far
    # end of the片單 anymore.
    open_tab(page, 'history')
    open_panes = [pane.get_attribute('data-pane')
                  for pane in page.locator('.agp-pane').all() if pane.is_visible()]
    assert open_panes == ['history']

    # 主控台 / 用戶管理 / 帳號資訊 / 登出 are account plumbing nobody opens twice a
    # day; on the bar they were four buttons that wrapped to a second row.
    nav = page.locator('.agp-usernav')
    expect(nav.locator('> li')).to_have_count(2)
    expect(nav.locator('.agp-navmenu-name')).to_have_text('tester')
    expect(nav.locator('.agp-navmenu-panel')).to_be_hidden()

    nav.locator('.agp-navmenu-toggle').click()
    expect(nav.locator('.agp-navmenu-panel')).to_be_visible()
    assert nav.locator('.agp-navmenu-panel a').all_inner_texts() == [
        '主控台', '用戶管理', '帳號資訊', '登出']

    # Clicking away closes it. A popover that stays open sits on top of the page
    # and there is nothing on screen that says how to get rid of it.
    page.locator('#homeSearch').click()
    expect(nav.locator('.agp-navmenu-panel')).to_be_hidden()

    # The watch page's own tab row already carries 線上看, and it is the selected
    # one; a second copy in the corner is the same link written twice.
    page.goto('%s/watch' % server.url)
    page.wait_for_selector('.agp-usernav .agp-navmenu')
    assert '線上看' not in page.locator('.agp-usernav').inner_text()
    expect(page.locator('.agp-tabs .agp-tab.is-active')).to_have_text('線上看')
    assert page.errors == []


def test_catalog_sheet_opens_closes_and_survives_a_shared_link(page, server):
    open_home(page, server)
    page.locator('#homeCatalog .agp-poster').first.click()
    page.wait_for_selector('#catalogSheet .agp-epgroup')

    sheet = page.locator('#catalogSheet')
    expect(sheet.locator('h3')).to_have_text(CATALOG_ALL[0]['title'])
    expect(sheet.locator('.agp-chip').first).to_contain_text('4.8')
    expect(sheet.locator('.agp-epgroup h4').first).to_contain_text('本篇')
    # Opening a title is a place, not a mode: the hash is what makes Back, the
    # iOS swipe-back gesture and a pasted link all land on the same sheet.
    assert page.evaluate('() => location.hash') == '#anime-%s' % CATALOG_LOCAL_SN

    page.keyboard.press('Escape')
    page.wait_for_selector('#catalogSheet', state='hidden')
    assert page.evaluate('() => location.hash') == ''

    # And the same sheet reached cold, from the link rather than from a card.
    sheet = open_sheet(page, server, CATALOG_ALL[3]['animeSn'])
    expect(sheet.locator('h3')).to_have_text(CATALOG_ALL[3]['title'])
    assert page.errors == []


def test_catalog_sheet_clamps_a_long_synopsis(page, server):
    sheet = open_sheet(page, server, CATALOG_ALL[3]['animeSn'])

    clamped = sheet.locator('.agp-sheet-text.is-clamped')
    expect(clamped).to_be_visible()
    shut = clamped.evaluate('(el) => el.getBoundingClientRect().height')

    sheet.locator('.agp-synopsis-more').click()
    expect(sheet.locator('.agp-sheet-text.is-clamped')).to_have_count(0)
    assert sheet.locator('.agp-sheet-text').evaluate(
        '(el) => el.getBoundingClientRect().height') > shut
    assert page.errors == []


def test_catalog_sheet_plays_what_is_local_and_queues_what_is_not(page, server):
    sheet = open_sheet(page, server, CATALOG_LOCAL_SN)

    # One episode is on disk, so this title plays right now -- and the episode
    # grid says which one without making anybody hunt for it.
    expect(sheet.locator('.agp-sheet-actions a[href*="watch?id="]')).to_contain_text('立即觀看')
    expect(sheet.locator('.agp-ep.is-local')).to_have_count(1)
    expect(sheet.locator('.agp-ep.is-local')).to_have_text(re.compile(r'\b2\b'))
    assert sheet.locator('.agp-sheet-hint').count() == 0
    # Episode 2 being on disk says nothing about episode 1, which is what the
    # sheet landed on and what the button would stream -- so it stays offered.
    expect(sheet.locator('button[data-stream]')).to_have_attribute(
        'data-stream', CATALOG_ALL[0]['videoSn'])

    # When the landing episode itself is the downloaded one, streaming it would
    # only mean fetching a second copy of a file that is already here.
    on_disk = open_sheet(page, server, CATALOG_LANDING_LOCAL_SN)
    expect(on_disk.locator('.agp-ep.is-local')).to_have_text(re.compile(r'\b1\b'))
    assert on_disk.locator('button[data-stream]').count() == 0

    # Nothing on disk is no longer a dead end: the download can be watched
    # while it runs, and 動畫瘋 itself stays as the way out.
    remote = open_sheet(page, server, CATALOG_ALL[3]['animeSn'])
    expect(remote.locator('.agp-sheet-hint')).to_contain_text('還沒有下載到片庫')
    expect(remote.locator('button[data-stream]')).to_contain_text('邊看邊下載')
    expect(remote.locator('a[href^="https://ani.gamer.com.tw/animeVideo.php"]')).to_be_visible()
    assert remote.locator('.agp-ep.is-local').count() == 0
    assert page.errors == []


def test_catalog_sheet_shows_the_rest_of_a_long_series_on_request(page, server):
    sheet = open_sheet(page, server, CATALOG_ALL[3]['animeSn'])
    group = sheet.locator('.agp-epgroup').first

    # 130 episodes are not painted up front; 名偵探柯南 ships 986 of them.
    expect(group.locator('.agp-ep')).to_have_count(120)
    expect(group.locator('.agp-epmore')).to_contain_text('顯示其餘 10 集')

    group.locator('.agp-epmore').click()
    expect(sheet.locator('.agp-epgroup').first.locator('.agp-ep')).to_have_count(130)
    assert page.errors == []


def test_catalog_queues_a_download_with_everything_the_server_needs(page, server):
    del MANUAL_TASKS[:]
    sheet = open_sheet(page, server, CATALOG_ALL[3]['animeSn'])

    sheet.locator('.agp-select').select_option('720')
    sheet.locator('button[data-download]').click()
    expect(page.locator('#agpToast.is-on')).to_contain_text('已加入下載佇列')

    # /manualTask reads all six keys straight out of the body and KeyErrors on
    # any one that is missing, so the payload shape is the contract.
    assert len(MANUAL_TASKS) == 1
    whole = MANUAL_TASKS[0]
    assert sorted(whole) == ['classify', 'danmu', 'mode', 'resolution', 'sn', 'thread']
    assert whole['sn'] == CATALOG_ALL[3]['videoSn']
    assert whole['resolution'] == '720'
    assert whole['mode'] == 'all'

    # Tapping one episode queues that episode alone -- and then becomes the way
    # in to watch it, because the moment it is queued there is something to play.
    # Episode 1 carries the series' own sn, so the 整部下載 above already turned
    # it into a link; the first episode still rendered as a button is the one
    # nobody has queued yet.
    episode = sheet.locator('.agp-ep[data-episode]').first
    tapped = episode.get_attribute('data-episode')
    episode.click()
    expect(sheet.locator('.agp-ep.is-queued[href*="id=%s"]' % tapped)).to_have_attribute(
        'href', re.compile(r'watch\?id=\d+&streaming=1'))
    assert len(MANUAL_TASKS) == 2
    assert MANUAL_TASKS[1]['mode'] == 'single'
    # The episode that was tapped, not merely "some episode": queueing the wrong
    # one still leaves a task in the list and still lights up a chip.
    assert MANUAL_TASKS[1]['sn'] == tapped
    assert page.errors == []


def test_catalog_sheet_is_a_bottom_sheet_on_a_phone(phone, server):
    sheet = open_sheet(phone, server, CATALOG_LOCAL_SN)

    box = sheet.locator('.agp-sheet-panel').bounding_box()
    assert box['x'] == 0
    assert box['width'] == IPHONE_VIEWPORT['width']
    # Pinned to the bottom edge rather than floating in the middle: a centred
    # box with catalogue showing above and below reads as a stray dialog.
    assert abs(box['y'] + box['height'] - IPHONE_VIEWPORT['height']) < 2

    # And the catalogue behind it must not drag away under the reader's thumb.
    assert phone.evaluate("() => getComputedStyle(document.body).overflow") == 'hidden'
    assert phone.errors == []


def test_home_falls_back_to_the_library_without_the_catalogue(page, server_without_catalog):
    """``online_watch`` off means the /catalog/* routes do not exist at all, and
    the page has to go back to being the 片庫 view it was rather than to a wall
    of empty sections."""
    page.goto(server_without_catalog.url)
    # The body class is the page saying it handled the failed fetch; asserting
    # on empty hosts alone would pass before the request had even gone out.
    page.wait_for_selector('body.agp-no-catalog')
    open_tab(page, 'all')
    page.wait_for_selector('#homeLibrary .agp-poster')

    for host in ['homeSeason', 'homeSchedule', 'homeCatalogHot', 'homeCatalogNew',
                 'homeCatalog']:
        assert page.locator('#%s .agp-section' % host).count() == 0

    # 所有動畫 is still a place worth going: without the catalogue it is the 片庫
    # on its own rather than an empty page.
    expect(page.locator('#homeLibrary .agp-section-head h2')).to_have_text('片庫')
    assert [tab.inner_text() for tab in page.locator('.agp-tabbar-btn').all()] == [
        '首頁', '所有動畫', '收藏', '紀錄', '我的']
    assert page.errors == []


# ------------------------------------------------------------ 收藏 / 紀錄 / 我的

def test_favourites_tab_lists_what_the_watch_page_starred(page, server):
    """收藏 used to be a per-anime boolean under a hashed key: the button lit up
    and nothing anywhere could list what had been starred, because a hash does
    not turn back into a title."""
    page.goto(server.url)
    open_tab(page, 'fav')
    expect(page.locator('#homeFavourites .agp-empty')).to_contain_text('還沒有收藏')

    goto_watch(page, server)
    name = page.locator('#watchTitleBar h1').inner_text().split('\n')[0]
    page.locator('#favButton').click()
    expect(page.locator('#favButton')).to_contain_text('已收藏')

    page.goto(server.url)
    open_tab(page, 'fav')
    poster = page.locator('#homeFavourites .agp-poster').first
    expect(poster.locator('.agp-poster-foot strong')).to_have_text(name)
    expect(page.locator('#homeFavourites .agp-count')).to_have_text('共 1 部作品')

    # And the X on the cover is the whole point of having a list: taking a
    # title back off it without opening it first.
    page.locator('#homeFavourites [data-unfav]').first.click()
    expect(page.locator('#homeFavourites .agp-empty')).to_contain_text('還沒有收藏')
    assert page.errors == []


def test_history_tab_lists_watch_positions_newest_first(page, server):
    page.goto(server.url)
    open_tab(page, 'history')
    rows = page.locator('.agp-history-row')
    expect(rows).to_have_count(len(WATCH_TIMES))

    # The month header is what makes a long list readable, and 動畫瘋 writes the
    # day and the episode on the row itself.
    expect(page.locator('.agp-history-month').first).to_contain_text('年')
    expect(rows.first.locator('.agp-history-body small')).to_contain_text('觀看至 第')
    # Newest first: WATCH_TIMES' first entry is 10 minutes old, the second over
    # an hour.
    newest = VIDEO_LIST['videos'][1]
    expect(rows.first.locator('.agp-history-body strong')).to_have_text(newest['anime_name'])

    bar = rows.first.locator('.agp-history-bar i')
    assert 25 < float(bar.evaluate('(el) => el.style.width').rstrip('%')) < 34
    assert page.errors == []


def test_history_row_deletes_itself_on_the_server(page, server):
    page.goto(server.url)
    open_tab(page, 'history')
    before = page.locator('.agp-history-row').count()

    page.locator('.agp-history-row [data-drop]').first.click()
    expect(page.locator('.agp-history-row')).to_have_count(before - 1)

    # A row that comes back on reload was only ever hidden.
    page.reload()
    open_tab(page, 'history')
    expect(page.locator('.agp-history-row')).to_have_count(before - 1)
    assert page.errors == []


def test_mine_tab_carries_the_account_links(page, server):
    """The account menu is a hover-and-click popover in the top corner; on a
    phone the whole top bar is gone and those links have to live somewhere."""
    page.goto(server.url)
    open_tab(page, 'mine')

    expect(page.locator('.agp-account-card strong')).to_have_text('tester')
    expect(page.locator('.agp-account-card small')).to_contain_text('片庫')
    assert [row.inner_text() for row in page.locator('.agp-account-row').all()] == [
        '線上看', '主控台', '用戶管理', '帳號資訊', '登出']
    assert page.errors == []


# -------------------------------------------------------------------- player

def test_online_watch_without_an_episode_lists_the_library(page, server):
    # 線上看 used to redirect straight into whatever finished downloading last.
    # A guess, and a bad one: get it wrong and the whole tab is one sentence
    # saying the episode cannot be found.
    page.goto(server.url + '/watch')
    page.wait_for_selector('#watchLibrary .watch-index-grid')

    assert page.url.rstrip('/').endswith('/watch'), page.url
    assert 'is-index' in page.locator('.watch-page').get_attribute('class').split()
    # Nothing was asked for, so the player, the episode list and the danmaku
    # column have nothing to show.
    expect(page.locator('.watch-grid')).to_be_hidden()

    # One card per title, not per episode: a library of five shows would
    # otherwise be fourteen cards of the same four covers.
    titles = set(video['anime_name'] for video in VIDEO_LIST['videos'])
    cards = page.locator('#watchLibrary .watch-index-grid > .agp-card')
    expect(cards).to_have_count(len(titles))
    expect(page.locator('#watchLibrary .watch-index-count')).to_have_text(
        '共 %d 部作品' % len(titles))
    assert set(cards.locator('.agp-card-title').all_inner_texts()) == titles

    # And it is an index, so a card is the way in.
    cards.first.click()
    page.wait_for_selector('#playerShell video')
    assert 'id=' in page.url
    assert page.errors == []


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


def test_the_episode_list_is_the_whole_series_not_the_downloads(page, server):
    """選集 said 共 1 集 for an episode opened with 邊看邊下載: the library was the
    only thing it knew about, and the library held exactly that one episode.

    The series is what 動畫瘋 says it is. What is on disk only decides what a
    chip does when it is tapped."""
    goto_watch(page, server)

    expect(page.locator('#episodeGrid .watch-episodes-head span')).to_have_text(
        '共 %d 集' % WATCH_SERIES_TOTAL)
    expect(page.locator('#episodeGrid .watch-episode-btn')).to_have_count(WATCH_SERIES_TOTAL)
    expect(page.locator('#watchTitleBar')).to_contain_text('共 %d 集' % WATCH_SERIES_TOTAL)

    # 動畫瘋 files dubs under their own tab. Run the groups together and the
    # numbering restarts halfway down the strip with nothing to explain it.
    expect(page.locator('#episodeGrid .watch-episodes-group')).to_have_text(['本篇', '中文配音'])

    local = [v for v in VIDEO_LIST['videos'] if v['anime_name'] == FIRST_ANIME]
    # On disk: a link. Not on disk: a button, because tapping it has to queue the
    # download first -- there is nothing at that address to play yet.
    expect(page.locator('#episodeGrid a.watch-episode-btn')).to_have_count(len(local))
    expect(page.locator('#episodeGrid button.watch-episode-btn')).to_have_count(
        WATCH_SERIES_TOTAL - len(local))
    assert page.errors == []


def test_tapping_an_episode_that_is_not_on_disk_starts_it_downloading(page, server):
    del MANUAL_TASKS[:]
    goto_watch(page, server)

    chip = page.locator('#episodeGrid button[data-stream]').first
    wanted = chip.get_attribute('data-stream')
    chip.click()

    # /watch?id=X&streaming=1 queues nothing -- it means "I just pressed
    # download, wait for the task to register". Navigating without the POST is
    # how you get a player that waits forever for a task nobody created.
    page.wait_for_url(re.compile(r'/watch\?id=%s&streaming=1' % wanted))
    assert len(MANUAL_TASKS) == 1
    task = MANUAL_TASKS[0]
    # /manualTask reads all six keys out of the body and KeyErrors on any that
    # is missing, so the payload shape is the contract.
    assert sorted(task) == ['classify', 'danmu', 'mode', 'resolution', 'sn', 'thread']
    assert task['sn'] == wanted
    assert task['mode'] == 'single'


def test_the_info_card_shows_the_real_synopsis_and_cover(page, server):
    """作品資訊 wrote its own blurb, and what it wrote was about this website --
    「由 aniGamerPlus+ 直接從本機片庫串流播放」 -- rather than about the anime."""
    goto_watch(page, server)

    desc = page.locator('#animeInfo .watch-info-desc')
    expect(desc).to_contain_text(WATCH_SYNOPSIS[:20])
    assert 'aniGamerPlus+' not in desc.inner_text()

    # The cover is the series' own portrait art. /thumbnail.jpg is a frame
    # ffmpeg pulled out of the episode, and it looks like exactly that: a
    # screenshot of whatever was on screen a few seconds in.
    expect(page.locator('#animeInfo .watch-info-cover img')).to_have_attribute(
        'src', re.compile(r'^/cover\.jpg'))
    assert page.locator('#animeInfo .watch-info-cover img[src*="thumbnail.jpg"]').count() == 0

    expect(page.locator('#animeInfo .watch-tag').first).to_have_text('奇幻')
    expect(page.locator('#animeInfo .watch-info-meta')).to_contain_text('測試導演')
    assert page.errors == []


def test_a_long_synopsis_is_folded_away_behind_one_line(page, server):
    """巴哈 tacks the whole staff credit list onto the end of 作品介紹 --
    原作/導演/角色設計/音響監督/OP主題曲, dozens of names. Printed whole it
    buries the library rail below the fold of a tablet screen."""
    goto_watch(page, server)

    desc = page.locator('#animeInfo .watch-info-desc')
    more = page.locator('#animeInfo .watch-info-more')
    expect(more).to_be_visible()
    expect(more).to_have_text('展開')
    folded = desc.bounding_box()['height']
    assert desc.evaluate('el => el.scrollHeight') > folded + 2, 'nothing was folded away'

    more.click()
    expect(more).to_have_text('收合')
    opened = desc.bounding_box()['height']
    assert opened > folded, (opened, folded)
    # Everything is there once it is open -- folding hides text, it must not
    # truncate it, or the last line reads as a sentence that stops mid-word.
    assert desc.evaluate('el => el.scrollHeight') <= opened + 2

    more.click()
    expect(more).to_have_text('展開')
    assert abs(desc.bounding_box()['height'] - folded) < 2
    assert page.errors == []


def test_a_short_synopsis_gets_no_toggle(page, server):
    """A title 巴哈 has nothing on falls back to a two-sentence blurb. Hanging a
    展開 under it that opens onto nothing is worse than no toggle."""
    goto_watch(page, server, VIDEO_LIST['videos'][-1]['sn'])

    expect(page.locator('#animeInfo .watch-info-desc')).to_be_visible()
    expect(page.locator('#animeInfo .watch-info-more')).to_be_hidden()
    assert page.locator('#animeInfo .watch-info-desc.is-clamped').count() == 0
    assert page.errors == []


def test_a_title_bahamut_never_heard_of_still_renders(page, server):
    """The library is allowed to hold files that did not come from 動畫瘋.
    /watch/series.json 404s for those, and the page falls back to the library."""
    goto_watch(page, server, VIDEO_LIST['videos'][-1]['sn'])

    expect(page.locator('#animeInfo h2')).to_have_text(NO_SERIES_INFO_ANIME)
    local = [v for v in VIDEO_LIST['videos'] if v['anime_name'] == NO_SERIES_INFO_ANIME]
    expect(page.locator('#episodeGrid .watch-episodes-head span')).to_have_text(
        '共 %d 集' % len(local))
    # Nothing to offer a download of: everything this page knows about is here.
    assert page.locator('#episodeGrid button[data-stream]').count() == 0
    assert page.errors == []


def test_episode_grid_and_menu_navigate(page, server):
    goto_watch(page, server)

    grid = page.locator('#episodeGrid .watch-episode-grid').first
    expect(grid).to_be_visible()
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


def test_fullscreen_prefers_the_real_thing(page, server):
    goto_watch(page, server)

    page.click('#fullscreenToggle')
    assert page.evaluate("() => !!document.fullscreenElement") is True
    expect(page.locator('#playerShell')).to_have_class(re.compile(r'(^| )is-fullscreen( |$)'))
    # The real API is in charge here; the stand-in must stay out of the way.
    assert page.evaluate(
        "() => document.body.classList.contains('player-pseudo-fullscreen')") is False

    page.click('#fullscreenToggle')
    assert page.evaluate("() => !!document.fullscreenElement") is False
    assert page.errors == []


def test_fullscreen_falls_back_without_handing_over_the_player(phone, server):
    """iPhone Safari has no element fullscreen, only ``webkitEnterFullscreen``
    on the video -- which swaps this player for Apple's own and takes the
    danmaku layer, the episode picker and every gesture with it. The fallback
    has to fill the viewport itself instead."""
    phone.add_init_script("""
        Object.defineProperty(Element.prototype, 'requestFullscreen', {value: undefined});
        Object.defineProperty(Element.prototype, 'webkitRequestFullscreen', {value: undefined});
        window.__nativeFullscreenAsked = false;
        Object.defineProperty(HTMLVideoElement.prototype, 'webkitEnterFullscreen', {
            configurable: true,
            value: function () { window.__nativeFullscreenAsked = true; },
        });
    """)
    goto_watch(phone, server)

    phone.click('#fullscreenToggle')
    shell = phone.locator('#playerShell')
    expect(shell).to_have_class(re.compile(r'(^| )is-pseudo-fullscreen( |$)'))
    # .is-fullscreen rides along, so the safe-area padding and the button icon
    # behave exactly as they do in the real thing.
    expect(shell).to_have_class(re.compile(r'(^| )is-fullscreen( |$)'))
    expect(phone.locator('#fullscreenToggle')).to_have_attribute('aria-pressed', 'true')

    assert phone.evaluate("() => window.__nativeFullscreenAsked") is False
    # The custom chrome is still on screen, which is the whole point.
    expect(phone.locator('#playerShell .desktop-player-controls')).to_be_attached()

    box = shell.bounding_box()
    assert box['x'] == 0 and box['y'] == 0
    assert box['width'] == IPHONE_VIEWPORT['width']
    assert box['height'] == IPHONE_VIEWPORT['height']
    assert phone.evaluate("() => getComputedStyle(document.body).overflow") == 'hidden'

    phone.click('#fullscreenToggle')
    expect(shell).not_to_have_class(re.compile(r'(^| )is-pseudo-fullscreen( |$)'))
    assert phone.evaluate("() => getComputedStyle(document.body).overflow") != 'hidden'
    assert phone.errors == []


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


# ------------------------------------------------------------- 邊看邊下載

# The fixture stream is built by ffmpeg on first run. Without it there is no
# transport stream a browser would decode, and faking one proves nothing -- so
# these skip rather than fail, exactly as a machine that cannot run the
# downloader in the first place deserves.
needs_stream = pytest.mark.skipif(
    not HLS_DURATIONS,
    reason='needs ffmpeg and pycryptodome to build the HLS fixture')


@pytest.fixture
def downloading():
    """Two chunks landed out of six, and put back that way afterwards."""
    HLS_STATE.update(HLS_STATE_DEFAULT)
    yield HLS_STATE
    HLS_STATE.update(HLS_STATE_DEFAULT)


def goto_stream(page, server, query='&streaming=1'):
    page.goto('%s/watch?id=%s%s' % (server.url, HLS_SN, query))
    page.wait_for_selector('#playerShell.is-custom-player')
    # readyState 2 means a frame has been decoded, which for this stream means
    # the key was fetched, the segments were decrypted and hls.js transmuxed
    # them. Nothing short of that proves the pipeline end to end.
    page.wait_for_function(
        "() => document.querySelector('#playerShell video')?.readyState >= 2",
        timeout=30000)
    return page


def stream_video(page, expression):
    return page.evaluate(
        "() => { const v = document.querySelector('#playerShell video'); return %s; }"
        % expression)


@needs_stream
def test_a_downloading_episode_gets_a_player_instead_of_an_error(page, server, downloading):
    requested = []
    page.on('request', lambda request: requested.append(request.url))
    goto_stream(page, server)

    # This sn is in no video_list.json anywhere; without the bootstrap entry the
    # page would be a 「找不到這一集影片」 dead end.
    expect(page.locator('#episodeChipLabel')).to_contain_text(HLS_ANIME)
    expect(page.locator('#playerDownloading')).to_be_visible()
    expect(page.locator('#playerDownloading')).to_contain_text('邊看邊下載')
    expect(page.locator('#playerDownloading')).to_contain_text('1080P')

    # Decryption is not optional on 動畫瘋, so a build of hls.js without AES-128
    # would leave a black picture and no error worth reading.
    assert any('/hls/key.bin' in url for url in requested)
    assert any('/hls/segment.ts' in url for url in requested)
    assert not any('/get_video.mp4' in url for url in requested)
    assert page.errors == []


@needs_stream
def test_a_downloading_episode_really_decodes_and_plays(page, server, downloading):
    goto_stream(page, server)

    # Muted, because an unmuted autoplay is what a headless browser refuses --
    # not anything the player did.
    page.evaluate("""() => {
        const v = document.querySelector('#playerShell video');
        v.muted = true;
        return v.play();
    }""")
    page.wait_for_function(
        "() => document.querySelector('#playerShell video').currentTime > 0.6",
        timeout=20000)

    expect(page.locator('#timeCurrent')).not_to_have_text('0:00')
    assert stream_video(page, 'v.videoWidth') == 320
    assert page.errors == []


@needs_stream
def test_the_clock_reads_the_whole_episode_not_the_downloaded_part(page, server, downloading):
    goto_stream(page, server)

    # video.duration only reaches as far as the chunks that have landed and
    # jumps right every few seconds. Reading the total off the playlist instead
    # is what stops the progress bar's right-hand end from crawling.
    expect(page.locator('#timeTotal')).to_have_text('0:12')
    assert stream_video(page, 'v.duration') < 11
    assert page.errors == []


@needs_stream
def test_seeking_stops_at_what_has_landed(page, server, downloading):
    goto_stream(page, server)

    page.locator('#playerSeek').evaluate(
        "(el) => { el.value = el.max;"
        " el.dispatchEvent(new Event('change', {bubbles: true})); }")
    page.wait_for_timeout(400)

    # Four of twelve seconds are on disk. Dragging to the end of a bar that
    # spans the whole episode must not land somewhere unplayable.
    assert stream_video(page, 'v.currentTime') <= 4.0
    assert page.errors == []


@needs_stream
def test_the_stream_grows_as_more_chunks_land(page, server, downloading):
    goto_stream(page, server)
    expect(page.locator('#playerDownloading')).to_contain_text('33%')

    downloading.update({'ready': HLS_SEGMENTS, 'mode': 'finalising'})

    # ffmpeg is merging, the temp directory is still there, and the playlist now
    # carries #EXT-X-ENDLIST -- so the player should reach the real end.
    expect(page.locator('#playerDownloading')).to_contain_text('正在合併', timeout=20000)
    page.wait_for_function(
        "() => document.querySelector('#playerShell video').duration > 11",
        timeout=20000)
    assert page.errors == []


@needs_stream
def test_the_player_hands_over_to_the_finished_file(page, server, downloading):
    goto_stream(page, server)
    page.evaluate("""() => {
        const v = document.querySelector('#playerShell video');
        v.muted = true;
        return v.play();
    }""")
    page.wait_for_function(
        "() => document.querySelector('#playerShell video').currentTime > 0.6",
        timeout=20000)

    downloading.update({'ready': HLS_SEGMENTS, 'mode': 'file'})

    # Merged and in the library: the episode is a file now, and the swap keeps
    # the position so nobody notices the source changed underneath them.
    page.wait_for_function(
        "() => (document.querySelector('#playerShell video').currentSrc || '')"
        ".includes('get_video.mp4')", timeout=20000)
    expect(page.locator('#playerDownloading')).to_be_hidden()
    assert page.errors == []


@needs_stream
def test_a_just_queued_episode_waits_for_the_task_to_register(page, server, downloading):
    # /manualTask answers before the download thread has created its progress
    # entry, so for a second or two the server has nothing to report but "no
    # such download". streaming=1 is the note the catalog leaves behind saying
    # "I just queued this", and the page has to sit through the gap rather than
    # believe the first answer it gets.
    downloading.update({'ready': 0, 'mode': 'pending'})
    page.goto('%s/watch?id=%s&streaming=1' % (server.url, HLS_SN))
    page.wait_for_selector('#playerShell.is-custom-player')
    expect(page.locator('#playerDownloading')).to_contain_text('正在準備下載')

    # Two polls later it is still waiting, not claiming the download stopped.
    page.wait_for_timeout(6000)
    expect(page.locator('#playerDownloading')).to_contain_text('正在準備下載')

    downloading.update({'ready': 2, 'mode': 'streaming'})
    page.wait_for_function(
        "() => document.querySelector('#playerShell video')?.readyState >= 2",
        timeout=30000)
    expect(page.locator('#playerDownloading')).to_contain_text('邊看邊下載')
    assert page.errors == []


@needs_stream
def test_a_link_opened_mid_download_finds_its_own_way_in(page, server, downloading):
    # Opening /watch for an episode whose task registered a moment after the
    # page was rendered: the bootstrap had nothing, but the stream is live. The
    # page reloads itself with streaming=1 rather than showing a dead end --
    # the title and episode number are only knowable server-side.
    downloading.update({'ready': 2, 'mode': 'streaming', 'bootstrap': False})
    page.goto('%s/watch?id=%s' % (server.url, HLS_SN))

    page.wait_for_url(lambda url: 'streaming=1' in url, timeout=15000)
    page.wait_for_selector('#playerShell.is-custom-player')
    expect(page.locator('#episodeChipLabel')).to_contain_text(HLS_ANIME)
    assert page.errors == []


@needs_stream
def test_a_streaming_episode_still_lists_the_whole_series(page, server, downloading):
    """The screenshot that started this: 邊看邊下載 was running and 選集 said
    共 1 集, because the episode being downloaded was the only one in the
    library. It is episode 1 of a 130-episode series."""
    goto_stream(page, server)

    total = sum(len(group['episodes']) for group in WATCH_SERIES_STREAMING['groups'])
    expect(page.locator('#episodeGrid .watch-episodes-head span')).to_have_text(
        '共 %d 集' % total)
    expect(page.locator('#episodeGrid .watch-episode-btn.is-current')).to_have_text('1')
    # And the rest of the series is right there to carry on with.
    assert page.locator('#episodeGrid button[data-stream]').count() > 100

    # Nothing on disk yet, so the library has no episode number to offer and the
    # header read 「單集」 over a title with the episode bracketed into it. Both
    # come off the official table instead.
    bar = page.locator('#watchTitleBar')
    expect(bar.locator('h1')).to_have_text(re.compile(r'^%s' % re.escape(HLS_ANIME)))
    expect(bar).to_contain_text('第 1 集')
    assert '單集' not in bar.inner_text()
    assert page.errors == []


@needs_stream
def test_the_catalog_starts_a_download_and_goes_straight_to_the_player(page, server, downloading):
    del MANUAL_TASKS[:]
    sheet = open_sheet(page, server, CATALOG_SEASON[0]['animeSn'])

    expect(sheet.locator('button[data-stream]')).to_contain_text('邊看邊下載')
    expect(sheet.locator('.agp-sheet-hint')).to_contain_text('在背景繼續下載')
    sheet.locator('button[data-stream]').click()

    page.wait_for_url(lambda url: 'streaming=1' in url, timeout=15000)
    page.wait_for_selector('#playerShell.is-custom-player')

    # One episode queued, not the whole series: nobody asked for 130 downloads
    # by pressing play.
    assert len(MANUAL_TASKS) == 1
    assert MANUAL_TASKS[0]['sn'] == HLS_SN
    assert MANUAL_TASKS[0]['mode'] == 'single'
    assert page.errors == []


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
