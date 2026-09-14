/// 彈幕層.
///
/// .ass 裡的座標是照 1920x1080 排的, 手機上直接照抄會全部擠在左上角, 所以
/// 這裡自己重排: 捲動彈幕依「這一軌什麼時候空出來」找軌道, 上下固定的則是
/// 佔滿五秒就讓位. 畫的時候只走還在畫面上的那幾條, TextPainter 也跟著回收.
///
/// 效能上有幾件事是刻意這樣寫的, 改之前先看一下:
///
/// * 不用 ValueListenableBuilder 包在外面. 播放器的時鐘每一幀都在動, 那樣寫
///   等於每一幀都重跑一次 build + LayoutBuilder + layout, 只為了換幾個座標.
///   這裡改成把時鐘交給 CustomPainter 的 repaint, 只重畫不重建.
/// * 外面包一層 RepaintBoundary. 沒有的話彈幕每動一次, 同一個 Stack 裡的
///   控制列、轉圈圈、右上角的徽章全部要跟著重新光柵化 —— 網路慢的時候那圈
///   spinner 一直在轉, 剛好把這筆帳放到最大.
/// * 透明度直接調進文字顏色裡, 不套 Opacity. Opacity 會 saveLayer, 等於每一幀
///   替整個播放區開一張離屏圖.
/// * 同時在畫面上的條數有上限, 而且真的完全沒動的那一幀不會發出重畫通知.
library;

// ValueListenable 不在 material 的 re-export 名單裡, 時鐘那個欄位要用它
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'ass.dart';

/// 同時在畫面上最多幾條. 軌道用完本來就會自己擋掉一部分, 但捲動軌只要前一條
/// 「整個進場」就算空出來, 所以一軌其實疊得下好幾條, 彈幕密的時候疊出來三百
/// 多條都有可能 —— 那已經不是看得清不清楚的問題, 是畫不動.
const int kDanmakuMaxLive = 160;

/// 卡頓的時候最多讓彈幕自己往前滑幾秒.
///
/// 播放器一卡住, 位置就停在原地, 彈幕跟著整排定格再跳一大格, 看起來比影片本身
/// 還糟 —— 橫著跑的字最藏不住這種停頓. 網路差的時候是每幾百毫秒卡一下, 所以
/// 這裡讓彈幕先自己滑過去, 差到超過這個秒數才真的停下來等.
const double kDanmakuCoast = 1.0;

class _Live {
  _Live({
    required this.comment,
    required this.painter,
    required this.lane,
    required this.spawn,
    required this.duration,
  });

  final DanmakuComment comment;

  /// 不是 final: 調透明度的時候原地換一支, 不必把整層清掉重來
  TextPainter painter;
  final int lane;
  final double spawn;
  final double duration;

  double get width => painter.width;

  double endAt() => spawn + duration;
}

