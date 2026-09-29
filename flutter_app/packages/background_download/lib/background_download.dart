/// 下載在 App 退到背景之後還能繼續跑, 而且看得到進度.
///
/// * [BackgroundDownload]: 下載中掛在系統上的進度.
///   - Android: dataSync 前景服務 + 常駐通知, 同時持有 CPU / Wi-Fi 鎖, 行程
///     不會在背景被凍結. Android 16 起通知改用進度樣式 (ProgressStyle) 並要求
///     升級成 Live Update —— 鎖定畫面置頂, 狀態列多一顆顯示百分比的膠囊.
///   - iOS: 動態島 / 鎖定畫面的即時動態 (Live Activity).
/// * [NativeTransfer]: 只有 iOS. App 被系統暫停之後 Dart 就不會再跑了, 前景
///   服務那一招在 iOS 上不存在, 所以影片檔整支交給系統的背景 URLSession 抓,
///   抓完系統才把 App 叫醒來收尾.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('background_download');

class BackgroundDownload {
  BackgroundDownload._();

  static MethodChannel get channel => _channel;

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  /// 啟動 (或更新) 下載中的進度顯示.
  ///
  /// [progress] 0~1, 不知道總量時給 null. [segments] 是這一批有幾集 ——
  /// Android 16 的進度條會切成那麼多段. [shortText] 是狀態列膠囊 / 動態島
  /// 縮起來時那一小格字, 例如「42%」.
  static Future<void> update({
    required String title,
    required String text,
    double? progress,
    int segments = 1,
    String shortText = '',
  }) =>
      _invoke('update', {
        'title': title,
        'text': text,
        'progress':
            progress == null ? -1 : (progress.clamp(0.0, 1.0) * 1000).round(),
        'segments': segments < 1 ? 1 : segments,
        'shortText': shortText,
      });

  /// 沒有下載了, 收掉進度顯示.
  ///
  /// 給了 [doneTitle] 表示這一批有抓完的: Android 另外發一則「下載完成」通知,
  /// iOS 的即時動態換成完成的樣子, 在鎖定畫面上多留一會兒.
  static Future<void> stop({String? doneTitle, String? doneText}) =>
      _invoke('stop', {
        if (doneTitle != null) 'doneTitle': doneTitle,
        if (doneText != null) 'doneText': doneText,
      });

  static Future<void> _invoke(String method, Object? arguments) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // widget test / 沒註冊外掛的環境
    } on PlatformException {
      // 系統不給起 (例如 App 已經在背景才想起前景服務) —— 下載本身照跑
    }
  }
}

/// 原生那邊回報的進度. [received] / [total] 都是整支檔案的位元組數,
/// 已經把續傳的起點算進去了.
class TransferProgress {
  const TransferProgress({
    required this.sn,
    required this.received,
    required this.total,
    this.fileName = '',
  });

  final String sn;
  final int received;
  final int total;
  final String fileName;

  factory TransferProgress.fromMap(Map<dynamic, dynamic> map) =>
      TransferProgress(
        sn: '${map['sn'] ?? ''}',
        received: (map['received'] as num?)?.toInt() ?? 0,
        total: (map['total'] as num?)?.toInt() ?? 0,
        fileName: '${map['name'] ?? ''}',
      );
}

enum TransferStatus {
  /// 影片檔已經在 `directory/fileName` 了
  done,

  /// 伺服器 404: 伺服器那邊還沒抓完
  notFound,
  failed,

  /// 被叫停 (暫停、網路設定、使用者把 App 滑掉). 抓到一半的部分原生那邊會留著
  /// 續傳資料, 下次 [NativeTransfer.start] 同一個檔名時接著抓.
  cancelled,
}

class TransferResult {
  const TransferResult({
    required this.sn,
    required this.status,
    this.received = 0,
    this.total = 0,
    this.error = '',
    this.fileName = '',
  });

  final String sn;
  final TransferStatus status;
  final int received;
  final int total;
  final String error;
  final String fileName;

