"""Exercise the real watch page inside a same-origin Discord Activity frame.

The tiny parent replaces Discord messaging only. Templates, player code, media
events and the Activity bridge are production assets served by ui_harness;
all videos and metadata come from local fixtures, without Discord credentials.
"""

from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi.responses import Response

from ui_harness import FIRST_SN, VIDEO_LIST, HarnessServer


@pytest.fixture(scope='module')
def activity_player_server():
    running = HarnessServer(catalog=False, hls=False)
    parent = """<!doctype html><html><head><style>
      html,body{margin:0;background:#0b0c0e}
      #stage{width:min(900px,100vw);aspect-ratio:16/9}
      iframe{display:block;border:0;width:100%;height:100%}
      </style></head><body><div id="stage">
      <iframe id="player" allow="autoplay; fullscreen; picture-in-picture"
        src="/watch?id=FIRST_SN&amp;activity=1"></iframe></div>
      <script>
        window.activityMessages=[];
        addEventListener('message',function(event){
          if(event.origin===location.origin && event.source===document.querySelector('#player').contentWindow){
            window.activityMessages.push(event.data);
          }
        });
      </script></body></html>""".replace('FIRST_SN', str(FIRST_SN))

    @running.app.get('/activity-player-harness')
    def parent_page():
        return Response(parent, media_type='text/html')

    with running:
        yield running


@pytest.fixture(scope='module')
def activity_player_browser(chromium_launcher):
    browser = chromium_launcher(
        headless=True, args=['--autoplay-policy=no-user-gesture-required'])
    yield browser
    browser.close()


@pytest.fixture
def activity_player(activity_player_browser, activity_player_server):
    context = activity_player_browser.new_context(
        locale='zh-TW', viewport={'width': 1100, 'height': 800})
    page = context.new_page()
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    origin = urlsplit(activity_player_server.url).netloc

    def local_only(route):
        request_url = urlsplit(route.request.url)
        progress_write = (route.request.method == 'POST' or
                          parse_qs(request_url.query).get('type', [''])[0] in ('set', 'del'))
        if request_url.netloc == origin and request_url.path == '/watch/time' and progress_write:
            # Progress persistence belongs to the existing watch tests. Keep
            # their shared history fixture unchanged when this frame closes.
            route.fulfill(content_type='application/json', body='{"status":"200"}')
        elif request_url.netloc == origin:
            route.continue_()
        else:
            route.abort()

    context.route('**/*', local_only)
    page.goto(activity_player_server.url + '/activity-player-harness')
    page.wait_for_function("""() => {
      const frame=document.querySelector('#player').contentWindow;
      return frame.page?.player?.video.readyState>=2 &&
        window.activityMessages.some(message=>message.type==='agp:activity-ready');
    }""")
    frame = page.frames[1]
    frame.evaluate('window.page.player.video.muted=true')
    page.evaluate('window.activityMessages=[]')
    yield page, frame
    assert errors == []
    context.close()


def snapshot(page, *, host=False, position=1.0, paused=True, rate=1.0,
             revision=1, action=None):
    """Use real postMessage; an optional local action runs 30ms after receipt."""
    state = {
        'sn': str(FIRST_SN), 'position': position, 'paused': paused,
        'rate': rate, 'revision': revision,
    }
    page.evaluate("""({state,host,action}) => {
      const child=document.querySelector('#player').contentWindow;
      if(action){
        function received(event){
          if(event.source!==window || event.data.type!=='agp:activity-state')return;
          child.removeEventListener('message',received);
          const at=child.performance.now();
          child.setTimeout(()=>{
            child.__activityActionDelay=child.performance.now()-at;
            const player=child.page.player;
            if(action==='play'||action==='pause')player.toggle();
            else if(action==='seek'){
              child.__activityBeforeSeek=player.video.currentTime;
              player.nudge(0.8);
              child.__activityAfterSeek=player.video.currentTime;
            }
            else if(action==='rate')player.applySettingRate(1.5);
            else if(action==='next')player.goRelative(1);
          },30);
        }
        child.addEventListener('message',received);
      }
      child.postMessage({type:'agp:activity-state',state,isHost:host},location.origin);
    }""", {'state': state, 'host': host, 'action': action})


