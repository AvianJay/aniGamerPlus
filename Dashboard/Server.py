#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# @Time    : 2019/6/26 16:12
# @Author  : Miyouzi
# @File    : Server.py
# @Software: PyCharm

# 非阻塞
from gevent import monkey; monkey.patch_all()
from gevent import spawn, get_hub, sleep as gevent_sleep

import json, sys, os, re, time
import threading, traceback
import random, string, hashlib, secrets
import platform, shutil, subprocess

from curl_cffi import requests as curl_requests
from aniGamerPlus import Config
from flask import Flask, request, jsonify, Response, redirect, make_response, g
from flask import render_template, send_file, stream_with_context
from aniGamerPlus import __cui as cui
from aniGamerPlus import __get_danmu_only
import Catalog
import logging, termcolor
from ColorPrint import err_print
from logging.handlers import TimedRotatingFileHandler
import mimetypes
from werkzeug.http import http_date
from werkzeug.security import generate_password_hash, check_password_hash
import urllib.parse
from functools import wraps
# ws 支持
import ssl
from flask_sock import Sock
from gevent.pywsgi import WSGIServer
from geventwebsocket.exceptions import WebSocketError
from geventwebsocket.handler import WebSocketHandler
from datetime import datetime
from plugin_system import PluginManager

mimetypes.add_type('text/css', '.css')
mimetypes.add_type('application/x-javascript', '.js')
template_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'templates')
static_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'static')
app = Flask(__name__, template_folder=template_path, static_folder=static_path)
app.debug = False
sock = Sock(app)

# 日志处理
# logger = logging.getLogger('werkzeug')
logger = logging.getLogger('geventwebsocket')
logging.basicConfig(level=logging.INFO)  # 记录访问
web_log_path = os.path.join(Config.get_working_dir(), 'logs', 'web.log')
handler = TimedRotatingFileHandler(filename=web_log_path, when='midnight', backupCount=7, encoding='utf-8')
handler.suffix = '%Y-%m-%d.log'
handler.extMatch = re.compile(r'^\d{4}-\d{2}-\d{2}.log')
logger.addHandler(handler)
logger.propagate = False  # 不在控制台上输出

# websocket鉴权需要的 token, 随机一个 32 位初始 token
websocket_token = ''.join(random.sample(string.ascii_letters + string.digits, 32))


# 处理 Flask 写日志到文件带有颜色控制符的问题
def colored(text, color=None, on_color=None, attrs=None):
    who_invoked = traceback.extract_stack()[-2][2]  # 函数调用人
    if who_invoked == 'log_request':
        # 如果是来自 Flask/werkzeug 的调用
        return text
    else:
        # 来自其他的调用正常高亮
        COLORS = termcolor.COLORS
        HIGHLIGHTS = termcolor.HIGHLIGHTS
        ATTRIBUTES = termcolor.ATTRIBUTES
        RESET = termcolor.RESET
        if os.getenv('ANSI_COLORS_DISABLED') is None:
            fmt_str = '\033[%dm%s'
            if color is not None:
                text = fmt_str % (COLORS[color], text)
            if on_color is not None:
                text = fmt_str % (HIGHLIGHTS[on_color], text)
            if attrs is not None:
                for attr in attrs:
                    text = fmt_str % (ATTRIBUTES[attr], text)
            text += RESET
        return text


termcolor.colored = colored
app.logger.addHandler(handler)


# ssl log ignore
class SafeWebSocketHandler(WebSocketHandler):
    def log_exception(self, exc_info):
        if isinstance(exc_info[1], ssl.SSLEOFError):
            # print("[忽略] SSL EOF 發生，來自客戶端非正常斷開")
            pass
        else:
            super().log_exception(exc_info)


def generate_file(path, start, length, chunk_size=8192):
    """逐步讀取檔案 (generator)，避免一次讀整份進 memory"""
    with open(path, 'rb') as f:
        f.seek(start)
        remaining = length
        while remaining > 0:
            read_size = min(chunk_size, remaining)
            data = f.read(read_size)
            if not data:
                break
            yield data
            remaining -= len(data)


def get_file_headers(path):
    """產生 ETag 和 Last-Modified"""
    stat = os.stat(path)

    # Last-Modified
    last_modified = http_date(stat.st_mtime)

    # ETag (依檔案大小 + 修改時間)
    etag_base = f"{stat.st_mtime}-{stat.st_size}".encode()
    etag = hashlib.md5(etag_base).hexdigest()

    return etag, last_modified, stat.st_size


def _apply_cache_headers(resp, current_settings, max_age):
    # 要登入才能看的片库不能标成 public: 前面挂个共用快取 (Cloudflare 之类),
    # 登入用户抓过的东西就会被原样发给没 cookie 的人
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Cache-Control'] = 'private, max-age=%d' % max_age
        resp.headers['Vary'] = 'Cookie'
    else:
        resp.headers['Cache-Control'] = 'public, max-age=%d' % max_age
    return resp


# aniGamerPlus 啟動時會用真正的 checknow 蓋掉這個佔位, 單獨跑 Server.py 時它就
# 什麼都不做. 兩邊的簽名必須一致, 否則 /checknow 只會拋 TypeError.
checknow = lambda: None
command_handler = None
userdata_lock = threading.Lock()
userdata_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json')
PLUGIN_RELOAD_INTERVAL_SECONDS = 30


def _generate_token():
    return secrets.token_urlsafe(32)


def _normalize_username(value):
    return str(value or '').strip()


def _normalize_role(value):
    return 'admin' if str(value).lower() == 'admin' else 'user'


def _hash_password(password):
    return generate_password_hash(str(password))


def _verify_password(user, password):
    password = str(password or '')
    password_hash = user.get('password_hash')
    if password_hash and check_password_hash(password_hash, password):
        return True
    legacy_password = user.get('password')
    return legacy_password is not None and secrets.compare_digest(str(legacy_password), password)


def _normalize_user(user, fallback_role='user'):
    changed = False
    normalized = dict(user or {})

    username = normalized.get('username', normalized.get('name'))
    username = _normalize_username(username)
    if normalized.get('username') != username:
        normalized['username'] = username
        changed = True
    if 'name' in normalized:
        normalized.pop('name', None)
        changed = True

    role = _normalize_role(normalized.get('role', fallback_role))
    if normalized.get('role') != role:
        normalized['role'] = role
        changed = True

    if not isinstance(normalized.get('videotimes'), dict):
        normalized['videotimes'] = {}
        changed = True

    if not isinstance(normalized.get('token'), str) or not normalized.get('token'):
        normalized['token'] = _generate_token()
        changed = True

    if not normalized.get('password_hash') and normalized.get('password') is not None:
        normalized['password_hash'] = _hash_password(normalized.get('password'))
        changed = True
    if normalized.get('password_hash') and 'password' in normalized:
        normalized.pop('password', None)
        changed = True

    return normalized, changed


def _build_default_user(default_user):
    normalized, _ = _normalize_user(default_user, default_user.get('role', 'user'))
    if not normalized.get('password_hash'):
        normalized['password_hash'] = _hash_password(default_user.get('password', 'admin'))
    normalized.pop('password', None)
    return normalized


def save_user_data(userdata):
    with userdata_lock:
        with open(userdata_path, 'w', encoding='utf-8') as f:
            json.dump(userdata, f, ensure_ascii=False, indent=4)


def load_user_data():
    settings = Config.read_settings()
    default_users = settings['dashboard']['user_control']['default_user']
    changed = False

    if os.path.exists(userdata_path):
        try:
            with open(userdata_path, 'r', encoding='utf-8') as f:
                userdata = json.load(f)
        except (json.JSONDecodeError, OSError, ValueError):
            userdata = {"users": []}
            changed = True
    else:
        userdata = {"users": []}
        changed = True

    raw_users = userdata.get('users')
    if not isinstance(raw_users, list):
        raw_users = []
        changed = True

    users = []
    existing_by_name = {}
    for raw_user in raw_users:
        normalized_user, user_changed = _normalize_user(raw_user)
        if not normalized_user['username']:
            changed = True
            continue
        user_key = normalized_user['username'].lower()
        if user_key in existing_by_name:
            changed = True
            continue
        users.append(normalized_user)
        existing_by_name[user_key] = normalized_user
        changed = changed or user_changed

    for default_user in default_users:
        normalized_default = _build_default_user(default_user)
        user_key = normalized_default['username'].lower()
        existing_user = existing_by_name.get(user_key)
        if existing_user is None:
            users.append(normalized_default)
            existing_by_name[user_key] = normalized_default
            changed = True
            continue
        default_role = normalized_default.get('role', 'user')
        if existing_user.get('role') != default_role:
            existing_user['role'] = default_role
            changed = True

    userdata = {"users": users}
    if changed:
        save_user_data(userdata)
    return userdata


def find_user_by_token(token, userdata=None):
    if not token:
        return None
    userdata = userdata or load_user_data()
    for user in userdata['users']:
        if user.get('token') == token:
            return user
    return None


def find_user_by_username(username, userdata=None):
    username = _normalize_username(username)
    if not username:
        return None
    userdata = userdata or load_user_data()
    for user in userdata['users']:
        if user.get('username', '').lower() == username.lower():
            return user
    return None


def verify_user(cookies):
    user = find_user_by_token(cookies.get('token'))
    if not user:
        return False, None
    return True, user["role"]


def _set_login_cookies(response, token):
    secure_cookie = bool(Config.read_settings()['dashboard'].get('SSL'))
    response.set_cookie('token', token, max_age=60 * 60 * 24 * 30, httponly=True, samesite='Lax', secure=secure_cookie)
    response.set_cookie('logined', 'true', max_age=60 * 60 * 24 * 30, httponly=False, samesite='Lax', secure=secure_cookie)
    return response


def _clear_login_cookies(response):
    response.delete_cookie('token')
    response.delete_cookie('logined')
    return response


def user_page_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not Config.read_settings()['dashboard']['user_control']['enabled']:
            return view(*args, **kwargs)
        user = find_user_by_token(request.cookies.get('token'))
        if not user:
            return redirect("./login?error=2")
        g.current_user = user
        return view(*args, **kwargs)
    return wrapped


def admin_page_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not Config.read_settings()['dashboard']['user_control']['enabled']:
            return view(*args, **kwargs)
        user = find_user_by_token(request.cookies.get('token'))
        if not user:
            return redirect("./login?error=2")
        if user.get('role') != 'admin':
            destination = "./watch" if Config.read_settings()['dashboard'].get('online_watch') else "/"
            return redirect(destination)
        g.current_user = user
        return view(*args, **kwargs)
    return wrapped


def admin_api_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not Config.read_settings()['dashboard']['user_control']['enabled']:
            return view(*args, **kwargs)
        user = find_user_by_token(request.cookies.get('token'))
        if not user:
            return jsonify({'success': False, 'message': 'login required'}), 401
        if user.get('role') != 'admin':
            return jsonify({'success': False, 'message': 'admin required'}), 403
        g.current_user = user
        return view(*args, **kwargs)
    return wrapped


def _handle_web_console_command():
    payload = request.get_json(silent=True) or {}
    raw_command = str(payload.get('command', '')).strip()
    if not raw_command:
        return jsonify({'success': False, 'message': '請輸入指令'}), 400

    if not callable(command_handler):
        return jsonify({'success': False, 'message': '指令處理器尚未初始化'}), 503

    try:
        result = command_handler(raw_command, show_detail=True)
    except BaseException as e:
        return jsonify({'success': False, 'message': str(e)}), 500

    success = bool(result.get('success', False))
    body = {
        'success': success,
        'message': result.get('message', ''),
    }
    if result.get('help', False):
        body['help'] = True
        body['commands'] = result.get('commands', [])

    err_print(0, 'Dashboard', f'通過 Web 控制臺執行指令: {raw_command}', no_sn=True, status=2 if success else 1)
    return jsonify(body), 200 if success else 400

caches = {}
danmu_update_timestamps = {}
DANMU_UPDATE_INTERVAL_SECONDS = 6 * 60 * 60


