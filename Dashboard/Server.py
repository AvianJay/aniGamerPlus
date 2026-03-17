#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# @Time    : 2019/6/26 16:12
# @Author  : Miyouzi
# @File    : Server.py
# @Software: PyCharm

# 非阻塞
from gevent import monkey; monkey.patch_all()
from gevent import spawn

import json, sys, os, re, time
import threading, traceback
import random, string, hashlib, secrets

from aniGamerPlus import Config
from flask import Flask, request, jsonify, Response, redirect, make_response, g
from flask import render_template, send_file, stream_with_context
from aniGamerPlus import __cui as cui
from aniGamerPlus import __get_danmu_only
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


checknow = lambda e: None
command_handler = None
userdata_lock = threading.Lock()
userdata_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json')


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


# 读取web需要的配置名称列表
id_list_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'static', 'js', 'settings_id_list.js')
with open(id_list_path, 'r', encoding='utf-8') as f:
    id_list = re.sub(r'(var id_list\s*=\s*|\s*\n?)', '', f.read()).replace('\'', '"')
    id_list = json.loads(id_list)

@app.after_request
def after_request(response):
    response.headers.add('Accept-Ranges', 'bytes')
    return response


settings = Config.read_settings()
plugin_manager = PluginManager(settings)
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
        web_settings[id] = settings[id]  # 仅返回 web 需要的配置

    return jsonify(web_settings)


@app.route('/uploadConfig', methods=['POST'])
@admin_api_required
def recv_config():
    data = json.loads(request.get_data(as_text=True))
    new_settings = Config.read_settings()
    for id in id_list:
        new_settings[id] = data[id]  # 更新配置
    Config.write_settings(new_settings)  # 保存配置
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
    return websocket_token, '200 ok'


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
    checknow(True)
    return '{"status":"200"}'


@app.route('/console/command', methods=['POST'])
@admin_api_required
def web_console_command():
    return _handle_web_console_command()


# todo: 修好websocket
@sock.route('/data/tasks_progress')
def tasks_progress(ws):
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
    if settings["dashboard"]["online_watch"]:
        if settings["dashboard"]["user_control"]["enabled"]:
            logined, user_role = verify_user(request.cookies)
            if logined and user_role == 'user':
                return redirect("./watch")
        return render_template('index.html')
    else:
        return redirect("./control")


@app.route('/favicon.ico')
def favicon():
    return send_file(os.path.join(static_path, 'img', 'aniGamerPlus.ico'))


if settings["dashboard"]["online_watch"]:
    @app.route('/watch')
    def watch():
        if settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return redirect("./login?error=2")
        # return open(f'{template_path}/watch.html', 'r').read()
        return render_template('watch.html')


    @app.route('/get_video.mp4')
    def getvid():
        plugin_manager.reload(Config.read_settings())
        if settings['dashboard']['online_watch_requires_login']:
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
            resp.headers['Cache-Control'] = 'public, max-age=3600'
            return resp

        # 檢查 Range header
        range_header = request.headers.get('Range', None)

        # --- Case 1: 沒有 Range → 直接回傳整份檔案 ---
        if not range_header:
            resp = send_file(path, mimetype='video/mp4', as_attachment=True, download_name=filename)
            resp.headers['Cache-Control'] = 'public, max-age=3600'
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
        resp.headers['Cache-Control'] = 'public, max-age=3600'
        resp.headers['ETag'] = etag
        resp.headers['Last-Modified'] = last_modified
        resp.headers['Content-Disposition'] = content_disposition

        return resp


    @app.route('/get_danmu.ass')
    def getsub():
        sn = request.args.get('id')
        if settings['danmu']:
            video = _find_video_entry(sn)
            path = Config.getpath(sn, 'danmu')

            if video and _should_update_danmu(sn):
                video_path = video.get('path')
                anime_name = video.get('anime_name')
                if video_path and anime_name and os.path.exists(video_path):
                    try:
                        __get_danmu_only(sn, anime_name, video_path, False)
                        if path and os.path.exists(path):
                            _mark_danmu_updated(sn)
                    except BaseException as e:
                        err_print(sn, '彈幕更新失敗', '線上觀看請求時自動更新失敗: ' + str(e), status=1, display=True)

            if path and os.path.exists(path) and str(sn) not in danmu_update_timestamps:
                _mark_danmu_updated(sn)

            if not path or not os.path.exists(path):
                return jsonify({"error": "danmu not found"}), 404
            return send_file(path)
        else:
            return 'Danmu is not enabled'


    @app.route('/video_list.json')
    def videolist():
        if settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return jsonify({"error": "login required"}), 403
        video_json = json.load(open(os.path.join(Config.get_working_dir(), 'video_list.json'), 'r'))
        return jsonify(video_json)


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
                    user['videotimes'][sn] = {"time": int(float(reqdata.get('time'))), "ended": ended, "timestamp": int(datetime.now().timestamp())}
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
    settings = Config.read_settings()
    return jsonify({
        "user_control": settings['dashboard']['user_control']['enabled'],
        "user_control_allow_register": settings['dashboard']['user_control']['allow_register'],
        "online_watch": settings['dashboard']['online_watch'],
        "online_watch_requires_login": settings['dashboard']['online_watch_requires_login'],
    })

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
            return '<script>alert("隡箸??冽????刻酉??");history.back();</script>'
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
                return jsonify({"status": "403", "message": "??蝣潮?霅仃??"}), 403
            if not new_pw1 or new_pw1 != new_pw2:
                return jsonify({"status": "403", "message": "?啣?蝣潔?銝?湛?"}), 403
            user['password_hash'] = _hash_password(new_pw1)
            user.pop('password', None)
            user['token'] = _generate_token()
            save_user_data(userdata)
            return jsonify({"status": "200", "message": "靽格??!", "logout": True})

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
