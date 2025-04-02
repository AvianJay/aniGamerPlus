#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 動畫瘋一直把我登出所以加這個 ;(
from selenium import webdriver
from selenium.common import NoSuchElementException, ElementNotInteractableException
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.common.by import By
from selenium.webdriver import Keys, ActionChains
from selenium.webdriver.support.ui import Select
from webdriver_manager.chrome import ChromeDriverManager
from selenium.webdriver.chrome.options import Options
from selenium_recaptcha_solver import RecaptchaSolver
import time
import sys
import os
import pickle
import Config

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
    ua = settings['ua']
    opt = webdriver.ChromeOptions()
    if headless:
        opt.add_argument('--headless')
    opt.add_argument(f'--user-agent={ua}')
    if settings['auto_login']['use_wdm']:
        return webdriver.Chrome(service=ChromeService(ChromeDriverManager().install()), options=opt)
    else:
        return webdriver.Chrome(options=opt)


def login(driver, username, password, save_cookie=False):
    __color_print(0, "登入狀態", detail='正在登入', no_sn=True)
    driver.get("https://user.gamer.com.tw/login.php")
    if os.path.exists('cookies.pkl'):
        __color_print(0, "登入狀態", details='找到cookie檔案', no_sn=True)
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
    login_button.click()
    time.sleep(.5)
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


def do_all(username, password, headless, save_cookie):
    try:
        driver = get_driver(headless)
    except Exception as e:
        __color_print(0, "登入狀態", detail='啟動瀏覽器時發生異常: ' + e, status=1, no_sn=True)
        return False
    try:
        if login(driver, username, password, save_cookie):
            raw_cookie = get_raw_cookie(driver)
        else:
            raw_cookie = False
        driver.close()
        return raw_cookie
    except Exception as e:
        __color_print(0, "登入狀態", detail='登入時發生異常: ' + e, status=1, no_sn=True)
        return False


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
