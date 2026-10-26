#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 動畫瘋一直把我登出所以加這個 ;(
from selenium import webdriver
from selenium.common.exceptions import NoSuchElementException, StaleElementReferenceException, TimeoutException, WebDriverException
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.common.by import By
from selenium.webdriver import ActionChains
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait
from webdriver_manager.chrome import ChromeDriverManager
from selenium_recaptcha_solver import RecaptchaSolver
from curl_cffi import requests as curl_requests
from urllib.parse import urlsplit
import time
import sys
import os
import pickle
import re
import shutil
import tempfile
import uuid
import Config


# 網站端認的是 BAHARUNE, App 端認的是 MB_BAHARUNE。少了前者, ani.gamer.com.tw 會把
# 你當訪客 —— 照樣給你影片, 只是先排 25 秒廣告, 然後最高 360P
_WEB_LOGIN_COOKIE = 'BAHARUNE'
_RECAPTCHA_FRAME = (
    'iframe[src*="/recaptcha/"][src*="/anchor"], iframe[title="reCAPTCHA"]'
)
_RECAPTCHA_MARKUP = (
    '.g-recaptcha, [name="g-recaptcha-response"], script[src*="/recaptcha/"]'
)
_RECAPTCHA_ERROR_REASONS = {
    'Google has detected automated queries. Try again later.': '未取得音訊驗證連結',
    'Speech recognition API could not understand audio, try again': '無法辨識音訊驗證內容',
    'Failed to solve captcha after 5 attempts': '音訊驗證重試次數已用完',
}


FINGERPRINT_CHECK_URL = 'https://ja3.zone/check'
_FINGERPRINT_FIELD_XPATH = (
    "//div[normalize-space()='{label}']"
    "/following-sibling::label[1]//textarea[@aria-label='Raw']"
)
_JA3_PATTERN = re.compile(r'^\d+,[\d-]*,[\d-]*,[\d-]*,[\d-]*$')
_AKAMAI_PATTERN = re.compile(r'^\d+:\d+(?:;\d+:\d+)*\|\d+\|\d+\|[a-z,]+$', re.IGNORECASE)

# stolen from Config.py lol
def __color_print(sn, err_msg, detail='', status=0, no_sn=False, display=True):
    # 避免与 ColorPrint.py 相互调用产生问题
    try:
        err_print(sn, err_msg, detail=detail, status=status, no_sn=no_sn, display=display)
    except UnboundLocalError:
        from ColorPrint import err_print
        err_print(sn, err_msg, detail=detail, status=status, no_sn=no_sn, display=display)


def get_driver(headless=False):
    __color_print(0, "登入狀態", detail='正在啟動瀏覽器', no_sn=True)
    settings = Config.read_settings()
    opt = webdriver.ChromeOptions()
    chrome_binary = (os.environ.get('CHROME_BIN') or
                     shutil.which('google-chrome') or
                     shutil.which('chromium') or
                     shutil.which('chromium-browser'))
    if chrome_binary:
        opt.binary_location = chrome_binary
    if headless:
        opt.add_argument('--headless=new')
        # Disabling Chromium's sandbox weakens isolation substantially. Some
        # containers cannot start it, but that must be an explicit operator
        # choice rather than the default for every headless login.
        if os.environ.get('AGP_CHROME_NO_SANDBOX') == '1':
            opt.add_argument('--no-sandbox')
        opt.add_argument('--disable-dev-shm-usage')
        opt.add_argument('--disable-gpu')
    if settings['auto_login']['use_wdm']:
        return webdriver.Chrome(service=ChromeService(ChromeDriverManager().install()), options=opt)
    else:
        return webdriver.Chrome(options=opt)


def _recaptcha_complete(driver):
    # Keep the response token inside the browser; callers only need a boolean.
    return driver.execute_script('''
        return Array.from(document.querySelectorAll('[name="g-recaptcha-response"]'))
            .some(element => Boolean(element.value.trim()));
    ''')


