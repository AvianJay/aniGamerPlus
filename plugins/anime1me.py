import html
import json
import os
import re
import subprocess
import sys
import threading
import time
import zlib
from datetime import datetime
from urllib.parse import quote, unquote

import requests
from bs4 import BeautifulSoup

import Config
from Anime import Anime
from ColorPrint import err_print
from plugin_system import CatalogProvider


LIST_FILENAME = 'anime1me_list.txt'
STATE_FILENAME = 'anime1me_state.json'
DOWNLOAD_HEADERS = {
    'accept-language': 'zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7',
    'referer': 'https://anime1.me/',
    'user-agent': (
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/134.0.0.0 Safari/537.36'
    ),
}
VIDEO_HEADERS = {
    **DOWNLOAD_HEADERS,
    'accept': '*/*',
    'sec-fetch-dest': 'video',
    'sec-fetch-mode': 'no-cors',
    'sec-fetch-site': 'same-site',
}
API_HEADERS = {
    **DOWNLOAD_HEADERS,
    'accept': '*/*',
    'content-type': 'application/x-www-form-urlencoded',
    'origin': 'https://anime1.me',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-site',
}

_ACTIVE_DOWNLOADS = set()
_ACTIVE_DOWNLOADS_LOCK = threading.Lock()
_DOWNLOAD_SEMAPHORE = threading.Semaphore(1)
# Dashboard 跟主程式各自有一個插件實例, PluginManager.reload() 還會再換新的一個,
# 但大家寫的是同一份 state 檔跟同一份 anime1me_list.txt. 鎖必須是模組層級的.
_STATE_LOCK = threading.RLock()
_LIST_LOCK = threading.Lock()

# 線上片庫的來源 id. Dashboard 用它當作品編號的前綴 (anime1:1878).
PROVIDER_ID = 'anime1'
PROVIDER_NAME = 'Anime1.me'
SITE_URL = 'https://anime1.me/'
ANIMELIST_URL = 'https://anime1.me/animelist.json'
# 全站片單一包 130 KB 左右, 站上首頁自己也是整包拿. 半小時更新一次就夠了
CATALOG_TTL = 30 * 60
CATALOG_RETRY = 5 * 60
# 作品的集數表要一頁一頁翻分類頁, 開過的作品留一會兒, 免得每開一次 sheet 就翻一輪
CATEGORY_TTL = 10 * 60
CATEGORY_CACHE_SIZE = 200
# 分類頁一頁 14 集; 80 頁是一千多集, 再長的作品也不太可能在 anime1 上
MAX_CATEGORY_PAGES = 80

_catalog_lock = threading.Lock()
_catalog_cache = {'at': 0.0, 'failed_at': 0.0, 'items': None, 'refreshing': False}
_category_lock = threading.Lock()
_category_cache = {}


def legalize_filename(filename):
    return Config.legalize_filename(str(filename).strip())


def normalize_url(url):
    normalized = str(url).strip()
    if not normalized:
        return ''
    normalized = normalized.replace('http://', 'https://', 1)
    if '/page/' in normalized:
        normalized = normalized.split('/page/')[0]
    return normalized.rstrip('/') + '/'


def ensure_sample_list(path):
    if os.path.exists(path):
        return
    sample = (
        '# 每行一個 anime1.me 分類頁網址，格式:\n'
        '# https://anime1.me/category/... latest <自訂名稱>\n'
        '# 可用模式: latest / all\n'
        '# 也支援像 sn_list.txt 一樣使用 @Tag 分組\n'
    )
    with open(path, 'w', encoding='utf-8') as f:
        f.write(sample)


def episode_sort_key(label):
    text = str(label).strip().lower()
    numbers = [int(part) for part in re.findall(r'\d+', text)]
    if numbers:
        return (0, numbers, text)
    return (1, [10**9], text)


def parse_episode_label(title):
    match = re.search(r'\[(.+?)\]\s*$', str(title).strip())
    if match:
        return match.group(1).strip()
    return str(title).strip()


def parse_agpp_episode(label, fallback_index):
    raw = str(label).strip()
    lowered = raw.lower()
    digits = re.findall(r'\d+', lowered)
    episode_number = int(digits[-1]) if digits else int(fallback_index)

    if re.fullmatch(r'\d+(?:\.\d+)?', lowered):
        return {'episode': episode_number, 'type': 'normal'}
    if 'ova' in lowered:
        return {'episode': episode_number, 'type': 'ova'}
    if 'oad' in lowered:
        return {'episode': episode_number, 'type': 'oad'}
    if 'sp' in lowered or 'special' in lowered:
        return {'episode': episode_number, 'type': 'sp'}
    if 'ona' in lowered:
        return {'episode': episode_number, 'type': 'ona'}
    if 'movie' in lowered:
        return {'episode': episode_number, 'type': 'movie'}
    if 'extra' in lowered:
        return {'episode': episode_number, 'type': 'extra'}
    return {'episode': episode_number, 'type': 'special'}


