"""Slow upstream work must not hold catalogue requests; WebP is a real conversion."""
import asyncio
import io
import os
from pathlib import Path
import threading
import types

import pytest
from PIL import Image

import Dashboard.Server as server
from Dashboard import thumbnail_cache
from test_fastapi_server import settings, autouse_settings, client, userdata


@pytest.fixture
def catalog_env(monkeypatch, tmp_path, autouse_settings):
    monkeypatch.setattr(server.Config, 'get_working_dir', lambda: str(tmp_path))
    monkeypatch.setattr(server, '_catalog_refresh_jobs', set())
    monkeypatch.setattr(server, '_catalog_refresh_after', {})
    monkeypatch.setattr(server, 'err_print', lambda *a, **k: None)
    release = threading.Event()
    threads = []

    def startable(*args, **kwargs):
        thread = threading.Thread(*args, **kwargs)
        threads.append(thread)
        return thread

    monkeypatch.setattr(server, 'threading', types.SimpleNamespace(Thread=startable, Lock=threading.Lock))
    yield release
    release.set()
    for thread in threads:
        thread.join(timeout=5)
        assert not thread.is_alive()


def test_cold_catalog_returns_pending_and_starts_only_one_crawl(client, catalog_env, monkeypatch):
    entered = threading.Event()
    calls = []

    def crawl():
        calls.append(True)
        entered.set()
        assert catalog_env.wait(5)
        return {'items': [{'animeSn': '1', 'title': 'One'}], 'complete': True}

    monkeypatch.setattr(server, '_crawl_catalog_all', crawl)
    response = client.get('/catalog/all.json')
    assert entered.wait(2)
    assert response.status_code == 200
    assert response.json()['loading'] is True
    assert response.json()['items'] == []
    assert response.headers['Cache-Control'] == 'no-store'
    assert response.headers['Retry-After'] == '2'
    for _ in range(5):
        assert client.get('/catalog/all.json').json()['loading'] is True
    assert len(calls) == 1
    catalog_env.set()


def test_stale_catalog_is_served_while_refresh_runs(client, catalog_env, monkeypatch):
    server._write_catalog_cache('all', {'items': [{'animeSn': '1', 'title': 'Old'}], 'complete': True})
    os.utime(server._catalog_cache_path('all'), (1, 1))
    def crawl():
        assert catalog_env.wait(5)
        return {'items': [{'animeSn': '1', 'title': 'New'}], 'complete': True}

    monkeypatch.setattr(server, '_crawl_catalog_all', crawl)
    response = client.get('/catalog/all.json')
    assert response.json()['items'][0]['title'] == 'Old'
    assert response.json()['loading'] is True


def test_failed_crawl_has_cooldown_and_does_not_cache_an_empty_result(client, catalog_env, monkeypatch):
    calls = []

    def fail():
        calls.append(True)
        raise OSError('synthetic upstream failure')

    monkeypatch.setattr(server, '_crawl_catalog_all', fail)
    # Run the scheduled task synchronously to make its completion deterministic.
    monkeypatch.setattr(server, 'threading', types.SimpleNamespace(
        Thread=lambda target, **kw: types.SimpleNamespace(start=target), Lock=threading.Lock))
    first = client.get('/catalog/all.json')
    second = client.get('/catalog/all.json')
    assert first.json()['loading'] is False
    assert second.json()['retryAfter'] == 60
    assert second.headers['Cache-Control'] == 'no-store'
    assert len(calls) == 1


def test_stale_index_does_not_wait_for_upstream(client, catalog_env, monkeypatch):
    server._write_catalog_cache('index', {'season': [{'title': 'Cached'}]})
    os.utime(server._catalog_cache_path('index'), (1, 1))
    monkeypatch.setattr(server, '_refresh_catalog_index', lambda: catalog_env.wait(5))
    assert client.get('/catalog/index.json').json()['season'][0]['title'] == 'Cached'


def test_pending_catalog_detail_is_not_a_false_404(client, autouse_settings, monkeypatch):
    monkeypatch.setattr(server, '_catalog_knows', lambda sn: False)
    monkeypatch.setattr(server, '_catalog_refreshing', lambda name: True)
    response = client.get('/catalog/anime.json?sn=123')
    assert response.status_code == 202
    assert response.json() == {'loading': True, 'retryAfter': 2}
    assert response.headers['Cache-Control'] == 'no-store'


def test_failed_catalog_publish_preserves_previous_cache(catalog_env, monkeypatch):
    original = {'items': [{'animeSn': '1', 'title': 'Original'}], 'complete': True}
    server._write_catalog_cache('all', original)

    def fail(*args):
        raise OSError('synthetic disk failure')

    monkeypatch.setattr(server, '_replace_with_retry', fail)
    server._write_catalog_cache('all', {'items': []})
    assert server._read_catalog_cache('all', 0) == original
    assert not list(Path(server._catalog_cache_path('all')).parent.glob('*.tmp'))