def _recaptcha_audio_blocked(driver):
    """Distinguish Google's explicit block from a slow/missing audio link."""
    try:
        driver.switch_to.default_content()
        frames = driver.find_elements(
            By.CSS_SELECTOR, 'iframe[src*="recaptcha"][src*="bframe"]')
        for frame in frames:
            if not frame.is_displayed():
                continue
            driver.switch_to.frame(frame)
            notices = driver.find_elements(
                By.CSS_SELECTOR, '.rc-doscaptcha-header, .rc-doscaptcha-body')
            if any(notice.is_displayed() for notice in notices):
                return True
            driver.switch_to.default_content()
    except WebDriverException:
        # Diagnostics must not obscure the original solver failure.
        return False
    finally:
        try:
            driver.switch_to.default_content()
        except WebDriverException:
            pass
    return False


def _solve_recaptcha(driver, timeout=20, allow_manual=False, manual_timeout=120,
                     manual_only=False):
    driver.switch_to.default_content()

    def visible_frame(current_driver):
        for frame in current_driver.find_elements(By.CSS_SELECTOR, _RECAPTCHA_FRAME):
            try:
                if frame.is_displayed():
                    return frame
            except StaleElementReferenceException:
                continue
        return False

    try:
        frame = WebDriverWait(driver, timeout).until(visible_frame)
    except TimeoutException:
        # An unloaded widget is not the same as a page with no CAPTCHA.
        if driver.find_elements(By.CSS_SELECTOR, _RECAPTCHA_MARKUP):
            __color_print(0, "登入狀態", detail='reCAPTCHA 未能載入，請稍後重試',
                          no_sn=True, status=1)
            return False
        return True

    if _recaptcha_complete(driver):
        return True

    solver_error = None
    try:
        if not manual_only:
            RecaptchaSolver(driver=driver).click_recaptcha_v2(iframe=frame)
    except Exception as error:
        # The solver may time out waiting for an audio challenge even when the
        # checkbox passed asynchronously. Check completion before giving up.
        # Do not log exception text: third-party errors can contain request data.
        solver_error = _RECAPTCHA_ERROR_REASONS.get(str(error), type(error).__name__)
    finally:
        # The solver's checkbox-only success path leaves us inside the iframe.
        driver.switch_to.default_content()

    if _recaptcha_complete(driver):
        return True
    audio_blocked = _recaptcha_audio_blocked(driver)
    if audio_blocked:
        solver_error = 'Google 已封鎖此瀏覽器或網路的音訊驗證請求'
    elif not manual_only:
        try:
            WebDriverWait(driver, timeout).until(_recaptcha_complete)
            return True
        except TimeoutException:
            pass

    if allow_manual:
        __color_print(0, "登入狀態", detail=f'請在瀏覽器中完成 reCAPTCHA 驗證（等待 {manual_timeout} 秒）',
                      no_sn=True, status=1)
        try:
            WebDriverWait(driver, manual_timeout).until(_recaptcha_complete)
            return True
        except TimeoutException:
            pass

    detail = 'reCAPTCHA 驗證未通過，未送出登入表單'
    if solver_error:
        detail += f'（{solver_error}）'
    if not allow_manual and not audio_blocked:
        detail += '；可停用 headless 後在瀏覽器中完成驗證'
    __color_print(0, "登入狀態", detail=detail, no_sn=True, status=1)
    return False


