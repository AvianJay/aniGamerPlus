"""Discord Activity identity and authoritative watch rooms.

Credentials are read from dashboard.discord_activity in config.json. State is
process local: run the Dashboard with one ASGI worker. Discord identities are
verified using OAuth and room membership using the application's Bot token.
"""
import math
import re
import secrets
import threading
import time

import requests
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

COOKIE_NAME = '__Secure-agp_activity'
SESSION_TTL = 6 * 60 * 60
GUEST_GRANT_TTL = 2 * 60 * 60
MEMBER_LEASE = 20
MEMBERSHIP_TTL = 5
MAX_SESSIONS = 4096
MAX_ROOMS = 256
API = 'https://discord.com/api/v10'
INSTANCE_PATTERN = re.compile(r'^[A-Za-z0-9_-]{1,256}$')


class ActivityError(Exception):
    def __init__(self, status, error, message):
        self.status, self.error, self.message = status, error, message


def _response(data, status=200):
    return JSONResponse(data, status_code=status, headers={'Cache-Control': 'no-store'})


def _now():
    return time.time()


class ActivityBackend:
    cookie_name = COOKIE_NAME

    def __init__(self, server):
        self.server = server
        self.lock = threading.RLock()
        self.membership_fill_lock = threading.Lock()
        self.sessions = {}
        self.rooms = {}
        self.memberships = {}
        self.login_attempts = {}

    def config(self):
        activity = self.server._get_current_settings().get('dashboard', {}).get('discord_activity', {})
        if not isinstance(activity, dict):
            activity = {}
        config = {}
        for name in ('client_id', 'client_secret', 'bot_token'):
            value = activity.get(name, '')
            if name == 'client_id' and isinstance(value, int) and not isinstance(value, bool):
                value = str(value)
            config[name] = value.strip() if isinstance(value, str) else ''
        return config

    def _settings(self):
        settings = self.server._get_current_settings()
        dashboard = settings.get('dashboard', {})
        if not dashboard.get('online_watch'):
            raise ActivityError(404, 'watch_disabled', '線上觀看尚未啟用。')
        return dashboard

    def _configured(self):
        config = self.config()
        if not all(config.values()) or not config['client_id'].isdigit():
            raise ActivityError(503, 'not_configured', '管理員尚未完成 Discord Activity 設定。')
        return config

    def _session(self, request, *, csrf=False, discord=False):
        sid = request.cookies.get(COOKIE_NAME)
        with self.lock:
            session = self.sessions.get(sid)
            if not session or session['expires'] <= _now():
                self.sessions.pop(sid, None)
                raise ActivityError(401, 'session_expired', '連線已過期，請重新開啟 Activity。')
            if csrf and not secrets.compare_digest(
                    request.headers.get('X-Activity-CSRF', ''), session['csrf_token']):
                raise ActivityError(403, 'invalid_csrf', '請重新開啟 Activity 後再試。')
            if discord and not session.get('user'):
                raise ActivityError(401, 'discord_required', '請先授權 Discord 帳號。')
            return sid, session

    def _account(self, session):
        if not session.get('local_token'):
            return None
        dashboard = self._settings()
        if not dashboard.get('user_control', {}).get('enabled'):
            return None
        user = self.server.find_user_by_token(session['local_token'])
        if not user:
            return None
        if session.get('linked_login') and user.get('discord_account', {}).get('id') != session['user']['id']:
            return None
        return user

    def _identity(self, session):
        dashboard = self._settings()
        account = self._account(session)
        linked = bool(account and account.get('discord_account', {}).get('id') == session.get('user', {}).get('id'))
        return {'csrf_token': session['csrf_token'], 'user': session.get('user'),
                'account': self.server._build_safe_user(account), 'linked': linked,
                'requires_login': bool(dashboard.get('online_watch_requires_login'))}

    def _require_viewer(self, session):
        dashboard = self._settings()
        if dashboard.get('online_watch_requires_login') and self._account(session) is None:
            raise ActivityError(403, 'login_required', '此伺服器要求登入網站帳號才能觀看。')

    def _invalidate_session_grants(self, sid):
        """Revocation is permanent, even if the same session logs in again."""
        with self.lock:
            for room in self.rooms.values():
                changed = False
                if room.get('auto_grant_issuer', {}).get('sid') == sid:
                    changed = self._clear_auto_grant(room)
                for uid, grant in list(room['grants'].items()):
                    if grant['issuer_sid'] == sid:
                        room['grants'].pop(uid, None)
                        changed = True
                    elif sid in grant['recipient_sessions']:
                        grant['recipient_sessions'].discard(sid)
                        changed = True
                        if not grant['recipient_sessions']:
                            room['grants'].pop(uid, None)
                if changed:
                    room['revision'] += 1

    def _discord_request(self, method, path, *, headers=None, data=None):
        """Never expose upstream bodies, tokens or exception messages to clients/logs."""
        try:
            response = requests.request(method, API + path, headers=headers, data=data,
                                        timeout=(5, 10))
            if response.status_code == 404:
                raise ActivityError(403, 'invalid_instance', '這個 Discord 一起看房間已結束。')
            if response.status_code == 429:
                raise ActivityError(503, 'discord_busy', 'Discord 暫時忙碌，請稍後重試。')
            if not 200 <= response.status_code < 300:
                raise ActivityError(502, 'discord_failed', 'Discord 驗證失敗，請稍後重試。')
            payload = response.json()
            if not isinstance(payload, dict):
                raise ValueError()
            return payload
        except ActivityError:
            raise
        except Exception:
            raise ActivityError(502, 'discord_unavailable', '目前無法連線至 Discord。') from None

    def _membership(self, session, instance_id, *, force=False):
        if not isinstance(instance_id, str) or not INSTANCE_PATTERN.fullmatch(instance_id):
            raise ActivityError(400, 'invalid_instance', '房間識別碼無效。')
        config = self._configured()
        # Serialize upstream cache fills without holding the sessions/rooms lock
        # across network I/O. Cached rooms and account operations remain usable.
        with self.lock:
            cached = self.memberships.get(instance_id)
        if force or not cached or cached[0] + MEMBERSHIP_TTL <= _now():
            with self.membership_fill_lock:
                with self.lock:
                    cached = self.memberships.get(instance_id)
                if not force and cached and cached[0] + MEMBERSHIP_TTL > _now():
                    if session['user']['id'] not in cached[1]:
                        raise ActivityError(403, 'not_a_participant', '請先加入這個 Discord 語音頻道中的 Activity。')
                    return cached[1]
                payload = self._discord_request('GET', '/applications/%s/activity-instances/%s' % (
                    config['client_id'], instance_id), headers={'Authorization': 'Bot ' + config['bot_token']})
                if payload.get('application_id') != config['client_id'] or payload.get('instance_id') != instance_id:
                    raise ActivityError(403, 'invalid_instance', 'Discord 房間驗證失敗。')
                users = payload.get('users')
                if not isinstance(users, list) or not all(isinstance(user, str) for user in users):
                    raise ActivityError(502, 'discord_failed', 'Discord 房間資料無效。')
                cached = (_now(), set(users))
                with self.lock:
                    self.memberships[instance_id] = cached
        if session['user']['id'] not in cached[1]:
            raise ActivityError(403, 'not_a_participant', '請先加入這個 Discord 語音頻道中的 Activity。')
        return cached[1]

    def auth_user(self, request):
        """For the existing watch API's internal cookie bridge, never a login route."""
        try:
            _, session = self._session(request, discord=True)
            with session['operation_lock']:
                self._session(request, discord=True)
                if not session.get('instance_id'):
                    return None
                self._require_viewer(session)
                self._membership(session, session['instance_id'])
                return self._account(session)
        except ActivityError:
            return None

    def guest_access(self, request):
        """Resolve an opaque capability for one episode and one Discord session.

        This deliberately returns no local account or website authentication
        token. The caller must separately restrict its route and response data.
        """
        token = request.query_params.get('ag')
        sn = request.query_params.get('id')
        if not isinstance(token, str) or not 20 <= len(token) <= 128 or not sn:
            return None
        try:
            self._settings()
            sid, session = self._session(request, discord=True)
            with session['operation_lock']:
                self._session(request, discord=True)
                instance_id = session.get('instance_id')
                if not instance_id:
                    return None
                users = self._membership(session, instance_id)
                with self.lock:
                    room = self.rooms.get(instance_id)
                    if room is None:
                        return None
                    now = _now()
                    self._prune_room(room, now, users)
                    uid = session['user']['id']
                    grant = room['grants'].get(uid)
                    if (not self._valid_grant(room, uid, grant, now, sid=sid) or
                            str(sn) != grant['sn'] or not secrets.compare_digest(token, grant['token'])):
                        return None
                    return {'sn': grant['sn'], 'instance_id': instance_id,
                            'user_id': uid, 'expires': grant['expires']}
        except ActivityError:
            return None

    def public_config(self, request):
        dashboard = self._settings()
        config = self.config()
        try:
            _, session = self._session(request)
            response = _response({
                'client_id': config['client_id'], 'configured': all(config.values()) and config['client_id'].isdigit(),
                'requires_login': bool(dashboard.get('online_watch_requires_login')),
                'accounts_enabled': bool(dashboard.get('user_control', {}).get('enabled')),
                'csrf_token': session['csrf_token']})
        except ActivityError:
            now = _now()
            with self.lock:
                self._prune(now)
                if len(self.sessions) >= MAX_SESSIONS:
                    raise ActivityError(503, 'server_busy', '一起看服務暫時已滿，請稍後重試。')
                sid = secrets.token_urlsafe(32)
                session = {'csrf_token': secrets.token_urlsafe(32), 'expires': now + SESSION_TTL,
                           'operation_lock': threading.RLock()}
                self.sessions[sid] = session
            response = _response({
                'client_id': config['client_id'], 'configured': all(config.values()) and config['client_id'].isdigit(),
                'requires_login': bool(dashboard.get('online_watch_requires_login')),
                'accounts_enabled': bool(dashboard.get('user_control', {}).get('enabled')),
                'csrf_token': session['csrf_token']})
            response.set_cookie(COOKIE_NAME, sid, max_age=SESSION_TTL, secure=True,
                                httponly=True, samesite='none', path='/')
            response.headers['set-cookie'] += '; Partitioned'
        return response

    def exchange_token(self, session, body, *, sid=None):
        config = self._configured()
        code = body.get('code')
        if not isinstance(code, str) or not 1 <= len(code) <= 4096:
            raise ActivityError(400, 'invalid_code', 'Discord 授權碼無效。')
        token = self._discord_request('POST', '/oauth2/token', data={
            'client_id': config['client_id'], 'client_secret': config['client_secret'],
            'grant_type': 'authorization_code', 'code': code})
        access_token = token.get('access_token')
        if not isinstance(access_token, str) or not access_token:
            raise ActivityError(502, 'discord_failed', 'Discord 未回傳授權資料。')
        user = self._discord_request('GET', '/users/@me', headers={'Authorization': 'Bearer ' + access_token})
        if not isinstance(user.get('id'), str) or not user['id'].isdigit():
            raise ActivityError(502, 'discord_failed', 'Discord 帳號資料無效。')
        if sid is not None:
            self._invalidate_session_grants(sid)
        session['user'] = {key: user.get(key) for key in ('id', 'username', 'global_name')}
        session.pop('local_token', None)
        session.pop('instance_id', None)
        session['linked_login'] = False
        try:
            expiry = min(SESSION_TTL, max(1, int(token.get('expires_in', SESSION_TTL))))
        except (ValueError, TypeError):
            raise ActivityError(502, 'discord_failed', 'Discord 授權期限無效。') from None
        session['expires'] = _now() + expiry
        if self._settings().get('user_control', {}).get('enabled'):
            matches = [local for local in self.server.load_user_data()['users']
                       if local.get('discord_account', {}).get('id') == user['id']]
            if len(matches) == 1:
                session['local_token'] = matches[0]['token']
                session['linked_login'] = True
        result = self._identity(session)
        result['access_token'] = access_token  # Needed only by SDK.authenticate; never persist it.
        return result

    def login(self, sid, session, body):
        if not self._settings().get('user_control', {}).get('enabled'):
            raise ActivityError(404, 'accounts_disabled', '帳號功能尚未啟用。')
        username, password = body.get('username'), body.get('password')
        if not isinstance(username, str) or not 1 <= len(username) <= 128 or not isinstance(password, str) or len(password) > 1024:
            raise ActivityError(400, 'invalid_login', '請輸入帳號與密碼。')
        now = _now()
        # Per Discord identity rather than session: reopening cannot evade throttling.
        key = session['user']['id']
        with self.lock:
            attempts = [at for at in self.login_attempts.get(key, []) if at > now - 60]
            if len(attempts) >= 8:
                raise ActivityError(429, 'login_limited', '登入嘗試過於頻繁，請一分鐘後再試。')
            self.login_attempts[key] = attempts + [now]
        account = self.server.find_user_by_username(username)
        if not account or not self.server._verify_password(account, password):
            raise ActivityError(401, 'invalid_login', '帳號或密碼不正確。')
        # A password reset racing verification must not authenticate the new token.
        fresh = self.server.find_user_by_token(account.get('token'))
        if not fresh:
            raise ActivityError(401, 'invalid_login', '帳號狀態已變更，請重新登入。')
        with self.lock:
            self._invalidate_session_grants(sid)
            session['local_token'] = fresh['token']
            session['linked_login'] = False
            self.login_attempts.pop(key, None)
        return self._identity(session)

    def presence_token(self, session, body):
        """Upgrade only the SDK token, keeping the existing viewing identity."""
        config = self._configured()
        code = body.get('code')
        if not isinstance(code, str) or not 1 <= len(code) <= 4096:
            raise ActivityError(400, 'invalid_code', 'Discord 授權碼無效。')
        token = self._discord_request('POST', '/oauth2/token', data={
            'client_id': config['client_id'], 'client_secret': config['client_secret'],
            'grant_type': 'authorization_code', 'code': code})
        access_token = token.get('access_token')
        if not isinstance(access_token, str) or not access_token:
            raise ActivityError(502, 'discord_failed', 'Discord 未回傳授權資料。')
        scope = token.get('scope')
        if not isinstance(scope, str) or not {'identify', 'rpc.activities.write'} <= set(scope.split()):
            raise ActivityError(403, 'presence_scope_required', '請允許 Discord 播放動態權限。')
        user = self._discord_request('GET', '/users/@me', headers={'Authorization': 'Bearer ' + access_token})
        if user.get('id') != session['user']['id']:
            raise ActivityError(403, 'discord_identity_mismatch', '請使用目前 Activity 的 Discord 帳號授權。')
        return {'access_token': access_token}

    def link(self, session, *, unlink=False):
        account = self._account(session)
        if account is None:
            raise ActivityError(401, 'login_required', '請先登入要綁定的網站帳號。')
        discord = session['user']
        def mutate(data):
            fresh = self.server.find_user_by_token(account['token'], data)
            if fresh is None:
                raise ActivityError(401, 'login_required', '請重新登入網站帳號。')
            if unlink:
                if fresh.get('discord_account', {}).get('id') != discord['id']:
                    raise ActivityError(409, 'different_account', '此網站帳號綁定了另一個 Discord 帳號。')
                fresh.pop('discord_account', None)
            else:
                if any(user.get('discord_account', {}).get('id') == discord['id'] and user['token'] != fresh['token']
                       for user in data['users']):
                    raise ActivityError(409, 'already_linked', '此 Discord 帳號已綁定其他網站帳號。')
                previous = fresh.get('discord_account', {}).get('id')
                if previous and previous != discord['id']:
                    raise ActivityError(409, 'different_account', '此網站帳號已綁定另一個 Discord 帳號。')
                fresh['discord_account'] = {'id': discord['id'], 'username': discord.get('username', '')}
            return None, True
        self.server.update_user_data(mutate)
        with self.lock:
            if unlink:
                for other_sid, other in self.sessions.items():
                    if other.get('user', {}).get('id') == discord['id']:
                        self._invalidate_session_grants(other_sid)
                        other.pop('local_token', None)
                        other['linked_login'] = False
            else:
                session['linked_login'] = True
        return self._identity(session)

    def _prune(self, now):
        self.sessions = {sid: session for sid, session in self.sessions.items() if session['expires'] > now}
        self.memberships = {key: value for key, value in self.memberships.items() if value[0] + 60 > now}
        self.login_attempts = {key: [at for at in value if at > now - 60]
                               for key, value in self.login_attempts.items() if value and value[-1] > now - 60}
        for key, room in list(self.rooms.items()):
            self._prune_room(room, now)
            if not room['members'] and room['last_active'] + 60 <= now:
                self.rooms.pop(key, None)

    def _prune_room(self, room, now, verified_users=None):
        old = list(room['members'])
        old_host = room['host_id']
        old_logged_in = {uid: member.get('logged_in') for uid, member in room['members'].items()}
        requires_login = bool(self._settings().get('online_watch_requires_login'))
        for uid, member in list(room['members'].items()):
            member['sessions'] = {sid: seen for sid, seen in member['sessions'].items()
                                  if seen + MEMBER_LEASE > now and sid in self.sessions
                                  and self.sessions[sid]['expires'] > now
                                  and self.sessions[sid].get('user', {}).get('id') == uid
                                  and self.sessions[sid].get('instance_id') == room['instance_id']}
            if not member['sessions'] or (verified_users is not None and uid not in verified_users):
                room['members'].pop(uid, None)
                continue
            member['logged_in'] = any(self._account(self.sessions[sid]) is not None for sid in member['sessions'])
        eligible = [uid for uid, member in room['members'].items() if not requires_login or member['logged_in']]
        if room['host_id'] not in eligible:
            room['host_id'] = next(iter(eligible), None)
        if old_host != room['host_id']:
            room['grants'].clear()
            self._clear_auto_grant(room)
        auto_changed = False
        if room.get('auto_grant') and self._auto_grant_authority(room, now) is None:
            auto_changed = self._clear_auto_grant(room)
        removed_grants = []
        for uid, grant in list(room['grants'].items()):
            if not self._valid_grant(room, uid, grant, now):
                room['grants'].pop(uid, None)
                removed_grants.append(uid)
        auto_changed = self._apply_auto_grants(room, now) or auto_changed
        if (old != list(room['members']) or old_host != room['host_id'] or removed_grants or auto_changed or
                old_logged_in != {uid: member.get('logged_in') for uid, member in room['members'].items()}):
            room['revision'] += 1

    def _clear_auto_grant(self, room, *, clear_blocked=True):
        changed = bool(room.get('auto_grant'))
        room['auto_grant'] = False
        room['auto_grant_issuer'] = {}
        if clear_blocked:
            room['auto_grant_blocked'] = set()
        for uid, grant in list(room['grants'].items()):
            if grant.get('automatic'):
                room['grants'].pop(uid, None)
                changed = True
            elif grant.get('auto_recipient_sessions'):
                grant['recipient_sessions'].difference_update(grant.pop('auto_recipient_sessions'))
                changed = True
        return changed

    def _auto_grant_authority(self, room, now):
        authority = room.get('auto_grant_issuer')
        if not room.get('auto_grant') or not authority:
            return None
        issuer = self.sessions.get(authority['sid'])
        host = room['members'].get(room['host_id'])
        if (not issuer or issuer['expires'] <= now or not host or
                authority['sid'] not in host['sessions'] or
                issuer.get('instance_id') != room['instance_id'] or
                issuer.get('user', {}).get('id') != room['host_id'] or
                issuer.get('local_token') != authority['token']):
            return None
        account = self._account(issuer)
        return (authority['sid'], issuer, account) if account and account['token'] == authority['token'] else None

    def _apply_auto_grants(self, room, now):
        authority = self._auto_grant_authority(room, now)
        if authority is None or not room['sn']:
            return False
        issuer_sid, issuer, account = authority
        changed = False
        for uid, member in room['members'].items():
            if uid == room['host_id'] or uid in room['auto_grant_blocked']:
                continue
            recipients = {sid for sid in member['sessions'] if self._account(self.sessions[sid]) is None}
            if not recipients:
                continue
            grant = room['grants'].get(uid)
            if grant:
                new_sessions = recipients - grant['recipient_sessions']
                if new_sessions:
                    grant['recipient_sessions'].update(new_sessions)
                    if not grant.get('automatic'):
                        grant.setdefault('auto_recipient_sessions', set()).update(new_sessions)
                    changed = True
                continue
            room['grants'][uid] = self._new_grant(room, issuer_sid, issuer, account, recipients, now,
                                                 automatic=True)
            changed = True
        return changed

    def _new_grant(self, room, sid, session, account, recipients, now, *, automatic=False):
        return {'token': secrets.token_urlsafe(32), 'sn': room['sn'],
                'issuer_sid': sid, 'issuer_id': session['user']['id'], 'issuer_token': account['token'],
                'recipient_sessions': set(recipients), 'automatic': automatic,
                'expires': min(now + GUEST_GRANT_TTL, session['expires'])}

    def _set_auto_grant(self, room, sid, session, body):
        if room['host_id'] != session['user']['id']:
            raise ActivityError(403, 'host_required', '只有主控者可以設定自動授權。')
        account = self._account(session)
        if account is None:
            raise ActivityError(403, 'login_required', '主控者必須登入網站帳號才能授權訪客。')
        enabled = body.get('enabled')
        if not isinstance(enabled, bool):
            raise ActivityError(400, 'invalid_auto_grant', '請指定是否啟用自動授權。')
        if enabled:
            issuer = {'sid': sid, 'token': account['token']}
            if not room['auto_grant'] or room['auto_grant_issuer'] != issuer:
                self._clear_auto_grant(room, clear_blocked=False)
                room['auto_grant'] = True
                room['auto_grant_issuer'] = issuer
                room['revision'] += 1
        elif self._clear_auto_grant(room, clear_blocked=False):
            room['revision'] += 1

    def _valid_grant(self, room, uid, grant, now, *, sid=None):
        if not grant or grant['expires'] <= now or grant['sn'] != room['sn']:
            return False
        if grant['issuer_id'] != room['host_id'] or uid not in room['members']:
            return False
        recipient_sessions = room['members'][uid]['sessions']
        if sid is not None and (sid not in recipient_sessions or sid not in grant['recipient_sessions']):
            return False
        if not any(recipient in recipient_sessions for recipient in grant['recipient_sessions']):
            return False
        issuer = self.sessions.get(grant['issuer_sid'])
        host = room['members'].get(grant['issuer_id'])
        if (not issuer or issuer['expires'] <= now or not host or
                grant['issuer_sid'] not in host['sessions'] or
                issuer.get('instance_id') != room['instance_id'] or
                issuer.get('local_token') != grant['issuer_token']):
            return False
        account = self._account(issuer)
        return bool(account and account['token'] == grant['issuer_token'])

    def room_action(self, sid, session, action, body):
        instance_id = body.get('instance_id')
        users = self._membership(session, instance_id, force=action == 'join')
        now, uid = _now(), session['user']['id']
        with self.lock:
            self._prune(now)
            room = self.rooms.get(instance_id)
            if action == 'join':
                if room is None:
                    if len(self.rooms) >= MAX_ROOMS:
                        raise ActivityError(503, 'server_busy', '一起看房間暫時已滿。')
                    room = {'instance_id': instance_id, 'host_id': None, 'members': {}, 'sn': None,
                            'position': 0.0, 'paused': True, 'rate': 1.0,
                            'updated_at': now, 'last_active': now, 'revision': 0, 'grants': {},
                            'auto_grant': False, 'auto_grant_issuer': {}, 'auto_grant_blocked': set()}
                    self.rooms[instance_id] = room
                old_instance = session.get('instance_id')
                if old_instance and old_instance != instance_id and old_instance in self.rooms:
                    self._remove_member(self.rooms[old_instance], sid, uid, now)
                self._prune_room(room, now, users)
                if uid not in room['members']:
                    room['members'][uid] = {'id': uid, 'name': session['user'].get('global_name') or session['user'].get('username') or uid,
                                            'sessions': {}}
                    room['revision'] += 1
                room['members'][uid]['sessions'][sid] = now
                session['instance_id'] = instance_id
                self._prune_room(room, now, users)
            else:
                if room is None or session.get('instance_id') != instance_id:
                    raise ActivityError(409, 'join_required', '請重新加入一起看房間。')
                self._prune_room(room, now, users)
                if uid not in room['members'] or sid not in room['members'][uid]['sessions']:
                    raise ActivityError(409, 'join_required', '連線已中斷，請重新加入一起看房間。')
                room['members'][uid]['sessions'][sid] = now
            room['last_active'] = now
            if action == 'leave':
                self._remove_member(room, sid, uid, now)
                session.pop('instance_id', None)
            elif action == 'control':
                self._require_viewer(session)
                if room['host_id'] != uid:
                    raise ActivityError(403, 'host_required', '只有主控者可以控制播放。')
                self._control(room, body, now)
            elif action in ('grant', 'revoke'):
                self._guest_grant(room, sid, session, body, now, revoke=action == 'revoke')
            elif action == 'auto-grant':
                self._set_auto_grant(room, sid, session, body)
            if self._apply_auto_grants(room, now):
                room['revision'] += 1
            return self._snapshot(room, uid, now, sid=sid)

    def _guest_grant(self, room, sid, session, body, now, *, revoke=False):
        uid = session['user']['id']
        if room['host_id'] != uid:
            raise ActivityError(403, 'host_required', '只有主控者可以授權訪客觀看。')
        account = self._account(session)
        if account is None:
            raise ActivityError(403, 'login_required', '主控者必須登入網站帳號才能授權訪客。')
        sn = body.get('sn')
        if not isinstance(sn, str) or not sn:
            raise ActivityError(400, 'invalid_video', '請指定目前播放的影片。')
        if sn != room['sn']:
            raise ActivityError(409, 'stale_video', '影片已切換，請重新授權目前影片。')
        target = body.get('user_id')
        if not isinstance(target, str) or target not in room['members'] or target == uid:
            raise ActivityError(404, 'participant_required', '請選擇目前 Activity 中的其他觀眾。')
        if revoke:
            room['grants'].pop(target, None)
            if room['auto_grant']:
                room['auto_grant_blocked'].add(target)
        else:
            room['auto_grant_blocked'].discard(target)
            room['grants'][target] = self._new_grant(room, sid, session, account,
                                                   room['members'][target]['sessions'], now)
        room['revision'] += 1

    def _remove_member(self, room, sid, uid, now):
        member = room['members'].get(uid)
        if member:
            member['sessions'].pop(sid, None)
        self._prune_room(room, now)

    def _control(self, room, body, now):
        action = body.get('action')
        if action not in ('select', 'play', 'pause', 'seek', 'rate', 'sync'):
            raise ActivityError(400, 'invalid_action', '播放操作無效。')
        if action != 'select' and 'expected_sn' in body and str(body['expected_sn']) != room['sn']:
            raise ActivityError(409, 'stale_video', '主控已切換影片，請等待播放器同步。')
        if action == 'select':
            sn = body.get('sn')
            if not isinstance(sn, (str, int)) or isinstance(sn, bool) or not 1 <= len(str(sn)) <= 128:
                raise ActivityError(400, 'invalid_video', '請選擇片庫中的影片。')
            if not self.server._find_video_entry(str(sn)):
                raise ActivityError(404, 'video_not_found', '片庫中找不到這部影片。')
            # A host's preceding player snapshot may accompany selection. Never
            # carry that episode's time, rate or playback state into the new one.
            room.update(sn=str(sn), position=0.0, paused=True, rate=1.0,
                        updated_at=now, revision=room['revision'] + 1)
            room['grants'].clear()
            room['auto_grant_blocked'].clear()
            return
        values = {}
        for field, lower, upper in (('position', 0, 7 * 24 * 3600), ('rate', 0.25, 4)):
            if field in body:
                value = body[field]
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not lower <= value <= upper:
                    raise ActivityError(400, 'invalid_playback', '播放時間或速度無效。')
                values[field] = float(value)
        if 'paused' in body and not isinstance(body['paused'], bool):
            raise ActivityError(400, 'invalid_playback', '播放狀態無效。')
        if room['sn'] is None:
            raise ActivityError(409, 'video_required', '請先選擇影片。')
        elif action == 'seek' and 'position' not in values:
            raise ActivityError(400, 'invalid_playback', '缺少播放時間。')
        elif action == 'rate' and 'rate' not in values:
            raise ActivityError(400, 'invalid_playback', '缺少播放速度。')
        if not room['paused']:
            room['position'] = min(7 * 24 * 3600, room['position'] + max(0, now - room['updated_at']) * room['rate'])
        room.update(values)
        if action == 'play':
            room['paused'] = False
        elif action == 'pause':
            room['paused'] = True
        elif action == 'sync' and 'paused' in body:
            room['paused'] = body['paused']
        room['updated_at'] = now
        room['revision'] += 1

    def _snapshot(self, room, uid, now, *, sid=None):
        result = {key: room[key] for key in ('instance_id', 'host_id', 'sn', 'position', 'paused', 'rate', 'updated_at', 'revision')}
        requires_login = bool(self._settings().get('online_watch_requires_login'))
        own_session = self.sessions.get(sid)
        own_account = self._account(own_session) if own_session else None
        grant = room['grants'].get(uid)
        valid_grant = self._valid_grant(room, uid, grant, now, sid=sid)
        can_watch = not requires_login or own_account is not None or valid_grant
        members = []
        for member in room['members'].values():
            member_grant = room['grants'].get(member['id'])
            authorized = (not requires_login or member.get('logged_in', False) or
                          self._valid_grant(room, member['id'], member_grant, now))
            members.append({'id': member['id'], 'name': member['name'],
                            'logged_in': member.get('logged_in', False),
                            'is_guest': not member.get('logged_in', False),
                            'requires_approval': requires_login and not authorized,
                            'authorized': authorized,
                            'grant_expires_at': member_grant['expires'] if member_grant else None})
        result.update(server_time=now, is_host=uid == room['host_id'] and (not requires_login or own_account is not None),
                      members=members, can_watch=can_watch,
                      auto_grant=room['auto_grant'],
                      auto_grant_available=uid == room['host_id'] and own_account is not None,
                      watch_token=grant['token'] if valid_grant and own_account is None else None,
                      grant_expires_at=grant['expires'] if valid_grant else None)
        return result

    def dispatch(self, request, action, body=None):
        try:
            self._settings()
            if action == 'config':
                return self.public_config(request)
            sid, session = self._session(request, csrf=request.method == 'POST', discord=action != 'token')
            # A session's OAuth, password login, binding and room selection
            # cannot interleave with one another or a media bridge read.
            with session['operation_lock']:
                self._session(request, csrf=request.method == 'POST', discord=action != 'token')
                return self._dispatch_session(request, action, body, sid, session)
        except ActivityError as error:
            return _response({'error': error.error, 'message': error.message}, error.status)

    def _dispatch_session(self, request, action, body, sid, session):
        try:
            if action == 'token':
                result = self.exchange_token(session, body, sid=sid)
            elif action == 'me':
                result = self._identity(session)
            elif action == 'login':
                result = self.login(sid, session, body)
            elif action == 'presence-token':
                result = self.presence_token(session, body)
            elif action in ('link', 'unlink'):
                result = self.link(session, unlink=action == 'unlink')
            elif action == 'logout':
                self._invalidate_session_grants(sid)
                session.pop('local_token', None)
                session['linked_login'] = False
                result = self._identity(session)
            else:
                result = self.room_action(sid, session, action, body)
            return _response(result)
        except ActivityError as error:
            return _response({'error': error.error, 'message': error.message}, error.status)


