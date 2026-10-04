import 'package:agp_mobile/src/state/intro_skip.dart';
import 'package:agp_mobile/src/state/tv_remote_protocol.dart';
import 'package:agp_mobile/src/theme.dart';
import 'package:agp_mobile/src/util/remote_keys.dart';
import 'package:agp_mobile/src/widgets/intro_skip_prompt.dart';
import 'package:agp_mobile/src/widgets/playback_countdown_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ValueNotifier<double> clock;
  late bool running;
  late bool active;
  late int skips, cancels, releases;
  setUp(() {
    clock = ValueNotifier(150);
    running = active = true;
    skips = cancels = releases = 0;
  });
  tearDown(() => clock.dispose());
  Future<void> show(WidgetTester tester,
      {String episode = '1', bool tv = false}) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(brightness: Brightness.dark, tv: tv),
      home: Scaffold(
          body: Center(
              child: IntroSkipPrompt(
        clock: clock,
        intro: const IntroSkip(160, 250, 'AniSkip'),
        episodeKey: episode,
        tv: tv,
        canCount: () => running && active,
        canFocus: () => active,
        onSkip: () => skips++,
        onCancel: () => cancels++,
        onFocusReleased: () => releases++,
        onNavigateControls: () {},
      ))),
    ));
    await tester.pump();
  }

  final card = find.byType(PlaybackCountdownCard);
  final skip = find.byKey(const ValueKey('skip-intro'));
  final cancel = find.byKey(const ValueKey('cancel-intro'));

  testWidgets(
      'countdown starts three playback seconds after OP, manual skip stays available',
      (tester) async {
    clock.value = 157;
    await show(tester);
    expect(find.text('跳過片頭'), findsWidgets);
    for (final position in [160.0, 161.0, 162.99]) {
      clock.value = position;
      await tester.pump(const Duration(seconds: 5));
      expect(skips, 0);
      expect(find.text('立即跳過 (8)'), findsNothing);
    }
    clock.value = 163;
    await tester.pump();
    expect(find.text('立即跳過 (8)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('立即跳過 (7)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    clock.value = 160;
    await show(tester, episode: '2');
    await tester.tap(skip);
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('enters OP with eight seconds and seeks once when it expires',
      (tester) async {
    await show(tester);
    expect(card, findsNothing);
    clock.value = 164;
    await tester.pump();
    expect(find.text('立即跳過 (8)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('立即跳過 (7)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    expect(skips, 1);
    expect(card, findsNothing);
    await tester.pump(const Duration(seconds: 20));
    clock.value = 170;
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('pause, buffering and covered menus hold the remaining countdown',
      (tester) async {
    clock.value = 164;
    await show(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('立即跳過 (6)'), findsOneWidget);
    running = false;
    await show(tester);
    await tester.pump(const Duration(seconds: 15));
    expect(skips, 0);
    expect(find.text('立即跳過 (6)'), findsOneWidget);
    running = true;
    active = false;
    await show(tester);
    await tester.pump(const Duration(seconds: 15));
    expect(skips, 0);
    active = true;
    await show(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(skips, 1);
  });

  testWidgets('clock updates within OP do not rebuild the card',
      (tester) async {
    clock.value = 164;
    await show(tester);
    final before = tester.widget<PlaybackCountdownCard>(card);
    for (var i = 0; i < 5; i++) {
      clock.value += .1;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
        identical(before, tester.widget<PlaybackCountdownCard>(card)), isTrue);
    clock.value = 300;
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(card, findsNothing);
    expect(skips, 0);
    clock.value = 164;
    await tester.pump();
    expect(find.text('立即跳過 (8)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancel stays dismissed until the next episode', (tester) async {
    clock.value = 164;
    await show(tester);
    await tester.tap(cancel);
    await tester.pump(const Duration(seconds: 10));
    expect(cancels, 1);
    expect(skips, 0);
    clock.value = 163;
    await show(tester);
    expect(card, findsNothing);
    await show(tester, episode: '2');
    expect(find.text('立即跳過 (8)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(skips, 1);
  });

  for (final phone in [false, true]) {
    testWidgets('TV confirms skip and navigates to cancel (phone=$phone)',
        (tester) async {
      await show(tester, tv: true);
      clock.value = 164;
      await tester.pump();
      await tester.pump();
      expect(tester.widget<FilledButton>(skip).focusNode!.hasFocus, isTrue);
      if (phone) {
        RemoteKeys.press(RemoteKey.right);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pump();
      expect(tester.widget<OutlinedButton>(cancel).focusNode!.hasFocus, isTrue);
      if (phone) {
        RemoteKeys.press(RemoteKey.ok);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      }
      await tester.pump(const Duration(seconds: 10));
      expect(cancels, 1);
      expect(skips, 0);
      await show(tester, tv: true, episode: '2');
      await tester.pump();
      if (phone) {
        RemoteKeys.press(RemoteKey.ok);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      }
      await tester.pump();
      expect(skips, 1);
    });
  }
}
