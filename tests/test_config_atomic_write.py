"""config.json / sn_list.txt must never be observable half-written.

``Config.write_settings`` used to ``open(config_path, 'w')`` in place, which
truncates the file before a single byte of the new document is there. The
dashboard calls ``read_settings()`` on essentially every request, so a save
that collided with a read handed the reader an empty or partial document --
and ``__read_settings_file`` answers that by calling ``__init_settings()``,
which ``os.remove``s config.json and writes factory defaults back. The
operator's whole configuration is gone, including ``user_control``, which is
what keeps the dashboard behind a login.

Run with::

    python -m pytest tests/test_config_atomic_write.py -q
"""

import json
import os
import threading
import time

import pytest

import Config


@pytest.fixture
def config_paths(tmp_path, monkeypatch):
    config = tmp_path / 'config.json'
    sn_list = tmp_path / 'sn_list.txt'
    monkeypatch.setattr(Config, 'config_path', str(config))
    monkeypatch.setattr(Config, 'sn_list_path', str(sn_list))
    return config, sn_list


def test_sn_list_write_is_atomic(config_paths):
    _, sn_list = config_paths
    Config.write_sn_list('12345 all\n')
    assert sn_list.read_text(encoding='utf-8') == '12345 all\n'

    Config.write_sn_list('67890 latest\n')
    assert sn_list.read_text(encoding='utf-8') == '67890 latest\n'


def test_add_sn_to_list_is_idempotent_and_preserves_metadata(config_paths):
    _, sn_list = config_paths
    Config.write_sn_list(
        '@season\n'
        '12345 latest <自訂名稱> # keep this\n'
        '# Ended: 67890 all\n'
    )

    assert Config.add_sn_to_list('12345', 'all') == {
        'added': False, 'updated': True}
    assert Config.add_sn_to_list('12345', 'all') == {
        'added': False, 'updated': False}
    assert Config.add_sn_to_list('67890', 'all') == {
        'added': True, 'updated': False}
    assert sn_list.read_text(encoding='utf-8') == (
        '@season\n'
        '12345 all <自訂名稱> # keep this\n'
        '# Ended: 67890 all\n'
        '@\n'
        '67890 all\n'
    )


def test_concurrent_sn_list_additions_do_not_overwrite_each_other(config_paths):
    _, sn_list = config_paths
    threads = [
        threading.Thread(target=Config.add_sn_to_list, args=(str(10000 + i),))
        for i in range(20)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=10)

    assert sorted(sn_list.read_text(encoding='utf-8').splitlines()) == [
        str(10000 + i) + ' all' for i in range(20)
    ]


def test_download_limiter_can_grow_and_shrink_without_losing_permits():
    limiter = Config._ResizableSemaphore(2)
    limiter.acquire()
    limiter.acquire()

    grew = threading.Event()

    def enter_after_grow():
        limiter.acquire()
        grew.set()
        limiter.release()

    grow_waiter = threading.Thread(target=enter_after_grow)
    grow_waiter.start()
    assert not grew.wait(0.05)
    limiter.set_limit(3)
    assert grew.wait(1)
    grow_waiter.join(timeout=1)

    limiter.set_limit(1)
    shrank = threading.Event()

    def enter_after_shrink():
        limiter.acquire()
        shrank.set()
        limiter.release()

    shrink_waiter = threading.Thread(target=enter_after_shrink)
    shrink_waiter.start()
    limiter.release()
    assert not shrank.wait(0.05)
    limiter.release()
    assert shrank.wait(1)
    shrink_waiter.join(timeout=1)


def test_download_limiter_is_shared_and_runtime_setting_updates_it(monkeypatch):
    monkeypatch.setattr(Config, '_download_limiter', None)
    from_main = Config.get_download_limiter(3)
    from_dashboard_import = Config.get_download_limiter(1)

    assert from_dashboard_import is from_main
    assert from_main.limit == 3
    assert Config.set_download_concurrency_limit(1) == 1
    assert from_dashboard_import.limit == 1


def test_no_temp_files_are_left_behind(config_paths, tmp_path):
    _, sn_list = config_paths
    Config.write_sn_list('12345 all\n')
    leftovers = [name for name in os.listdir(tmp_path) if name.endswith('.tmp')]
    assert leftovers == [], leftovers


