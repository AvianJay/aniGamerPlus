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
import random, string

from aniGamerPlus import Config
from flask import Flask, request, jsonify, Response, redirect
from flask import render_template, send_file
from flask_basicauth import BasicAuth
from aniGamerPlus import __cui as cui
from aniGamerPlus import checknow
import logging, termcolor
from ColorPrint import err_print
from logging.handlers import TimedRotatingFileHandler
import mimetypes
# ws 支持
import ssl
from flask_sockets import Sockets
from gevent.pywsgi import WSGIServer
from geventwebsocket.exceptions import WebSocketError
from geventwebsocket.handler import WebSocketHandler

mimetypes.add_type('text/css', '.css')
mimetypes.add_type('application/x-javascript', '.js')
template_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'templates')
static_path = os.path.join(Config.get_working_dir(), 'Dashboard', 'static')
app = Flask(__name__, template_folder=template_path, static_folder=static_path)
app.debug = False
sockets = Sockets(app)
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


    @sockets.route('/data/tasks_progress')
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
        while not ws.closed:
            msg = json.dumps(Config.tasks_progress_rate)
            try:
                ws.send(msg)
                time.sleep(1)
            except WebSocketError:
                # 连接中断
                ws.close()
                break


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


    @sockets.route('/data/tasks_progress')
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
        while not ws.closed:
            msg = json.dumps(Config.tasks_progress_rate)
            try:
                ws.send(msg)
                time.sleep(1)
            except WebSocketError:
                # 连接中断
                ws.close()
                break


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


@app.route('/')
def home():
    if settings["dashboard"]["online_watch"]:
        return render_template('index.html')
    else:
        return redirect("/control")


@app.route('/favicon.ico')
def favicon():
    return send_file(os.path.join(static_path, 'img', 'aniGamerPlus.ico'))


if settings["dashboard"]["online_watch"]:
    @app.route('/watch')
    def watch():
        # return open(f'{template_path}/watch.html', 'r').read()
        return render_template('watch.html')


    @app.route('/get_video.mp4')
    def getvid():
        sn = request.args.get('id')
        res = request.args.get('res')
        path = Config.getpath(sn, 'video', resolution=res)
        range_header = request.headers.get('Range', None)
        byte1, byte2 = 0, None
        if range_header:
            match = re.search(r'(\d+)-(\d*)', range_header)
            groups = match.groups()

            if groups[0]:
                byte1 = int(groups[0])
            if groups[1]:
                byte2 = int(groups[1])
        
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
        video_json = json.load(open(os.path.join(Config.get_working_dir(), 'video_list.json'), 'r'))
        return jsonify(video_json)


    @app.route('/watch/time')
    def webtime():
        gettype = request.args.get('type')
        sn = request.args.get('sn')
        ended = request.args.get('ended', "false").lower() == "true"
        token = request.cookies.get('token')
        userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
        if gettype == 'set':
            for user in userdata['users']:
                if user['token'] == token:
                    user['videotimes'][sn] = {"time": int(request.args.get('time')), "ended": ended}
                    with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                        json.dump(userdata, f, ensure_ascii=False, indent=4)
                    return '{"status":"200"}'
        elif gettype == 'get':
            for user in userdata['users']:
                if user['token'] == token:
                    if not sn:
                        return jsonify(user['videotimes'])
                    if user['videotimes'][sn]:
                        return jsonify(user['videotimes'][sn])
                    else:
                        return jsonify({"time": 0, "ended": False})
        for user in userdata['users']:
            if user['token'] == token:
                return '{"status":"404", "msg":"Type is invalid"}'
        return '{"status":"403", "msg":"Token is invalid"}'


if settings['dashboard']['user_control']['enabled']:
    # init user
    settings = Config.read_settings()
    if os.path.exists(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json')):
        try:
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            for duser in settings['dashboard']['user_control']['default_user']:
                t = False
                for user in userdata['users']:
                    if duser['name'] == user['name']:
                        user['password'] = duser['password']
                        user['role'] = duser['role']
                        t = True
                if not t:
                    userdata['users'].append(duser)
        except:
            userdata = {"users": settings['dashboard']['user_control']['default_user'].copy()}
            for u in userdata["users"]:
                u["token"] = ''.join(random.sample(string.ascii_letters + string.digits, 32))
                u["videotimes"] = []
    else:
        userdata = {"users": settings['dashboard']['user_control']['default_user'].copy()}
        for u in userdata["users"]:
            u["token"] = ''.join(random.sample(string.ascii_letters + string.digits, 32))
            u["videotimes"] = []
    with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
        json.dump(userdata, f, ensure_ascii=False, indent=4)

    @app.route('/logout')
    def logout():
        return '<script>document.cookies.token = "";window.location.href = "/login"</script>'

    @app.route('/login', methods=['GET', 'POST'])
    def login():
        if request.method == 'POST':
            username = request.form.get('username')
            password = request.form.get('password')
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            for user in userdata['users']:
                if user['name'] == username and user['password'] == password:
                    return f"<script>document.cookies.token = '{user['token']}';window.location.href = '/watch'</script>"
            return '<script>window.location.href = "/login?error=1"</script>'
        else:
            return render_template('login.html')


    @app.route('/register', methods=['GET', 'POST'])
    def register():
        settings = Config.read_settings()
        if not settings['dashboard']['user_control']['allow_register']:
            return '<script>alert("伺服器沒有啟用註冊!");history.back();</script>'
        if request.method == 'POST':
            if not request.form.get('pw1') == request.form.get('pw2'):
                return '<script>window.location.href = "/register?error=2"</script>'
            username = request.form.get('username')
            password = request.form.get('pw1')
            userdata = json.load(open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'r'))
            for user in userdata['users']:
                if user['name'] == username:
                    return '<script>window.location.href = "/register?error=1"</script>'
            newuser = {'name': username, 'password': password, 'token': ''.join(random.sample(string.ascii_letters + string.digits, 32)), 'videotimes': [], 'role': 'user'}
            userdata['users'].append(newuser)
            with open(os.path.join(Config.get_working_dir(), 'Dashboard', 'userdata.json'), 'w', encoding='utf-8') as f:
                json.dump(userdata, f, ensure_ascii=False, indent=4)
            return '<script>alert("註冊成功!");window.location.href = "/login"</script>'
        else:
            return render_template('register.html')


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
        server = WSGIServer((host, port), app, handler_class=WebSocketHandler, certfile=ssl_crt, keyfile=ssl_key)

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

        server.wrap_socket = my_wrap_socket
        server.wrap_socket_and_handle = my_wrap_socket_and_handle

    else:
        # app.run(use_reloader=False, port=port, host=host, threaded=True)
        server = WSGIServer((host, port), app, handler_class=WebSocketHandler, environ={'wsgi.multithread': True,'wsgi.multiprocess': True,})

    server.serve_forever()


if __name__ == '__main__':
    run()
    pass
