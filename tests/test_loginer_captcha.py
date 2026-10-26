"""CAPTCHA regressions with synthetic drivers and no runtime configuration.

Run with ``python -m pytest tests/test_loginer_captcha.py --disable-plugin-autoload --noconftest -q``.
"""

import importlib.util
from pathlib import Path
import pickle
import sys
import types

import pytest
from requests.cookies import RequestsCookieJar
from selenium.common.exceptions import NoSuchElementException, TimeoutException, WebDriverException


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


class ChallengeFrame(Element):
    def __init__(self, *, displayed=True, notices=()):
        super().__init__(displayed)
        self.notices = list(notices)


class CaptchaDriver:
    def __init__(self, *, iframe_after=1, markup=True, token_after=None,
                 challenge_frames=()):
        self.iframe_after = iframe_after
        self.markup = markup
        self.token_after = token_after
        self.iframe_polls = 0
        self.token_polls = 0
        self.wait_timeouts = []
        self.context = 'document'
        self.default_content_calls = 0
        self.iframe = Element()
        self.challenge_frames = list(challenge_frames)
        self.frame_visits = []
        self.switch_to = types.SimpleNamespace(
            default_content=self.default_content, frame=self.switch_frame)

    def default_content(self):
        self.context = 'document'
        self.default_content_calls += 1

    def switch_frame(self, frame):
        assert self.context == 'document'
        self.context = frame
        self.frame_visits.append(frame)

    def find_elements(self, by, selector):
        if 'bframe' in selector:
            assert self.context == 'document'
            return self.challenge_frames
        if 'iframe' in selector:
            assert self.context == 'document'
            self.iframe_polls += 1
            if self.iframe_after is not None and self.iframe_polls >= self.iframe_after:
                return [self.iframe]
            return []
        if 'rc-doscaptcha' in selector:
            assert isinstance(self.context, ChallengeFrame)
            return self.context.notices
        if 'g-recaptcha' in selector:
            return [Element()] if self.markup else []
        return []

    def find_element(self, by, selector):
        elements = self.find_elements(by, selector)
        if not elements:
            raise NoSuchElementException(selector)
        return elements[0]

    def execute_script(self, script, *args):
        assert self.context == 'document'
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
    driver = CaptchaDriver(token_after=2, challenge_frames=[
        ChallengeFrame(notices=[Element()]),
    ])
    install_solver(monkeypatch, loginer, error=TimeoutException('synthetic timeout'))

    assert loginer._solve_recaptcha(driver)
    assert driver.context == 'document'
    assert driver.frame_visits == []


def test_visible_audio_block_is_detected_and_restores_document(loginer):
    frame = ChallengeFrame(notices=[Element(displayed=False), Element()])
    driver = CaptchaDriver(challenge_frames=[frame])
    driver.context = 'captcha'

    assert loginer._recaptcha_audio_blocked(driver)
    assert driver.frame_visits == [frame]
    assert driver.context == 'document'


@pytest.mark.parametrize('frame_displayed, notice_displayed', [
    (False, True), (True, False),
])
def test_hidden_audio_block_is_not_counted(loginer, frame_displayed, notice_displayed):
    frame = ChallengeFrame(displayed=frame_displayed,
                           notices=[Element(displayed=notice_displayed)])
    driver = CaptchaDriver(challenge_frames=[frame])

    assert not loginer._recaptcha_audio_blocked(driver)
    assert driver.frame_visits == ([frame] if frame_displayed else [])
    assert driver.context == 'document'


def test_audio_block_detection_checks_later_challenge_frames(loginer):
    frames = [ChallengeFrame(), ChallengeFrame(notices=[Element()])]
    driver = CaptchaDriver(challenge_frames=frames)

    assert loginer._recaptcha_audio_blocked(driver)
    assert driver.frame_visits == frames
    assert driver.context == 'document'


def test_audio_block_diagnostic_error_restores_document(loginer, monkeypatch):
    driver = CaptchaDriver(challenge_frames=[ChallengeFrame()])
    find_elements = driver.find_elements

    def fail_inside_challenge(by, selector):
        if 'rc-doscaptcha' in selector:
            raise WebDriverException('synthetic diagnostic failure')
        return find_elements(by, selector)

    monkeypatch.setattr(driver, 'find_elements', fail_inside_challenge)

    assert not loginer._recaptcha_audio_blocked(driver)
    assert driver.context == 'document'


