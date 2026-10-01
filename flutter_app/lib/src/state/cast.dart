/// 投放到 Chromecast.
///
/// 一支 App 同一時間只有一條投放連線, 所以掛在 AppState 上: 離開播放頁不會斷,
/// 電視照樣播下去 (跟 YouTube 一樣); 回到同一集的播放頁時認得電視上那一份,
/// 直接接手, 不必重新載入.
///
/// 電視那一頭拿不到我們的 cookie, 所以交給它的網址是帶著投放票的 (見
/// AgpClient.castTicket). 接收器用的是 Google 的預設媒體接收器 (CC1AD845),
/// 不必另外註冊、也不必架一個自己的接收器網頁.
///
/// 真正跟 Google Cast SDK 講話的是 [CastBackend]; widget test 換成假的.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../util/device.dart';

/// 同一個網路上的一台 Chromecast (或內建 Chromecast 的電視、喇叭).
@immutable
class CastDevice {
  const CastDevice({required this.id, required this.name, this.model = ''});

  final String id;
  final String name;
  final String model;

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 電視上那個播放器現在在做什麼.
enum CastPlayback { idle, loading, buffering, playing, paused, ended, failed }

/// 要丟給電視的一集.
@immutable
class CastMedia {
  const CastMedia({
    required this.sn,
    required this.source,
    required this.url,
    required this.contentType,
    required this.title,
    this.subtitle = '',
    this.poster,
    this.duration,
  });

  final String sn;

  /// 哪一份片源 (完整檔 / 邊看邊下載 / 某個畫質). 播放頁回來時拿它認
  /// 「電視上那份就是我要的」, 對不上才重新載入.
  final String source;

  final Uri url;

  /// `video/mp4` 或 `application/x-mpegURL`
  final String contentType;

  final String title;
  final String subtitle;
  final Uri? poster;

  /// 秒. 知道的話先告訴接收器, 進度條一開始就畫得對.
  final double? duration;

  bool get isHls => contentType.toLowerCase().contains('mpegurl');
}

/// 接收器回報的狀態.
@immutable
class CastRemoteStatus {
  const CastRemoteStatus({
    required this.playback,
    this.duration,
    this.contentId,
  });

  final CastPlayback playback;
  final double? duration;

  /// 這份狀態講的是哪一支片 (載入時給的網址). 換集的那一瞬間, 上一集最後
  /// 那幾筆狀態還會陸續進來, 要靠它分辨.
  final String? contentId;
}

/// 投放的實際做法. 正式版是 [GoogleCastBackend], 測試換成假的.
abstract class CastBackend {
  /// 初始化 SDK. 沒有 Google Play 服務的 Android 機器會在這裡失敗.
  Future<bool> initialise();

  Stream<List<CastDevice>> get devices;
  Future<void> startDiscovery();
  Future<void> stopDiscovery();

  /// 開始連線. 真的連上要等 [sessions] 送出裝置名稱.
  Future<bool> connect(CastDevice device);

  /// 斷線, 並且讓電視停止播放.
  Future<void> disconnect();

  /// 連上時是裝置名稱, 沒有連線時是 null.
  Stream<String?> get sessions;

  Stream<CastRemoteStatus?> get statuses;

  /// 秒
  Stream<double> get positions;

  Future<void> load(CastMedia media,
      {required double startAt, required bool autoplay, required double rate});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(double seconds);
  Future<void> setRate(double rate);
}

class CastController extends ChangeNotifier with WidgetsBindingObserver {
  CastController({CastBackend? backend})
      : _backendOverride = backend;

  /// 連線掉了之後, App 在前景等這麼久還沒接回來, 才算真的停止投放.
  ///
  /// iOS 的 Cast SDK 在 App 退到背景 (或被系統暫停過、網路斷一下) 時會先把
  /// session 暫停, 回到前景再接回來 —— 中間那一段外掛回報的是「沒有 session」.
  /// 照單全收的話, 播放頁會以為停止投放了: 在手機上開播放器, 等 session 接回來
  /// 又把這一集重新交給電視, 電視上的畫面就從頭載入一次.
  static const Duration kSessionGrace = Duration(seconds: 8);

  /// 只有手機跟平板投得出去: 電視自己就是螢幕, 桌面版沒有 Cast SDK.
  /// 測試裡可以直接改.
  static bool supported = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  final CastBackend? _backendOverride;
  CastBackend? _backendInstance;
  CastBackend get _backend =>
      _backendInstance ??= _backendOverride ?? GoogleCastBackend();

  Future<bool>? _boot;
  bool _ready = false;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// SDK 起得來 (有 Google Play 服務、不是電視). 不然整個投放功能藏起來.
  bool get available => _ready;

