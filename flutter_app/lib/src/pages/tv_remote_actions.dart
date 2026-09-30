/// 電視上: 手機送來的指令真正落在畫面上的那一層, 跟配對碼對話框.
///
/// 連線、配對、協定都在 state/tv_remote_host.dart; 這裡只管「按一下確認鍵」、
/// 「開播放頁」、「換伺服器」在這支 App 裡是什麼意思.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../state/tv_remote_host.dart';
import '../state/tv_remote_protocol.dart';
import '../theme.dart';
import '../util/device.dart';
import '../util/remote_keys.dart';
import '../widgets/common.dart';
import 'search_page.dart';
import 'watch_page.dart';

/// 電視上那一台遙控伺服器. App 開著就一直開著 (設定裡可以關).
class TvRemoteService {
  TvRemoteService._();

  static TvRemoteHost? get host => TvRemoteHost.current;

  static AppState? _state;
  static GlobalKey<NavigatorState>? _navigator;
  static VoidCallback? _listener;

  /// 開機時叫一次. 設定裡關掉的話什麼都不做, 之後 [setEnabled] 再開
  static Future<void> start(
      AppState state, GlobalKey<NavigatorState> navigator) async {
    _state = state;
    _navigator = navigator;
    if (TvRemoteHost.current != null || !state.prefs.remoteEnabled) return;
    final created = TvRemoteHost(
      actions: AppTvRemoteActions(state, navigator),
      id: state.prefs.deviceId,
      name: Device.name,
      paired: state.prefs.pairedPhones,
      onPairedChanged: state.prefs.setPairedPhones,
    );
    TvRemoteHost.current = created;
    // 伺服器 / 帳號換了要讓手機知道 (手機據此決定要不要問「把設定傳過去」)
    void listener() => created.statusChanged();
    state.addListener(listener);
    _listener = listener;
    try {
      await created.start();
      await Device.holdMulticastLock(true);
    } catch (_) {
      await stop();
    }
  }

  static Future<void> stop() async {
    final current = TvRemoteHost.current;
    TvRemoteHost.current = null;
    final listener = _listener;
    _listener = null;
    if (listener != null) _state?.removeListener(listener);
    if (current == null) return;
    await Device.holdMulticastLock(false);
    await current.stop();
    current.dispose();
  }

  static Future<void> setEnabled(bool on) async {
    final state = _state;
    final navigator = _navigator;
    if (state == null || navigator == null) return;
    await state.prefs.setRemoteEnabled(on);
    if (on) {
      await start(state, navigator);
    } else {
      await stop();
    }
  }
}

class AppTvRemoteActions implements TvRemoteActions {
  AppTvRemoteActions(this.state, this.navigator);

  final AppState state;
  final GlobalKey<NavigatorState> navigator;

  NavigatorState? get _nav => navigator.currentState;

  @override
  ({String server, String user}) get status => (
        server: state.client.hasServer ? state.client.baseUrl : '',
        user: state.currentUser?.username ?? '',
      );

  @override
  void key(RemoteKey key) {
    switch (key) {
      // 跟實體遙控器的返回鍵同一條路: 有 PopScope 的頁面 (播放頁先收控制列)
      // 照樣先問它. 首頁那一層不會被關掉 —— 手機上按返回不該把電視上的 App 關了
      case RemoteKey.back:
        unawaited(_nav?.maybePop());
      case RemoteKey.home:
        _nav?.popUntil((route) => route.isFirst);
      default:
        RemoteKeys.press(key);
    }
  }

  @override
  Future<String?> text(String value, {required bool submit}) async {
    if (RemoteKeys.type(value, submit: submit)) return null;
    final nav = _nav;
    if (nav == null || !state.hasServer || value.trim().isEmpty) {
      return '電視上現在沒有在等輸入的地方。';
    }
    // 沒有輸入框在等: 大概是想找片, 直接幫他開搜尋
    nav.popUntil((route) => route.isFirst);
    unawaited(nav.push(MaterialPageRoute<void>(
      builder: (_) => SearchPage(state: state, initialQuery: value.trim()),
    )));
    return null;
  }

  @override
  Future<String?> play(String sn, {double? at, bool streaming = false}) async {
    if (!state.hasServer) return '電視還沒設定伺服器，先把手機的設定傳過去。';
    if (state.needsLogin) return '電視上還沒登入，先把手機的設定傳過去 (會連同登入狀態)。';
    final nav = _nav;
    if (nav == null) return '電視上的 App 還沒準備好。';
    // 疊在上面的 (正在播的上一集、作品資訊、選單) 全部收掉再開, 返回鍵才會
    // 直接回到首頁, 而不是回到剛剛那一集
    nav.popUntil((route) => route.isFirst);
    unawaited(nav.push(MaterialPageRoute<void>(
      builder: (_) =>
          WatchPage(state: state, sn: sn, streaming: streaming, startAt: at),
    )));
    return null;
  }

  @override
  Future<String?> configure(String server, String token) async {
    final probe = AgpClient(baseUrl: server);
    try {
      await probe.serverInfo();
    } catch (_) {
      return '電視連不上 $server。電視跟伺服器要在同一個網路 (或伺服器對外開著)。';
    } finally {
      probe.close();
    }
    unawaited(state.applyRemoteSetup(server: probe.baseUrl, token: token));
    return null;
  }

  @override
  void showPairing(PairingRequest request) {
    final context = _nav?.overlay?.context;
    if (context == null) {
      request.reject();
      return;
    }
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PairingDialog(request: request),
    ));
  }

  @override
  void connected(String phoneName) {
    final context = _nav?.context;
    if (context != null) toast(context, '「$phoneName」連上來遙控這台電視了。');
  }
}

class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.request});

  final PairingRequest request;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  @override
  void initState() {
    super.initState();
    widget.request.finished.addListener(_finished);
  }

  void _finished() {
    if (!widget.request.finished.value || !mounted) return;
    // 只收自己: 這時候上面可能又疊了別的東西
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  void dispose() {
    widget.request.finished.removeListener(_finished);
    // 被返回鍵之類的關掉了: 手機那邊不能一直等一個看不到的配對碼
    if (!widget.request.finished.value) widget.request.reject();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.phone_android_rounded,
          size: 30, color: AgpColors.accent),
      title: Text('「${widget.request.phoneName}」想要遙控這台電視'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('在手機上輸入這組配對碼：',
              style: TextStyle(color: colors.onSurfaceVariant)),
          const SizedBox(height: 14),
          Text(
            widget.request.pin.split('').join(' '),
            key: const ValueKey('pairing-pin'),
            style: const TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w800,
              letterSpacing: 6,
              color: AgpColors.accent,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          Text('配對一次就好，之後這支手機會直接連上。',
              style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant)),
        ],
      ),
      actions: [
        // 刻意不給預設焦點: 看到對話框順手按一下確認鍵不該就拒絕掉
        TextButton(
          onPressed: widget.request.reject,
          child: const Text('拒絕'),
        ),
      ],
    );
  }
}
