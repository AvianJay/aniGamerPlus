/// agp-shell.js 裡那幾個小工具的 Dart 版.
///
/// 沒有封面的作品在網頁上是用片名 hash 出來的漸層當底圖, 這裡照抄同一組算式,
/// 同一部作品在手機上跟在瀏覽器上才會是同一個顏色.
library;

import 'package:flutter/material.dart';

/// DJB2-ish, 跟 agp-shell.js 的 artFor() 逐字對應.
int _hashOf(String name) {
  var hash = 0;
  for (final code in name.runes) {
    hash = ((hash << 5) + hash + code).toSigned(32);
  }
  return hash;
}

/// 片名 -> 穩定的兩色漸層.
LinearGradient artFor(String? name) {
  final text = (name ?? '').trim();
  final hash = _hashOf(text.isEmpty ? 'aniGamerPlus' : text);
  final hue = (hash % 360).abs().toDouble();
  final hue2 = ((hue + 38 + (hash % 40).abs()) % 360).toDouble();
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      HSLColor.fromAHSL(1, hue, 0.58, 0.26).toColor(),
      HSLColor.fromAHSL(1, hue2, 0.62, 0.15).toColor(),
    ],
  );
}

/// agp-shell.js 用的是 CJK / 諺文 / 全形符號那三段. 這裡直接比 code unit,
/// 免得正規表示式的跳脫在不同工具鏈之間被吃掉.
bool _hasCjk(String text) {
  for (final unit in text.codeUnits) {
    if (unit >= 0x3000 && unit <= 0x9fff) return true;
    if (unit >= 0xac00 && unit <= 0xd7af) return true;
    if (unit >= 0xff00 && unit <= 0xffef) return true;
  }
  return false;
}

/// 沒有封面時蓋在漸層上的字. 中日韓取前兩個字, 拉丁字母取前兩個單字的首字母.
String initials(String? name) {
  final text = (name ?? '').trim();
  if (text.isEmpty) return '?';
  if (_hasCjk(text)) {
    return text.length <= 2 ? text : text.substring(0, 2);
  }
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  return words
      .take(2)
      .map((w) => w.substring(0, 1).toUpperCase())
      .join();
}

/// 秒 -> 0:00 / 0:00:00
String formatClock(num? seconds) {
  final total = (seconds ?? 0).isFinite ? (seconds ?? 0).round() : 0;
  if (total <= 0) return '0:00';
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
  return h > 0
      ? '$h:$mm:${s.toString().padLeft(2, '0')}'
      : '$mm:${s.toString().padLeft(2, '0')}';
}

String formatDuration(Duration d) => formatClock(d.inSeconds);

/// 播放器時間軸專用: 分鐘一律補到兩位, 跟動畫瘋一樣寫成 04:09.
///
/// formatClock() 在不滿十分鐘時寫 4:09, 那會讓整條時間軸在跨過 9:59 跟
/// 59:59 的時候整個橫向跳一格.
String formatPlayerClock(num? seconds) {
  final text = formatClock(seconds);
  final head = text.indexOf(':');
  if (head == 1) return '0$text';
  return text;
}

/// 人氣: 站上寫的是 "65萬", 這裡把原始數字也折成同一種寫法.
String formatCount(dynamic raw) {
  final text = (raw ?? '').toString().trim();
  if (text.isEmpty) return '';
  final number = int.tryParse(text);
  if (number == null) return text;
  if (number < 10000) return number.toString();
  var value = (number / 10000.0).toStringAsFixed(1);
  if (value.endsWith('.0')) value = value.substring(0, value.length - 2);
  return '$value萬';
}

const List<String> weekdayLabels = ['週一', '週二', '週三', '週四', '週五', '週六', '週日'];

/// 巴哈的星期是 1=週一 … 7=週日, DateTime.weekday 剛好一樣.
int bahamutWeekday(DateTime when) => when.weekday;

String dayKey(DateTime when) =>
    '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}';

/// 今天 / 昨天 / 9/6 週六
String dayLabel(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(when.year, when.month, when.day);
  final diff = today.difference(that).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  const names = ['週一', '週二', '週三', '週四', '週五', '週六', '週日'];
  return '${when.month}/${when.day} ${names[when.weekday - 1]}';
}

String clockOf(DateTime when) =>
    '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';

/// home.js 的 episodeLabel(): 純數字就是「第 N 集」, 有字就照原樣, 都沒有算單集.
String episodeLabel(dynamic episode) {
  final text = (episode ?? '').toString().trim();
  if (text.isEmpty) return '單集';
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) {
    final value = double.parse(text);
    final shown = value == value.roundToDouble()
        ? value.round().toString()
        : text;
    return '第 $shown 集';
  }
  return text;
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// 貼上動畫瘋的連結時, 只留下 sn.
String snFromInput(String raw) {
  final text = raw.trim();
  final match = RegExp(r'sn=(\d+)').firstMatch(text);
  if (match != null) return match.group(1)!;
  final digits = RegExp(r'^\d+$');
  return digits.hasMatch(text) ? text : '';
}
