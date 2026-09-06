"""The 邊看邊下載 protocol, pinned without a browser or a running server.

``test_web_ui.py`` proves the player wiring and ``test_real_server_e2e.py``
proves it against a real download; this module proves the part in between --
the playlist that gets handed to hls.js. That is where the subtle mistakes live:
renumbering the media sequence silently breaks AES decryption, leaking the
ffmpeg-localised copy sends Windows paths to a browser, and trusting
``tasks_progress_rate`` instead of the directory serves segments that are not
there yet.

These call the helpers in ``Dashboard/Server.py`` directly, which is why they are
module-level functions rather than closures inside the routes.
"""

import io
import os

import pytest

import gevent.monkey
# Server.py monkey-patches gevent the moment it is imported. That rewrites the
# thread-identity functions importlib keys its module locks on, and doing it
# while pytest holds an import lock raises "cannot release un-acquired lock";
# gevent's own answer is to patch before the process imports anything, which a
# test module by definition cannot do. Nothing below runs on gevent -- Flask's
# test client is an ordinary synchronous call -- so the patch is skipped.
gevent.monkey.patch_all = lambda *args, **kwargs: None

import Dashboard.Server as server
from aniGamerPlus import Config


KEY_URI = 'https://i2.bahamut.com.tw/JUMP/ani.php?sn=48502&key=abc'
SN = '48502'


def remote_playlist(count=5, key_line=None, target=10):
    """What Anime.py writes to <temp>/<sn>.m3u8 before it downloads anything."""
    lines = ['#EXTM3U', '#EXT-X-VERSION:3',
             '#EXT-X-TARGETDURATION:%d' % target,
             '#EXT-X-MEDIA-SEQUENCE:0', '#EXT-X-PLAYLIST-TYPE:VOD',
             key_line or ('#EXT-X-KEY:METHOD=AES-128,URI="%s"' % KEY_URI)]
    for index in range(count):
        lines.append('#EXTINF:10.000,')
        lines.append('media_b1500000_%d.ts' % index)
    lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


def localised_playlist(temp_dir, count=5):
    """What Anime.py *overwrites* it with once every chunk has landed.

    Absolute Windows paths with doubled backslashes and the key pointing at the
    on-disk copy -- valid ffmpeg input, and nothing a browser can use.
    """
    base = temp_dir.replace('/', '\\').replace('\\', '\\\\')
    lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:10',
             '#EXT-X-MEDIA-SEQUENCE:0', '#EXT-X-PLAYLIST-TYPE:VOD',
             '#EXT-X-KEY:METHOD=AES-128,URI="%s\\\\key.m3u8key"' % base]
    for index in range(count):
        lines.append('#EXTINF:10.000,')
        lines.append('%s\\\\media_b1500000_%d.ts' % (base, index))
    lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


@pytest.fixture(autouse=True)
def clean_module_state():
    """Every test starts with no cached parse and no running task."""
    server._hls_playlist_cache.clear()
    Config.tasks_progress_rate.clear()
    yield
    server._hls_playlist_cache.clear()
    Config.tasks_progress_rate.clear()


@pytest.fixture
def temp_dir(tmp_path):
    """A download directory shaped exactly like Anime.py's."""
    path = tmp_path / (SN + server.HLS_TEMP_SUFFIX)
    path.mkdir()
    return path


def write_playlist(temp_dir, text):
    io.open(str(temp_dir / (SN + '.m3u8')), 'w', encoding='utf-8',
            newline='\n').write(text)


def write_chunks(temp_dir, indexes, size=2048):
    for index in indexes:
        with open(str(temp_dir / ('media_b1500000_%d.ts' % index)), 'wb') as f:
            f.write(b'\0' * size)


@pytest.fixture
def settings(tmp_path):
    """Only the keys the streaming code actually reads."""
    return {
        'temp_dir': str(tmp_path),
        'segment_download_mode': True,
        'dashboard': {'online_watch_requires_login': False},
    }


@pytest.fixture
def client(monkeypatch, settings):
    """Flask test client with the settings and the library both stubbed out.

    ``_hls_settings`` is replaced rather than the config file, so the tests never
    touch the operator's real config.json or their real temp directory.
    """
    monkeypatch.setattr(server, '_hls_settings', lambda: settings)
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    server.app.config['TESTING'] = True
    return server.app.test_client()


# ------------------------------------------------------------------- parsing

def test_parser_reads_durations_and_names_from_the_remote_playlist():
    parsed = server._hls_parse_playlist(remote_playlist(3))
    assert [s['name'] for s in parsed['segments']] == [
        'media_b1500000_0.ts', 'media_b1500000_1.ts', 'media_b1500000_2.ts']
    assert parsed['total_duration'] == pytest.approx(30.0)
    assert parsed['target_duration'] == 10
    assert KEY_URI in parsed['key_line']