def login(driver, username, password, save_cookie=False, allow_manual_captcha=False,
          manual_captcha=False, captcha_timeout=120):
    __color_print(0, "登入狀態", detail='正在登入', no_sn=True)
    driver.get("https://gamer.com.tw/")
    if os.path.exists('cookies.pkl'):
        __color_print(0, "登入狀態", detail='找到cookie檔案', no_sn=True)
        cookies = pickle.load(open("cookies.pkl", "rb"))
        for cookie in cookies:
            driver.add_cookie(cookie)
    driver.get("https://user.gamer.com.tw/login.php")
    time.sleep(1)
    if driver.current_url != 'https://user.gamer.com.tw/login.php':
        # 沒被留在登入頁, 不代表登進去了: 過期的 cookies.pkl 一樣會被放行, 只是身上
        # 少了網站端的憑證。真的問一句有沒有, 沒有就當作沒登入, 老實輸入帳密
        if driver.get_cookie(_WEB_LOGIN_COOKIE):
            return True
        __color_print(0, "登入狀態", detail='現有cookie已失效，重新登入', no_sn=True, status=1)
        driver.delete_all_cookies()
        if os.path.exists('cookies.pkl'):
            # 留著只會下次再騙自己一遍
            os.remove('cookies.pkl')
        driver.get("https://user.gamer.com.tw/login.php")
        time.sleep(1)
    wait = WebDriverWait(driver, 20)
    user_input = wait.until(EC.visibility_of_element_located((By.XPATH, '//*[@id="form-login"]/input[1]')))
    pass_input = wait.until(EC.visibility_of_element_located((By.XPATH, '//*[@id="form-login"]/div[1]/input')))
    user_input.send_keys(username)
    pass_input.send_keys(password)
    if not _solve_recaptcha(driver, allow_manual=allow_manual_captcha,
                            manual_only=manual_captcha, manual_timeout=captcha_timeout):
        return False
    login_button = wait.until(EC.element_to_be_clickable((By.ID, 'btn-login')))
    ActionChains(driver).move_to_element(login_button).click().perform()
    time.sleep(10)
    if driver.current_url == 'https://user.gamer.com.tw/login.php':
        # 還在登入頁面
        message = driver.find_element(By.CSS_SELECTOR, '#loginFormDiv > div.caption-text.red.margin-bottom.msgdiv-alert')
        if message.text != "":
            __color_print(0, "登入狀態", detail='錯誤: ' + message.text, no_sn=True, status=1)
            return False
        else:
            __color_print(0, "登入狀態", detail='登入時可能發生驗證問題', no_sn=True, status=1)
            # todo: 處理2fa
            return False
    if not driver.get_cookie(_WEB_LOGIN_COOKIE):
        # 表單過了、頁面也跳走了, 但憑證沒發下來。這時候回報成功, 換來的是一份看起來
        # 很像登入的訪客 cookie, 之後每一集都默默掉到 360P
        __color_print(0, "登入狀態", detail='登入後仍未取得網站憑證', no_sn=True, status=1)
        return False
    __color_print(0, "登入狀態", detail='登入成功', no_sn=True, status=2)
    if save_cookie:
        __color_print(0, "登入狀態", detail='正在儲存cookie', no_sn=True)
        pickle.dump(driver.get_cookies(), open("cookies.pkl", "wb"))
    return True


def get_raw_cookie(driver):
    driver.get("https://ani.gamer.com.tw")
    cookies = driver.get_cookies()
    cookies_raw = ""
    for cookie in cookies:
        cookies_raw += f"{cookie['name']}={cookie['value']}; "
    cookies_raw = cookies_raw.rstrip("; ")
    return cookies_raw


def _get_fingerprint_field(driver, label, timeout=20):
    xpath = _FINGERPRINT_FIELD_XPATH.format(label=label)

    def read_value(current_driver):
        try:
            value = current_driver.find_element(By.XPATH, xpath).get_attribute('value')
        except NoSuchElementException:
            return False
        return value.strip() if value else False

    return WebDriverWait(driver, timeout).until(read_value)


def capture_browser_identity(driver, timeout=20):
    user_agent = driver.execute_script('return navigator.userAgent')
    if not user_agent or not user_agent.strip():
        raise ValueError('無法取得瀏覽器 UA')

    driver.get(FINGERPRINT_CHECK_URL)
    ja3 = _get_fingerprint_field(driver, 'JA3 fingerprint', timeout)
    akamai = _get_fingerprint_field(driver, 'Akamai fingerprint', timeout)

    if not _JA3_PATTERN.fullmatch(ja3):
        raise ValueError('JA3 指紋格式不正確')
    if not _AKAMAI_PATTERN.fullmatch(akamai):
        raise ValueError('Akamai 指紋格式不正確')

    return {
        'ua': user_agent.strip(),
        'browser_fingerprint': {
            'ja3': ja3,
            'akamai': akamai
        }
    }


