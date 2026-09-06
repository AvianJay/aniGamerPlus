/// 彈幕層.
///
/// .ass 裡的座標是照 1920x1080 排的, 手機上直接照抄會全部擠在左上角, 所以
/// 這裡自己重排: 捲動彈幕依「這一軌什麼時候空出來」找軌道, 上下固定的則是
/// 佔滿五秒就讓位. 畫的時候只走還在畫面上的那幾條, TextPainter 也跟著回收.
library;

import 'package:flutter/material.dart';

import 'ass.dart';

class _Live {
  _Live({
    required this.comment,
    required this.painter,
    required this.lane,
    required this.spawn,
    required this.duration,
  });

  final DanmakuComment comment;
  final TextPainter painter;
  final int lane;
  final double spawn;
  final double duration;

  double get width => painter.width;

  double endAt() => spawn + duration;
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.comments,
    required this.positionSeconds,
    required this.playing,
    this.enabled = true,
    this.opacity = 1.0,
    this.area = 1.0,
    this.scale = 1.0,
    this.speed = 1.0,
  });

  final List<DanmakuComment> comments;

  /// 播放器目前的秒數. 上層每次 tick 都會餵新的.
  final double positionSeconds;
  final bool playing;
  final bool enabled;
  final double opacity;

  /// 佔畫面高度的比例: 1 / 0.75 / 0.5 / 0.25
  final double area;
  final double scale;
  final double speed;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  final List<_Live> _live = [];

  /// 每一軌下一次可以再放彈幕的時間
  final List<double> _scrollLanes = [];
  final List<double> _topLanes = [];
  final List<double> _bottomLanes = [];

  int _cursor = 0;
  double _lastTime = -1;
  Size _size = Size.zero;

  static const double _baseScrollSeconds = 9.0;

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comments != widget.comments) {
      _reset();
    }
  }

  void _reset() {
    _live.clear();
    _scrollLanes.clear();
    _topLanes.clear();
    _bottomLanes.clear();
    _cursor = 0;
    _lastTime = -1;
  }

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

  TextPainter _paint(DanmakuComment comment) {
    final painter = TextPainter(
      text: TextSpan(
        text: comment.text,
        style: TextStyle(
          fontSize: _fontSize,
          color: comment.color,
          fontWeight: FontWeight.w600,
          height: 1.1,
          shadows: const [
            Shadow(blurRadius: 3, color: Color(0xCC000000), offset: Offset(1, 1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter;
  }

  void _sync(double now) {
    if (_size == Size.zero) return;

    // 往回拉 (或換集) 就整層重來
    if (_lastTime < 0 || now < _lastTime - 0.4 || now > _lastTime + 4) {
      _live.clear();
      _scrollLanes.clear();
      _topLanes.clear();
      _bottomLanes.clear();
      _cursor = _indexAt(now);
    }
    _lastTime = now;

    // 過期的收掉
    _live.removeWhere((live) => live.endAt() <= now);

    while (_cursor < widget.comments.length &&
        widget.comments[_cursor].start <= now) {
      final comment = widget.comments[_cursor];
      _cursor++;
      // 一次跳很多集的時候別把幾百條一起塞進來
      if (now - comment.start > 1.5) continue;
      _spawn(comment, now);
    }
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

  void _spawn(DanmakuComment comment, double now) {
    final painter = _paint(comment);
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
    // 每一軌都塞滿了就丟掉這一條 —— 疊在一起誰也看不清
    if (lane < 0) return;

    if (comment.mode == DanmakuMode.scroll) {
      final travel = _size.width + painter.width;
      final duration = _baseScrollSeconds / (widget.speed <= 0 ? 1 : widget.speed);
      // 這一軌要等到前一條整個進場才空出來, 不然會追撞
      lanes[lane] = now + duration * (painter.width + 24) / travel;
      _live.add(_Live(
        comment: comment,
        painter: painter,
        lane: lane,
        spawn: now,
        duration: duration,
      ));
    } else {
      const hold = 5.0;
      lanes[lane] = now + hold;
      _live.add(_Live(
        comment: comment,
        painter: painter,
        lane: lane,
        spawn: now,
        duration: hold,
      ));
    }
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
        _sync(widget.positionSeconds);
        return IgnorePointer(
          child: Opacity(
            opacity: widget.opacity.clamp(0.05, 1.0),
            child: CustomPaint(
              size: size,
              painter: _DanmakuPainter(
                live: List<_Live>.from(_live),
                now: widget.positionSeconds,
                laneHeight: _laneHeight,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.live,
    required this.now,
    required this.laneHeight,
  });

  final List<_Live> live;
  final double now;
  final double laneHeight;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in live) {
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

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => true;
}