def test_readers_never_see_a_half_written_sn_list(config_paths):
    """The failure this whole module exists for: a reader landing inside the
    truncate-then-write window."""
    _, sn_list = config_paths
    # Big enough that writing it is not a single instantaneous syscall.
    small = '11111 all\n' * 200
    large = '22222 latest\n' * 200
    Config.write_sn_list(small)

    stop = threading.Event()
    seen = []
    errors = []

    def writer():
        for i in range(60):
            if stop.is_set():
                return
            try:
                Config.write_sn_list(small if i % 2 else large)
            except Exception as error:  # noqa: BLE001 - the point is to report it
                errors.append('write failed during concurrent reads: %r' % (error,))
                return

    def reader():
        while not stop.is_set():
            try:
                with open(str(sn_list), 'r', encoding='utf-8') as handle:
                    seen.append(handle.read())
            except FileNotFoundError:
                errors.append('sn_list.txt vanished mid-write')
                return
            except PermissionError:
                # Windows hands out a transient EACCES while os.replace() is
                # landing. That is what Config.__read_config_text() retries
                # through; a raw open() here just tries again.
                time.sleep(0.002)
                continue
            except OSError as error:
                errors.append('read error: %s' % error)
                return
            # Windows will not let os.replace() land while a handle is open on
            # the destination; a reader that never lets go is not a real one.
            time.sleep(0.001)

    threads = [threading.Thread(target=reader) for _ in range(3)]
    write_thread = threading.Thread(target=writer)
    for thread in threads:
        thread.start()
    write_thread.start()
    write_thread.join(timeout=30)
    stop.set()
    for thread in threads:
        thread.join(timeout=10)

    assert not errors, errors[:3]
    assert seen, 'the reader never got a look in'
    # Every observation has to be one of the two whole documents -- never a
    # prefix of one, and never empty.
    bad = [text[:40] for text in seen if text not in (small, large)]
    assert bad == [], bad


def test_a_transient_read_error_does_not_reset_the_config(config_paths, monkeypatch):
    """__read_settings_file used to answer *any* exception -- including a
    momentary EACCES from Windows, an antivirus scan or a descriptor shortage
    -- by deleting config.json and writing factory defaults back. That turns a
    hiccup into the loss of the operator's whole configuration, and factory
    defaults have user_control off, so the dashboard also loses its login."""
    config, _ = config_paths
    mine = {'config_version': 18.4, 'mine': 'do not lose this'}
    config.write_text(json.dumps(mine), encoding='utf-8')

    real_open = open
    attempts = {'n': 0}

    def flaky_open(path, *args, **kwargs):
        if str(path) == str(config):
            attempts['n'] += 1
            if attempts['n'] <= 3:
                raise PermissionError(13, 'Permission denied')
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr('builtins.open', flaky_open)
    reset = []
    monkeypatch.setattr(Config, '__init_settings',
                        lambda: reset.append(True), raising=False)

    loaded = getattr(Config, '__read_settings_file')()
    assert reset == [], 'a transient read error must not reset the config'
    assert loaded['mine'] == 'do not lose this'
    assert attempts['n'] > 3, 'it should have retried'


def test_genuinely_corrupt_json_still_resets(config_paths, monkeypatch):
    """The reset path exists for a real reason; keep it."""
    config, _ = config_paths
    config.write_text('{not json at all', encoding='utf-8')
    reset = []

    def fake_init():
        reset.append(True)
        config.write_text(json.dumps({'config_version': 18.4}), encoding='utf-8')

    monkeypatch.setattr(Config, '__init_settings', fake_init, raising=False)
    monkeypatch.setattr(Config, 'check_encoding', lambda *a, **k: None)
    # __color_print reaches for ColorPrint.err_print, which wants a console;
    # what it prints is not what this test is about.
    monkeypatch.setattr(Config, '__color_print', lambda *a, **k: None,
                        raising=False)

    getattr(Config, '__read_settings_file')()
    assert reset == [True]


def test_write_failure_leaves_the_previous_file_intact(config_paths, monkeypatch):
    """A failed save must not cost the operator the file that was already
    there -- that is the whole reason for writing to one side first."""
    _, sn_list = config_paths
    Config.write_sn_list('12345 all\n')

    def boom(src, dst):
        raise OSError('simulated disk failure')

    monkeypatch.setattr(Config.os, 'replace', boom)
    with pytest.raises(OSError):
        Config.write_sn_list('99999 latest\n')

    assert sn_list.read_text(encoding='utf-8') == '12345 all\n'
    leftovers = [name for name in os.listdir(os.path.dirname(str(sn_list)))
                 if name.endswith('.tmp')]
    assert leftovers == [], leftovers
