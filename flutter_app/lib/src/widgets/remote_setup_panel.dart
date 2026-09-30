/// 掃碼設定的那一塊: QR 碼、手動輸入用的網址, 跟目前走到哪一步.
///
/// 伺服器跟著這個 widget 活: 顯示出來才開, 離開畫面就收掉.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../state/remote_setup.dart';
import '../theme.dart';

class RemoteSetupPanel extends StatefulWidget {
  const RemoteSetupPanel({
    super.key,
    required this.onSubmit,
    this.askServer = true,
    this.initialServer = '',
    this.host,
    this.phoneRemote = false,
  });

  final RemoteSetupHandler onSubmit;
  final bool askServer;
  final String initialServer;

  /// QR 碼裡放的位址. 平常不給, 自己找這台在區網上的那一個.
  @visibleForTesting
  final InternetAddress? host;

  /// 這台開著手機遙控: 提一句手機 App 可以直接把設定傳過來 (比掃碼還省事)
  final bool phoneRemote;

  @override
  State<RemoteSetupPanel> createState() => _RemoteSetupPanelState();
}

class _RemoteSetupPanelState extends State<RemoteSetupPanel> {
  RemoteSetupServer? _server;
  QrImage? _qr;
  String _startError = '';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final server = RemoteSetupServer(
      onSubmit: widget.onSubmit,
      askServer: widget.askServer,
      initialServer: widget.initialServer,
    );
    try {
      final url = await server.start(host: widget.host);
      if (!mounted) {
        unawaited(server.close());
        server.dispose();
        return;
      }
      server.addListener(_changed);
      setState(() {
        _server = server;
        _startError = '';
        _qr = QrImage(QrCode.fromData(
          data: url.toString(),
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ));
      });
    } catch (error) {
      unawaited(server.close());
      server.dispose();
      if (!mounted) return;
      setState(() => _startError =
          error is RemoteSetupException ? error.message : '開不了設定用的連線：$error');
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final server = _server;
    if (server != null) {
      server.removeListener(_changed);
      unawaited(server.close());
      server.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final server = _server;
    final qr = _qr;

    final Widget body;
    if (_startError.isNotEmpty) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_startError,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, height: 1.5)),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () {
              setState(() => _startError = '');
              unawaited(_start());
            },
            child: const Text('重試'),
          ),
        ],
      );
    } else if (server == null || qr == null) {
      body = const Padding(
        padding: EdgeInsets.all(40),
        child: CircularProgressIndicator(),
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: '設定用的 QR 碼',
            image: true,
            child: Container(
              key: const ValueKey('remote-setup-qr'),
              width: 212,
              height: 212,
              decoration: BoxDecoration(
                // 深色主題下也得是白底黑碼, 不然有些相機認不出來
                color: Colors.white,
                borderRadius: BorderRadius.circular(kRadiusSmall),
              ),
              child: CustomPaint(painter: _QrPainter(qr)),
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            server.url.toString(),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: colors.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 12),
          _status(server, colors),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_2_rounded,
                size: 20, color: AgpColors.accent),
            const SizedBox(width: 8),
            Text(
              widget.askServer ? '用手機掃碼設定' : '用手機掃碼登入',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '手機跟這台要連同一個網路。用相機掃描，在打開的網頁裡填好就會送過來。',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12.5, height: 1.5, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        body,
        if (widget.phoneRemote) ...[
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.settings_remote_rounded,
                  size: 18, color: AgpColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.askServer
                      ? '手機上裝了這個 App 的話，也可以在「我的 → 遙控電視」連上這台，直接把伺服器設定 (連同登入) 傳過來。'
                      : '手機上裝了這個 App 的話，也可以在「我的 → 遙控電視」連上這台，直接把登入狀態傳過來。',
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _status(RemoteSetupServer server, ColorScheme colors) {
    final (IconData icon, Color color, String text) = switch (server.phase) {
      RemoteSetupPhase.waiting => (
          Icons.phone_android_rounded,
          colors.onSurfaceVariant,
          '等手機掃碼…'
        ),
      RemoteSetupPhase.opened => (
          Icons.edit_note_rounded,
          AgpColors.accent,
          '手機已經打開設定頁了，填好按送出'
        ),
      RemoteSetupPhase.working => (
          Icons.sync_rounded,
          AgpColors.accent,
          '收到了，正在連線…'
        ),
      RemoteSetupPhase.failed => (
          Icons.error_outline_rounded,
          AgpColors.accent,
          '${server.message}（在手機上改好再送一次）'
        ),
      RemoteSetupPhase.done => (
          Icons.check_circle_rounded,
          AgpColors.accent,
          '完成！'
        ),
    };
    return Row(
      key: const ValueKey('remote-setup-status'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              style: TextStyle(fontSize: 13, color: color, height: 1.4)),
        ),
      ],
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  /// 四周留白四格 —— 規格要的, 少了相機常常對不到焦
  static const int _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount + _quiet * 2;
    final cell = size.shortestSide / count;
    final paint = Paint()
      ..color = Colors.black
      // 關掉反鋸齒, 相鄰的格子之間才不會透出一條細白線
      ..isAntiAlias = false;
    final path = Path();
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        path.addRect(Rect.fromLTWH(
          (col + _quiet) * cell,
          (row + _quiet) * cell,
          cell + 0.5,
          cell + 0.5,
        ));
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}
