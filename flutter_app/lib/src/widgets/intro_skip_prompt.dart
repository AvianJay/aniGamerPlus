import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/intro_skip.dart';
import 'playback_countdown_card.dart';

/// Listen to the clock without rebuilding the player on each position update.
/// Only visibility crossings and whole countdown seconds rebuild this card.
class IntroSkipPrompt extends StatefulWidget {
  const IntroSkipPrompt({
    super.key,
    required this.clock,
    required this.intro,
    required this.episodeKey,
    required this.canCount,
    required this.canFocus,
    required this.onSkip,
    required this.onCancel,
    required this.onFocusReleased,
    required this.onNavigateControls,
    this.tv = false,
    this.compact = false,
    this.seconds = 9,
  });

  final ValueListenable<double> clock;
  final IntroSkip intro;
  final String episodeKey;
  final bool Function() canCount, canFocus;
  final VoidCallback onSkip, onCancel, onFocusReleased, onNavigateControls;
  final bool tv, compact;
  // Give late metadata or a seek into OP a fresh chance to cancel.
  final int seconds;

  @override
  State<IntroSkipPrompt> createState() => IntroSkipPromptState();
}

class IntroSkipPromptState extends State<IntroSkipPrompt> {
  final _group = FocusNode(debugLabel: 'intro-offer');
  final _skip = FocusNode(debugLabel: 'intro-skip');
  final _cancel = FocusNode(debugLabel: 'intro-cancel');
  bool _visible = false;
  bool _acted = false;
  bool _skipPending = false;
  int _generation = 0;
  double? _skipAt;
  late double _lastPosition = widget.clock.value;
  late bool _wasCounting = widget.canCount();
  late int _remaining = widget.seconds;

  bool get hasFocus => _group.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_changed);
    _sync();
  }

  void _changed() => _sync(rebuild: true);

  void _sync({bool rebuild = false}) {
    final position = widget.clock.value;
    final canCount = widget.canCount();
    final visible = !_acted && widget.intro.visibleAt(position);
    var changed = visible != _visible;
    if (visible != _visible) {
      _generation++;
      _skipPending = false;
      final release = !visible && hasFocus;
      _visible = visible;
      if (visible) {
        // Normal playback: OP - 6s shows nine seconds, OP + 3s skips.
        // Late entry gets a short countdown instead of an unexpected seek.
        _skipAt = position < widget.intro.autoSkipAt
            ? widget.intro.autoSkipAt
            : position + widget.seconds;
      } else {
        _skipAt = null;
      }
      if (visible && widget.tv && widget.canFocus()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _visible && widget.canFocus()) _skip.requestFocus();
        });
      } else if (release) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onFocusReleased();
        });
      }
    } else if (visible && (!canCount || !_wasCounting)) {
      // Menus can cover the card while video keeps playing. Hold its remaining
      // time until counting is allowed again, including the final covered step.
      _skipAt = _skipAt! + math.max(0, position - _lastPosition);
    }
    _lastPosition = position;
    _wasCounting = canCount;
    if (visible) {
      final remaining = math.max(0, (_skipAt! - position).ceil());
      changed |= remaining != _remaining;
      _remaining = remaining;
    }
    if (changed && rebuild && mounted) setState(() {});
    if (visible && canCount && _remaining == 0 && !_skipPending) {
      _skipPending = true;
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation) return;
        _skipPending = false;
        if (_visible &&
            !_acted &&
            widget.canCount() &&
            _skipAt != null &&
            widget.clock.value >= _skipAt!) {
          _act(widget.onSkip);
        }
      });
    }
  }

  void _act(VoidCallback callback) {
    if (_acted || !_visible) return;
    _acted = true;
    _generation++;
    setState(() => _visible = false);
    callback();
  }

  @override
  void didUpdateWidget(covariant IntroSkipPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) {
      oldWidget.clock.removeListener(_changed);
      widget.clock.addListener(_changed);
    }
    if (oldWidget.episodeKey != widget.episodeKey ||
        oldWidget.intro.start != widget.intro.start ||
        oldWidget.intro.end != widget.intro.end) {
      _generation++;
      _skipPending = false;
      _skipAt = null;
      _acted = false;
      _visible = false;
      _remaining = widget.seconds;
      _lastPosition = widget.clock.value;
      _wasCounting = widget.canCount();
    }
    _sync();
  }

  @override
  void dispose() {
    widget.clock.removeListener(_changed);
    _group.dispose();
    _skip.dispose();
    _cancel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return RepaintBoundary(
      child: FocusTraversalGroup(
        child: Focus(
          focusNode: _group,
          onKeyEvent: (_, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            // Route TV arrows locally, including phone RemoteKeys events.
            if (key == LogicalKeyboardKey.arrowRight) {
              _cancel.requestFocus();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              _skip.requestFocus();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.arrowDown) {
              widget.onNavigateControls();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA) {
              if (event is! KeyRepeatEvent) {
                _act(_cancel.hasFocus ? widget.onCancel : widget.onSkip);
              }
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: PlaybackCountdownCard(
            key: const ValueKey('intro-countdown'),
            title: '即將跳過片頭',
            detail: '跳過片頭 · ${widget.intro.source}',
            action: '立即跳過 ($_remaining)',
            actionKey: const ValueKey('skip-intro'),
            cancelKey: const ValueKey('cancel-intro'),
            actionFocus: _skip,
            cancelFocus: _cancel,
            compact: widget.compact,
            onAction: () => _act(widget.onSkip),
            onCancel: () => _act(widget.onCancel),
          ),
        ),
      ),
    );
  }
}