def update_browser_identity(driver):
    __color_print(0, "登入狀態", detail='正在透過 ja3.zone 自動取得 UA、JA3 與 Akamai 指紋', no_sn=True)
    try:
        browser_identity = capture_browser_identity(driver)
        settings = Config.read_settings()
        settings['ua'] = browser_identity['ua']
        settings['browser_fingerprint'] = browser_identity['browser_fingerprint']
        Config.write_settings(settings)
    except Exception as e:
        __color_print(
            0,
            "登入狀態",
            detail='自動更新瀏覽器指紋失敗，保留原設定: ' + str(e),
            status=1,
            no_sn=True
        )
        return False

    __color_print(0, "登入狀態", detail='已自動更新 UA、JA3 與 Akamai 指紋', status=2, no_sn=True)
    return True


def app_login(username, password, save_cookie=False):
    __color_print(0, "登入狀態", detail='正在透過 App 介面登入', no_sn=True)
    try:
        settings = Config.read_settings()
        headers = {
            'User-Agent': 'Bahadroid (https://www.gamer.com.tw/)',
            'X-Bahamut-App-Instanceid': uuid.uuid4().hex,
            'X-Bahamut-App-Android': 'tw.com.gamer.android.activecenter',
            'X-Bahamut-App-Version': '251',
        }
        with curl_requests.Session(impersonate='chrome') as session:
            session.cookies.set('ckAPP_VCODE', '7045', domain='.gamer.com.tw', secure=True)
            response = session.post(
                'https://api.gamer.com.tw/mobile_app/user/v3/do_login.php',
                headers=headers,
                data={'uid': username, 'passwd': password, 'vcode': '7045'},
                timeout=30,
            )
            response.raise_for_status()
            result = response.json()
            if not isinstance(result, dict) or result.get('success') != 1:
                __color_print(0, "登入狀態", detail='App 登入未成功，改用瀏覽器登入',
                              no_sn=True, status=1)
                return False

            response = session.get('https://user.gamer.com.tw/login.php',
                                   headers={'User-Agent': settings['ua']}, timeout=30)
            response.raise_for_status()
            target = urlsplit(response.url)
            cookies = [cookie for cookie in session.cookies.jar
                       if cookie.domain.lstrip('.') in ('gamer.com.tw', 'ani.gamer.com.tw')
                       and not cookie.is_expired()]
            if (target.hostname not in ('gamer.com.tw', 'www.gamer.com.tw')
                    or target.path not in ('', '/')
                    or not any(cookie.name == _WEB_LOGIN_COOKIE and cookie.value
                               and cookie.value != 'deleted' for cookie in cookies)):
                __color_print(0, "登入狀態", detail='App 登入後未通過網站登入驗證',
                              no_sn=True, status=1)
                return False

            if save_cookie:
                browser_cookies = []
                for cookie in cookies:
                    browser_cookie = {
                        'name': cookie.name, 'value': cookie.value,
                        'domain': cookie.domain, 'path': cookie.path or '/',
                        'secure': cookie.secure,
                    }
                    if cookie.expires is not None:
                        browser_cookie['expiry'] = int(cookie.expires)
                    browser_cookies.append(browser_cookie)
                with open('cookies.pkl', 'wb') as output:
                    pickle.dump(browser_cookies, output)
            raw_cookie = '; '.join(f'{cookie.name}={cookie.value}' for cookie in cookies)
        __color_print(0, "登入狀態", detail='App 登入成功，已通過網站登入驗證',
                      no_sn=True, status=2)
        return raw_cookie
    except Exception as error:
        __color_print(0, "登入狀態", detail='App 登入失敗（' + type(error).__name__ + '）',
                      no_sn=True, status=1)
        return False


