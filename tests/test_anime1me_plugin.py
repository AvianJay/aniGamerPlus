# -*- coding: utf-8 -*-
"""anime1.me 插件: 線上片庫的來源, 以及它跟追番清單、state 檔之間的契約.

全部離線: 片單跟分類頁都是這裡寫死的 HTML/JSON, 下載執行緒換成同步呼叫.
"""

import json
import os
import sys

import pytest
from bs4 import BeautifulSoup

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from plugins import anime1me  # noqa: E402


CATEGORY_URL = 'https://anime1.me/category/2026%e5%b9%b4%e6%98%a5%e5%ad%a3/re0/'
TITLE = 'Re:從零開始的異世界生活 第四季'


def episode(post_id, label):
    return {
        'id': post_id,
        'name': '%s [%s]' % (TITLE, label),
        'label': label,
        'url': 'https://anime1.me/' + post_id,
        'date': '',
    }


CATEGORY = {
    'title': TITLE,
    'url': CATEGORY_URL,
    'episodes': [episode('30100', '01'), episode('30259', '02'), episode('30300', 'OVA')],
}
CATALOG = [{'animeSn': '1878', 'title': TITLE, 'cover': '', 'info': '2026 春',
            'volume': '連載中(2)', 'popular': '', 'subtitle': '喵萌奶茶屋'}]


class SyncThread:
    """下載都是丟執行緒跑的; 測試裡當場跑完, 才看得到它做了什麼."""

    def __init__(self, target, args=(), daemon=None, name=None):
        self._target = target
        self._args = args

    def start(self):
        self._target(*self._args)


@pytest.fixture
def plugin(tmp_path, monkeypatch):
    settings = {'working_dir': str(tmp_path), 'bangumi_dir': str(tmp_path / 'bangumi'),
                'classify_bangumi': True}
    instance = anime1me.Anime1MePlugin(settings)
    # state 檔原本放在插件旁邊, 測試不能寫到 repo 裡那一份
    instance._plugin_dir = str(tmp_path)
    instance._state_path = str(tmp_path / 'state.json')
    monkeypatch.setattr(anime1me, 'load_catalog', lambda: CATALOG)
    monkeypatch.setattr(anime1me, 'load_category', lambda cat_id: CATEGORY)
    monkeypatch.setattr(anime1me.threading, 'Thread', SyncThread)
    return instance


def make_plugin_like(instance):
    other = anime1me.Anime1MePlugin(instance._settings)
    other._plugin_dir = instance._plugin_dir
    other._state_path = instance._state_path
    return other


# ------------------------------------------------------------ parsing

def test_parse_animelist_skips_offsite_rows_and_formats_the_season():
    payload = [
        [1878, 'Re:從零開始的異世界生活 第四季', '連載中(19)', '2026', '春', ''],
        [1956, 'Let&#8217;s Go 怪奇組', '1-12', '2026', '夏', '桜都'],
        [0, '<a href="https://anime1.pw/?cat=62">站外的</a>', '1-12', '2026', '夏', '桜都'],
        [1700, '跨季作品', '1-24', '2026', '2025冬/2025夏/2026春', ''],
        [1878, '重複的一列', '', '', '', ''],
        [1500, '沒有字幕組', '-', '2020', '冬', '-'],
        'garbage',
    ]
    items = anime1me.parse_animelist(payload)
    assert [item['animeSn'] for item in items] == ['1878', '1956', '1700', '1500']
    assert items[0]['info'] == '2026 春' and items[0]['volume'] == '連載中(19)'
    assert items[1]['title'] == 'Let’s Go 怪奇組' and items[1]['subtitle'] == '桜都'
    assert items[2]['info'] == '2025冬/2025夏/2026春'
    # 站上用 - 表示「沒有」, 不能變成作品資訊上一顆寫著 - 的標籤
    assert (items[3]['volume'], items[3]['subtitle']) == ('', '')


CATEGORY_PAGE = '''
<h1 class="page-title">Re:從零開始的異世界生活 第四季</h1>
<article id="post-30259"><h2 class="entry-title"><a href="https://anime1.me/30259">Re [19]</a></h2>
  <time datetime="2026-09-30T22:17:07+08:00"></time><video data-apireq="x"></video></article>
<article id="post-30220"><h2 class="entry-title"><a href="https://anime1.me/30220">Re [18]</a></h2>
  <button data-src="https://p2p.example/embed"></button></article>
<article id="post-1"><h2 class="entry-title"><a href="https://anime1.me/1">公告</a></h2><p>沒有影片</p></article>
<article id="post-2"><h2 class="entry-title"><a href="https://evil.example/2">站外</a></h2><video></video></article>
<div class="nav-previous"><a href="https://anime1.me/category/re0/page/2">上一頁</a></div>
'''


