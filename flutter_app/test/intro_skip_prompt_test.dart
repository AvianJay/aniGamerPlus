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
      {String episode = '1',
      bool tv = false,
      IntroSkip intro = const IntroSkip(160, 250, 'AniSkip')}) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(brightness: Brightness.dark, tv: tv),
      home: Scaffold(
          body: Center(
              child: IntroSkipPrompt(
        clock: clock,
        intro: intro,
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

  testWidgets('03:26 OP counts from 03:20 and skips at 03:29', (tester) async {
    clock.value = 199.99;
    await show(tester, intro: const IntroSkip(206, 296, 'AniSkip'));
    expect(card, findsNothing);
    clock.value = 200;
    await tester.pump();
    expect(find.text('立即跳過 (9)'), findsOneWidget);
    // A frozen native clock must not skip, even if real time has elapsed.
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('立即跳過 (9)'), findsOneWidget);
    expect(skips, 0);
    for (var second = 201; second < 209; second++) {
      clock.value = second.toDouble();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('立即跳過 (${209 - second})'), findsOneWidget);
      expect(skips, 0);
    }
    clock.value = 208.999;
    await tester.pump();
    expect(skips, 0);
    clock.value = 209;
    await tester.pump();
    expect(skips, 1);
    await tester.pump();
    expect(card, findsNothing);
    clock.value = 215;
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('manual skip is available six seconds before OP', (tester) async {
    clock.value = 154;
    await show(tester);
    await tester.tap(skip);
    await tester.pump();
    expect(skips, 1);
    expect(card, findsNothing);
  });

  testWidgets('late entry gives nine playback seconds to cancel',
      (tester) async {
    clock.value = 164;
    await show(tester);
    expect(find.text('立即跳過 (9)'), findsOneWidget);
    clock.value = 172.999;
    await tester.pump();
    expect(find.text('立即跳過 (1)'), findsOneWidget);
    expect(skips, 0);
    clock.value = 173;
    await tester.pump();
    expect(skips, 1);
    await tester.pump();
    expect(card, findsNothing);
  });

  testWidgets('pause, buffering and covered menus hold the remaining countdown',
      (tester) async {
    clock.value = 154;
    await show(tester);
    clock.value = 156;
    await tester.pump();
    expect(find.text('立即跳過 (7)'), findsOneWidget);
    running = false;
    await show(tester);
    await tester.pump(const Duration(seconds: 15));
    expect(skips, 0);
    expect(find.text('立即跳過 (7)'), findsOneWidget);
    clock.value = 164;
    await tester.pump();
    expect(find.text('立即跳過 (7)'), findsOneWidget);
    running = true;
    active = false;
    await show(tester);
    clock.value = 172;
    await tester.pump();
    expect(find.text('立即跳過 (7)'), findsOneWidget);
    expect(skips, 0);
    active = true;
    await show(tester);
    clock.value = 179;
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('clock updates within a second do not rebuild the card',
      (tester) async {
    clock.value = 154;
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
    expect(card, findsNothing);
    expect(skips, 0);
    clock.value = 154;
    await tester.pump();
    expect(find.text('立即跳過 (9)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rewinding before the countdown resets its deadline',
      (tester) async {
    clock.value = 154;
    await show(tester);
    clock.value = 160;
    await tester.pump();
    expect(find.text('立即跳過 (3)'), findsOneWidget);
    clock.value = 153;
    await tester.pump();
    expect(card, findsNothing);
    clock.value = 154;
    await tester.pump();
    expect(find.text('立即跳過 (9)'), findsOneWidget);
    clock.value = 163;
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('OP at the beginning of a video cannot count before zero',
      (tester) async {
    clock.value = 0;
    await show(tester, intro: const IntroSkip(0, 90, 'AniSkip'));
    expect(find.text('立即跳過 (3)'), findsOneWidget);
    clock.value = 2.999;
    await tester.pump();
    expect(skips, 0);
    clock.value = 3;
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('fractional OP timestamps do not round the skip earlier',
      (tester) async {
    clock.value = 154.776;
    await show(tester, intro: const IntroSkip(160.776, 250.776, 'AniSkip'));
    clock.value = 163.775;
    await tester.pump();
    expect(find.text('立即跳過 (1)'), findsOneWidget);
    expect(skips, 0);
    clock.value = 163.776;
    await tester.pump();
    expect(skips, 1);
  });

  testWidgets('cancel stays dismissed until the next episode', (tester) async {
    clock.value = 154;
    await show(tester);
    await tester.tap(cancel);
    clock.value = 163;
    await tester.pump();
    expect(cancels, 1);
    expect(skips, 0);
    clock.value = 154;
    await show(tester);
    expect(card, findsNothing);
    await show(tester, episode: '2');
    expect(find.text('立即跳過 (9)'), findsOneWidget);
    clock.value = 163;
    await tester.pump();
    expect(skips, 1);
  });

  for (final phone in [false, true]) {
    testWidgets('TV confirms skip and navigates to cancel (phone=$phone)',
        (tester) async {
      await show(tester, tv: true);
      clock.value = 154;
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
      clock.value = 163;
      await tester.pump();
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