def test_confirmed_block_skips_automatic_response_wait(loginer, monkeypatch):
    driver = CaptchaDriver(challenge_frames=[ChallengeFrame(notices=[Element()])])
    install_solver(monkeypatch, loginer, error=RuntimeError('private request payload'))
    details = []
    monkeypatch.setattr(loginer, '__color_print',
                        lambda *args, **kwargs: details.append(kwargs.get('detail', '')))

    assert not loginer._solve_recaptcha(driver, timeout=3)
    assert driver.wait_timeouts == [3]
    assert driver.token_polls == 2
    assert driver.context == 'document'
    assert 'Google 已封鎖此瀏覽器或網路的音訊驗證請求' in details[-1]
    assert 'headless' not in details[-1]
    assert 'private request payload' not in ''.join(details)


def test_confirmed_block_can_still_allow_manual_completion(loginer, monkeypatch):
    driver = CaptchaDriver(token_after=3,
                           challenge_frames=[ChallengeFrame(notices=[Element()])])
    install_solver(monkeypatch, loginer)

    assert loginer._solve_recaptcha(driver, timeout=3, allow_manual=True, manual_timeout=9)
    assert driver.wait_timeouts == [3, 9]
    assert driver.context == 'document'


@pytest.mark.parametrize('message, reason', [
    ('Google has detected automated queries. Try again later.', '未取得音訊驗證連結'),
    ('Speech recognition API could not understand audio, try again', '無法辨識音訊驗證內容'),
    ('Failed to solve captcha after 5 attempts', '音訊驗證重試次數已用完'),
])
def test_known_solver_errors_report_static_reason(loginer, monkeypatch, message, reason):
    driver = CaptchaDriver()
    install_solver(monkeypatch, loginer, error=RuntimeError(message))
    details = []
    monkeypatch.setattr(loginer, '__color_print',
                        lambda *args, **kwargs: details.append(kwargs.get('detail', '')))

    assert not loginer._solve_recaptcha(driver, timeout=3)
    assert reason in details[-1]
    assert message not in ''.join(details)
    assert 'Google 已封鎖' not in details[-1]
    assert driver.wait_timeouts == [3, 3]


@pytest.mark.parametrize('message', [
    'private request payload',
    'Google has detected automated queries. Try again later. private request payload',
])
def test_unknown_solver_error_payload_is_not_logged(loginer, monkeypatch, message):
    driver = CaptchaDriver()
    install_solver(monkeypatch, loginer, error=RuntimeError(message))
    details = []
    monkeypatch.setattr(loginer, '__color_print',
                        lambda *args, **kwargs: details.append(kwargs.get('detail', '')))

    assert not loginer._solve_recaptcha(driver)
    assert 'RuntimeError' in details[-1]
    assert 'private request payload' not in ''.join(details)
    assert '未取得音訊驗證連結' not in details[-1]


def test_manual_fallback_allows_a_later_response(loginer, monkeypatch):
    driver = CaptchaDriver(token_after=7)
    install_solver(monkeypatch, loginer)

    assert loginer._solve_recaptcha(driver, timeout=3, allow_manual=True, manual_timeout=9)
    assert 9 in driver.wait_timeouts


def test_automatic_mode_does_not_wait_for_manual_completion(loginer, monkeypatch):
    driver = CaptchaDriver(token_after=7)
    install_solver(monkeypatch, loginer)

    assert not loginer._solve_recaptcha(driver, timeout=3, allow_manual=False, manual_timeout=9)
    assert 9 not in driver.wait_timeouts


def test_manual_fallback_is_bounded(loginer, monkeypatch):
    driver = CaptchaDriver()
    install_solver(monkeypatch, loginer)

    assert not loginer._solve_recaptcha(driver, allow_manual=True, manual_timeout=9)
    assert driver.wait_timeouts.count(9) == 1


@pytest.mark.parametrize('token_after, expected', [(3, True), (None, False)])
def test_manual_only_preserves_challenge_and_uses_only_manual_wait(
        loginer, monkeypatch, token_after, expected):
    driver = CaptchaDriver(token_after=token_after)

    def unexpected_solver(*args, **kwargs):
        pytest.fail('Remote recovery must not start an automatic audio challenge')

    monkeypatch.setattr(loginer, 'RecaptchaSolver', unexpected_solver)

    assert loginer._solve_recaptcha(
        driver, timeout=3, allow_manual=True, manual_timeout=9, manual_only=True) is expected
    assert driver.wait_timeouts == [3, 9]
    assert driver.context == 'document'


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
    captcha_options = []

    def solve(current_driver, **kwargs):
        assert current_driver is driver
        captcha_options.append(kwargs)
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

    assert loginer.login(driver, 'test-user', 'test-password', allow_manual_captcha=True,
                         manual_captcha=True, captcha_timeout=37)
    assert driver.events == ['captcha_complete', 'button_lookup', 'submit']
    assert captcha_options == [{
        'allow_manual': True, 'manual_only': True, 'manual_timeout': 37,
    }]