def test_parse_category_page_lists_only_playable_on_site_episodes():
    title, episodes, prev_url = anime1me.parse_category_page(CATEGORY_PAGE)
    assert title == 'Re:從零開始的異世界生活 第四季'
    assert [(e['id'], e['label'], e['date']) for e in episodes] == [
        ('30259', '19', '2026-09-30'), ('30220', '18', '')]
    assert prev_url == 'https://anime1.me/category/re0/page/2'


def test_parse_category_page_does_not_follow_offsite_pagination():
    html = '<div class="nav-previous"><a href="https://evil.example/page/2">上一頁</a></div>'
    assert anime1me.parse_category_page(html)[2] == ''


def test_parse_article_on_a_single_episode_page_uses_the_given_title():
    # 單集頁的標題不是連結, 以前會解析成 Unknown、網址是空的, 存進 state 的鍵也就是空的
    article = BeautifulSoup('<article id="post-30259"><h2 class="entry-title">Re [19]</h2>'
                            '<video data-apireq="abc"></video></article>', 'html.parser').article
    video = anime1me.parse_article(article, None, title='Re [19]', page_url='https://anime1.me/30259')
    assert video['name'] == 'Re [19]' and video['page_url'] == 'https://anime1.me/30259'
    assert video['episode_label'] == '19'
    assert (video['method'], video['data']) == ('apireq', 'abc')


# ------------------------------------------------------------ anime list

def test_subscribe_appends_outside_the_last_tag_group(tmp_path):
    list_path = str(tmp_path / 'anime1me_list.txt')
    with open(list_path, 'w', encoding='utf-8') as f:
        f.write('@追番\nhttps://anime1.me/category/other/ latest\n')
    assert anime1me.subscribe_anime(list_path, CATEGORY_URL, TITLE) == 'added'
    entries = anime1me.read_anime_list(list_path)
    assert [(e['tag'], e['mode']) for e in entries] == [('追番', 'latest'), ('', 'all')]
    assert anime1me.url_identity(entries[1]['url']) == anime1me.url_identity(CATEGORY_URL)


def test_subscribe_upgrades_an_existing_line_in_place(tmp_path):
    # 清單上是瀏覽器複製來的中文網址, 片單給的是百分比編碼的 —— 要認得是同一部
    list_path = str(tmp_path / 'anime1me_list.txt')
    with open(list_path, 'w', encoding='utf-8') as f:
        f.write('https://anime1.me/category/2026年春季/re0 latest <Re0 S4> # 我的註解\n')
    assert anime1me.subscribe_anime(list_path, CATEGORY_URL) == 'updated'
    with open(list_path, encoding='utf-8') as f:
        assert f.read() == 'https://anime1.me/category/2026年春季/re0 all <Re0 S4> # 我的註解\n'
    assert anime1me.subscribe_anime(list_path, CATEGORY_URL) == 'exists'


# ------------------------------------------------------------ state

def test_two_plugin_instances_do_not_erase_each_others_downloads(plugin):
    # Dashboard 跟主程式各有一個實例. 各拿各的記憶體副本寫回去時, 後寫的會把
    # 先寫的那一集洗掉, 下一輪檢查更新就又下載一次
    other = make_plugin_like(plugin)

    def record(page_url):
        def mutate(state):
            state['entries'].setdefault('k', {'downloaded': {}})['downloaded'][page_url] = {}
        return mutate

    plugin._update_state(record('https://anime1.me/1'))
    other._update_state(record('https://anime1.me/2'))
    with open(plugin._state_path, encoding='utf-8') as f:
        downloaded = json.load(f)['entries']['k']['downloaded']
    assert set(downloaded) == {'https://anime1.me/1', 'https://anime1.me/2'}


# ------------------------------------------------------------ catalog hooks

def test_catalog_hooks_ignore_other_providers(plugin):
    assert plugin.catalog_providers() == [{'id': 'anime1', 'name': 'Anime1.me', 'features': {
        'tags': False, 'download': True, 'subscribe': True}}]
    assert plugin.catalog_items('bahamut') is None
    assert plugin.catalog_anime('bahamut', '1878') is None
    assert plugin.catalog_download('bahamut', '1878', [], 'all', {}) is None
    assert plugin.catalog_items('anime1') == CATALOG


