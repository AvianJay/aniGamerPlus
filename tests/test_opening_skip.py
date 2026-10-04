import Catalog
import OpeningSkip
import json
from pathlib import Path
import pytest


class Response:
    def __init__(self, payload, status=200):
        self.payload = payload
        self.status_code = status

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError('HTTP error')

    def json(self):
        return self.payload


class Session:
    def __init__(self, subjects):
        self.subjects = subjects

    def post(self, url, **kwargs):
        if 'bgm.tv' in url:
            return Response({'data': self.subjects})
        return Response({'data': {'Page': {'media': [
            {'idMal': 16498, 'title': {'native': '進撃の巨人'},
             'startDate': {'year': 2013}},
        ]}}})

    def get(self, url, **kwargs):
        return Response({'found': True, 'results': [
            {'skipType': 'op', 'interval': {'startTime': 128.4, 'endTime': 218.4},
             'episodeLength': 1441},
            {'skipType': 'ed', 'interval': {'startTime': 1300, 'endTime': 1430},
             'episodeLength': 1441},
        ]})


def test_tag_url_and_popularity():
    assert 'tags=%E7%95%B0%E4%B8%96%E7%95%8C' in Catalog.list_page_url(2, '異世界')
    assert Catalog.popularity('142.8萬') > Catalog.popularity('9000')
    assert Catalog.popularity('1.2億') > Catalog.popularity('142.8萬')


def test_mal_mapping_and_op_bounds():
    session = Session([{'name': '進撃の巨人', 'name_cn': '进击的巨人',
                        'date': '2013-04-06'}])
    assert OpeningSkip.resolve_mal_id('進擊的巨人', '2013/04/07',
                                      session=session) == 16498
    assert OpeningSkip.resolve_mal_id('進擊的巨人', '2020/04/07',
                                      session=session) is None
    assert OpeningSkip.aniskip_op(16498, 1, 1440, session=session) == (128.4, 218.4)
    assert OpeningSkip.aniskip_op(16498, 1, 300, session=session) is None


def test_bocchi_search_simplifies_the_bangumi_keyword():
    class BocchiSession:
        def post(self, url, **kwargs):
            if 'bgm.tv' in url:
                if kwargs['json']['keyword'] != '孤独摇滚！':
                    return Response({'data': [{'name': 'Invisible Loneliness',
                                             'name_cn': '透明的孤独'}]})
                return Response({'data': [{'name': 'ぼっち・ざ・ろっく！',
                    'name_cn': '孤独摇滚！', 'date': '2022-10-08'}]})
            return Response({'data': {'Page': {'media': [{
                'idMal': 47917, 'title': {'native': 'ぼっち・ざ・ろっく！'},
                'startDate': {'year': 2022},
            }]}}})
    assert OpeningSkip.resolve_mal_id('孤獨搖滾！', '2022/10/09',
                                    session=BocchiSession()) == 47917


class BackupSession:
    def __init__(self, *, anilist_down=False, aniskip_status=404, anime_skip=None):
        self.anilist_down = anilist_down
        self.aniskip_status = aniskip_status
        self.anime_skip = anime_skip or json.loads(
            (Path(__file__).parent / 'fixtures/bocchi_anime_skip.json').read_text(encoding='utf-8'))
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append(url)
        if 'bgm.tv' in url:
            return Response({'data': [{'name': 'ぼっち・ざ・ろっく！',
                'name_cn': '孤独摇滚！', 'date': '2022-10-08'}]})
        if 'anilist.co' in url:
            return Response({'data': {'Page': {'media': [{
                'id': 130003, 'idMal': 47917, 'episodes': 12,
                'title': {'native': 'ぼっち・ざ・ろっく！', 'english': 'Bocchi the Rock!'},
                'startDate': {'year': 2022}}]}}}, 503 if self.anilist_down else 200)
        assert 'anime-skip.com' in url
        assert kwargs['headers']['X-Client-ID']
        assert kwargs['json']['variables'] == ({'search': 'Bocchi the Rock!'}
            if self.anilist_down else {'id': '130003'})
        return Response(self.anime_skip)

    def get(self, url, **kwargs):
        self.calls.append(url)
        if 'jikan.moe' in url:
            assert kwargs['params']['q'] == 'ぼっち・ざ・ろっく！'
            return Response({'data': [{'mal_id': 47917, 'episodes': 12,
                'title_japanese': 'ぼっち・ざ・ろっく！', 'title_english': 'Bocchi the Rock!',
                'aired': {'from': '2022-10-09T00:00:00+00:00'}}]})
        assert 'api.aniskip.com' in url
        return Response({'found': True, 'results': [{'skipType': 'op', 'episodeLength': 1420,
            'interval': {'startTime': 115.96, 'endTime': 205.96}}]}, self.aniskip_status)


def test_jikan_and_anime_skip_can_rescue_both_provider_failures():
    session = BackupSession(anilist_down=True, aniskip_status=503)
    series = OpeningSkip.resolve_series('孤獨搖滾！', '2022/10/09', session=session)
    assert series['malId'] == 47917
    assert OpeningSkip.opening_op(series, 3, 1420, session=session) == {
        'interval': [220.823737, 311.37238], 'source': 'AnimeSkip'}


def test_aniskip_keeps_priority_without_extra_requests():
    session = BackupSession(aniskip_status=200)
    series = OpeningSkip.resolve_series('孤獨搖滾！', '2022/10/09', session=session)
    assert OpeningSkip.opening_op(series, 1, 1420, session=session)['source'] == 'AniSkip'
    assert not any('jikan.moe' in url or 'anime-skip.com' in url for url in session.calls)


@pytest.mark.parametrize('episode,interval', [
    (3, [220.823737, 311.37238]), (4, [104.743621, 195.440381]),
    (10, [146.930299, 237.500372]), (8, None), (12, None)])
def test_anime_skip_recorded_bocchi_timestamps(episode, interval):
    session = BackupSession()
    series = OpeningSkip.resolve_series('孤獨搖滾！', '2022/10/09', session=session)
    result = OpeningSkip.opening_op(series, episode, 1420, session=session)
    assert (result['interval'] if result else None) == interval


@pytest.mark.parametrize('scenario', ['conflict', 'season', 'cut', 'mixed'])
def test_anime_skip_rejects_unsafe_matches(scenario):
    session = BackupSession()
    rows = session.anime_skip['data']['shows'][0]['episodes']
    if scenario == 'conflict':
        next(row for row in rows if row['number'] == '3')['timestamps'][2]['at'] = 400
    elif scenario == 'season':
        rows[0]['season'] = '2'
    elif scenario == 'mixed':
        for row in rows:
            if row['number'] == '3':
                for stamp in row['timestamps']:
                    if stamp['type']['name'] == 'Intro':
                        stamp['type']['name'] = 'Mixed Intro'
    series = OpeningSkip.resolve_series('孤獨搖滾！', '2022/10/09', session=session)
    assert OpeningSkip.opening_op(series, 3, 1440 if scenario == 'cut' else 1420,
                                  session=session) is None