@pytest.mark.parametrize('headless', [True, False])
def test_do_all_only_offers_manual_captcha_with_visible_browser(loginer, monkeypatch, headless):
    driver = types.SimpleNamespace(quit=lambda: None)
    seen = []
    monkeypatch.setattr(loginer, 'get_driver', lambda requested: driver)
    monkeypatch.setattr(loginer, 'app_login', lambda *args: False)

    def login(*args, **kwargs):
        seen.append(kwargs['allow_manual_captcha'])
        return False

    monkeypatch.setattr(loginer, 'login', login)

    assert loginer.do_all('test-user', 'test-password', headless, False) is False
    assert seen == [not headless]


@pytest.fixture
def app_session(loginer, monkeypatch):
    state = types.SimpleNamespace(
        result={'success': True}, web_cookie='synthetic-web-token',
        target='https://www.gamer.com.tw/', calls=[], closed=False,
        deleted=False, error=None,
    )
    jar = RequestsCookieJar()
    state.jar = jar

    class Session:
        def __init__(self, **kwargs):
            self.cookies = types.SimpleNamespace(jar=jar, set=jar.set)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            state.closed = True

        def post(self, url, **kwargs):
            state.calls.append(('post', url, kwargs))
            if state.error:
                raise state.error
            if state.web_cookie is not None:
                jar.set('BAHARUNE', state.web_cookie, domain='.gamer.com.tw',
                        secure=True, expires=2147483647)
            jar.set('MB_BAHARUNE', 'synthetic-app-token', domain='.gamer.com.tw')
            jar.set('unrelated', 'private-other-token', domain='example.com')
            return types.SimpleNamespace(raise_for_status=lambda: None,
                                         json=lambda: state.result)

        def get(self, url, **kwargs):
            state.calls.append(('get', url, kwargs))
            if state.deleted:
                jar.set('BAHARUNE', 'deleted', domain='.gamer.com.tw')
            return types.SimpleNamespace(raise_for_status=lambda: None, url=state.target)

    monkeypatch.setattr(loginer.curl_requests, 'Session', Session)
    monkeypatch.setattr(loginer.Config, 'read_settings', lambda: {'ua': 'test-browser-agent'},
                        raising=False)
    return state


def test_app_login_obtains_a_verified_web_session_without_a_browser(
        loginer, app_session, capsys):
    result = loginer.app_login('private-test-user', 'private-test-password')

    assert 'BAHARUNE=synthetic-web-token' in result
    assert 'MB_BAHARUNE=synthetic-app-token' in result
    assert 'unrelated' not in result
    assert app_session.closed
    assert [call[0] for call in app_session.calls] == ['post', 'get']
    _, url, request = app_session.calls[0]
    assert url == 'https://api.gamer.com.tw/mobile_app/user/v3/do_login.php'
    assert request['data'] == {
        'uid': 'private-test-user', 'passwd': 'private-test-password', 'vcode': '7045',
    }
    assert app_session.jar.get('ckAPP_VCODE') == request['data']['vcode']
    assert app_session.calls[1][2]['headers']['User-Agent'] == 'test-browser-agent'
    assert not Path('cookies.pkl').exists()
    output = capsys.readouterr()
    for secret in ('private-test-user', 'private-test-password', 'synthetic-web-token'):
        assert secret not in output.out + output.err


@pytest.mark.parametrize('result', [{'success': False}, {'success': 'false'}, {}, []])
def test_app_login_rejects_unsuccessful_responses(loginer, app_session, result):
    app_session.result = result

    assert loginer.app_login('user', 'password', save_cookie=True) is False
    assert [call[0] for call in app_session.calls] == ['post']
    assert not Path('cookies.pkl').exists()
    assert app_session.closed


def test_app_login_requires_the_web_cookie_even_with_an_app_cookie(loginer, app_session):
    app_session.web_cookie = None

    assert loginer.app_login('user', 'password', save_cookie=True) is False
    assert not Path('cookies.pkl').exists()


@pytest.mark.parametrize('target', [
    'https://user.gamer.com.tw/login.php',
    'https://user.gamer.com.tw/two-factor.php',
    'https://www.gamer.com.tw/error.php',
    'https://example.com/',
])
def test_app_login_requires_a_successful_web_login_redirect(loginer, app_session, target):
    app_session.target = target

    assert loginer.app_login('user', 'password', save_cookie=True) is False
    assert not Path('cookies.pkl').exists()