  /// 找得到的裝置. 只有在 [startDiscovery] 之後才會更新.
  List<CastDevice> devices = const [];

  /// 連著的那一台. null 就是沒在投放.
  String? deviceName;
  bool get connected => deviceName != null;

  /// 正在連的那一台
  CastDevice? connecting;
  Completer<bool>? _connectWaiter;

  /// 最後一次交給電視的那一集. 斷線就清掉.
  CastMedia? media;
  CastPlayback playback = CastPlayback.idle;

  /// 秒. 接收器還沒回報之前先用載入時給的.
  double duration = 0;

  /// 電視上播到哪裡 (秒). 一秒變好幾次, 所以另外一條, 不跟著 notifyListeners.
  final ValueNotifier<double> position = ValueNotifier<double>(0);

  /// 載入之後有沒有真的看到它開始動. 沒看到之前的「播完了」是上一集的.
  bool _sawPlayback = false;

  int _discoverers = 0;
  bool _discovering = false;

  /// SDK 說連線沒了, 但還沒認定是真的斷了 (見 [kSessionGrace])
  bool _lost = false;
  Timer? _lostTimer;
  bool _foreground = true;
  bool _observing = false;

  /// 連線暫時掉了, 正在等它接回來. 這段時間 [connected] 還是 true.
  bool get reconnecting => _lost;

  /// 起 SDK. 只會真的做一次; 失敗了這次開機就不再試.
  Future<bool> warmUp() {
    if (!supported || Device.tv) return Future<bool>.value(false);
    return _boot ??= _start();
  }

  Future<bool> _start() async {
    var ok = false;
    try {
      ok = await _backend.initialise();
    } catch (_) {
      ok = false;
    }
    if (!ok) return false;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
    _subscriptions
      ..add(_backend.devices.listen(_onDevices, onError: (Object _) {}))
      ..add(_backend.sessions.listen(_onSession, onError: (Object _) {}))
      ..add(_backend.statuses.listen(_onStatus, onError: (Object _) {}))
      ..add(_backend.positions.listen(_onPosition, onError: (Object _) {}));
    _ready = true;
    notifyListeners();
    return true;
  }

  /// 開始找裝置. 播放頁跟選裝置的面板各自開、各自關, 最後一個關掉才真的停.
  void startDiscovery() {
    _discoverers++;
    unawaited(_syncDiscovery());
  }

  void stopDiscovery() {
    if (_discoverers > 0) _discoverers--;
    unawaited(_syncDiscovery());
  }

  Future<void> _syncDiscovery() async {
    if (!await warmUp()) return;
    final want = _discoverers > 0;
    if (want == _discovering) return;
    _discovering = want;
    try {
      if (want) {
        await _backend.startDiscovery();
      } else {
        await _backend.stopDiscovery();
      }
    } catch (_) {
      // 找不到就是找不到, 不值得讓播放頁出錯
    }
  }

  /// 連到 [device]. 真的連上 (或 20 秒內沒連上) 才回來.
  Future<bool> connect(CastDevice device) async {
    if (!_ready) return false;
    if (deviceName != null && connecting == null) return true;
    final waiter = Completer<bool>();
    _connectWaiter = waiter;
    connecting = device;
    notifyListeners();
    try {
      final started = await _backend.connect(device);
      if (!started && !waiter.isCompleted) waiter.complete(false);
    } catch (_) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    final ok = await waiter.future
        .timeout(const Duration(seconds: 20), onTimeout: () => false);
    if (_connectWaiter == waiter) _connectWaiter = null;
    if (connecting == device) {
      connecting = null;
      notifyListeners();
    }
    return ok;
  }

  /// 停止投放: 斷線, 電視上的播放也一起停.
  Future<void> disconnect() async {
    if (!_ready) return;
    try {
      await _backend.disconnect();
    } catch (_) {}
    // SDK 偶爾不回報斷線 (電視已經先關了). 這裡自己收尾, 回報晚到也只是再收一次.
    // 自己按的停止不必等寬限期
    _drop();
  }

