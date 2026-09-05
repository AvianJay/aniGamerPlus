"""A standalone Flask app that serves the real dashboard templates and static
files against fixture data.

``Dashboard/Server.py`` pulls in ``Config`` -> ``Loginer`` -> ``selenium`` and a
live ``config.json``, none of which belong in a UI test. This harness mounts the
same ``templates`` / ``static`` folders and reimplements only the handful of
endpoints the redesigned pages talk to, with the same response shapes as the
real server (see ``_build_dashboard_bootstrap`` / ``_build_watch_bootstrap`` and
the ``/watch/time`` route in ``Dashboard/Server.py``).
"""

import json
import os
import re
import threading
import time
from datetime import datetime, timedelta
from wsgiref.simple_server import WSGIRequestHandler, make_server

from flask import Flask, jsonify, make_response, render_template, request, send_file

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE_PATH = os.path.join(ROOT, 'Dashboard', 'templates')
STATIC_PATH = os.path.join(ROOT, 'Dashboard', 'static')
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures')

ANIMES = [
    ('葬送的芙莉蓮', 4),
    ('迷宮飯', 3),
    ('孤獨搖滾！', 2),
    ('SPY×FAMILY', 3),
    ('Frieren Beyond Journey', 2),
]


def build_video_list():
    """Mirror the schema written by ``aniGamerPlus.updatelist()``."""
    videos = []
    sn = 100000
    now = datetime.now().replace(microsecond=0)
    for day, (anime, episodes) in enumerate(ANIMES):
        # Anchored inside its own calendar day rather than a fixed number of
        # hours back: an hour before ``now`` is yesterday when the suite runs
        # just after midnight, and the timetable then has no 今天 group at all.
        midnight = (now - timedelta(days=day)).replace(hour=0, minute=0, second=0)
        for episode in range(1, episodes + 1):
            sn += 1
            stamp = max(midnight, now - timedelta(days=day, seconds=episode))
            videos.append({
                'sn': str(sn),
                'title': '%s[%d]' % (anime, episode),
                'anime_name': anime,
                'episode': str(episode),
                'resolution': 1080 if episode % 2 else 720,
                'path': os.path.join('bangumi', anime, '%s[%d][1080P].mp4' % (anime, episode)),
                'source': 'baha',
                'timestamp': int(stamp.timestamp()),
                'danmu_path': os.path.join('bangumi', anime, '%s[%d].ass' % (anime, episode)),
                'danmu': True,
            })
    return {'videos': videos}


VIDEO_LIST = build_video_list()
FIRST_SN = VIDEO_LIST['videos'][0]['sn']
# One title whose file is missing, so /thumbnail.jpg has something to 404 on.
NO_THUMBNAIL_SN = VIDEO_LIST['videos'][-1]['sn']

# Written by /watch/time and read back by the home page, exactly like the real
# server's per-user ``videotimes`` map.
WATCH_TIMES = {
    VIDEO_LIST['videos'][1]['sn']: {
        'time': 420,
        'ended': False,
        'timestamp': int(time.time()) - 600,
        'duration': 1440,
    },
    VIDEO_LIST['videos'][5]['sn']: {
        'time': 90,
        'ended': False,
        'timestamp': int(time.time()) - 4000,
        'duration': 1500,
    },
}