def _read_video_list_file():
    video_list_path = os.path.join(Config.get_working_dir(), 'video_list.json')
    if not os.path.exists(video_list_path):
        return {'videos': []}
    with open(video_list_path, 'r', encoding='utf-8') as f:
        return json.load(f)


def _find_video_entry(sn):
    video_data = _read_video_list_file()
    sn_str = str(sn)
    for video in video_data.get('videos', []):
        if str(video.get('sn')) == sn_str:
            return video
    return None


_ffmpeg_path_cache = None
_ffmpeg_missing_logged = False
_keyed_locks = {}
_keyed_locks_guard = threading.Lock()
_thumbnail_failures = {}

# 官方的每集封面, 12 小时够新了
ANIME_INFO_TTL = 12 * 60 * 60
ANIME_INFO_API = 'https://api.gamer.com.tw/anime/v1/video.php?videoSn='
# 只有从动画疯下的集数才有官方封面, 本地导入的 sn 是 aniGamerPlus 自己编的
BAHAMUT_SOURCE = '巴哈姆特動畫瘋'
# 抓不到就先记着, 否则首页每重绘一次 (搜索框每敲一个字) 就重来一轮上游请求
THUMBNAIL_RETRY_INTERVAL = 10 * 60
# 片单缓存: 首页那几个分区每天都在动, 全站列表一天爬一次就够
CATALOG_INDEX_TTL = 60 * 60
CATALOG_ALL_TTL = 24 * 60 * 60
# animeSn -> videoSn 中间隔一个 301, 一部作品的第一集不会变, 存久一点
CATALOG_REF_TTL = 30 * 24 * 60 * 60
# 一页一页翻, 中间歇一下. 并发翻页会被巴哈用 429 挡回来
CATALOG_CRAWL_DELAY = 0.25
# 爬缺了几页的片单只留一会儿, 好过顶着一天的有效期发一份不全的出去
CATALOG_PARTIAL_TTL = 10 * 60
CATALOG_PAGE_SIZE = 28


def _keyed_lock(name):
    # 同一集同时被多个卡片请求时, 只干一次活
    with _keyed_locks_guard:
        if name not in _keyed_locks:
            _keyed_locks[name] = threading.Lock()
        return _keyed_locks[name]


def _offload(func, *args, **kwargs):
    # curl_cffi 的 socket I/O 在 C 里, monkey.patch_all 管不到, 直接在 greenlet
    # 里调用会把整个 hub 停住 —— 下载器、WebSocket 进度、别的请求全一起冻结.
    # 它在 libcurl perform 期间放开 GIL, 丢进 gevent 的真线程池就不挡别人.
    return get_hub().threadpool.apply(func, args, kwargs)


def _curl_perform(session_kwargs, url, request_kwargs):
    session = curl_requests.Session(**session_kwargs)
    return session.request('get', url, **request_kwargs)


def _bahamut_get(url, timeout=10, allow_redirects=True):
    """跟 Config.bahamut_request 用同一套指纹, 但配置在 greenlet 上读完再下线程池.

    read_settings() 顺手会删过期日志、必要时重写配置文件, 这些副作用一直只在
    greenlet 里发生, 彼此不会交错; 搬到线程池里就可能两个线程同时删同一个文件.
    所以线程池那一步只留 libcurl 的 perform.
    """
    settings = Config.read_settings()
    fingerprint = settings.get('browser_fingerprint') or {}
    session_kwargs = {
        'impersonate': 'firefox' if 'firefox' in settings['ua'].lower() else 'chrome',
        'ja3': fingerprint.get('ja3') or None,
        'akamai': fingerprint.get('akamai') or None,
    }
    request_kwargs = {'headers': {'User-Agent': settings['ua']}, 'timeout': timeout}
    if not allow_redirects:
        request_kwargs['allow_redirects'] = False
    if settings.get('use_proxy') and settings.get('proxy'):
        request_kwargs['proxies'] = {'https': settings['proxy'], 'http': settings['proxy']}
    return _offload(_curl_perform, session_kwargs, url, request_kwargs)


def _get_ffmpeg_path():
    # 与 Anime.py 一致: 先看系统 path, 再看工作目录
    global _ffmpeg_path_cache, _ffmpeg_missing_logged
    if not _ffmpeg_path_cache:  # 找不到时不记进缓存, 中途装上的 ffmpeg 才认得出来
        found = shutil.which('ffmpeg') or ''
        if not found:
            local = os.path.join(Config.get_working_dir(),
                                 'ffmpeg.exe' if 'Windows' in platform.system() else 'ffmpeg')
            found = local if os.path.exists(local) else ''
        _ffmpeg_path_cache = found
        if not found and not _ffmpeg_missing_logged:
            _ffmpeg_missing_logged = True  # 只吼一次, 不然每张卡片刷一行
            err_print(0, '縮圖功能', '縮圖依賴於ffmpeg, 但ffmpeg未找到', status=1, no_sn=True)
    return _ffmpeg_path_cache


def _thumbnail_cache_path(sn):
    cache_dir = os.path.join(Config.get_working_dir(), 'thumbnails')
    if not os.path.exists(cache_dir):
        os.makedirs(cache_dir, exist_ok=True)
    return os.path.join(cache_dir, re.sub(r'[^0-9A-Za-z]', '', str(sn)) + '.jpg')