def jpeg(path, color='navy'):
    Image.new('RGB', (120, 80), color).save(path, 'JPEG')


def test_jpeg_cache_migration_converts_deletes_and_can_be_rerun(tmp_path):
    jpeg(tmp_path / '123.jpg')
    jpeg(tmp_path / '456.jpeg')
    (tmp_path / '789.jpg').write_bytes(b'corrupt image')
    jpeg(tmp_path / '123.tmp.jpg')
    result = thumbnail_cache.migrate_directory(tmp_path)
    assert result['converted'] == 2 and result['failed'] == 1
    for name in ('123', '456'):
        with Image.open(tmp_path / (name + '.webp')) as image:
            image.load()
            assert image.format == 'WEBP' and image.size == (120, 80)
    assert not (tmp_path / '123.jpg').exists()
    assert not (tmp_path / '456.jpeg').exists()
    assert (tmp_path / '789.jpg').read_bytes() == b'corrupt image'
    assert (tmp_path / '123.tmp.jpg').exists()
    assert thumbnail_cache.migrate_directory(tmp_path)['converted'] == 0
    assert not list(tmp_path.glob('.webp-*.tmp'))


def test_failed_publish_keeps_original_jpeg_and_cleans_temp(tmp_path, monkeypatch):
    source = tmp_path / '123.jpg'
    jpeg(source)
    original = source.read_bytes()

    def fail(*args):
        raise OSError('synthetic disk failure')

    monkeypatch.setattr(thumbnail_cache.os, 'replace', fail)
    assert thumbnail_cache.migrate_directory(tmp_path)['failed'] == 1
    assert source.read_bytes() == original
    assert not (tmp_path / '123.webp').exists()
    assert not list(tmp_path.glob('.webp-*.tmp'))


def test_webp_route_converts_existing_jpeg_without_fetching(client, autouse_settings, tmp_path, monkeypatch):
    source = tmp_path / '123.jpg'
    jpeg(source)
    monkeypatch.setattr(server, '_thumbnail_cache_path', lambda sn: str(tmp_path / (sn + '.webp')))
    monkeypatch.setattr(server, '_build_thumbnail', lambda *args: pytest.fail('Must reuse existing JPEG'))
    response = client.get('/thumbnail.webp?id=123')
    assert response.status_code == 200
    assert response.headers['content-type'] == 'image/webp'
    with Image.open(io.BytesIO(response.content)) as image:
        assert image.format == 'WEBP'
    assert not source.exists()
    assert client.get('/thumbnail.jpg?id=123').status_code == 404
    head = client.head('/thumbnail.webp?id=123')
    assert head.content == b'' and head.headers['content-type'] == 'image/webp'
    assert head.headers['content-length'] == str(len(response.content))
    assert client.get('/thumbnail.webp?id=123', headers={'If-None-Match': response.headers['etag']}).status_code == 304


def test_webp_route_checks_login_before_conversion(client, autouse_settings, settings, tmp_path, monkeypatch):
    settings['dashboard']['online_watch_requires_login'] = True
    jpeg(tmp_path / '123.jpg')
    monkeypatch.setattr(server, '_thumbnail_cache_path', lambda sn: str(tmp_path / (sn + '.webp')))
    assert client.get('/thumbnail.webp?id=123').status_code == 403
    assert (tmp_path / '123.jpg').exists()
    assert not (tmp_path / '123.webp').exists()


def test_downloaded_cover_is_encoded_as_webp(tmp_path, monkeypatch):
    source = tmp_path / 'upstream.jpg'
    jpeg(source)
    monkeypatch.setattr(server, '_get_anime_info', lambda sn: {'video': {'cover': 'https://example.test/cover.jpg'}})
    monkeypatch.setattr(server, '_bahamut_get', lambda *a, **k: types.SimpleNamespace(status_code=200, content=source.read_bytes()))
    destination = tmp_path / '123.webp'
    assert server._build_thumbnail('123', str(destination), {'source': server.BAHAMUT_SOURCE})
    with Image.open(destination) as image:
        assert image.format == 'WEBP'


def test_ffmpeg_generates_real_webp(tmp_path):
    if not server._get_ffmpeg_path():
        pytest.skip('ffmpeg unavailable')
    destination = tmp_path / 'frame.webp'
    video = Path(__file__).parent / 'fixtures' / 'sample.webm'
    assert server._make_thumbnail(str(video), str(destination))
    with Image.open(destination) as image:
        image.load()
        assert image.format == 'WEBP'


def test_startup_schedules_cache_migration(monkeypatch):
    entered = threading.Event()
    monkeypatch.setattr(server, '_migrate_thumbnails', entered.set)

    async def startup():
        async with server._lifespan(server.app):
            assert await asyncio.to_thread(entered.wait, 2)

    asyncio.run(startup())