def test_parser_refuses_the_localised_copy(temp_dir):
    """The ffmpeg-only form must never reach a browser.

    It carries absolute Windows paths; serving it would both break playback and
    tell every viewer where the library lives on disk.
    """
    assert server._hls_parse_playlist(localised_playlist(str(temp_dir))) is None


def test_parser_refuses_a_playlist_with_no_aes_key():
    text = remote_playlist(3).replace(
        '#EXT-X-KEY:METHOD=AES-128,URI="%s"' % KEY_URI, '')
    assert server._hls_parse_playlist(text) is None


def test_parser_gives_every_playlist_its_own_identity():
    """A retry can re-resolve to another resolution, which renames every chunk.

    The player watches this value so it rebuilds instead of splicing two
    different streams together.
    """
    first = server._hls_parse_playlist(remote_playlist(3))
    second = server._hls_parse_playlist(
        remote_playlist(3).replace('media_b1500000', 'media_b800000'))
    assert first['playlist_id'] != second['playlist_id']


# ----------------------------------------------------------------- rendering

def test_playlist_lists_only_the_contiguous_prefix(temp_dir):
    """Chunks finish out of order, so 4-on-disk does not mean 4-playable."""
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1, 2, 4])          # 3 is still in flight
    parsed = server._hls_playlist(SN, str(temp_dir))
    ready = server._hls_ready_count(str(temp_dir), parsed['segments'])
    assert ready == 3

    body = server._hls_render(SN, parsed, ready, False)
    assert body.count('#EXTINF') == 3
    assert 'segment.ts?id=%s&n=2' % SN in body
    assert 'n=3' not in body
    assert '#EXT-X-ENDLIST' not in body


def test_playlist_stops_at_a_zero_length_chunk(temp_dir):
    """Insurance against half-written files left by an older build."""
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1])
    write_chunks(temp_dir, [2], size=0)
    parsed = server._hls_playlist(SN, str(temp_dir))
    assert server._hls_ready_count(str(temp_dir), parsed['segments']) == 2


def test_playlist_keeps_media_sequence_at_zero(temp_dir):
    """Renumbering would break decryption silently.

    When #EXT-X-KEY carries no explicit IV, the AES IV *is* the segment's media
    sequence number. Shifting the sequence to match a trimmed window would make
    every segment decrypt to noise, with no error anywhere.
    """
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1, 2])
    parsed = server._hls_playlist(SN, str(temp_dir))
    body = server._hls_render(SN, parsed, 3, False)
    assert '#EXT-X-MEDIA-SEQUENCE:0' in body


def test_playlist_preserves_an_explicit_key_iv():
    """Only the URI is substituted, so an upstream IV= survives untouched."""
    key_line = ('#EXT-X-KEY:METHOD=AES-128,URI="%s",IV=0x0123456789abcdef'
                '0123456789abcdef' % KEY_URI)
    parsed = server._hls_parse_playlist(remote_playlist(2, key_line=key_line))
    body = server._hls_render(SN, parsed, 2, False)
    assert 'IV=0x0123456789abcdef0123456789abcdef' in body
    assert 'URI="key.bin?id=%s"' % SN in body
    assert KEY_URI not in body                    # upstream URL is not leaked


def test_playlist_starts_at_zero_not_the_live_edge():
    """Without ENDLIST hls.js treats the stream as live.

    Its default start position is then roughly three target durations from the
    end -- i.e. it would skip everything already downloaded. EXT-X-START pins it
    to the beginning, and native Apple playback honours the same tag.
    """
    parsed = server._hls_parse_playlist(remote_playlist(5))
    body = server._hls_render(SN, parsed, 3, False)
    assert '#EXT-X-START:TIME-OFFSET=0,PRECISE=YES' in body


def test_playlist_closes_with_endlist_when_every_chunk_is_present():
    parsed = server._hls_parse_playlist(remote_playlist(4))
    body = server._hls_render(SN, parsed, 4, True)
    assert body.rstrip().endswith('#EXT-X-ENDLIST')
    assert body.count('#EXTINF') == 4


def test_rendered_playlist_never_contains_a_local_path(temp_dir):
    write_playlist(temp_dir, remote_playlist(3))
    write_chunks(temp_dir, [0, 1, 2])
    parsed = server._hls_playlist(SN, str(temp_dir))
    body = server._hls_render(SN, parsed, 3, True)
    assert '\\' not in body
    assert 'key.m3u8key' not in body
    assert str(temp_dir) not in body


# ------------------------------------------------------------- parse caching