def controls(page):
    return page.evaluate("""() => window.activityMessages.filter(message=>
      message.type==='agp:activity-control' && message.action!=='sync')""")


def wait_control(page, action, count=1):
    page.wait_for_function("""({action,count})=>window.activityMessages.filter(
      message=>message.type==='agp:activity-control'&&message.action===action).length>=count
    """, arg={'action': action, 'count': count}, timeout=3000)


def test_initial_paused_snapshot_sets_position_and_rate_without_feedback(activity_player):
    page, frame = activity_player
    assert frame.evaluate('window.page.player.video.paused')
    snapshot(page, position=1.2, rate=1.5)
    frame.wait_for_function("""() => {
      const video=window.page.player.video;
      return video.paused && Math.abs(video.currentTime-1.2)<0.1 && video.playbackRate===1.5;
    }""")
    assert frame.locator('#playerSeek').is_disabled()
    page.wait_for_timeout(200)
    assert controls(page) == []


def test_follower_cannot_pause_seek_or_change_shared_rate(activity_player):
    page, frame = activity_player
    snapshot(page, position=1, paused=False)
    frame.wait_for_function('!window.page.player.video.paused')
    before = frame.evaluate('window.page.player.video.currentTime')
    frame.evaluate("""() => {
      const player=window.page.player;
      player.nudge(2);
      player.applySettingRate(2);
      player.toggle();
    }""")
    page.wait_for_timeout(150)
    assert not frame.evaluate('window.page.player.video.paused')
    assert frame.evaluate('window.page.player.video.playbackRate') == 1
    assert abs(frame.evaluate('window.page.player.video.currentTime') - before) < .8
    assert frame.locator('#playerSeek').is_disabled()
    assert controls(page) == []


def test_host_actions_within_100ms_of_snapshot_are_sent_once(activity_player):
    page, frame = activity_player
    # Programmatic state application must not swallow the first real click.
    snapshot(page, host=True, paused=True, action='play')
    wait_control(page, 'play')
    assert frame.evaluate('window.__activityActionDelay') < 100
    snapshot(page, host=True, paused=False, position=.4, revision=2, action='pause')
    wait_control(page, 'pause')
    assert frame.evaluate('window.__activityActionDelay') < 100
    snapshot(page, host=True, paused=True, position=.4, revision=3, action='seek')
    wait_control(page, 'seek')
    assert frame.evaluate('window.__activityActionDelay') < 100
    snapshot(page, host=True, paused=True, position=1.2, revision=4, action='rate')
    wait_control(page, 'rate')
    assert frame.evaluate('window.__activityActionDelay') < 100
    page.wait_for_timeout(150)
    sent = controls(page)
    assert [message['action'] for message in sent] == ['play', 'pause', 'seek', 'rate']
    before_seek = frame.evaluate('window.__activityBeforeSeek')
    after_seek = frame.evaluate('window.__activityAfterSeek')
    assert after_seek - before_seek == pytest.approx(.8, abs=.05)
    assert sent[2]['position'] == pytest.approx(after_seek, abs=.05)
    assert sent[3]['rate'] == 1.5
    # The server acknowledgement is another applied snapshot, never a command.
    snapshot(page, host=True, paused=True, position=1.2, rate=1.5, revision=5)
    page.wait_for_timeout(200)
    assert controls(page) == sent


