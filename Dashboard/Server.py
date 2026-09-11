#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# @Time    : 2019/6/26 16:12
# @Author  : Miyouzi
# @File    : Server.py
# @Software: PyCharm

# FastAPI/ASGI implementation of the Dashboard web server.
#
# This is a real migration, not a compatibility wrapper: every route below is
# a native FastAPI/Starlette route, streaming uses Starlette responses, and
# the task-progress channel is a native FastAPI WebSocket. No Flask, no
# flask-sock, no gevent, no monkey patching.
#
# Blocking work (curl_cffi network I/O, filesystem reads, ffmpeg, downloader
# threads, PBKDF2/scrypt hashing, config/userdata I/O, command handling) must
# never run on the ASGI event loop. The convention in this file:
# plain ``def`` endpoints are executed by FastAPI in its worker threadpool, so
# ordinary blocking calls inside them are safe. ``async def`` endpoints run
# authentication/settings guards in the threadpool before parsing bounded
# request bodies, then dispatch remaining blocking work there as well.
# ``_offload()`` is therefore a direct call -- the caller is already off the
# event loop.

import asyncio
import json, sys, os, re, time
import tempfile
import threading, traceback
import random, string, hashlib, hmac, secrets
import platform, shutil, subprocess

from curl_cffi import requests as curl_requests
from aniGamerPlus import Config
from aniGamerPlus import __cui as cui
from aniGamerPlus import __get_danmu_only
import Catalog
import logging
from ColorPrint import err_print
from logging.handlers import TimedRotatingFileHandler
import mimetypes
from email.utils import formatdate
import urllib.parse
from datetime import datetime
from plugin_system import PluginManager

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import (
    JSONResponse, PlainTextResponse, RedirectResponse, Response,
    StreamingResponse, FileResponse,
)
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.concurrency import run_in_threadpool
import uvicorn

mimetypes.add_type('text/css', '.css')
mimetypes.add_type('application/x-javascript', '.js')
template_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'templates')
static_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'static')
templates = Jinja2Templates(directory=template_path)

# No API docs: the original server exposed no schema endpoints, and this is a
# self-hosted dashboard, not a public API.
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
app.mount('/static', StaticFiles(directory=static_path), name='static')

# Dashboard requests are small JSON/forms. Bound both declared and streamed
# bodies so unauthenticated clients cannot make Starlette buffer arbitrary
# amounts of memory before a route can authenticate them.
MAX_REQUEST_BODY_BYTES = 2 * 1024 * 1024


class _RequestBodyTooLarge(Exception):
    pass


class _RequestBodyLimitMiddleware:
    def __init__(self, asgi_app, max_body_size):
        self.app = asgi_app
        self.max_body_size = max_body_size

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get('headers') or [])
        try:
            content_length = int(headers.get(b'content-length', b'0'))
        except (TypeError, ValueError):
            content_length = 0
        if content_length > self.max_body_size:
            await JSONResponse({'detail': 'Request body too large'}, status_code=413)(
                scope, receive, send)
            return

        received = 0
        response_started = False

        async def limited_receive():
            nonlocal received
            message = await receive()
            if message['type'] == 'http.request':
                received += len(message.get('body', b''))
                if received > self.max_body_size:
                    raise _RequestBodyTooLarge
            return message

        async def tracked_send(message):
            nonlocal response_started
            if message['type'] == 'http.response.start':
                response_started = True
            await send(message)

        try:
            await self.app(scope, limited_receive, tracked_send)
        except _RequestBodyTooLarge:
            if response_started:
                raise
            await JSONResponse({'detail': 'Request body too large'}, status_code=413)(
                scope, receive, send)


app.add_middleware(_RequestBodyLimitMiddleware,
                   max_body_size=MAX_REQUEST_BODY_BYTES)

# 日志处理
logger = logging.getLogger('dashboard')
logging.basicConfig(level=logging.INFO)  # 记录访问
web_log_path = os.path.join(Config.get_working_dir(), 'logs', 'web.log')
os.makedirs(os.path.dirname(web_log_path), exist_ok=True)
handler = TimedRotatingFileHandler(filename=web_log_path, when='midnight', backupCount=7, encoding='utf-8')
handler.suffix = '%Y-%m-%d.log'
handler.extMatch = re.compile(r'^\d{4}-\d{2}-\d{2}.log')
logger.addHandler(handler)
logger.propagate = False  # 不在控制台上输出
logging.getLogger('uvicorn.access').addHandler(handler)

# websocket鉴权不再需要 token, 进度通道直接认管理員 cookie (见 tasks_progress).
# 这个 token 只保留给 /data/get_token 的兼容回應 (monitor.js 之前的版本会来取).
websocket_token = ''.join(random.sample(string.ascii_letters + string.digits, 32))


@app.middleware('http')
async def add_accept_ranges(request: Request, call_next):
    # 原 Flask 版 after_request 给每条回應都加 Accept-Ranges: bytes, 播放器和
    # 下载器靠它判断能不能断点续传, 原样保留.
    response = await call_next(request)
    if 'accept-ranges' not in response.headers:
        response.headers['Accept-Ranges'] = 'bytes'
    return response


# 8 KB 一塊是給區網外的細線路留的保守值, 但代價是一集 500 MB 要跑六萬多次
# read + write. 播放器一開就是幾十 MB 的 Range, 每一塊都要繞一趟排程,
# CPU 全花在切塊上. 256 KB 仍然遠小於任何一個播放器的緩衝區, 記憶體
# 占用可以忽略, 但系統呼叫少了三十倍.
VIDEO_CHUNK_SIZE = 256 * 1024


def generate_file(path, start, length, chunk_size=VIDEO_CHUNK_SIZE):
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


def http_date(timestamp):
    """RFC 1123 GMT 时间, 原来由 werkzeug.http.http_date 提供."""
    return formatdate(timestamp, usegmt=True)


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
# Single global userdata lock. RLock so load/save stay re-entrant inside the
# transactional helper below (and inside load's own normalize-and-save path);
# there is exactly one userdata lock -- no inconsistent lock ordering.
userdata_lock = threading.RLock()
userdata_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json')
PLUGIN_RELOAD_INTERVAL_SECONDS = 30

# 新密码一律用这个格式存; _check_hash 同时认得 werkzeug 写下的旧格式, 老用户
# 不必改密码就能继续登入.
_PBKDF2_HASH_ITERATIONS = 260000


def _generate_token():
    return secrets.token_urlsafe(32)


def _normalize_username(value):
    return str(value or '').strip()


def _normalize_role(value):
    return 'admin' if str(value).lower() == 'admin' else 'user'


def _hash_password(password):
    # Canonical format going forward is werkzeug-compatible: the salt is a
    # literal ASCII string and the digest runs over salt.encode().
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        'sha256', str(password).encode('utf-8'),
        salt.encode('utf-8'), _PBKDF2_HASH_ITERATIONS)
    return 'pbkdf2:sha256:%d$%s$%s' % (_PBKDF2_HASH_ITERATIONS, salt, digest.hex())


def _check_hash(stored, password):
    """验 werkzeug 留下的旧哈希 (pbkdf2 与 scrypt 两种写法) 以及本模块的新哈希.

    userdata.json 里躺着的是 generate_password_hash 写的东西, 换哈希库不能把
    老用户锁在门外, 所以这里把它的两种字符串格式都认下来, 输对了就过.

    werkzeug 把 salt 当成字面 ASCII 字符串, 摘要跑在 salt.encode() 上.
    迁移初期的 _hash_password 误用了 bytes.fromhex(salt); 那些已写下的哈希
    在这里用 fallback 继续认, 新写的一律走 ASCII 语义.
    """
    try:
        method, _, rest = str(stored).partition('$')
        salt, _, hashed = rest.partition('$')
        if not method or not salt or not hashed:
            return False
        secret = str(password).encode('utf-8')
        if method.startswith('pbkdf2:sha256:'):
            iterations = int(method.rsplit(':', 1)[1])
            candidate = hashlib.pbkdf2_hmac(
                'sha256', secret, salt.encode('utf-8'), iterations)
            if hmac.compare_digest(candidate.hex(), hashed):
                return True
            try:
                legacy = hashlib.pbkdf2_hmac(
                    'sha256', secret, bytes.fromhex(salt), iterations)
            except (ValueError, TypeError):
                return False
            return hmac.compare_digest(legacy.hex(), hashed)
        if method.startswith('scrypt:'):
            try:
                _, n, r, p = method.split(':')
                n_i, r_i, p_i = int(n), int(r), int(p)
            except (ValueError, TypeError):
                return False
            # werkzeug passes maxmem=132*n*r*p to hashlib.scrypt; without it
            # OpenSSL rejects its default parameters ("memory limit exceeded").
            # Bounds keep a malformed local hash from triggering unbounded
            # allocation: real hashes use n=2**14..2**15, r=8, p=1.
            if n_i < 2 or r_i < 1 or p_i < 1:
                return False
            if n_i > 2 ** 20 or r_i > 64 or p_i > 64:
                return False
            maxmem = 132 * n_i * r_i * p_i
            dklen = len(hashed) // 2
            try:
                candidate = hashlib.scrypt(
                    secret, salt=salt.encode('utf-8'),
                    n=n_i, r=r_i, p=p_i, dklen=dklen, maxmem=maxmem)
            except (ValueError, TypeError, MemoryError, OverflowError):
                return False
            if hmac.compare_digest(candidate.hex(), hashed):
                return True
            try:
                legacy = hashlib.scrypt(
                    secret, salt=bytes.fromhex(salt),
                    n=n_i, r=r_i, p=p_i, dklen=dklen, maxmem=maxmem)
            except (ValueError, TypeError, MemoryError, OverflowError):
                return False
            return hmac.compare_digest(legacy.hex(), hashed)
    except (ValueError, TypeError):
        return False
    return False


def _verify_password(user, password):
    password = str(password or '')
    password_hash = user.get('password_hash')
    if password_hash and _check_hash(password_hash, password):
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