def install(server):
    """Register routes and return the identity bridge used by Server.py."""
    backend = ActivityBackend(server)

    def page(request: Request):
        try:
            backend._settings()
        except ActivityError as error:
            return _response({'error': error.error, 'message': error.message}, error.status)
        response = server._render(request, 'discord_activity.html')
        response.headers['Cache-Control'] = 'no-store'
        return response

    server.app.add_api_route('/discord/activity', page, methods=['GET'])
    for action in ('config', 'me', 'state', 'token', 'presence-token', 'login', 'link', 'unlink', 'logout', 'join', 'control', 'leave', 'grant', 'revoke', 'auto-grant'):
        def make_endpoint(action):
            async def endpoint(request: Request):
                if request.method == 'GET':
                    return await run_in_threadpool(backend.dispatch, request, action, dict(request.query_params))
                # Session/CSRF guards run before buffering or interpreting a body.
                try:
                    await run_in_threadpool(backend._settings)
                    await run_in_threadpool(backend._session, request, csrf=True, discord=action != 'token')
                except ActivityError as error:
                    return _response({'error': error.error, 'message': error.message}, error.status)
                raw = await request.body()
                if len(raw) > 16 * 1024:
                    return _response({'error': 'body_too_large', 'message': '請求資料過大。'}, 413)
                try:
                    body = await request.json() if raw else {}
                except Exception:
                    return _response({'error': 'invalid_json', 'message': '請求格式無效。'}, 400)
                if not isinstance(body, dict):
                    return _response({'error': 'invalid_json', 'message': '請求格式無效。'}, 400)
                return await run_in_threadpool(backend.dispatch, request, action, body)
            return endpoint
        server.app.add_api_route('/discord/activity/' + action, make_endpoint(action),
                                 methods=['GET'] if action in ('config', 'me', 'state') else ['POST'],
                                 name='discord_activity_' + action)
    return backend