def test_disconnect_pauses_and_prevents_local_host_commands(activity_player):
    page, frame = activity_player
    snapshot(page, host=True, paused=False)
    frame.wait_for_function('!window.page.player.video.paused')
    page.evaluate("""() => document.querySelector('#player').contentWindow.postMessage(
      {type:'agp:activity-disconnect'},location.origin)""")
    frame.wait_for_function('window.page.player.video.paused')
    frame.evaluate('window.page.player.toggle(); window.page.player.nudge(1)')
    page.wait_for_timeout(150)
    assert frame.evaluate('window.page.player.video.paused')
    assert frame.locator('#playerSeek').is_disabled()
    assert controls(page) == []


def test_next_episode_is_requested_without_navigating_out_of_activity(activity_player):
    page, frame = activity_player
    before_parent, before_child = page.url, frame.url
    snapshot(page, host=True, action='next')
    wait_control(page, 'select')
    selected = controls(page)
    assert len(selected) == 1
    assert selected[0]['sn'] == str(VIDEO_LIST['videos'][1]['sn'])
    assert page.url == before_parent
    assert frame.url == before_child


def test_guest_player_carries_video_grant_on_media_and_metadata_only(activity_player):
    page, frame = activity_player
    seen = []
    page.on('request', lambda request: seen.append(request.url))
    frame.goto(frame.url + '&ag=guest-test-capability-scoped-to-this-video')
    frame.wait_for_function('window.page?.player?.video.readyState>=2')
    current = frame.evaluate('window.page.player.video.currentSrc')
    query = parse_qs(urlsplit(current).query)
    assert query['id'] == [str(FIRST_SN)]
    assert query['ag'] == ['guest-test-capability-scoped-to-this-video']
    for path in ('/video_list.json', '/watch/series.json', '/get_video.mp4', '/thumbnail.webp'):
        matching = [url for url in seen if urlsplit(url).path == path]
        assert matching, path
        for url in matching:
            query = parse_qs(urlsplit(url).query)
            assert query['id'] == [str(FIRST_SN)]
            assert query['ag'] == ['guest-test-capability-scoped-to-this-video']
    assert frame.evaluate("activityWatchUrl('https://outside.example/video')") == 'https://outside.example/video'
    assert frame.evaluate("activityWatchUrl('./static/js/watch.js')") == './static/js/watch.js'
    assert frame.evaluate("activityWatchUrl('./watch/time?type=set')") == './watch/time?type=set'


def test_activity_fullscreen_uses_parent_messages_and_reflects_parent_state(activity_player):
    page, frame = activity_player
    frame.evaluate("""() => {
      window.nativeFullscreenCalls=0;
      Element.prototype.requestFullscreen=function(){window.nativeFullscreenCalls++;throw Error('native disabled')};
      Element.prototype.webkitRequestFullscreen=function(){window.nativeFullscreenCalls++;throw Error('native disabled')};
      window.page.player.toggleFullscreen();
    }""")
    page.wait_for_function("window.activityMessages.some(message=>message.type==='agp:activity-fullscreen'&&message.expanded===true)")
    assert frame.evaluate('window.nativeFullscreenCalls') == 0
    page.evaluate("""() => document.querySelector('#player').contentWindow.postMessage(
      {type:'agp:activity-fullscreen-state',expanded:true},location.origin)""")
    frame.wait_for_function("document.querySelector('#fullscreenToggle').getAttribute('aria-pressed')==='true'")
    assert frame.locator('#fullscreenToggle').get_attribute('aria-label') == '還原畫面'
    frame.locator('#fullscreenToggle').focus()
    page.keyboard.press('Escape')
    page.wait_for_function("window.activityMessages.some(message=>message.type==='agp:activity-fullscreen'&&message.expanded===false)")
    page.evaluate("""() => document.querySelector('#player').contentWindow.postMessage(
      {type:'agp:activity-fullscreen-state',expanded:false},location.origin)""")
    frame.wait_for_function("document.querySelector('#fullscreenToggle').getAttribute('aria-pressed')==='false'")
    assert frame.evaluate('window.nativeFullscreenCalls') == 0