def _make_thumbnail(video_path, output_path):
    ffmpeg = _get_ffmpeg_path()
    if not ffmpeg:
        return False
    tmp_path = output_path + '.tmp.jpg'
    # 4 分钟处通常已过 OP, 片子太短就依次往前退
    for seek in ('240', '30', '0'):
        try:
            subprocess.call([ffmpeg, '-y', '-loglevel', 'error', '-ss', seek,
                             '-i', video_path, '-frames:v', '1',
                             '-vf', 'scale=960:-2', '-q:v', '4', tmp_path],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except BaseException:
            err_print(0, '縮圖錯誤', traceback.format_exc(), status=1, no_sn=True, display=False)
            return False
        if os.path.exists(tmp_path) and os.path.getsize(tmp_path) > 0:
            os.replace(tmp_path, output_path)
            return True
    if os.path.exists(tmp_path):
        os.remove(tmp_path)
    return False


def _anime_info_cache_path(sn):
    cache_dir = os.path.join(Config.get_working_dir(), 'anime_info')
    if not os.path.exists(cache_dir):
        os.makedirs(cache_dir, exist_ok=True)
    return os.path.join(cache_dir, re.sub(r'[^0-9]', '', str(sn)) + '.json')


def _read_anime_info_cache(cache_path):
    if not os.path.exists(cache_path):
        return None
    if time.time() - os.path.getmtime(cache_path) >= ANIME_INFO_TTL:
        return None
    try:
        with open(cache_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except BaseException:
        return None  # 缓存坏了就当没有, 重新抓


def _get_anime_info(sn):
    """动画疯官方的单集资讯: 标题, 集数表, 每集封面, 上架时间.

    走服务端而不是浏览器, 是因为这个 api 不发 CORS 头, 而公用的 cors 代理
    现在要 api key 了. 服务端本来就在跟巴哈说话, 顺手转发一下最省事, 还能
    落盘缓存, 首页几十张卡片不会去捶人家的 api.
    """
    cache_path = _anime_info_cache_path(sn)
    cached = _read_anime_info_cache(cache_path)
    if cached is not None:
        return cached

    with _keyed_lock('info-' + str(sn)):
        cached = _read_anime_info_cache(cache_path)
        if cached is not None:
            return cached
        try:
            resp = _bahamut_get(ANIME_INFO_API + str(sn), timeout=10)
            data = (resp.json() or {}).get('data')
        except BaseException:
            err_print(sn, '取得動畫資訊失敗', traceback.format_exc(), status=1, display=False)
            return None
        if not data:
            return None
        try:
            with open(cache_path, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False)
        except BaseException:
            pass  # 缓存写不进去不影响这次返回
        return data


# videoSn -> 哪一份 anime_info 快取裡列著這一集. 邊看邊下載按下去的那一瞬間,
# 那一集既不在片庫也還沒進 tasks_progress_rate, 這張表是當下唯一認得它的東西
_EPISODE_OWNERS = {'stamp': None, 'map': {}}


def _episode_owners():
    """把快取過的集數表反過來排: 一集的 videoSn 查得到它屬於哪一部作品.

    指紋要戴上 mtime: 新一集上架時 anime_info 是原檔覆寫, 檔名不變, 只比
    檔名的話那一集就永遠進不了這張表。
    """
    cache_dir = os.path.join(Config.get_working_dir(), 'anime_info')
    try:
        names = sorted(name for name in os.listdir(cache_dir) if name.endswith('.json'))
        stamp = tuple((name, os.path.getmtime(os.path.join(cache_dir, name)))
                      for name in names)
    except OSError:
        return {}
    if _EPISODE_OWNERS['stamp'] == stamp:
        return _EPISODE_OWNERS['map']

    owners = {}
    for name in names:
        info = _read_anime_info_cache(os.path.join(cache_dir, name))
        for episodes in (((info or {}).get('anime') or {}).get('episodes') or {}).values():
            for episode in episodes or []:
                video_sn = str(episode.get('videoSn') or '')
                if video_sn:
                    owners.setdefault(video_sn, name[:-len('.json')])
    _EPISODE_OWNERS['stamp'] = stamp
    _EPISODE_OWNERS['map'] = owners
    return owners


def _catalog_cache_path(name):
    cache_dir = os.path.join(Config.get_working_dir(), 'catalog')
    if not os.path.exists(cache_dir):
        os.makedirs(cache_dir, exist_ok=True)
    return os.path.join(cache_dir, re.sub(r'[^0-9a-z_]', '', str(name)) + '.json')


def _read_catalog_cache(name, ttl):
    # ttl 传 0 就是不看新旧: 上游抓挂了的时候, 端一份过期的出去也比开天窗强
    path = _catalog_cache_path(name)
    if not os.path.exists(path):
        return None
    if ttl and time.time() - os.path.getmtime(path) >= ttl:
        return None
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except BaseException:
        return None


def _write_catalog_cache(name, payload):
    try:
        with open(_catalog_cache_path(name), 'w', encoding='utf-8') as f:
            json.dump(payload, f, ensure_ascii=False)
    except BaseException:
        pass  # 写不进去不影响这次返回, 下次再抓一遍就是


def _get_catalog_index():
    """首页那几个分区: 本季新番 / 更新時間表 / 近期熱播 / 最新上架."""
    cached = _read_catalog_cache('index', CATALOG_INDEX_TTL)
    if cached is not None:
        return cached
    with _keyed_lock('catalog-index'):
        cached = _read_catalog_cache('index', CATALOG_INDEX_TTL)
        if cached is not None:
            return cached
        try:
            payload = Catalog.parse_index(_bahamut_get(Catalog.INDEX_API, timeout=15).json())
        except BaseException:
            err_print(0, '取得動畫瘋片單失敗', traceback.format_exc(),
                      status=1, no_sn=True, display=False)
            return _read_catalog_cache('index', 0)
        _write_catalog_cache('index', payload)
        return payload


def _fetch_list_html(page):
    """animeList.php 的一页. 吃到 429 就退一步再来."""
    status = 0
    delay = 1.0
    for attempt in range(3):
        resp = _bahamut_get(Catalog.list_page_url(page), timeout=15)
        status = resp.status_code
        if status == 200:
            return resp.text
        if status != 429:
            break
        gevent_sleep(delay)
        delay *= 2
    raise IOError('animeList.php page %d: HTTP %s' % (page, status))


def _crawl_catalog_all():
    """全站片单, 一页 28 部, 六十几页.

    顺着一页页爬而不是并发抓: 并发翻页会被巴哈整片 429 挡掉, 而被挡掉的页
    如果当空页收下, 存进缓存的就是一份缺了几百部的片单 —— 还顶着一天的有效
    期, 比慢一点难受得多. 所以缺页要记下来, 交给上面决定这份能不能久留.
    """
    html = _fetch_list_html(1)
    items = Catalog.parse_list_page(html)
    total = Catalog.total_pages(html)
    missing = []
    for page in range(2, total + 1):
        gevent_sleep(CATALOG_CRAWL_DELAY)
        try:
            items.extend(Catalog.parse_list_page(_fetch_list_html(page)))
        except BaseException:
            missing.append(page)

    seen = set()
    unique = []
    for item in items:
        if item['animeSn'] and item['animeSn'] not in seen:
            seen.add(item['animeSn'])
            unique.append(item)
    if missing:
        err_print(0, '片單有幾頁沒抓到', '第 ' + ', '.join(map(str, missing)) + ' 頁',
                  status=1, no_sn=True, display=False)
    return {'items': unique, 'complete': not missing, 'totalPages': total}


def _catalog_all_is_fresh(payload):
    # 缺页的那份只当短期货, 到点就再爬一次
    if not payload:
        return False
    age = time.time() - os.path.getmtime(_catalog_cache_path('all'))
    return age < (CATALOG_ALL_TTL if payload.get('complete') else CATALOG_PARTIAL_TTL)


def _refresh_catalog_all():
    with _keyed_lock('catalog-all'):
        cached = _read_catalog_cache('all', 0)
        if _catalog_all_is_fresh(cached):
            return cached
        try:
            payload = _crawl_catalog_all()
        except BaseException:
            err_print(0, '取得動畫瘋全站片單失敗', traceback.format_exc(),
                      status=1, no_sn=True, display=False)
            return cached
        if not payload['items']:
            return cached
        _write_catalog_cache('all', payload)
        return payload


def _get_catalog_all():
    """全站片单. 第一次要爬满六十几页, 之后都是拿缓存.

    过期了先把旧的端出去, 更新丢到后台: 这个列表一天才动一次, 没必要让谁
    等上二十几秒只为了看到几乎一样的东西.
    """
    cached = _read_catalog_cache('all', 0)
    if _catalog_all_is_fresh(cached):
        return cached.get('items') or []
    if cached and cached.get('items'):
        spawn(_refresh_catalog_all)
        return cached.get('items') or []
    return (_refresh_catalog_all() or {}).get('items') or []


def _resolve_video_sn(anime_sn):
    """animeSn 认的是作品, videoSn 才是能播能下的那一集, 中间隔一个 301."""
    anime_sn = str(anime_sn)
    cached = (_read_catalog_cache('ref', CATALOG_REF_TTL) or {}).get(anime_sn)
    if cached:
        return cached
    with _keyed_lock('catalog-ref-' + anime_sn):
        cached = (_read_catalog_cache('ref', CATALOG_REF_TTL) or {}).get(anime_sn)
        if cached:
            return cached
        try:
            resp = _bahamut_get(Catalog.REF_URL + anime_sn, timeout=10, allow_redirects=False)
            video_sn = Catalog.parse_video_sn(resp.headers.get('Location') or '')
        except BaseException:
            err_print(anime_sn, '解析作品編號失敗', traceback.format_exc(),
                      status=1, display=False)
            return ''
        if video_sn:
            # 整份表是一个文件, 读改写要单独串起来, 否则两部作品同时解析会丢掉一条
            with _keyed_lock('catalog-ref-write'):
                refs = _read_catalog_cache('ref', CATALOG_REF_TTL) or {}
                refs[anime_sn] = video_sn
                _write_catalog_cache('ref', refs)
        return video_sn


def _catalog_knows(anime_sn):
    """只认片单里出现过的作品.

    这个路由会替浏览器去抓巴哈, 不限住就成了打向人家 api 的请求放大器 ——
    跟 /anime_info、/thumbnail.jpg 里那两道 "不在片库就不转发" 是同一个道理,
    只是这里的边界从本地片库换成了片单本身.
    """
    target = str(anime_sn)
    for item in _get_catalog_all() or []:
        if item.get('animeSn') == target:
            return True
    index = _get_catalog_index() or {}
    for name in ('season', 'hot', 'newAdded'):
        for item in index.get(name) or []:
            if item.get('animeSn') == target:
                return True
    return False


def _local_episode_map():
    # 详情页要标出哪几集已经在本地了, 键跟 _find_video_entry 一样用字符串 sn
    entries = {}
    for video in (_read_video_list_file().get('videos') or []):
        entries[str(video.get('sn'))] = video
    return entries


def _catalog_episodes(info):
    """把官方那份按类型分组的集数表摊平, 顺手标上本地有没有."""
    local = _local_episode_map()
    anime = (info or {}).get('anime') or {}
    groups = []
    raw_groups = anime.get('episodes') or {}
    for name in sorted(raw_groups.keys()):
        episodes = []
        for episode in raw_groups.get(name) or []:
            video_sn = str(episode.get('videoSn') or '')
            entry = local.get(video_sn)
            episodes.append({
                'videoSn': video_sn,
                'episode': episode.get('episode') or '',
                'cover': episode.get('cover') or '',
                'local': entry is not None,
                'resolution': (entry or {}).get('resolution') or 0,
            })
        if episodes:
            groups.append({
                'name': Catalog.EPISODE_TYPES.get(str(name), str(name)),
                'episodes': episodes,
            })
    return groups


def _catalog_login_error(current_settings):
    # 片单跟片库同一道门: 设了要登入才能看, 片单也不该是敞开的
    if current_settings['dashboard']['online_watch_requires_login']:
        vaild_user, user_role = verify_user(request.cookies)
        if not vaild_user:
            return jsonify({"error": "login required"}), 403
    return None



def _build_thumbnail(sn, cache_path, entry):
    """官方封面优先, 抽帧兜底.

    官方封面是那一集的宣传图, 比从片子里随便抓的一帧好看得多. 抽帧留着应付
    官方没图、api 挂了、或者片子根本不是从动画疯下的情况.
    """
    # 本地导入的集数 sn 是 aniGamerPlus 自己编的, 拿去问巴哈只是白等一趟往返
    if entry.get('source') == BAHAMUT_SOURCE:
        cover_url = ((_get_anime_info(sn) or {}).get('video') or {}).get('cover') or ''
        if cover_url.strip():
            tmp_path = cache_path + '.tmp.jpg'
            try:
                resp = _bahamut_get(cover_url.strip(), timeout=15)
                if resp.status_code == 200 and resp.content:
                    with open(tmp_path, 'wb') as f:
                        f.write(resp.content)
                    os.replace(tmp_path, cache_path)
                    return True
            except BaseException:
                err_print(sn, '下載封面失敗', traceback.format_exc(), status=1, display=False)
            if os.path.exists(tmp_path):
                os.remove(tmp_path)

    video_path = entry.get('path')
    if not video_path or not os.path.exists(video_path):
        return False
    return _make_thumbnail(video_path, cache_path)


def _thumbnail_recently_failed(sn):
    return time.time() - _thumbnail_failures.get(str(sn), 0) < THUMBNAIL_RETRY_INTERVAL


def _thumbnail_unavailable():
    resp = jsonify({"error": "thumbnail unavailable"})
    # 让浏览器也记着这次没图, 否则首页每重绘一次就要再问服务端一遍
    resp.headers['Cache-Control'] = 'private, max-age=%d' % THUMBNAIL_RETRY_INTERVAL
    return resp, 404


def _should_update_danmu(sn):
    now = int(datetime.now().timestamp())
    last_updated = danmu_update_timestamps.get(str(sn), 0)
    return now - last_updated >= DANMU_UPDATE_INTERVAL_SECONDS


def _mark_danmu_updated(sn):
    danmu_update_timestamps[str(sn)] = int(datetime.now().timestamp())


def cache(id, time=600, set=None):
    now = int(datetime.now().timestamp())
    # Clean up expired cache
    if id in caches:
        if caches[id]["expire"] < now:
            del caches[id]
            return None
    if set is not None:
        caches[id] = {"expire": now + time, "data": set}
    return caches.get(id, {}).get("data")


def _get_current_settings():
    return Config.read_settings()


def _get_dashboard_flags(current_settings=None):
    current_settings = current_settings or _get_current_settings()
    dashboard_settings = current_settings.get('dashboard', {})
    user_control_settings = dashboard_settings.get('user_control', {})
    return {
        "user_control": user_control_settings.get('enabled', False),
        "user_control_allow_register": user_control_settings.get('allow_register', False),
        "online_watch": dashboard_settings.get('online_watch', False),
        "online_watch_requires_login": dashboard_settings.get('online_watch_requires_login', False),
    }


def _get_request_user(current_settings=None):
    current_settings = current_settings or _get_current_settings()
    if not current_settings.get('dashboard', {}).get('user_control', {}).get('enabled'):
        return None
    return find_user_by_token(request.cookies.get('token'))


def _build_safe_user(user):
    if not user:
        return None
    return {
        'username': user.get('username'),
        'role': user.get('role', 'user'),
    }


def _build_dashboard_bootstrap(extra=None, current_settings=None):
    current_settings = current_settings or _get_current_settings()
    user = _get_request_user(current_settings)
    bootstrap = {
        'serverInfo': _get_dashboard_flags(current_settings),
        'loggedIn': bool(user),
        'currentUser': _build_safe_user(user),
    }
    if extra:
        bootstrap.update(extra)
    return bootstrap


# ----------------------------------------------------------------- 邊看邊下載
# Anime.py 的 __segment_download_mode() 會把每一片 .ts 丟進 temp 下的一個目錄, 最後
# 才用 ffmpeg 合成 mp4. 也就是說, 下載到一半的集數在磁碟上本來就是一份 HLS 串流,
# 只要把已經落地的前綴當成 playlist 發出去, 就能邊下載邊看 —— 而且完全不必再跟
# 動畫瘋多要一份影片, 併發數跟帳號風險都跟原本的下載一模一樣.
HLS_TEMP_SUFFIX = '-downloading-by-aniGamerPlusPlus'
# key.m3u8key 是 Anime.py 自己取的檔名, 出現在 m3u8 裡就表示這份已經被改寫成
# 給 ffmpeg 吃的本機路徑版, 不能再發給瀏覽器
HLS_LOCALISED_MARKER = 'key.m3u8key'
HLS_SETTINGS_TTL = 5.0
HLS_MIME = 'application/vnd.apple.mpegurl'

_hls_settings_cache = {'at': 0.0, 'settings': None}
_hls_playlist_cache = {}  # sn(str) -> {'sig': (mtime, size), 'parsed': {...}}


def _hls_settings():
    # hls.js 每 5~10 秒重抓一次 playlist, 加上狀態輪詢跟 chunk, 一個觀眾一分鐘就有
    # 十幾個請求. read_settings() 每次都重讀重驗 config.json, 還會順手掃 log 目錄、
    # 有機會回寫檔案 —— 不快取的話光是放一集就會把它跑上千次.
    now = time.monotonic()
    if (_hls_settings_cache['settings'] is None
            or now - _hls_settings_cache['at'] > HLS_SETTINGS_TTL):
        # 不上鎖: greenlet 之間不會撕裂, 最壞只是兩個人同時去讀一次設定
        _hls_settings_cache['settings'] = Config.read_settings()
        _hls_settings_cache['at'] = now
    return _hls_settings_cache['settings']


def _hls_temp_dir(sn, current_settings):
    # read_settings() 保證 temp_dir 一定是絕對路徑 (空值或指到不存在的地方時會退回
    # <working_dir>/temp), 所以這裡不能自己寫死 'temp'
    return os.path.join(current_settings['temp_dir'],
                        re.sub(r'[^0-9]', '', str(sn)) + HLS_TEMP_SUFFIX)


def _hls_task(sn):
    # tasks_progress_rate 是下載器那幾條真執行緒在改的, 沒有鎖. 先整份 dict() 拷一份
    # 再取, 不能寫成 if k in d: d[k] —— 兩行之間 Anime.py 可能剛好把 key 刪掉
    try:
        return dict(Config.tasks_progress_rate).get(int(sn))
    except (TypeError, ValueError):
        return None


def _hls_parse_playlist(text):
    """從 *遠端原始* m3u8 取出有序的 (時長, chunk 檔名).

    __segment_download_mode() 在開始下載任何東西之前就先把這份寫下來了, 所以整集的
    分片清單跟總長度從第一秒就是已知的. 等到每一片都落地, 它會用同一個路徑覆蓋成
    給 ffmpeg 吃的版本 —— 絕對路徑、雙反斜線、key 指向 key.m3u8key. 那個型態絕對
    不能發給瀏覽器, 所以這裡看到就直接回 None.
    """
    if HLS_LOCALISED_MARKER in text or '\\\\' in text:
        return None

    key_line = ''
    target_duration = 10
    segments = []
    pending_extinf = None
    pending_duration = 10.0

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith('#EXT-X-KEY') and 'AES-128' in line:
            key_line = line
        elif line.startswith('#EXT-X-TARGETDURATION'):
            try:
                target_duration = int(float(line.split(':', 1)[1]))
            except (IndexError, ValueError):
                pass
        elif line.startswith('#EXTINF'):
            pending_extinf = line
            try:
                pending_duration = float(line.split(':', 1)[1].split(',')[0])
            except (IndexError, ValueError):
                pending_duration = float(target_duration)
        elif not line.startswith('#') and re.match(r'media_b.+ts', line):
            # 必須跟 Anime.py.download_chunk 用同一個表達式取檔名, 否則伺服器 stat
            # 的名字會跟下載器寫下的名字對不起來
            segments.append({
                'name': re.findall(r'media_b.+ts', line)[0],
                'extinf': pending_extinf or '#EXTINF:%.3f,' % pending_duration,
                'duration': pending_duration,
            })
            pending_extinf = None
            pending_duration = float(target_duration)

    if not key_line or not segments:
        return None

    return {
        'key_line': key_line,
        'target_duration': max(1, target_duration),
        'segments': segments,
        'total_duration': sum(s['duration'] for s in segments),
        # 重試任務可能改抓別的清晰度, chunk 名字裡的位元率就變了. 前端記住這個值,
        # 一旦變了就整個重建播放器, 而不是讓 hls.js 接到另一條串流上去
        'playlist_id': hashlib.md5(
            '|'.join(s['name'] for s in segments).encode('utf-8')).hexdigest()[:12],
    }


def _hls_forget_playlist(sn):
    _hls_playlist_cache.pop(str(sn), None)


def _hls_playlist(sn, temp_dir):
    """解析後的 playlist, 並且撐過 m3u8 被改寫成本機路徑版的那一刻.

    任務跑著的時候分片清單不會變, 會變的只有哪幾片已經在磁碟上, 那個由 scandir 決定.
    把解析結果留著, 是為了讓看到一半的觀眾不要在最後一片剛落地、
    __segment_download_mode() 覆寫 m3u8 的瞬間被切掉 —— 慢一點的磁碟合併要跑好幾十秒,
    而那段時間整集其實都還躺在 temp 裡, 完全可以繼續播.
    """
    sn_key = str(sn)
    m3u8_path = os.path.join(temp_dir, str(sn) + '.m3u8')
    cached = _hls_playlist_cache.get(sn_key)

    try:
        stat = os.stat(m3u8_path)
        signature = (stat.st_mtime, stat.st_size)
    except OSError:
        # 合併完成把整個目錄搬走了; 手上還有解析結果就先頂著, 由磁碟掃描去決定狀態
        return cached['parsed'] if cached else None

    if cached and cached['sig'] == signature:
        return cached['parsed']

    with _keyed_lock('hls-' + sn_key):
        # 排隊的這段時間裡前面那個請求可能已經解析好了, 拿到鎖要再看一眼
        cached = _hls_playlist_cache.get(sn_key)
        if cached and cached['sig'] == signature:
            return cached['parsed']
        try:
            with open(m3u8_path, 'r', encoding='utf-8') as f:
                parsed = _hls_parse_playlist(f.read())
        except OSError:
            return cached['parsed'] if cached else None

        if parsed is None:
            # 已經被本機化了 (或根本不是我們認得的格式), 留著舊的解析結果繼續服務
            return cached['parsed'] if cached else None

        if len(_hls_playlist_cache) > 32:
            live = set(str(key) for key in dict(Config.tasks_progress_rate).keys())
            for stale in [key for key in list(_hls_playlist_cache) if key not in live]:
                _hls_playlist_cache.pop(stale, None)

        _hls_playlist_cache[sn_key] = {'sig': signature, 'parsed': parsed}
        return parsed


def _hls_ready_count(temp_dir, segments):
    """從頭算起有幾片是完整的.

    download_chunk() 在 multi_downloading_segment 的號誌下跑, 完成順序是亂的, 所以
    tasks_progress_rate 的 rate 只是「下完幾片」而不是連續進度 —— 40% 完全有可能第
    一片還沒下來. 能播到哪裡只有目錄說了算. Anime.py 那邊改成先寫 .part 再 replace
    之後, 「檔名出現而且不是 0 byte」就等於「這一片是完整的」.
    """
    try:
        sizes = {}
        # 用 scandir 而不是逐片 getsize: 一集有一百多片, 大小在列目錄時就一起拿到了
        for entry in os.scandir(temp_dir):
            if entry.is_file():
                try:
                    sizes[entry.name] = entry.stat().st_size
                except OSError:
                    pass
    except OSError:
        return 0  # 目錄被 rmtree 掉了, 交給狀態端點去講

    count = 0
    for segment in segments:
        # 大小檢查留著當保險: 舊版本寫下的半截檔案沒有 .part 保護
        if sizes.get(segment['name'], 0) <= 0:
            break
        count += 1
    return count


def _hls_render(sn, parsed, ready, complete):
    lines = [
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXT-X-TARGETDURATION:%d' % parsed['target_duration'],
        # 不重新編號: #EXT-X-KEY 沒帶 IV 的時候, IV 就是分片的序號. 前綴從 0 開始配上
        # MEDIA-SEQUENCE:0, 序號才對得上解密用的 IV
        '#EXT-X-MEDIA-SEQUENCE:0',
        '#EXT-X-PLAYLIST-TYPE:EVENT',
        # 沒有 ENDLIST 之前 hls.js 一律當直播看待, 預設會從尾端往回三個 targetduration
        # 開始播 —— 也就是把已經下載好的部分整個跳過. 原生播放器也吃這一行
        '#EXT-X-START:TIME-OFFSET=0,PRECISE=YES',
        # 只換掉 URI, 不重建整行: 上游哪天帶了 IV= 也不會被我們弄丟
        re.sub(r'URI="[^"]*"', 'URI="key.bin?id=%s"' % sn, parsed['key_line']),
    ]
    for index in range(ready):
        lines.append(parsed['segments'][index]['extinf'])
        # 相對路徑, 讓它跟著 /hls/ 走, 反向代理掛在哪個路徑底下都不會錯
        lines.append('segment.ts?id=%s&n=%d' % (sn, index))
    if complete:
        lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


def _hls_resolution_from_filename(filename):
    # Anime.py 要等解析完才知道真正的清晰度, 在那之前 filename 是 '《標題》',
    # 配不上就回 0 —— 那才是實話, 清晰度這時候真的還沒定下來
    match = re.search(r'\[(\d+)P\]', str(filename or ''))
    return int(match.group(1)) if match else 0


def _hls_state(sn, current_settings):
    """一個地方決定這個 sn 現在是什麼狀態, 四條路由都讀它."""
    state = {
        'mode': 'none', 'ready': 0, 'total': 0,
        'readyDuration': 0.0, 'totalDuration': 0.0, 'targetDuration': 10,
        'playlistId': None, 'rate': 0.0, 'status': '', 'resolution': 0,
        'videoUrl': None, 'danmu': False, 'parsed': None, 'temp_dir': None,
    }

    entry = _find_video_entry(sn)
    if entry is not None:
        # 合併完成而且 video_list.json 也更新了, 該換去完成檔了
        _hls_forget_playlist(sn)
        state['mode'] = 'file'
        state['rate'] = 100.0
        state['resolution'] = int(entry.get('resolution') or 0)
        state['danmu'] = bool(entry.get('danmu'))
        state['videoUrl'] = './get_video.mp4?id=%s%s' % (
            sn, '&res=%s' % state['resolution'] if state['resolution'] else '')
        return state

    task = _hls_task(sn)
    if not current_settings.get('segment_download_mode') or task is None:
        # segment_download_mode 關掉時走的是 ffmpeg 直錄, 根本沒有分片可以發; 而沒有
        # 進度紀錄卻留著一個 temp 目錄, 那是失敗留下的殘骸, 不是還在跑的任務
        _hls_forget_playlist(sn)
        return state

    state['rate'] = float(task.get('rate') or 0)
    state['status'] = str(task.get('status') or '')
    state['resolution'] = _hls_resolution_from_filename(task.get('filename'))

    temp_dir = _hls_temp_dir(sn, current_settings)
    state['temp_dir'] = temp_dir
    parsed = _hls_playlist(sn, temp_dir)
    if parsed is None:
        state['mode'] = 'parsing'  # 還在跟巴哈要 m3u8, 或者這份我們讀不懂
        return state

    ready = _hls_ready_count(temp_dir, parsed['segments'])
    total = len(parsed['segments'])
    state.update({
        'parsed': parsed,
        'ready': ready,
        'total': total,
        'targetDuration': parsed['target_duration'],
        'totalDuration': round(parsed['total_duration'], 3),
        'readyDuration': round(sum(s['duration'] for s in parsed['segments'][:ready]), 3),
        'playlistId': parsed['playlist_id'],
    })

    if ready >= total or state['status'] == '下載完成':
        state['mode'] = 'finalising'  # ffmpeg 正在合併, temp 還在, 照樣能播
    elif ready > 0:
        state['mode'] = 'streaming'
    else:
        state['mode'] = 'parsing'  # 一片都還沒落地
    return state


def _hls_bootstrap_entry(sn, current_settings):
    """給正在下載的集數捏一筆 video_list 形狀的資料.

    /watch 之所以能擺出播放器而不是「找不到這一集影片」, 就是因為 watch.js 拿到的
    東西跟真正的片庫條目長得一模一樣 —— renderTitleBar、資訊卡、集數列、setTime
    通通不必知道有串流這回事. 多出來的那兩個 key 才是播放器要分支的地方.
    """
    if not current_settings.get('segment_download_mode'):
        return None

    task = _hls_task(sn)
    pending = task is None
    if pending and not request.args.get('streaming'):
        # /manualTask 一送出就回, 真正建立進度紀錄是那條執行緒跑到 Anime.download()
        # 之後的事. streaming=1 就是「我剛按下去」的憑據, 讓播放頁自己去等
        return None

    title = ''
    if task:
        title = str(task.get('filename') or '').strip().strip('《》')
    anime_name = title
    episode = ''
    # 這裡是整個功能唯一一次呼叫 _get_anime_info: 它落盤快取 12 小時, 而且走的是
    # 不帶 cookie 的 curl_cffi, 碰不到動畫瘋帳號. 首頁每張卡片本來就在叫它了,
    # 一次開頁叫一次遠比現況省 —— 重點是別讓它進到五秒一次的狀態輪詢裡
    info = _get_anime_info(sn) or {}
    video_info = info.get('video') or {}
    anime_info = info.get('anime') or {}
    if anime_info.get('title'):
        anime_name = anime_info['title']
    if video_info.get('title') and not title:
        title = video_info['title']
    if video_info.get('episode'):
        episode = video_info['episode']

    return {
        'sn': str(sn),
        'title': title or anime_name or str(sn),
        'anime_name': anime_name or title or str(sn),
        'episode': episode,
        'resolution': _hls_resolution_from_filename(task.get('filename')) if task else 0,
        'path': '',  # 還沒有東西在磁碟上
        'source': BAHAMUT_SOURCE,
        'timestamp': int(time.time()),
        'danmu_path': None,
        # 彈幕的 .ass 要等合併完才生得出來. 先給 False, loadDanmaku() 就整個不會發請求;
        # 交接到完成檔的時候播放器會把它翻回真正的值再讀一次
        'danmu': False,
        'streaming': True,
        'pending': pending,
    }


def _build_watch_bootstrap(current_settings=None):
    current_settings = current_settings or _get_current_settings()
    requested_sn = str(request.args.get('id') or '').strip()
    requested_resolution = str(request.args.get('res') or '').strip()
    bootstrap = {
        'requestedVideoId': requested_sn or None,
        'requestedResolution': requested_resolution or None,
        'initialVideoData': None,
        'initialVideoSeries': [],
        'resumeTime': 0,
        'streaming': False,
    }

    if not requested_sn:
        return bootstrap

    video_list = _read_video_list_file().get('videos', [])
    initial_video = None
    for video in video_list:
        if str(video.get('sn')) == requested_sn:
            initial_video = dict(video)
            break

    if not initial_video:
        # 還在下載的集數當然不在 video_list.json 裡. 捏一筆同樣形狀的資料出去, 播放頁
        # 就能擺出播放器邊下邊播, 而不是丟一句「找不到這一集影片」把人擋在門外
        initial_video = _hls_bootstrap_entry(requested_sn, current_settings)
        if initial_video is None:
            return bootstrap

    if requested_resolution and requested_resolution.isdigit():
        initial_video['resolution'] = requested_resolution

    bootstrap['initialVideoData'] = initial_video
    bootstrap['streaming'] = bool(initial_video.get('streaming'))
    bootstrap['initialVideoSeries'] = [video for video in video_list if video.get('anime_name') == initial_video.get('anime_name')]

    user = _get_request_user(current_settings)
    if user:
        resume_state = user.get('videotimes', {}).get(requested_sn, {})
        if not resume_state.get('ended'):
            bootstrap['resumeTime'] = int(resume_state.get('time', 0) or 0)

    return bootstrap


def _settings_signature(current_settings):
    return json.dumps(current_settings, ensure_ascii=False, sort_keys=True)


def _sync_plugin_manager(force=False):
    global plugin_manager_last_reload_at, plugin_manager_settings_signature, settings

    current_settings = _get_current_settings()
    signature = _settings_signature(current_settings)
    now = time.monotonic()

    if force or signature != plugin_manager_settings_signature or now - plugin_manager_last_reload_at >= PLUGIN_RELOAD_INTERVAL_SECONDS:
        plugin_manager.reload(current_settings)
        plugin_manager_settings_signature = signature
        plugin_manager_last_reload_at = now
        settings = current_settings

    return current_settings


# 读取web需要的配置名称列表
id_list_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'static', 'js', 'settings_id_list.js')
with open(id_list_path, 'r', encoding='utf-8') as f:
    id_list = re.sub(r'(var id_list\s*=\s*|\s*\n?)', '', f.read()).replace('\'', '"')
    id_list = json.loads(id_list)

@app.after_request
def after_request(response):
    response.headers.add('Accept-Ranges', 'bytes')
    return response


settings = _get_current_settings()
plugin_manager = PluginManager(settings)
plugin_manager_settings_signature = _settings_signature(settings)
plugin_manager_last_reload_at = time.monotonic()


@app.context_processor
def inject_dashboard_template_context():
    return {
        'dashboard_bootstrap': _build_dashboard_bootstrap(),
    }


@app.route('/control')
@admin_page_required
def control():
    return render_template('control.html')


@app.route('/monitor')
@admin_page_required
def monitor():
    return render_template('monitor.html')


@app.route('/data/config.json', methods=['GET'])
@admin_api_required
def config():
    settings = Config.read_settings()
    web_settings = {}
    for id in id_list:
        if id == 'browser_fingerprint':
            web_settings['browser_fingerprint_ja3'] = settings[id]['ja3']
            web_settings['browser_fingerprint_akamai'] = settings[id]['akamai']
        else:
            web_settings[id] = settings[id]  # 仅返回 web 需要的配置

    return jsonify(web_settings)


@app.route('/uploadConfig', methods=['POST'])
@admin_api_required
def recv_config():
    data = json.loads(request.get_data(as_text=True))
    new_settings = Config.read_settings()
    for id in id_list:
        if id == 'browser_fingerprint':
            new_settings[id] = {
                'ja3': data.get('browser_fingerprint_ja3', ''),
                'akamai': data.get('browser_fingerprint_akamai', '')
            }
        else:
            new_settings[id] = data[id]  # 更新配置
    Config.write_settings(new_settings)  # 保存配置
    _sync_plugin_manager(force=True)
    err_print(0, 'Dashboard', '通過 Web 控制臺更新了 config.json', no_sn=True, status=2)
    return '{"status":"200"}'


@app.route('/manualTask', methods=['POST'])
@admin_api_required
def manual_task():
    data = json.loads(request.get_data(as_text=True))
    settings = Config.read_settings()

    # 下载清晰度
    if data['resolution'] not in ('360', '480', '540', '720', '1080'):
        # 如果不是合法清晰度
        resolution = settings['download_resolution']
    else:
        resolution = data['resolution']

    # 下载模式
    if data['mode'] not in ('single', 'latest', 'all', 'largest-sn'):
        mode = 'single'
    else:
        mode = data['mode']

    # 下载线程数
    if data['thread']:
        thread = int(data['thread'])
    else:
        thread = 1
    if thread > Config.get_max_multi_thread():
        # 是否超过最大允许线程数
        thread_limit = Config.get_max_multi_thread()
    else:
        thread_limit = thread

    def run_cui():
        cui(data['sn'], resolution, mode, thread_limit, [], classify=data['classify'], realtime_show=False,
            cui_danmu=data['danmu'])

    server = threading.Thread(target=run_cui)
    err_print(0, 'Dashboard', '通過 Web 控制臺下達了手動任務', no_sn=True, status=2)
    server.start()  # 启动手动任务线程
    return '{"status":"200"}'


@app.route('/data/sn_list', methods=['GET'])
@admin_api_required
def show_sn_list():
    return Config.get_sn_list_content()


@app.route('/data/get_token', methods=['GET'])
@admin_api_required
def get_token():
    global websocket_token
    # 生成 32 位随机字符串作为token
    websocket_token = ''.join(random.sample(string.ascii_letters + string.digits, 32))
    return jsonify({'token': websocket_token, 'legacy': True})


@app.route('/sn_list', methods=['POST'])
@admin_api_required
def set_sn_list():
    data = request.get_data(as_text=True)
    Config.write_sn_list(data)
    err_print(0, 'Dashboard', '通過 Web 控制臺更新了 sn_list', no_sn=True, status=2)
    return '{"status":"200"}'


@app.route('/checknow')
@admin_api_required
def checknowctrl():
    err_print(0, 'Dashboard', '通過 Web 控制臺發出了立即更新的請求', no_sn=True, status=2)
    checknow()
    return '{"status":"200"}'


@app.route('/console/command', methods=['POST'])
@admin_api_required
def web_console_command():
    return _handle_web_console_command()


# todo: 修好websocket
@app.route('/data/tasks_progress')
def tasks_progress():
    ws = request.environ.get('wsgi.websocket')
    if ws is None:
        return jsonify({'success': False, 'message': 'websocket required'}), 400
    current_settings = Config.read_settings()
    if current_settings['dashboard']['user_control']['enabled']:
        user = find_user_by_token(request.cookies.get('token'))
        if not user or user.get('role') != 'admin':
            ws.close()
            return

    while True:
        msg = json.dumps(Config.tasks_progress_rate)
        try:
            ws.send(msg)
            time.sleep(1)
        except (WebSocketError, ConnectionError, OSError):
            ws.close()
            break
    return
    # 鉴权
    global websocket_token
    token = request.args.get('token')
    if token != websocket_token:
        ws.send('Unauthorized')
        ws.close()
    else:
        # 一次性 token
        websocket_token = ''

    # 推送任务进度数据
    # https://blog.csdn.net/sinat_32651363/article/details/87912701
    while True:
        msg = json.dumps(Config.tasks_progress_rate)
        try:
            ws.send(msg)
            time.sleep(1)
        except WebSocketError:
            # 连接中断
            ws.close()
            break


@app.route('/')
def home():
    current_settings = _get_current_settings()
    if current_settings["dashboard"]["online_watch"]:
        if current_settings["dashboard"]["user_control"]["enabled"]:
            logined, user_role = verify_user(request.cookies)
            if logined and user_role == 'user':
                return redirect("./watch")
        return render_template('index.html')
    else:
        return redirect("./control")


@app.route('/favicon.ico')
def favicon():
    return send_file(os.path.join(static_path, 'img', 'aniGamerPlus.ico'))


# A service worker may only control the paths below its own URL, so both it and
# the manifest are mirrored at the site root instead of living under /static.
@app.route('/manifest.webmanifest')
def webmanifest():
    response = make_response(send_file(os.path.join(static_path, 'manifest.webmanifest')))
    response.headers['Content-Type'] = 'application/manifest+json; charset=utf-8'
    return response


@app.route('/sw.js')
def service_worker():
    response = make_response(send_file(os.path.join(static_path, 'sw.js')))
    response.headers['Content-Type'] = 'application/javascript; charset=utf-8'
    response.headers['Service-Worker-Allowed'] = '/'
    response.headers['Cache-Control'] = 'no-cache'
    return response


# iOS looks for these at the root when a page is added to the home screen from
# a URL it has not parsed the <link> tags of (e.g. a shared link).
@app.route('/apple-touch-icon.png')
@app.route('/apple-touch-icon-precomposed.png')
def apple_touch_icon():
    return send_file(os.path.join(static_path, 'img', 'pwa', 'apple-touch-icon.png'))


if settings["dashboard"]["online_watch"]:
    @app.route('/watch')
    def watch():
        current_settings = _get_current_settings()
        if current_settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return redirect("./login?error=2")
        return render_template('watch.html', watch_bootstrap=_build_watch_bootstrap(current_settings))


    @app.route('/anime_info')
    def get_anime_info():
        # 动画疯官方的单集资讯, 服务端代抓 (那个 api 不发 CORS 头)
        current_settings = _sync_plugin_manager()
        if current_settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return jsonify({"error": "login required"}), 403

        sn = request.args.get('id')
        if not sn or not str(sn).isdigit():
            return jsonify({"error": "invalid sn"}), 400
        # 不在片库里的 sn 一律不转发, 免得这个路由变成打向巴哈的请求放大器
        if _find_video_entry(sn) is None:
            return jsonify({"error": "video not found"}), 404

        info = _get_anime_info(sn)
        if not info:
            return jsonify({"error": "anime info unavailable"}), 404
        resp = jsonify(info)
        resp.headers['Cache-Control'] = 'private, max-age=3600'
        return resp

    @app.route('/watch/series.json')
    def watch_series():
        """播放頁要的作品資料: 官方封面、官方簡介, 跟整部作品的集數表.

        跟 /catalog/anime.json 端的是同一份東西, 差別只在入口: 那邊給的是作品編號,
        播放頁手上只有正在播的那一集. 沒有這條路由, 資訊卡就只能拿片庫裡那幾集
        自己編一段介紹, 集數列也只擺得出下載過的集數 —— 邊看邊下載進來的人於是
        看到「共 1 集」.
        """
        current_settings = _sync_plugin_manager()
        if current_settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return jsonify({"error": "login required"}), 403

        sn = request.args.get('id')
        if not sn or not str(sn).isdigit():
            return jsonify({"error": "invalid sn"}), 400
        # 跟 /anime_info、/thumbnail.jpg 同一道門: 片庫裡有, 或者正在下載, 才代抓
        if _find_video_entry(sn) is not None or _hls_task(sn) is not None:
            info = _get_anime_info(sn)
        else:
            # 剛按下邊看邊下載的那一集: 下載執行緒還沒登記它, 片庫也還沒有檔,
            # 但它就列在剛剛那一部作品的集數表上。認那張表, 不另外去問巴哈 ——
            # 這條路由依舊不會變成任人指定 sn 就替他打巴哈的請求放大器
            owner = _episode_owners().get(str(sn))
            info = _get_anime_info(owner) if owner else None
        if not info:
            return jsonify({"error": "video not found"}), 404

        anime = info.get('anime') or {}
        video = info.get('video') or {}
        resp = jsonify({
            'animeSn': str(anime.get('animeSn') or ''),
            'videoSn': str(sn),
            'title': Catalog.series_title(anime.get('title')),
            # 作品封面是 3:4 的直式圖, 跟單集那張橫的截圖不是同一種東西
            'cover': anime.get('cover') or video.get('cover') or '',
            'content': Catalog.plain_text(anime.get('contentHtml') or anime.get('content')),
            'tags': anime.get('tags') or [],
            'director': anime.get('director') or '',
            'publisher': anime.get('publisher') or '',
            'score': anime.get('score') or 0,
            'seasonStart': anime.get('seasonStart') or '',
            'popular': Catalog.views(anime.get('popular')),
            'totalEpisode': anime.get('totalEpisode') or '',
            'groups': _catalog_episodes(info),
        })
        return _apply_cache_headers(resp, current_settings, 3600)

    @app.route('/catalog/index.json')
    def catalog_index():
        # 动画疯首页的几个分区. 片库里只有下过的那几部, 这里是站上全部
        current_settings = _get_current_settings()
        denied = _catalog_login_error(current_settings)
        if denied is not None:
            return denied
        payload = _get_catalog_index()
        if payload is None:
            return jsonify({"error": "catalog unavailable"}), 503
        return _apply_cache_headers(jsonify(payload), current_settings, 600)

    @app.route('/catalog/all.json')
    def catalog_all():
        current_settings = _get_current_settings()
        denied = _catalog_login_error(current_settings)
        if denied is not None:
            return denied

        items = _get_catalog_all()
        keyword = (request.args.get('q') or '').strip()
        if keyword:
            # 全站一千八百多部都已经在本地了, 搜个片名没必要再去问巴哈
            keyword = keyword.lower()
            items = [item for item in items if keyword in item['title'].lower()]
        try:
            page = max(1, int(request.args.get('page') or 1))
        except BaseException:
            page = 1
        start = (page - 1) * CATALOG_PAGE_SIZE
        resp = jsonify({
            'items': items[start:start + CATALOG_PAGE_SIZE],
            'page': page,
            'pages': max(1, (len(items) + CATALOG_PAGE_SIZE - 1) // CATALOG_PAGE_SIZE),
            'total': len(items),
        })
        return _apply_cache_headers(resp, current_settings, 600)

    @app.route('/catalog/anime.json')
    def catalog_anime():
        # 详情页: 简介、集数表, 以及每一集在本地有没有
        current_settings = _get_current_settings()
        denied = _catalog_login_error(current_settings)
        if denied is not None:
            return denied

        anime_sn = request.args.get('sn')
        if not anime_sn or not str(anime_sn).isdigit():
            return jsonify({"error": "invalid sn"}), 400
        if not _catalog_knows(anime_sn):
            return jsonify({"error": "anime not found"}), 404

        video_sn = _resolve_video_sn(anime_sn)
        if not video_sn:
            return jsonify({"error": "anime unavailable"}), 404
        info = _get_anime_info(video_sn)
        if not info:
            return jsonify({"error": "anime info unavailable"}), 404

        anime = info.get('anime') or {}
        resp = jsonify({
            'animeSn': str(anime_sn),
            'videoSn': video_sn,
            'title': Catalog.series_title(anime.get('title')),
            'cover': anime.get('cover') or '',
            'content': Catalog.plain_text(anime.get('contentHtml') or anime.get('content')),
            'tags': anime.get('tags') or [],
            'director': anime.get('director') or '',
            'publisher': anime.get('publisher') or '',
            'score': anime.get('score') or 0,
            'seasonStart': anime.get('seasonStart') or '',
            'popular': Catalog.views(anime.get('popular')),
            'totalEpisode': anime.get('totalEpisode') or '',
            'groups': _catalog_episodes(info),
        })
        return _apply_cache_headers(resp, current_settings, 600)

    @app.route('/thumbnail.jpg')
    def get_thumbnail():
        # 首页/播放页的封面: 官方封面抓不到才从影片里抽一帧, 抓过就落盘缓存
        current_settings = _sync_plugin_manager()
        if current_settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return jsonify({"error": "login required"}), 403

        sn = request.args.get('id')
        if not sn or not str(sn).isdigit():
            return jsonify({"error": "invalid sn"}), 400

        cache_path = _thumbnail_cache_path(sn)
        if not os.path.exists(cache_path):
            # 先确认 sn 真的在片库里再干活: 否则任何人都能拿这个路由去捶巴哈,
            # 顺手把锁表和 anime_info/ 撑到没边
            entry = _find_video_entry(sn)
            if entry is None and _hls_task(sn) is not None:
                # 還在下載的集數: 影片檔還沒有, 但官方封面抓得到. 有進度紀錄跟有片庫
                # 條目一樣, 都足以證明這個 sn 是自己人, 擋人的那道保險還在
                entry = {'source': BAHAMUT_SOURCE, 'path': ''}
            if entry is None:
                return jsonify({"error": "video not found"}), 404
            if not _thumbnail_recently_failed(sn):
                with _keyed_lock('thumb-' + str(sn)):
                    # 排队的这段时间里, 前面那个请求可能刚好失败. 拿到锁必须再看一眼
                    # 退避, 否则退避形同虚设, 一次失败会被并发放大成 N 次抓取
                    if not os.path.exists(cache_path) and not _thumbnail_recently_failed(sn):
                        if _build_thumbnail(sn, cache_path, entry):
                            _thumbnail_failures.pop(str(sn), None)
                        else:
                            _thumbnail_failures[str(sn)] = time.time()
            if not os.path.exists(cache_path):
                return _thumbnail_unavailable()

        etag, last_modified, file_size = get_file_headers(cache_path)
        if request.headers.get('If-None-Match') == etag:
            resp = Response(status=304)
        else:
            resp = send_file(cache_path, mimetype='image/jpeg')
        resp.headers['ETag'] = etag
        resp.headers['Last-Modified'] = last_modified
        _apply_cache_headers(resp, current_settings, 86400)
        return resp


    @app.route('/get_video.mp4')
    def getvid():
        current_settings = _sync_plugin_manager()
        if current_settings['dashboard']['online_watch_requires_login']:
            valid_user, user_role = verify_user(request.cookies)
            if not valid_user:
                return jsonify({"error": "login required"}), 403

        sn = request.args.get('id')
        res = request.args.get('res')
        playback_source = plugin_manager.resolve_playback_source({
            'sn': str(sn),
            'resolution': int(res) if res and str(res).isdigit() else 0,
        })
        if playback_source and playback_source.get('url'):
            return redirect(playback_source['url'])

        path = Config.getpath(sn, 'video', resolution=res)
        if not path or not os.path.exists(path):
            return jsonify({"error": "video not found"}), 404
        filename = os.path.basename(path)
        ascii_filename = re.sub(r'[^a-zA-Z0-9._-]', '_', filename)
        utf8_filename = urllib.parse.quote(filename)
        content_disposition = (
            f'inline; filename="{ascii_filename}"; filename*=UTF-8\'\'{utf8_filename}'
        )

        etag, last_modified, file_size = get_file_headers(path)

        # 我不知道 ChatGPT一直問我就一直回好啊
        # 然後就變成這樣了 lol
        # --- 瀏覽器快取檢查 ---
        if request.headers.get("If-None-Match") == etag or \
        request.headers.get("If-Modified-Since") == last_modified:
            resp = Response(status=304)  # Not Modified
            resp.headers['ETag'] = etag
            resp.headers['Last-Modified'] = last_modified
            _apply_cache_headers(resp, current_settings, 3600)
            return resp

        # 檢查 Range header
        range_header = request.headers.get('Range', None)

        # --- Case 1: 沒有 Range → 直接回傳整份檔案 ---
        if not range_header:
            resp = send_file(path, mimetype='video/mp4', as_attachment=True, download_name=filename)
            _apply_cache_headers(resp, current_settings, 3600)
            resp.headers['ETag'] = etag
            resp.headers['Last-Modified'] = last_modified
            resp.headers['Accept-Ranges'] = 'bytes'
            resp.headers['Content-Disposition'] = content_disposition
            return resp

        # --- Case 2: 有 Range → 部分內容串流回傳 ---
        byte1, byte2 = 0, None
        match = re.search(r'(\d+)-(\d*)', range_header)
        groups = match.groups()
        if groups[0]:
            byte1 = int(groups[0])
        if groups[1]:
            byte2 = int(groups[1])

        if byte2 is not None:
            length = byte2 + 1 - byte1
        else:
            length = file_size - byte1

        resp = Response(
            stream_with_context(generate_file(path, byte1, length)),
            status=206,
            mimetype='video/mp4',
            direct_passthrough=True,
        )

        resp.headers.add('Content-Range', f'bytes {byte1}-{byte1 + length - 1}/{file_size}')
        resp.headers.add('Accept-Ranges', 'bytes')
        resp.headers.add('Content-Length', str(length))
        _apply_cache_headers(resp, current_settings, 3600)
        resp.headers['ETag'] = etag
        resp.headers['Last-Modified'] = last_modified
        resp.headers['Content-Disposition'] = content_disposition

        return resp


    # ------------------------------------------------------------- 邊看邊下載
    # 下載中的集數在 temp 裡本來就是一份 HLS 串流, 這四條路由只是把它照原樣端出去:
    # playlist 只列已經連續落地的前綴, 分片直接讀檔, 金鑰原封不動交給瀏覽器解.
    # 全部都是本機磁碟, 不會為了播放再跟動畫瘋要任何東西.

    def _hls_request_state():
        """四條路由共用的門口: 驗登入、驗 sn, 然後算出現在是什麼狀態."""
        current_settings = _hls_settings()
        denied = _catalog_login_error(current_settings)
        if denied is not None:
            return None, None, denied
        sn = request.args.get('id')
        if not sn or not str(sn).isdigit():
            return None, None, (jsonify({"error": "invalid sn"}), 400)
        return current_settings, _hls_state(sn, current_settings), None

    @app.route('/hls/status.json')
    def hls_status():
        # 播放器每五秒問一次: 現在能不能播、下到幾 %、整集多長、下載完了沒.
        # 只放會變的東西 —— 片名集數在開頁時就寫進 bootstrap 了, 不必每次重送,
        # 更不該讓 _get_anime_info 進到這條輪詢裡
        current_settings, state, denied = _hls_request_state()
        if denied is not None:
            return denied

        payload = dict(state)
        payload.pop('parsed', None)   # 內部用的解析結果, 不外流
        payload.pop('temp_dir', None)  # 本機路徑不該出現在 API 回應裡
        resp = jsonify(payload)
        # 就算是 mode=none 也回 200: 前端要分得出「沒在下載」跟「伺服器壞了」
        resp.headers['Cache-Control'] = 'no-store'
        if current_settings['dashboard']['online_watch_requires_login']:
            resp.headers['Vary'] = 'Cookie'
        return resp

    @app.route('/hls/playlist.m3u8')
    def hls_playlist():
        current_settings, state, denied = _hls_request_state()
        if denied is not None:
            return denied

        if not current_settings.get('segment_download_mode'):
            return jsonify({"error": "streaming unavailable"}), 404
        if state['mode'] == 'file':
            # 下載完了, 該去 /get_video.mp4, 不是繼續問這裡
            return jsonify({"error": "download finished"}), 404
        if state['mode'] == 'none':
            return jsonify({"error": "not downloading"}), 404
        if state['mode'] == 'parsing' or not state['parsed'] or state['ready'] <= 0:
            # 寧可 404 也不要發一份零分片的 playlist: hls.js 會把空清單當
            # LEVEL_EMPTY_ERROR 直接放棄, 而 404 是它願意重試的 LEVEL_LOAD_ERROR
            return jsonify({"error": "not ready"}), 404

        body = _hls_render(request.args.get('id'), state['parsed'],
                           state['ready'], state['mode'] == 'finalising')
        resp = Response(body, mimetype=HLS_MIME)
        # 不能走 _apply_cache_headers: 它的 max-age 會把一份幾秒就變一次的 playlist
        # 釘住, 而 get_file_headers 的 mtime+size ETag 對還在長大的東西是錯的
        resp.headers['Cache-Control'] = 'no-store'
        if current_settings['dashboard']['online_watch_requires_login']:
            resp.headers['Vary'] = 'Cookie'
        return resp

    @app.route('/hls/key.bin')
    def hls_key():
        # AES-128 的金鑰原樣交給瀏覽器, 伺服器這邊不解密. 這不會多開一個曝險面:
        # /get_video.mp4 早就用同一道門發完整的成品影片了, 金鑰能開的東西比那個少
        current_settings, state, denied = _hls_request_state()
        if denied is not None:
            return denied
        if state['mode'] not in ('parsing', 'streaming', 'finalising'):
            return jsonify({"error": "not downloading"}), 404

        try:
            with open(os.path.join(state['temp_dir'], 'key.m3u8key'), 'rb') as f:
                data = f.read()
        except OSError:
            return jsonify({"error": "key not ready"}), 404
        if not data:
            return jsonify({"error": "key not ready"}), 404

        resp = Response(data, mimetype='application/octet-stream')
        resp.headers['Cache-Control'] = 'no-store'
        if current_settings['dashboard']['online_watch_requires_login']:
            resp.headers['Vary'] = 'Cookie'
        return resp

    @app.route('/hls/segment.ts')
    def hls_segment():
        current_settings, state, denied = _hls_request_state()
        if denied is not None:
            return denied
        if state['mode'] not in ('streaming', 'finalising') or not state['parsed']:
            return jsonify({"error": "not downloading"}), 404

        # 用序號定位而不是讓前端傳檔名: 這樣沒有任何一段客戶端字串會走到檔案系統,
        # 目錄穿越不是被過濾掉, 是根本構造不出來
        try:
            index = int(request.args.get('n'))
        except (TypeError, ValueError):
            return jsonify({"error": "invalid segment"}), 400
        if index < 0 or index >= len(state['parsed']['segments']):
            return jsonify({"error": "invalid segment"}), 404
        if index >= state['ready']:
            # 要的比我們發出去的 playlist 還前面, 表示它拿的是舊清單
            return jsonify({"error": "segment not ready"}), 404

        path = os.path.join(state['temp_dir'], state['parsed']['segments'][index]['name'])
        try:
            # 整片讀進記憶體再回, 不用 send_file: 一片 1080p 大概 2~4 MB, 但檔案握把
            # 只開幾微秒. 重試任務會把同一片重下一次, 而 Windows 上 os.replace 碰到
            # 別人開著的目標檔會失敗 —— 握把開久一點, 觀眾就有機會弄垮下載.
            # 順帶把「合併完成時 rmtree 把目錄抽走」這個競態也一起解決掉
            with open(path, 'rb') as f:
                data = f.read()
        except OSError:
            return jsonify({"error": "segment gone"}), 404
        if not data:
            return jsonify({"error": "segment gone"}), 404

        resp = Response(data, mimetype='video/mp2t')
        # 分片一旦寫下就不會再變, 往回拖時間軸可以直接吃瀏覽器快取, 不必重讀磁碟
        return _apply_cache_headers(resp, current_settings, 3600)


    @app.route('/get_danmu.ass')
    def getsub():
        current_settings = _get_current_settings()
        sn = request.args.get('id')
        if current_settings['danmu']:
            video = _find_video_entry(sn)
            path = Config.getpath(sn, 'danmu')

            # Trigger danmu update in background thread to avoid Cloudflare 524 timeout
            if video and _should_update_danmu(sn):
                video_path = video.get('path')
                anime_name = video.get('anime_name')
                if video_path and anime_name and os.path.exists(video_path):
                    def _bg_update_danmu(sn=sn, anime_name=anime_name, video_path=video_path):
                        try:
                            __get_danmu_only(sn, anime_name, video_path, False)
                            updated_path = Config.getpath(sn, 'danmu')
                            if updated_path and os.path.exists(updated_path):
                                _mark_danmu_updated(sn)
                        except BaseException as e:
                            err_print(sn, '彈幕更新失敗', '線上觀看請求時自動更新失敗: ' + str(e), status=1, display=True)
                    threading.Thread(target=_bg_update_danmu, daemon=True).start()

            if path and os.path.exists(path) and str(sn) not in danmu_update_timestamps:
                _mark_danmu_updated(sn)

            if not path or not os.path.exists(path):
                return jsonify({"error": "danmu not found"}), 404
            return send_file(path)
        else:
            return 'Danmu is not enabled'


    @app.route('/video_list.json')
    def videolist():
        current_settings = _get_current_settings()
        if current_settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return jsonify({"error": "login required"}), 403
        # 走 _read_video_list_file(): 它會指定 encoding='utf-8', 檔案還沒生成時
        # 也不會 500. 直接 open() 會拿系統預設編碼去讀 (繁中 Windows 是 cp950),
        # 片名一律變成亂碼.
        return jsonify(_read_video_list_file())


    @app.route('/watch/time', methods=['GET', 'POST'])
    def webtime():
        if request.method == 'POST':
            reqdata = request.get_json() or request.form.copy()
        else:
            reqdata = request.args.copy()
        gettype = reqdata.get('type')
        sn = reqdata.get('sn')
        ended = str(reqdata.get('ended', "false")).lower() == "true"
        token = request.cookies.get('token')
        userdata = load_user_data()
        if gettype == 'set':
            for user in userdata['users']:
                if user['token'] == token:
                    # 播放器偶尔会送回 Infinity 或空值 (直播源、moov 里没写时长),
                    # 一个坏参数不该变成 500 把整笔进度一起丢掉
                    try:
                        entry = {"time": int(float(reqdata.get('time'))), "ended": ended, "timestamp": int(datetime.now().timestamp())}
                    except (TypeError, ValueError, OverflowError):
                        return '{"status":"400", "msg":"Invalid time"}', 400
                    # The player reports the media duration alongside the
                    # position so the library can draw a real progress bar
                    # instead of guessing against a nominal episode length.
                    try:
                        duration = int(float(reqdata.get('duration')))
                        if duration > 0:
                            entry['duration'] = duration
                    except (TypeError, ValueError, OverflowError):
                        pass
                    user['videotimes'][sn] = entry
                    save_user_data(userdata)
                    return '{"status":"200"}'
        elif gettype == 'del':
            # 觀看紀錄那一頁的刪除鈕. 沒有這筆就當作已經刪掉了 —— 連按兩下不該
            # 是一次 200 一次 404
            for user in userdata['users']:
                if user['token'] == token:
                    if not sn:
                        return '{"status":"400", "msg":"Missing sn"}', 400
                    if user['videotimes'].pop(sn, None) is not None:
                        save_user_data(userdata)
                    return '{"status":"200"}'
        elif gettype == 'get':
            for user in userdata['users']:
                if user['token'] == token:
                    if not sn:
                        return jsonify(user['videotimes'])
                    if user['videotimes'].get(sn):
                        return jsonify(user['videotimes'][sn])
                    else:
                        return jsonify({"time": 0, "ended": False})
        for user in userdata['users']:
            if user['token'] == token:
                return '{"status":"404", "msg":"Invalid type"}'
        return '{"status":"403", "msg":"Invalid token"}'
    

@app.route('/get_server_info')
def get_server_info():
    return jsonify(_get_dashboard_flags())

if settings['dashboard']['user_control']['enabled']:
    load_user_data()

    @app.route('/logout')
    def logout():
        response = make_response(redirect('./login'))
        return _clear_login_cookies(response)

    @app.route('/login', methods=['GET', 'POST'])
    def login():
        if request.method == 'GET':
            return render_template('login.html')

        reqdata = request.form.copy() if request.form else (request.get_json(silent=True) or {})
        if not reqdata:
            return '<script>alert("Empty request!");history.back();</script>'

        username = _normalize_username(reqdata.get('username'))
        password = reqdata.get('password')
        userdata = load_user_data()
        user = find_user_by_username(username, userdata)
        if not user or not _verify_password(user, password):
            return redirect('./login?error=1')

        if user.get('password') is not None:
            user['password_hash'] = _hash_password(password)
            user.pop('password', None)
            save_user_data(userdata)

        destination = './watch' if Config.read_settings()['dashboard'].get('online_watch') else './control'
        response = make_response(redirect(destination))
        return _set_login_cookies(response, user['token'])


    @app.route('/register', methods=['GET', 'POST'])
    def register():
        current_settings = Config.read_settings()
        if not current_settings['dashboard']['user_control']['allow_register']:
            return '<script>alert("註冊功能未啟用");history.back();</script>'
        if request.method == 'GET':
            return render_template('register.html')

        reqdata = request.get_json(silent=True) or request.form.copy()
        if not reqdata:
            return '<script>alert("Empty request!");history.back();</script>'
        if not reqdata.get('username') or not reqdata.get('pw1') or not reqdata.get('pw2'):
            return redirect('./register?error=3')
        if reqdata.get('pw1') != reqdata.get('pw2'):
            return redirect('./register?error=2')

        username = _normalize_username(reqdata.get('username'))
        password = str(reqdata.get('pw1'))
        if not re.match(r'^[a-zA-Z0-9_]{3,20}$', username):
            return redirect('./register?error=4')
        if not re.match(r'^[a-zA-Z0-9_]{6,64}$', password):
            return redirect('./register?error=5')

        userdata = load_user_data()
        if find_user_by_username(username, userdata):
            return redirect('./register?error=1')

        userdata['users'].append({
            'username': username,
            'password_hash': _hash_password(password),
            'token': _generate_token(),
            'videotimes': {},
            'role': 'user',
        })
        save_user_data(userdata)
        return redirect('./login?error=3')

    @app.route('/usermanage', methods=['GET', 'POST'])
    @admin_page_required
    def usermanage_v2():
        userdata = load_user_data()
        if request.method == 'GET':
            users = []
            for user in userdata['users']:
                safe_user = user.copy()
                safe_user.pop('password', None)
                safe_user.pop('password_hash', None)
                safe_user.pop('token', None)
                users.append(safe_user)
            return render_template('usermanage.html', users=users)

        reqdata = request.form.copy() if request.form else (request.get_json(silent=True) or {})
        if not reqdata:
            return jsonify({'status': '400', 'message': 'Empty request!'}), 400

        action = reqdata.get('action')
        username = _normalize_username(reqdata.get('username'))
        target_user = find_user_by_username(username, userdata)

        if action == 'delete':
            if not target_user:
                return jsonify({'status': '404', 'message': 'User not found'}), 404
            if target_user['username'].lower() == g.current_user['username'].lower():
                return jsonify({'status': '403', 'message': 'Cannot delete current user'}), 403
            userdata['users'] = [user for user in userdata['users'] if user['username'].lower() != username.lower()]
            save_user_data(userdata)
            return jsonify({'status': '200', 'message': 'User deleted'})

        if action == 'change':
            if not target_user:
                return jsonify({'status': '404', 'message': 'User not found'}), 404
            new_password = reqdata.get('password')
            if new_password:
                target_user['password_hash'] = _hash_password(new_password)
                target_user.pop('password', None)
                target_user['token'] = _generate_token()
            target_user['role'] = _normalize_role(reqdata.get('role', target_user.get('role')))
            save_user_data(userdata)
            return jsonify({'status': '200', 'message': 'User updated'})

        if action == 'add':
            if not username or not reqdata.get('password'):
                return jsonify({'status': '400', 'message': 'Username and password are required'}), 400
            if find_user_by_username(username, userdata):
                return jsonify({'status': '409', 'message': 'User already exists'}), 409
            userdata['users'].append({
                'username': username,
                'password_hash': _hash_password(reqdata.get('password')),
                'token': _generate_token(),
                'videotimes': {},
                'role': _normalize_role(reqdata.get('role')),
            })
            save_user_data(userdata)
            return jsonify({'status': '200', 'message': 'User created'})

        return jsonify({'status': '400', 'message': 'Invalid action'}), 400

    @app.route('/userinfo', methods=['GET', 'POST'])
    @user_page_required
    def userinfo_v2():
        userdata = load_user_data()
        user = find_user_by_token(request.cookies.get('token'), userdata)
        if not user:
            return redirect('/login')

        if request.method == 'GET':
            safe_user = user.copy()
            safe_user.pop('password', None)
            safe_user.pop('password_hash', None)
            safe_user.pop('token', None)
            return render_template('userinfo.html', user=safe_user)

        reqdata = request.form.copy() if request.form else (request.get_json(silent=True) or {})
        if not reqdata:
            return jsonify({'status': '400', 'message': 'Empty request!'}), 400

        action = reqdata.get('action')
        if action == 'get':
            ret_data = user.copy()
            ret_data['status'] = '200'
            ret_data.pop('token', None)
            ret_data.pop('password', None)
            ret_data.pop('password_hash', None)
            return jsonify(ret_data)

        if action in ('changepassword', 'change'):
            original_pw = reqdata.get('original_password', reqdata.get('old_password'))
            new_pw1 = reqdata.get('new_password1')
            new_pw2 = reqdata.get('new_password2')
            if not _verify_password(user, original_pw):
                return jsonify({"status": "403", "message": "錯誤的原密碼"}), 403
            if not new_pw1 or new_pw1 != new_pw2:
                return jsonify({"status": "403", "message": "新密碼不一致"}), 403
            user['password_hash'] = _hash_password(new_pw1)
            user.pop('password', None)
            user['token'] = _generate_token()
            save_user_data(userdata)
            return jsonify({"status": "200", "message": "密碼修改成功!", "logout": True})

        return jsonify({'status': '400', 'message': 'Invalid action'}), 400


if False and settings['dashboard']['user_control']['enabled']:
    # init user
    settings = Config.read_settings()
    if os.path.exists(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json')):
        try:
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            for duser in settings['dashboard']['user_control']['default_user']:
                t = False
                for user in userdata['users']:
                    if duser['username'] == user['username']:
                        user['password'] = duser['password']
                        user['role'] = duser['role']
                        t = True
                if not t:
                    userdata['users'].append(duser)
        except:
            userdata = {"users": settings['dashboard']['user_control']['default_user'].copy()}
            for u in userdata["users"]:
                u["token"] = ''.join(random.sample(string.ascii_letters + string.digits, 32))
                u["videotimes"] = {}
    else:
        userdata = {"users": settings['dashboard']['user_control']['default_user'].copy()}
        for u in userdata["users"]:
            u["token"] = ''.join(random.sample(string.ascii_letters + string.digits, 32))
            u["videotimes"] = {}
    with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
        json.dump(userdata, f, ensure_ascii=False, indent=4)

    def verify_user(cookies):
        if not cookies.get('logined') or cookies.get('logined') != 'true' or not cookies.get('token'):
            return False, None
        userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
        for user in userdata['users']:
            if user['token'] == cookies.get('token'):
                return True, user["role"]
        return False, None

    @app.route('/logout')
    def logout():
        return '<script>document.cookie = "token=expired";document.cookie = "logined=false";window.location.href = "./login"</script>'

    @app.route('/login', methods=['GET', 'POST'])
    def login():
        if request.method == 'POST':
            if request.form:
                reqdata = request.form.copy()
            else:
                reqdata = request.get_json()
            if not reqdata:
                return '<script>alert("Empty request!);history.back();</script>'
            username = reqdata.get('username')
            password = reqdata.get('password')
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            for user in userdata['users']:
                if user['username'] == username and user['password'] == password:
                    return f"<script>document.cookie = 'token={user['token']}; expires=Fri, 31 Dec 9999 23:59:59 GMT';document.cookie = 'logined=true; expires=Fri, 31 Dec 9999 23:59:59 GMT';window.location.href = './watch'</script>"
                # test 假設password sha256
                # if user['username'] == username:
                #     hashes = [hashlib.sha256((user['password'].encode() + str(int(time.time()) + t)).encode()).hexdigest() for t in range(-5, 6)]
                #     if password in hashes:
                #         return f"<script>document.cookie = 'token={user['token']}; expires=Fri, 31 Dec 9999 23:59:59 GMT';document.cookie = 'logined=true; expires=Fri, 31 Dec 9999 23:59:59 GMT';window.location.href = './watch'</script>"
            return '<script>window.location.href = "./login?error=1"</script>'
        else:
            return render_template('login.html')


    @app.route('/register', methods=['GET', 'POST'])
    def register():
        settings = Config.read_settings()
        if not settings['dashboard']['user_control']['allow_register']:
            return '<script>alert("伺服器沒有啟用註冊!");history.back();</script>'
        if request.method == 'POST':
            reqdata = request.get_json() or request.form.copy()
            # print("DEBUG:", reqdata)
            if not reqdata:
                return '<script>alert("Empty request!");history.back();</script>'
            elif not reqdata.get('username') or not reqdata.get('pw1') or not reqdata.get('pw2'):
                return redirect('./register?error=3')
            if not reqdata.get('pw1') == reqdata.get('pw2'):
                return redirect('./register?error=2')
            username = reqdata.get('username')
            # verify username
            if not re.match(r'^[a-zA-Z0-9_]{3,20}$', username):
                return redirect('./register?error=4')
            if not re.match(r'^[a-zA-Z0-9_]{6,20}$', reqdata.get('pw1')):
                return redirect('./register?error=5')
            password = reqdata.get('pw1')
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            for user in userdata['users']:
                if user['username'].lower() == username.lower():
                    return redirect('./register?error=1')
            newuser = {'username': username, 'password': password, 'token': ''.join(random.sample(string.ascii_letters + string.digits, 32)), 'videotimes': {}, 'role': 'user'}
            userdata['users'].append(newuser)
            with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                json.dump(userdata, f, ensure_ascii=False, indent=4)
            return redirect('./login?error=3')
        else:
            return render_template('register.html')
        
    @app.route('/usermanage', methods=['GET', 'POST'])
    def usermanage():
        logined, user_role = verify_user(request.cookies)
        if not logined:
            return redirect("./login?error=2")
        if user_role != 'admin':
            return '<script>alert("權限不足!");window.location.href = "./watch"</script>'
        if request.method == 'POST':
            if request.form:
                reqdata = request.form.copy()
            else:
                reqdata = request.get_json()
            if not reqdata:
                return '<script>alert("Empty request!);history.back();</script>'
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            for user in userdata['users']:
                if user['token'] == request.cookies.get('token'):
                    if reqdata.get('action') == 'delete':
                        userdata['users'].remove(user)
                        with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                            json.dump(userdata, f, ensure_ascii=False, indent=4)
                        return '<script>alert("刪除成功!");window.location.href = "./user"</script>'
                    elif reqdata.get('action') == 'change':
                        for u in userdata['users']:
                            if u['username'] == reqdata.get('username'):
                                u['password'] = reqdata.get('password')
                                u['role'] = reqdata.get('role')
                        with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                            json.dump(userdata, f, ensure_ascii=False, indent=4)
                        return '<script>alert("修改成功!");window.location.href = "./user"</script>'
                    elif reqdata.get('action') == 'add':
                        for u in userdata['users']:
                            if u['username'] == reqdata.get('username'):
                                return '<script>alert("用戶名已存在!");window.location.href = "./user"</script>'
                        newuser = {'name': reqdata.get('username'), 'password': reqdata.get('password'), 'token': ''.join(random.sample(string.ascii_letters + string.digits, 32)), 'videotimes': [], 'role': reqdata.get('role')}
                        userdata['users'].append(newuser)
                        with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                            json.dump(userdata, f, ensure_ascii=False, indent=4)
                        return '<script>alert("添加成功!");window.location.href = "./user"</script>'
        else:
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            return render_template('usermanage.html', users=userdata['users'])
        
    @app.route('/userinfo', methods=['GET', 'POST'])
    def userinfo():
        userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
        if request.method == 'POST':
            if request.form:
                reqdata = request.form.copy()
            else:
                reqdata = request.get_json()
            if not reqdata:
                return '<script>alert("Empty request!);history.back();</script>'
            for user in userdata['users']:
                if user['token'] == request.cookies.get('token'):
                    if reqdata.get('action') == 'get':
                        retData = user.copy()
                        retData['status'] = '200'
                        retData.pop('token')
                        retData.pop('password')
                        return jsonify(retData)
                    elif reqdata.get('action') == 'changepassword':
                        original_pw = reqdata.get('original_password')
                        if not original_pw == user['password']:
                            return jsonify({"status": "403", "message": "舊密碼驗證失敗！"})
                        pw1 = reqdata.get('new_password1')
                        pw2 = reqdata.get('new_password2')
                        if not pw1 == pw2:
                            return jsonify({"status": "403", "message": "新密碼不一致！"})
                        user['password'] = pw1
                        user['token'] = ''.join(random.sample(string.ascii_letters + string.digits, 32))
                        with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                            json.dump(userdata, f, ensure_ascii=False, indent=4)
                        return jsonify({"status": "200", "message": "修改成功!"})
        else:
            for user in userdata['users']:
                if user['token'] == request.cookies.get('token'):
                    return render_template('userinfo.html', user=user)
        return '<script>alert("Token is invalid!");window.location.href = "/login"</script>'


def run():
    settings = Config.read_settings()  # 读取配置

    port = settings['dashboard']['port']
    host = settings['dashboard']['host']

    # check cert if enabled ssl
    if settings['dashboard']['SSL']:
        ssl_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'sslkey')
        ssl_crt = os.path.join(ssl_path, 'server.crt')
        ssl_key = os.path.join(ssl_path, 'server.key')
        if not os.path.exists(ssl_crt) or not os.path.exists(ssl_key):
            err_print(0, 'Dashboard', '啟用了SSL，但是證書檔案不存在! 強制禁用', no_sn=True, status=1)
            settings['dashboard']['SSL'] = False

    if settings['dashboard']['SSL']:
        # SSL 配置
        ssl_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'sslkey')
        ssl_crt = os.path.join(ssl_path, 'server.crt')
        ssl_key = os.path.join(ssl_path, 'server.key')
        ssl_keys = (ssl_crt, ssl_key)
        # app.run(use_reloader=False, port=port, host=host, ssl_context=ssl_keys, threaded=True)
        server = WSGIServer((host, port), app, handler_class=WebSocketHandler, certfile=ssl_crt, keyfile=ssl_key, environ={'wsgi.multithread': True,'wsgi.multiprocess': True,})

        wrap_socket = server.wrap_socket
        wrap_socket_and_handle = server.wrap_socket_and_handle

        # 处理一些浏览器(比如Chrome)尝试 SSL v3 访问时报错
        def my_wrap_socket(sock, **_kwargs):
            try:
                # print('my_wrap_socket')
                return wrap_socket(sock, **_kwargs)
            except ssl.SSLError:
                # print('my_wrap_socket ssl.SSLError')
                pass
            except ssl.SSLEOFError:
                pass

        # 此方法依赖上面的返回值, 因此当尝试访问 SSL v3 时, 这个也会出错
        def my_wrap_socket_and_handle(client_socket, address):
            try:
                # print('my_wrap_socket_and_handle')
                return wrap_socket_and_handle(client_socket, address)
            except AttributeError:
                # print('my_wrap_socket_and_handle AttributeError')
                pass
            except TypeError:
                pass
            except ConnectionResetError:
                pass

        server.wrap_socket = my_wrap_socket
        server.wrap_socket_and_handle = my_wrap_socket_and_handle

    else:
        # app.run(use_reloader=False, port=port, host=host, threaded=True)
        server = WSGIServer((host, port), app, handler_class=WebSocketHandler, environ={'wsgi.multithread': True,'wsgi.multiprocess': True,})

    server.serve_forever()


if __name__ == '__main__':
    run()
    pass
