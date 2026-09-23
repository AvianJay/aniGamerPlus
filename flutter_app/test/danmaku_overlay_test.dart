/// 彈幕層的 ticker 什麼時候該跑、什麼時候該停.
///
/// 它一跑, 每一個 vsync 就要把整個畫面 (連影片) 重新合成一次 —— 120Hz 的
/// iPad 上就是一秒一百二十次. 所以「沒事做就停」跟「畫得對」一樣重要.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agp_mobile/src/danmaku/ass.dart';
import 'package:agp_mobile/src/danmaku/danmaku_overlay.dart';

DanmakuComment comment(double start, [String text = '彈幕']) => DanmakuComment(
      start: start,
      end: start + 5,
      text: text,
      color: Colors.white,
      mode: DanmakuMode.scroll,
    );

void main() {
  var now = 0.0;

  Future<void> show(WidgetTester tester, List<DanmakuComment> comments,
      {bool playing = true, double rate = 1}) {
    return tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 800,
          height: 450,
          child: DanmakuOverlay(
            comments: comments,
            position: () => now,
            playing: playing,
            rate: rate,
          ),
        ),
      ),
    ));
  }

  setUp(() => now = 0);

  testWidgets('下一條還要很久才出現: 先睡, 快到了再醒', (tester) async {
    final comments = [comment(30)];
    await show(tester, comments);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: '下一條彈幕還要 30 秒, 這段時間不該每一幀空轉');

    // 時間到了 (叫醒的計時器是照播放速度算的)
    now = 29.6;
    await tester.pump(const Duration(seconds: 30));
    expect(tester.binding.hasScheduledFrame, isTrue, reason: '快到了卻沒醒來');

    // 出場之後每一幀都要動
    now = 30.1;
    await tester.pump(const Duration(milliseconds: 16));
    now = 30.2;
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('兩倍速的時候提早一半的時間醒來', (tester) async {
    await show(tester, [comment(30)], rate: 2);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);
    // 媒體時間還差 29.5 秒, 兩倍速的話真實時間只要 15 秒不到
    now = 29.6;
    await tester.pump(const Duration(seconds: 15));
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: '照一倍速算醒來的時間, 兩倍速時會錯過開頭那幾條');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('暫停了就停下來, 再播就醒來', (tester) async {
    final comments = [comment(0.1, '一'), comment(0.2, '二')];
    await show(tester, comments);
    for (final at in [0.05, 0.15, 0.25, 0.3]) {
      now = at;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.hasScheduledFrame, isTrue, reason: '畫面上有字在跑');

    await show(tester, comments, playing: false);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: '暫停著, 彈幕層卻還在每一幀空轉');

    await show(tester, comments);
    expect(tester.binding.hasScheduledFrame, isTrue, reason: '按了播放卻沒醒來');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('一集的彈幕都跑完了就不再醒來', (tester) async {
    now = 100;
    await show(tester, [comment(1), comment(2)]);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
