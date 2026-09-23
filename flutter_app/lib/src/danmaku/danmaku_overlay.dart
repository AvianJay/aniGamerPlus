/// 彈幕層.
///
/// .ass 裡的座標是照 1920x1080 排的, 手機上直接照抄會全部擠在左上角, 所以
/// 這裡自己重排: 捲動彈幕依「這一軌什麼時候空出來」找軌道, 上下固定的則是
/// 佔滿五秒就讓位. 畫的時候只走還在畫面上的那幾條, 圖也跟著回收.
///
/// 效能上有幾件事是刻意這樣寫的, 改之前先看一下:
///
/// * 每一條彈幕出場時只畫一次, 畫成一張圖 (連同陰影), 之後每一幀只是把那張
///   圖貼到新的位置. 以前每一幀都重新排一次字、重新模糊一次陰影 —— iOS 的
///   Impeller 沒有光柵快取, 一百多條字的模糊陰影就是一百多次離屏模糊, 一秒
///   一百二十次. 貼圖則是一幀一百多個四邊形, 幾乎不花錢.
/// * 時間軸是一個「問了才算」的函式, 不是每一幀都在變的 notifier. 那樣的話
///   每一個聽著它的東西都得每一幀重建一次 —— 以前播放頁的時間跟進度條就是
///   這樣, 連控制列收起來的時候都在一秒重建一百二十次.
/// * Ticker 只在真的有東西要動的時候跑. 它一跑, 每一個 vsync 就要把整個
///   畫面 (連影片) 重新合成一次; 暫停、卡住、或是下一條彈幕還要好幾秒才出現
///   的時候, 它是停著的.
/// * 外面包一層 RepaintBoundary. 沒有的話彈幕每動一次, 同一個 Stack 裡的
///   控制列、轉圈圈、右上角的徽章全部要跟著重新光柵化.
/// * 透明度是貼圖時那支畫筆的 alpha, 不套 Opacity. Opacity 會 saveLayer, 等於
///   每一幀替整個播放區開一張離屏圖; 而且這樣調透明度不必重畫任何一張圖.
/// * 同時在畫面上的條數有上限, 而且真的完全沒動的那一幀不會發出重畫通知.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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

/// 字的四周留多少給陰影. 陰影模糊半徑 3 大約往外擴 7 點, 再加上 1 點位移;
/// 留不夠的話陰影邊緣會被圖框切成一條直線.
const double _kShadowPad = 8;

/// 到現在為止總共畫了幾張彈幕圖. 測試拿來確認「一條只畫一次」.
@visibleForTesting
int debugDanmakuRasterized = 0;

/// 現在還握在手上的彈幕圖有幾張. 測試拿來確認收掉的都有還回去.
@visibleForTesting
int debugDanmakuSpritesAlive = 0;

/// 一條彈幕畫好的樣子.
class _Sprite {
  _Sprite(this.image, this.width, this.height) {
    debugDanmakuRasterized++;
    debugDanmakuSpritesAlive++;
  }

  /// 含陰影的整張圖, 裝置像素
  final ui.Image image;

  /// 字本身佔多寬多高 (邏輯像素, 不含陰影的留白) —— 排軌道、算位置用這個
  final double width;
  final double height;

  void dispose() {
    debugDanmakuSpritesAlive--;
    image.dispose();
  }
}

class _Live {
  _Live({
    required this.comment,
    required this.sprite,
    required this.lane,
    required this.spawn,
    required this.duration,
  });

  final DanmakuComment comment;
  final _Sprite sprite;
  final int lane;
  final double spawn;
  final double duration;

  double get width => sprite.width;

  double endAt() => spawn + duration;
}

/// 畫的時候要的東西. 這一包是共用的可變物件: state 改它, painter 讀它,
/// 中間不再複製一份 list 出來 —— 以前那份複製是每一幀一次.
class _Scene {
  final List<_Live> live = [];
  double now = 0;
  double laneHeight = 0;

  /// 整層的透明度, 貼圖的時候套上去
  double alpha = 1;

  /// 裝置像素比. 圖是照這個比例畫的, 貼的時候要對回去.
  double pixelRatio = 1;

  /// 收掉一條就要把它的圖還回去 —— 那是 GPU 上的記憶體, 不會自己消失.
  void drop(bool Function(_Live live) test) {
    live.removeWhere((item) {
      if (!test(item)) return false;
      item.sprite.dispose();
      return true;
    });
  }

