"""Screenshot the live dashboard so the redesign can be looked at, not guessed at.

Points a desktop and an iPad viewport at a running ``aniGamerPlus.py`` and drops
PNGs in ``tests/_shots``. Not a test -- there is nothing to assert about "does
this look right" -- so it is run by hand::

    python tests/shoot.py [http://127.0.0.1:5000]
"""

import os
import sys

from playwright.sync_api import sync_playwright

BASE_URL = (sys.argv[1] if len(sys.argv) > 1 else
            os.environ.get('AGP_SERVER', 'http://127.0.0.1:5000'))
DASH_USER = os.environ.get('AGP_DASH_USER', 'admin')
DASH_PASS = os.environ.get('AGP_DASH_PASS', 'admin')
SN = os.environ.get('AGP_SN', '48502')
SHOTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_shots')

IPAD_UA = ('Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
           '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1')

IPHONE_UA = ('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
             '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1')

DEVICES = [
    ('desktop', {'viewport': {'width': 1440, 'height': 900}}),
    ('ipad', {'viewport': {'width': 1024, 'height': 768}, 'user_agent': IPAD_UA,
              'is_mobile': True, 'has_touch': True, 'device_scale_factor': 2}),
    # The narrow player sheds content rather than piling it up; that only shows
    # below 560px, so a phone has to be in the set.
    ('iphone', {'viewport': {'width': 390, 'height': 844}, 'user_agent': IPHONE_UA,
                'is_mobile': True, 'has_touch': True, 'device_scale_factor': 3}),
]


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


def sign_in(page):
    page.goto(BASE_URL + '/login')
    if page.locator('#username').count():
        page.fill('#username', DASH_USER)
        page.fill('#password', DASH_PASS)
        page.click('button[type="submit"]')
        # Not networkidle: the dashboard holds a websocket open, so the network
        # never goes quiet and waiting for that just burns the timeout.
        page.wait_for_url(lambda url: '/login' not in url, timeout=30000)
        page.wait_for_load_state('domcontentloaded')


def shoot(page, name, full_page=False):
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, name + '.png')
    page.screenshot(path=path, full_page=full_page)
    print('wrote', path)


def main():
    with sync_playwright() as p:
        browser = launch_chromium(p, headless=os.environ.get('AGP_HEADLESS') == '1')
        for label, options in DEVICES:
            context = browser.new_context(locale='zh-TW', **options)
            page = context.new_page()
            sign_in(page)

            page.goto(BASE_URL + '/')
            page.wait_for_selector('#homeTimetable .agp-day', timeout=30000)
            # The cards only look finished once their thumbnails have arrived.
            page.wait_for_function(
                """() => {
                    const imgs = [...document.querySelectorAll('.agp-art-img')];
                    return imgs.length > 0 && imgs.every((i) => i.complete);
                }""", timeout=30000)
            shoot(page, 'home-' + label)
            shoot(page, 'home-' + label + '-full', full_page=True)

            # 片庫搬到「所有動畫」那一頁了, 它自己也值得一張
            page.locator('.agp-tabbar-btn[data-pane="all"]').click()
            page.wait_for_selector('#homeLibrary .agp-poster', timeout=30000)
            shoot(page, 'all-' + label)

            page.goto('%s/watch?id=%s' % (BASE_URL, SN))
            page.wait_for_selector('#playerShell.is-custom-player', timeout=30000)
            # Park on a frame well past the OP so every run frames the same
            # picture, and pause so the danmaku stops moving under the shutter.
            page.wait_for_function(
                "() => document.querySelector('#playerShell video')?.readyState >= 2",
                timeout=60000)
            page.evaluate("""() => {
                const v = document.querySelector('#playerShell video');
                v.pause();
                v.currentTime = 300;
            }""")
            page.wait_for_function(
                "() => document.querySelector('#playerShell video').readyState >= 2",
                timeout=30000)
            page.wait_for_timeout(2500)          # let danmaku and the grid land

            # With the chrome up, which is what the complaint is about.
            page.evaluate("() => document.querySelector('#playerShell')"
                          ".classList.add('controls-visible')")
            page.wait_for_timeout(400)
            shoot(page, 'watch-' + label + '-controls')
            shoot(page, 'watch-' + label + '-full', full_page=True)

            # And the way it looks while you are actually watching it.
            page.evaluate("() => document.querySelector('#playerShell')"
                          ".classList.remove('controls-visible')")
            page.wait_for_timeout(400)
            shoot(page, 'watch-' + label)

            context.close()
        browser.close()


if __name__ == '__main__':
    main()