def test_app_login_rejects_a_web_cookie_deleted_during_validation(loginer, app_session):
    app_session.deleted = True

    assert loginer.app_login('user', 'password') is False


def test_app_login_can_save_browser_compatible_cookies(loginer, app_session):
    assert loginer.app_login('user', 'password', save_cookie=True)

    with Path('cookies.pkl').open('rb') as saved:
        cookies = pickle.load(saved)
    web_cookie = next(cookie for cookie in cookies if cookie['name'] == 'BAHARUNE')
    assert web_cookie == {
        'name': 'BAHARUNE', 'value': 'synthetic-web-token',
        'domain': '.gamer.com.tw', 'path': '/', 'secure': True, 'expiry': 2147483647,
    }
    assert all(cookie['name'] != 'unrelated' for cookie in cookies)


def test_app_login_does_not_log_request_secrets_on_failure(
        loginer, monkeypatch, app_session, capsys):
    app_session.error = RuntimeError('private-test-password synthetic-web-token')
    monkeypatch.setattr(loginer, '__color_print',
                        lambda *args, **kwargs: print(kwargs.get('detail', '')))

    assert loginer.app_login('user', 'private-test-password') is False
    assert app_session.closed
    output = capsys.readouterr()
    assert 'RuntimeError' in output.out
    assert 'private-test-password' not in output.out + output.err
    assert 'synthetic-web-token' not in output.out + output.err


def test_headless_app_login_success_skips_browser_startup(loginer, monkeypatch):
    calls = []

    def app_login(*args):
        calls.append(args)
        return 'BAHARUNE=synthetic-web-token'

    def unexpected_browser(*args):
        pytest.fail('Successful app login must not start a browser')

    monkeypatch.setattr(loginer, 'app_login', app_login)
    monkeypatch.setattr(loginer, 'get_driver', unexpected_browser)

    assert loginer.do_all('user', 'password', True, True) == 'BAHARUNE=synthetic-web-token'
    assert calls == [('user', 'password', True)]


@pytest.fixture
def remote_session(loginer, monkeypatch, tmp_path):
    application_dir = tmp_path / 'application'
    application_dir.mkdir()
    cookie_path = application_dir / 'cookie.txt'
    cookie_path.write_text('previous-synthetic-cookie', encoding='utf-8')
    settings = {'auto_login': {
        'username': 'private-synthetic-username',
        'password': 'private-synthetic-password',
    }}
    old_cache = object()
    monkeypatch.setattr(loginer.Config, 'read_settings', lambda: settings, raising=False)
    monkeypatch.setattr(loginer.Config, 'working_dir', str(application_dir), raising=False)
    monkeypatch.setattr(loginer.Config, 'cookie_path', str(cookie_path), raising=False)
    monkeypatch.setattr(loginer.Config, 'cookie', old_cache, raising=False)
    monkeypatch.setattr(loginer, '__color_print',
                        lambda *args, **kwargs: print(kwargs.get('detail', '')))
    events = []
    driver = types.SimpleNamespace(
        capabilities={'goog:chromeOptions': {'debuggerAddress': '127.0.0.1:54321'}},
        quit=lambda: events.append('quit'),
    )

    def get_driver(*, headless):
        assert headless is True
        assert Path.cwd() == application_dir
        events.append('driver')
        return driver

    def get_raw_cookie(current_driver):
        assert current_driver is driver
        events.append('raw_cookie')
        return 'BAHARUNE=private-synthetic-cookie'

    def update_identity(current_driver):
        assert current_driver is driver
        events.append('identity')
        return True

    monkeypatch.setattr(loginer, 'get_driver', get_driver)
    monkeypatch.setattr(loginer, 'get_raw_cookie', get_raw_cookie)
    monkeypatch.setattr(loginer, 'update_browser_identity', update_identity)
    return types.SimpleNamespace(
        application_dir=application_dir, cookie_path=cookie_path,
        settings=settings, old_cache=old_cache, events=events, driver=driver,
    )