  void clear() => drop((_) => true);
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.comments,
    required this.position,
    required this.playing,
    this.rate = 1.0,
    this.buffering = false,
    this.enabled = true,
    this.opacity = 1.0,
    this.area = 1.0,
    this.scale = 1.0,
    this.speed = 1.0,
  });

  final List<DanmakuComment> comments;

  /// 此刻播到第幾秒. 每一幀都會來問一次.
  final ValueGetter<double> position;

  /// 播放速度. 彈幕的時間軸照這個往前推 —— 兩倍速時字也要跑兩倍快, 不然
  /// 跟播放器的落差每幾秒就大到得整排瞬移一次.
  final double rate;

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

  late final Ticker _ticker;
  Duration _tickAt = Duration.zero;

  /// 下一條彈幕還要好一陣子才出現時, 到時候叫醒 ticker 的那一個
  Timer? _wake;

  /// 畫面上的時間軸. 跟播放器的時鐘不一定一樣, 見 [_advance].
  double _shown = 0;

  int _cursor = 0;
  double _lastTime = -1;
  Size _size = Size.zero;

  static const double _baseScrollSeconds = 9.0;

  @override
  void initState() {
    super.initState();
    _shown = widget.position();
    _scene.alpha = _alpha;
    _ticker = createTicker(_onTick);
    _resume();
  }

  @override
  void dispose() {
    _wake?.cancel();
    _ticker.dispose();
    _repaint.dispose();
    _scene.clear();
    super.dispose();
  }

  /// 讓 ticker 跑起來 (已經在跑就什麼都不做). 真的沒事做的話它下一幀自己
  /// 會停, 所以任何「可能有變化」的時候都可以放心叫.
  void _resume() {
    _wake?.cancel();
    _wake = null;
    if (!widget.enabled || widget.comments.isEmpty || _ticker.isActive) return;
    _tickAt = Duration.zero;
    _ticker.start();
  }

  void _rest() {
    if (_ticker.isActive) _ticker.stop();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        _shown = widget.position();
      } else {
        _wake?.cancel();
        _rest();
        _reset();
      }
    }
    // 字級 / 範圍 / 速度是烤進圖或軌道算式裡的, 換了只能整層重來;
    // 透明度只是貼圖那支筆的 alpha, 換掉就好 —— 不然拉那條 slider 的時候
    // 每動一格畫面就空一次
    if (oldWidget.comments != widget.comments ||
        oldWidget.scale != widget.scale ||
        oldWidget.area != widget.area ||
        oldWidget.speed != widget.speed) {
      _reset();
      _repaint.value++;
    } else if (oldWidget.opacity != widget.opacity) {
      _scene.alpha = _alpha;
      _repaint.value++;
    }
    // 開始播、跳轉完、換速度都會讓外面重建一次 —— 正好是 ticker 該醒來的時候
    _resume();
  }

  void _reset() {
    _scene.clear();
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
      // 還沒量到大小: 先停, build 量到了會再叫醒
      _rest();
      return;
    }
    // 第一幀跟 app 回到前景那一下 dt 會很大, 夾住免得彈幕一口氣衝出去
    final dt = _tickAt == Duration.zero
        ? 0.0
        : ((elapsed - _tickAt).inMicroseconds / 1000000.0).clamp(0.0, 0.25);
    _tickAt = elapsed;

    final moved = _advance(dt);
    final spawned = _sync(_shown);
    if (moved || spawned) {
      _scene.now = _shown;
      _repaint.value++;
    }
    if (!widget.playing && !moved && !spawned) {
      // 暫停了, 或是卡住而且已經滑到頭了: 停下來, 不要每一幀空轉
      _rest();
    } else if (widget.playing && _scene.live.isEmpty) {
      _idleUntilNext();
    }
  }

  /// 畫面上一條都沒有, 下一條又還要好一陣子: 先睡, 快到了再醒.
  void _idleUntilNext() {
    if (_cursor >= widget.comments.length) {
      _rest(); // 這一集後面沒有了
      return;
    }
    final gap = widget.comments[_cursor].start - _shown;
    if (gap < 1.0) return;
    _rest();
    final rate = widget.rate > 0 ? widget.rate : 1.0;
    _wake = Timer(Duration(milliseconds: ((gap - 0.5) / rate * 1000).round()),
        _resume);
  }

  /// 把畫面上的時間軸往前推一格, 回傳有沒有真的動.
  bool _advance(double dt) {
    final target = widget.position();
    final before = _shown;
    final drift = target - _shown;

    if (_scene.live.isEmpty || drift.abs() > kDanmakuCoast + 0.5) {
      // 畫面上沒東西 (剛醒來、剛開始), 或是換集、拉時間軸、卡太久追不回來了:
      // 直接對上
      _shown = target;
    } else if (widget.playing) {
      // 照播放速度往前走, 再把跟播放器之間那幾十毫秒的落差慢慢磨掉.
      // 直接把值指過去會看到一整排字每 100ms 抖一下.
      _shown += dt * widget.rate;
      _shown += (target - _shown) * math.min(1.0, dt * 4);
    } else if (widget.buffering && drift > -kDanmakuCoast) {
      // 只是卡一下, 先自己滑過去
      _shown += dt * widget.rate;
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

  /// 把一條彈幕 (字 + 陰影) 畫成一張圖. 只在出場那一次做.
  ///
  /// 透明度不烤進去: 那是貼圖時畫筆的事, 這樣拉透明度的時候一張都不必重畫.
  _Sprite _rasterize(DanmakuComment comment) {
    final painter = TextPainter(
      text: TextSpan(
        text: comment.text,
        style: TextStyle(
          fontSize: _fontSize,
          color: comment.color,
          fontWeight: FontWeight.w600,
          height: 1.1,
          shadows: const [
            Shadow(
              blurRadius: 3,
              color: Color.fromRGBO(0, 0, 0, 0.8),
              offset: Offset(1, 1),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final ratio = _scene.pixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    painter.paint(canvas, const Offset(_kShadowPad, _kShadowPad));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      ((painter.width + _kShadowPad * 2) * ratio).ceil(),
      ((painter.height + _kShadowPad * 2) * ratio).ceil(),
    );
    picture.dispose();
    final sprite = _Sprite(image, painter.width, painter.height);
    painter.dispose();
    return sprite;
  }

  /// 回傳這一格有沒有生出 / 收掉東西
  bool _sync(double now) {
    if (_size == Size.zero) return false;
    var changed = false;

    // 往回拉 (或換集) 就整層重來
    if (_lastTime < 0 || now < _lastTime - 0.4 || now > _lastTime + 4) {
      if (_scene.live.isNotEmpty) changed = true;
      _scene.clear();
      _scrollLanes.clear();
      _topLanes.clear();
      _bottomLanes.clear();
      _cursor = _indexAt(now);
    }
    _lastTime = now;

    // 過期的收掉
    final before = _scene.live.length;
    _scene.drop((live) => live.endAt() <= now);
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
    // 先找軌道再畫, 丟掉的那些連圖都不用生.
    if (lane < 0) return false;

    final sprite = _rasterize(comment);

    if (comment.mode == DanmakuMode.scroll) {
      final travel = _size.width + sprite.width;
      final duration = _baseScrollSeconds / (widget.speed <= 0 ? 1 : widget.speed);
      // 這一軌要等到前一條整個進場才空出來, 不然會追撞
      lanes[lane] = now + duration * (sprite.width + 24) / travel;
      _scene.live.add(_Live(
        comment: comment,
        sprite: sprite,
        lane: lane,
        spawn: now,
        duration: duration,
      ));
    } else {
      const hold = 5.0;
      lanes[lane] = now + hold;
      _scene.live.add(_Live(
        comment: comment,
        sprite: sprite,
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
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // 圖是照裝置像素畫的: 換了螢幕 (外接、分割畫面) 那些圖的解析度就不對了
        if (size != _size || ratio != _scene.pixelRatio) {
          _size = size;
          _scene.pixelRatio = ratio;
          _reset();
          _resume();
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
    final ratio = scene.pixelRatio;
    // 整層的透明度就是這支筆的 alpha. low = 雙線性取樣: 位置已經對齊到裝置
    // 像素, 實際上是一比一貼上去, 不會糊.
    final pen = Paint()
      ..filterQuality = FilterQuality.low
      ..color = Color.fromRGBO(255, 255, 255, scene.alpha);
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
      final image = item.sprite.image;
      // 對齊到裝置像素再貼: 圖是一比一畫的, 落在半個像素上就會被取樣糊掉
      final left = ((x - _kShadowPad) * ratio).roundToDouble() / ratio;
      final top = ((y - _kShadowPad) * ratio).roundToDouble() / ratio;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(left, top, image.width / ratio, image.height / ratio),
        pen,
      );
    }
  }

  // scene 是共用的可變物件, 內容變了是靠 repaint 那條 Listenable 通知的,
  // 所以這裡只要比物件本身有沒有換掉.
  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      oldDelegate.scene != scene;
}