def _save_userdata_locked(userdata):
    """Atomic filesystem write. Caller must hold userdata_lock.

    Writes a temp file in the same directory, flushes/fsyncs, then
    os.replace() so readers never see a truncated document. On failure the
    temp file is removed and the destination is left untouched.
    """
    directory = os.path.dirname(os.path.abspath(userdata_path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    else:
        directory = '.'
    fd, tmp_name = tempfile.mkstemp(prefix='.userdata-', suffix='.tmp', dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(userdata, f, ensure_ascii=False, indent=4)
            f.flush()
            try:
                os.fsync(f.fileno())
            except OSError:
                pass
        os.replace(tmp_name, userdata_path)
        try:
            dir_fd = os.open(directory, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        except OSError:
            dir_fd = None
        if dir_fd is not None:
            try:
                try:
                    os.fsync(dir_fd)
                except OSError:
                    pass
            finally:
                os.close(dir_fd)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def save_user_data(userdata):
    with userdata_lock:
        _save_userdata_locked(userdata)


def _load_userdata_locked():
    """Read + normalize + merge default users. Caller must hold userdata_lock."""
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
        _save_userdata_locked(userdata)
    return userdata


def load_user_data():
    """Synchronized read: holds the userdata lock for the whole
    read-normalize-(maybe-)write so readers never race a truncate/rewrite."""
    with userdata_lock:
        return _load_userdata_locked()


def update_user_data(mutator):
    """Run a complete read-modify-write under one lock scope.

    ``mutator`` receives the live ``userdata`` dict and returns either
    ``(result, dirty)`` or just ``result`` (saved when dirty is truthy).
    Implemented via the public load/save funnels so monkeypatched
    persistence in tests keeps working; the outer RLock still serializes
    concurrent transactions.
    """
    with userdata_lock:
        userdata = load_user_data()
        outcome = mutator(userdata)
        if isinstance(outcome, tuple) and len(outcome) == 2:
            result, dirty = outcome
        else:
            result, dirty = outcome, True
        if dirty:
            save_user_data(userdata)
        return result


# Alias kept for readability at call sites / tests.
def userdata_transaction(mutator):
    return update_user_data(mutator)


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


def _redirect(url):
    # Starlette 默认 307, Flask 是 302: 浏览器/APP 都认的是 302, 必须显式指定.
    return RedirectResponse(url, status_code=302)


def _html_response(text, status_code=200):
    # 原 Flask 版直接 return 字符串, 默认 Content-Type 是 text/html, 原样保留.
    return Response(content=text, media_type='text/html', status_code=status_code)


def _user_page_guard(request, current_settings):
    """user_page_required 的 FastAPI 版: 返回 None 表示放行, 否则直接回給客户端."""
    if not current_settings['dashboard']['user_control']['enabled']:
        return None
    user = find_user_by_token(request.cookies.get('token'))
    if not user:
        return _redirect("./login?error=2")
    request.state.current_user = user
    return None


def _admin_page_guard(request, current_settings):
    if not current_settings['dashboard']['user_control']['enabled']:
        return None
    user = find_user_by_token(request.cookies.get('token'))
    if not user:
        return _redirect("./login?error=2")
    if user.get('role') != 'admin':
        destination = "./watch" if current_settings['dashboard'].get('online_watch') else "/"
        return _redirect(destination)
    request.state.current_user = user
    return None


def _admin_api_guard(request, current_settings):
    if not current_settings['dashboard']['user_control']['enabled']:
        return None
    user = find_user_by_token(request.cookies.get('token'))
    if not user:
        return JSONResponse({'success': False, 'message': 'login required'}, status_code=401)
    if user.get('role') != 'admin':
        return JSONResponse({'success': False, 'message': 'admin required'}, status_code=403)
    request.state.current_user = user
    return None


def _online_watch_gate(current_settings):
    # 原版路由是 import 时按 online_watch 开关有条件注册的, 关掉就 404. 这里改成
    # 每次请求现看开关, 行为一样 (关掉就是 404), 但改配置不必重启.
    if current_settings['dashboard'].get('online_watch'):
        return None
    return JSONResponse({'error': 'not found'}, status_code=404)


def _user_control_gate(current_settings):
    # /login 等路由原版只在 user_control 打开时才存在, 关掉就是 404, 原样保留.
    if current_settings['dashboard']['user_control']['enabled']:
        return None
    return JSONResponse({'error': 'not found'}, status_code=404)


def _admin_api_preflight(request):
    current_settings = _get_current_settings()
    return _admin_api_guard(request, current_settings)


def _admin_page_preflight(request):
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    return _admin_page_guard(request, current_settings)


def _user_page_preflight(request):
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    return _user_page_guard(request, current_settings)


def _login_preflight():
    return _user_control_gate(_get_current_settings())


def _register_preflight():
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    if not current_settings['dashboard']['user_control']['allow_register']:
        return _html_response('<script>alert("註冊功能未啟用");history.back();</script>')
    return None


def _watch_time_preflight(token):
    if find_user_by_token(token):
        return None
    return _html_response('{"status":"403", "msg":"Invalid token"}')


async def _form_or_json(request):
    """Flask 版 `request.form if request.form else request.get_json()` 的等价写法."""
    try:
        form = await request.form()
    except Exception:
        form = None
    if form:
        return dict(form)
    try:
        data = await request.json()
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


async def _json_then_form(request):
    """Flask 版 `request.get_json() or request.form` 的等价写法 (register/webtime 用这个顺序)."""
    try:
        data = await request.json()
    except Exception:
        data = None
    if isinstance(data, dict) and data:
        return data
    try:
        form = await request.form()
    except Exception:
        return {}
    return dict(form)


def _run_console_command_blocking(raw_command):
    """Sync console-command execution; runs in a worker thread via run_in_threadpool."""
    if not raw_command:
        return JSONResponse({'success': False, 'message': '請輸入指令'}, status_code=400)

    if not callable(command_handler):
        return JSONResponse({'success': False, 'message': '指令處理器尚未初始化'}, status_code=503)

    try:
        result = command_handler(raw_command, show_detail=True)
    except BaseException as e:
        return JSONResponse({'success': False, 'message': str(e)}, status_code=500)

    success = bool(result.get('success', False))
    body = {
        'success': success,
        'message': result.get('message', ''),
    }
    if result.get('help', False):
        body['help'] = True
        body['commands'] = result.get('commands', [])

    err_print(0, 'Dashboard', f'通過 Web 控制臺執行指令: {raw_command}', no_sn=True, status=2 if success else 1)
    return JSONResponse(body, status_code=200 if success else 400)


async def _handle_web_console_command(request):
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    raw_command = str(payload.get('command', '')).strip()
    return await run_in_threadpool(_run_console_command_blocking, raw_command)

caches = {}
danmu_update_timestamps = {}
DANMU_UPDATE_INTERVAL_SECONDS = 6 * 60 * 60


# video_list.json 是幾乎每一條路由的第一件事: 播放要查路徑, 縮圖、劇集表、
# 線上畫質都要先確認這個 sn 是自己人. 播一集光是 Range 請求就有上百個, 每個
# 都重讀重解析整份片庫 —— 片庫大起來之後這是伺服器最花時間的一段. 用檔案的
# (mtime, size) 當版本號快取, 下載器一寫新的一集就自動失效.
_video_list_cache = {'sig': None, 'data': {'videos': []}, 'index': {}}


def _read_video_list_file():
    return _load_video_list()['data']


def _load_video_list():
    video_list_path = os.path.join(Config.get_working_dir(), 'video_list.json')
    try:
        stat = os.stat(video_list_path)
        sig = (stat.st_mtime_ns, stat.st_size)
    except OSError:
        # 還沒下載過任何一集, 檔案根本不存在
        if _video_list_cache['sig'] is not None:
            _video_list_cache.update(sig=None, data={'videos': []}, index={})
        return _video_list_cache

    if _video_list_cache['sig'] == sig:
        return _video_list_cache

    try:
        with open(video_list_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError):
        # 下載器正在改寫這份檔案. 舊的那份還能用, 下一次請求再試
        return _video_list_cache

    index = {}
    for video in data.get('videos', []):
        # 同一集可能存了好幾種畫質, 先來的先贏跟原本的線性掃描結果一致
        index.setdefault(str(video.get('sn')), video)
    _video_list_cache.update(sig=sig, data=data, index=index)
    return _video_list_cache


def _find_video_entry(sn):
    return _load_video_list()['index'].get(str(sn))


def _find_video_path(sn, resolution=None):
    """Config.getpath(sn, 'video') 的快取版.

    順手補掉原本那個行為: 沒帶 res 或帶了看不懂的 res 時, getpath() 會在
    int(None) 上丟例外, 吞掉之後一律回 None —— 也就是 /get_video.mp4?id=123
    永遠 404. 片庫裡有這一集就該播得出來, 挑不到指定畫質才退回第一個。
    """
    sn_str = str(sn)
    try:
        wanted = int(resolution)
    except (TypeError, ValueError):
        wanted = None

    fallback = None
    for video in _load_video_list()['data'].get('videos', []):
        if str(video.get('sn')) != sn_str:
            continue
        if wanted is not None and video.get('resolution') == wanted:
            return video.get('path')
        if fallback is None:
            fallback = video.get('path')
    return fallback


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
    # 原 Flask/gevent 版把 curl_cffi 丢进 hub 的真线程池, 因为补丁管
    # 不到 C 里的 socket I/O. 现在 plain-def 路由本来就跑在 FastAPI 的工作线程
    # 池里, 根本不在事件循环上, 直接调就行 —— 再套一层线程池只是多一次切换.
    return func(*args, **kwargs)


def _curl_perform(session_kwargs, url, request_kwargs):
    session = curl_requests.Session(**session_kwargs)
    return session.request('get', url, **request_kwargs)


def _bahamut_get(url, timeout=10, allow_redirects=True, extra_headers=None):
    """跟 Config.bahamut_request 用同一套指纹, 但配置在工作线程上读完再请求.

    read_settings() 顺手会删过期日志、必要时重写配置文件, 这些副作用一直只在
    请求线程里发生, 彼此不会交错; 而 libcurl 的 perform 本来就是阻塞调用,
    在工作线程里跑刚刚好.
    """
    settings = Config.read_settings()
    fingerprint = settings.get('browser_fingerprint') or {}
    session_kwargs = {
        'impersonate': 'firefox' if 'firefox' in settings['ua'].lower() else 'chrome',
        'ja3': fingerprint.get('ja3') or None,
        'akamai': fingerprint.get('akamai') or None,
    }
    request_kwargs = {'headers': {'User-Agent': settings['ua']}, 'timeout': timeout}
    if extra_headers:
        # CDN 上的 chunklist/分片要 Origin 才肯给, 见 Anime.py parse_playlist()
        request_kwargs['headers'].update(extra_headers)
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
        time.sleep(delay)
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
        time.sleep(CATALOG_CRAWL_DELAY)
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
        thread = threading.Thread(target=_refresh_catalog_all, daemon=True)
        thread.start()
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


def _catalog_login_error(current_settings, request):
    # 片单跟片库同一道门: 设了要登入才能看, 片单也不该是敞开的
    if current_settings['dashboard']['online_watch_requires_login']:
        vaild_user, user_role = verify_user(request.cookies)
        if not vaild_user:
            return JSONResponse({"error": "login required"}, status_code=403)
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
    resp = JSONResponse({"error": "thumbnail unavailable"}, status_code=404)
    # 让浏览器也记着这次没图, 否则首页每重绘一次就要再问服务端一遍
    resp.headers['Cache-Control'] = 'private, max-age=%d' % THUMBNAIL_RETRY_INTERVAL
    return resp


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


# read_settings() 每次都重讀重驗 config.json, 還會順手掃 log 目錄、必要時回寫
# 檔案. 播一集的 Range 請求、進度輪詢、縮圖加起來一分鐘就有上百個請求, 每個都
# 跑一遍太浪費. 三秒內共用同一份 —— 從控制臺存設定會直接把它作廢, 所以使用者
# 不會看到自己剛改的東西沒生效.
SETTINGS_TTL = 3.0
_settings_cache = {'at': 0.0, 'settings': None}


def _invalidate_settings_cache():
    _settings_cache['settings'] = None


def _get_current_settings():
    now = time.monotonic()
    cached = _settings_cache['settings']
    # 不上鎖: 请求跑在各自的工作线程里, 最壞只是兩個人同時去讀一次設定
    if cached is None or now - _settings_cache['at'] > SETTINGS_TTL:
        cached = Config.read_settings()
        _settings_cache['settings'] = cached
        _settings_cache['at'] = now
    return cached


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


def _get_request_user(request, current_settings=None):
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


def _build_dashboard_bootstrap(request, extra=None, current_settings=None):
    current_settings = current_settings or _get_current_settings()
    user = _get_request_user(request, current_settings)
    bootstrap = {
        'serverInfo': _get_dashboard_flags(current_settings),
        'loggedIn': bool(user),
        'currentUser': _build_safe_user(user),
    }
    if extra:
        bootstrap.update(extra)
    return bootstrap


def _render(request, name, context=None, status_code=200):
    # 原 Flask 版 context_processor 给每个模板都塞 dashboard_bootstrap, 这里在
    # 渲染点拼进去, 模板拿到的变量名不变.
    merged = {'request': request,
              'dashboard_bootstrap': _build_dashboard_bootstrap(request)}
    if context:
        merged.update(context)
    return templates.TemplateResponse(request, name, merged, status_code=status_code)


# ----------------------------------------------------------------- 邊看邊下載
# Anime.py 的 __segment_download_mode() 會把每一片 .ts 丟進 temp 下的一個目錄, 最後
# 才用 ffmpeg 合成 mp4. 也就是說, 下載到一半的集數在磁碟上本來就是一份 HLS 串流,
# 只要把已經落地的前綴當成 playlist 發出去, 就能邊下載邊看 —— 而且完全不必再跟
# 動畫瘋多要一份影片, 併發數跟帳號風險都跟原本的下載一模一樣.
HLS_TEMP_SUFFIX = '-downloading-by-aniGamerPlusPlus'
# key.m3u8key 是 Anime.py 自己取的檔名, 出現在 m3u8 裡就表示這份已經被改寫成
# 給 ffmpeg 吃的本機路徑版, 不能再發給瀏覽器
HLS_LOCALISED_MARKER = 'key.m3u8key'
HLS_MIME = 'application/vnd.apple.mpegurl'

_hls_playlist_cache = {}  # sn(str) -> {'sig': (mtime, size), 'parsed': {...}}


def _hls_settings():
    # hls.js 每 5~10 秒重抓一次 playlist, 加上狀態輪詢跟 chunk, 一個觀眾一分鐘就有
    # 十幾個請求. 這裡本來自己留一份快取, 現在 _get_current_settings() 已經是
    # 快取版, 直接共用同一份就好 —— 少一個各自過期、各自不一致的來源.
    return _get_current_settings()


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


def _hls_bootstrap_entry(sn, current_settings, request):
    """給正在下載的集數捏一筆 video_list 形狀的資料.

    /watch 之所以能擺出播放器而不是「找不到這一集影片」, 就是因為 watch.js 拿到的
    東西跟真正的片庫條目長得一模一樣 —— renderTitleBar、資訊卡、集數列、setTime
    通通不必知道有串流這回事. 多出來的那兩個 key 才是播放器要分支的地方.
    """
    if not current_settings.get('segment_download_mode'):
        return None

    task = _hls_task(sn)
    pending = task is None
    if pending and not request.query_params.get('streaming'):
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


# --------------------------------------------------------------- 線上切換畫質
# 片庫裡一集只留一種畫質 —— video_list.json 一個 sn 就一筆, Config.getpath() 又是
# 拿 resolution 去精確比對, 所以 /get_video.mp4 換個 res 只會 404. 上面那組 /hls/*
# 也救不了: _hls_state() 只要看到片庫裡有這一集就直接回 mode=file.
#
# 真正還留著別的畫質的地方只有動畫瘋自己. Anime.get_m3u8_dict() 會把 master
# playlist 拆成 {畫質: chunklist 網址}, 這一段就是把那份東西代理出去 —— 播放器要
# 720P, 伺服器就現去拿 720P 的 chunklist, 金鑰跟分片轉手發給它. 磁碟上什麼都不留,
# 也完全不碰下載佇列.
STREAM_TTL = 30 * 60      # chunklist 網址是簽名過的, 半小時內重用是安全的
STREAM_CACHE_MAX = 16     # 解析結果只是幾 KB 的字串表, 留最近幾集就夠
STREAM_ORIGIN_HEADER = {
    'Origin': 'https://ani.gamer.com.tw',
    'Referer': 'https://ani.gamer.com.tw/',
}

_stream_dict_cache = {}   # sn(str) -> {'at': monotonic, 'dict': {res(str): chunklist url}}
_stream_media_cache = {}  # 'sn/res' -> {'at':, 'parsed':, 'base':, 'key': bytes|None}


def _stream_trim_cache(cache):
    # 沒有 TTL 掃描執行緒, 就在寫入時順手把最舊的踢掉, 免得開久了無限長
    while len(cache) > STREAM_CACHE_MAX:
        oldest = min(cache, key=lambda key: cache[key]['at'])
        cache.pop(oldest, None)


def _stream_allowed(sn):
    """跟 /watch/series.json 同一道門: 不讓任何人隨手指定 sn 就叫伺服器去捶動畫瘋.

    這裡比那邊更值得防 —— 代理會真的用我們的帳號去解析播放位址, 變成請求放大器的
    代價比多抓一份劇集列表高得多. 只認片庫裡有的、正在下載的, 或是某部已快取劇集
    表裡列到的集數.
    """
    if _find_video_entry(sn) is not None:
        return True
    if _hls_task(sn) is not None:
        return True
    return str(sn) in _episode_owners()


def _stream_resolve_blocking(sn):
    # 延後匯入: Anime 進來會一路拉起 yt_dlp/bs4, 而且它跟 Server.py 是被
    # aniGamerPlus.py 一起載的 —— 擺在模組頂端就得跟那邊的匯入順序賭運氣
    from Anime import Anime
    anime = Anime(int(sn))
    return dict(anime.get_m3u8_dict())


def _stream_dict(sn):
    """{畫質: chunklist 網址}, 解析一次快取 30 分鐘."""
    sn_key = str(sn)
    cached = _stream_dict_cache.get(sn_key)
    if cached and time.monotonic() - cached['at'] < STREAM_TTL:
        return cached['dict']

    # 一集只解析一次: 同一集被兩個人同時打開時, 不該把解鎖/廣告那一串跟動畫瘋的
    # 互動做兩遍
    with _keyed_lock('stream-%s' % sn_key):
        cached = _stream_dict_cache.get(sn_key)
        if cached and time.monotonic() - cached['at'] < STREAM_TTL:
            return cached['dict']
        try:
            m3u8_dict = _offload(_stream_resolve_blocking, sn_key)
        except KeyboardInterrupt:
            raise
        except BaseException as error:
            # BaseException 不是手滑: Anime.__get_m3u8_dict() 碰到地區限制、帳號
            # 問題或去廣告失敗是直接 sys.exit(1), 在工作线程裡那會變成
            # SystemExit 掛在呼叫上. 讓它飛出去這條請求就只會是一個沒說明的 500
            err_print(sn_key, '線上畫質', '解析可用畫質失敗: %s' % error,
                      status=1, display=False)
            m3u8_dict = {}
        entry = {'at': time.monotonic(), 'dict': m3u8_dict}
        _stream_dict_cache[sn_key] = entry
        _stream_trim_cache(_stream_dict_cache)
        return m3u8_dict


def _stream_absolute(base, uri):
    # chunklist 裡的金鑰跟分片不保證是完整網址, 相對路徑要自己補回去
    if re.match(r'https?://', uri, re.I):
        return uri
    return base.rstrip('/') + '/' + uri.lstrip('/')


def _stream_parse_media(text):
    """把 chunklist 拆成 (金鑰行, 有序的分片 URI 表).

    不共用 _hls_parse_playlist(): 那一支刻意只留 media_b….ts 那一段檔名, 因為下載器
    是拿同一個名字去 stat 磁碟上的分片, 帶著查詢字串就對不上了. 代理要的剛好相反
    —— 原樣的 URI 才組得回回源網址. 所以這裡什麼都不砍, 也不挑檔名長什麼樣子.
    """
    key_line = ''
    key_uri = ''
    target_duration = 10
    segments = []
    pending_extinf = ''
    pending_duration = 10.0

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith('#EXT-X-KEY') and 'AES-128' in line:
            key_line = line
            match = re.search(r'URI="([^"]*)"', line)
            key_uri = match.group(1) if match else ''
        elif line.startswith('#EXT-X-TARGETDURATION'):
            try:
                target_duration = max(1, int(float(line.split(':', 1)[1])))
            except (IndexError, ValueError):
                pass
        elif line.startswith('#EXTINF'):
            pending_extinf = line
            try:
                pending_duration = float(line.split(':', 1)[1].split(',')[0])
            except (IndexError, ValueError):
                pending_duration = float(target_duration)
        elif not line.startswith('#'):
            segments.append({
                'uri': line,
                'extinf': pending_extinf or '#EXTINF:%.3f,' % pending_duration,
                'duration': pending_duration,
            })
            pending_extinf = ''
            pending_duration = float(target_duration)

    if not key_line or not key_uri or not segments:
        # 動畫瘋的 VOD 一律是 AES-128 加密的. 解不出金鑰行就表示我們拿到的根本不是
        # 想要的東西 (多半是錯誤頁), 寧可整份不認
        return None
    return {
        'key_line': key_line,
        'key_uri': key_uri,
        'target_duration': target_duration,
        'segments': segments,
        'total_duration': sum(segment['duration'] for segment in segments),
    }


def _stream_media(sn, res):
    """某個畫質解析好的分片表, 外加組回源網址用的前綴."""
    cache_key = '%s/%s' % (sn, res)
    cached = _stream_media_cache.get(cache_key)
    if cached and time.monotonic() - cached['at'] < STREAM_TTL:
        return cached

    with _keyed_lock('stream-media-%s' % cache_key):
        cached = _stream_media_cache.get(cache_key)
        if cached and time.monotonic() - cached['at'] < STREAM_TTL:
            return cached

        url = _stream_dict(sn).get(str(res))
        if not url:
            return None
        try:
            upstream = _bahamut_get(url, timeout=15, extra_headers=STREAM_ORIGIN_HEADER)
        except KeyboardInterrupt:
            raise
        except BaseException as error:
            err_print(sn, '線上畫質', '取得 %sP 播放清單失敗: %s' % (res, error),
                      status=1, display=False)
            return None
        if upstream.status_code != 200:
            return None

        parsed = _stream_parse_media(upstream.content.decode('utf-8', 'replace'))
        if parsed is None:
            return None
        entry = {
            'at': time.monotonic(),
            'parsed': parsed,
            'base': url.split('?', 1)[0].rsplit('/', 1)[0],
            'key': None,  # 真的有人來要 key.bin 時才回源, 拿到就留著
        }
        _stream_media_cache[cache_key] = entry
        _stream_trim_cache(_stream_media_cache)
        return entry


def _stream_key(sn, res, media):
    # 金鑰只有 16 bytes, 但 ExoPlayer/AVPlayer 不保證只要一次. 拿到就跟著這一份
    # chunklist 一起留著, 免得每次重載清單都往回源多打一發
    if media['key']:
        return media['key']
    try:
        upstream = _bahamut_get(_stream_absolute(media['base'], media['parsed']['key_uri']),
                                timeout=15, extra_headers=STREAM_ORIGIN_HEADER)
    except KeyboardInterrupt:
        raise
    except BaseException as error:
        err_print(sn, '線上畫質', '取得 %sP 金鑰失敗: %s' % (res, error),
                  status=1, display=False)
        return b''
    if upstream.status_code != 200 or not upstream.content:
        return b''
    media['key'] = upstream.content
    return media['key']


def _stream_render(sn, res, parsed):
    """把上游的 chunklist 改寫成全部指回我們自己的版本."""
    lines = [
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXT-X-TARGETDURATION:%d' % parsed['target_duration'],
        # 跟 _hls_render() 同一個理由: #EXT-X-KEY 沒帶 IV 時, IV 就是分片序號.
        # 重新編號會讓解密整個對不上
        '#EXT-X-MEDIA-SEQUENCE:0',
        # 這裡跟邊看邊下載不一樣 —— 上游那份是完整的一集, 不是還在長的東西, 所以是
        # VOD 而且一開始就有 ENDLIST, 播放器才肯讓人拖時間軸
        '#EXT-X-PLAYLIST-TYPE:VOD',
        # 用 re.sub 換掉 URI 而不是重寫整行: 上游要是有帶 IV=, 那個一定要原樣留著
        re.sub(r'URI="[^"]*"', 'URI="key.bin?id=%s&res=%s"' % (sn, res),
               parsed['key_line']),
    ]
    for index, segment in enumerate(parsed['segments']):
        lines.append(segment['extinf'])
        lines.append('segment.ts?id=%s&res=%s&n=%d' % (sn, res, index))
    lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


def _build_watch_bootstrap(request, current_settings=None):
    current_settings = current_settings or _get_current_settings()
    requested_sn = str(request.query_params.get('id') or '').strip()
    requested_resolution = str(request.query_params.get('res') or '').strip()
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
        initial_video = _hls_bootstrap_entry(requested_sn, current_settings, request)
        if initial_video is None:
            return bootstrap

    if requested_resolution and requested_resolution.isdigit():
        initial_video['resolution'] = requested_resolution

    bootstrap['initialVideoData'] = initial_video
    bootstrap['streaming'] = bool(initial_video.get('streaming'))
    bootstrap['initialVideoSeries'] = [video for video in video_list if video.get('anime_name') == initial_video.get('anime_name')]

    user = _get_request_user(request, current_settings)
    if user:
        resume_state = user.get('videotimes', {}).get(requested_sn, {})
        if not resume_state.get('ended'):
            bootstrap['resumeTime'] = int(resume_state.get('time', 0) or 0)

    return bootstrap


def _settings_signature(current_settings):
    return json.dumps(current_settings, ensure_ascii=False, sort_keys=True)


def _sync_plugin_manager(force=False):
    global plugin_manager_last_reload_at, plugin_manager_settings_signature
    global plugin_manager_settings_object, settings

    current_settings = _get_current_settings()
    now = time.monotonic()

    # /get_video.mp4 每一個 Range 請求都會走到這裡, 一集就有上百次. 設定現在是
    # 快取的, 同一份物件連指紋都不必重算 —— json.dumps 整份設定不便宜.
    if current_settings is plugin_manager_settings_object and not force:
        if now - plugin_manager_last_reload_at < PLUGIN_RELOAD_INTERVAL_SECONDS:
            return current_settings
        signature = plugin_manager_settings_signature
    else:
        signature = _settings_signature(current_settings)

    if force or signature != plugin_manager_settings_signature or now - plugin_manager_last_reload_at >= PLUGIN_RELOAD_INTERVAL_SECONDS:
        plugin_manager.reload(current_settings)
        plugin_manager_settings_signature = signature
        plugin_manager_last_reload_at = now
        settings = current_settings

    plugin_manager_settings_object = current_settings
    return current_settings


# 读取web需要的配置名称列表
id_list_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'static', 'js', 'settings_id_list.js')
with open(id_list_path, 'r', encoding='utf-8') as f:
    id_list = re.sub(r'(var id_list\s*=\s*|\s*\n?)', '', f.read()).replace('\'', '"')
    id_list = json.loads(id_list)

settings = _get_current_settings()
plugin_manager = PluginManager(settings)
plugin_manager_settings_signature = _settings_signature(settings)
plugin_manager_settings_object = settings
plugin_manager_last_reload_at = time.monotonic()


@app.get('/control')
def control(request: Request):
    current_settings = _get_current_settings()
    denied = _admin_page_guard(request, current_settings)
    if denied is not None:
        return denied
    return _render(request, 'control.html')


@app.get('/monitor')
def monitor(request: Request):
    current_settings = _get_current_settings()
    denied = _admin_page_guard(request, current_settings)
    if denied is not None:
        return denied
    return _render(request, 'monitor.html')


@app.get('/data/config.json')
def config(request: Request):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
    settings = Config.read_settings()
    web_settings = {}
    for id in id_list:
        if id == 'browser_fingerprint':
            web_settings['browser_fingerprint_ja3'] = settings[id]['ja3']
            web_settings['browser_fingerprint_akamai'] = settings[id]['akamai']
        else:
            web_settings[id] = settings[id]  # 仅返回 web 需要的配置

    return JSONResponse(web_settings)


@app.post('/uploadConfig')
async def recv_config(request: Request):
    denied = await run_in_threadpool(_admin_api_preflight, request)
    if denied is not None:
        return denied
    # Only body parsing stays on the event loop; config file I/O runs pooled.
    data = await request.json()
    return await run_in_threadpool(_recv_config_blocking, request, data)


def _recv_config_blocking(request, data):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
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
    _invalidate_settings_cache()
    _sync_plugin_manager(force=True)
    err_print(0, 'Dashboard', '通過 Web 控制臺更新了 config.json', no_sn=True, status=2)
    return _html_response('{"status":"200"}')


@app.post('/manualTask')
async def manual_task(request: Request):
    denied = await run_in_threadpool(_admin_api_preflight, request)
    if denied is not None:
        return denied
    data = await request.json()
    return await run_in_threadpool(_manual_task_blocking, request, data)


def _manual_task_blocking(request, data):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
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
    return _html_response('{"status":"200"}')


@app.get('/data/sn_list')
def show_sn_list(request: Request):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
    return _html_response(Config.get_sn_list_content())


@app.get('/data/get_token')
def get_token(request: Request):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
    global websocket_token
    # 生成 32 位随机字符串作为token
    websocket_token = ''.join(random.sample(string.ascii_letters + string.digits, 32))
    return JSONResponse({'token': websocket_token, 'legacy': True})


@app.post('/sn_list')
async def set_sn_list(request: Request):
    denied = await run_in_threadpool(_admin_api_preflight, request)
    if denied is not None:
        return denied
    data = (await request.body()).decode('utf-8')
    return await run_in_threadpool(_set_sn_list_blocking, request, data)


def _set_sn_list_blocking(request, data):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
    Config.write_sn_list(data)
    err_print(0, 'Dashboard', '通過 Web 控制臺更新了 sn_list', no_sn=True, status=2)
    return _html_response('{"status":"200"}')


@app.get('/checknow')
def checknowctrl(request: Request):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
    err_print(0, 'Dashboard', '通過 Web 控制臺發出了立即更新的請求', no_sn=True, status=2)
    checknow()
    return _html_response('{"status":"200"}')


@app.post('/console/command')
async def web_console_command(request: Request):
    denied = await run_in_threadpool(_admin_api_preflight, request)
    if denied is not None:
        return denied
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    return await run_in_threadpool(_web_console_command_blocking, request, payload)


def _web_console_command_blocking(request, payload):
    current_settings = _get_current_settings()
    denied = _admin_api_guard(request, current_settings)
    if denied is not None:
        return denied
    if not isinstance(payload, dict):
        payload = {}
    raw_command = str(payload.get('command', '')).strip()
    return _run_console_command_blocking(raw_command)


@app.get('/data/tasks_progress')
def tasks_progress_http():
    # monitor.js 之前用 gevent 的 wsgi.websocket 走这条路; 现在进度走原生
    # WebSocket (下条路由), 普通 HTTP GET 过来只能回 400, 跟原来一模一样.
    return JSONResponse({'success': False, 'message': 'websocket required'}, status_code=400)


@app.websocket('/data/tasks_progress')
async def tasks_progress(websocket: WebSocket):
    # 原生 FastAPI WebSocket, 取代 flask-sock/gevent-websocket 那一套. 認管理員
    # cookie (瀏覽器開 WebSocket 會自動帶上), 載荷跟原來逐秒送的
    # Config.tasks_progress_rate JSON 一字不差.
    # 設定檔與 userdata 讀取是阻塞 I/O, 必须先丢进线程池, 不能占着事件循环.
    await websocket.accept()
    try:
        current_settings = await run_in_threadpool(_get_current_settings)
        if current_settings['dashboard']['user_control']['enabled']:
            user = await run_in_threadpool(
                find_user_by_token, websocket.cookies.get('token'))
            if not user or user.get('role') != 'admin':
                await websocket.close()
                return

        while True:
            await websocket.send_text(json.dumps(Config.tasks_progress_rate))
            await asyncio.sleep(1)
    except (WebSocketDisconnect, RuntimeError, asyncio.CancelledError):
        pass


@app.get('/')
def home(request: Request):
    current_settings = _get_current_settings()
    if current_settings["dashboard"]["online_watch"]:
        if current_settings["dashboard"]["user_control"]["enabled"]:
            logined, user_role = verify_user(request.cookies)
            if logined and user_role == 'user':
                return _redirect("./watch")
        return _render(request, 'index.html')
    else:
        return _redirect("./control")


@app.api_route('/favicon.ico', methods=['GET', 'HEAD'])
def favicon(request: Request):
    return FileResponse(os.path.join(static_path, 'img', 'aniGamerPlus.ico'))


# A service worker may only control the paths below its own URL, so both it and
# the manifest are mirrored at the site root instead of living under /static.
@app.api_route('/manifest.webmanifest', methods=['GET', 'HEAD'])
def webmanifest():
    response = FileResponse(os.path.join(static_path, 'manifest.webmanifest'))
    response.headers['Content-Type'] = 'application/manifest+json; charset=utf-8'
    return response


@app.api_route('/sw.js', methods=['GET', 'HEAD'])
def service_worker():
    response = FileResponse(os.path.join(static_path, 'sw.js'))
    response.headers['Content-Type'] = 'application/javascript; charset=utf-8'
    response.headers['Service-Worker-Allowed'] = '/'
    response.headers['Cache-Control'] = 'no-cache'
    return response


# iOS looks for these at the root when a page is added to the home screen from
# a URL it has not parsed the <link> tags of (e.g. a shared link).
@app.api_route('/apple-touch-icon.png', methods=['GET', 'HEAD'])
@app.api_route('/apple-touch-icon-precomposed.png', methods=['GET', 'HEAD'])
def apple_touch_icon(request: Request):
    return FileResponse(os.path.join(static_path, 'img', 'pwa', 'apple-touch-icon.png'))


@app.get('/watch')
def watch(request: Request):
    current_settings = _get_current_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    if current_settings['dashboard']['online_watch_requires_login']:
        vaild_user, user_role = verify_user(request.cookies)
        if not vaild_user:
            return _redirect("./login?error=2")
    return _render(request, 'watch.html',
                   {'watch_bootstrap': _build_watch_bootstrap(request, current_settings)})


@app.get('/anime_info')
def get_anime_info(request: Request):
    # 动画疯官方的单集资讯, 服务端代抓 (那个 api 不发 CORS 头)
    current_settings = _sync_plugin_manager()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    if current_settings['dashboard']['online_watch_requires_login']:
        vaild_user, user_role = verify_user(request.cookies)
        if not vaild_user:
            return JSONResponse({"error": "login required"}, status_code=403)

    sn = request.query_params.get('id')
    if not sn or not str(sn).isdigit():
        return JSONResponse({"error": "invalid sn"}, status_code=400)
    # 不在片库里的 sn 一律不转发, 免得这个路由变成打向巴哈的请求放大器
    if _find_video_entry(sn) is None:
        return JSONResponse({"error": "video not found"}, status_code=404)

    info = _get_anime_info(sn)
    if not info:
        return JSONResponse({"error": "anime info unavailable"}, status_code=404)
    resp = JSONResponse(info)
    resp.headers['Cache-Control'] = 'private, max-age=3600'
    return resp


@app.get('/watch/series.json')
def watch_series(request: Request):
    """播放頁要的作品資料: 官方封面、官方簡介, 跟整部作品的集數表.

    跟 /catalog/anime.json 端的是同一份東西, 差別只在入口: 那邊給的是作品編號,
    播放頁手上只有正在播的那一集. 沒有這條路由, 資訊卡就只能拿片庫裡那幾集
    自己編一段介紹, 集數列也只擺得出下載過的集數 —— 邊看邊下載進來的人於是
    看到「共 1 集」.
    """
    current_settings = _sync_plugin_manager()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    if current_settings['dashboard']['online_watch_requires_login']:
        vaild_user, user_role = verify_user(request.cookies)
        if not vaild_user:
            return JSONResponse({"error": "login required"}, status_code=403)

    sn = request.query_params.get('id')
    if not sn or not str(sn).isdigit():
        return JSONResponse({"error": "invalid sn"}, status_code=400)
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
        return JSONResponse({"error": "video not found"}, status_code=404)

    anime = info.get('anime') or {}
    video = info.get('video') or {}
    resp = JSONResponse({
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


@app.get('/catalog/index.json')
def catalog_index(request: Request):
    # 动画疯首页的几个分区. 片库里只有下过的那几部, 这里是站上全部
    current_settings = _get_current_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    denied = _catalog_login_error(current_settings, request)
    if denied is not None:
        return denied
    payload = _get_catalog_index()
    if payload is None:
        return JSONResponse({"error": "catalog unavailable"}, status_code=503)
    return _apply_cache_headers(JSONResponse(payload), current_settings, 600)


@app.get('/catalog/all.json')
def catalog_all(request: Request):
    current_settings = _get_current_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    denied = _catalog_login_error(current_settings, request)
    if denied is not None:
        return denied

    items = _get_catalog_all()
    keyword = (request.query_params.get('q') or '').strip()
    if keyword:
        # 全站一千八百多部都已经在本地了, 搜个片名没必要再去问巴哈
        keyword = keyword.lower()
        items = [item for item in items if keyword in item['title'].lower()]
    try:
        page = max(1, int(request.query_params.get('page') or 1))
    except BaseException:
        page = 1
    start = (page - 1) * CATALOG_PAGE_SIZE
    resp = JSONResponse({
        'items': items[start:start + CATALOG_PAGE_SIZE],
        'page': page,
        'pages': max(1, (len(items) + CATALOG_PAGE_SIZE - 1) // CATALOG_PAGE_SIZE),
        'total': len(items),
    })
    return _apply_cache_headers(resp, current_settings, 600)


@app.get('/catalog/anime.json')
def catalog_anime(request: Request):
    # 详情页: 简介、集数表, 以及每一集在本地有没有
    current_settings = _get_current_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    denied = _catalog_login_error(current_settings, request)
    if denied is not None:
        return denied

    anime_sn = request.query_params.get('sn')
    if not anime_sn or not str(anime_sn).isdigit():
        return JSONResponse({"error": "invalid sn"}, status_code=400)
    if not _catalog_knows(anime_sn):
        return JSONResponse({"error": "anime not found"}, status_code=404)

    video_sn = _resolve_video_sn(anime_sn)
    if not video_sn:
        return JSONResponse({"error": "anime unavailable"}, status_code=404)
    info = _get_anime_info(video_sn)
    if not info:
        return JSONResponse({"error": "anime info unavailable"}, status_code=404)

    anime = info.get('anime') or {}
    resp = JSONResponse({
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


@app.api_route('/thumbnail.jpg', methods=['GET', 'HEAD'])
def get_thumbnail(request: Request):
    # 首页/播放页的封面: 官方封面抓不到才从影片里抽一帧, 抓过就落盘缓存
    current_settings = _sync_plugin_manager()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    if current_settings['dashboard']['online_watch_requires_login']:
        vaild_user, user_role = verify_user(request.cookies)
        if not vaild_user:
            return JSONResponse({"error": "login required"}, status_code=403)

    sn = request.query_params.get('id')
    if not sn or not str(sn).isdigit():
        return JSONResponse({"error": "invalid sn"}, status_code=400)

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
            return JSONResponse({"error": "video not found"}, status_code=404)
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
        resp = Response(status_code=304)
    elif request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = 'image/jpeg'
        resp.headers['Content-Length'] = str(file_size)
    else:
        resp = FileResponse(cache_path, media_type='image/jpeg')
    resp.headers['ETag'] = etag
    resp.headers['Last-Modified'] = last_modified
    _apply_cache_headers(resp, current_settings, 86400)
    return resp


def _parse_video_range(range_header, file_size):
    """Strictly parse a single ``bytes=`` range.

    Returns ``(start, end)`` inclusive on success, or ``None`` when the
    header is malformed, uses an unsupported form (e.g. multiple ranges),
    is reversed (start > end), or is unsatisfiable (start >= size).
    Callers map ``None`` to ``416`` with ``Content-Range: bytes */size``.
    An end beyond the file is clamped to ``size - 1``.
    """
    try:
        size = int(file_size)
    except (TypeError, ValueError):
        return None
    if size <= 0:
        return None
    text = str(range_header or '').strip()
    if not text.startswith('bytes='):
        return None
    spec = text[len('bytes='):].strip()
    if not spec or ',' in spec:
        return None
    fixed = re.fullmatch(r'(\d+)-(\d+)', spec)
    if fixed:
        start, end = int(fixed.group(1)), int(fixed.group(2))
        if start > end or start >= size:
            return None
        return start, min(end, size - 1)
    open_ended = re.fullmatch(r'(\d+)-', spec)
    if open_ended:
        start = int(open_ended.group(1))
        if start >= size:
            return None
        return start, size - 1
    suffix = re.fullmatch(r'-(\d+)', spec)
    if suffix:
        length = int(suffix.group(1))
        if length <= 0:
            return None
        if length >= size:
            return 0, size - 1
        return size - length, size - 1
    return None


def _video_range_not_satisfiable(current_settings, etag, last_modified,
                                 file_size, content_disposition):
    resp = Response(status_code=416)
    resp.headers['Content-Range'] = 'bytes */%d' % file_size
    resp.headers['Accept-Ranges'] = 'bytes'
    resp.headers['ETag'] = etag
    resp.headers['Last-Modified'] = last_modified
    resp.headers['Content-Disposition'] = content_disposition
    _apply_cache_headers(resp, current_settings, 3600)
    return resp


@app.api_route('/get_video.mp4', methods=['GET', 'HEAD'])
def getvid(request: Request):
    current_settings = _sync_plugin_manager()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    if current_settings['dashboard']['online_watch_requires_login']:
        valid_user, user_role = verify_user(request.cookies)
        if not valid_user:
            return JSONResponse({"error": "login required"}, status_code=403)

    sn = request.query_params.get('id')
    res = request.query_params.get('res')
    playback_source = plugin_manager.resolve_playback_source({
        'sn': str(sn),
        'resolution': int(res) if res and str(res).isdigit() else 0,
    })
    if playback_source and playback_source.get('url'):
        return _redirect(playback_source['url'])

    path = _find_video_path(sn, res)
    if not path or not os.path.exists(path):
        return JSONResponse({"error": "video not found"}, status_code=404)
    filename = os.path.basename(path)
    ascii_filename = re.sub(r'[^a-zA-Z0-9._-]', '_', filename)
    utf8_filename = urllib.parse.quote(filename)
    content_disposition = (
        f'inline; filename="{ascii_filename}"; filename*=UTF-8\'\'{utf8_filename}'
    )

    etag, last_modified, file_size = get_file_headers(path)

    # --- 瀏覽器快取檢查 ---
    if request.headers.get("If-None-Match") == etag or \
    request.headers.get("If-Modified-Since") == last_modified:
        resp = Response(status_code=304)  # Not Modified
        resp.headers['ETag'] = etag
        resp.headers['Last-Modified'] = last_modified
        _apply_cache_headers(resp, current_settings, 3600)
        return resp

    # 檢查 Range header: 單一 bytes 範圍才回 206, 其它一律 416.
    range_header = request.headers.get('Range', None)

    # --- Case 1: 沒有 Range → 直接回傳整份檔案 ---
    if not range_header:
        if request.method == 'HEAD':
            # Flask 版 HEAD 自动回同样标头、不带 body, 这里显式做掉.
            resp = Response(status_code=200)
            resp.headers['Content-Type'] = 'video/mp4'
            resp.headers['Content-Length'] = str(file_size)
            resp.headers['ETag'] = etag
            resp.headers['Last-Modified'] = last_modified
            resp.headers['Accept-Ranges'] = 'bytes'
            resp.headers['Content-Disposition'] = content_disposition
            _apply_cache_headers(resp, current_settings, 3600)
            return resp
        resp = FileResponse(path, media_type='video/mp4')
        _apply_cache_headers(resp, current_settings, 3600)
        resp.headers['ETag'] = etag
        resp.headers['Last-Modified'] = last_modified
        resp.headers['Accept-Ranges'] = 'bytes'
        resp.headers['Content-Disposition'] = content_disposition
        return resp

    # --- Case 2: 有 Range → 嚴格解析單一範圍 ---
    parsed = _parse_video_range(range_header, file_size)
    if parsed is None:
        return _video_range_not_satisfiable(
            current_settings, etag, last_modified, file_size,
            content_disposition)

    byte1, byte2 = parsed
    length = byte2 + 1 - byte1

    if request.method == 'HEAD':
        # HEAD 回同樣的狀態與標頭, 不帶 body.
        resp = Response(status_code=206)
        resp.headers['Content-Type'] = 'video/mp4'
        resp.headers['Content-Range'] = f'bytes {byte1}-{byte2}/{file_size}'
        resp.headers['Accept-Ranges'] = 'bytes'
        resp.headers['Content-Length'] = str(length)
        _apply_cache_headers(resp, current_settings, 3600)
        resp.headers['ETag'] = etag
        resp.headers['Last-Modified'] = last_modified
        resp.headers['Content-Disposition'] = content_disposition
        return resp

    resp = StreamingResponse(
        generate_file(path, byte1, length),
        status_code=206,
        media_type='video/mp4',
    )

    resp.headers['Content-Range'] = f'bytes {byte1}-{byte2}/{file_size}'
    resp.headers['Accept-Ranges'] = 'bytes'
    resp.headers['Content-Length'] = str(length)
    _apply_cache_headers(resp, current_settings, 3600)
    resp.headers['ETag'] = etag
    resp.headers['Last-Modified'] = last_modified
    resp.headers['Content-Disposition'] = content_disposition

    return resp


# ------------------------------------------------------------- 邊看邊下載
# 下載中的集數在 temp 裡本來就是一份 HLS 串流, 這四條路由只是把它照原樣端出去:
# playlist 只列已經連續落地的前綴, 分片直接讀檔, 金鑰原封不動交給瀏覽器解.
# 全部都是本機磁碟, 不會為了播放再跟動畫瘋要任何東西.

def _hls_request_state(request):
    """四條路由共用的門口: 驗登入、驗 sn, 然後算出現在是什麼狀態."""
    current_settings = _hls_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return None, None, gated
    denied = _catalog_login_error(current_settings, request)
    if denied is not None:
        return None, None, denied
    sn = request.query_params.get('id')
    if not sn or not str(sn).isdigit():
        return None, None, (JSONResponse({"error": "invalid sn"}, status_code=400))
    return current_settings, _hls_state(sn, current_settings), None


@app.get('/hls/status.json')
def hls_status(request: Request):
    # 播放器每五秒問一次: 現在能不能播、下到幾 %、整集多長、下載完了沒.
    # 只放會變的東西 —— 片名集數在開頁時就寫進 bootstrap 了, 不必每次重送,
    # 更不該讓 _get_anime_info 進到這條輪詢裡
    current_settings, state, denied = _hls_request_state(request)
    if denied is not None:
        return denied

    payload = dict(state)
    payload.pop('parsed', None)   # 內部用的解析結果, 不外流
    payload.pop('temp_dir', None)  # 本機路徑不該出現在 API 回應裡
    resp = JSONResponse(payload)
    # 就算是 mode=none 也回 200: 前端要分得出「沒在下載」跟「伺服器壞了」
    resp.headers['Cache-Control'] = 'no-store'
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Vary'] = 'Cookie'
    return resp


@app.api_route('/hls/playlist.m3u8', methods=['GET', 'HEAD'])
def hls_playlist(request: Request):
    current_settings, state, denied = _hls_request_state(request)
    if denied is not None:
        return denied

    if not current_settings.get('segment_download_mode'):
        return JSONResponse({"error": "streaming unavailable"}, status_code=404)
    if state['mode'] == 'file':
        # 下載完了, 該去 /get_video.mp4, 不是繼續問這裡
        return JSONResponse({"error": "download finished"}, status_code=404)
    if state['mode'] == 'none':
        return JSONResponse({"error": "not downloading"}, status_code=404)
    if state['mode'] == 'parsing' or not state['parsed'] or state['ready'] <= 0:
        # 寧可 404 也不要發一份零分片的 playlist: hls.js 會把空清單當
        # LEVEL_EMPTY_ERROR 直接放棄, 而 404 是它願意重試的 LEVEL_LOAD_ERROR
        return JSONResponse({"error": "not ready"}, status_code=404)

    body = _hls_render(request.query_params.get('id'), state['parsed'],
                       state['ready'], state['mode'] == 'finalising')
    if request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = HLS_MIME
        resp.headers['Content-Length'] = str(len(body.encode('utf-8')))
    else:
        resp = Response(content=body, media_type=HLS_MIME)
    # 不能走 _apply_cache_headers: 它的 max-age 會把一份幾秒就變一次的 playlist
    # 釘住, 而 get_file_headers 的 mtime+size ETag 對還在長大的東西是錯的
    resp.headers['Cache-Control'] = 'no-store'
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Vary'] = 'Cookie'
    return resp


@app.api_route('/hls/key.bin', methods=['GET', 'HEAD'])
def hls_key(request: Request):
    # AES-128 的金鑰原樣交給瀏覽器, 伺服器這邊不解密. 這不會多開一個曝險面:
    # /get_video.mp4 早就用同一道門發完整的成品影片了, 金鑰能開的東西比那個少
    current_settings, state, denied = _hls_request_state(request)
    if denied is not None:
        return denied
    if state['mode'] not in ('parsing', 'streaming', 'finalising'):
        return JSONResponse({"error": "not downloading"}, status_code=404)

    try:
        with open(os.path.join(state['temp_dir'], 'key.m3u8key'), 'rb') as f:
            data = f.read()
    except OSError:
        return JSONResponse({"error": "key not ready"}, status_code=404)
    if not data:
        return JSONResponse({"error": "key not ready"}, status_code=404)

    if request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = 'application/octet-stream'
        resp.headers['Content-Length'] = str(len(data))
    else:
        resp = Response(content=data, media_type='application/octet-stream')
    resp.headers['Cache-Control'] = 'no-store'
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Vary'] = 'Cookie'
    return resp


@app.api_route('/hls/segment.ts', methods=['GET', 'HEAD'])
def hls_segment(request: Request):
    current_settings, state, denied = _hls_request_state(request)
    if denied is not None:
        return denied
    if state['mode'] not in ('streaming', 'finalising') or not state['parsed']:
        return JSONResponse({"error": "not downloading"}, status_code=404)

    # 用序號定位而不是讓前端傳檔名: 這樣沒有任何一段客戶端字串會走到檔案系統,
    # 目錄穿越不是被過濾掉, 是根本構造不出來
    try:
        index = int(request.query_params.get('n'))
    except (TypeError, ValueError):
        return JSONResponse({"error": "invalid segment"}, status_code=400)
    if index < 0 or index >= len(state['parsed']['segments']):
        return JSONResponse({"error": "invalid segment"}, status_code=404)
    if index >= state['ready']:
        # 要的比我們發出去的 playlist 還前面, 表示它拿的是舊清單
        return JSONResponse({"error": "segment not ready"}, status_code=404)

    path = os.path.join(state['temp_dir'], state['parsed']['segments'][index]['name'])
    try:
        # 整片讀進記憶體再回, 不用 FileResponse: 一片 1080p 大概 2~4 MB, 但檔案握把
        # 只開幾微秒. 重試任務會把同一片重下一次, 而 Windows 上 os.replace 碰到
        # 別人開著的目標檔會失敗 —— 握把開久一點, 觀眾就有機會弄垮下載.
        # 順帶把「合併完成時 rmtree 把目錄抽走」這個競態也一起解決掉
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        return JSONResponse({"error": "segment gone"}, status_code=404)
    if not data:
        return JSONResponse({"error": "segment gone"}, status_code=404)

    if request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = 'video/mp2t'
        resp.headers['Content-Length'] = str(len(data))
    else:
        resp = Response(content=data, media_type='video/mp2t')
    # 分片一旦寫下就不會再變, 往回拖時間軸可以直接吃瀏覽器快取, 不必重讀磁碟
    return _apply_cache_headers(resp, current_settings, 3600)


# ----------------------------------------------------------- 線上切換畫質
# 片庫裡一集只有一種畫質, 想換就只能回頭跟動畫瘋要. 這四條路由把 Bahamut 的
# per-resolution HLS 代理出來: 清單改寫成指回自己, 金鑰跟分片轉手發出去.
# 跟上面那組 /hls/* 的差別是那邊讀本機磁碟、清單還在長 (EVENT), 這邊是回源、
# 整集一次給完 (VOD).

def _stream_request_state(request):
    """四條路由共用的門口: 驗登入、驗 sn、驗這個 sn 我們願不願意代抓."""
    current_settings = _hls_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return None, None, gated
    denied = _catalog_login_error(current_settings, request)
    if denied is not None:
        return None, None, denied
    sn = str(request.query_params.get('id') or '')
    if not sn.isdigit():
        return None, None, (JSONResponse({"error": "invalid sn"}, status_code=400))
    if not _stream_allowed(sn):
        return None, None, (JSONResponse({"error": "unknown sn"}, status_code=404))
    return current_settings, sn, None


def _stream_request_media(request):
    """再多驗一個 res, 並且把那個畫質的分片表準備好."""
    current_settings, sn, denied = _stream_request_state(request)
    if denied is not None:
        return None, None, None, None, denied
    res = str(request.query_params.get('res') or '')
    if not res.isdigit():
        return None, None, None, None, (JSONResponse({"error": "invalid resolution"}, status_code=400))
    media = _stream_media(sn, res)
    if media is None:
        return None, None, None, None, (JSONResponse({"error": "resolution unavailable"}, status_code=404))
    return current_settings, sn, res, media, None


@app.get('/stream/sources.json')
def stream_sources(request: Request):
    # 播放器開設定選單時問一次: 這一集在動畫瘋那邊還有哪些畫質可以挑
    current_settings, sn, denied = _stream_request_state(request)
    if denied is not None:
        return denied
    resolutions = sorted(
        (int(key) for key in _stream_dict(sn) if str(key).isdigit()), reverse=True)
    resp = JSONResponse({'sn': sn, 'resolutions': resolutions})
    # 解析結果伺服器自己就快取 30 分鐘了, 這裡讓客戶端也留一下, 免得轉個螢幕
    # 方向、重開一次選單就再問一遍. 一律 private —— 這是拿我們的帳號解析出來
    # 的東西, 不該讓前面的共用快取原樣發給別人
    resp.headers['Cache-Control'] = 'private, max-age=300'
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Vary'] = 'Cookie'
    return resp


@app.api_route('/stream/playlist.m3u8', methods=['GET', 'HEAD'])
def stream_playlist(request: Request):
    current_settings, sn, res, media, denied = _stream_request_media(request)
    if denied is not None:
        return denied
    body = _stream_render(sn, res, media['parsed'])
    if request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = HLS_MIME
        resp.headers['Content-Length'] = str(len(body.encode('utf-8')))
    else:
        resp = Response(content=body, media_type=HLS_MIME)
    # chunklist 的網址是簽名過的, 過期就得重解析. 不能讓客戶端把這份清單釘住
    resp.headers['Cache-Control'] = 'no-store'
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Vary'] = 'Cookie'
    return resp


@app.api_route('/stream/key.bin', methods=['GET', 'HEAD'])
def stream_key(request: Request):
    # 跟 /hls/key.bin 一樣, 金鑰原樣交給播放器, 伺服器這邊不解密
    current_settings, sn, res, media, denied = _stream_request_media(request)
    if denied is not None:
        return denied
    data = _stream_key(sn, res, media)
    if not data:
        return JSONResponse({"error": "key unavailable"}, status_code=502)
    if request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = 'application/octet-stream'
        resp.headers['Content-Length'] = str(len(data))
    else:
        resp = Response(content=data, media_type='application/octet-stream')
    resp.headers['Cache-Control'] = 'no-store'
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Vary'] = 'Cookie'
    return resp


@app.api_route('/stream/segment.ts', methods=['GET', 'HEAD'])
def stream_segment(request: Request):
    current_settings, sn, res, media, denied = _stream_request_media(request)
    if denied is not None:
        return denied

    # 用序號定位而不是讓客戶端傳 URI: 這樣沒有任何一段客戶端字串會變成回源網址,
    # 也就沒有拿這台伺服器當跳板亂打別人的空間
    try:
        index = int(request.query_params.get('n'))
    except (TypeError, ValueError):
        return JSONResponse({"error": "invalid segment"}, status_code=400)
    segments = media['parsed']['segments']
    if index < 0 or index >= len(segments):
        return JSONResponse({"error": "invalid segment"}, status_code=404)

    url = _stream_absolute(media['base'], segments[index]['uri'])
    try:
        upstream = _bahamut_get(url, timeout=30, extra_headers=STREAM_ORIGIN_HEADER)
    except KeyboardInterrupt:
        raise
    except BaseException as error:
        err_print(sn, '線上畫質', '取得 %sP 第 %d 片失敗: %s' % (res, index, error),
                  status=1, display=False)
        return JSONResponse({"error": "segment unavailable"}, status_code=502)
    if upstream.status_code != 200 or not upstream.content:
        return JSONResponse({"error": "segment unavailable"}, status_code=502)

    if request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = 'video/mp2t'
        resp.headers['Content-Length'] = str(len(upstream.content))
    else:
        resp = Response(content=upstream.content, media_type='video/mp2t')
    # 分片內容不會變, 往回拖時間軸就吃客戶端快取, 不必再回源一次
    return _apply_cache_headers(resp, current_settings, 3600)


@app.api_route('/get_danmu.ass', methods=['GET', 'HEAD'])
def getsub(request: Request):
    current_settings = _get_current_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    sn = request.query_params.get('id')
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
            return JSONResponse({"error": "danmu not found"}, status_code=404)
        return FileResponse(path)
    else:
        return _html_response('Danmu is not enabled')


@app.api_route('/video_list.json', methods=['GET', 'HEAD'])
def videolist(request: Request):
    current_settings = _get_current_settings()
    gated = _online_watch_gate(current_settings)
    if gated is not None:
        return gated
    if current_settings['dashboard']['online_watch_requires_login']:
        vaild_user, user_role = verify_user(request.cookies)
        if not vaild_user:
            return JSONResponse({"error": "login required"}, status_code=403)

    # 這一支是整個 app 開機時最重的一筆: 片庫大一點 (四千集就是 2.7 MB)
    # 的話, 每次都把整份重新解析再重新序列化一遍, 實測要一秒多. 但磁碟上那個檔
    # 本來就是要送出去的那份 JSON —— 直接發檔案, 中間那兩步都不必做.
    #
    # 再配一組 ETag: 沒有新下載的集數時客戶端只會收到一個 304, 連那 100 KB
    # 都不必再傳.
    video_list_path = os.path.join(Config.get_working_dir(), 'video_list.json')
    if not os.path.exists(video_list_path):
        # 還沒下載過任何一集
        return JSONResponse({'videos': []})

    etag, last_modified, file_size = get_file_headers(video_list_path)
    if request.headers.get('If-None-Match') == etag or request.headers.get('If-Modified-Since') == last_modified:
        resp = Response(status_code=304)
    elif request.method == 'HEAD':
        resp = Response(status_code=200)
        resp.headers['Content-Type'] = 'application/json'
        resp.headers['Content-Length'] = str(file_size)
    else:
        resp = FileResponse(video_list_path, media_type='application/json')
    resp.headers['ETag'] = etag
    resp.headers['Last-Modified'] = last_modified
    # must-revalidate: 片庫隨時可能多一集, 客戶端每次都該問一下 —— 但問完
    # 通常就是一個 304, 便宜得很
    if current_settings['dashboard']['online_watch_requires_login']:
        resp.headers['Cache-Control'] = 'private, no-cache, must-revalidate'
        resp.headers['Vary'] = 'Cookie'
    else:
        resp.headers['Cache-Control'] = 'public, no-cache, must-revalidate'
    return resp


@app.api_route('/watch/time', methods=['GET', 'POST'])
async def webtime(request: Request):
    if request.method == 'POST':
        denied = await run_in_threadpool(
            _watch_time_preflight, request.cookies.get('token'))
        if denied is not None:
            return denied
        reqdata = await _json_then_form(request)
    else:
        reqdata = dict(request.query_params)
    token = request.cookies.get('token')
    return await run_in_threadpool(_webtime_blocking, reqdata, token)


def _webtime_blocking(reqdata, token):
    gettype = reqdata.get('type')
    sn = reqdata.get('sn')
    ended = str(reqdata.get('ended', "false")).lower() == "true"
    if gettype == 'set':
        def _apply(userdata):
            for user in userdata['users']:
                if user['token'] == token:
                    # 播放器偶尔会送回 Infinity 或空值 (直播源、moov 里没写时长),
                    # 一个坏参数不该变成 500 把整笔进度一起丢掉
                    try:
                        entry = {"time": int(float(reqdata.get('time'))), "ended": ended, "timestamp": int(datetime.now().timestamp())}
                    except (TypeError, ValueError, OverflowError):
                        return (_html_response('{"status":"400", "msg":"Invalid time"}', status_code=400), False)
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
                    return (_html_response('{"status":"200"}'), True)
            return (_html_response('{"status":"403", "msg":"Invalid token"}'), False)
        return update_user_data(_apply)
    elif gettype == 'del':
        # 觀看紀錄那一頁的刪除鈕. 沒有這筆就當作已經刪掉了 —— 連按兩下不該
        # 是一次 200 一次 404
        def _apply_del(userdata):
            for user in userdata['users']:
                if user['token'] == token:
                    if not sn:
                        return (_html_response('{"status":"400", "msg":"Missing sn"}', status_code=400), False)
                    if user['videotimes'].pop(sn, None) is not None:
                        return (_html_response('{"status":"200"}'), True)
                    return (_html_response('{"status":"200"}'), False)
            return (_html_response('{"status":"403", "msg":"Invalid token"}'), False)
        return update_user_data(_apply_del)
    elif gettype == 'get':
        userdata = load_user_data()
        for user in userdata['users']:
            if user['token'] == token:
                if not sn:
                    return JSONResponse(user['videotimes'])
                if user['videotimes'].get(sn):
                    return JSONResponse(user['videotimes'][sn])
                else:
                    return JSONResponse({"time": 0, "ended": False})
    userdata = load_user_data()
    for user in userdata['users']:
        if user['token'] == token:
            return _html_response('{"status":"404", "msg":"Invalid type"}')
    return _html_response('{"status":"403", "msg":"Invalid token"}')


@app.get('/get_server_info')
def get_server_info():
    return JSONResponse(_get_dashboard_flags())


@app.get('/logout')
def logout(request: Request):
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    response = _redirect('./login')
    return _clear_login_cookies(response)


@app.api_route('/login', methods=['GET', 'POST'])
async def login(request: Request):
    if request.method == 'GET':
        return await run_in_threadpool(_login_blocking, request, None)
    denied = await run_in_threadpool(_login_preflight)
    if denied is not None:
        return denied
    # Only form/JSON parsing stays on the event loop; PBKDF2/scrypt and
    # userdata/config I/O run pooled so unauthenticated logins never block it.
    reqdata = await _form_or_json(request)
    return await run_in_threadpool(_login_blocking, request, reqdata)


def _login_blocking(request, reqdata):
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    if request.method == 'GET':
        return _render(request, 'login.html', {'error': request.query_params.get('error')})

    if not reqdata:
        return _html_response('<script>alert("Empty request!");history.back();</script>')

    username = _normalize_username(reqdata.get('username'))
    password = reqdata.get('password')
    # Expensive PBKDF2/scrypt verification stays outside the userdata lock.
    snapshot = load_user_data()
    user = find_user_by_username(username, snapshot)
    if not user or not _verify_password(user, password):
        return _redirect('./login?error=1')

    token = user.get('token')
    if user.get('password') is not None:
        # Legacy plaintext migration: hash outside, compare-and-update inside
        # so a concurrent password change is never silently overwritten.
        legacy_pw = user.get('password')
        new_hash = _hash_password(password)

        def _migrate(userdata):
            fresh = find_user_by_username(username, userdata)
            if fresh is None:
                return (None, False)
            if fresh.get('password') is None:
                return (fresh.get('token'), False)
            if legacy_pw is not None and fresh.get('password') != legacy_pw:
                if not _verify_password(fresh, password):
                    return (fresh.get('token'), False)
            fresh['password_hash'] = new_hash
            fresh.pop('password', None)
            return (fresh.get('token'), True)

        migrated_token = update_user_data(_migrate)
        if migrated_token:
            token = migrated_token

    destination = './watch' if Config.read_settings()['dashboard'].get('online_watch') else './control'
    response = _redirect(destination)
    return _set_login_cookies(response, token)


@app.api_route('/register', methods=['GET', 'POST'])
async def register(request: Request):
    if request.method == 'GET':
        return await run_in_threadpool(_register_blocking, request, None)
    denied = await run_in_threadpool(_register_preflight)
    if denied is not None:
        return denied
    reqdata = await _json_then_form(request)
    return await run_in_threadpool(_register_blocking, request, reqdata)


def _register_blocking(request, reqdata):
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    if not current_settings['dashboard']['user_control']['allow_register']:
        return _html_response('<script>alert("註冊功能未啟用");history.back();</script>')
    if request.method == 'GET':
        return _render(request, 'register.html', {'error': request.query_params.get('error')})

    if not reqdata:
        return _html_response('<script>alert("Empty request!");history.back();</script>')
    if not reqdata.get('username') or not reqdata.get('pw1') or not reqdata.get('pw2'):
        return _redirect('./register?error=3')
    if reqdata.get('pw1') != reqdata.get('pw2'):
        return _redirect('./register?error=2')

    username = _normalize_username(reqdata.get('username'))
    password = str(reqdata.get('pw1'))
    if not re.match(r'^[a-zA-Z0-9_]{3,20}$', username):
        return _redirect('./register?error=4')
    if not re.match(r'^[a-zA-Z0-9_]{6,64}$', password):
        return _redirect('./register?error=5')

    # Expensive hash + token generation stay outside the lock; uniqueness is
    # revalidated inside the transaction.
    new_hash = _hash_password(password)
    new_token = _generate_token()

    def _append(userdata):
        if find_user_by_username(username, userdata):
            return (_redirect('./register?error=1'), False)
        userdata['users'].append({
            'username': username,
            'password_hash': new_hash,
            'token': new_token,
            'videotimes': {},
            'role': 'user',
        })
        return (_redirect('./login?error=3'), True)

    return update_user_data(_append)


@app.api_route('/usermanage', methods=['GET', 'POST'])
async def usermanage_v2(request: Request):
    if request.method == 'GET':
        return await run_in_threadpool(_usermanage_blocking, request, None)
    denied = await run_in_threadpool(_admin_page_preflight, request)
    if denied is not None:
        return denied
    reqdata = await _form_or_json(request)
    return await run_in_threadpool(_usermanage_blocking, request, reqdata)


def _usermanage_blocking(request, reqdata):
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    denied = _admin_page_guard(request, current_settings)
    if denied is not None:
        return denied
    if request.method == 'GET':
        userdata = load_user_data()
        users = []
        for user in userdata['users']:
            safe_user = user.copy()
            safe_user.pop('password', None)
            safe_user.pop('password_hash', None)
            safe_user.pop('token', None)
            users.append(safe_user)
        # 手機 app 沒有辦法解析 usermanage.html, 拿同一份資料的 JSON 版
        if request.query_params.get('format') == 'json':
            return JSONResponse({'status': '200', 'users': [
                {
                    'username': user.get('username', ''),
                    'role': user.get('role', 'user'),
                    'videotimes': len(user.get('videotimes') or {}),
                }
                for user in users
            ]})
        return _render(request, 'usermanage.html', {'users': users})

    if not reqdata:
        return JSONResponse({'status': '400', 'message': 'Empty request!'}, status_code=400)

    action = reqdata.get('action')
    username = _normalize_username(reqdata.get('username'))
    actor_token = request.cookies.get('token')
    actor_name = getattr(getattr(request, 'state', None), 'current_user', {}).get('username', '')

    # Expensive hashing stays outside the lock; identity/state is revalidated
    # inside each transaction below.
    precomputed_hash = None
    precomputed_token = None
    if action == 'change' and reqdata.get('password'):
        precomputed_hash = _hash_password(reqdata.get('password'))
        precomputed_token = _generate_token()
    if action == 'add' and username and reqdata.get('password'):
        precomputed_hash = _hash_password(reqdata.get('password'))
        precomputed_token = _generate_token()

    def _check_actor(userdata):
        actor = find_user_by_token(actor_token, userdata)
        if not actor or actor.get('role') != 'admin':
            return None
        return actor

    if action == 'delete':
        def _apply_delete(userdata):
            if _check_actor(userdata) is None:
                return (JSONResponse({'status': '403', 'message': 'admin required'}, status_code=403), False)
            target_user = find_user_by_username(username, userdata)
            if not target_user:
                return (JSONResponse({'status': '404', 'message': 'User not found'}, status_code=404), False)
            actor = find_user_by_token(actor_token, userdata)
            if target_user['username'].lower() == (actor.get('username') or actor_name).lower():
                return (JSONResponse({'status': '403', 'message': 'Cannot delete current user'}, status_code=403), False)
            userdata['users'] = [user for user in userdata['users'] if user['username'].lower() != username.lower()]
            return (JSONResponse({'status': '200', 'message': 'User deleted'}), True)
        return update_user_data(_apply_delete)

    if action == 'change':
        def _apply_change(userdata):
            if _check_actor(userdata) is None:
                return (JSONResponse({'status': '403', 'message': 'admin required'}, status_code=403), False)
            target_user = find_user_by_username(username, userdata)
            if not target_user:
                return (JSONResponse({'status': '404', 'message': 'User not found'}, status_code=404), False)
            if reqdata.get('password'):
                target_user['password_hash'] = precomputed_hash
                target_user.pop('password', None)
                target_user['token'] = precomputed_token
            if reqdata.get('role') is not None:
                target_user['role'] = _normalize_role(reqdata.get('role'))
            else:
                target_user['role'] = _normalize_role(target_user.get('role'))
            return (JSONResponse({'status': '200', 'message': 'User updated'}), True)

        return update_user_data(_apply_change)

    if action == 'add':
        def _apply_add(userdata):
            if _check_actor(userdata) is None:
                return (JSONResponse({'status': '403', 'message': 'admin required'}, status_code=403), False)
            if not username or not reqdata.get('password'):
                return (JSONResponse({'status': '400', 'message': 'Username and password are required'}, status_code=400), False)
            if find_user_by_username(username, userdata):
                return (JSONResponse({'status': '409', 'message': 'User already exists'}, status_code=409), False)
            userdata['users'].append({
                'username': username,
                'password_hash': precomputed_hash,
                'token': precomputed_token,
                'videotimes': {},
                'role': _normalize_role(reqdata.get('role')),
            })
            return (JSONResponse({'status': '200', 'message': 'User created'}), True)
        return update_user_data(_apply_add)

    return JSONResponse({'status': '400', 'message': 'Invalid action'}, status_code=400)


@app.api_route('/userinfo', methods=['GET', 'POST'])
async def userinfo_v2(request: Request):
    if request.method == 'GET':
        return await run_in_threadpool(_userinfo_blocking, request, None)
    denied = await run_in_threadpool(_user_page_preflight, request)
    if denied is not None:
        return denied
    reqdata = await _form_or_json(request)
    return await run_in_threadpool(_userinfo_blocking, request, reqdata)


def _userinfo_blocking(request, reqdata):
    current_settings = _get_current_settings()
    gated = _user_control_gate(current_settings)
    if gated is not None:
        return gated
    denied = _user_page_guard(request, current_settings)
    if denied is not None:
        return denied
    token = request.cookies.get('token')
    snapshot = load_user_data()
    user = find_user_by_token(token, snapshot)
    if not user:
        return _redirect('/login')

    if request.method == 'GET':
        safe_user = user.copy()
        safe_user.pop('password', None)
        safe_user.pop('password_hash', None)
        safe_user.pop('token', None)
        return _render(request, 'userinfo.html', {'user': safe_user})

    if not reqdata:
        return JSONResponse({'status': '400', 'message': 'Empty request!'}, status_code=400)

    action = reqdata.get('action')
    if action == 'get':
        fresh = load_user_data()
        fresh_user = find_user_by_token(token, fresh)
        if not fresh_user:
            return _redirect('/login')
        ret_data = fresh_user.copy()
        ret_data['status'] = '200'
        ret_data.pop('token', None)
        ret_data.pop('password', None)
        ret_data.pop('password_hash', None)
        return JSONResponse(ret_data)

    if action in ('changepassword', 'change'):
        original_pw = reqdata.get('original_password', reqdata.get('old_password'))
        new_pw1 = reqdata.get('new_password1')
        new_pw2 = reqdata.get('new_password2')
        # Expensive verification + hashing outside the lock.
        if not _verify_password(user, original_pw):
            return JSONResponse({"status": "403", "message": "錯誤的原密碼"}, status_code=403)
        if not new_pw1 or new_pw1 != new_pw2:
            return JSONResponse({"status": "403", "message": "新密碼不一致"}, status_code=403)
        snap_hash = user.get('password_hash')
        snap_legacy = user.get('password')
        snap_name = user.get('username')
        new_hash = _hash_password(new_pw1)
        new_token = _generate_token()

        def _apply_pw(userdata):
            fresh_user = find_user_by_token(token, userdata)
            if not fresh_user:
                return (_redirect('/login'), False)
            if fresh_user.get('password_hash') != snap_hash or fresh_user.get('password') != snap_legacy:
                # State moved under us (concurrent password change); revalidate
                # inside the transaction rather than overwriting blindly.
                if not _verify_password(fresh_user, original_pw):
                    return (JSONResponse({"status": "403", "message": "錯誤的原密碼"}, status_code=403), False)
                if fresh_user.get('username') != snap_name:
                    return (_redirect('/login'), False)
            fresh_user['password_hash'] = new_hash
            fresh_user.pop('password', None)
            fresh_user['token'] = new_token
            return (JSONResponse({"status": "200", "message": "密碼修改成功!", "logout": True}), True)

        return update_user_data(_apply_pw)

    return JSONResponse({'status': '400', 'message': 'Invalid action'}, status_code=400)


if _get_current_settings()['dashboard']['user_control']['enabled']:
    load_user_data()


def run():
    current_settings = Config.read_settings()  # 读取配置

    port = current_settings['dashboard']['port']
    host = current_settings['dashboard']['host']

    ssl_certfile = ssl_keyfile = None
    # check cert if enabled ssl
    if current_settings['dashboard']['SSL']:
        ssl_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'sslkey')
        ssl_crt = os.path.join(ssl_path, 'server.crt')
        ssl_key = os.path.join(ssl_path, 'server.key')
        if not os.path.exists(ssl_crt) or not os.path.exists(ssl_key):
            err_print(0, 'Dashboard', '啟用了SSL，但是證書檔案不存在! 強制禁用', no_sn=True, status=1)
            current_settings['dashboard']['SSL'] = False
        else:
            ssl_certfile, ssl_keyfile = ssl_crt, ssl_key

    # uvicorn 是 ASGI server: 原来 gevent WSGIServer + WebSocketHandler 干的事
    # (HTTP + WebSocket 同端口、TLS) 由它接手. aniGamerPlus 在 daemon 线程里调
    # run(), uvicorn.run 会自己建事件循环, 在非主线程跑也没问题.
    if current_settings['dashboard']['SSL']:
        uvicorn.run(app, host=host, port=port,
                    ssl_certfile=ssl_certfile, ssl_keyfile=ssl_keyfile)
    else:
        uvicorn.run(app, host=host, port=port)


if __name__ == '__main__':
    run()
    pass