def test_remote_login_saves_session_and_never_prints_secrets(
        loginer, monkeypatch, remote_session, capsys):
    session = remote_session
    previous_dir = Path.cwd()
    login_options = []

    def login(driver, username, password, **kwargs):
        assert driver is session.driver
        assert Path.cwd() == session.application_dir
        assert username == session.settings['auto_login']['username']
        assert password == session.settings['auto_login']['password']
        login_options.append(kwargs)
        session.events.append('login')
        return True

    monkeypatch.setattr(loginer, 'login', login)

    assert loginer.remote_login(timeout=37)
    assert login_options == [{
        'save_cookie': True, 'allow_manual_captcha': True,
        'manual_captcha': True, 'captcha_timeout': 37,
    }]
    assert session.cookie_path.read_text(encoding='utf-8') == 'BAHARUNE=private-synthetic-cookie'
    assert loginer.Config.cookie is None
    assert session.events == ['driver', 'login', 'raw_cookie', 'identity', 'quit']
    assert Path.cwd() == previous_dir
    assert list(session.application_dir.glob('.login-*')) == []
    output = capsys.readouterr()
    assert '9222:127.0.0.1:54321' in output.out
    assert 'chrome://inspect/#devices' in output.out
    assert 'server session has been saved' in output.out
    for secret in ('private-synthetic-username', 'private-synthetic-password',
                   'private-synthetic-cookie'):
        assert secret not in output.out + output.err


def test_remote_login_timeout_preserves_session_and_quits(
        loginer, monkeypatch, remote_session, capsys):
    session = remote_session
    previous_dir = Path.cwd()

    def login(*args, **kwargs):
        assert kwargs['captcha_timeout'] == 37
        session.events.append('login_timeout')
        return False

    monkeypatch.setattr(loginer, 'login', login)

    assert not loginer.remote_login(timeout=37)
    assert session.cookie_path.read_text(encoding='utf-8') == 'previous-synthetic-cookie'
    assert loginer.Config.cookie is session.old_cache
    assert session.events == ['driver', 'login_timeout', 'quit']
    assert Path.cwd() == previous_dir
    assert list(session.application_dir.glob('.login-*')) == []
    assert 'server session has been saved' not in capsys.readouterr().out


def test_remote_login_error_keeps_payload_private_and_quits(
        loginer, monkeypatch, remote_session, capsys):
    session = remote_session
    previous_dir = Path.cwd()

    def login(*args, **kwargs):
        raise RuntimeError('private-synthetic-password private-synthetic-cookie')

    monkeypatch.setattr(loginer, 'login', login)

    assert not loginer.remote_login()
    assert session.events == ['driver', 'quit']
    assert Path.cwd() == previous_dir
    assert session.cookie_path.read_text(encoding='utf-8') == 'previous-synthetic-cookie'
    output = capsys.readouterr()
    assert 'RuntimeError' in output.out
    assert 'private-synthetic-password' not in output.out + output.err
    assert 'private-synthetic-cookie' not in output.out + output.err


def test_remote_login_failed_cookie_replace_preserves_old_cookie_and_cleans_up(
        loginer, monkeypatch, remote_session):
    session = remote_session
    previous_dir = Path.cwd()
    monkeypatch.setattr(loginer, 'login', lambda *args, **kwargs: True)

    def fail_replace(source, destination):
        assert Path(source).read_text(encoding='utf-8') == 'BAHARUNE=private-synthetic-cookie'
        assert Path(destination) == session.cookie_path
        raise OSError('synthetic replacement failure')

    monkeypatch.setattr(loginer.os, 'replace', fail_replace)

    assert not loginer.remote_login()
    assert session.cookie_path.read_text(encoding='utf-8') == 'previous-synthetic-cookie'
    assert loginer.Config.cookie is session.old_cache
    assert session.events[-1] == 'quit'
    assert Path.cwd() == previous_dir
    assert list(session.application_dir.glob('.login-*')) == []


@pytest.mark.parametrize('address', [
    '192.0.2.10:54321', '0.0.0.0:54321', '[::]:54321',
    'localhost:0', '127.0.0.1:65536', '127.0.0.1:not-a-port',
])
def test_remote_login_rejects_nonloopback_or_invalid_debugger(
        loginer, monkeypatch, remote_session, capsys, address):
    session = remote_session
    session.driver.capabilities['goog:chromeOptions']['debuggerAddress'] = address
    previous_dir = Path.cwd()

    def unexpected_login(*args, **kwargs):
        pytest.fail('Invalid debugger address must be rejected before entering credentials')

    monkeypatch.setattr(loginer, 'login', unexpected_login)

    assert not loginer.remote_login()
    assert session.events == ['driver', 'quit']
    assert Path.cwd() == previous_dir
    assert session.cookie_path.read_text(encoding='utf-8') == 'previous-synthetic-cookie'
    output = capsys.readouterr()
    assert 'ValueError' in output.out
    assert 'ssh -N' not in output.out


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
