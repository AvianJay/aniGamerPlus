import 'dart:async';

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
    this.seconds = 8,
  });

  final ValueListenable<double> clock;
  final IntroSkip intro;
  final String episodeKey;
  final bool Function() canCount, canFocus;
  final VoidCallback onSkip, onCancel, onFocusReleased, onNavigateControls;
  final bool tv, compact;
  final int seconds;

  @override
  State<IntroSkipPrompt> createState() => IntroSkipPromptState();
}

class IntroSkipPromptState extends State<IntroSkipPrompt> {
  final _group = FocusNode(debugLabel: 'intro-offer');
  final _skip = FocusNode(debugLabel: 'intro-skip');
  final _cancel = FocusNode(debugLabel: 'intro-cancel');
  Timer? _timer;
  bool _visible = false;
  bool _acted = false;
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
    final visible = !_acted && widget.intro.visibleAt(widget.clock.value);
    if (visible != _visible) {
      final release = !visible && hasFocus;
      _visible = visible;
      _remaining = widget.seconds;
      if (rebuild && mounted) setState(() {});
      if (visible && widget.tv && widget.canFocus()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _visible && widget.canFocus()) _skip.requestFocus();
        });
      } else if (release) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onFocusReleased();
        });
      }
    }
    if (!_visible || !widget.canCount()) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        // Recheck current state, including menus/lifecycle, before any seek.
        _sync(rebuild: true);
        if (!_visible || !widget.canCount()) return;
        if (_remaining <= 1) {
          _act(widget.onSkip);
        } else {
          setState(() => _remaining--);
        }
      });
    }
  }

  void _act(VoidCallback callback) {
    if (_acted || !_visible) return;
    _acted = true;
    _timer?.cancel();
    _timer = null;
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
      _timer?.cancel();
      _timer = null;
      _acted = false;
      _visible = false;
      _remaining = widget.seconds;
    }
    _sync();
  }

  @override
  void dispose() {
    widget.clock.removeListener(_changed);
    _timer?.cancel();
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