  factory TransferResult.fromMap(Map<dynamic, dynamic> map) => TransferResult(
        sn: '${map['sn'] ?? ''}',
        status: TransferStatus.values.firstWhere(
          (status) => status.name == map['status'],
          orElse: () => TransferStatus.failed,
        ),
        received: (map['received'] as num?)?.toInt() ?? 0,
        total: (map['total'] as num?)?.toInt() ?? 0,
        error: '${map['error'] ?? ''}',
        fileName: '${map['name'] ?? ''}',
      );
}

/// App 起來時原生那邊的樣子: 還在抓的, 跟 Dart 不在的時候做完的.
class TransferSnapshot {
  const TransferSnapshot({required this.running, required this.results});

  final List<TransferProgress> running;
  final List<TransferResult> results;
}

/// iOS: 用系統的背景 URLSession 抓影片檔.
///
/// 續傳沿用 Dart 那邊的 `.part`: [start] 的 `offset` 就是 `.part` 現在的長度,
/// 原生那邊送 `Range: bytes=offset-`, 抓完把剩下的接到 `.part` 後面再改名成
/// 正式檔名. 做完的結果會先落盤再通知, 所以 Dart 不在的時候 (App 被系統收掉、
/// 只在背景被叫醒) 做完的集數, 下次 [snapshot] 還拿得到, 拿到之後 [ack].
class NativeTransfer {
  NativeTransfer({MethodChannel? channel}) : _ch = channel ?? _channel {
    _ch.setMethodCallHandler(_handle);
  }

  static NativeTransfer? _platform;

  /// 這個平台要不要走原生傳輸. 只有 iOS 需要.
  static NativeTransfer? get platform {
    if (!Platform.isIOS) return null;
    return _platform ??= NativeTransfer();
  }

  final MethodChannel _ch;
  final StreamController<TransferProgress> _progress =
      StreamController<TransferProgress>.broadcast();
  final StreamController<TransferResult> _results =
      StreamController<TransferResult>.broadcast();

  Stream<TransferProgress> get progress => _progress.stream;
  Stream<TransferResult> get results => _results.stream;

  /// 原生那邊把工作建好、開始跑了才回來. 同一個 [sn] 已經在跑的話什麼都不做.
  Future<void> start({
    required String sn,
    required Uri url,
    required Map<String, String> headers,
    required String directory,
    required String fileName,
    required int offset,
    required bool allowCellular,
    required String label,
  }) =>
      _ch.invokeMethod<void>('download.start', {
        'sn': sn,
        'url': url.toString(),
        'headers': headers,
        'directory': directory,
        'name': fileName,
        'offset': offset,
        'allowCellular': allowCellular,
        'label': label,
      });

  /// 叫停, 留著續傳資料. 真的有東西被停掉才回 true —— 之後會再來一個
  /// [TransferStatus.cancelled] 的結果.
  Future<bool> cancel(String sn) async =>
      await _ch.invokeMethod<bool>('download.cancel', {'sn': sn}) ?? false;

  /// 丟掉某個檔名留下來的續傳資料 (那一集被刪掉了)
  Future<void> discard(String fileName) =>
      _ch.invokeMethod<void>('download.discard', {'name': fileName});

  Future<TransferSnapshot> snapshot() async {
    final raw = await _ch.invokeMapMethod<String, dynamic>('download.snapshot');
    final running = (raw?['running'] as List?) ?? const [];
    final results = (raw?['results'] as List?) ?? const [];
    return TransferSnapshot(
      running: [
        for (final item in running.whereType<Map>())
          TransferProgress.fromMap(item),
      ],
      results: [
        for (final item in results.whereType<Map>()) TransferResult.fromMap(item),
      ],
    );
  }

  /// 這個結果 Dart 已經處理好了, 原生那邊可以忘掉它.
  Future<void> ack(String sn) =>
      _ch.invokeMethod<void>('download.ack', {'sn': sn});

  Future<void> _handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'download.progress':
        _progress.add(TransferProgress.fromMap(args));
      case 'download.result':
        _results.add(TransferResult.fromMap(args));
    }
  }
}
