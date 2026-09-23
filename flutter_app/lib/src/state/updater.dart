/// App 自己的更新 —— 不經過任何商店, 直接看 GitHub Releases.
///
/// 兩條通道:
///  - 正式版: `releases/latest` 上掛的 APK / IPA. 檔名裡帶著 CI 的 run number,
///    例如 `aniGamerPlus-1.0.0-123.apk`, 那個 123 就是 build number.
///  - Nightly: 固定 tag `nightly` 的 prerelease, 每次 master 一推就整包換掉.
///    檔名固定, 旁邊附一份 `flutter-nightly.json` 說這一包是第幾個 build.
///
/// 兩條通道的 build number 都是同一個 workflow 的 run number, 所以可以直接比大小.
///
/// 安裝: Android 下載 APK 後丟給系統安裝器 (同一把簽章才蓋得過去);
/// iOS 沒有這種門, 只能把 IPA 網址交給側載商店 (TrollStore / SideStore / AltStore)
/// 讓它自己下載、簽名、安裝.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

const String kUpdateRepo = 'AvianJay/aniGamerPlus';
const String kNightlyTag = 'nightly';
const String kNightlyManifest = 'flutter-nightly.json';

enum UpdateChannel {
  stable('stable', '正式版'),
  nightly('nightly', 'Nightly');

  const UpdateChannel(this.key, this.label);
  final String key;
  final String label;

  static UpdateChannel parse(String? key) =>
      values.firstWhere((c) => c.key == key, orElse: () => stable);
}

/// iOS 要把 IPA 交給誰. [auto] = 看手機上裝了哪個就用哪個.
enum IosInstaller {
  auto('auto', '自動偵測', ''),
  trollStore('trollstore', 'TrollStore', 'apple-magnifier'),
  sideStore('sidestore', 'SideStore', 'sidestore'),
  altStore('altstore', 'AltStore', 'altstore');

  const IosInstaller(this.key, this.label, this.scheme);
  final String key;
  final String label;

  /// 三家都吃 `<scheme>://install?url=<IPA 網址>`.
  /// TrollStore 借的是「放大鏡」的 scheme, 名字看起來跟它毫無關係.
  final String scheme;

  static IosInstaller parse(String? key) =>
      values.firstWhere((i) => i.key == key, orElse: () => auto);

  /// 自動偵測時的優先順序: TrollStore 不用重簽、不會七天過期, 排第一.
  static const List<IosInstaller> stores = [trollStore, sideStore, altStore];

  Uri installUri(String ipaUrl) =>
      Uri.parse('$scheme://install?url=${Uri.encodeComponent(ipaUrl)}');
}

class AppVersion {
  const AppVersion(this.version, this.build);
  final String version;
  final int build;

  @override
  String toString() => build > 0 ? '$version ($build)' : version;
}

class UpdateInfo {
  const UpdateInfo({
    required this.channel,
    required this.version,
    required this.build,
    required this.url,
    this.notes = '',
    this.commit = '',
  });

  final UpdateChannel channel;
  final String version;
  final int build;

  /// APK 或 IPA 的直接下載網址
  final String url;
  final String notes;
  final String commit;

