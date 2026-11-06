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
        self.login_requests = []
        self.authorizations = []
        self.join_grant_duration = None
        self.auto_grant_fail = False
        self.auto_grant_requests = []
        self.use_real_presence = False
        self.fail_next_state = False
        self.platform = 'desktop'
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
            'auto_grant': False, 'auto_grant_available': False,
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
                src="/.proxy/discord/activity?frame_id=frame&amp;instance_id=room&amp;platform=PLATFORM"></iframe>'''
                           .replace('PLATFORM', self.platform), 'text/html')
        if path == '/discord/activity':
            return respond((ROOT / 'Dashboard/templates/discord_activity.html').read_bytes(), 'text/html')
        if path == '/static/js/vendor/discord-embedded-app-sdk.js':
            return respond('''window.sdkAuthorizations=[];window.sdkActivities=[];
                window.DiscordEmbeddedAppSDK={DiscordSDK:class{
                constructor(){this.instanceId='room';this.commands={
                    authorize:async(value)=>{window.sdkAuthorizations.push(value);return {code:'fake-code'}},
                    authenticate:async()=>({user:{id:'123'}}),
                    setActivity:async(value)=>{window.sdkActivities.push(value);return value}}}
                ready(){return Promise.resolve()}
                subscribe(event,handler){if(event==='ACTIVITY_LAYOUT_MODE_UPDATE')window.sdkLayoutHandler=handler;return Promise.resolve()}
                unsubscribe(){return Promise.resolve()}}};''', 'application/javascript')
        if path == '/static/js/discord-activity-presence.js':
            if self.use_real_presence:
                return respond((ROOT/'Dashboard/static/js/discord-activity-presence.js').read_bytes(), 'application/javascript')
            return respond('''window.AgpDiscordPresence={create:()=>({update(){},clear(){},destroy(){},setEnabled:async()=>{}})};''', 'application/javascript')
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
        if path == '/discord/activity/presence-token':
            assert request.post_data_json == {'code': 'fake-code'}
            return respond({'access_token': 'fake-presence-token'})
        if path == '/discord/activity/me':
            return respond(self.identity)
        if path == '/discord/activity/login':
            body = request.post_data_json
            assert {k: body[k] for k in ('username', 'password')} == {'username': 'tester', 'password': 'test-password'}
            self.login_requests.append(body)
            self.identity['account'] = {'username': 'tester', 'role': 'user'}
            self.identity['linked'] = body.get('link') is True
            self.state.update(host_id='123', is_host=True, can_watch=True,
                              auto_grant_available=True,
                              revision=self.state['revision'] + 1)
            self.state['members'][0].update(logged_in=True, is_guest=False, requires_approval=False, authorized=True)
            return respond(self.identity)
        if path == '/discord/activity/link':
            self.identity['linked'] = True
            return respond(self.identity)
        if path == '/discord/activity/unlink':
            self.identity.update(account=None, linked=False)
            self.state.update(host_id='456', is_host=False, can_watch=False,
                              auto_grant=False, auto_grant_available=False,
                              watch_token=None, grant_expires_at=None,
                              revision=self.state['revision'] + 1)
            self.state['members'][0].update(logged_in=False, is_guest=True, requires_approval=True, authorized=False)
            return respond(self.identity)
        if path in ['/discord/activity/join', '/discord/activity/state']:
            if path.endswith('/state') and self.fail_next_state:
                self.fail_next_state = False
                return respond({'error': 'session_expired', 'message': '連線已過期'}, status=401)
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
        if path == '/discord/activity/auto-grant':
            data = request.post_data_json
            assert set(data) == {'instance_id', 'enabled'}
            assert data['instance_id'] == 'room' and isinstance(data['enabled'], bool)
            self.auto_grant_requests.append(data)
            if self.auto_grant_fail:
                return respond({'message': '更新失敗'}, status=503)
            self.state.update(auto_grant=data['enabled'], revision=self.state['revision']+1)
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
    assert frame.locator('#accountRemember').is_checked()
    frame.locator('#accountRemember').uncheck()
    frame.locator('#accountUsername').fill('tester')
    frame.locator('#accountPassword').fill('test-password')
    frame.locator('#accountLogin').click()
    frame.wait_for_function("document.querySelectorAll('.activity-episode').length===2")
    assert frame.locator('#accountPassword').input_value() == ''
    assert mocked.login_requests[-1]['link'] is False
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


def test_login_binds_discord_by_default_and_closes_account_sheet(activity_ui):
    page, mocked = activity_ui
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    frame.wait_for_function("document.querySelector('#lobbyTitle').textContent==='等候主辦人授權'")
    frame.locator('#activityLoginPrompt').click()
    frame.locator('#accountUsername').fill('tester')
    frame.locator('#accountPassword').fill('test-password')
    frame.locator('#accountLogin').click()
    frame.wait_for_function("document.querySelectorAll('.activity-episode').length===2")
    assert mocked.login_requests[-1]['link'] is True
    assert ('POST', '/discord/activity/link') not in mocked.calls
    frame.locator('#accountPanel').wait_for(state='hidden')
    assert frame.locator('#accountToggle').get_attribute('data-linked') == 'true'
    frame.locator('#accountToggle').click()
    assert frame.locator('#accountUnlink').is_visible()
    assert frame.locator('#accountLink').is_hidden()


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


def test_host_auto_grant_toggle_is_authoritative_and_failure_keeps_previous_state(activity_ui):
    page, mocked = activity_ui
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    frame.wait_for_function("document.querySelector('#lobbyTitle').textContent==='等候主辦人授權'")
    assert frame.locator('#autoGrantControls').is_hidden()
    frame.locator('#accountToggle').click()
    frame.locator('#accountUsername').fill('tester')
    frame.locator('#accountPassword').fill('test-password')
    frame.locator('#accountLogin').click()
    button = frame.locator('#autoGrantToggle')
    button.wait_for(state='visible')
    assert button.get_attribute('aria-pressed') == 'false'
    button.click()
    frame.wait_for_function("document.querySelector('#autoGrantToggle').getAttribute('aria-pressed')==='true'")
    assert mocked.auto_grant_requests == [{'instance_id': 'room', 'enabled': True}]
    mocked.auto_grant_fail = True
    button.click()
    frame.wait_for_function("document.querySelector('#activityToast').textContent==='更新失敗'")
    assert button.get_attribute('aria-pressed') == 'true'
    assert not button.is_disabled()
    mocked.auto_grant_fail = False
    button.click()
    frame.wait_for_function("document.querySelector('#autoGrantToggle').getAttribute('aria-pressed')==='false'")
    mocked.state.update(is_host=False, auto_grant_available=False, revision=mocked.state['revision']+1)
    frame.locator('#autoGrantControls').wait_for(state='hidden')


def test_optional_presence_uses_flutter_template_and_separate_authorization_without_resetting_room(activity_ui):
    page, mocked = activity_ui
    mocked.use_real_presence = True
    mocked.state.update(host_id='456', sn='100', can_watch=True, watch_token='guest-video-token',
                        position=12, rate=1.5, paused=False, updated_at=time.time())
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    player = frame.locator('#activityPlayer')
    player.wait_for(state='visible')
    assert frame.locator('#activityPresenceToggle').get_attribute('aria-pressed') == 'false'
    assert frame.evaluate('window.sdkActivities') == []
    assert all('rpc.activities.write' not in value['scope'] for value in frame.evaluate('window.sdkAuthorizations'))
    before_src = player.get_attribute('src')
    child = frame.child_frames[0]
    child.evaluate("""() => parent.postMessage({type:'agp:activity-playback',sn:'100',
      title:'孤獨搖滾！',episode:'第 1 集',position:12,duration:1440,paused:false,rate:1.5,
      cover:'https://example.com/cover.webp'},location.origin)""")
    frame.locator('#activityPresenceToggle').click()
    frame.wait_for_function("window.sdkActivities.some(value=>value.activity?.details==='孤獨搖滾！')")
    assert frame.locator('#activityPresenceToggle').get_attribute('aria-pressed') == 'true'
    assert ('POST', '/discord/activity/presence-token') in mocked.calls
    assert mocked.calls.count(('POST', '/discord/activity/token')) == 1
    authorization = frame.evaluate('window.sdkAuthorizations.at(-1)')
    assert 'rpc.activities.write' in authorization['scope']
    activity = frame.evaluate('window.sdkActivities.filter(value=>value.activity?.details).at(-1).activity')
    assert activity['type'] == 3 and activity['details'] == '孤獨搖滾！'
    assert activity['state'] == '第 1 集'
    assert activity['assets'] == {'large_image': 'https://example.com/cover.webp', 'large_text': '孤獨搖滾！'}
    assert activity['timestamps']['end'] > activity['timestamps']['start']
    assert 'guest-video-token' not in str(activity)
    assert player.get_attribute('src') == before_src
    mocked.state.update(paused=True, position=30, updated_at=time.time(), revision=mocked.state['revision']+1)
    child.evaluate("""() => parent.postMessage({type:'agp:activity-playback',sn:'100',
      title:'孤獨搖滾！',episode:'第 1 集',position:30,duration:1440,paused:true,rate:1.5,
      cover:'https://example.com/cover.webp'},location.origin)""")
    frame.wait_for_function("window.sdkActivities.at(-1).activity?.state==='第 1 集 · 已暫停'", timeout=7000)
    assert 'timestamps' not in frame.evaluate('window.sdkActivities.at(-1).activity')
    frame.locator('#activityPresenceToggle').click()
    frame.wait_for_function('window.sdkActivities.at(-1).activity===null')
    assert frame.locator('#activityPresenceToggle').get_attribute('aria-pressed') == 'false'
    assert player.get_attribute('src') == before_src
    frame.locator('#activityPresenceToggle').click()
    frame.wait_for_function("window.sdkActivities.at(-1)?.activity?.details==='孤獨搖滾！'")
    mocked.state.update(can_watch=False, watch_token=None, revision=mocked.state['revision']+1)
    player.wait_for(state='hidden')
    frame.wait_for_function('window.sdkActivities.at(-1).activity===null')


@pytest.mark.parametrize('width,height', [(1280, 900), (390, 844)])
def test_activity_fullscreen_fills_parent_viewport_without_native_fullscreen_or_reload(activity_ui, width, height):
    page, mocked = activity_ui
    page.set_viewport_size({'width': width, 'height': height})
    mocked.state.update(host_id='456', sn='100', can_watch=True, watch_token='guest-current-video')
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    player = frame.locator('#activityPlayer')
    player.wait_for(state='visible')
    frame.wait_for_function("document.querySelector('#activityPlayer').contentWindow.latest?.state?.sn==='100'")
    assert frame.evaluate('document.documentElement.scrollWidth<=innerWidth')
    before_src = player.get_attribute('src')
    child = frame.child_frames[0]
    child.evaluate("""() => {
      window.keepPlayer=true;
      parent.postMessage({type:'agp:activity-fullscreen',expanded:true},location.origin);
    }""")
    frame.wait_for_function("document.body.classList.contains('activity-player-expanded')")
    box = player.bounding_box()
    viewport = frame.evaluate('({width:innerWidth,height:innerHeight})')
    theater = frame.evaluate("""() => {
      const rect=document.querySelector('.activity-theater').getBoundingClientRect();
      return {x:rect.x,y:rect.y,width:rect.width,height:rect.height};
    }""")
    assert theater == {'x': 0, 'y': 0, 'width': viewport['width'], 'height': viewport['height']}
    assert box['width'] == viewport['width'] and box['height'] == viewport['height']
    assert frame.evaluate('document.fullscreenElement') is None
    frame.locator('#activityExpandedExit').click()
    frame.wait_for_function("!document.body.classList.contains('activity-player-expanded')")
    child.evaluate("parent.postMessage({type:'agp:activity-fullscreen',expanded:true},location.origin)")
    frame.wait_for_function("document.body.classList.contains('activity-player-expanded')")
    frame.locator('#activityExpandedExit').focus()
    page.keyboard.press('Escape')
    frame.wait_for_function("!document.body.classList.contains('activity-player-expanded')")
    assert player.get_attribute('src') == before_src
    assert child.evaluate('window.keepPlayer') is True
    child.evaluate("parent.postMessage({type:'agp:activity-fullscreen',expanded:true},location.origin)")
    frame.wait_for_function("document.body.classList.contains('activity-player-expanded')")
    mocked.state.update(can_watch=False, watch_token=None, revision=mocked.state['revision']+1)
    player.wait_for(state='hidden')
    assert not frame.evaluate("document.body.classList.contains('activity-player-expanded')")


@pytest.mark.parametrize('width,height', [(200, 200), (240, 240), (320, 240), (390, 220)])
def test_discord_small_mobile_view_preserves_player_without_scaling_whole_page(activity_ui, width, height):
    page, mocked = activity_ui
    mocked.state.update(host_id='456', sn='100', can_watch=True, watch_token='same-video-capability')
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    player = frame.locator('#activityPlayer')
    player.wait_for(state='visible')
    child = frame.child_frames[0]
    child.evaluate('window.samePlayer=true')
    original_src = player.get_attribute('src')
    page.evaluate("""() => {
      document.body.style.margin='0';
      const activity=document.querySelector('#activity');
      activity.style.cssText='position:fixed;inset:0;border:0;width:100vw;height:100vh';
    }""")
    page.set_viewport_size({'width': width, 'height': height})
    layout = frame.evaluate("""() => {
      const box=document.querySelector('.activity-theater').getBoundingClientRect();
      return {width:innerWidth,height:innerHeight,scrollWidth:document.documentElement.scrollWidth,
        scrollHeight:document.documentElement.scrollHeight,x:box.x,y:box.y,playerWidth:box.width,playerHeight:box.height,
        topbar:getComputedStyle(document.querySelector('.activity-topbar')).display,
        sidebar:getComputedStyle(document.querySelector('.activity-sidebar')).display};
    }""")
    assert layout == {'width': width, 'height': height, 'scrollWidth': width, 'scrollHeight': height,
                      'x': 0, 'y': 0, 'playerWidth': width, 'playerHeight': height,
                      'topbar': 'none', 'sidebar': 'none'}
    assert player.get_attribute('src') == original_src
    assert child.evaluate('window.samePlayer') is True
    # Resizing a floating Activity does not change the user's expansion choice.
    child.evaluate("parent.postMessage({type:'agp:activity-fullscreen',expanded:true},location.origin)")
    frame.locator('#activityExpandedExit').wait_for(state='visible')
    assert frame.locator('#activityExpandedExit').bounding_box()['width'] < width
    frame.locator('#activityExpandedExit').click()
    page.set_viewport_size({'width': 390, 'height': 844})
    frame.wait_for_function("getComputedStyle(document.querySelector('.activity-topbar')).display!=='none'")
    assert frame.evaluate('document.documentElement.scrollWidth<=innerWidth')
    assert player.get_attribute('src') == original_src
    assert child.evaluate('window.samePlayer') is True
    assert not frame.evaluate("document.body.classList.contains('activity-player-expanded')")


def test_discord_small_waiting_view_never_creates_guest_player(activity_ui):
    page, mocked = activity_ui
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    frame.wait_for_function("document.querySelector('#lobbyTitle').textContent==='等候主辦人授權'")
    page.evaluate("""() => {
      document.body.style.margin='0';
      document.querySelector('#activity').style.cssText='position:fixed;inset:0;border:0;width:100vw;height:100vh';
    }""")
    page.set_viewport_size({'width': 200, 'height': 200})
    assert frame.locator('#playerPlaceholder').is_visible()
    assert frame.locator('#activityPlayer').is_hidden()
    assert frame.locator('#activityPlayer').get_attribute('src') is None
    assert frame.locator('#lobbyTitle').is_visible()
    assert frame.evaluate('document.documentElement.scrollWidth===innerWidth')
    assert frame.evaluate('document.documentElement.scrollHeight===innerHeight')
    assert ('GET', '/video_list.json') not in mocked.calls


def test_reconnect_resets_optional_presence_until_user_grants_scope_again(activity_ui):
    page, mocked = activity_ui
    mocked.use_real_presence = True
    mocked.state.update(host_id='456', sn='100', can_watch=True, watch_token='guest-video-token',
                        position=12, paused=True, updated_at=time.time())
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    player = frame.locator('#activityPlayer')
    player.wait_for(state='visible')
    frame.child_frames[0].evaluate("""() => parent.postMessage({type:'agp:activity-playback',sn:'100',
      title:'孤獨搖滾！',episode:'第 1 集',position:12,duration:1440,paused:true,rate:1},location.origin)""")
    frame.locator('#activityPresenceToggle').click()
    frame.wait_for_function("window.sdkActivities.at(-1)?.activity?.details==='孤獨搖滾！'")
    assert mocked.calls.count(('POST', '/discord/activity/presence-token')) == 1
    mocked.fail_next_state = True
    frame.locator('#connectButton').wait_for(state='visible')
    player.wait_for(state='hidden')
    frame.locator('#connectButton').click()
    player.wait_for(state='visible')
    assert frame.locator('#activityPresenceToggle').get_attribute('aria-pressed') == 'false'
    assert frame.evaluate('window.sdkActivities.at(-1).activity') is None
    assert mocked.calls.count(('POST', '/discord/activity/token')) == 2
    assert mocked.calls.count(('POST', '/discord/activity/presence-token')) == 1
    assert 'rpc.activities.write' not in frame.evaluate('window.sdkAuthorizations.at(-1).scope')
    frame.locator('#activityPresenceToggle').click()
    frame.wait_for_function("document.querySelector('#activityPresenceToggle').getAttribute('aria-pressed')==='true'")
    assert mocked.calls.count(('POST', '/discord/activity/presence-token')) == 2
    assert 'rpc.activities.write' in frame.evaluate('window.sdkAuthorizations.at(-1).scope')


@pytest.mark.parametrize('layout_mode', [1, 2])
def test_discord_minimized_layout_uses_player_only_even_without_viewport_resize(activity_ui, layout_mode):
    page, mocked = activity_ui
    mocked.state.update(host_id='456', sn='100', can_watch=True, watch_token='same-video-token')
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    player = frame.locator('#activityPlayer')
    player.wait_for(state='visible')
    frame.wait_for_function("typeof window.sdkLayoutHandler==='function'")
    before_src = player.get_attribute('src')
    child = frame.child_frames[0]
    child.evaluate('window.samePlayer=true')
    frame.evaluate('(mode)=>window.sdkLayoutHandler({layout_mode:mode})', layout_mode)
    frame.wait_for_function("document.body.classList.contains('activity-client-compact')")
    layout = frame.evaluate("""() => {
      const box=document.querySelector('.activity-theater').getBoundingClientRect();
      return {x:box.x,y:box.y,width:box.width,height:box.height,
        viewportWidth:innerWidth,viewportHeight:innerHeight,
        scrollWidth:document.documentElement.scrollWidth,scrollHeight:document.documentElement.scrollHeight,
        topbar:getComputedStyle(document.querySelector('.activity-topbar')).display};
    }""")
    assert layout['x'] == layout['y'] == 0
    assert layout['width'] == layout['viewportWidth'] == layout['scrollWidth']
    assert layout['height'] == layout['viewportHeight'] == layout['scrollHeight']
    assert layout['topbar'] == 'none'
    frame.evaluate('window.sdkLayoutHandler({layout_mode:0})')
    frame.wait_for_function("getComputedStyle(document.querySelector('.activity-topbar')).display!=='none'")
    assert player.get_attribute('src') == before_src
    assert child.evaluate('window.samePlayer') is True


def set_native_mobile_overlays(page, frame, *, top=72, bottom=80, left=20, right=20,
                               publish_insets=True):
    """Model Discord controls outside our iframe, including real pointer blocking."""
    insets = {'top': top, 'bottom': bottom, 'left': left, 'right': right}
    page.evaluate("""(insets) => {
      document.body.style.margin='0';
      document.querySelector('#activity').style.cssText=
        'position:fixed;inset:0;border:0;width:100vw;height:100vh';
      for(const side of ['top','bottom','left','right']) {
        let overlay=document.getElementById('discord-native-'+side);
        if(!overlay){overlay=document.createElement('div');overlay.id='discord-native-'+side;document.body.append(overlay);}
        overlay.style.cssText='position:fixed;z-index:2147483647;background:#282a36;pointer-events:auto';
        if(side==='top'||side==='bottom'){
          Object.assign(overlay.style,{left:'0',right:'0',height:insets[side]+'px',[side]:'0'});
        }else{
          Object.assign(overlay.style,{top:insets.top+'px',bottom:insets.bottom+'px',width:insets[side]+'px',[side]:'0'});
        }
      }
    }""", insets)
    if publish_insets:
        frame.evaluate("""(insets) => {
          for(const [side,value] of Object.entries(insets))
            document.documentElement.style.setProperty('--discord-safe-area-inset-'+side,value+'px');
        }""", insets)


def open_mobile_activity(activity_ui):
    page, mocked = activity_ui
    mocked.platform = 'mobile'
    page.set_viewport_size({'width': 390, 'height': 844})
    page.goto(ORIGIN + '/outer')
    frame = page.frames[1]
    frame.wait_for_function("document.querySelector('#lobbyTitle').textContent==='等候主辦人授權'")
    return page, mocked, frame


def assert_native_controls_do_not_cover(locator, page, *, top, bottom, left, right):
    box = locator.bounding_box()
    assert box is not None
    assert box['y'] >= top
    assert box['y'] + box['height'] <= page.viewport_size['height'] - bottom
    assert box['x'] >= left
    assert box['x'] + box['width'] <= page.viewport_size['width'] - right


@pytest.mark.parametrize('entrance', ['#accountToggle', '#activityLoginPrompt'])
def test_mobile_login_remains_clickable_beneath_discord_native_controls(activity_ui, entrance):
    page, mocked, frame = open_mobile_activity(activity_ui)
    set_native_mobile_overlays(page, frame)
    button = frame.locator(entrance)
    button.wait_for(state='visible')
    button.scroll_into_view_if_needed()
    assert_native_controls_do_not_cover(button, page, top=72, bottom=80, left=20, right=20)
    button.click()
    frame.locator('#accountUsername').fill('tester')
    frame.locator('#accountPassword').fill('test-password')
    submit = frame.locator('#accountLogin')
    submit.scroll_into_view_if_needed()
    assert_native_controls_do_not_cover(submit, page, top=72, bottom=80, left=20, right=20)
    submit.click()
    frame.wait_for_function("document.querySelectorAll('.activity-episode').length===2")
    assert mocked.identity['account']['username'] == 'tester'
    assert ('POST', '/discord/activity/login') in mocked.calls
    assert frame.locator('#activityLoginPrompt').is_hidden()


def test_mobile_login_uses_startup_fallback_before_discord_publishes_safe_areas(activity_ui):
    page, _, frame = open_mobile_activity(activity_ui)
    set_native_mobile_overlays(page, frame, top=56, bottom=56, left=0, right=0,
                               publish_insets=False)
    button = frame.locator('#accountToggle')
    assert_native_controls_do_not_cover(button, page, top=56, bottom=56, left=0, right=0)
    button.click()
    frame.locator('#accountUsername').fill('tester')
    frame.locator('#accountPassword').fill('test-password')
    frame.locator('#accountLogin').click()
    frame.wait_for_function("document.querySelectorAll('.activity-episode').length===2")


def test_mobile_native_safe_area_changes_move_login_without_reloading_activity(activity_ui):
    page, mocked, frame = open_mobile_activity(activity_ui)
    set_native_mobile_overlays(page, frame)
    frame.evaluate('window.sameActivity=true')
    set_native_mobile_overlays(page, frame, top=104, bottom=96, left=28, right=24)
    button = frame.locator('#accountToggle')
    button.scroll_into_view_if_needed()
    assert_native_controls_do_not_cover(button, page, top=104, bottom=96, left=28, right=24)
    button.click()
    assert frame.locator('#accountUsername').is_visible()
    assert frame.evaluate('window.sameActivity') is True
    assert mocked.calls.count(('POST', '/discord/activity/token')) == 1
    assert frame.evaluate('document.documentElement.scrollWidth<=innerWidth')


def test_mobile_keyboard_height_does_not_hide_account_form_as_a_compact_preview(activity_ui):
    page, mocked, frame = open_mobile_activity(activity_ui)
    set_native_mobile_overlays(page, frame)
    frame.locator('#activityLoginPrompt').click()
    frame.locator('#accountUsername').fill('tester')
    # An iOS/Android keyboard can reduce a focused Activity below the compact
    # media query threshold; that must not turn the active login form into PIP.
    page.set_viewport_size({'width': 390, 'height': 320})
    set_native_mobile_overlays(page, frame, top=56, bottom=48, left=12, right=12)
    assert frame.locator('#accountPanel').is_visible()
    assert frame.locator('#accountUsername').is_visible()
    frame.locator('#accountPassword').fill('test-password')
    submit = frame.locator('#accountLogin')
    submit.scroll_into_view_if_needed()
    assert_native_controls_do_not_cover(submit, page, top=56, bottom=48, left=12, right=12)
    submit.click()
    frame.wait_for_function("document.querySelectorAll('.activity-episode').length===2")
    assert mocked.identity['account']['username'] == 'tester'