def test_parse_cache_outlives_localisation(temp_dir):
    """A viewer mid-episode must not be cut off when ffmpeg starts merging.

    The moment the last chunk lands, __segment_download_mode() overwrites the
    m3u8 with the localised form. The merge can take tens of seconds, and the
    whole episode is still sitting in temp and perfectly playable throughout.
    """
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1, 2, 3, 4])
    first = server._hls_playlist(SN, str(temp_dir))
    assert first is not None

    write_playlist(temp_dir, localised_playlist(str(temp_dir)))
    again = server._hls_playlist(SN, str(temp_dir))
    assert again is not None
    assert again['playlist_id'] == first['playlist_id']


def test_parse_cache_notices_a_redownloaded_playlist(temp_dir):
    write_playlist(temp_dir, remote_playlist(5))
    first = server._hls_playlist(SN, str(temp_dir))
    write_playlist(temp_dir, remote_playlist(5).replace(
        'media_b1500000', 'media_b800000'))
    second = server._hls_playlist(SN, str(temp_dir))
    assert second['playlist_id'] != first['playlist_id']
    assert second['segments'][0]['name'] == 'media_b800000_0.ts'


def test_ready_count_survives_the_temp_dir_vanishing(temp_dir):
    """shutil.rmtree runs the instant the merge finishes."""
    write_playlist(temp_dir, remote_playlist(3))
    write_chunks(temp_dir, [0, 1, 2])
    parsed = server._hls_playlist(SN, str(temp_dir))
    import shutil
    shutil.rmtree(str(temp_dir))
    assert server._hls_ready_count(str(temp_dir), parsed['segments']) == 0


# --------------------------------------------------------------- state logic

def test_status_reports_the_resolution_from_the_task_filename():
    """Anime.py only knows the real resolution after it has resolved the m3u8.

    Before that the progress entry's filename is just '《title》', and reporting 0
    is the honest answer -- lock_resolution is off by default, so the downloader
    may yet substitute the closest available one.
    """
    assert server._hls_resolution_from_filename('《Re：從零開始的異世界生活》') == 0
    assert server._hls_resolution_from_filename('Re [1][1080P].mp4') == 1080
    assert server._hls_resolution_from_filename(None) == 0


def test_orphaned_temp_dir_without_a_progress_entry_is_not_served(temp_dir, settings, monkeypatch):
    """A failed download leaves the directory behind. That is not a stream."""
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1, 2])
    state = server._hls_state(SN, settings)
    assert state['mode'] == 'none'


def test_streaming_is_off_when_segment_download_mode_is_off(temp_dir, settings, monkeypatch):
    """__ffmpeg_download_mode writes one growing mp4 and no chunks at all."""
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    settings['segment_download_mode'] = False
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 10.0, 'filename': '《x》', 'status': '正在下載'}
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1])
    assert server._hls_state(SN, settings)['mode'] == 'none'


def test_state_walks_from_parsing_to_streaming_to_finalising(temp_dir, settings, monkeypatch):
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: None)
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 0.0, 'filename': '《x》', 'status': '正在解析'}

    # m3u8 not written yet
    assert server._hls_state(SN, settings)['mode'] == 'parsing'

    # written, but nothing has landed
    write_playlist(temp_dir, remote_playlist(4))
    assert server._hls_state(SN, settings)['mode'] == 'parsing'

    write_chunks(temp_dir, [0, 1])
    state = server._hls_state(SN, settings)
    assert state['mode'] == 'streaming'
    assert state['ready'] == 2 and state['total'] == 4
    assert state['readyDuration'] == pytest.approx(20.0)
    assert state['totalDuration'] == pytest.approx(40.0)

    write_chunks(temp_dir, [2, 3])
    assert server._hls_state(SN, settings)['mode'] == 'finalising'


def test_state_hands_off_once_the_episode_is_in_the_library(settings, monkeypatch):
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: {
        'sn': SN, 'resolution': 1080, 'danmu': True, 'path': 'x.mp4'})
    state = server._hls_state(SN, settings)
    assert state['mode'] == 'file'
    assert state['videoUrl'] == './get_video.mp4?id=%s&res=1080' % SN
    assert state['danmu'] is True


# -------------------------------------------------------------------- routes

def test_status_route_answers_200_even_when_nothing_is_downloading(client):
    """The player has to tell "not downloading" apart from "server broken"."""
    response = client.get('/hls/status.json?id=' + SN)
    assert response.status_code == 200
    assert response.get_json()['mode'] == 'none'
    assert response.headers['Cache-Control'] == 'no-store'


def test_status_route_never_leaks_the_temp_path(client, temp_dir):
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 5.0, 'filename': '《x》', 'status': '正在下載'}
    payload = client.get('/hls/status.json?id=' + SN).get_json()
    assert 'temp_dir' not in payload
    assert 'parsed' not in payload


