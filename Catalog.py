# coding: utf-8
"""巴哈姆特動畫瘋的片單.

本地片库里只有下过的那几部, 这个模块负责把站上的全部作品拿回来: 首页的分区
(本季新番/更新时间表/热播/最新上架) 走 app 用的 index.php, "所有动画" 走
animeList.php 一页页爬.

这里只做抓取和解析, 不碰缓存也不碰 gevent —— 上游请求由调用方传进来的 get()
发出, 因为 Dashboard 里必须走 Server._bahamut_get 把 libcurl 丢进线程池, 而
命令行下直接用 Config.bahamut_request 就行. 解析出了问题也能脱开服务器单测.
"""

import re

INDEX_API = 'https://api.gamer.com.tw/mobile_app/anime/v3/index.php'
LIST_URL = 'https://ani.gamer.com.tw/animeList.php'
REF_URL = 'https://ani.gamer.com.tw/animeRef.php?sn='

# 一张卡片从这里开始, 用它切开整页比写一条跨卡片的大正则稳: 某个字段缺了
# 只会让那一张卡片少一项, 不会让 .*? 一路吃到下一张卡片上去
_CARD_SPLIT = re.compile(r"<a href='animeRef\.php\?sn=(\d+)'")
_COVER = re.compile(r"data-src='([^']+)'")
_ALT = re.compile(r"alt='([^']*)'")
_ACG = re.compile(r'toggleGather\((\d+)')
_NAME = re.compile(r"<p class='theme-name'>([^<]*)</p>")
_TIME = re.compile(r"<p class='theme-time'>([^<]*)</p>")
_NUMBER = re.compile(r"<span class='theme-number'>\s*([^<]*?)\s*</span>")
_VIEWS = re.compile(r"<div class='show-view-number'>.*?<p>([^<]*)</p>", re.S)
_PAGE_NO = re.compile(r"\?page=(\d+)")


def _first(pattern, text, default=''):
    found = pattern.search(text)
    return found.group(1).strip() if found else default


def parse_list_page(html):
    """animeList.php 的一页, 28 张卡片."""
    chunks = _CARD_SPLIT.split(html)
    items = []
    # split 出来是 [页头, sn, 卡片, sn, 卡片, ...], 所以成对地走
    for i in range(1, len(chunks) - 1, 2):
        anime_sn = chunks[i]
        body = chunks[i + 1]
        title = _first(_NAME, body) or _first(_ALT, body)
        if not title:
            continue
        items.append({
            'animeSn': anime_sn,
            'acgSn': _first(_ACG, body),
            'title': title,
            'cover': _first(_COVER, body),
            'info': _first(_TIME, body),
            'volume': _first(_NUMBER, body),
            'popular': _first(_VIEWS, body),
        })
    return items


def total_pages(html):
    """页码条上最大的那个数字. 抓不到就当只有一页, 宁可少爬也别空转."""
    pages = [int(m) for m in _PAGE_NO.findall(html)]
    return max(pages) if pages else 1


def list_page_url(page):
    return LIST_URL + '?page=' + str(int(page)) + '&c=0&sort=1'


WEEKDAYS = ('週一', '週二', '週三', '週四', '週五', '週六', '週日')


def views(raw):
    """卡片上的人氣. app api 给的是原始数字, animeList.php 给的已经是 "65萬",
    统一成后者, 免得同一排卡片两种写法."""
    text = str(raw or '').strip()
    if not text.isdigit():
        return text
    number = int(text)
    if number < 10000:
        return str(number)
    return ('%.1f' % (number / 10000.0)).rstrip('0').rstrip('.') + '萬'


def _card(raw):
    # index.php 的三个分区字段不完全一样, 缺的就留空, 前端按有没有决定画不画
    info = raw.get('info') or ''
    if not info and raw.get('upTime'):
        info = '更新：' + raw['upTime']
    return {
        'animeSn': str(raw.get('animeSn') or ''),
        'acgSn': str(raw.get('acgSn') or ''),
        'videoSn': str(raw.get('videoSn') or ''),
        'title': raw.get('title') or '',
        'cover': raw.get('cover') or '',
        'info': info,
        'volume': '',
        'popular': views(raw.get('popular')),
    }


def _section(payload, *names):
    # newAnime 有时是列表, 有时是 {date: [...], popular: [...]}
    node = payload
    for name in names:
        if not isinstance(node, dict):
            return []
        node = node.get(name)
    if isinstance(node, dict):
        node = node.get('date') or node.get('popular') or []
    return [_card(item) for item in node or [] if isinstance(item, dict)]


def parse_index(payload):
    """app 首页那一坨: 本季新番 / 更新時間表 / 近期熱播 / 最新上架."""
    data = (payload or {}).get('data') or {}
    season = _section(data, 'newAnime')

    # 时间表只给 videoSn, 点进去要的却是作品的 animeSn. 表上排的就是这一季在播
    # 的番, 本季新番那份正好每部都带着 animeSn, 按片名对一下就补齐了 —— 比为
    # 每一行多跑一趟 animeRef.php 省得多
    by_title = {}
    for item in season:
        if item['title'] and item['animeSn']:
            by_title.setdefault(item['title'], item)

    schedule = []
    raw_schedule = data.get('newAnimeSchedule') or {}
    for index, label in enumerate(WEEKDAYS, start=1):
        episodes = raw_schedule.get(str(index)) or []
        rows = []
        for ep in episodes:
            if not isinstance(ep, dict):
                continue
            title = ep.get('title') or ''
            known = by_title.get(title) or {}
            rows.append({
                'videoSn': str(ep.get('videoSn') or ''),
                'animeSn': known.get('animeSn', ''),
                'cover': known.get('cover', ''),
                'title': title,
                'time': ep.get('scheduleTime') or '',
                'volume': ep.get('volumeString') or '',
            })
        schedule.append({'weekday': index, 'label': label, 'episodes': rows})

    return {
        'season': season,
        'schedule': schedule,
        'hot': _section(data, 'hotAnime'),
        'newAdded': _section(data, 'newAdded'),
    }


def parse_video_sn(location):
    """animeRef.php 的 301 目标里那个 sn, 就是这部作品第一集的 videoSn."""
    found = re.search(r'sn=(\d+)', location or '')
    return found.group(1) if found else ''


# 官方集数表按类型分组, 键就是这几个数字
EPISODE_TYPES = {'0': '本篇', '1': '電影', '2': '特別篇', '3': '中文配音'}

_TAG = re.compile(r'<[^>]+>')
_BREAK = re.compile(r'<\s*br\s*/?\s*>', re.I)
_EPISODE_SUFFIX = re.compile(r'\s*\[[^\]]*\]\s*$')


def plain_text(html):
    """简介官方只给 contentHtml. 前端不该拿到带标签的字符串 —— 真要原样塞进
    DOM 就等于把巴哈的内容当自己的模板, 所以在这里就剥干净."""
    if not html:
        return ''
    text = _BREAK.sub('\n', str(html))
    text = _TAG.sub('', text)
    text = text.replace('&nbsp;', ' ').replace('&amp;', '&')
    text = text.replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"')
    return '\n'.join(line.strip() for line in text.split('\n')).strip()


def series_title(title):
    """anime.title 带着集数后缀 (名偵探柯南 [1]), 作品名要去掉它."""
    return _EPISODE_SUFFIX.sub('', str(title or '')).strip()
