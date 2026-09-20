import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

typedef PreviewDecoder = Future<Uint8List?> Function(
    String source, Map<String, String> headers, int timeMs);

/// A separate decoder never seeks or pauses the actual video player. Only one
/// frame is decoded at a time; fast drags replace queued work instead of opening
/// a decoder for every pointer event. Images stay in a bounded memory cache.
class SeekPreview extends ChangeNotifier {
  SeekPreview({PreviewDecoder? decoder}) : _decode = decoder ?? _nativeFrame;

  static const debounce = Duration(milliseconds: 160);
  static const maxFrames = 60;
  final PreviewDecoder _decode;
  final _cache = <int, Uint8List?>{};
  String _source = '';
  Map<String, String> _headers = const {};
  Timer? _timer;
  Timer? _timeout;
  int _generation = 0;
  int? _wanted;
  bool _running = false;
  bool _disposed = false;
  Uint8List? image;
  bool loading = false;

  static Future<Uint8List?> _nativeFrame(
      String source, Map<String, String> headers, int timeMs) {
    final uri = Uri.tryParse(source);
    return VideoThumbnail.thumbnailData(
      video: uri?.scheme == 'file' ? uri!.toFilePath() : source,
      headers: headers,
      timeMs: timeMs,
      maxWidth: 320,
      imageFormat: ImageFormat.JPEG,
      quality: 70,
    );
  }

  void setSource(String source, Map<String, String> headers) {
    if (_source == source && mapEquals(_headers, headers)) return;
    _generation++;
    _source = source;
    _headers = Map.of(headers);
    _cache.clear();
    cancel();
  }

  void request(double seconds) {
    if (_disposed || !seconds.isFinite) return;
    final timeMs = (seconds.clamp(0, double.maxFinite) / 2).floor() * 2000;
    if (_wanted == timeMs) return;
    _wanted = timeMs;
    _timer?.cancel();
    image = _cache[timeMs];
    loading = _source.isNotEmpty && !_cache.containsKey(timeMs);
    if (_cache.containsKey(timeMs)) {
      final cached = _cache.remove(timeMs);
      _cache[timeMs] = cached;
    }
    notifyListeners();
    if (loading) _timer = Timer(debounce, _pump);
  }

  Future<void> _pump() async {
    if (_disposed || _running || _wanted == null || _source.isEmpty) return;
    final time = _wanted!;
    if (_cache.containsKey(time)) return;
    final generation = _generation;
    _running = true;
    // A timed-out native decoder may still be running. Change the presentation,
    // but do not start another native job until that decoder actually returns.
    _timeout = Timer(const Duration(seconds: 8), () {
      if (!_disposed && generation == _generation && time == _wanted) {
        loading = false;
        notifyListeners();
      }
    });
    Uint8List? result;
    try {
      result = await _decode(_source, _headers, time);
      if (result?.isEmpty ?? false) result = null;
    } catch (_) {
      // HLS without seekable frames and missing native plugins are optional
      // preview failures, never playback failures.
    } finally {
      _timeout?.cancel();
      _running = false;
    }
    if (_disposed) return;
    if (generation == _generation) {
      _cache[time] = result;
      while (_cache.length > maxFrames) {
        _cache.remove(_cache.keys.first);
      }
      if (_wanted == time) {
        image = result;
        loading = false;
        notifyListeners();
      }
    }
    if (_wanted != null &&
        !_cache.containsKey(_wanted) &&
        !(_timer?.isActive ?? false)) {
      _timer = Timer(debounce, _pump);
    }
  }

  void cancel() {
    _timer?.cancel();
    _wanted = null;
    image = null;
    loading = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timeout?.cancel();
    _cache.clear();
    super.dispose();
  }
}
