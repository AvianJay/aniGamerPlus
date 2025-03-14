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
import time
import sys
import os
import pickle


def get_driver(headless=False):
    opt = webdriver.ChromeOptions()
    if headless:
        opt.add_argument('--headless')
    return webdriver.Chrome(service=ChromeService(ChromeDriverManager().install(), options=opt))


def login(driver, username, password, save_cookie=False):
    if os.path.exists('cookies.pkl'):
        print('INFO: Found cookie file. Restoring...')
        cookies = pickle.load(open("cookies.pkl", "rb"))
        for cookie in cookies:
            driver.add_cookie(cookie)
    driver.get("https://user.gamer.com.tw/login.php")
    time.sleep(1)
    if driver.current_url != 'https://user.gamer.com.tw/login.php':
        # already logined
        return True
    user_input = driver.find_element(By.XPATH, '//*[@id="form-login"]/input[1]')
    pass_input = driver.find_element(By.XPATH, '//*[@id="form-login"]/div[1]/input')
    login_button = driver.find_element(By.XPATH, '//*[@id="btn-login"]')
    user_input.send_keys(username)
    pass_input.send_keys(password)
    login_button.click()
    time.sleep(.5)
    if driver.current_url == 'https://user.gamer.com.tw/login.php':
        # 還在登入頁面
        message = driver.find_element(By.CSS_SELECTOR, '#loginFormDiv > div.caption-text.red.margin-bottom.msgdiv-alert')
        if message != "":
            print("ERROR:", message)
            return False
        else:
            print("INFO: 2fa?")
    print("INFO: Logined")
    if save_cookie:
        print("INFO: Saving cookie...")
        pickle.dump(driver.get_cookies(), open("cookies.pkl", "wb"))
    return True


def get_raw_cookie(driver):
    driver.get("https://ani.gamer.com.tw")
    cookies = driver.get_cookies()
    cookies_raw = ""
    for cookie in cookies:
        cookies_raw += f"{cookie["name"]}={cookie["value"]}; "
    cookies_raw.strip("; ")
    return cookies_raw


if __name__ == "__main__":
    if len(sys.argv) < 5:
        print("Usage:", sys.argv[0], "[username] [password] [headless?] [save_cookie?]\nreturns raw cookie.\n? = [true/false]")
        exit(1)
    driver = get_driver(bool(sys.argv[3]))
    if login(driver, sys.argv[1], sys.argv[2], bool(sys.argv[4])):
        print(get_raw_cookie(driver))
        exit(0)
    else:
        print("ERROR: Get raw cookie failed.")
        exit(1)
