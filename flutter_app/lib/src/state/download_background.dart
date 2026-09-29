import 'dart:async';

import 'package:background_download/background_download.dart';
import 'package:flutter/widgets.dart';

import 'downloads.dart';

/// 下載在背景繼續跑, 系統上看得到進度.
///
/// * 有下載在進行 (或在排隊 / 等伺服器) 的時候, 把整批的進度送給
///   [BackgroundDownload]: Android 是前景服務的通知 (Android 16 起是 Live
///   Update), iOS 是動態島 / 鎖定畫面的即時動態. 全部做完 / 暫停 / 被網路設定
///   擋住就收掉, 這一批有抓完的話換成「下載完成」.
/// * App 進背景時告訴 [DownloadStore]: iOS 上排隊的要趁還沒被暫停全部交給系統.
class DownloadBackground with WidgetsBindingObserver {
  DownloadBackground(this.store) {
    store.addListener(_onChanged);
    WidgetsBinding.instance.addObserver(this);
    _onChanged();
  }

  final DownloadStore store;

  /// 進度最快多久送一次 —— 每個 chunk 都送的話光是跨平台丟訊息就很忙
  static const Duration minInterval = Duration(seconds: 1);

  bool _showing = false;

  /// 這一批出現過的集數 (開始顯示之後排進來的都算), 跟其中已經抓完的.
  /// 進度條切段、「3/5 集」、最後的「已下載 N 集」都是照這一批算的.
  final Set<String> _batch = {};
  final Set<String> _batchDone = {};

  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _timer;
  bool _disposed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        store.setBackgrounded(false);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        store.setBackgrounded(true);
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onChanged() {
    if (_disposed || _timer != null) return;
    final wait = minInterval - DateTime.now().difference(_lastPush);
    if (wait <= Duration.zero) {
      _push();
    } else {
      _timer = Timer(wait, () {
        _timer = null;
        _push();
      });
    }
  }

  void _push() {
    if (_disposed) return;
    _lastPush = DateTime.now();

    final running = <DownloadEntry>[];
    var pending = 0;
    for (final entry in store.entries) {
      switch (entry.status) {
        case DownloadStatus.running:
          running.add(entry);
          _batch.add(entry.sn);
        case DownloadStatus.queued:
        case DownloadStatus.waiting:
          pending++;
          _batch.add(entry.sn);
        case DownloadStatus.done:
          if (_batch.contains(entry.sn)) _batchDone.add(entry.sn);
        case DownloadStatus.paused:
        case DownloadStatus.failed:
          break;
      }
    }
    // 被刪掉的集數不算在這一批裡
    _batch.removeWhere((sn) => store.entryFor(sn) == null);
    _batchDone.removeWhere((sn) => !_batch.contains(sn));

    final busy = store.networkAllowed && (running.isNotEmpty || pending > 0);
    if (!busy) {
      if (_showing) {
        _showing = false;
        unawaited(BackgroundDownload.stop(
          doneTitle: _batchDone.isEmpty ? null : '下載完成',
          doneText: _batchDone.isEmpty ? null : _doneText(),
        ));
      }
      _batch.clear();
      _batchDone.clear();
      return;
    }
    _showing = true;

    // 整批的進度: 抓完的一集算一整段, 在跑的照位元組算, 排隊的算零.
    // 有一集還不知道總長的話, 那一集先算零, 不要讓整條亂跳.
    final count = _batch.length;
    var sum = _batchDone.length.toDouble();
    for (final entry in running) {
      if (entry.total > 0) sum += entry.progress;
    }
    final double? overall =
        running.isEmpty && _batchDone.isEmpty ? null : sum / count;

    final String title;
    if (running.length == 1) {
      final entry = running.first;
      title = [entry.displayName, entry.episode]
          .where((part) => part.isNotEmpty)
          .join(' ');
    } else if (running.isNotEmpty) {
      title = '下載中 ${running.length} 集';
    } else {
      title = '等待下載';
    }

    final details = <String>[
      if (count > 1) '${_batchDone.length}/$count 集',
      if (pending > 0) '$pending 集排隊中',
      if (running.length == 1 && running.first.total > 0)
        '${_mb(running.first.received)} / ${_mb(running.first.total)}',
    ];

    unawaited(BackgroundDownload.update(
      title: title.isEmpty ? '下載中' : title,
      text: details.isEmpty ? '下載中' : details.join(' · '),
      progress: overall,
      segments: count,
      shortText: overall == null ? '' : '${(overall * 100).floor()}%',
    ));
  }

  String _doneText() {
    if (_batchDone.length == 1) {
      final entry = store.entryFor(_batchDone.first);
      if (entry != null) {
        final name = [entry.displayName, entry.episode]
            .where((part) => part.isNotEmpty)
            .join(' ');
        if (name.isNotEmpty) return name;
      }
    }
    return '已下載 ${_batchDone.length} 集';
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_onChanged);
    if (_showing) unawaited(BackgroundDownload.stop());
  }
}
