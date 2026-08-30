#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 動畫瘋一直把我登出所以加這個 ;(
from selenium import webdriver
from selenium.common import NoSuchElementException, ElementNotInteractableException
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.common.by import By
from selenium.webdriver import Keys, ActionChains
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support.ui import Select
from webdriver_manager.chrome import ChromeDriverManager
from selenium.webdriver.chrome.options import Options
from selenium_recaptcha_solver import RecaptchaSolver
import time
import sys
import os
import pickle
import re
import Config


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
    if headless:
        opt.add_argument('--headless=new')
    if settings['auto_login']['use_wdm']:
        return webdriver.Chrome(service=ChromeService(ChromeDriverManager().install()), options=opt)
    else:
        return webdriver.Chrome(options=opt)


def login(driver, username, password, save_cookie=False):
    __color_print(0, "登入狀態", detail='正在登入', no_sn=True)
    driver.get("https://gamer.com.tw/")
    if os.path.exists('cookies.pkl'):
        __color_print(0, "登入狀態", detail='找到cookie檔案', no_sn=True)
        cookies = pickle.load(open("cookies.pkl", "rb"))
        for cookie in cookies:
            driver.add_cookie(cookie)
    driver.get("https://user.gamer.com.tw/login.php")
    time.sleep(1)
    # todo: 偵測效果不好，之後換方法
    if driver.current_url != 'https://user.gamer.com.tw/login.php':
        # already logined
        return True
    user_input = driver.find_element(By.XPATH, '//*[@id="form-login"]/input[1]')
    pass_input = driver.find_element(By.XPATH, '//*[@id="form-login"]/div[1]/input')
    login_button = driver.find_element(By.XPATH, '//*[@id="btn-login"]')
    user_input.send_keys(username)
    pass_input.send_keys(password)
    try:
        solver = RecaptchaSolver(driver=driver)
        recaptcha_iframe = driver.find_element(By.XPATH, '//iframe[@title="reCAPTCHA"]')
        solver.click_recaptcha_v2(iframe=recaptcha_iframe)
    except NoSuchElementException:
        pass
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
        if login(driver, username, password, save_cookie):
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


if __name__ == "__main__":
    if len(sys.argv) < 5:
        print("Usage:", sys.argv[0], "[username] [password] [headless?] [save_cookie?]\nreturns raw cookie.\n? = [true/false]")
        exit(1)
    stat = do_all(sys.argv[1], sys.argv[2], bool(sys.argv[3]), bool(sys.argv[4]))
    if stat:
        print(stat)
        exit(0)
    else:
        print("ERROR: Get raw cookie failed.")
        exit(1)
