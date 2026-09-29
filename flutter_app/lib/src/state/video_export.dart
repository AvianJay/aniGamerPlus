/// 把下載到手機的集數存到 App 外面.
///
/// 下載好的檔案躺在 App 自己的 documents 裡, 檔名是 `<sn>-<解析度>p.mp4` ——
/// 別的播放器找不到, 移除 App 也會一起消失. 匯出就是把它們複製到使用者用系統
/// 選擇器挑的位置, 順便換成看得懂的名字. 彈幕 .ass 取同一個主檔名, VLC、mpv
/// 這類播放器會自己把它當字幕載入.
library;

import 'dart:convert';

import 'package:file_export/file_export.dart';

import 'downloads.dart';

/// 主檔名的上限 (UTF-8 位元組). 大多數檔案系統一個檔名最多 255 位元組,
/// 中文一個字就佔 3 個, 還要留給副檔名跟提供者撞名時補的「 (1)」.
const int kExportNameMaxBytes = 200;

/// 跟伺服器 Config.legalize_filename 同一套: 不能放進檔名的字換成全形,
/// 這樣匯出的檔名跟伺服器片庫裡的長得一樣.
String legalizeFileName(String name) {
  const replacements = {
    '|': '｜',
    '?': '？',
    '*': '＊',
    '<': '＜',
    '>': '＞',
    '"': '＂',
    ':': '：',
    '\\': '＼',
    '/': '／',
  };
  final buffer = StringBuffer();
  String? last;
  for (final rune in name.runes) {
    final char = String.fromCharCode(rune);
    // 控制字元不管哪個檔案系統都不收
    if (rune < 0x20 || rune == 0x7f) continue;
    final mapped = replacements[char];
    if (mapped == null) {
      buffer.write(char);
      last = null;
      continue;
    }
    // 伺服器那邊是 re.sub(r'\|+', '｜') —— 連續好幾個只留一個 (斜線跟反斜線例外)
    if (mapped == last && char != '\\' && char != '/') continue;
    buffer.write(mapped);
    last = mapped;
  }
  // 開頭的點會變成隱藏檔, 結尾的點跟空白在 FAT / Windows 上會被吃掉
  return buffer.toString().trim().replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
}

String _truncateUtf8(String text, int maxBytes) {
  if (utf8.encode(text).length <= maxBytes) return text;
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final size = utf8.encode(char).length;
    if (used + size > maxBytes) break;
    buffer.write(char);
    used += size;
  }
  return buffer.toString().trimRight();
}

/// 跟伺服器預設的命名 (Anime.py 的 __get_filename) 一樣: 作品名[集數][解析度P],
/// 只是不加「【動畫瘋】」那個前綴 —— 那是伺服器設定裡可以改的, App 這邊不知道.
String exportBaseName(DownloadEntry entry) {
  final name = entry.displayName.trim();
  final episode = entry.episode.trim();
  final buffer = StringBuffer(name.isNotEmpty ? name : entry.sn);
  if (episode.isNotEmpty) buffer.write('[$episode]');
  if (entry.resolution > 0) buffer.write('[${entry.resolution}P]');
  final legal = legalizeFileName(buffer.toString());
  return _truncateUtf8(
      legal.isNotEmpty ? legal : entry.sn, kExportNameMaxBytes);
}

/// 要交給 [FileExport.save] 的檔案清單.
///
/// 本機檔案已經不見的集數直接略過. 兩集湊出同一個主檔名的話 (片庫沒填作品名、
/// 標題又一樣) 後面那集補上 sn —— 不然存進同一個資料夾時提供者會自己改名,
/// 彈幕檔就對不上影片了.
List<ExportFile> exportFilesFor(
  DownloadStore store,
  Iterable<DownloadEntry> entries, {
  required bool withDanmaku,
}) {
  final files = <ExportFile>[];
  final used = <String>{};
  for (final entry in entries) {
    final video = store.localVideo(entry.sn);
    if (video == null) continue;
    var base = exportBaseName(entry);
    if (!used.add(base.toLowerCase())) {
      base = '$base-${entry.sn}';
      used.add(base.toLowerCase());
    }
    files.add(ExportFile(
      path: video.path,
      name: '$base.mp4',
      mimeType: 'video/mp4',
    ));
    final danmaku = withDanmaku ? store.localDanmaku(entry.sn) : null;
    if (danmaku != null) {
      files.add(ExportFile(
        path: danmaku.path,
        name: '$base.ass',
        // 故意不寫 text/x-ssa: Android 的文件提供者看到認得的 MIME 會照它改
        // 副檔名, 認不得的 (或 octet-stream) 才會照檔名原樣存
        mimeType: 'application/octet-stream',
      ));
    }
  }
  return files;
}
