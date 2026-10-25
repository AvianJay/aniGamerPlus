"""CAPTCHA regressions with synthetic drivers and no runtime configuration.

Run with ``python -m pytest tests/test_loginer_captcha.py --noconftest -q``.
"""

import importlib.util
from pathlib import Path
import sys
import types

import pytest
from selenium.common.exceptions import NoSuchElementException, TimeoutException


@pytest.fixture
def loginer(monkeypatch, tmp_path):
    config = types.ModuleType('Config')
    solver = types.ModuleType('selenium_recaptcha_solver')
    solver.RecaptchaSolver = object
    solver.StandardDelayConfig = object
    source = Path(__file__).resolve().parents[1] / 'Loginer.py'
    spec = importlib.util.spec_from_file_location('_loginer_captcha_regression', source)
    module = importlib.util.module_from_spec(spec)
    # Restore sys.modules immediately after loading so other suites retain
    # their own Config and solver modules.
    with monkeypatch.context() as imports:
        imports.setitem(sys.modules, 'Config', config)
        imports.setitem(sys.modules, 'selenium_recaptcha_solver', solver)
        spec.loader.exec_module(module)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(module, '__color_print', lambda *args, **kwargs: None)
    monkeypatch.setattr(module.time, 'sleep', lambda seconds: None)
    monkeypatch.setattr(module, 'WebDriverWait', PollWait)
    return module


class PollWait:
    """Exercise polling without wall-clock delays or external services."""

    def __init__(self, driver, timeout, **kwargs):
        self.driver = driver
        driver.wait_timeouts.append(timeout)

    def until(self, predicate, message=''):
        for _ in range(4):
            try:
                result = predicate(self.driver)
            except NoSuchElementException:
                continue
            if result:
                return result
        raise TimeoutException(message)


class Element:
    def __init__(self, displayed=True):
        self.displayed = displayed

    def is_displayed(self):
        return self.displayed

    def is_enabled(self):
        return True

    def send_keys(self, value):
        pass


class CaptchaDriver:
    def __init__(self, *, iframe_after=1, markup=True, token_after=None):
        self.iframe_after = iframe_after
        self.markup = markup
        self.token_after = token_after
        self.iframe_polls = 0
        self.token_polls = 0
        self.wait_timeouts = []
        self.context = 'document'
        self.default_content_calls = 0
        self.iframe = Element()
        self.switch_to = types.SimpleNamespace(default_content=self.default_content)

    def default_content(self):
        self.context = 'document'
        self.default_content_calls += 1

    def find_elements(self, by, selector):
        if 'iframe' in selector:
            self.iframe_polls += 1
            if self.iframe_after is not None and self.iframe_polls >= self.iframe_after:
                return [self.iframe]
            return []
        return [Element()] if self.markup else []

    def find_element(self, by, selector):
        elements = self.find_elements(by, selector)
        if not elements:
            raise NoSuchElementException(selector)
        return elements[0]

    def execute_script(self, script, *args):
        self.token_polls += 1
        return self.token_after is not None and self.token_polls >= self.token_after


def install_solver(monkeypatch, loginer, *, error=None):
    calls = []

    class Solver:
        def __init__(self, driver, **kwargs):
            self.driver = driver

        def click_recaptcha_v2(self, iframe):
            calls.append(iframe)
            self.driver.context = 'captcha'
            if error is not None:
                raise error

    monkeypatch.setattr(loginer, 'RecaptchaSolver', Solver)
    return calls


def test_delayed_widget_and_response_are_waited_for(loginer, monkeypatch):
    driver = CaptchaDriver(iframe_after=3, token_after=3)
    calls = install_solver(monkeypatch, loginer)

    assert loginer._solve_recaptcha(driver)
    assert calls == [driver.iframe]
    assert driver.iframe_polls >= 3
    assert driver.token_polls >= 3
    assert driver.context == 'document'


def test_completed_captcha_is_not_clicked_again(loginer, monkeypatch):
    driver = CaptchaDriver(token_after=1)
    calls = install_solver(monkeypatch, loginer)

    assert loginer._solve_recaptcha(driver)
    assert calls == []
    assert driver.context == 'document'


def test_page_without_captcha_can_continue(loginer, monkeypatch):
    driver = CaptchaDriver(iframe_after=None, markup=False)
    calls = install_solver(monkeypatch, loginer)

    assert loginer._solve_recaptcha(driver)
    assert calls == []


def test_captcha_markup_without_loaded_iframe_cannot_continue(loginer, monkeypatch):
    driver = CaptchaDriver(iframe_after=None)
    calls = install_solver(monkeypatch, loginer)

    assert not loginer._solve_recaptcha(driver)
    assert calls == []


