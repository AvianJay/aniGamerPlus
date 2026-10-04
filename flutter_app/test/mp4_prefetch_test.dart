import 'dart:typed_data';

import 'package:agp_mobile/src/state/mp4_prefetch.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mp4_fixture.dart';

void main() {
  for (final tail in [false, true]) {
    for (final wide in [false, true]) {
      test(
          'keyframe and following chunks use sample tables (tail=$tail, co64=$wide)',
          () {
        final file = sampleMovie(tailMoov: tail, co64: wide);
        final data = ByteData.sublistView(file);
        final offset = tail ? data.getUint32(0) + data.getUint32(16) : 16;
        final size = data.getUint32(offset);
        final ranges = mp4PrefetchRanges(
            Uint8List.sublistView(file, offset, offset + size),
            32,
            file.length);
        expect(ranges, hasLength(1));
        // Chunk 4 keyframe is at 30s; cover chunks 4 and 5 through 44s.
        final mdat = tail ? 16 : 16 + size;
        expect(ranges.single, (mdat + 8 + 12000, mdat + 8 + 82000 - 1));
      });
    }
  }
  test('truncated and unsupported sample tables never guess a range', () {
    expect(mp4PrefetchRanges(Uint8List(20), 32, 1000), isEmpty);
    expect(mp4PrefetchRanges(Uint8List.fromList(box('moov', [])), 32, 1000),
        isEmpty);
  });
}
