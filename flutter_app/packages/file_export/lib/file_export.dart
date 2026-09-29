/// 把 App 沙盒裡的檔案存到使用者自己選的位置.
///
/// 兩邊都交給系統的選擇器, 所以不需要任何儲存空間權限:
///
/// * Android: 儲存空間存取架構 (SAF). 一個檔案開「建立文件」, 可以順便改名;
///   好幾個檔案就請使用者選一個資料夾, 一支一支建進去. 複製在背景執行緒跑,
///   進度透過 [FileExport.save] 的 `onProgress` 回報, 中途可以 [FileExport.cancel].
/// * iOS: 檔案 App 的匯出面板 (`UIDocumentPickerViewController`). 複製是系統
///   自己做的, 不會有進度, 也停不下來.
library;

import 'package:flutter/services.dart';

/// 一個要匯出的檔案: 手機上的路徑, 跟存出去時要叫的名字.
class ExportFile {
  const ExportFile({
    required this.path,
    required this.name,
    this.mimeType = 'application/octet-stream',
  });

  final String path;
  final String name;
  final String mimeType;

  Map<String, String> toMap() => {
        'path': path,
        'name': name,
        'mimeType': mimeType,
      };
}

class ExportResult {
  const ExportResult({required this.saved, required this.cancelled});

  /// 真的存好的檔案數
  final int saved;

  /// 使用者在選位置時按了取消, 或是複製到一半叫停
  final bool cancelled;
}

/// 已經寫出去幾個位元組 / 總共要寫幾個位元組
typedef ExportProgress = void Function(int copied, int total);

class FileExport {
  FileExport._();

  static const MethodChannel channel = MethodChannel('file_export');

  static ExportProgress? _onProgress;
  static bool _listening = false;
  static bool _busy = false;

  /// 請使用者選位置, 然後把 [files] 複製過去.
  ///
  /// 在使用者選好位置之前不會有任何進度; 第一次 `onProgress` 就代表複製開始了.
  /// 失敗時丟 [PlatformException], `details['saved']` 是失敗前已經存好的檔案數.
  static Future<ExportResult> save(
    List<ExportFile> files, {
    ExportProgress? onProgress,
  }) async {
    if (files.isEmpty) {
      return const ExportResult(saved: 0, cancelled: false);
    }
    // 原生那邊也會擋, 但在這裡先擋下來, 才不會把前一次的進度回呼換掉
    if (_busy) {
      throw PlatformException(code: 'busy', message: '上一個匯出還沒結束');
    }
    if (!_listening) {
      _listening = true;
      channel.setMethodCallHandler(_handle);
    }
    _busy = true;
    _onProgress = onProgress;
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>('save', {
        'files': [for (final file in files) file.toMap()],
      });
      return ExportResult(
        saved: (raw?['saved'] as num?)?.toInt() ?? 0,
        cancelled: raw?['cancelled'] == true,
      );
    } finally {
      _onProgress = null;
      _busy = false;
    }
  }

  /// 叫正在跑的複製停下來. 寫到一半的那個檔案會被刪掉, 已經寫完的留著.
  static Future<void> cancel() => channel.invokeMethod<void>('cancel');

  static Future<void> _handle(MethodCall call) async {
    if (call.method != 'progress') return;
    final args = (call.arguments as Map?) ?? const {};
    _onProgress?.call(
      (args['copied'] as num?)?.toInt() ?? 0,
      (args['total'] as num?)?.toInt() ?? 0,
    );
  }
}
