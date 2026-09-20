import 'package:flutter/material.dart';

import '../state/seek_preview.dart';
import '../util/format.dart';

class SeekPreviewCard extends StatelessWidget {
  const SeekPreviewCard(
      {super.key,
      required this.preview,
      required this.seconds,
      this.width = 160,
      this.unavailable = false});

  final SeekPreview preview;
  final double seconds;
  final double width;
  final bool unavailable;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ListenableBuilder(
          listenable: preview,
          builder: (context, _) => SizedBox(
            width: width,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xEE181A20),
                  border: Border.all(color: Colors.white54),
                  borderRadius: BorderRadius.circular(5),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 12)
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: !unavailable && preview.image != null
                        ? Image.memory(preview.image!,
                            fit: BoxFit.contain,
                            gaplessPlayback: false,
                            errorBuilder: (_, __, ___) => const Center(
                                child: Icon(Icons.image_not_supported_outlined,
                                    color: Colors.white54)))
                        : Center(
                            child: preview.loading && !unavailable
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white70))
                                : Text(unavailable ? '尚未下載到這裡' : '此片源無法預覽',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11))),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(formatPlayerClock(seconds),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(color: Colors.black, blurRadius: 5)],
                      fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ),
        ),
      );
}
