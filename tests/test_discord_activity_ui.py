"""Run the real Activity page against a local, deterministic Discord/API stub."""

import json
from pathlib import Path
import time
from urllib.parse import parse_qs, urlsplit

import pytest


ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'https://123.discordsays.com'
ACTIVITY_URL = ORIGIN + '/.proxy/discord/activity'


class ActivityMock:
    def __init__(self):
        self.calls = []
        self.authorizations = []
        self.join_grant_duration = None
        self.identity = {
            'user': {'id': '123', 'username': 'discord-me'},
            'account': None, 'linked': False, 'requires_login': True,
            'csrf_token': 'test-csrf',
        }
        self.state = {
            'instance_id': 'room', 'host_id': None,
            'members': [{'id': '123', 'name': 'Me', 'logged_in': False, 'is_guest': True,
                         'requires_approval': True, 'authorized': False, 'grant_expires_at': None},
                        {'id': '456', 'name': '<img src=x onerror=alert(1)>', 'logged_in': False,
                         'is_guest': True, 'requires_approval': True, 'authorized': False,
                         'grant_expires_at': None}],
            'sn': None, 'position': 0, 'paused': True, 'rate': 1,
            'updated_at': time.time(), 'server_time': time.time(),
            'is_host': False, 'revision': 1, 'can_watch': False,
            'watch_token': None, 'grant_expires_at': None,
        }

    def handle(self, route):
        request = route.request
        path = urlsplit(request.url).path.removeprefix('/.proxy')
        self.calls.append((request.method, path))

        def respond(body, content_type='application/json', status=200):
            route.fulfill(status=status, content_type=content_type,
                          body=body if isinstance(body, (str, bytes)) else json.dumps(body))

        if path == '/outer':
            return respond('''<!doctype html><iframe id="activity" style="border:0;width:100%;height:900px"
                src="/.proxy/discord/activity?frame_id=frame&amp;instance_id=room&amp;platform=desktop"></iframe>''', 'text/html')
        if path == '/discord/activity':
            return respond((ROOT / 'Dashboard/templates/discord_activity.html').read_bytes(), 'text/html')
        if path == '/static/js/vendor/discord-embedded-app-sdk.js':
            return respond('''window.DiscordEmbeddedAppSDK={DiscordSDK:class{
                constructor(){this.instanceId='room';this.commands={
                    authorize:async()=>({code:'fake-code'}),
                    authenticate:async()=>({user:{id:'123'}})}}
                ready(){return Promise.resolve()}}};''', 'application/javascript')
        if path.startswith('/static/'):
            file = ROOT / 'Dashboard' / path.lstrip('/')
            content_type = {'.css': 'text/css', '.js': 'application/javascript', '.ico': 'image/x-icon'}.get(file.suffix)
            if content_type and file.is_file():
                return respond(file.read_bytes(), content_type)
        if path == '/discord/activity/config':
            return respond({'client_id': '123', 'configured': True,
                            'requires_login': True, 'accounts_enabled': True,
                            'csrf_token': 'test-csrf'})
        if request.method == 'POST':
            assert request.headers.get('x-activity-csrf') == 'test-csrf', path
        if path == '/discord/activity/token':
            assert request.post_data_json == {'code': 'fake-code'}
            return respond({**self.identity, 'access_token': 'fake-token'})
        if path == '/discord/activity/me':
            return respond(self.identity)
        if path == '/discord/activity/login':
            assert request.post_data_json == {'username': 'tester', 'password': 'test-password'}
            self.identity['account'] = {'username': 'tester', 'role': 'user'}
            self.state.update(host_id='123', is_host=True, can_watch=True,
                              revision=self.state['revision'] + 1)
            self.state['members'][0].update(logged_in=True, is_guest=False, requires_approval=False, authorized=True)
            return respond(self.identity)
        if path == '/discord/activity/link':
            self.identity['linked'] = True
            return respond(self.identity)
        if path == '/discord/activity/unlink':
            self.identity.update(account=None, linked=False)
            self.state.update(host_id='456', is_host=False, can_watch=False,
                              watch_token=None, grant_expires_at=None,
                              revision=self.state['revision'] + 1)
            self.state['members'][0].update(logged_in=False, is_guest=True, requires_approval=True, authorized=False)
            return respond(self.identity)
        if path in ['/discord/activity/join', '/discord/activity/state']:
            if path.endswith('/join') and self.join_grant_duration is not None:
                self.state['grant_expires_at'] = time.time() + self.join_grant_duration
                self.join_grant_duration = None
            self.state['server_time'] = time.time()
            return respond(self.state)
        if path in ['/discord/activity/grant', '/discord/activity/revoke']:
            data = request.post_data_json
            assert data == {'instance_id': 'room', 'user_id': '456', 'sn': self.state['sn']}
            action = path.rsplit('/', 1)[-1]
            self.authorizations.append((action, data))
            granted = action == 'grant'
            self.state['members'][1].update(authorized=granted, requires_approval=not granted,
                                            grant_expires_at=time.time()+600 if granted else None)
            self.state['revision'] += 1
            return respond(self.state)
        if path == '/video_list.json':
            return respond({'videos': [
                {'sn': 100, 'anime_name': '孤獨搖滾！', 'episode': 1, 'resolution': 1080},
                {'sn': 101, 'anime_name': '孤獨搖滾！', 'episode': 2, 'resolution': 1080},
            ]})
        if path == '/discord/activity/control':
            data = request.post_data_json
            assert data['action'] == 'select'
            self.state.update(sn=data['sn'], position=8, paused=False,
                              rate=1.5, updated_at=time.time()-2,
                              server_time=time.time(), revision=self.state['revision']+1)
            return respond(self.state)
        if path == '/discord/activity/leave':
            return respond({})
        if path == '/watch':
            return respond('''<!doctype html><script>
                addEventListener('message',event=>{window.latest=event.data});
                parent.postMessage({type:'agp:activity-ready'},location.origin);
                </script>''', 'text/html')
        return respond({}, status=404)


