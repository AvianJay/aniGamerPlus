/// 彈幕層: 什麼時候該跑、什麼時候該停, 還有畫的方式.
///
/// 它一跑, 每一個 vsync 就要把整個畫面 (連影片) 重新合成一次 —— 120Hz 的
/// iPad 上就是一秒一百二十次. 所以「沒事做就停」跟「畫得對」一樣重要; 而每一
/// 幀要做的事也要夠少: 一條彈幕只畫一次, 之後只是貼圖.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agp_mobile/src/danmaku/ass.dart';
import 'package:agp_mobile/src/danmaku/danmaku_overlay.dart';

DanmakuComment comment(double start,
        [String text = '彈幕', DanmakuMode mode = DanmakuMode.scroll]) =>
    DanmakuComment(
      start: start,
      end: start + 5,
      text: text,
      color: Colors.white,
      mode: mode,
    );

void main() {
  var now = 0.0;
  const frame = ValueKey('frame');

  Future<void> show(WidgetTester tester, List<DanmakuComment> comments,
      {bool playing = true, double rate = 1, double opacity = 1}) {
    return tester.pumpWidget(MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: frame,
          child: SizedBox(
            width: 800,
            height: 450,
            child: DanmakuOverlay(
              comments: comments,
              position: () => now,
              playing: playing,
              rate: rate,
              opacity: opacity,
            ),
          ),
        ),
      ),
    ));
  }

  /// 畫面最上面那一條 (置頂彈幕那一軌) 最不透明的一個像素
  Future<int> topBandAlpha(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(frame));
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      var best = 0;
      for (var y = 0; y < 40; y++) {
        for (var x = 0; x < image.width; x++) {
          final alpha = bytes!.getUint8((y * image.width + x) * 4 + 3);
          if (alpha > best) best = alpha;
        }
      }
      image.dispose();
      return best;
    }))!;
  }

  /// 照真實時間往前播: 媒體時間跟每一幀的時間要對得上, 不然彈幕層會 (正確地)
  /// 把跳過去的那一段當成使用者拉了進度條
  Future<void> play(WidgetTester tester, double until) async {
    while (now < until - 1e-9) {
      now = (now + 0.05).clamp(0.0, until);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() => now = 0);

  testWidgets('字真的畫得出來, 透明度照樣生效', (tester) async {
    final comments = [comment(0.1, 'danmaku', DanmakuMode.top)];
    await show(tester, comments);
    await play(tester, 0.3);
    final solid = await topBandAlpha(tester);
    expect(solid, greaterThan(200), reason: '置頂那一條沒畫出來');

    await show(tester, comments, opacity: 0.25);
    await tester.pump(const Duration(milliseconds: 16));
    final faint = await topBandAlpha(tester);
    expect(faint, lessThan(solid * 0.5), reason: '透明度沒有套上去');
    expect(faint, greaterThan(0), reason: '調低透明度之後整條不見了');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('一條彈幕只畫一次, 之後每一幀只是換位置', (tester) async {
    final comments = [comment(0.1, '一'), comment(0.2, '二')];
    await show(tester, comments);
    final before = debugDanmakuRasterized;
    await play(tester, 3);
    expect(debugDanmakuRasterized - before, 2,
        reason: '兩條彈幕在畫面上待了六十幀, 應該只畫兩次');

    // 調透明度也不必重畫
    await show(tester, comments, opacity: 0.5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(debugDanmakuRasterized - before, 2, reason: '調個透明度就整層重畫');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收掉的彈幕要把圖還回去', (tester) async {
    final alive = debugDanmakuSpritesAlive;
    final comments = [comment(0.1), comment(0.2), comment(0.3)];
    await show(tester, comments);
    await play(tester, 0.4);
    expect(debugDanmakuSpritesAlive - alive, 3);
    // 一路播到捲完 (九秒)
    await play(tester, 10);
    expect(debugDanmakuSpritesAlive - alive, 0, reason: '過期的彈幕沒有還圖');

    // 往回拉: 整層重來, 手上那幾條也要還
    now = 0;
    await show(tester, comments);
    await play(tester, 0.4);
    expect(debugDanmakuSpritesAlive - alive, 3);
    await tester.pumpWidget(const SizedBox());
    expect(debugDanmakuSpritesAlive - alive, 0, reason: '整層拆掉時沒有還圖');
  });

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
