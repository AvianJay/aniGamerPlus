import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Optional local fonts make UI audit captures readable; CI stays self-contained.
Future<void> loadCaptureFonts() async {
  final font = Platform.environment['AGP_CJK_FONT'];
  if (font != null) {
    final data = await File(font).readAsBytes();
    for (final family in ['Ahem', 'Roboto', 'AuditFont']) {
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(data))))
          .load();
    }
  }
  final icons = Platform.environment['AGP_ICON_FONT'];
  if (icons != null) {
    await (FontLoader('MaterialIcons')
          ..addFont(File(icons).readAsBytes().then(ByteData.sublistView)))
        .load();
  }
}

ThemeData captureTheme(ThemeData theme) {
  if (Platform.environment['AGP_CJK_FONT'] == null) return theme;
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'AuditFont'),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'AuditFont'),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle:
          theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'AuditFont'),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: theme.chipTheme.labelStyle?.copyWith(fontFamily: 'AuditFont'),
    ),
  );
}

/// File-image decoding uses real IO, outside the widget test's fake clock.
Future<void> settleImages(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 16));
    final images = tester.renderObjectList<RenderImage>(find.byType(RawImage));
    if (images.every((image) => image.image != null)) return;
  }
  fail('The visible poster did not finish decoding');
}