def test_solver_return_without_response_is_not_success(loginer, monkeypatch):
    driver = CaptchaDriver()
    install_solver(monkeypatch, loginer)

    assert not loginer._solve_recaptcha(driver)
    assert driver.context == 'document'
    assert driver.default_content_calls


def test_solver_error_restores_document_and_fails(loginer, monkeypatch):
    driver = CaptchaDriver()
    install_solver(monkeypatch, loginer, error=NoSuchElementException('synthetic error'))

    assert not loginer._solve_recaptcha(driver)
    assert driver.context == 'document'


def test_response_can_confirm_success_after_solver_error(loginer, monkeypatch):
    driver = CaptchaDriver(token_after=2)
    install_solver(monkeypatch, loginer, error=TimeoutException('synthetic timeout'))

    assert loginer._solve_recaptcha(driver)
    assert driver.context == 'document'


def test_manual_fallback_allows_a_later_response(loginer, monkeypatch):
    driver = CaptchaDriver(token_after=6)
    install_solver(monkeypatch, loginer)

    assert loginer._solve_recaptcha(driver, timeout=3, allow_manual=True, manual_timeout=9)
    assert 9 in driver.wait_timeouts


def test_automatic_mode_does_not_wait_for_manual_completion(loginer, monkeypatch):
    driver = CaptchaDriver(token_after=6)
    install_solver(monkeypatch, loginer)

    assert not loginer._solve_recaptcha(driver, timeout=3, allow_manual=False, manual_timeout=9)
    assert 9 not in driver.wait_timeouts


def test_manual_fallback_is_bounded(loginer, monkeypatch):
    driver = CaptchaDriver()
    install_solver(monkeypatch, loginer)

    assert not loginer._solve_recaptcha(driver, allow_manual=True, manual_timeout=9)
    assert driver.wait_timeouts.count(9) == 1


class LoginDriver:
    def __init__(self):
        self.current_url = ''
        self.wait_timeouts = []
        self.events = []
        self.logged_in = False

    def get(self, url):
        self.current_url = url

    def find_element(self, by, selector):
        if 'btn-login' in selector:
            self.events.append('button_lookup')
        return Element()

    def get_cookie(self, name):
        return {'name': name, 'value': 'synthetic-token'} if self.logged_in else None


def test_failed_captcha_prevents_login_submission(loginer, monkeypatch):
    driver = LoginDriver()
    monkeypatch.setattr(loginer, '_solve_recaptcha', lambda *args, **kwargs: False)

    def unexpected_actions(*args):
        pytest.fail('Login was submitted after CAPTCHA failure')

    monkeypatch.setattr(loginer, 'ActionChains', unexpected_actions)

    assert not loginer.login(driver, 'test-user', 'test-password')
    assert 'button_lookup' not in driver.events


def test_login_finds_and_clicks_button_after_captcha_completion(loginer, monkeypatch):
    driver = LoginDriver()
    manual_modes = []

    def solve(current_driver, **kwargs):
        assert current_driver is driver
        manual_modes.append(kwargs['allow_manual'])
        driver.events.append('captcha_complete')
        return True

    class Actions:
        def __init__(self, current_driver):
            assert current_driver is driver

        def move_to_element(self, element):
            return self

        def click(self):
            return self

        def perform(self):
            driver.events.append('submit')
            driver.logged_in = True
            driver.current_url = 'https://www.gamer.com.tw/'

    monkeypatch.setattr(loginer, '_solve_recaptcha', solve)
    monkeypatch.setattr(loginer, 'ActionChains', Actions)

    assert loginer.login(driver, 'test-user', 'test-password', allow_manual_captcha=True)
    assert driver.events == ['captcha_complete', 'button_lookup', 'submit']
    assert manual_modes == [True]


@pytest.mark.parametrize('headless', [True, False])
def test_do_all_only_offers_manual_captcha_with_visible_browser(loginer, monkeypatch, headless):
    driver = types.SimpleNamespace(quit=lambda: None)
    seen = []
    monkeypatch.setattr(loginer, 'get_driver', lambda requested: driver)

    def login(*args, **kwargs):
        seen.append(kwargs['allow_manual_captcha'])
        return False

    monkeypatch.setattr(loginer, 'login', login)

    assert loginer.do_all('test-user', 'test-password', headless, False) is False
    assert seen == [not headless]


@pytest.mark.parametrize('value, expected', [
    ('true', True), ('TRUE', True), ('1', True),
    ('false', False), ('FALSE', False), ('0', False),
])
def test_cli_boolean_values(loginer, value, expected):
    assert loginer._parse_bool(value) is expected


@pytest.mark.parametrize('value', ['', 'maybe', '2'])
def test_cli_boolean_rejects_unknown_values(loginer, value):
    with pytest.raises(ValueError):
        loginer._parse_bool(value)
