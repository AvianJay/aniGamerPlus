/// 掃碼設定: 在這台裝置上開一台只活在設定畫面裡的小伺服器, 同一個網路裡的手機
/// 掃 QR 碼打開它的網頁, 在手機上把伺服器位址 (跟帳號) 填好送過來.
///
/// 給電視用的 —— 用遙控器在螢幕鍵盤上一格一格敲 http://192.168.1.10:5000
/// 跟帳號密碼, 敲錯一個字又要重來. 手機本來就在手上, 相機一掃就是瀏覽器.
///
/// 這台伺服器只聽一個隨機路徑 (QR 碼裡帶著), 設定畫面一關或設定完成就收掉.
/// 不需要手機上裝這個 App: 送來的欄位由這一邊自己去連線驗證.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

class RemoteSetupForm {
  const RemoteSetupForm({
    this.server = '',
    this.username = '',
    this.password = '',
  });

  final String server;
  final String username;
  final String password;
}

/// 驗證並套用手機送來的設定. 回 null 表示成功, 否則是要顯示在手機上的原因.
typedef RemoteSetupHandler = Future<String?> Function(RemoteSetupForm form);

enum RemoteSetupPhase {
  /// 等手機掃碼
  waiting,

  /// 手機打開設定頁了, 還沒送出
  opened,

  /// 收到了, 正在驗證
  working,

  /// 上一次送來的不行, 手機上會看到原因, 改了可以再送
  failed,

  /// 完成. 伺服器已經收掉
  done,
}

class RemoteSetupException implements Exception {
  const RemoteSetupException(this.message);
  final String message;

  @override
  String toString() => message;
}

class RemoteSetupServer extends ChangeNotifier {
  RemoteSetupServer({
    required this.onSubmit,
    this.askServer = true,
    this.initialServer = '',
    Random? random,
  }) : _token = _newToken(random ?? Random.secure());

  final RemoteSetupHandler onSubmit;

  /// false = 伺服器已經設好了, 只要帳號密碼 (登入頁用)
  final bool askServer;

  /// 手機上的表單先填好這一個
  final String initialServer;

  final String _token;
  HttpServer? _server;
  bool _busy = false;
  bool _disposed = false;

  RemoteSetupPhase phase = RemoteSetupPhase.waiting;

  /// 上一次失敗的原因
  String message = '';

  /// 手機要打開的網址 (QR 碼的內容). start() 之後才有.
  Uri? url;

  /// 送出的表單最多收這麼大 —— 三個欄位而已, 再大就不是我們的表單
  static const int _maxBody = 16 * 1024;

  static String _newToken(Random random) => base64Url
      .encode(List<int>.generate(16, (_) => random.nextInt(256)))
      .replaceAll('=', '');

  String get _path => '/setup/$_token';

