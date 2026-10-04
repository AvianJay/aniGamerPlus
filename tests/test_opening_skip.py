import Catalog
import OpeningSkip


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