def create_app(logged_in=True):
    app = Flask(__name__, template_folder=TEMPLATE_PATH, static_folder=STATIC_PATH)
    app.config['TESTING'] = True

    def dashboard_bootstrap():
        return {
            'serverInfo': {
                'online_watch': True,
                'user_control': logged_in,
                'online_watch_requires_login': False,
            },
            'loggedIn': logged_in,
            'currentUser': {'username': 'tester', 'role': 'admin'} if logged_in else None,
        }

    def watch_bootstrap():
        requested_sn = str(request.args.get('id') or '').strip()
        requested_resolution = str(request.args.get('res') or '').strip()
        bootstrap = {
            'requestedVideoId': requested_sn or None,
            'requestedResolution': requested_resolution or None,
            'initialVideoData': None,
            'initialVideoSeries': [],
            'resumeTime': 0,
        }
        if not requested_sn:
            return bootstrap
        initial = None
        for video in VIDEO_LIST['videos']:
            if str(video['sn']) == requested_sn:
                initial = dict(video)
                break
        if not initial:
            return bootstrap
        if requested_resolution.isdigit():
            initial['resolution'] = requested_resolution
        bootstrap['initialVideoData'] = initial
        bootstrap['initialVideoSeries'] = [
            video for video in VIDEO_LIST['videos']
            if video['anime_name'] == initial['anime_name']
        ]
        entry = WATCH_TIMES.get(requested_sn, {})
        if logged_in and not entry.get('ended'):
            bootstrap['resumeTime'] = int(entry.get('time', 0) or 0)
        return bootstrap

    @app.context_processor
    def inject_context():
        return {'dashboard_bootstrap': dashboard_bootstrap()}

    @app.route('/')
    def home():
        return render_template('index.html')

    @app.route('/watch')
    def watch():
        return render_template('watch.html', watch_bootstrap=watch_bootstrap())

    @app.route('/control')
    def control():
        return '<!doctype html><title>control</title><p>control stub</p>'

    @app.route('/video_list.json')
    def video_list():
        return jsonify(VIDEO_LIST)

    @app.route('/get_server_info')
    def server_info():
        return jsonify(dashboard_bootstrap()['serverInfo'])

    @app.route('/watch/time', methods=['GET', 'POST'])
    def watch_time():
        data = request.args if request.method == 'GET' else (request.get_json() or request.form)
        kind = data.get('type')
        sn = data.get('sn')
        if kind == 'set':
            entry = {
                'time': int(float(data.get('time') or 0)),
                'ended': str(data.get('ended', 'false')).lower() == 'true',
                'timestamp': int(time.time()),
            }
            try:
                duration = int(float(data.get('duration')))
                if duration > 0:
                    entry['duration'] = duration
            except (TypeError, ValueError):
                pass
            WATCH_TIMES[sn] = entry
            return '{"status":"200"}'
        if kind == 'get':
            if not sn:
                return jsonify(WATCH_TIMES)
            return jsonify(WATCH_TIMES.get(sn, {'time': 0, 'ended': False}))
        return '{"status":"404", "msg":"Invalid type"}'

    @app.route('/get_video.mp4')
    def get_video():
        # The fixture is VP9/Opus rather than H.264: Playwright's bundled
        # Chromium ships without the proprietary codecs, and the browser goes by
        # the Content-Type here, not by the route's .mp4 name. send_file handles
        # the Range requests the player issues while seeking.
        return send_file(os.path.join(FIXTURES, 'sample.webm'), mimetype='video/webm',
                         conditional=True)

    @app.route('/thumbnail.jpg')
    def thumbnail():
        # The real server grabs this frame out of the downloaded episode with
        # ffmpeg and 404s when there is no file to grab from; NO_THUMBNAIL_SN
        # stands in for that case so the gradient fallback stays covered.
        sn = request.args.get('id')
        if not sn or sn == NO_THUMBNAIL_SN:
            return jsonify({'error': 'thumbnail unavailable'}), 404
        return send_file(os.path.join(FIXTURES, 'sample-thumb.jpg'), mimetype='image/jpeg')

    @app.route('/get_danmu.ass')
    def get_danmu():
        response = make_response(send_file(os.path.join(FIXTURES, 'sample.ass')))
        response.headers['Content-Type'] = 'text/plain; charset=utf-8'
        return response

    @app.route('/manifest.webmanifest')
    def manifest():
        response = make_response(send_file(os.path.join(STATIC_PATH, 'manifest.webmanifest')))
        response.headers['Content-Type'] = 'application/manifest+json; charset=utf-8'
        return response

    @app.route('/sw.js')
    def service_worker():
        response = make_response(send_file(os.path.join(STATIC_PATH, 'sw.js')))
        response.headers['Content-Type'] = 'application/javascript; charset=utf-8'
        response.headers['Service-Worker-Allowed'] = '/'
        return response

    @app.route('/favicon.ico')
    def favicon():
        return send_file(os.path.join(STATIC_PATH, 'img', 'aniGamerPlus.ico'))

    @app.route('/apple-touch-icon.png')
    @app.route('/apple-touch-icon-precomposed.png')
    def apple_touch_icon():
        return send_file(os.path.join(STATIC_PATH, 'img', 'pwa', 'apple-touch-icon.png'))

    @app.after_request
    def after_request(response):
        response.headers.add('Accept-Ranges', 'bytes')
        return response

    return app


class QuietHandler(WSGIRequestHandler):
    def log_message(self, *args):
        pass


class HarnessServer(object):
    """Runs the harness on a background thread and exposes its base URL."""

    def __init__(self, logged_in=True):
        self.httpd = make_server('127.0.0.1', 0, create_app(logged_in), handler_class=QuietHandler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def url(self):
        return 'http://127.0.0.1:%d' % self.port

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


def head_of(path):
    """Read a template/static file for assertions that do not need a browser."""
    with open(os.path.join(ROOT, path), encoding='utf-8') as handle:
        return handle.read()


ASSET_REF = re.compile(r'(?:href|src)="\./(static/[^"?]+)')


def referenced_static_assets(html):
    return sorted(set(ASSET_REF.findall(html)))


if __name__ == '__main__':
    with HarnessServer() as server:
        print('harness on %s (sample sn=%s)' % (server.url, FIRST_SN))
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
