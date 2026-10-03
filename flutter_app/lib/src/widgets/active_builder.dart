import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// 被不透明路由或其他分頁遮住時暫停重建, 回到畫面時讀取最新狀態.
class ActiveListenableBuilder extends StatefulWidget {
  const ActiveListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });

  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<ActiveListenableBuilder> createState() =>
      _ActiveListenableBuilderState();
}

class _ActiveListenableBuilderState extends State<ActiveListenableBuilder> {
  bool _active = true;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.of(context);
  }

  void _changed() {
    if (_active) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ActiveListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// 播放進度只有跨過顯示區間時才重建, 不用每 100ms 重畫固定的跳片頭按鈕.
class ClockVisibility extends StatefulWidget {
  const ClockVisibility({
    super.key,
    required this.clock,
    required this.visibleAt,
    required this.child,
  });

  final ValueListenable<double> clock;
  final bool Function(double) visibleAt;
  final Widget child;

  @override
  State<ClockVisibility> createState() => _ClockVisibilityState();
}

class _ClockVisibilityState extends State<ClockVisibility> {
  late bool _visible = widget.visibleAt(widget.clock.value);

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_changed);
  }

  void _changed() {
    final visible = widget.visibleAt(widget.clock.value);
    if (visible != _visible) setState(() => _visible = visible);
  }

  @override
  void didUpdateWidget(covariant ClockVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) {
      oldWidget.clock.removeListener(_changed);
      widget.clock.addListener(_changed);
    }
    _visible = widget.visibleAt(widget.clock.value);
  }

  @override
  void dispose() {
    widget.clock.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _visible ? widget.child : const SizedBox.shrink();
}