/// 畫的時候要的東西. 這一包是共用的可變物件: state 改它, painter 讀它,
/// 中間不再複製一份 list 出來 —— 以前那份複製是每一幀一次.
class _Scene {
  final List<_Live> live = [];
  double now = 0;
  double laneHeight = 0;
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.comments,
    required this.clock,
    required this.playing,
    this.buffering = false,
    this.enabled = true,
    this.opacity = 1.0,
    this.area = 1.0,
    this.scale = 1.0,
    this.speed = 1.0,
  });

  final List<DanmakuComment> comments;

  /// 播放器目前的秒數. 直接吃 notifier, 不要在外面包 builder.
  final ValueListenable<double> clock;

  /// 真的在播 (沒暫停、沒拖時間軸、也沒在等緩衝)
  final bool playing;

  /// 在等緩衝. 跟 [playing] 分開是因為這兩種停法要用不同的處理.
  final bool buffering;
  final bool enabled;
  final double opacity;

  /// 佔畫面高度的比例: 1 / 0.75 / 0.5 / 0.25
  final double area;
  final double scale;
  final double speed;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  final _Scene _scene = _Scene();

  /// 每一軌下一次可以再放彈幕的時間
  final List<double> _scrollLanes = [];
  final List<double> _topLanes = [];
  final List<double> _bottomLanes = [];

  /// 只有這個會叫 CustomPaint 重畫. 定格的那幾幀不動它, 彈幕層就完全
  /// 不用重新光柵化.
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  Ticker? _ticker;
  Duration _tickAt = Duration.zero;

  /// 畫面上的時間軸. 跟播放器的時鐘不一定一樣, 見 [_advance].
  double _shown = 0;

  int _cursor = 0;
  double _lastTime = -1;
  Size _size = Size.zero;

  static const double _baseScrollSeconds = 9.0;

  @override
  void initState() {
    super.initState();
    _shown = widget.clock.value;
    _ticker = createTicker(_onTick);
    if (widget.enabled) _ticker!.start();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        _tickAt = Duration.zero;
        _shown = widget.clock.value;
        if (!(_ticker?.isActive ?? false)) _ticker?.start();
      } else {
        if (_ticker?.isActive ?? false) _ticker!.stop();
        _reset();
      }
    }
    // 字級 / 範圍 / 速度是烤進 TextPainter 或軌道算式裡的, 換了只能整層重來;
    // 透明度只是顏色, 原地換一支 painter 就好 —— 不然拉那條 slider 的時候
    // 每動一格畫面就空一次
    if (oldWidget.comments != widget.comments ||
        oldWidget.scale != widget.scale ||
        oldWidget.area != widget.area ||
        oldWidget.speed != widget.speed) {
      _reset();
      _repaint.value++;
    } else if (oldWidget.opacity != widget.opacity) {
      for (final live in _scene.live) {
        live.painter = _paint(live.comment);
      }
      _repaint.value++;
    }
  }

  void _reset() {
    _scene.live.clear();
    _scene.laneHeight = _laneHeight;
    _scrollLanes.clear();
    _topLanes.clear();
    _bottomLanes.clear();
    _cursor = 0;
    _lastTime = -1;
  }

  // ------------------------------------------------------------------ 時間軸

  void _onTick(Duration elapsed) {
    if (!widget.enabled || _size == Size.zero) {
      _tickAt = elapsed;
      return;
    }
    // 第一幀跟 app 回到前景那一下 dt 會很大, 夾住免得彈幕一口氣衝出去
    final dt = _tickAt == Duration.zero
        ? 0.0
        : ((elapsed - _tickAt).inMicroseconds / 1000000.0).clamp(0.0, 0.25);
    _tickAt = elapsed;

    final moved = _advance(dt);
    final spawned = _sync(_shown);
    if (!moved && !spawned) return;
    _scene.now = _shown;
    _repaint.value++;
  }

  /// 把畫面上的時間軸往前推一格, 回傳有沒有真的動.
  bool _advance(double dt) {
    final target = widget.clock.value;
    final before = _shown;
    final drift = target - _shown;

    if (drift.abs() > kDanmakuCoast + 0.5) {
      // 換集、拉時間軸、或是卡太久追不回來了: 直接對上
      _shown = target;
    } else if (widget.playing) {
      // 跟著真實時間走, 順便用 ±60% 的速度把那幾十毫秒的落差磨掉.
      // 直接把值指過去會看到一整排字瞬移.
      _shown += dt * (1 + drift).clamp(0.4, 1.6);
    } else if (widget.buffering && drift > -kDanmakuCoast) {
      // 只是卡一下, 先自己滑過去
      _shown += dt;
    }
    // 真的按了暫停就不動

    return (_shown - before).abs() > 0.0001;
  }

  // -------------------------------------------------------------------- 排版

  double get _fontSize {
    final base = (_size.height / 24).clamp(13.0, 30.0);
    return base * widget.scale;
  }

  double get _laneHeight => _fontSize * 1.4;

  int get _laneCount {
    if (_laneHeight <= 0) return 1;
    final usable = _size.height * widget.area;
    return (usable / _laneHeight).floor().clamp(1, 40);
  }

  double get _alpha => widget.opacity.clamp(0.05, 1.0);

  TextPainter _paint(DanmakuComment comment) {
    // 透明度烤進顏色裡, 不要在外面套 Opacity —— 那會 saveLayer
    final alpha = _alpha;
    final painter = TextPainter(
      text: TextSpan(
        text: comment.text,
        style: TextStyle(
          fontSize: _fontSize,
          color: comment.color.withValues(alpha: comment.color.a * alpha),
          fontWeight: FontWeight.w600,
          height: 1.1,
          shadows: [
            Shadow(
              blurRadius: 3,
              color: Color.fromRGBO(0, 0, 0, 0.8 * alpha),
              offset: const Offset(1, 1),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter;
  }

  /// 回傳這一格有沒有生出 / 收掉東西
  bool _sync(double now) {
    if (_size == Size.zero) return false;
    var changed = false;

    // 往回拉 (或換集) 就整層重來
    if (_lastTime < 0 || now < _lastTime - 0.4 || now > _lastTime + 4) {
      if (_scene.live.isNotEmpty) changed = true;
      _scene.live.clear();
      _scrollLanes.clear();
      _topLanes.clear();
      _bottomLanes.clear();
      _cursor = _indexAt(now);
    }
    _lastTime = now;

    // 過期的收掉
    final before = _scene.live.length;
    _scene.live.removeWhere((live) => live.endAt() <= now);
    if (_scene.live.length != before) changed = true;

    while (_cursor < widget.comments.length &&
        widget.comments[_cursor].start <= now) {
      final comment = widget.comments[_cursor];
      _cursor++;
      // 一次跳很多集的時候別把幾百條一起塞進來
      if (now - comment.start > 1.5) continue;
      // 畫不動就別畫, 反正疊到這個數量也看不清了
      if (_scene.live.length >= kDanmakuMaxLive) continue;
      if (_spawn(comment, now)) changed = true;
    }
    return changed;
  }

  int _indexAt(double now) {
    var low = 0;
    var high = widget.comments.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (widget.comments[mid].start < now) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  bool _spawn(DanmakuComment comment, double now) {
    final List<double> lanes;
    if (comment.mode == DanmakuMode.scroll) {
      lanes = _scrollLanes;
    } else if (comment.mode == DanmakuMode.top) {
      lanes = _topLanes;
    } else {
      lanes = _bottomLanes;
    }

    final maxLanes = _laneCount;
    var lane = -1;
    for (var i = 0; i < maxLanes; i++) {
      if (i >= lanes.length) {
        lanes.add(0);
      }
      if (lanes[i] <= now) {
        lane = i;
        break;
      }
    }
    // 每一軌都塞滿了就丟掉這一條 —— 疊在一起誰也看不清.
    // 先找軌道再排版, 丟掉的那些連 TextPainter 都不用生.
    if (lane < 0) return false;

    final painter = _paint(comment);

    if (comment.mode == DanmakuMode.scroll) {
      final travel = _size.width + painter.width;
      final duration = _baseScrollSeconds / (widget.speed <= 0 ? 1 : widget.speed);
      // 這一軌要等到前一條整個進場才空出來, 不然會追撞
      lanes[lane] = now + duration * (painter.width + 24) / travel;
      _scene.live.add(_Live(
        comment: comment,
        painter: painter,
        lane: lane,
        spawn: now,
        duration: duration,
      ));
    } else {
      const hold = 5.0;
      lanes[lane] = now + hold;
      _scene.live.add(_Live(
        comment: comment,
        painter: painter,
        lane: lane,
        spawn: now,
        duration: hold,
      ));
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _size) {
          _size = size;
          _reset();
        }
        // 這裡不再呼叫 _sync —— 那是 ticker 的事. build 只負責量大小,
        // 之後每一幀都只走 repaint 那條路.
        return RepaintBoundary(
          child: IgnorePointer(
            child: CustomPaint(
              size: size,
              painter: _DanmakuPainter(scene: _scene, repaint: _repaint),
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({required this.scene, required Listenable repaint})
      : super(repaint: repaint);

  final _Scene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final now = scene.now;
    final laneHeight = scene.laneHeight;
    for (final item in scene.live) {
      final elapsed = now - item.spawn;
      if (elapsed < 0) continue;
      final progress = (elapsed / item.duration).clamp(0.0, 1.0);

      double x;
      double y;
      if (item.comment.mode == DanmakuMode.scroll) {
        final travel = size.width + item.width;
        x = size.width - travel * progress;
        y = item.lane * laneHeight + 2;
      } else if (item.comment.mode == DanmakuMode.top) {
        x = (size.width - item.width) / 2;
        y = item.lane * laneHeight + 2;
      } else {
        x = (size.width - item.width) / 2;
        y = size.height - (item.lane + 1) * laneHeight - 2;
      }
      if (x > size.width || x + item.width < 0) continue;
      item.painter.paint(canvas, Offset(x, y));
    }
  }

  // scene 是共用的可變物件, 內容變了是靠 repaint 那條 Listenable 通知的,
  // 所以這裡只要比物件本身有沒有換掉.
  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.scene != scene;
}