  /// 開始聽. [host] 只給測試用; 平常自己找這台在區網上的位址.
  Future<Uri> start({InternetAddress? host}) async {
    final address = host ?? await lanAddress();
    if (address == null) {
      throw const RemoteSetupException('找不到這台裝置的區網位址，確認有連上 Wi-Fi 或網路線。');
    }
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) {},
    );
    final shown = Uri(
      scheme: 'http',
      host: address.address,
      port: server.port,
      path: _path,
    );
    url = shown;
    return shown;
  }

  /// 連同還開著的連線一起收掉. 設定完成時「好了」那一頁已經送完才會走到這裡.
  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// 這台在區網上的 IPv4 位址. 有線、Wi-Fi 優先, 私有網段優先.
  static Future<InternetAddress?> lanAddress() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
    } catch (_) {
      return null;
    }
    InternetAddress? best;
    var bestScore = -1;
    for (final interface in interfaces) {
      // wlan0 / eth0 (Android, Linux), en0 (macOS), wlp2s0 (新式命名)
      final physical =
          RegExp(r'^(wl|eth|en)').hasMatch(interface.name.toLowerCase());
      for (final address in interface.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        final score = (isPrivateAddress(address) ? 2 : 0) + (physical ? 1 : 0);
        if (score > bestScore) {
          best = address;
          bestScore = score;
        }
      }
    }
    return best;
  }

  static bool isPrivateAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length != 4) return false;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }

  void _set(RemoteSetupPhase value, [String reason = '']) {
    phase = value;
    message = reason;
    // 設定畫面可能在驗證途中就被關掉了
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ------------------------------------------------------------------ 請求

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Frame-Options', 'DENY')
      ..contentType = ContentType.html;
    try {
      if (request.uri.path != _path) {
        response.statusCode = HttpStatus.notFound;
        response.write(_page('找不到', '<p>這個網址不對，請重新掃描電視上的 QR 碼。</p>'));
        return;
      }
      if (phase == RemoteSetupPhase.done) {
        response
            .write(_page('已經設定好了', '<p>這一頁已經用過了。要重新設定的話，請再掃一次電視上的 QR 碼。</p>'));
        return;
      }
      switch (request.method) {
        case 'GET':
          if (phase == RemoteSetupPhase.waiting) _set(RemoteSetupPhase.opened);
          response.write(_formPage(server: initialServer));
        case 'POST':
          await _submit(request, response);
        default:
          response.statusCode = HttpStatus.methodNotAllowed;
          response.headers.set(HttpHeaders.allowHeader, 'GET, POST');
      }
    } catch (_) {
      // 手機那邊斷線之類的: 這一條算了, 等下一條
    } finally {
      try {
        await response.close();
      } catch (_) {}
      if (phase == RemoteSetupPhase.done) unawaited(close());
    }
  }

  Future<void> _submit(HttpRequest request, HttpResponse response) async {
    final bytes = <int>[];
    var tooLarge = false;
    // 超過了也要讀完 (只是不留): 沒讀完就回應的話, 連線會在手機收到回應之前
    // 被切掉
    await for (final chunk in request) {
      if (tooLarge) continue;
      bytes.addAll(chunk);
      tooLarge = bytes.length > _maxBody;
    }
    if (tooLarge) {
      response.statusCode = HttpStatus.requestEntityTooLarge;
      response.write(_page('太大了', '<p>送來的資料太大。</p>'));
      return;
    }
    final Map<String, String> fields;
    try {
      fields = Uri.splitQueryString(utf8.decode(bytes));
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
      response
          .write(_formPage(server: initialServer, error: '看不懂送來的資料，再送一次試試。'));
      return;
    }
    final form = RemoteSetupForm(
      server: askServer ? (fields['server'] ?? '').trim() : initialServer,
      username: (fields['username'] ?? '').trim(),
      password: fields['password'] ?? '',
    );
    if (askServer && form.server.isEmpty) {
      response.write(_formPage(
          server: form.server, username: form.username, error: '請先填伺服器位址。'));
      return;
    }
    if (!askServer && (form.username.isEmpty || form.password.isEmpty)) {
      response.write(_formPage(
          server: form.server, username: form.username, error: '請把帳號跟密碼都填好。'));
      return;
    }
    // 同一時間只處理一次送出 —— 連點兩下的話第二下不要再去連一次
    if (_busy) {
      response.statusCode = HttpStatus.conflict;
      response.write(_page('處理中', '<p>上一次送出的還在連線，稍等一下再重新整理這一頁。</p>'));
      return;
    }
    _busy = true;
    _set(RemoteSetupPhase.working);
    String? error;
    try {
      error = await onSubmit(form);
    } catch (e) {
      error = '$e';
    } finally {
      _busy = false;
    }
    if (error == null) {
      _set(RemoteSetupPhase.done);
      response.write(_donePage(form));
      return;
    }
    _set(RemoteSetupPhase.failed, error);
    response.write(
        _formPage(server: form.server, username: form.username, error: error));
  }

  // ------------------------------------------------------------------ 網頁

  static String _escape(String text) => const HtmlEscape().convert(text);

  String _formPage({
    String server = '',
    String username = '',
    String error = '',
  }) {
    final serverField = askServer
        ? '''
<label>伺服器位址
<input name="server" value="${_escape(server)}" placeholder="http://192.168.1.10:5000"
 inputmode="url" autocapitalize="off" autocorrect="off" spellcheck="false" required>
</label>
<p class="note">就是平常用瀏覽器開 Dashboard 的那一個。沒填 http:// 會自動補上。</p>'''
        : '<p class="server">伺服器：${_escape(server)}</p>';
    final accountNote =
        askServer ? '<h2>帳號 <span>（伺服器有開帳號系統才要填）</span></h2>' : '<h2>帳號</h2>';
    final required = askServer ? '' : ' required';
    return _page(
      askServer ? '設定電視上的 aniGamerPlus' : '登入電視上的 aniGamerPlus',
      '''
<p class="lead">填好按「送到電視」，電視會自己連上。</p>
${error.isEmpty ? '' : '<p class="error">${_escape(error)}</p>'}
<form method="post" autocomplete="off" onsubmit="var b=this.querySelector('button');b.disabled=true;b.textContent='連線中…'">
$serverField
$accountNote
<label>帳號<input name="username" value="${_escape(username)}" autocapitalize="off" autocorrect="off" spellcheck="false"$required></label>
<label>密碼<input name="password" type="password"$required></label>
<button type="submit">送到電視</button>
</form>
<p class="note">這一頁由電視提供，只在電視上的設定畫面開著時有效。</p>''',
    );
  }

  String _donePage(RemoteSetupForm form) => _page(
        '好了！',
        '<p class="lead">電視已經連上 ${_escape(form.server)}'
            '${form.username.isEmpty ? '' : '，也用「${_escape(form.username)}」登入了'}。'
            '</p><p>這一頁可以關掉了。</p>',
      );

  static String _page(String title, String body) => '''<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_escape(title)}</title>
<style>
:root{--bg:#fafbfb;--card:#fff;--fg:#16181d;--dim:#687378;--line:#dde4e6;--accent:#00b5d4;--err:#d64545}
@media (prefers-color-scheme:dark){:root{--bg:#0b0c0e;--card:#191c21;--fg:#f3f4f6;--dim:#adb4bc;--line:#30363d}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,-apple-system,"PingFang TC","Noto Sans TC",sans-serif}
main{max-width:440px;margin:0 auto;padding:28px 18px 40px}
.brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:20px;margin-bottom:18px}
.logo{display:inline-grid;place-items:center;width:36px;height:36px;border-radius:9px;background:var(--accent);color:#fff;font-size:16px}
h1{font-size:22px;margin:0 0 6px}
h2{font-size:15px;margin:22px 0 4px}
h2 span{font-weight:400;color:var(--dim);font-size:13px}
.lead{margin:0 0 18px;color:var(--dim)}
.server{padding:10px 12px;border-radius:10px;background:var(--card);border:1px solid var(--line);word-break:break-all}
label{display:block;font-weight:600;font-size:14px;margin-top:12px}
input{display:block;width:100%;margin-top:6px;padding:12px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--fg);font:inherit}
input:focus{outline:none;border-color:var(--accent)}
button{display:block;width:100%;margin-top:24px;padding:14px;border:0;border-radius:10px;background:var(--accent);color:#fff;font:inherit;font-weight:700}
button:disabled{opacity:.6}
.note{font-size:13px;color:var(--dim);margin:8px 0 0}
.error{padding:10px 12px;border-radius:10px;border:1px solid var(--err);color:var(--err);background:rgba(214,69,69,.08)}
</style></head><body><main>
<div class="brand"><span class="logo">&#9654;</span>aniGamerPlus</div>
<h1>${_escape(title)}</h1>
$body
</main></body></html>''';
}
