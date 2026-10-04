import 'dart:typed_data';

List<int> words(List<int> numbers) {
  final data = ByteData(numbers.length * 4);
  for (var i = 0; i < numbers.length; i++) {
    data.setUint32(i * 4, numbers[i]);
  }
  return data.buffer.asUint8List();
}

List<int> box(String name, List<int> bytes) => [
      ...words([bytes.length + 8]),
      ...name.codeUnits,
      ...bytes
    ];

/// 80 seconds, 2 samples/second, 8 chunks, keyframes every 10 seconds.
/// The early chunks are deliberately tiny; timestamps do not map to byte ratios.
Uint8List sampleMovie(
    {bool tailMoov = false, bool co64 = false, int scale = 1}) {
  final sizes = [100, 200, 300, 1500, 2000, 100, 200, 300]
      .map((size) => size * scale)
      .toList();
  final data = <int>[];
  final offsets = <int>[];
  for (final size in sizes) {
    offsets.add(24 + data.length);
    data.addAll(List.generate(size * 20, (i) => i % 251));
  }
  List<int> moov(List<int> at) => box('moov', [
        ...box('mvhd', words([0, 0, 0, 1000, 80000])),
        ...box(
            'trak',
            box('mdia', [
              ...box('mdhd', words([0, 0, 0, 1000, 80000])),
              ...box(
                  'minf',
                  box('stbl', [
                    ...box('stts', words([0, 1, 160, 500])),
                    ...box('stss',
                        words([0, 8, 1, 21, 41, 61, 81, 101, 121, 141])),
                    ...box('stsc', words([0, 1, 1, 20, 1])),
                    ...box(
                        'stsz',
                        words([
                          0,
                          0,
                          160,
                          for (final size in sizes)
                            for (var i = 0; i < 20; i++) size
                        ])),
                    ...box(
                        co64 ? 'co64' : 'stco',
                        words([
                          0,
                          8,
                          for (final offset in at) ...[if (co64) 0, offset]
                        ])),
                  ])),
            ])),
      ]);
  final head = box('ftyp', words([0, 0]));
  final metadata = moov(offsets);
  return Uint8List.fromList(tailMoov
      ? [...head, ...box('mdat', data), ...metadata]
      : [
          ...head,
          ...moov(offsets.map((at) => at + metadata.length).toList()),
          ...box('mdat', data)
        ]);
}