@pytest.fixture(scope='module')
def activity_ui_browser(chromium_launcher):
    browser = chromium_launcher(headless=True)
    yield browser
    browser.close()


@pytest.fixture
def activity_ui(activity_ui_browser):
    context = activity_ui_browser.new_context(viewport={'width': 1280, 'height': 1000})
    page = context.new_page()
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    mocked = ActivityMock()
    context.route('**/*', mocked.handle)
    yield page, mocked
    assert errors == []
    context.close()


def test_standalone_activity_visit_does_not_bootstrap_session(activity_ui):
    page, mocked = activity_ui
    page.goto(ACTIVITY_URL)
    page.wait_for_function("document.querySelector('#lobbyTitle').textContent==='從 Discord 開始一起看'")
    assert ('GET', '/discord/activity/config') not in mocked.calls
    assert not any(method == 'POST' for method, _ in mocked.calls)
    assert page.context.cookies() == []


def test_embedded_activity_login_link_host_sync_and_unlink(activity_ui):
    page, mocked = activity_ui
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    frame.wait_for_function("document.querySelector('#lobbyTitle').textContent==='等候主辦人授權'")
    assert ('POST', '/discord/activity/join') in mocked.calls
    frame.locator('#accountToggle').click()
    frame.locator('#accountUsername').wait_for(state='visible')
    assert frame.evaluate('window.parent!==window')
    assert ('GET', '/video_list.json') not in mocked.calls
    frame.locator('#accountUsername').fill('tester')
    frame.locator('#accountPassword').fill('test-password')
    frame.locator('#accountLogin').click()
    frame.wait_for_function("document.querySelectorAll('.activity-episode').length===2")
    assert frame.locator('#accountPassword').input_value() == ''
    assert not mocked.identity['linked']
    assert ('POST', '/discord/activity/link') not in mocked.calls
    assert frame.locator('#memberList img').count() == 0
    frame.locator('#accountLink').click()
    frame.locator('#accountUnlink').wait_for(state='visible')
    assert mocked.identity['linked']
    frame.locator('#accountClose').click()
    frame.locator('.activity-episode[data-sn="100"]').click()
    frame.locator('#activityPlayer').wait_for(state='visible')
    frame.wait_for_function("document.querySelector('#activityPlayer').contentWindow.latest?.state?.sn==='100'")
    sent = frame.evaluate("document.querySelector('#activityPlayer').contentWindow.latest")
    assert sent['isHost'] is True
    assert sent['state']['position'] >= 11  # Base 8s + 2s at 1.5x.
    assert '/.proxy/watch?id=100&activity=1' in frame.locator('#activityPlayer').get_attribute('src')
    frame.locator('[data-access-action="grant"][data-user-id="456"]').click()
    frame.locator('[data-access-action="revoke"][data-user-id="456"]').wait_for(state='visible')
    assert mocked.authorizations == [('grant', {'instance_id': 'room', 'user_id': '456', 'sn': '100'})]
    frame.locator('[data-access-action="revoke"][data-user-id="456"]').click()
    frame.locator('[data-access-action="grant"][data-user-id="456"]').wait_for(state='visible')
    assert mocked.authorizations[-1] == ('revoke', {'instance_id': 'room', 'user_id': '456', 'sn': '100'})
    mocked.state.update(is_host=False, host_id='456', revision=mocked.state['revision']+1)
    frame.wait_for_function("document.querySelector('#playbackRole').textContent==='同步觀看'")
    assert frame.locator('.activity-episode:enabled').count() == 0
    frame.locator('#accountToggle').click()
    frame.locator('#accountUnlink').click()
    frame.locator('#accountUsername').wait_for(state='visible')
    assert frame.locator('#activityPlayer').is_hidden()


