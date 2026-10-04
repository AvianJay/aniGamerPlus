import 'dart:math' as math;

import '../danmaku/ass.dart';

class IntroSkip {
  const IntroSkip(this.start, this.end, this.source);
  final double start;
  final double end;
  final String source;

  double get countdownStart => math.max(0, start - 6);
  double get autoSkipAt => start + 3;

  bool visibleAt(double position) =>
      position >= countdownStart && position < end - 5;
}

// No author IDs survive the ASS export. Require several differently worded or
// time-separated votes within seven seconds, and reject end-of-episode jumps.
final _jump = RegExp(
  r'(?:空降|跳(?:過|过)?(?:片頭|片头|op)|(?:op|片頭|片头)\s*(?:結束|结束))\s*(?:到|至|在|:|：|->|→)?\s*(\d{1,2}):(\d{2})(?!\d)',
  caseSensitive: false,
);

IntroSkip? danmakuIntro(List<DanmakuComment> comments, double duration) {
  if (duration < 600) return null;
  final votes = <(double, double, String)>[];
  for (final comment in comments) {
    if (comment.start < 0 || comment.start > 240) continue;
    final match = _jump.firstMatch(comment.text);
    if (match == null) continue;
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    if (seconds >= 60) continue;
    final target = (minutes * 60 + seconds).toDouble();
    if (target < 45 ||
        target > math.min(360, duration * .25) ||
        target > duration - 300 ||
        comment.start > target + 15) {
      continue;
    }
    votes.add((target, comment.start, comment.text.trim().toLowerCase()));
  }
  if (votes.length < 3) return null;
  votes.sort((a, b) => a.$1.compareTo(b.$1));
  List<(double, double, String)> best = const [];
  for (var i = 0; i < votes.length; i++) {
    final cluster =
        votes.skip(i).takeWhile((v) => v.$1 - votes[i].$1 <= 7).toList();
    if (cluster.length > best.length) best = cluster;
  }
  if (best.length < 3) return null;
  final distinct = <String>{};
  final timeBuckets = <int>{};
  for (final vote in best) {
    distinct.add(vote.$3);
    timeBuckets.add(vote.$2 ~/ 8);
  }
  if (distinct.length < 2 || timeBuckets.length < 2) return null;
  final target = best[best.length ~/ 2].$1;
  return IntroSkip(0, target, '彈幕');
}
