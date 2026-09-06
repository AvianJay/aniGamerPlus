"""Playwright plumbing shared by every suite in this directory.

Each module used to open its own ``sync_playwright()`` in a session-scoped
fixture. Two of those alive in one process is what raises "Playwright Sync API
inside the asyncio loop", so ``python -m pytest tests/`` blew up even though
either module passed on its own. One driver, opened here, is handed to both.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

playwright_api = pytest.importorskip('playwright.sync_api')


@pytest.fixture(scope='session')
def playwright_driver():
    """The one and only sync-API driver for the whole run."""
    with playwright_api.sync_playwright() as driver:
        yield driver


@pytest.fixture(scope='session')
def chromium_launcher(playwright_driver):
    """Launch a browser that can actually decode the library.

    Playwright's bundled Chromium ships without the proprietary codecs, so a
    real 1080p H.264/AAC episode never fires ``loadedmetadata`` in it -- the
    picture stays black and ``duration`` reads 0. Installed Chrome and Edge do
    carry them, so prefer those and fall back to the bundle (fine for the
    WebM fixtures, useless for the real files).
    """
    def launch(**kwargs):
        for channel in ('chrome', 'msedge'):
            try:
                return playwright_driver.chromium.launch(channel=channel, **kwargs)
            except Exception:
                continue
        return playwright_driver.chromium.launch(**kwargs)
    return launch
