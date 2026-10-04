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
      {bool playing = true,
      double rate = 1,
      double opacity = 1,
      bool lowPower = false,
      double scale = 1,
      double pixelRatio = 1,
      bool framesEnabled = true,
      int timeline = 0,
      bool enabled = true}) {
    return tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: pixelRatio),
        child: Center(
          child: RepaintBoundary(
            key: frame,
            child: SizedBox(
              width: 800,
              height: 450,
              child: TickerMode(
                enabled: framesEnabled,
                child: DanmakuOverlay(
                  comments: comments,
                  position: () => now,
                  playing: playing,
                  rate: rate,
                  opacity: opacity,
                  lowPower: lowPower,
                  scale: scale,
                  enabled: enabled,
                  timeline: timeline,
                ),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  /// 畫面最上面那一條 (置頂彈幕那一軌) 最不透明的一個像素
  Future<int> topBandAlpha(WidgetTester tester) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(frame));
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

  for (final hz in [60.0, 120.0]) {
    testWidgets('電視在 ${hz.toInt()}Hz 均勻每 30fps 重畫, 避免短長幀交替', (tester) async {
      tester.view.display.refreshRate = hz;
      addTearDown(tester.view.display.resetRefreshRate);
      await show(tester, [comment(0.1, 'smooth')], lowPower: true);
      await play(tester, 0.3);
      final frame = Duration(microseconds: (1000000 / hz).round());
      final indices = <int>[];
      var paints = debugDanmakuPaints;
      for (var i = 0; i < hz.toInt(); i++) {
        now += frame.inMicroseconds / 1000000;
        await tester.pump(frame);
        if (debugDanmakuPaints > paints) indices.add(i);
        paints = debugDanmakuPaints;
      }
      expect(indices.length, inInclusiveRange(28, 32));
      for (var i = 1; i < indices.length; i++) {
        expect(indices[i] - indices[i - 1], (hz / 30).round());
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

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
    expect(debugDanmakuRasterized - before, 2, reason: '兩條彈幕在畫面上待了六十幀, 應該只畫兩次');

    // 調透明度也不必重畫
    await show(tester, comments, opacity: 0.5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(debugDanmakuRasterized - before, 2, reason: '調個透明度就整層重畫');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('電視只有一條捲動彈幕也限制整個引擎的幀排程, 手機維持 vsync', (tester) async {
    for (final lowPower in [true, false]) {
      now = 0;
      await show(tester, [comment(0)], lowPower: lowPower);
      await tester.pump();
      final paints = debugDanmakuPaints;
      var continuousFrames = 0;
      // 用 120Hz 畫面測試, 不能只減少畫圖卻繼續讓 ticker 每一幀叫醒引擎.
      for (var i = 0; i < 120; i++) {
        now += 1 / 120;
        await tester.pump(const Duration(microseconds: 8333));
        if (tester.binding.hasScheduledFrame) continuousFrames++;
      }
      final count = debugDanmakuPaints - paints;
      expect(count, lowPower ? inInclusiveRange(28, 31) : greaterThan(110));
      expect(continuousFrames, lowPower ? 0 : 120,
          reason: '在 ticker 裡略過 paint 仍會讓引擎合成影片');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('電視限幀仍跟上播放時鐘, 暫停後休眠, 恢復與切換模式能繼續', (tester) async {
    final alive = debugDanmakuSpritesAlive;
    final comments = [comment(0), comment(30, 'seek', DanmakuMode.top)];
    await show(tester, comments, lowPower: true);
    await tester.pump();
    await play(tester, 1);
    expect(debugDanmakuSpritesAlive - alive, 1);
    await show(tester, comments, lowPower: true, playing: false);
    await tester.pump(const Duration(milliseconds: 40));
    final paused = debugDanmakuPaints;
    await tester.pump(const Duration(seconds: 1));
    expect(debugDanmakuPaints, paused);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await show(tester, comments, lowPower: true);
    await play(tester, 2);
    expect(debugDanmakuPaints, greaterThan(paused));

    now = 30;
    await tester.pump(const Duration(milliseconds: 40));
    expect(debugDanmakuSpritesAlive - alive, 1);
    expect(await topBandAlpha(tester), greaterThan(0));
    await show(tester, comments, lowPower: false, playing: false);
    await tester.pump();
    expect(await topBandAlpha(tester), greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    expect(debugDanmakuSpritesAlive, alive);
  });

  testWidgets('電視彈幕被其他頁面遮住時停止要求幀, 返回後恢復', (tester) async {
    final comments = [comment(0)];
    await show(tester, comments, lowPower: true);
    await tester.pump();
    await play(tester, 0.5);
    await show(tester, comments, lowPower: true, framesEnabled: false);
    await tester.pump();
    final hidden = debugDanmakuPaints;
    await play(tester, 1);
    expect(debugDanmakuPaints, hidden);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await show(tester, comments, lowPower: true);
    await play(tester, 1.5);
    expect(debugDanmakuPaints, greaterThan(hidden));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('電視只有固定彈幕時不要求影片合成幀, 下一條與過期時間仍正常', (tester) async {
    final alive = debugDanmakuSpritesAlive;
    await show(
        tester,
        [
          comment(0, 'still', DanmakuMode.top),
          comment(2, 'next'),
        ],
        lowPower: true);
    await tester.pump();
    expect(debugDanmakuSpritesAlive - alive, 1);
    final fixed = debugDanmakuPaints;
    await play(tester, 1.5);
    expect(debugDanmakuPaints, fixed);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(await topBandAlpha(tester), greaterThan(0));
    await play(tester, 2.2);
    expect(debugDanmakuSpritesAlive - alive, 2);
    expect(debugDanmakuPaints, greaterThan(fixed));
    await play(tester, 6);
    expect(debugDanmakuSpritesAlive - alive, 1);
    await play(tester, 12);
    expect(debugDanmakuSpritesAlive, alive);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('收掉的彈幕要把圖還回去', (tester) async {
    final alive = debugDanmakuSpritesAlive;
    final comments = [comment(0.1, '一'), comment(0.2, '二'), comment(0.3, '三')];
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

  for (final lowPower in [false, true]) {
    testWidgets('休眠稍晚醒來仍補送留言 (lowPower=$lowPower)', (tester) async {
      final alive = debugDanmakuSpritesAlive;
      await show(tester, [comment(30, 'wake', DanmakuMode.top)],
          lowPower: lowPower);
      await tester.pump();
      now = 30.08;
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(milliseconds: 40));
      expect(debugDanmakuSpritesAlive - alive, 1);
      expect(await topBandAlpha(tester), greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      expect(debugDanmakuSpritesAlive, alive);
    });

    testWidgets('彈幕全部播完後倒回, 明確對時會喚醒並重新出場 (lowPower=$lowPower)', (tester) async {
      final alive = debugDanmakuSpritesAlive;
      final comments = [comment(10, 'rewind', DanmakuMode.top)];
      now = 20;
      await show(tester, comments, lowPower: lowPower);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      now = 10.1;
      await show(tester, comments, lowPower: lowPower, timeline: 1);
      await tester.pump(const Duration(milliseconds: 40));
      expect(debugDanmakuSpritesAlive - alive, 1);
      expect(await topBandAlpha(tester), greaterThan(0));
      await play(tester, 16);
      expect(debugDanmakuSpritesAlive, alive);
      await tester.pumpWidget(const SizedBox());
    });
  }

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

  for (final lowPower in [false, true]) {
    testWidgets('密集彈幕分幀建圖, 暫停時也會消化完佇列 (lowPower=$lowPower)', (tester) async {
      final comments = List.generate(12, (i) => comment(0, 'burst $i'));
      final before = debugDanmakuRasterized;
      await show(tester, comments, playing: false, lowPower: lowPower);
      final budget =
          lowPower ? kDanmakuTvRastersPerFrame : kDanmakuRastersPerFrame;
      var previous = before;
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(debugDanmakuRasterized - previous, lessThanOrEqualTo(budget),
            reason: '單幀建立太多貼圖會搶走影片的繪製時間');
        previous = debugDanmakuRasterized;
      }
      expect(debugDanmakuRasterized - before, comments.length,
          reason: '預算用完的留言應延後處理, 不應直接丟掉');
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('相同文字與顏色共用貼圖, 最後一條離場才釋放', (tester) async {
    final alive = debugDanmakuSpritesAlive;
    final bytes = debugDanmakuTextureBytes;
    final before = debugDanmakuRasterized;
    final comments = [
      comment(0.1, 'same', DanmakuMode.top),
      comment(0.2, 'same', DanmakuMode.bottom),
      comment(0.3, 'same'),
    ];
    await show(tester, comments);
    await play(tester, 0.5);
    expect(debugDanmakuRasterized - before, 1);
    expect(debugDanmakuSpritesAlive - alive, 1);
    final retained = debugDanmakuTextureBytes;
    expect(retained, greaterThan(bytes));
    await play(tester, 6);
    expect(debugDanmakuSpritesAlive - alive, 1, reason: '固定彈幕消失時, 捲動彈幕還需要同一張圖');
    expect(debugDanmakuTextureBytes, retained);
    await play(tester, 10);
    expect(debugDanmakuSpritesAlive, alive);
    expect(debugDanmakuTextureBytes, bytes);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('不同顏色不共用貼圖', (tester) async {
    final before = debugDanmakuRasterized;
    await show(tester, [
      comment(0.1, 'same'),
      const DanmakuComment(
        start: 0.2,
        end: 5.2,
        text: 'same',
        color: Colors.red,
        mode: DanmakuMode.scroll,
      ),
    ]);
    await play(tester, 0.5);
    expect(debugDanmakuRasterized - before, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('電視限制同時顯示量, 密集短留言也不超量', (tester) async {
    final alive = debugDanmakuSpritesAlive;
    final comments = List.generate(500, (i) => comment(i * 0.02, '$i'));
    await show(tester, comments, lowPower: true);
    var peak = 0;
    while (now < 8) {
      now += 0.05;
      await tester.pump(const Duration(milliseconds: 50));
      final count = debugDanmakuSpritesAlive - alive;
      if (count > peak) peak = count;
      expect(count, lessThanOrEqualTo(kDanmakuTvMaxLive));
    }
    expect(peak, kDanmakuTvMaxLive, reason: '測試必須真的把顯示量推到上限');
    await tester.pumpWidget(const SizedBox());
    expect(debugDanmakuSpritesAlive, alive);
  });

  testWidgets('電視限制高 DPI 貼圖解析度, 仍能畫出文字與透明度', (tester) async {
    final bytes = debugDanmakuTextureBytes;
    final comments = [comment(0, 'danmaku', DanmakuMode.top)];
    await show(tester, comments, playing: false, pixelRatio: 3);
    await tester.pump();
    final normalBytes = debugDanmakuTextureBytes - bytes;
    expect(normalBytes, greaterThan(0));
    await show(tester, comments,
        playing: false, pixelRatio: 3, lowPower: true, opacity: 0.25);
    await tester.pump();
    final tvBytes = debugDanmakuTextureBytes - bytes;
    expect(tvBytes, greaterThan(0));
    expect(tvBytes, lessThan(normalBytes / 2));
    final alpha = await topBandAlpha(tester);
    expect(alpha, inInclusiveRange(1, 70));
    await tester.pumpWidget(const SizedBox());
    expect(debugDanmakuTextureBytes, bytes);
  });

  testWidgets('超長彈幕限制貼圖寬度和總記憶體, 關閉時全部釋放', (tester) async {
    final bytes = debugDanmakuTextureBytes;
    final comments = List.generate(
        100,
        (i) => comment(0, 'long $i ${'W' * 1000}',
            DanmakuMode.values[i % DanmakuMode.values.length]));
    await show(tester, comments,
        playing: false, lowPower: true, pixelRatio: 3, scale: 2);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(debugDanmakuTextureBytes - bytes,
          lessThanOrEqualTo(kDanmakuTvTextureBytes));
    }
    expect(debugDanmakuTextureBytes - bytes,
        greaterThan(kDanmakuTvTextureBytes * 0.8),
        reason: '要真的接近記憶體上限, 才能驗證預算擋得住');
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
    await show(tester, comments, lowPower: true, enabled: false);
    expect(debugDanmakuTextureBytes, bytes);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('只有固定彈幕時, 時鐘前進不重畫; 過期仍會清除', (tester) async {
    await show(tester, [comment(0.1, 'still', DanmakuMode.top)]);
    await play(tester, 0.3);
    final paints = debugDanmakuPaints;
    await play(tester, 3);
    expect(debugDanmakuPaints, paints);
    expect(await topBandAlpha(tester), greaterThan(0));
    await play(tester, 6);
    expect(debugDanmakuPaints, greaterThan(paints));
    expect(await topBandAlpha(tester), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('跳轉會丟掉尚未出場的舊彈幕, 換字級會重建共用貼圖', (tester) async {
    final alive = debugDanmakuSpritesAlive;
    final comments = [
      ...List.generate(50, (i) => comment(0, 'old $i')),
      comment(30, 'new', DanmakuMode.top),
    ];
    await show(tester, comments, playing: false, lowPower: true);
    await tester.pump();
    expect(debugDanmakuSpritesAlive - alive, kDanmakuTvRastersPerFrame);
    now = 30;
    await tester.pump(const Duration(milliseconds: 40));
    expect(debugDanmakuSpritesAlive - alive, 1);
    final bytes = debugDanmakuTextureBytes;
    final before = debugDanmakuRasterized;
    await show(tester, comments,
        playing: false, lowPower: true, scale: 2, opacity: 0.25);
    await tester.pump();
    expect(debugDanmakuRasterized - before, 1);
    expect(debugDanmakuTextureBytes, greaterThan(bytes));
    expect(await topBandAlpha(tester), inInclusiveRange(1, 70));
    await tester.pumpWidget(const SizedBox());
    expect(debugDanmakuSpritesAlive, alive);
  });
}