def probe_video_height(path, ffprobe_program='ffprobe'):
    commands = [
        [ffprobe_program, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=height', '-of', 'csv=p=0', path],
    ]
    if os.name == 'nt':
        commands.append([os.path.join(Config.get_working_dir(), 'ffprobe.exe'), '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=height', '-of', 'csv=p=0', path])

    for cmd in commands:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            text = result.stdout.strip()
            if text.isdigit():
                return int(text)
        except BaseException:
            continue
    return 720


def download_file(url, session, filename):
    with session.get(url, stream=True, headers=VIDEO_HEADERS, timeout=60) as response:
        response.raise_for_status()
        with open(filename, 'wb') as f:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    f.write(chunk)
    return filename


def download_hls(url, filename, ffmpeg_program='ffmpeg'):
    commands = [
        [ffmpeg_program, '-y', '-protocol_whitelist', 'file,http,https,tcp,tls', '-i', url, '-acodec', 'copy', '-vcodec', 'copy', filename],
    ]
    if os.name == 'nt':
        commands.append([os.path.join(Config.get_working_dir(), 'ffmpeg.exe'), '-y', '-protocol_whitelist', 'file,http,https,tcp,tls', '-i', url, '-acodec', 'copy', '-vcodec', 'copy', filename])

    last_error = None
    for cmd in commands:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0:
                return True
            last_error = result.stderr.strip() or result.stdout.strip() or 'ffmpeg failed'
        except BaseException as exc:
            last_error = str(exc)
    raise RuntimeError(last_error or 'ffmpeg download failed')


def get_mp4_url(data, session):
    response = session.post('https://v.anime1.me/api', headers=API_HEADERS, data=f'd={data}', timeout=30)
    response.raise_for_status()
    payload = response.json()
    return 'https:' + payload['s'][0]['src']


def download_anime(video_data, path, session):
    method = video_data['method']
    if method == 'direct':
        download_file(video_data['data'], session, path)
        return True
    if method == 'apireq':
        mp4_url = get_mp4_url(video_data['data'], session)
        download_file(mp4_url, session, path)
        return True
    if method == 'p2p':
        return download_hls(video_data['data'], path)
    raise RuntimeError(f'Unsupported download method: {method}')


def parse_article(article, session, title='', page_url=''):
    # 分類頁上每一集的標題是一條連到單集頁的連結; 單集頁自己的標題就只是字,
    # 那時候標題跟網址由呼叫端給
    h2_tag = article.find('h2')
    link_tag = h2_tag.find('a') if h2_tag else None
    if link_tag:
        title = link_tag.get_text(strip=True)
        page_url = link_tag.get('href', '')
    elif h2_tag and not title:
        title = h2_tag.get_text(strip=True)
    title = title or 'Unknown'
    method = 'unknown'
    data = None

    video_tag = article.find('video')
    if video_tag:
        if video_tag.get('data-apireq'):
            method = 'apireq'
            data = video_tag.get('data-apireq')
        else:
            source_tag = article.find('source')
            if source_tag and source_tag.get('src'):
                method = 'direct'
                src = source_tag.get('src')
                data = src if src.startswith('http') else 'https:' + src
    elif article.find('button'):
        button = article.find('button')
        iframe_url = button.get('data-src')
        if iframe_url:
            method = 'p2p'
            response = session.get(iframe_url, headers=DOWNLOAD_HEADERS, timeout=30)
            response.raise_for_status()
            soup = BeautifulSoup(response.text, 'html.parser')
            source_tag = soup.find('source')
            if source_tag and source_tag.get('src'):
                data = source_tag.get('src')

    return {
        'name': title,
        'page_url': page_url,
        'episode_label': parse_episode_label(title),
        'method': method,
        'data': data,
    }


def get_info(url, session):
    videos = []
    normalized_url = normalize_url(url)
    response = session.get(normalized_url, headers=DOWNLOAD_HEADERS, timeout=30)
    response.raise_for_status()
    soup = BeautifulSoup(response.text, 'html.parser')

    title_node = soup.find('h1', class_='page-title')
    title = title_node.get_text(strip=True) if title_node else normalized_url

    while True:
        articles = soup.find_all('article')
        for article in articles:
            video = parse_article(article, session)
            if video['data']:
                videos.append(video)

        prev_button = soup.find('div', class_='nav-previous')
        prev_link = prev_button.find('a') if prev_button else None
        if not prev_link or not prev_link.get('href'):
            break

        response = session.get(prev_link['href'], headers=DOWNLOAD_HEADERS, timeout=30)
        response.raise_for_status()
        soup = BeautifulSoup(response.text, 'html.parser')

    return title, videos


# ---------------------------------------------------------------- 線上片庫
# Dashboard 的「所有動畫」除了動畫瘋, 也列得出 anime1.me 的作品. 這裡只管
# 抓跟解析; 作品編號加前綴、標出哪幾集已經在片庫, 是 Dashboard 那邊的事.

def _plain(value):
    return html.unescape(str(value if value is not None else '')).strip()


def parse_animelist(payload):
    """anime1.me/animelist.json -> 片單卡片.

    每一列是 [分類編號, 名稱, 集數, 年份, 季節, 字幕組], 最近更新的排最前面.
    分類編號 0 的是連去 anime1.pw 的站外作品, 名稱欄是一段 <a>, 不收.
    """
    items = []
    seen = set()
    for row in payload or []:
        if not isinstance(row, (list, tuple)) or len(row) < 2:
            continue
        try:
            cat_id = int(row[0])
        except (TypeError, ValueError):
            continue
        title = _plain(row[1])
        if cat_id <= 0 or cat_id in seen or not title:
            continue
        seen.add(cat_id)
        # 沒有字幕組 (或不知道集數) 的那一欄站上填的是 -, 當成空的
        fields = ['' if field == '-' else field for field in (_plain(value) for value in row[2:6])]
        fields += [''] * (4 - len(fields))
        episodes, year, season, subtitle = fields
        # 跨季的作品季節欄自己就帶年份 (2025冬/2025夏/2026春), 不必再掛一次
        when = season if re.search(r'\d', season) else ' '.join(part for part in (year, season) if part)
        items.append({
            'animeSn': str(cat_id),
            'title': title,
            'cover': '',
            'info': when,
            'volume': episodes,
            'popular': '',
            'subtitle': subtitle,
        })
    return items


_catalog_fetch_lock = threading.Lock()


def _refresh_catalog():
    try:
        response = requests.get(ANIMELIST_URL, headers=DOWNLOAD_HEADERS, timeout=15)
        response.raise_for_status()
        items = parse_animelist(response.json())
    except BaseException as exc:
        err_print(0, 'anime1.me 片單取得失敗', str(exc), no_sn=True, status=1, display=False)
        items = None
    with _catalog_lock:
        if items:
            _catalog_cache.update(at=time.time(), items=items)
        else:
            _catalog_cache['failed_at'] = time.time()
        _catalog_cache['refreshing'] = False
    return items


def load_catalog():
    """全站片單. 過期了先把舊的交出去, 背景再抓一份新的; 一份都沒有才當場抓."""
    with _catalog_lock:
        items = _catalog_cache['items']
        if items is not None:
            now = time.time()
            stale = now - _catalog_cache['at'] >= CATALOG_TTL
            backoff = now - _catalog_cache['failed_at'] < CATALOG_RETRY
            if stale and not backoff and not _catalog_cache['refreshing']:
                _catalog_cache['refreshing'] = True
                threading.Thread(target=_refresh_catalog, daemon=True, name='anime1-catalog').start()
            return items
    # 同時進來的請求一起等這一趟, 不要各打一次
    with _catalog_fetch_lock:
        with _catalog_lock:
            if _catalog_cache['items'] is not None:
                return _catalog_cache['items']
            if time.time() - _catalog_cache['failed_at'] < CATALOG_RETRY:
                return []
        return _refresh_catalog() or []


def find_catalog_item(anime_id):
    target = str(anime_id)
    for item in load_catalog():
        if item['animeSn'] == target:
            return item
    return None


_POST_ID = re.compile(r'post-(\d+)')


def parse_category_page(text):
    """分類頁的一頁: (作品名, 這一頁的集數, 上一頁的網址).

    站上最新的一集排最前面, 「上一頁」是更舊的那幾集. 這裡只列集數, 不解析
    影片來源 —— 那個簽章會過期, 真的要下載時再去單集頁拿新的.
    """
    soup = BeautifulSoup(text, 'html.parser')
    title_node = soup.find('h1', class_='page-title')
    title = title_node.get_text(strip=True) if title_node else ''
    episodes = []
    for article in soup.find_all('article'):
        # 公告之類的文章沒有影片, 列出來也下載不了
        if not article.find('video') and not article.find('button', attrs={'data-src': True}):
            continue
        link = article.select_one('h2 a[href]')
        match = _POST_ID.search(article.get('id') or '')
        if not link or not match:
            continue
        page_url = link['href'].strip()
        if not page_url.startswith(SITE_URL):
            continue
        name = link.get_text(strip=True)
        time_node = article.find('time')
        episodes.append({
            'id': match.group(1),
            'name': name,
            'label': parse_episode_label(name),
            'url': page_url,
            'date': (time_node.get('datetime') or '')[:10] if time_node else '',
        })
    prev_link = soup.select_one('div.nav-previous a[href]')
    prev_url = prev_link['href'].strip() if prev_link else ''
    if not prev_url.startswith(SITE_URL):
        prev_url = ''
    return title, episodes, prev_url


def fetch_category(cat_id):
    response = requests.get(SITE_URL + '?cat=' + str(int(cat_id)), headers=DOWNLOAD_HEADERS, timeout=30)
    response.raise_for_status()
    # ?cat= 會轉到分類頁真正的網址, 追番清單跟 state 認的都是那一個
    url = response.url
    if not url.startswith(SITE_URL):
        raise RuntimeError('分類頁轉到了站外: ' + url)
    title, episodes, prev_url = parse_category_page(response.text)
    pages = 1
    while prev_url and pages < MAX_CATEGORY_PAGES:
        response = requests.get(prev_url, headers=DOWNLOAD_HEADERS, timeout=30)
        response.raise_for_status()
        _, more, prev_url = parse_category_page(response.text)
        episodes.extend(more)
        pages += 1

    # 片庫跟動畫瘋的集數表都是從第一集排起
    ordered = []
    seen = set()
    for episode in reversed(episodes):
        if episode['id'] not in seen:
            seen.add(episode['id'])
            ordered.append(episode)
    return {
        'title': title,
        'url': url if '?' in url else normalize_url(url),
        'episodes': ordered,
    }


def load_category(cat_id):
    key = str(int(cat_id))
    with _category_lock:
        cached = _category_cache.get(key)
        if cached and time.time() - cached['at'] < CATEGORY_TTL:
            return cached['data']
    data = fetch_category(key)
    with _category_lock:
        _category_cache[key] = {'at': time.time(), 'data': data}
        while len(_category_cache) > CATEGORY_CACHE_SIZE:
            oldest = min(_category_cache, key=lambda name: _category_cache[name]['at'])
            del _category_cache[oldest]
    return data


def url_identity(url):
    # 清單裡的網址可能是瀏覽器複製來的百分比編碼, 也可能是解碼過的中文
    return unquote(normalize_url(url)).lower()


def display_episode(label):
    text = str(label).strip()
    return str(int(text)) if text.isdigit() else text


def subscribe_anime(list_path, url, title=''):
    """以 all 模式把作品加進 anime1me_list.txt, 已經在裡面就只把模式升成 all.

    回傳 'added' / 'updated' / 'exists'.
    """
    target = url_identity(url)
    with _LIST_LOCK:
        ensure_sample_list(list_path)
        with open(list_path, 'r', encoding='utf-8') as f:
            content = f.read()
        newline = '\r\n' if '\r\n' in content else '\n'
        lines = content.splitlines()
        result = 'added'
        for index, line in enumerate(lines):
            body, sep, comment = line.partition('#')
            parts = body.split()
            if not parts or parts[0].startswith('@') or url_identity(parts[0]) != target:
                continue
            if len(parts) > 1 and parts[1] == 'all':
                return 'exists'
            if len(parts) > 1 and parts[1] == 'latest':
                body = re.sub(r'^(\s*\S+\s+)latest', r'\1all', body, count=1)
            else:
                body = re.sub(r'^(\s*\S+)', r'\1 all', body, count=1)
            lines[index] = body + sep + comment
            result = 'updated'
            break
        else:
            # 跟 sn_list 一樣: @分類會一路影響到檔尾, 新加的這部先明確回到未分類
            active_tag = False
            for line in lines:
                stripped = line.strip()
                if stripped.startswith('@'):
                    active_tag = bool(stripped[1:].strip())
            if active_tag:
                lines.append('@')
            lines.append(url + ' all' + ('  # ' + title if title else ''))

        tmp_path = list_path + '.tmp'
        with open(tmp_path, 'w', encoding='utf-8', newline='') as f:
            f.write(newline.join(lines) + newline)
        os.replace(tmp_path, list_path)
        return result


def write_agpp_metadata(series_dir, anime_name, videos, source='Anime1.me'):
    entries = []
    ordered_videos = sorted(videos, key=lambda item: episode_sort_key(item.get('episode_label')))
    for index, video in enumerate(ordered_videos, start=1):
        filename = video.get('filename')
        if not filename:
            continue
        episode_info = parse_agpp_episode(video.get('episode_label', ''), index)
        resolution = int(video.get('resolution') or 720)
        entries.append({
            'episode': episode_info['episode'],
            'resolution': resolution,
            'type': episode_info['type'],
            'filename': filename,
        })

    payload = {
        'videos': entries,
        'anime_name': anime_name,
        'source': source,
        'unique_sn': str(zlib.crc32(anime_name.encode('utf-8')) % 1000000).zfill(6),
    }
    metadata_path = os.path.join(series_dir, '.aniGamerPlus.json')
    with open(metadata_path, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False)


def generate_agpp(path, anime_name=None, source='Anime1.me'):
    metadata_path = os.path.join(path, '.aniGamerPlus.json')
    if os.path.exists(metadata_path):
        return metadata_path

    target_name = anime_name or os.path.basename(os.path.abspath(path))
    videos = []
    for filename in sorted(os.listdir(path)):
        if not filename.lower().endswith('.mp4'):
            continue
        label = parse_episode_label(os.path.splitext(filename)[0])
        videos.append({
            'episode_label': label,
            'filename': filename,
            'resolution': probe_video_height(os.path.join(path, filename)),
        })
    write_agpp_metadata(path, target_name, videos, source=source)
    return metadata_path


def read_anime_list(list_path):
    ensure_sample_list(list_path)
    Config.check_encoding(list_path)

    results = []
    current_tag = ''
    with open(list_path, 'r', encoding='utf-8') as f:
        for raw_line in f.readlines():
            stripped = raw_line.strip()
            if not stripped:
                continue
            if stripped.startswith('@'):
                current_tag = stripped[1:].strip()
                continue
            if stripped.startswith('#'):
                continue

            line = raw_line.split('#', 1)[0].strip()
            if not line:
                continue

            rename = ''
            rename_match = re.search(r'<(.+?)>', line)
            if rename_match:
                rename = rename_match.group(1).strip()
                line = re.sub(r'<.+?>', '', line).strip()

            parts = [part for part in re.split(r'\s+', line) if part]
            if not parts:
                continue

            url = parts[0]
            mode = 'latest'
            if len(parts) > 1 and parts[1] in ('latest', 'all'):
                mode = parts[1]

            if not url.startswith('https://anime1.me/') and not url.startswith('https://anime1.pw/'):
                continue

            results.append({
                'url': normalize_url(url),
                'mode': mode,
                'tag': current_tag,
                'rename': rename,
            })

    return results


class Anime1CompatAnime:
    def __init__(self, settings, anime_name, video, file_path, resolution, file_size_mb, bangumi_dir):
        self._settings = settings
        self._bangumi_name = anime_name
        self._episode = video.get('episode_label', '')
        self._title = video.get('name', anime_name)
        self._video_filename = os.path.basename(file_path)
        self._sn = int(zlib.crc32(video.get('page_url', self._title).encode('utf-8')) & 0x7FFFFFFF)
        self.local_video_path = file_path
        self.video_resolution = int(resolution or 0)
        self.video_size = int(file_size_mb or 0)
        self.upload_succeed_flag = False
        self._bangumi_dir = bangumi_dir

    def get_sn(self):
        return self._sn

    def get_bangumi_name(self):
        return self._bangumi_name

    def get_episode(self):
        return self._episode

    def get_title(self):
        return self._title

    def upload(self, bangumi_tag='', debug_file=''):
        return Anime.upload(self, bangumi_tag=bangumi_tag, debug_file=debug_file)

    def notify_download_complete(self):
        if self._settings['coolq_notify']:
            try:
                msg = '【aniGamerPlus消息】\n《' + self._video_filename + '》下載完成, 本集 ' + str(self.video_size) + ' MB'
                if self._settings['coolq_settings']['message_suffix']:
                    msg = msg + '\n\n' + self._settings['coolq_settings']['message_suffix']

                for query in self._settings['coolq_settings']['query']:
                    if '?' not in query:
                        query = query + '?'
                    else:
                        query = query + '&'
                    req = query + self._settings['coolq_settings']['msg_argument_name'] + '=' + quote(msg)
                    requests.get(req, timeout=15)
            except BaseException as exc:
                err_print(self._sn, 'CQ NOTIFY ERROR', 'Exception: ' + str(exc), status=1)

        if self._settings['telebot_notify']:
            try:
                msg = '【aniGamerPlus消息】\n《' + self._video_filename + '》下載完成, 本集 ' + str(self.video_size) + ' MB'
                token = self._settings['telebot_token']
                if self._settings['telebot_use_chat_id'] and self._settings['telebot_chat_id']:
                    chat_id = self._settings['telebot_chat_id']
                else:
                    response = requests.get(f'https://api.telegram.org/bot{token}/getUpdates', timeout=15).json()
                    chat_id = response['result'][0]['message']['chat']['id']
                requests.get(
                    f'https://api.telegram.org/bot{token}/sendMessage',
                    params={'chat_id': str(chat_id), 'text': msg},
                    timeout=15,
                )
            except BaseException as exc:
                err_print(self._sn, 'TG NOTIFY ERROR', 'Exception: ' + str(exc), status=1)

        if self._settings['discord_notify']:
            try:
                msg = '【aniGamerPlus消息】\n《' + self._video_filename + '》下載完成，本集 ' + str(self.video_size) + ' MB'
                payload = {
                    'content': None,
                    'embeds': [{
                        'title': '下載完成',
                        'description': msg,
                        'color': 5814783,
                        'author': {
                            'name': 'Anime1.me',
                        },
                    }],
                }
                response = requests.post(self._settings['discord_token'], json=payload, timeout=15)
                if response.status_code != 204:
                    err_print(self._sn, 'discord NOTIFY ERROR', 'Exception: Send msg error\nReq: ' + response.text, status=1)
            except BaseException as exc:
                err_print(self._sn, 'Discord NOTIFY UNKNOWN ERROR', 'Exception: ' + str(exc), status=1)

        if self._settings['plex_refresh']:
            try:
                url = (
                    'https://{plex_url}/library/sections/{plex_section}/refresh?X-Plex-Token={plex_token}'
                    .format(
                        plex_url=self._settings['plex_url'],
                        plex_section=self._settings['plex_section'],
                        plex_token=self._settings['plex_token'],
                    )
                )
                response = requests.get(url, timeout=30)
                if response.status_code != 200:
                    err_print(self._sn, 'Plex auto Refresh ERROR', status=1)
            except BaseException as exc:
                err_print(self._sn, 'Plex auto Refresh UNKNOWN ERROR', 'Exception: ' + str(exc), status=1)

        if self._settings['m3u8']:
            try:
                playlist_path = os.path.join(self._bangumi_dir, legalize_filename(self._bangumi_name) + '.m3u8')
                if not os.path.isfile(playlist_path):
                    with open(playlist_path, 'w', encoding='utf-8') as f:
                        f.write('#EXTM3U\n')
                with open(playlist_path, 'a', encoding='utf-8') as f:
                    f.write('#EXTINF:-1,' + self._title + '\n' + self._video_filename + '\n')
                err_print(self._sn, 'M3U8 寫入成功')
            except BaseException as exc:
                err_print(self._sn, 'M3U8 寫入失敗', str(exc), status=1)


class Anime1MePlugin(CatalogProvider):
    provider_id = PROVIDER_ID
    provider_name = PROVIDER_NAME
    # 站上沒有分類標籤可篩; 單集下載跟整部追番都有
    features = {'tags': False, 'download': True, 'subscribe': True}

    def __init__(self, settings):
        self._settings = settings
        self._working_dir = settings.get('working_dir', Config.get_working_dir())
        self._plugin_dir = os.path.dirname(os.path.realpath(__file__))
        self._list_path = os.path.join(self._working_dir, LIST_FILENAME)
        self._state_path = os.path.join(self._plugin_dir, STATE_FILENAME)
        self._session = requests.Session()
        self._session.headers.update(DOWNLOAD_HEADERS)
        ensure_sample_list(self._list_path)
        self._state = self._load_state()

    def _load_state(self):
        if not os.path.exists(self._state_path):
            return {'entries': {}}
        try:
            with open(self._state_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            if 'entries' not in data:
                data['entries'] = {}
            return data
        except BaseException:
            return {'entries': {}}

    def _read_state(self):
        # 寫入是先寫暫存檔再 os.replace; Windows 上讀的那一端開著檔案, replace 會
        # 丟 PermissionError, 所以讀也要進同一把鎖
        with _STATE_LOCK:
            self._state = self._load_state()
            return self._state

    def _update_state(self, mutate):
        """在鎖裡重讀 state 檔、改、寫回去.

        以前是每個實例拿自己那份記憶體副本整份寫回去. Dashboard 跟主程式各有
        一個實例, reload 又會換新的, 後寫的那一份就把先寫的幾集洗掉 —— 那幾集
        下一輪檢查更新又被當成新的, 再下載一次.
        """
        with _STATE_LOCK:
            state = self._load_state()
            result = mutate(state)
            os.makedirs(self._plugin_dir, exist_ok=True)
            tmp_path = self._state_path + '.tmp'
            with open(tmp_path, 'w', encoding='utf-8') as f:
                json.dump(state, f, ensure_ascii=False, indent=4)
            os.replace(tmp_path, self._state_path)
            self._state = state
            return result

    def _entry_key(self, entry):
        return normalize_url(entry['url'])

    def _series_name(self, entry, detected_title):
        return entry.get('rename') or detected_title

    def _series_dir(self, entry, anime_name):
        base_dir = self._settings.get('bangumi_dir', os.path.join(self._working_dir, 'bangumi'))
        if entry.get('tag'):
            base_dir = os.path.join(base_dir, legalize_filename(entry['tag']))
        if self._settings.get('classify_bangumi', True):
            return os.path.join(base_dir, legalize_filename(anime_name))
        return base_dir

    def _mark_downloading(self, task_key):
        with _ACTIVE_DOWNLOADS_LOCK:
            if task_key in _ACTIVE_DOWNLOADS:
                return False
            _ACTIVE_DOWNLOADS.add(task_key)
            return True

    def _mark_finished(self, task_key):
        with _ACTIVE_DOWNLOADS_LOCK:
            _ACTIVE_DOWNLOADS.discard(task_key)

    def _write_series_metadata(self, entry_state):
        series_dir = entry_state.get('series_dir')
        anime_name = entry_state.get('anime_name')
        if not series_dir or not anime_name or not os.path.exists(series_dir):
            return
        videos = list(entry_state.get('downloaded', {}).values())
        write_agpp_metadata(series_dir, anime_name, videos, source='Anime1.me')

    def _download_episode(self, entry, anime_name, video, context):
        task_key = f"{self._entry_key(entry)}|{video['page_url']}"
        if not self._mark_downloading(task_key):
            return

        _DOWNLOAD_SEMAPHORE.acquire()
        try:
            err_print(anime_name, 'anime1.me 下載', video['name'], status=0)
            series_dir = self._series_dir(entry, anime_name)
            os.makedirs(series_dir, exist_ok=True)

            filename = legalize_filename(video['name']) + '.mp4'
            output_path = os.path.join(series_dir, filename)

            if not os.path.exists(output_path) or os.path.getsize(output_path) < 5 * 1024 * 1024:
                download_anime(video, output_path, self._session)

            resolution = probe_video_height(output_path)
            file_size_mb = int(os.path.getsize(output_path) / float(1024 * 1024))
            compat_anime = Anime1CompatAnime(
                self._settings,
                anime_name,
                video,
                output_path,
                resolution,
                file_size_mb,
                series_dir,
            )
            entry_key = self._entry_key(entry)

            def record(state):
                state_entry = state['entries'].setdefault(entry_key, {'downloaded': {}})
                state_entry['anime_name'] = anime_name
                state_entry['series_dir'] = series_dir
                state_entry['source_url'] = entry['url']
                state_entry.setdefault('downloaded', {})[video['page_url']] = {
                    'page_url': video['page_url'],
                    'title': video['name'],
                    'episode_label': video['episode_label'],
                    'filename': filename,
                    'path': output_path,
                    'resolution': resolution,
                    'size_mb': file_size_mb,
                    'downloaded_at': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                }
                return json.loads(json.dumps(state_entry))

            self._write_series_metadata(self._update_state(record))
            compat_anime.notify_download_complete()

            if self._settings.get('upload_to_server') and context.get('upload_video'):
                try:
                    upload_success = context['upload_video'](compat_anime, entry.get('tag', ''))
                    compat_anime.upload_succeed_flag = bool(upload_success)
                    if upload_success:
                        err_print(compat_anime.get_sn(), 'anime1.me 上傳完成', compat_anime._video_filename, status=2)
                    else:
                        err_print(compat_anime.get_sn(), 'anime1.me 上傳失敗', compat_anime._video_filename, status=1)
                except BaseException as exc:
                    err_print(compat_anime.get_sn(), 'anime1.me 上傳失敗', str(exc), status=1)

            if self._settings.get('dashboard', {}).get('online_watch') and context.get('updatelist'):
                try:
                    context['updatelist']()
                except BaseException:
                    pass

            err_print(anime_name, 'anime1.me 下載完成', video['name'], status=2)
        except BaseException as exc:
            err_print(anime_name, 'anime1.me 下載失敗', f'{video["name"]}: {exc}', status=1)
        finally:
            if self._settings.get('download_cd', 0) > 0:
                time.sleep(int(self._settings['download_cd']))
            _DOWNLOAD_SEMAPHORE.release()
            self._mark_finished(task_key)

    def _schedule_entry(self, entry, context):
        """清單上的一部作品: 找出還沒下載的集數, 各開一條下載執行緒. 回傳排了幾集."""
        try:
            detected_title, videos = get_info(entry['url'], self._session)
        except BaseException as exc:
            err_print(entry['url'], 'anime1.me 檢查更新失敗', str(exc), status=1)
            return 0

        if not videos:
            return 0

        anime_name = self._series_name(entry, detected_title)
        entry_key = self._entry_key(entry)
        series_dir = self._series_dir(entry, anime_name)

        def remember(state):
            state_entry = state['entries'].setdefault(entry_key, {'downloaded': {}})
            state_entry['anime_name'] = anime_name
            state_entry['series_dir'] = series_dir
            state_entry['source_url'] = entry['url']
            return set(state_entry.get('downloaded', {}))

        downloaded = self._update_state(remember)
        videos_in_order = videos if entry['mode'] == 'all' else videos[:1]
        pending = [video for video in videos_in_order if video['page_url'] not in downloaded]

        if pending:
            err_print(anime_name, 'anime1.me 更新檢查', f'發現 {len(pending)} 個新項目', status=2)

        for video in pending:
            worker = threading.Thread(
                target=self._download_episode,
                args=(entry, anime_name, video, context),
                daemon=True,
            )
            worker.start()
        return len(pending)

    def on_auto_update(self, context):
        scheduled = 0
        for entry in read_anime_list(self._list_path):
            scheduled += self._schedule_entry(entry, context)
        return {'handled': True, 'scheduled': scheduled}

    # ------------------------------------------------------------ 線上片庫

    def catalog_items(self, provider):
        if not self.owns(provider):
            return None
        return load_catalog()

    def _catalog_entry(self, category):
        """這部作品在 anime1me_list.txt 上的那一行; 沒追的話給一個預設的.

        從片單下載的集數跟追番下載的要落在同一個資料夾、記在同一筆 state 下,
        否則使用者自訂的名稱跟分類會被繞過, 同一集還會在兩個地方各存一份.
        """
        target = url_identity(category['url'])
        for entry in read_anime_list(self._list_path):
            if url_identity(entry['url']) == target:
                return entry
        return {'url': category['url'], 'mode': 'latest', 'tag': '', 'rename': ''}

    def _downloaded_by_page(self):
        downloaded = {}
        for state_entry in self._read_state().get('entries', {}).values():
            for page_url, record in (state_entry.get('downloaded') or {}).items():
                downloaded[page_url] = record
        return downloaded

    def catalog_anime(self, provider, anime_id):
        if not self.owns(provider):
            return None
        item = find_catalog_item(anime_id)
        if item is None:
            return None
        category = load_category(anime_id)
        entry = self._catalog_entry(category)
        anime_name = self._series_name(entry, category['title'] or item['title'])
        series_dir = self._series_dir(entry, anime_name)
        downloaded = self._downloaded_by_page()

        regular = []
        special = []
        for index, episode in enumerate(category['episodes'], start=1):
            record = downloaded.get(episode['url']) or {}
            # 還沒下載的集數也給出它下載後會在的位置: 別的方式下載進來的
            # (手動跑 anime1me.py) state 裡沒有紀錄, 但檔案就在那裡
            path = record.get('path') or os.path.join(series_dir, legalize_filename(episode['name']) + '.mp4')
            row = {'id': episode['id'], 'episode': display_episode(episode['label']), 'path': path}
            if parse_agpp_episode(episode['label'], index)['type'] == 'normal':
                regular.append(row)
            else:
                special.append(row)

        groups = []
        if regular:
            groups.append({'name': '本篇', 'episodes': regular})
        if special:
            groups.append({'name': '特別篇', 'episodes': special})
        return {
            'title': category['title'] or item['title'],
            'seasonStart': item['info'],
            'publisher': item['subtitle'],
            'totalEpisode': str(len(category['episodes'])) if category['episodes'] else '',
            'sourceUrl': category['url'],
            'groups': groups,
        }

    def _download_post(self, entry, anime_name, episode, context):
        # 分類頁上的影片簽章過一陣子就失效, 下載前到單集頁拿一份新的
        try:
            response = requests.get(episode['url'], headers=DOWNLOAD_HEADERS, timeout=30)
            response.raise_for_status()
            article = BeautifulSoup(response.text, 'html.parser').find('article')
            if article is None:
                raise RuntimeError('單集頁上找不到影片')
            video = parse_article(article, self._session, title=episode['name'], page_url=episode['url'])
            if not video['data']:
                raise RuntimeError('找不到可下載的影片來源')
        except BaseException as exc:
            err_print(anime_name, 'anime1.me 下載失敗', f'{episode["name"]}: {exc}', status=1)
            return
        self._download_episode(entry, anime_name, video, context)

    def catalog_download(self, provider, anime_id, episodes, mode, context):
        if not self.owns(provider):
            return None
        item = find_catalog_item(anime_id)
        if item is None:
            return {'success': False, 'message': '片單裡沒有這部作品'}
        category = load_category(anime_id)
        entry = self._catalog_entry(category)
        anime_name = self._series_name(entry, category['title'] or item['title'])

        if mode == 'all':
            # 跟動畫瘋的「加入下載」一樣是追番: 寫進清單, 之後出的新集數也會自己下載
            subscribe_anime(self._list_path, entry['url'], anime_name)
            entry = dict(entry, mode='all')
            threading.Thread(target=self._schedule_entry, args=(entry, context), daemon=True).start()
            return {'success': True, 'message': f'已將《{anime_name}》加入 {LIST_FILENAME}，正在排入下載'}

        wanted = set(str(episode_id) for episode_id in episodes or [])
        targets = [episode for episode in category['episodes'] if episode['id'] in wanted]
        if not targets:
            return {'success': False, 'message': '找不到指定的集數'}
        for episode in targets:
            threading.Thread(
                target=self._download_post,
                args=(entry, anime_name, episode, context),
                daemon=True,
            ).start()
        return {'success': True, 'scheduled': len(targets), 'message': f'已排入 {len(targets)} 集'}

    def get_commands(self):
        return [
            {'name': 'anime1me-check', 'description': '立即檢查 anime1.me anime_list.txt'},
        ]

    def run_command(self, command_name, args=None, context=None):
        if command_name != 'anime1me-check':
            return None
        result = self.on_auto_update(context or {})
        return {
            'success': True,
            'message': f"anime1.me 已排入 {result.get('scheduled', 0)} 個任務",
        }


def create_plugin(settings):
    return Anime1MePlugin(settings)


def main(url, gen_agpp_flag):
    session = requests.Session()
    session.headers.update(DOWNLOAD_HEADERS)
    title, videos = get_info(url, session)
    if not videos:
        raise RuntimeError('No downloadable videos found')

    anime_name = title
    series_dir = os.path.join(os.getcwd(), legalize_filename(anime_name))
    os.makedirs(series_dir, exist_ok=True)

    downloaded = []
    for video in sorted(videos, key=lambda item: episode_sort_key(item['episode_label'])):
        filename = legalize_filename(video['name']) + '.mp4'
        output_path = os.path.join(series_dir, filename)
        download_anime(video, output_path, session)
        downloaded.append({
            'episode_label': video['episode_label'],
            'filename': filename,
            'resolution': probe_video_height(output_path),
        })

    if gen_agpp_flag:
        write_agpp_metadata(series_dir, anime_name, downloaded, source='Anime1.me')


if __name__ == '__main__':
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print('Usage:', sys.argv[0], '[anime1.me category URL] [gen agpp true|false]')
        sys.exit(1)

    target_url = sys.argv[1]
    if 'https://anime1.me/' not in target_url and 'https://anime1.pw/' not in target_url:
        print('Invalid URL.')
        sys.exit(1)

    should_generate = len(sys.argv) == 3 and sys.argv[2].lower() == 'true'
    main(target_url, should_generate)
