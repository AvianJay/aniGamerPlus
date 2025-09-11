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
import random, string, hashlib

from aniGamerPlus import Config
from flask import Flask, request, jsonify, Response, redirect
from flask import render_template, send_file, stream_with_context
from flask_basicauth import BasicAuth
from aniGamerPlus import __cui as cui
import logging, termcolor
from ColorPrint import err_print
from logging.handlers import TimedRotatingFileHandler
import mimetypes
# ws 支持
import ssl
from flask_sock import Sock
from gevent.pywsgi import WSGIServer
from geventwebsocket.exceptions import WebSocketError
from geventwebsocket.handler import WebSocketHandler
from datetime import datetime

mimetypes.add_type('text/css', '.css')
mimetypes.add_type('application/x-javascript', '.js')
template_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'templates')
static_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'static')
app = Flask(__name__, template_folder=template_path, static_folder=static_path)
app.debug = False
sock = Sock(app)
basic_auth = BasicAuth(app)

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


def get_chunk(path, byte1=None, byte2=None):
    full_path = path
    file_size = os.stat(full_path).st_size
    start = 0
    
    if byte1 < file_size:
        start = byte1
    if byte2:
        length = byte2 + 1 - byte1
    else:
        length = file_size - start

    with open(full_path, 'rb') as f:
        f.seek(start)
        chunk = f.read(length)
    return chunk, start, length, file_size


checknow = lambda e: None

caches = {}
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
if settings['dashboard']['BasicAuth']:
    @app.route('/control')
    @basic_auth.required
    def control():
        return render_template('control.html')


    @app.route('/monitor')
    @basic_auth.required
    def monitor():
        return render_template('monitor.html')


    @app.route('/data/config.json', methods=['GET'])
    @basic_auth.required
    def config():
        settings = Config.read_settings()
        web_settings = {}
        for id in id_list:
            web_settings[id] = settings[id]  # 仅返回 web 需要的配置

        return jsonify(web_settings)


    @app.route('/uploadConfig', methods=['POST'])
    @basic_auth.required
    def recv_config():
        data = json.loads(request.get_data(as_text=True))
        new_settings = Config.read_settings()
        for id in id_list:
            new_settings[id] = data[id]  # 更新配置
        Config.write_settings(new_settings)  # 保存配置
        err_print(0, 'Dashboard', '通過 Web 控制臺更新了 config.json', no_sn=True, status=2)
        return '{"status":"200"}'


    @app.route('/manualTask', methods=['POST'])
    @basic_auth.required
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
    @basic_auth.required
    def show_sn_list():
        return Config.get_sn_list_content()


    @app.route('/data/get_token', methods=['GET'])
    @basic_auth.required
    def get_token():
        global websocket_token
        # 生成 32 位随机字符串作为token
        websocket_token = ''.join(random.sample(string.ascii_letters + string.digits, 32))
        return websocket_token, '200 ok'


    @app.route('/sn_list', methods=['POST'])
    @basic_auth.required
    def set_sn_list():
        data = request.get_data(as_text=True)
        Config.write_sn_list(data)
        err_print(0, 'Dashboard', '通過 Web 控制臺更新了 sn_list', no_sn=True, status=2)
        return '{"status":"200"}'


    @app.route('/checknow')
    @basic_auth.required
    def checknowctrl():
        err_print(0, 'Dashboard', '通過 Web 控制臺發出了立即更新的請求', no_sn=True, status=2)
        checknow(True)
        return '{"status":"200"}'
else:
    @app.route('/control')
    def control():
        return render_template('control.html')


    @app.route('/monitor')
    def monitor():
        return render_template('monitor.html')


    @app.route('/data/config.json', methods=['GET'])
    def config():
        settings = Config.read_settings()
        web_settings = {}
        for id in id_list:
            web_settings[id] = settings[id]  # 仅返回 web 需要的配置

        return jsonify(web_settings)


    @app.route('/uploadConfig', methods=['POST'])
    def recv_config():
        data = json.loads(request.get_data(as_text=True))
        new_settings = Config.read_settings()
        for id in id_list:
            new_settings[id] = data[id]  # 更新配置
        Config.write_settings(new_settings)  # 保存配置
        err_print(0, 'Dashboard', '通過 Web 控制臺更新了 config.json', no_sn=True, status=2)
        return '{"status":"200"}'


    @app.route('/manualTask', methods=['POST'])
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
    def show_sn_list():
        return Config.get_sn_list_content()


    @app.route('/data/get_token', methods=['GET'])
    def get_token():
        global websocket_token
        # 生成 32 位随机字符串作为token
        websocket_token = ''.join(random.sample(string.ascii_letters + string.digits, 32))
        return websocket_token, '200 ok'


    @app.route('/sn_list', methods=['POST'])
    def set_sn_list():
        data = request.get_data(as_text=True)
        Config.write_sn_list(data)
        err_print(0, 'Dashboard', '通過 Web 控制臺更新了 sn_list', no_sn=True, status=2)
        return '{"status":"200"}'


    @app.route('/checknow')
    def checknowctrl():
        err_print(0, 'Dashboard', '通過 Web 控制臺發出了立即更新的請求', no_sn=True, status=2)
        checknow(True)
        return '{"status":"200"}'


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
        if settings['dashboard']['online_watch_requires_login']:
            vaild_user, user_role = verify_user(request.cookies)
            if not vaild_user:
                return jsonify({"error": "login required"}), 403
        sn = request.args.get('id')
        res = request.args.get('res')
        c = cache(f"{str(sn)}_{str(res)}")
        if c:
            path = c
        else:
            path = Config.getpath(sn, 'video', resolution=res)
            cache(f"{str(sn)}_{str(res)}", time=3600, set=path)
        if not os.path.exists(path):
            return jsonify({"error": "File not found"}), 404
        range_header = request.headers.get('Range', None)
        byte1, byte2 = 0, None
        if range_header:
            match = re.search(r'(\d+)-(\d*)', range_header)
            groups = match.groups()

            if groups[0]:
                byte1 = int(groups[0])
            if groups[1]:
                byte2 = int(groups[1])
        else:
            return send_file(path, mimetype='video/mp4', download_name=f"{sn}.mp4")
        
        chunk, start, length, file_size = get_chunk(path, byte1, byte2)
        resp = Response(chunk, 206, mimetype='video/mp4',
                        content_type='video/mp4', direct_passthrough=True)
        resp.headers.add('Content-Range', 'bytes {0}-{1}/{2}'.format(start, start + length - 1, file_size))
        return resp


    @app.route('/get_danmu.ass')
    def getsub():
        sn = request.args.get('id')
        if settings['danmu']:
            path = Config.getpath(sn, 'danmu')
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
        userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
        if gettype == 'set':
            for user in userdata['users']:
                if user['token'] == token:
                    user['videotimes'][sn] = {"time": int(float(request.args.get('time'))), "ended": ended, "timestamp": int(datetime.now().timestamp())}
                    with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                        json.dump(userdata, f, ensure_ascii=False, indent=4)
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

    if settings['dashboard']['BasicAuth']:
        # BasicAuth 配置
        app.config['BASIC_AUTH_USERNAME'] = settings['dashboard']['username']  # BasicAuth user
        app.config['BASIC_AUTH_PASSWORD'] = settings['dashboard']['password']  # BasicAuth password
        app.config['BASIC_AUTH_FORCE'] = False  # 關閉全站验证
        basic_auth = BasicAuth(app)

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
