#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 動畫瘋一直把我登出所以加這個 ;(
import sys
import os
import pickle
import Config
import nodriver as uc

# stolen from Config.py lol
def __color_print(sn, err_msg, detail='', status=0, no_sn=False, display=True):
    # 避免与 ColorPrint.py 相互调用产生问题
    try:
        err_print(sn, err_msg, detail=detail, status=status, no_sn=no_sn, display=display)
    except UnboundLocalError:
        from ColorPrint import err_print
        err_print(sn, err_msg, detail=detail, status=status, no_sn=no_sn, display=display)


async def get_driver(headless=False):
    __color_print(0, "登入狀態", detail='正在啟動瀏覽器', no_sn=True)
    settings = Config.read_settings()
    ua = settings['ua']
    browser_args = [f'--user-agent={ua}']
    if headless:
        browser_args.append('--headless=new')
    return await uc.start(headless=headless, browser_args=browser_args, no_sandbox=True, disable_gpu=True)


async def login(browser, username, password, save_cookie=False):
    __color_print(0, "登入狀態", detail='正在登入', no_sn=True)
    await browser.get("https://gamer.com.tw/")
    if os.path.exists('cookies.pkl'):
        __color_print(0, "登入狀態", detail='找到cookie檔案', no_sn=True)
        try:
            await browser.cookies.load('cookies.pkl')
        except Exception:
            # Backward compatibility: old selenium cookies.pkl might not match nodriver format.
            pass

    page = await browser.get("https://user.gamer.com.tw/login.php")
    await page.sleep(1)
    await page

    current_url = getattr(page, 'url', '') or ''
    # todo: 偵測效果不好，之後換方法
    if current_url != 'https://user.gamer.com.tw/login.php':
        # already logined
        return True

    user_input = await page.select('#form-login input[type="text"]')
    pass_input = await page.select('#form-login input[type="password"]')
    login_button = await page.select('#btn-login')

    await user_input.send_keys(username)
    await pass_input.send_keys(password)

    try:
        await page.cf_verify()
    except Exception:
        pass

    await login_button.click()
    await page.sleep(5)
    await page
    current_url = getattr(page, 'url', '') or ''

    if current_url == 'https://user.gamer.com.tw/login.php':
        # 還在登入頁面
        message = await page.select('#loginFormDiv > div.caption-text.red.margin-bottom.msgdiv-alert')
        message_text = message.text if message else ''
        if message_text != "":
            __color_print(0, "登入狀態", detail='錯誤: ' + message_text, no_sn=True, status=1)
            return False
        else:
            __color_print(0, "登入狀態", detail='登入時可能發生驗證問題', no_sn=True, status=1)
            # todo: 處理2fa
            return False

    __color_print(0, "登入狀態", detail='登入成功', no_sn=True, status=2)
    if save_cookie:
        __color_print(0, "登入狀態", detail='正在儲存cookie', no_sn=True)
        try:
            await browser.cookies.save('cookies.pkl')
        except Exception:
            # Fallback for compatibility: if nodriver cookie save fails, keep legacy pickle dump.
            raw_cookies = await browser.cookies.get_all()
            with open('cookies.pkl', 'wb') as cookie_fp:
                pickle.dump(raw_cookies, cookie_fp)
    return True


async def get_raw_cookie(browser):
    await browser.get("https://ani.gamer.com.tw")
    cookies = await browser.cookies.get_all()
    cookies_raw = ""
    for cookie in cookies:
        if hasattr(cookie, 'name') and hasattr(cookie, 'value'):
            cookies_raw += f"{cookie.name}={cookie.value}; "
        elif isinstance(cookie, dict) and 'name' in cookie and 'value' in cookie:
            cookies_raw += f"{cookie['name']}={cookie['value']}; "
    cookies_raw = cookies_raw.rstrip("; ")
    return cookies_raw


async def _do_all_async(username, password, headless, save_cookie):
    browser = None
    try:
        browser = await get_driver(headless)
    except Exception as e:
        __color_print(0, "登入狀態", detail='啟動瀏覽器時發生異常: ' + str(e), status=1, no_sn=True)
        return False

    try:
        if await login(browser, username, password, save_cookie):
            return await get_raw_cookie(browser)
        return False
    except Exception as e:
        __color_print(0, "登入狀態", detail='登入時發生異常: ' + str(e), status=1, no_sn=True)
        return False
    finally:
        if browser:
            try:
                browser.stop()
            except Exception:
                pass


def do_all(username, password, headless, save_cookie):
    return uc.loop().run_until_complete(_do_all_async(username, password, headless, save_cookie))


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
