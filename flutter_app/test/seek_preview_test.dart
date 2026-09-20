import 'dart:async';

import 'package:agp_mobile/src/state/seek_preview.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('fast drags decode only the latest frame and reuse cached frames',
      (tester) async {
    final calls = <int>[];
    final preview = SeekPreview(decoder: (_, __, time) async {
      calls.add(time);
      return Uint8List.fromList([time ~/ 2000]);
    })
      ..setSource('/episode.mp4', const {});
    addTearDown(preview.dispose);
    preview.request(10);
    preview.request(43);
    preview.request(86);
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, [86000]);
    expect(preview.image, [43]);
    preview.request(10);
    await tester.pump(const Duration(milliseconds: 200));
    preview.request(87);
    expect(preview.image, [43]);
    expect(calls, [86000, 10000]);
  });

  testWidgets('in-flight frames never overwrite a newer drag or source',
      (tester) async {
    final jobs = <Completer<Uint8List?>>[];
    final sources = <String>[];
    final preview = SeekPreview(decoder: (source, _, __) {
      sources.add(source);
      final job = Completer<Uint8List?>();
      jobs.add(job);
      return job.future;
    })
      ..setSource('/one.mp4', const {});
    addTearDown(preview.dispose);
    preview.request(10);
    await tester.pump(const Duration(milliseconds: 200));
    preview.setSource('/two.mp4', const {});
    preview.request(80);
    await tester.pump(const Duration(milliseconds: 200));
    expect(jobs.length, 1, reason: 'one native decoder at a time');
    jobs.first.complete(Uint8List.fromList([1]));
    await tester.pump();
    expect(preview.image, isNull);
    await tester.pump(const Duration(milliseconds: 200));
    expect(sources, ['/one.mp4', '/two.mp4']);
    preview.cancel();
    jobs.last.complete(Uint8List.fromList([2]));
    await tester.pump();
    expect(preview.image, isNull);
  });

  testWidgets(
      'decoder failures and timeouts do not queue unlimited native work',
      (tester) async {
    final job = Completer<Uint8List?>();
    var calls = 0;
    final preview = SeekPreview(decoder: (_, __, ___) {
      calls++;
      return job.future;
    })
      ..setSource('/slow.mp4', const {});
    addTearDown(preview.dispose);
    preview.request(5);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 9));
    expect(preview.loading, false);
    preview.request(45);
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, 1);
    preview.cancel();
    job.completeError(StateError('unsupported media'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'native thumbnail request keeps authentication and uses milliseconds',
      (tester) async {
    const channel = MethodChannel('plugins.justsoft.xyz/video_thumbnail');
    MethodCall? sent;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      sent = call;
      return Uint8List.fromList([1]);
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final preview = SeekPreview()
      ..setSource('https://example.test/video.mp4', {'Cookie': 'token=test'})
      ..request(254);
    await tester.pump(const Duration(milliseconds: 200));
    expect(sent!.method, 'data');
    expect(sent!.arguments['timeMs'], 254000);
    expect(sent!.arguments['headers'], {'Cookie': 'token=test'});
    expect(sent!.arguments['maxw'], 320);
    preview.dispose();
  });
}
