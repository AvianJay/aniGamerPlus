/// 彈幕的 .ass 解析.
///
/// 檔案是 Danmu.py 產的, 每一行長這樣:
///   Dialogue: 0,0:01:23.40,0:01:35.40,Roll,,0,0,0,,{\move(...)\1c&H4CFFFFFF}內容
/// 版面 (第幾軌、跑多快) 在這裡一律不採信 —— 那是照 1920x1080 排的,
/// 手機上要重排, 所以只取「時間、樣式、顏色、文字」四樣.
library;

import 'package:flutter/material.dart';

enum DanmakuMode { scroll, top, bottom }

class DanmakuComment {
  final double start;
  final double end;
  final String text;
  final Color color;
  final DanmakuMode mode;

  const DanmakuComment({
    required this.start,
    required this.end,
    required this.text,
    required this.color,
    required this.mode,
  });
}

final RegExp _override = RegExp(r'\{[^}]*\}');
final RegExp _colorTag = RegExp(r'\\[1-4]?c&H([0-9a-fA-F]{6,8})&?');

double _parseTime(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length != 3) return 0;
  final hours = double.tryParse(parts[0]) ?? 0;
  final minutes = double.tryParse(parts[1]) ?? 0;
  final seconds = double.tryParse(parts[2]) ?? 0;
  return hours * 3600 + minutes * 60 + seconds;
}

Color _parseColor(String body) {
  final match = _colorTag.firstMatch(body);
  if (match == null) return Colors.white;
  var hex = match.group(1)!.toUpperCase();
  var alpha = 255;
  if (hex.length == 8) {
    // ASS 的 alpha 是反的: 00 全不透明, FF 全透明
    alpha = 255 - int.parse(hex.substring(0, 2), radix: 16);
    hex = hex.substring(2);
  }
  // &HBBGGRR
  final b = int.parse(hex.substring(0, 2), radix: 16);
  final g = int.parse(hex.substring(2, 4), radix: 16);
  final r = int.parse(hex.substring(4, 6), radix: 16);
  // 太暗的顏色在深色播放器上等於看不見, 拉一個下限
  final lift = (r + g + b) < 90 ? 90 : 0;
  return Color.fromARGB(
    alpha < 96 ? 200 : alpha,
    (r + lift).clamp(0, 255),
    (g + lift).clamp(0, 255),
    (b + lift).clamp(0, 255),
  );
}

String _plainText(String raw) => raw
    .replaceAll(_override, '')
    .replaceAll(r'\N', ' ')
    .replaceAll(r'\n', ' ')
    .replaceAll(r'\h', ' ')
    .trim();

/// 整份 .ass -> 依開始時間排好的彈幕
List<DanmakuComment> parseAss(String source) {
  final comments = <DanmakuComment>[];
  for (final line in source.split(RegExp(r'\r?\n'))) {
    if (!line.startsWith('Dialogue:')) continue;
    final body = line.substring('Dialogue:'.length);
    // Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    final fields = body.split(',');
    if (fields.length < 10) continue;

    final start = _parseTime(fields[1]);
    final end = _parseTime(fields[2]);
    final style = fields[3].trim().toLowerCase();
    final rawText = fields.sublist(9).join(',');
    final text = _plainText(rawText);
    if (text.isEmpty) continue;

    comments.add(DanmakuComment(
      start: start,
      end: end > start ? end : start + 5,
      text: text,
      color: _parseColor(rawText),
      mode: style == 'top'
          ? DanmakuMode.top
          : style == 'bottom'
              ? DanmakuMode.bottom
              : DanmakuMode.scroll,
    ));
  }
  comments.sort((a, b) => a.start.compareTo(b.start));
  return comments;
}
