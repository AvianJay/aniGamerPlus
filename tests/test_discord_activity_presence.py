"""Flutter-compatible rich presence through a mocked Embedded App SDK."""
import json
from pathlib import Path

import pytest


MODULE = Path(__file__).resolve().parents[1] / 'Dashboard/static/js/discord-activity-presence.js'
NOW = 1_700_000_000_000


@pytest.fixture(scope='module')
def presence_browser(chromium_launcher):
    browser = chromium_launcher(headless=True)
    yield browser
    browser.close()


@pytest.fixture
def page(presence_browser):
    context = presence_browser.new_context()
    page = context.new_page()
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.set_content('<!doctype html><html><body></body></html>')
    page.add_script_tag(content=MODULE.read_text(encoding='utf-8'))
    page.evaluate("""() => {
      window.clock=1700000000000; Date.now=()=>window.clock;
      window.calls=[]; window.failures=[]; window.authorizations=0;
      window.sdk={commands:{setActivity:async value=>{calls.push(value)}}};
      window.presence=AgpDiscordPresence.create({sdk,
        authorize:async()=>{authorizations++}, onError:value=>failures.push(value)});
    }""")
    yield page
    assert errors == []
    context.close()


def payload(*, sn='101', paused=False, position=100, title='孤獨搖滾！', episode='1',
            duration=600, cover='https://cover.example/series.webp'):
    return {
        'state': {'sn': sn, 'can_watch': True, 'position': position, 'rate': 2,
                  'paused': paused, 'server_time': 1000, 'updated_at': 990},
        'identity': {'user': {'id': '123'}},
        'video': {'sn': sn, 'anime_name': 'Fallback title', 'episode': '9'},
        'player': {'sn': sn, 'title': title, 'episode': episode, 'position': 999,
                   'duration': duration, 'paused': not paused, 'rate': .5, 'cover': cover},
    }


def update(page, value, *, elapsed=0):
    page.evaluate('({value,elapsed})=>{clock+=elapsed; presence.update(value)}',
                  {'value': value, 'elapsed': elapsed})


def calls(page, count):
    page.wait_for_function('(count)=>window.calls.length===count', arg=count)
    return page.evaluate('window.calls')


def test_flutter_template_is_opt_in_and_uses_room_playback_clock(page):
    update(page, payload())
    assert not page.evaluate('presence.enabled')
    assert page.evaluate('authorizations') == 0
    assert page.evaluate('calls') == []
    assert page.evaluate('presence.setEnabled(true)')
    activity = calls(page, 1)[0]['activity']
    assert activity == {
        'type': 3, 'details': '孤獨搖滾！', 'state': '第 1 集',
        'timestamps': {'start': NOW // 1000 - 60, 'end': NOW // 1000 + 240},
        'assets': {'large_image': 'https://cover.example/series.webp', 'large_text': '孤獨搖滾！'},
    }
    assert page.evaluate('authorizations') == 1
    # Application identity belongs to this Activity, never Flutter's fixed app ID.
    assert 'name' not in activity and 'application_id' not in activity
    assert not any(key in activity for key in ('secrets', 'details_url', 'state_url'))


def test_pause_episode_and_unicode_limits_match_flutter(page):
    update(page, payload(title='🎸' * 140, paused=True, episode='特別篇'))
    page.evaluate('presence.setEnabled(true)')
    activity = calls(page, 1)[0]['activity']
    assert len(activity['details']) == 128
    assert activity['state'] == '特別篇 · 已暫停'
    assert 'timestamps' not in activity
    update(page, payload(sn='102', episode='2.5', duration=0, cover=''), elapsed=5001)
    activity = calls(page, 2)[1]['activity']
    assert activity['state'] == '第 2.5 集'
    assert 'timestamps' not in activity and 'assets' not in activity


def test_natural_progress_deduplicates_but_seek_and_pause_update(page):
    update(page, payload())
    page.evaluate('presence.setEnabled(true)')
    calls(page, 1)
    update(page, payload(position=110), elapsed=5000)
    page.wait_for_timeout(30)
    assert len(page.evaluate('calls')) == 1
    update(page, payload(position=180), elapsed=1)
    calls(page, 2)
    update(page, payload(paused=True, position=180), elapsed=5000)
    assert calls(page, 3)[2]['activity']['state'] == '第 1 集 · 已暫停'


def test_revocation_cancels_queued_episode_and_clears_immediately(page):
    update(page, payload())
    page.evaluate('presence.setEnabled(true)')
    calls(page, 1)
    update(page, payload(sn='102', title='New episode'), elapsed=100)
    assert len(page.evaluate('calls')) == 1
    blocked = payload(sn='102')
    blocked['state']['can_watch'] = False
    update(page, blocked)
    assert calls(page, 2)[1] == {'activity': None}
    page.evaluate('clock+=10000')
    page.wait_for_timeout(30)
    assert len(page.evaluate('calls')) == 2


def test_inflight_rpc_cannot_restore_old_presence_after_destroy(page):
    page.evaluate("""() => {
      window.resolvers=[];
      sdk.commands.setActivity=value=>{calls.push(value); return new Promise(resolve=>resolvers.push(resolve))};
    }""")
    update(page, payload())
    page.evaluate('presence.setEnabled(true)')
    calls(page, 1)
    update(page, payload(sn='102'))
    page.evaluate('presence.destroy(); resolvers[0]({})')
    assert calls(page, 2)[1] == {'activity': None}
    page.evaluate('resolvers[1]({}); clock+=10000')
    update(page, payload(sn='103'))
    page.wait_for_timeout(30)
    assert len(page.evaluate('calls')) == 2


def test_permission_refusal_is_safe_and_keeps_presence_off(page):
    page.evaluate("""() => {
      presence=AgpDiscordPresence.create({sdk,authorize:async()=>{throw new Error('secret-sdk-response')}});
    }""")
    message = page.evaluate("presence.setEnabled(true).catch(error=>error.message)")
    assert 'secret-sdk-response' not in message
    assert '重新授權' in message
    assert not page.evaluate('presence.enabled')
    assert page.evaluate('calls') == []


def test_disable_during_pending_permission_does_not_enable_later(page):
    page.evaluate("""() => {
      presence=AgpDiscordPresence.create({sdk,authorize:()=>new Promise(resolve=>window.permit=resolve)});
      window.pendingEnable=presence.setEnabled(true);
    }""")
    page.evaluate('presence.setEnabled(false)')
    page.evaluate('permit()')
    assert not page.evaluate('window.pendingEnable')
    assert not page.evaluate('presence.enabled')
    assert page.evaluate('calls') == []


@pytest.mark.parametrize('cover', [
    'https://activity.example/thumbnail.webp?id=101&ag=private-capability',
    'https://user:password@cover.example/image.webp',
    'http://cover.example/image.webp',
])
def test_artwork_never_includes_guest_capabilities_or_credentials(page, cover):
    update(page, payload(cover=cover))
    page.evaluate('presence.setEnabled(true)')
    assert 'assets' not in calls(page, 1)[0]['activity']


def test_rpc_failure_is_sanitized_and_does_not_retry_each_poll(page):
    page.evaluate("() => {sdk.commands.setActivity=async value=>{calls.push(value);throw new Error('secret-sdk-body')}}")
    update(page, payload())
    page.evaluate('presence.setEnabled(true)')
    calls(page, 1)
    page.wait_for_function('failures.length===1')
    assert 'secret' not in json.dumps(page.evaluate('failures'))
    update(page, payload(position=110), elapsed=5000)
    page.wait_for_timeout(30)
    assert len(page.evaluate('calls')) == 1