def test_guest_waits_then_watches_only_granted_episode_and_stops_on_revoke(activity_ui):
    page, mocked = activity_ui
    mocked.state.update(host_id='456', sn='100')
    mocked.state['members'][1].update(logged_in=True, is_guest=False, authorized=True, requires_approval=False)
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    frame.wait_for_function("document.querySelector('#lobbyTitle').textContent==='等候主辦人授權'")
    assert frame.locator('#activityPlayer').is_hidden()
    assert ('POST', '/discord/activity/join') in mocked.calls
    assert ('GET', '/video_list.json') not in mocked.calls
    assert frame.locator('[data-access-action]').count() == 0
    mocked.state.update(can_watch=True, watch_token='single-video-token+/=', grant_expires_at=time.time()+60,
                        revision=2)
    mocked.state['members'][0].update(authorized=True, requires_approval=False)
    frame.locator('#activityPlayer').wait_for(state='visible')
    frame.wait_for_function("document.querySelector('#playbackRole').textContent==='本片訪客'")
    url = urlsplit(frame.locator('#activityPlayer').get_attribute('src'))
    assert url.path == '/.proxy/watch'
    assert parse_qs(url.query) == {'id': ['100'], 'activity': ['1'], 'ag': ['single-video-token+/=']}
    assert ('GET', '/video_list.json') not in mocked.calls
    # Even a direct request from the guest player cannot send host controls.
    frame.child_frames[0].evaluate("""() => parent.postMessage(
        {type:'agp:activity-control',action:'seek',sn:'100',position:100},location.origin)""")
    page.wait_for_timeout(100)
    assert ('POST', '/discord/activity/control') not in mocked.calls
    mocked.state.update(can_watch=False, watch_token=None, grant_expires_at=None, revision=3)
    mocked.state['members'][0].update(authorized=False, requires_approval=True)
    frame.locator('#activityPlayer').wait_for(state='hidden')
    assert frame.locator('#activityPlayer').get_attribute('src') is None
    assert ('GET', '/video_list.json') not in mocked.calls
    # Changing episodes never carries the preceding video's guest token along.
    mocked.state.update(sn='101', revision=4)
    page.wait_for_timeout(1100)
    assert frame.locator('#activityPlayer').is_hidden()
    mocked.state.update(can_watch=True, watch_token='new-episode-token', grant_expires_at=time.time()+60,
                        revision=5)
    mocked.state['members'][0].update(authorized=True, requires_approval=False)
    frame.locator('#activityPlayer').wait_for(state='visible')
    next_query = parse_qs(urlsplit(frame.locator('#activityPlayer').get_attribute('src')).query)
    assert next_query['id'] == ['101'] and next_query['ag'] == ['new-episode-token']
    assert ('GET', '/video_list.json') not in mocked.calls


def test_guest_grant_expiry_stops_player_before_next_room_poll(activity_ui):
    page, mocked = activity_ui
    mocked.state.update(host_id='456', sn='100', can_watch=True, watch_token='short-lived-token',
                        grant_expires_at=None)
    # Start the short lease at join, after Chromium has loaded the real assets.
    mocked.join_grant_duration = .7
    mocked.state['members'][1].update(logged_in=True, is_guest=False, authorized=True, requires_approval=False)
    mocked.state['members'][0].update(authorized=True, requires_approval=False)
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    frame.locator('#activityPlayer').wait_for(state='visible')
    frame.locator('#activityPlayer').wait_for(state='hidden', timeout=1000)
    assert frame.locator('#activityPlayer').get_attribute('src') is None
    assert frame.locator('#lobbyTitle').text_content() == '本集授權已到期'
    assert ('GET', '/video_list.json') not in mocked.calls
