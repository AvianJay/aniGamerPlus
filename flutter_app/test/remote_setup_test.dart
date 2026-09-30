/// 掃碼設定那台小伺服器: 手機打開的網頁、送出的欄位、錯誤怎麼回、用完就收.
///
/// 沒有裝置也沒有網路: 伺服器開在 loopback 上, 手機由 HttpClient 扮演.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agp_mobile/src/state/remote_setup.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(int, String)> send(Uri url, {Map<String, String>? form}) async {
  final client = HttpClient();
  try {
    final request =
        form == null ? await client.getUrl(url) : await client.postUrl(url);
    if (form != null) {
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(Uri(queryParameters: form).query);
    }
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  } finally {
    client.close(force: true);
  }
}

void main() {
  RemoteSetupServer? current;
  late Uri url;
  final submitted = <RemoteSetupForm>[];
  String? Function(RemoteSetupForm form) answer = (_) => null;

  Future<void> start({bool askServer = true, String initial = ''}) async {
    submitted.clear();
    current = RemoteSetupServer(
      askServer: askServer,
      initialServer: initial,
      onSubmit: (form) async {
        submitted.add(form);
        return answer(form);
      },
    );
    url = await current!.start(host: InternetAddress.loopbackIPv4);
  }

  tearDown(() async {
    await current?.close();
    current?.dispose();
    current = null;
    answer = (_) => null;
  });

  test('QR 碼裡的網址帶著一段猜不到的路徑, 別的路徑一律 404', () async {
    await start();
    expect(url.host, '127.0.0.1');
    expect(url.path, startsWith('/setup/'));
    expect(url.pathSegments.last.length, greaterThanOrEqualTo(20));

    final (status, _) = await send(url.replace(path: '/setup/guess'));
    expect(status, 404);
    expect(current!.phase, RemoteSetupPhase.waiting);

    // 每一次開都是新的一段
    final first = url;
    await current!.close();
    current!.dispose();
    await start();
    expect(url.path, isNot(first.path));
  });

  test('打開網頁: 表單先填好目前的位址, 而且有跳脫', () async {
    await start(initial: 'http://10.0.0.2:5000/"><script>');
    final (status, body) = await send(url);
    expect(status, 200);
    expect(body, contains('<form method="post"'));
    expect(body, contains('name="server"'));
    expect(body,
        contains('http:&#47;&#47;10.0.0.2:5000&#47;&quot;&gt;&lt;script&gt;'));
    expect(body, isNot(contains('"><script>')));
    expect(current!.phase, RemoteSetupPhase.opened);
  });

  test('送出: 欄位原封不動交出去, 成功之後這一頁就作廢', () async {
    await start();
    final (status, body) = await send(url, form: {
      'server': ' 192.168.1.10:5000 ',
      'username': 'ani',
      'password': 'p&ss=word+ 中文',
    });
    expect(status, 200);
    expect(body, contains('好了'));
    expect(submitted, hasLength(1));
    expect(submitted.single.server, '192.168.1.10:5000');
    expect(submitted.single.username, 'ani');
    expect(submitted.single.password, 'p&ss=word+ 中文');
    expect(current!.phase, RemoteSetupPhase.done);

    // 再送一次不會再套用一遍 —— 伺服器可能已經收掉了, 沒收掉的話也只會說用過了
    try {
      final (_, again) =
          await send(url, form: {'server': 'http://evil:1', 'username': ''});
      expect(again, contains('已經設定好了'));
    } on SocketException {
      // 收掉了
    }
    expect(submitted, hasLength(1));
  });

  test('驗證失敗: 手機上看到原因, 欄位留著可以改了再送', () async {
    await start();
    answer = (_) => '連不上. 確認伺服器有開';
    final (status, body) = await send(url, form: {
      'server': 'http://192.168.1.99:5000',
      'username': 'ani',
      'password': 'secret',
    });
    expect(status, 200);
    expect(body, contains('連不上. 確認伺服器有開'));
    expect(body, contains('value="http:&#47;&#47;192.168.1.99:5000"'));
    expect(body, contains('value="ani"'));
    // 密碼不回填
    expect(body, isNot(contains('secret')));
    expect(current!.phase, RemoteSetupPhase.failed);
    expect(current!.message, '連不上. 確認伺服器有開');

    answer = (_) => null;
    final (_, retried) =
        await send(url, form: {'server': 'http://192.168.1.10:5000'});
    expect(retried, contains('好了'));
    expect(current!.phase, RemoteSetupPhase.done);
  });

  test('沒填位址就不去連', () async {
    await start();
    final (_, body) = await send(url, form: {'server': '  ', 'username': ''});
    expect(body, contains('請先填伺服器位址'));
    expect(submitted, isEmpty);
  });

  test('登入頁那一種: 只問帳號密碼, 位址用這邊已經設好的', () async {
    await start(askServer: false, initial: 'http://192.168.1.10:5000');
    final (_, page) = await send(url);
    expect(page, isNot(contains('name="server"')));
    expect(page, contains('192.168.1.10:5000'));

    final (_, missing) = await send(url, form: {'username': 'ani'});
    expect(missing, contains('請把帳號跟密碼都填好'));
    expect(submitted, isEmpty);

    // 手機硬塞一個別的位址進來也沒用
    await send(url, form: {
      'server': 'http://evil:1',
      'username': 'ani',
      'password': 'pw',
    });
    expect(submitted.single.server, 'http://192.168.1.10:5000');
  });

  test('太大的內容直接拒絕', () async {
    await start();
    final (status, _) = await send(url, form: {'server': 'x' * 40000});
    expect(status, 413);
    expect(submitted, isEmpty);
  });

  test('只挑區網位址: 私有網段才算', () {
    bool private(String address) =>
        RemoteSetupServer.isPrivateAddress(InternetAddress(address));
    expect(private('192.168.1.5'), isTrue);
    expect(private('10.0.0.8'), isTrue);
    expect(private('172.16.0.1'), isTrue);
    expect(private('172.31.255.1'), isTrue);
    expect(private('172.32.0.1'), isFalse);
    expect(private('8.8.8.8'), isFalse);
  });
}