def test_playlist_route_404s_before_the_first_chunk_lands(client, temp_dir):
    """A zero-segment playlist is fatal to hls.js; a 404 is retried.

    An empty level raises LEVEL_EMPTY_ERROR and the player gives up, whereas a
    404 is a LEVEL_LOAD_ERROR it will come back from.
    """
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 0.0, 'filename': '《x》', 'status': '正在解析'}
    write_playlist(temp_dir, remote_playlist(5))
    assert client.get('/hls/playlist.m3u8?id=' + SN).status_code == 404


def test_playlist_route_serves_the_prefix(client, temp_dir):
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 40.0, 'filename': '《x》', 'status': '正在下載'}
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1])
    response = client.get('/hls/playlist.m3u8?id=' + SN)
    assert response.status_code == 200
    assert response.mimetype == 'application/vnd.apple.mpegurl'
    body = response.get_data(as_text=True)
    assert body.count('#EXTINF') == 2
    assert '#EXT-X-ENDLIST' not in body


def test_playlist_route_refuses_an_episode_already_in_the_library(client, monkeypatch):
    monkeypatch.setattr(server, '_find_video_entry', lambda sn: {
        'sn': SN, 'resolution': 1080, 'danmu': False})
    assert client.get('/hls/playlist.m3u8?id=' + SN).status_code == 404


@pytest.mark.parametrize('bad', ['-1', '99999', '../../config.json', '', 'x'])
def test_segment_index_cannot_escape_the_temp_dir(client, temp_dir, bad):
    """Segments are addressed by index, so no client string reaches the disk.

    Traversal is not filtered here -- it is structurally impossible, because the
    filename comes from the server's own parse of the playlist.
    """
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 40.0, 'filename': '《x》', 'status': '正在下載'}
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1])
    response = client.get('/hls/segment.ts?id=%s&n=%s' % (SN, bad))
    assert response.status_code in (400, 404)


def test_segment_route_serves_a_landed_chunk(client, temp_dir):
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 40.0, 'filename': '《x》', 'status': '正在下載'}
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1], size=4096)
    response = client.get('/hls/segment.ts?id=%s&n=1' % SN)
    assert response.status_code == 200
    assert response.mimetype == 'video/mp2t'
    assert len(response.get_data()) == 4096


def test_segment_route_refuses_a_chunk_beyond_the_published_prefix(client, temp_dir):
    Config.tasks_progress_rate[int(SN)] = {
        'rate': 40.0, 'filename': '《x》', 'status': '正在下載'}
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1, 4])
    assert client.get('/hls/segment.ts?id=%s&n=4' % SN).status_code == 404


def test_key_route_serves_the_key_only_while_downloading(client, temp_dir):
    assert client.get('/hls/key.bin?id=' + SN).status_code == 404

    Config.tasks_progress_rate[int(SN)] = {
        'rate': 40.0, 'filename': '《x》', 'status': '正在下載'}
    write_playlist(temp_dir, remote_playlist(5))
    write_chunks(temp_dir, [0, 1])
    with open(str(temp_dir / 'key.m3u8key'), 'wb') as f:
        f.write(b'0123456789abcdef')
    response = client.get('/hls/key.bin?id=' + SN)
    assert response.status_code == 200
    assert response.get_data() == b'0123456789abcdef'
    assert response.headers['Cache-Control'] == 'no-store'


@pytest.mark.parametrize('route', ['status.json', 'playlist.m3u8', 'key.bin', 'segment.ts'])
def test_every_stream_route_rejects_a_non_numeric_sn(client, route):
    assert client.get('/hls/%s?id=../../etc/passwd' % route).status_code == 400
    assert client.get('/hls/%s' % route).status_code == 400


# -------------------------------------------------- packaging, not behaviour

def test_service_worker_bypasses_the_stream_routes():
    """CacheStorage ignores Cache-Control, so a cached playlist freezes forever.

    hls.js reloads the playlist with a plain fetch and no Range header, so the
    service worker's range check does not catch it -- the path list has to.
    """
    source = io.open(os.path.join('Dashboard', 'static', 'sw.js'),
                     encoding='utf-8').read()
    assert "'/hls/'" in source
    assert "var CACHE = 'agp-shell-v8'" not in source


def test_the_hls_library_is_vendored_not_hotlinked():
    """Nothing else in this project loads from a CDN, and the service worker
    means the page has to work offline."""
    watch_html = io.open(os.path.join('Dashboard', 'templates', 'watch.html'),
                         encoding='utf-8').read()
    match = [name for name in os.listdir(os.path.join('Dashboard', 'static', 'js'))
             if name.startswith('hls.') and name.endswith('.js')]
    assert match, 'no hls.js vendored in Dashboard/static/js'
    assert any(name in watch_html for name in match)
    assert 'cdnjs' not in watch_html and 'unpkg' not in watch_html