  String get label => '$version ($build)';
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 正式版的資產檔名: `aniGamerPlus-1.0.0-123.apk`,
/// `aniGamerPlus-flutter-1.0.0-123-unsigned.ipa`
final RegExp _assetName =
    RegExp(r'-(\d+(?:\.\d+)*)-(\d+)(?:-unsigned)?\.(apk|ipa)$');

class Updater {
  Updater({
    http.Client? httpClient,
    this.apiBase = 'https://api.github.com/repos/$kUpdateRepo',
    this.downloadBase = 'https://github.com/$kUpdateRepo/releases/download',
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String apiBase;
  final String downloadBase;

  static Future<AppVersion>? _current;

  /// 跑起來之後就不會變, 讀一次就好
  static Future<AppVersion> current() => _current ??= () async {
        final info = await PackageInfo.fromPlatform();
        return AppVersion(info.version, int.tryParse(info.buildNumber) ?? 0);
      }();

  /// 通道上最新的那一包; 這個平台沒有檔案可裝時回 null.
  Future<UpdateInfo?> latest(UpdateChannel channel, {required bool ios}) =>
      switch (channel) {
        UpdateChannel.stable => _stable(ios: ios),
        UpdateChannel.nightly => _nightly(ios: ios),
      };

  /// 比 [currentBuild] 新才回傳.
  Future<UpdateInfo?> check(UpdateChannel channel,
      {required bool ios, required int currentBuild}) async {
    final info = await latest(channel, ios: ios);
    if (info == null || info.build <= currentBuild) return null;
    return info;
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final http.Response response;
    try {
      response = await _http.get(uri, headers: const {
        'Accept': 'application/vnd.github+json',
      }).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw UpdateException('連不上 GitHub，請稍後再試。');
    }
    if (response.statusCode == 404) {
      throw UpdateException('這個通道目前還沒有發佈任何版本。');
    }
    if (response.statusCode != 200) {
      throw UpdateException('GitHub 回應 ${response.statusCode}，請稍後再試。');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map) throw UpdateException('看不懂 GitHub 的回應。');
    return body.cast<String, dynamic>();
  }

  Future<UpdateInfo?> _stable({required bool ios}) async {
    final release = await _json(Uri.parse('$apiBase/releases/latest'));
    final assets = release['assets'];
    if (assets is! List) return null;
    for (final asset in assets.whereType<Map>()) {
      final name = '${asset['name'] ?? ''}';
      final url = '${asset['browser_download_url'] ?? ''}';
      final match = _assetName.firstMatch(name);
      if (match == null || url.isEmpty) continue;
      if ((match.group(3) == 'ipa') != ios) continue;
      return UpdateInfo(
        channel: UpdateChannel.stable,
        version: match.group(1)!,
        build: int.parse(match.group(2)!),
        url: url,
        notes: '${release['body'] ?? ''}'.trim(),
      );
    }
    return null;
  }

  Future<UpdateInfo?> _nightly({required bool ios}) async {
    final base = '$downloadBase/$kNightlyTag';
    final manifest = await _json(Uri.parse('$base/$kNightlyManifest'));
    final file = '${manifest[ios ? 'ipa' : 'apk'] ?? ''}';
    final build = manifest['build'] is int
        ? manifest['build'] as int
        : int.tryParse('${manifest['build']}') ?? 0;
    if (file.isEmpty || build <= 0) return null;
    return UpdateInfo(
      channel: UpdateChannel.nightly,
      version: '${manifest['version'] ?? ''}',
      build: build,
      url: '$base/$file',
      commit: '${manifest['commit'] ?? ''}',
      notes: '${manifest['date'] ?? ''}',
    );
  }

  // --------------------------------------------------------------- Android

  /// 下載到 app 自己的快取目錄 —— 那裡不需要任何儲存權限,
  /// open_filex 的 FileProvider 也涵蓋得到.
  Future<File> downloadApk(UpdateInfo info,
      {void Function(int received, int total)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/update-${info.build}.apk');
    final part = File('${file.path}.part');
    final response = await _http.send(http.Request('GET', Uri.parse(info.url)));
    if (response.statusCode != 200) {
      throw UpdateException('下載失敗 (HTTP ${response.statusCode})。');
    }
    final total = response.contentLength ?? -1;
    var received = 0;
    final sink = part.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } catch (_) {
      await sink.close();
      if (await part.exists()) await part.delete();
      throw UpdateException('下載中斷，請再試一次。');
    }
    await sink.close();
    if (await file.exists()) await file.delete();
    return part.rename(file.path);
  }

  /// 交給系統安裝器. 第一次會被系統要求允許「安裝未知應用程式」.
  static Future<void> installApk(File apk) async {
    final result = await OpenFilex.open(apk.path,
        type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done) {
      throw UpdateException('無法開啟安裝程式：${result.message}');
    }
  }

  // ------------------------------------------------------------------- iOS

  /// 手機上裝了哪些側載商店. 要 Info.plist 的 LSApplicationQueriesSchemes
  /// 有列出那幾個 scheme, canLaunchUrl 才會說實話.
  static Future<List<IosInstaller>> detectIosInstallers() async {
    final found = <IosInstaller>[];
    for (final store in IosInstaller.stores) {
      try {
        if (await canLaunchUrl(Uri.parse('${store.scheme}://'))) {
          found.add(store);
        }
      } catch (_) {}
    }
    return found;
  }

  /// [preferred] 是 auto 時: 偵測到的第一個; 一個都沒有就先硬開 TrollStore,
  /// 再不行才讓 Safari 直接下載 IPA.
  /// 回傳實際用了誰; null = 交給了瀏覽器.
  static Future<IosInstaller?> installIpa(
      UpdateInfo info, IosInstaller preferred) async {
    final candidates = <IosInstaller>[
      if (preferred != IosInstaller.auto) preferred,
      ...await detectIosInstallers(),
      IosInstaller.trollStore,
    ];
    for (final store in candidates) {
      try {
        if (await launchUrl(store.installUri(info.url),
            mode: LaunchMode.externalApplication)) {
          return store;
        }
      } catch (_) {}
    }
    if (await launchUrl(Uri.parse(info.url),
        mode: LaunchMode.externalApplication)) {
      return null;
    }
    throw UpdateException('找不到可以安裝 IPA 的 App。');
  }

  void close() => _http.close();
}
