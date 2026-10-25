#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 動畫瘋一直把我登出所以加這個 ;(
from selenium import webdriver
from selenium.common.exceptions import NoSuchElementException, StaleElementReferenceException, TimeoutException
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.common.by import By
from selenium.webdriver import ActionChains
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait
from webdriver_manager.chrome import ChromeDriverManager
from selenium_recaptcha_solver import RecaptchaSolver
import time
import sys
import os
import pickle
import re
import shutil
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


def _solve_recaptcha(driver, timeout=20, allow_manual=False, manual_timeout=120):
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
        RecaptchaSolver(driver=driver).click_recaptcha_v2(iframe=frame)
    except Exception as error:
        # The solver may time out waiting for an audio challenge even when the
        # checkbox passed asynchronously. Check completion before giving up.
        # Do not log exception text: third-party errors can contain request data.
        solver_error = type(error).__name__
    finally:
        # The solver's checkbox-only success path leaves us inside the iframe.
        driver.switch_to.default_content()

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
    if not allow_manual:
        detail += '；可停用 headless 後在瀏覽器中完成驗證'
    __color_print(0, "登入狀態", detail=detail, no_sn=True, status=1)
    return False


def login(driver, username, password, save_cookie=False, allow_manual_captcha=False):
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
    if not _solve_recaptcha(driver, allow_manual=allow_manual_captcha):
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


def do_all(username, password, headless, save_cookie):
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


def _parse_bool(value):
    value = value.lower()
    if value in ('true', '1'):
        return True
    if value in ('false', '0'):
        return False
    raise ValueError('headless 和 save_cookie 必須是 true 或 false')


if __name__ == "__main__":
    if len(sys.argv) < 5:
        print("Usage:", sys.argv[0], "[username] [password] [headless?] [save_cookie?]\nreturns raw cookie.\n? = [true/false]")
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
