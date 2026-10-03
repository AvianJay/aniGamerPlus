import 'package:agp_mobile/src/widgets/active_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TrackedValue<T> extends ValueNotifier<T> {
  TrackedValue(super.value);
  bool get listening => hasListeners;
}

void main() {
  testWidgets('隱藏畫面不因通知重建, 回來顯示最新值並解除舊監聽', (tester) async {
    final first = TrackedValue<int>(0);
    final second = TrackedValue<int>(10);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var builds = 0;
    Future<void> show(bool active, ValueNotifier<int> value) =>
        tester.pumpWidget(
          MaterialApp(
              home: TickerMode(
                  enabled: active,
                  child: ActiveListenableBuilder(
                      listenable: value,
                      builder: (_) {
                        builds++;
                        return Text('${value.value}');
                      }))),
        );
    await show(true, first);
    first.value = 1;
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    await show(false, first);
    final before = builds;
    for (var i = 2; i < 8; i++) {
      first.value = i;
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pump();
    }
    expect(builds, before);
    await show(true, first);
    expect(find.text('7'), findsOneWidget);
    await show(true, second);
    expect(first.listening, isFalse);
    expect(find.text('10'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(second.listening, isFalse);
  });

  testWidgets('時鐘只在跨過片頭顯示區間時要求重建', (tester) async {
    final clock = TrackedValue<double>(0);
    addTearDown(clock.dispose);
    await tester.pumpWidget(MaterialApp(
        home: ClockVisibility(
            clock: clock,
            visibleAt: (time) => time >= 10 && time < 20,
            child: const Text('跳過片頭'))));
    await tester.pump();
    for (final time in [1.0, 5.0, 9.9]) {
      clock.value = time;
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
    clock.value = 10;
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(find.text('跳過片頭'), findsOneWidget);
    clock.value = 15;
    expect(tester.binding.hasScheduledFrame, isFalse);
    clock.value = 20;
    await tester.pump();
    expect(find.text('跳過片頭'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(clock.listening, isFalse);
  });
}
