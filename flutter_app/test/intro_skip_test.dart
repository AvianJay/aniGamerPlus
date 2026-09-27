import 'package:agp_mobile/src/danmaku/ass.dart';
import 'package:agp_mobile/src/state/intro_skip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DanmakuComment comment(double at, String text) => DanmakuComment(
        start: at,
        end: at + 5,
        text: text,
        color: Colors.white,
        mode: DanmakuMode.scroll,
      );

  test('a single air-drop claim and end-of-episode trolls never create a skip',
      () {
    expect(
        danmakuIntro([
          comment(12, '空降 23:45'),
          comment(20, '空降 23:45'),
          comment(40, 'OP 結束 23:45'),
          comment(50, '空降 1:30'),
        ], 1440),
        isNull);
  });

  test('several close and independent early claims allow a manual skip', () {
    final intro = danmakuIntro([
      comment(10, '空降 1:30'),
      comment(22, '片頭結束 1:32'),
      comment(34, '跳過OP 1:29'),
      comment(40, '空降 23:45'),
    ], 1440);
    expect(intro?.source, '彈幕');
    expect(intro?.end, closeTo(90, 3));
    expect(intro?.visibleAt(30), isTrue);
    expect(intro?.visibleAt(89), isFalse);
  });
}