def test_activity_playback_metadata_has_flutter_template_fields_without_capability(activity_player):
    page, frame = activity_player
    frame.goto(frame.url + '&ag=guest-test-capability-scoped-to-this-video')
    frame.wait_for_function('window.page?.player?.video.readyState>=2')
    page.wait_for_function("window.activityMessages.some(message=>message.type==='agp:activity-playback'&&message.duration>0)")
    metadata = page.evaluate("window.activityMessages.filter(message=>message.type==='agp:activity-playback'&&message.duration>0).at(-1)")
    assert metadata['sn'] == str(FIRST_SN)
    assert metadata['title'] and metadata['episode']
    assert isinstance(metadata['paused'], bool)
    assert metadata['rate'] == 1
    assert 'guest-test-capability' not in str(metadata)


@pytest.mark.parametrize('width', [900, 390])
def test_player_fits_activity_frame_without_inner_scrolling(activity_player, width):
    page, frame = activity_player
    page.set_viewport_size({'width': width, 'height': 800})
    snapshot(page, host=True)
    frame.wait_for_function('window.page.player.seek.disabled===false')
    frame.evaluate('window.page.player.showControls()')
    layout = frame.evaluate("""() => ({
      viewport:innerHeight,
      scrollHeight:document.documentElement.scrollHeight,
      controlsBottom:document.querySelector('.desktop-player-controls').getBoundingClientRect().bottom,
      shellBottom:document.querySelector('#playerShell').getBoundingClientRect().bottom,
      headerVisible:getComputedStyle(document.querySelector('.agp-topbar')).display!=='none'
    })""")
    assert not layout['headerVisible']
    assert layout['controlsBottom'] <= layout['viewport'] + 1
    assert layout['shellBottom'] <= layout['viewport'] + 1
    assert layout['scrollHeight'] <= layout['viewport'] + 1, layout


@pytest.mark.parametrize('width,height', [(200, 200), (240, 240), (320, 240), (390, 220)])
def test_actual_player_controls_fit_discord_mobile_square_and_survive_restore(activity_player, width, height):
    page, frame = activity_player
    snapshot(page, host=True, position=5)
    frame.wait_for_function('Math.abs(window.page.player.video.currentTime-5)<.1')
    frame.evaluate('window.savedVideo=window.page.player.video')
    page.evaluate("""() => {
      const stage=document.querySelector('#stage');
      stage.style.cssText='width:100vw;height:100vh;aspect-ratio:auto';
    }""")
    page.set_viewport_size({'width': width, 'height': height})
    frame.evaluate('window.page.player.showControls()')
    layout = frame.evaluate("""() => {
      const rect=document.querySelector('#playerShell').getBoundingClientRect();
      const controls=['#playToggle','#settingsToggle','#fullscreenToggle'].map(id=>{
        const el=document.querySelector(id);const box=el.getBoundingClientRect();
        return {width:box.width,left:box.left,right:box.right,top:box.top,bottom:box.bottom};
      });
      return {width:innerWidth,height:innerHeight,scrollWidth:document.documentElement.scrollWidth,
        scrollHeight:document.documentElement.scrollHeight,playerWidth:rect.width,playerHeight:rect.height,controls};
    }""")
    assert layout['width'] == layout['playerWidth'] == layout['scrollWidth'] == width
    assert layout['height'] == layout['playerHeight'] == layout['scrollHeight'] == height
    for button in layout['controls']:
        assert button['width'] >= 30
        assert 0 <= button['left'] < button['right'] <= width
        assert 0 <= button['top'] < button['bottom'] <= height
    assert frame.evaluate('window.page.player.video===window.savedVideo')
    assert frame.evaluate('window.page.player.video.currentTime') == pytest.approx(5, abs=.1)
    page.set_viewport_size({'width': 390, 'height': 844})
    assert frame.evaluate('window.page.player.video===window.savedVideo')
    assert frame.evaluate('document.documentElement.scrollWidth===innerWidth')
    assert frame.evaluate('document.documentElement.scrollHeight===innerHeight')