  /// 把 [next] 交給電視, 從 [startAt] 秒開始.
  Future<void> load(CastMedia next,
      {required double startAt, bool autoplay = true, double rate = 1}) async {
    media = next;
    playback = CastPlayback.loading;
    _sawPlayback = false;
    duration = next.duration ?? 0;
    position.value = startAt;
    notifyListeners();
    try {
      await _backend.load(next,
          startAt: startAt, autoplay: autoplay, rate: rate);
    } catch (_) {
      if (media != next) return;
      playback = CastPlayback.failed;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> play() => _guard(_backend.play);
  Future<void> pause() => _guard(_backend.pause);
  Future<void> seek(double seconds) {
    position.value = seconds;
    return _guard(() => _backend.seek(seconds));
  }

  Future<void> setRate(double rate) => _guard(() => _backend.setRate(rate));

  Future<void> _guard(Future<void> Function() action) async {
    if (!connected) return;
    try {
      await action();
    } catch (_) {
      // 電視那頭不理我們 (斷線中、或接收器已經換人用了). 下一筆狀態會說實話.
    }
  }

  void _onDevices(List<CastDevice> found) {
    devices = List.unmodifiable(found);
    notifyListeners();
  }

  void _onSession(String? name) {
    if (name != null) {
      final changed = deviceName != name || connecting != null || _lost;
      _cancelLoss();
      deviceName = name;
      connecting = null;
      final waiter = _connectWaiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete(true);
      if (changed) notifyListeners();
      return;
    }
    if (deviceName == null && media == null) return;
    if (_lost) return;
    _lost = true;
    _armLoss();
    notifyListeners();
  }

  /// 開始 (或重新開始) 算寬限期. 在背景時不算: iOS 會把整支 App 停下來, 計時器
  /// 在回到前景那一刻早就過期了, 而 SDK 這時候才正要把 session 接回來.
  void _armLoss() {
    _lostTimer?.cancel();
    _lostTimer = null;
    if (!_foreground) return;
    _lostTimer = Timer(kSessionGrace, _drop);
  }

  void _cancelLoss() {
    _lost = false;
    _lostTimer?.cancel();
    _lostTimer = null;
  }

  /// 真的斷了: 電視上那一集忘掉, 播放頁會在手機上接回來
  void _drop() {
    _cancelLoss();
    if (deviceName == null && media == null) return;
    deviceName = null;
    media = null;
    playback = CastPlayback.idle;
    _sawPlayback = false;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (_lost) _armLoss();
  }

  void _onStatus(CastRemoteStatus? status) {
    final current = media;
    if (status == null || current == null) return;
    final id = status.contentId;
    // 換集那一瞬間進來的、講的還是上一集的狀態
    if (id != null && id.isNotEmpty && !_sameMedia(id, current)) return;
    var next = status.playback;
    if (next == CastPlayback.playing ||
        next == CastPlayback.paused ||
        next == CastPlayback.buffering) {
      _sawPlayback = true;
    }
    // 還沒開始動之前的「閒置 / 播完」是上一集留下來的
    if (!_sawPlayback &&
        (next == CastPlayback.idle || next == CastPlayback.ended)) {
      return;
    }
    final total = status.duration;
    final durationChanged =
        total != null && total > 0 && (total - duration).abs() > 0.5;
    if (durationChanged) duration = total;
    if (next == playback && !durationChanged) return;
    playback = next;
    notifyListeners();
  }

  /// 接收器回報的網址是不是我們交出去的那一個. 不只比字串: 接收器那頭若把
  /// 網址正規化過 (編碼方式不同), 逐字比就會把每一筆狀態都當成別人的.
  static bool _sameMedia(String contentId, CastMedia media) {
    if (contentId == media.url.toString()) return true;
    final reported = Uri.tryParse(contentId);
    return reported != null &&
        reported.path == media.url.path &&
        reported.queryParameters['id'] == media.sn &&
        reported.queryParameters['res'] == media.url.queryParameters['res'];
  }

  void _onPosition(double seconds) {
    if (media == null || seconds < 0) return;
    // 載入後、開始動之前, SDK 會先回報一個 0. 那不是真的位置
    if (!_sawPlayback && seconds == 0) return;
    position.value = seconds;
  }

  @override
  void dispose() {
    _lostTimer?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    position.dispose();
    super.dispose();
  }
}

/// [CastBackend] 的正式版: flutter_chrome_cast (底下是 Google Cast SDK).
class GoogleCastBackend implements CastBackend {
  final Map<String, GoogleCastDevice> _known = {};

  @override
  Future<bool> initialise() {
    const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
    final GoogleCastOptions options = Platform.isIOS
        ? IOSGoogleCastOptions(
            GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(appId),
            // 播放頁一開就要知道附近有沒有 Chromecast, 才決定按鈕要不要出現
            startDiscoveryAfterFirstTapOnCastButton: false,
            // 退到背景也不要暫停 session: 投放中播放頁會用 cast_keepalive 讓
            // App 留著, 才看得到電視播完、接得上下一集. 真的被系統暫停了,
            // 回來時 CastController 的寬限期會擋掉那一段「沒有 session」.
            suspendSessionsWhenBackgrounded: false,
          )
        : GoogleCastOptionsAndroid(appId: appId);
    return GoogleCastContext.instance.setSharedInstanceWithOptions(options);
  }

  @override
  Stream<List<CastDevice>> get devices =>
      GoogleCastDiscoveryManager.instance.devicesStream.map((found) {
        _known
          ..clear()
          ..addEntries(found.map((device) => MapEntry(device.deviceID, device)));
        return [
          for (final device in found)
            CastDevice(
              id: device.deviceID,
              name: device.friendlyName,
              model: device.modelName ?? '',
            ),
        ];
      });

  @override
  Future<void> startDiscovery() =>
      GoogleCastDiscoveryManager.instance.startDiscovery();

  @override
  Future<void> stopDiscovery() =>
      GoogleCastDiscoveryManager.instance.stopDiscovery();

  @override
  Future<bool> connect(CastDevice device) async {
    final target = _known[device.id];
    if (target == null) return false;
    return GoogleCastSessionManager.instance.startSessionWithDevice(target);
  }

  @override
  Future<void> disconnect() async {
    await GoogleCastSessionManager.instance.endSessionAndStopCasting();
  }

  @override
  Stream<String?> get sessions =>
      GoogleCastSessionManager.instance.currentSessionStream.map((session) {
        if (session == null ||
            session.connectionState != GoogleCastConnectState.connected) {
          return null;
        }
        final name = session.device?.friendlyName ?? '';
        return name.isEmpty ? 'Chromecast' : name;
      }).distinct();

  @override
  Stream<CastRemoteStatus?> get statuses =>
      GoogleCastRemoteMediaClient.instance.mediaStatusStream.map((status) {
        if (status == null) return null;
        final info = status.mediaInformation;
        final seconds = info?.duration;
        return CastRemoteStatus(
          playback: _playbackOf(status.playerState, status.idleReason),
          duration: seconds == null ? null : seconds.inMilliseconds / 1000,
          contentId: info?.contentUrl?.toString() ?? info?.contentId,
        );
      });

  static CastPlayback _playbackOf(
      CastMediaPlayerState state, GoogleCastMediaIdleReason? reason) {
    switch (state) {
      case CastMediaPlayerState.playing:
        return CastPlayback.playing;
      case CastMediaPlayerState.paused:
        return CastPlayback.paused;
      case CastMediaPlayerState.buffering:
        return CastPlayback.buffering;
      case CastMediaPlayerState.loading:
        return CastPlayback.loading;
      case CastMediaPlayerState.idle:
      case CastMediaPlayerState.unknown:
        return switch (reason) {
          GoogleCastMediaIdleReason.finished => CastPlayback.ended,
          GoogleCastMediaIdleReason.error => CastPlayback.failed,
          _ => CastPlayback.idle,
        };
    }
  }

  @override
  Stream<double> get positions => GoogleCastRemoteMediaClient
      .instance.playerPositionStream
      .map((position) => position.inMilliseconds / 1000);

  @override
  Future<void> load(CastMedia media,
      {required double startAt,
      required bool autoplay,
      required double rate}) {
    final poster = media.poster;
    final seconds = media.duration;
    return GoogleCastRemoteMediaClient.instance.loadMedia(
      GoogleCastMediaInformation(
        // contentId 跟 contentUrl 用同一個: 接收器回報狀態時帶的是 contentId,
        // CastController 拿它分辨狀態是不是這一集的
        contentId: media.url.toString(),
        contentUrl: media.url,
        streamType: CastMediaStreamType.buffered,
        contentType: media.contentType,
        // 動畫瘋的分片是 MPEG-TS
        hlsSegmentFormat: media.isHls ? CastHlsSegmentFormat.ts : null,
        hlsVideoSegmentFormat:
            media.isHls ? HlsVideoSegmentFormat.mpeg2Ts : null,
        duration: seconds != null && seconds > 0
            ? Duration(milliseconds: (seconds * 1000).round())
            : null,
        metadata: GoogleCastGenericMediaMetadata(
          title: media.title,
          subtitle: media.subtitle,
          images: poster == null ? null : [GoogleCastImage(url: poster)],
        ),
      ),
      autoPlay: autoplay,
      playPosition: Duration(milliseconds: (startAt * 1000).round()),
      playbackRate: rate,
    );
  }

  @override
  Future<void> play() => GoogleCastRemoteMediaClient.instance.play();

  @override
  Future<void> pause() => GoogleCastRemoteMediaClient.instance.pause();

  @override
  Future<void> seek(double seconds) =>
      GoogleCastRemoteMediaClient.instance.seek(GoogleCastMediaSeekOption(
        position: Duration(milliseconds: (seconds * 1000).round()),
        // 跳轉不要順便改變播放 / 暫停
        resumeState: GoogleCastMediaResumeState.unchanged,
      ));

  @override
  Future<void> setRate(double rate) =>
      GoogleCastRemoteMediaClient.instance.setPlaybackRate(rate);
}