def test_catalog_anime_groups_episodes_and_reports_their_files(plugin, tmp_path):
    recorded = str(tmp_path / 'elsewhere' / 'ep1.mp4')
    plugin._update_state(lambda state: state['entries'].setdefault('k', {})
                         .setdefault('downloaded', {}).update(
                             {'https://anime1.me/30100': {'path': recorded}}))

    detail = plugin.catalog_anime('anime1', '1878')
    assert detail['title'] == TITLE and detail['sourceUrl'] == CATEGORY_URL
    assert (detail['seasonStart'], detail['publisher'], detail['totalEpisode']) == (
        '2026 春', '喵萌奶茶屋', '3')
    regular, special = detail['groups']
    assert regular['name'] == '本篇' and [e['episode'] for e in regular['episodes']] == ['1', '2']
    assert special['name'] == '特別篇' and special['episodes'][0]['id'] == '30300'
    # 下載過的集數給 state 裡記的位置, 沒下載的給它會被存到的位置
    assert regular['episodes'][0]['path'] == recorded
    series_dir = os.path.join(str(tmp_path / 'bangumi'), anime1me.legalize_filename(TITLE))
    assert regular['episodes'][1]['path'] == os.path.join(
        series_dir, anime1me.legalize_filename(TITLE + ' [02]') + '.mp4')


def test_catalog_anime_follows_the_users_rename_and_tag(plugin, tmp_path):
    # 清單上已經追了這部 (自訂名稱、分類): 片單下載的集數要落在同一個資料夾
    with open(plugin._list_path, 'w', encoding='utf-8') as f:
        f.write('@新番\nhttps://anime1.me/category/2026年春季/re0/ latest <Re0 S4>\n')
    path = plugin.catalog_anime('anime1', '1878')['groups'][0]['episodes'][0]['path']
    assert os.path.dirname(path) == os.path.join(str(tmp_path / 'bangumi'), '新番', 'Re0 S4')


def test_catalog_anime_unknown_title_is_none(plugin):
    assert plugin.catalog_anime('anime1', '9999') is None


def test_catalog_download_single_fetches_only_the_chosen_episodes(plugin, monkeypatch):
    fetched = []
    monkeypatch.setattr(plugin, '_download_post',
                        lambda entry, name, ep, context: fetched.append((entry['url'], name, ep['id'])))
    result = plugin.catalog_download('anime1', '1878', ['30259', 'not-there'], 'single', {})
    assert result == {'success': True, 'scheduled': 1, 'message': '已排入 1 集'}
    assert fetched == [(CATEGORY_URL, TITLE, '30259')]
    assert plugin.catalog_download('anime1', '1878', ['nope'], 'single', {})['success'] is False
    assert plugin.catalog_download('anime1', '9999', ['30259'], 'single', {})['success'] is False


def test_catalog_download_all_subscribes_and_schedules_the_series(plugin, monkeypatch):
    scheduled = []
    monkeypatch.setattr(plugin, '_schedule_entry',
                        lambda entry, context: scheduled.append(entry) or 3)
    result = plugin.catalog_download('anime1', '1878', [], 'all', {'updatelist': None})
    assert result['success'] is True
    assert [(e['url'], e['mode']) for e in scheduled] == [(CATEGORY_URL, 'all')]
    # 跟動畫瘋的「加入下載」一樣是追番: 之後的新集數也要自己下載
    entries = anime1me.read_anime_list(plugin._list_path)
    assert [(e['url'], e['mode']) for e in entries] == [(CATEGORY_URL, 'all')]


def test_download_post_reads_a_fresh_signature_from_the_episode_page(plugin, monkeypatch):
    class Page:
        text = ('<article id="post-30259"><h2 class="entry-title">%s [02]</h2>'
                '<video data-apireq="fresh"></video></article>' % TITLE)

        def raise_for_status(self):
            pass

    monkeypatch.setattr(anime1me.requests, 'get', lambda url, **kwargs: Page())
    downloaded = []
    monkeypatch.setattr(plugin, '_download_episode',
                        lambda entry, name, video, context: downloaded.append(video))
    plugin._download_post({'url': CATEGORY_URL}, TITLE, episode('30259', '02'), {})
    assert downloaded[0]['data'] == 'fresh'
    assert downloaded[0]['page_url'] == 'https://anime1.me/30259'
