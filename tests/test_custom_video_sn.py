# -*- coding: utf-8 -*-
"""片庫裡 .aniGamerPlus.json 那幾集的 sn, 每次啟動都要是同一個.

起因: 非正篇 (ova/sp/...) 的 sn 中間那兩位數以前是 hash(type) % 100. Python 的
字串 hash 每次啟動都重新加鹽, 同一集重啟後就換了 sn —— 觀看紀錄、繼續觀看、
縮圖快取全部對不上.
"""

import json
import os
import subprocess
import sys
import types
import zlib

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

for _name in ('pip_system_certs', 'pip_system_certs.wrapt_requests', 'selenium_recaptcha_solver'):
    if _name not in sys.modules:
        _stub = types.ModuleType(_name)
        if _name == 'selenium_recaptcha_solver':
            _stub.RecaptchaSolver = object
            _stub.StandardDelayConfig = object
        sys.modules[_name] = _stub

agp = pytest.importorskip('aniGamerPlus')


def scan(monkeypatch, tmp_path, videos):
    series = tmp_path / 'bangumi' / 'show'
    series.mkdir(parents=True)
    for video in videos:
        (series / video['filename']).write_bytes(b'\0')
    (series / '.aniGamerPlus.json').write_text(json.dumps({
        'anime_name': 'show', 'unique_sn': '123456', 'source': 'Anime1.me', 'videos': videos,
    }), encoding='utf-8')
    monkeypatch.setattr(agp, 'working_dir', str(tmp_path))
    monkeypatch.setattr(agp, 'read_db_all', lambda: [])
    monkeypatch.setattr(agp.Config, 'read_settings', lambda: {'bangumi_dir': str(tmp_path / 'bangumi')})
    monkeypatch.setattr(agp.plugin_manager, 'has_remote', lambda video_data: False)
    agp.updatelist()
    listed = json.loads((tmp_path / 'video_list.json').read_text(encoding='utf-8'))['videos']
    return [video['sn'] for video in listed]


def test_special_episodes_get_fixed_type_codes(monkeypatch, tmp_path):
    sns = scan(monkeypatch, tmp_path, [
        {'episode': 3, 'resolution': 720, 'type': 'normal', 'filename': 'a.mp4'},
        {'episode': 1, 'resolution': 720, 'type': 'ova', 'filename': 'b.mp4'},
        {'episode': 2, 'resolution': 720, 'type': 'sp', 'filename': 'c.mp4'},
        {'episode': 1, 'resolution': 720, 'type': 'movie', 'filename': 'd.mp4'},
    ])
    assert sns == ['4112345600003', '4112345601001', '4112345603002', '4112345605001']


def test_unknown_types_stay_clear_of_the_fixed_codes():
    # 表外的類型用 crc32 落在 10~99: 不會撞到正篇的 00, 也不會撞到表裡的 01~07
    for name in ('weird', 'pv', 'cm', '特典'):
        code = agp.custom_video_type_code(name)
        assert code == str(10 + zlib.crc32(name.encode('utf-8')) % 90)
        assert 10 <= int(code) <= 99
    assert agp.custom_video_type_code(' OVA ') == '01'


def test_type_code_does_not_depend_on_the_hash_seed():
    # 真正的病根是每次啟動的 hash 種子不同; 換兩個種子各算一次, 要算出一樣的東西
    code = ('import types, sys\n'
            'for n in ("pip_system_certs", "pip_system_certs.wrapt_requests", "selenium_recaptcha_solver"):\n'
            '    m = types.ModuleType(n); m.RecaptchaSolver = m.StandardDelayConfig = object; sys.modules[n] = m\n'
            'import aniGamerPlus\n'
            'print(aniGamerPlus.custom_video_type_code("weird"), aniGamerPlus.custom_video_type_code("ova"))\n')
    outputs = set()
    for seed in ('1', '2'):
        env = dict(os.environ, PYTHONHASHSEED=seed)
        result = subprocess.run([sys.executable, '-c', code], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=120)
        assert result.returncode == 0, result.stderr
        outputs.add(result.stdout.strip().splitlines()[-1])
    assert len(outputs) == 1