def do_all(username, password, headless, save_cookie):
    if headless:
        raw_cookie = app_login(username, password, save_cookie)
        if raw_cookie:
            return raw_cookie
    try:
        driver = get_driver(headless)
    except Exception as e:
        __color_print(0, "登入狀態", detail='啟動瀏覽器時發生異常: ' + str(e), status=1, no_sn=True)
        return False
    try:
        if login(driver, username, password, save_cookie, allow_manual_captcha=not headless):
            raw_cookie = get_raw_cookie(driver)
            update_browser_identity(driver)
        else:
            raw_cookie = False
        return raw_cookie
    except Exception as e:
        __color_print(0, "登入狀態", detail='登入時發生異常: ' + str(e), status=1, no_sn=True)
        return False
    finally:
        try:
            driver.quit()
        except Exception:
            pass


def remote_login(timeout=600):
    """Recover a server session through SSH-forwarded Chrome DevTools."""
    driver = None
    cookie_temp = None
    previous_dir = os.getcwd()
    try:
        # Load credentials through the normal runtime path, never via argv or
        # stdout. Keep browser cookies in the application directory as usual.
        settings = Config.read_settings()
        os.chdir(Config.working_dir)
        driver = get_driver(headless=True)
        address = driver.capabilities['goog:chromeOptions']['debuggerAddress']
        host, _, port = address.rpartition(':')
        if host not in ('127.0.0.1', 'localhost') or not 0 < int(port) < 65536:
            raise ValueError('Chrome debugger must listen on loopback')
        print('Chrome is running headlessly. On your PC, open an SSH tunnel:', flush=True)
        print(f'  ssh -N -L 9222:127.0.0.1:{port} <user>@<server>', flush=True)
        print('Open chrome://inspect/#devices, configure localhost:9222, then Inspect the login page.',
              flush=True)
        print('Enable the DevTools screencast to complete the CAPTCHA. No browser UI is needed on the server.',
              flush=True)
        if not login(driver, settings['auto_login']['username'], settings['auto_login']['password'],
                     save_cookie=True, allow_manual_captcha=True,
                     manual_captcha=True, captcha_timeout=timeout):
            return False
        raw_cookie = get_raw_cookie(driver)
        update_browser_identity(driver)
        # Replace atomically and retain private permissions on the new file.
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8',
                                         dir=os.path.dirname(Config.cookie_path),
                                         prefix='.login-', delete=False) as output:
            cookie_temp = output.name
            output.write(raw_cookie)
        os.replace(cookie_temp, Config.cookie_path)
        cookie_temp = None
        Config.cookie = None
        print('Login succeeded; the server session has been saved. You can close the SSH tunnel.', flush=True)
        return True
    except Exception as error:
        __color_print(0, "登入狀態", detail='遠端登入失敗（' + type(error).__name__ + '）',
                      status=1, no_sn=True)
        return False
    finally:
        if cookie_temp is not None:
            try:
                os.remove(cookie_temp)
            except OSError:
                pass
        if driver is not None:
            try:
                driver.quit()
            except Exception:
                pass
        os.chdir(previous_dir)


def _parse_bool(value):
    value = value.lower()
    if value in ('true', '1'):
        return True
    if value in ('false', '0'):
        return False
    raise ValueError('headless 和 save_cookie 必須是 true 或 false')


if __name__ == "__main__":
    if sys.argv[1:] == ['--remote-login']:
        exit(0 if remote_login() else 1)
    if len(sys.argv) < 5:
        print("Usage:", sys.argv[0], "[username] [password] [headless?] [save_cookie?]\nreturns raw cookie.\n? = [true/false]")
        print("Server recovery:", sys.argv[0], "--remote-login\nuses saved account settings and writes cookies without printing them.")
        exit(1)
    try:
        headless = _parse_bool(sys.argv[3])
        save_cookie = _parse_bool(sys.argv[4])
    except ValueError as error:
        print(str(error))
        exit(1)
    stat = do_all(sys.argv[1], sys.argv[2], headless, save_cookie)
    if stat:
        print(stat)
        exit(0)
    else:
        print("ERROR: Get raw cookie failed.")
        exit(1)
