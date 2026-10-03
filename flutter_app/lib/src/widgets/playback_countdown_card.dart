import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared by the opening and next-episode offers.
class PlaybackCountdownCard extends StatelessWidget {
  const PlaybackCountdownCard({
    super.key,
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
    required this.onCancel,
    this.actionKey,
    this.cancelKey,
    this.actionFocus,
    this.cancelFocus,
    this.compact = false,
  });

  final String title, detail, action;
  final VoidCallback onAction, onCancel;
  final Key? actionKey, cancelKey;
  final FocusNode? actionFocus, cancelFocus;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
        width: compact ? 216 : 268,
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
            : const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: AgpColors.lineStrong),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact)
              Text(title,
                  style: const TextStyle(
                      fontSize: 12,
                      color: AgpColors.fgFaint,
                      fontWeight: FontWeight.w700)),
            if (!compact) ...[
              const SizedBox(height: 5),
              Text(detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, color: Colors.white)),
            ],
            if (!compact) const SizedBox(height: 11),
            Row(children: [
              Expanded(
                child: FilledButton(
                  key: actionKey,
                  focusNode: actionFocus,
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size(0, compact ? 32 : 40),
                    tapTargetSize: compact
                        ? MaterialTapTargetSize.shrinkWrap
                        : MaterialTapTargetSize.padded,
                    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontSize: compact ? 12.5 : 14,
                        fontWeight: FontWeight.w700),
                  ),
                  child: Text(action),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: cancelKey,
                focusNode: cancelFocus,
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size(0, compact ? 32 : 40),
                  tapTargetSize: compact
                      ? MaterialTapTargetSize.shrinkWrap
                      : MaterialTapTargetSize.padded,
                ),
                child: const Text('取消'),
              ),
            ]),
          ],
        ),
      );
}
