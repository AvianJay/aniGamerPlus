import 'dart:math' as math;
import 'dart:typed_data';

/// Byte ranges for the keyframe before a seek and the following 12 seconds.
/// Read sample tables, never estimate byte position from a bitrate ratio.
/// Fragmented/unsupported files return no ranges and play normally.
List<(int, int)> mp4PrefetchRanges(Uint8List moov, double seconds, int total) {
  try {
    final root = _Box(ByteData.sublistView(moov), 0, moov.length);
    final movie = root.children.singleWhere((box) => box.type == 'moov');
    final mvhd = movie.child('mvhd');
    final movieScale = mvhd?.u32(mvhd.u8(0) == 1 ? 20 : 12) ?? 0;
    final ranges = <(int, int)>[];
    for (final track in movie.children.where((box) => box.type == 'trak')) {
      final mdia = track.child('mdia');
      final header = mdia?.child('mdhd');
      final tables = mdia?.child('minf')?.child('stbl');
      if (header == null || tables == null) continue;
      final scale = header.u32(header.u8(0) == 1 ? 20 : 12);
      if (scale == 0) continue;
      var at = math.max(0.0, seconds - 2) * scale;
      final edits = track.child('edts')?.child('elst');
      if (edits != null) {
        if (movieScale == 0) continue;
        var empty = 0.0;
        var mediaStart = 0;
        var supported = false;
        final wide = edits.u8(0) == 1;
        final count = edits.u32(4);
        if (count > 2) continue;
        for (var i = 0; i < count; i++) {
          final p = 8 + i * (wide ? 20 : 12);
          final length = wide ? edits.u64(p) : edits.u32(p);
          final start = wide ? edits.i64(p + 8) : edits.i32(p + 4);
          if (edits.u32(p + (wide ? 16 : 8)) != 0x00010000) break;
          if (start == -1 && !supported) {
            empty += length / movieScale;
          } else if (start >= 0 && !supported) {
            mediaStart = start;
            supported = true;
          } else {
            supported = false;
            break;
          }
        }
        if (!supported) continue;
        at = math.max(0.0, at - empty * scale) + mediaStart;
      }
      final times = tables.child('stts');
      final sizes = tables.child('stsz');
      final mapping = tables.child('stsc');
      final offsets = tables.child('stco') ?? tables.child('co64');
      if (times == null ||
          sizes == null ||
          mapping == null ||
          offsets == null) {
        continue;
      }
      int sampleAt(double ticks) {
        var sample = 0;
        var time = 0;
        for (var i = 0; i < times.u32(4); i++) {
          final count = times.u32(8 + i * 8);
          final delta = times.u32(12 + i * 8);
          if (delta == 0) throw const FormatException('zero sample duration');
          if (ticks < time + count * delta) {
            return sample + math.max(0, (ticks - time) ~/ delta);
          }
          time += count * delta;
          sample += count;
        }
        return sample - 1;
      }

      var first = sampleAt(at);
      final last = sampleAt(at + 14 * scale);
      final sync = tables.child('stss');
      if (sync != null) {
        var before = -1;
        for (var i = 0; i < sync.u32(4); i++) {
          final sample = sync.u32(8 + i * 4) - 1;
          if (sample > first) break;
          before = sample;
        }
        if (before < 0) continue;
        first = before;
      }
      final count = sizes.u32(8);
      final fixedSize = sizes.u32(4);
      final mappings = mapping.u32(4);
      if (count == 0 || first < 0 || last < first || mappings == 0) continue;
      if (mapping.u32(8) != 1) continue;
      var entry = 0;
      var sample = 0;
      for (var chunk = 1; chunk <= offsets.u32(4); chunk++) {
        while (entry + 1 < mappings &&
            mapping.u32(8 + (entry + 1) * 12) <= chunk) {
          entry++;
        }
        final perChunk = mapping.u32(12 + entry * 12);
        if (perChunk == 0 || sample + perChunk > count) break;
        if (sample > last) break;
        if (sample + perChunk > first) {
          final offset = offsets.type == 'co64'
              ? offsets.u64(8 + (chunk - 1) * 8)
              : offsets.u32(8 + (chunk - 1) * 4);
          var bytes = fixedSize * perChunk;
          if (fixedSize == 0) {
            for (var s = sample; s < sample + perChunk; s++) {
              bytes += sizes.u32(12 + s * 4);
            }
          }
          if (bytes > 0 && offset >= 0 && offset + bytes <= total) {
            ranges.add((offset, offset + bytes - 1));
          }
        }
        sample += perChunk;
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.$1 <= merged.last.$2 + 1) {
        final previous = merged.removeLast();
        merged.add((previous.$1, math.max(previous.$2, range.$2)));
      } else {
        merged.add(range);
      }
    }
    return merged;
  } catch (_) {
    return const [];
  }
}

class _Box {
  const _Box(this.data, this.start, this.end, [this.type = '']);
  final ByteData data;
  final int start, end;
  final String type;
  int get payload =>
      type.isEmpty ? start : start + (data.getUint32(start) == 1 ? 16 : 8);
  int u8(int at) => data.getUint8(_at(at, 1));
  int u32(int at) => data.getUint32(_at(at, 4));
  int u64(int at) => data.getUint64(_at(at, 8));
  int i32(int at) => data.getInt32(_at(at, 4));
  int i64(int at) => data.getInt64(_at(at, 8));
  int _at(int at, int bytes) {
    final index = payload + at;
    if (index < payload || index + bytes > end) {
      throw const FormatException('short box');
    }
    return index;
  }

  Iterable<_Box> get children sync* {
    var at = payload;
    while (at + 8 <= end) {
      var size = data.getUint32(at);
      final name = String.fromCharCodes(
          List.generate(4, (i) => data.getUint8(at + 4 + i)));
      final header = size == 1 ? 16 : 8;
      if (at + header > end) throw const FormatException('short box');
      if (size == 1) size = data.getUint64(at + 8);
      if (size == 0) size = end - at;
      if (size < header || at + size > end) {
        throw const FormatException('invalid box');
      }
      yield _Box(data, at, at + size, name);
      at += size;
    }
  }

  _Box? child(String name) {
    for (final box in children) {
      if (box.type == name) return box;
    }
    return null;
  }
}
