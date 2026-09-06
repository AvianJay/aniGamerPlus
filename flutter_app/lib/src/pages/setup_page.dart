/// 第一次開啟 (或之後要換一台) 時填伺服器位址.
///
/// 這支 app 不會自己去巴哈抓片, 它連的是你自己跑的那台 aniGamerPlus+,
/// 所以位址填的是 Dashboard 的網址, 跟你在瀏覽器上打的那一個一樣.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.state, this.canPop = false});

  final AppState state;

  /// 從「我的」進來的時候上面有返回鍵, 開機時沒有
  final bool canPop;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.state.prefs.server);
  bool _busy = false;
  String _error = '';
  String _hint = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '請先填伺服器位址');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _hint = '';
    });

    final probe = AgpClient(baseUrl: raw);
    try {
      final info = await probe.serverInfo();
      probe.close();
      await widget.state.setServer(raw);
      if (!mounted) return;
      setState(() => _busy = false);
      if (widget.canPop) {
        Navigator.of(context).pop(true);
        return;
      }
      if (info.userControl && !widget.state.loggedIn) {
        _hint = '這台伺服器有開帳號系統, 進去之後記得先登入';
      }
    } catch (error) {
      probe.close();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _explain(error);
      });
    }
  }

  String _explain(Object error) {
    final text = error.toString();
    if (error is ApiException) {
      if (error.statusCode == 404) {
        return '連得上, 但這個位址沒有 aniGamerPlus 的介面 —— 確認一下埠號';
      }
      return error.message;
    }
    if (text.contains('SocketException') || text.contains('Connection refused')) {
      return '連不上. 確認伺服器有開, 而且手機跟它在同一個網路';
    }
    if (text.contains('TimeoutException')) {
      return '連線逾時';
    }
    if (text.contains('HandshakeException')) {
      return 'HTTPS 憑證有問題, 試試看改用 http://';
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.state.prefs.serverHistory;

    return Scaffold(
      appBar: widget.canPop ? AppBar(title: const Text('伺服器位址')) : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 32),
          children: [
            if (!widget.canPop) ...[
              const SizedBox(height: 24),
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: AgpColors.accent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.white, size: 30),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'aniGamerPlus',
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '填上你自己那台 aniGamerPlus 的網址 —— 就是平常用瀏覽器開 Dashboard 的那一個.',
                style: TextStyle(fontSize: 14, height: 1.5, color: AgpColors.fgDim),
              ),
              const SizedBox(height: 26),
            ],
            TextField(
              controller: _controller,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _connect(),
              decoration: const InputDecoration(
                labelText: '伺服器位址',
                hintText: 'http://192.168.1.10:5000',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '沒填 http:// 的話會自動補上.',
              style: TextStyle(fontSize: 12, color: AgpColors.fgFaint),
            ),
            if (history.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in history)
                    ActionChip(
                      label: Text(item, style: const TextStyle(fontSize: 12)),
                      avatar: const Icon(Icons.history, size: 15),
                      onPressed: () => setState(() => _controller.text = item),
                    ),
                ],
              ),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 18),
              _Banner(
                icon: Icons.error_outline,
                color: AgpColors.accent,
                text: _error,
              ),
            ],
            if (_hint.isNotEmpty) ...[
              const SizedBox(height: 18),
              _Banner(
                icon: Icons.info_outline,
                color: const Color(0xFF3A8BD8),
                text: _hint,
              ),
            ],
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _busy ? null : _connect,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('連線'),
            ),
            if (!widget.canPop && widget.state.downloads.finished.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  toast(context, '離線模式: 只會看到已經下載到手機上的集數');
                  widget.state.offline = true;
                  widget.state.booting = false;
                  widget.state.refreshLibrary();
                },
                icon: const Icon(Icons.download_done_rounded, size: 18),
                label: Text('先看離線的 ${widget.state.downloads.finished.length} 集'),
              ),
            ],
            const SizedBox(height: 30),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              '找不到位址?',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 6),
            const Text(
              '在跑 aniGamerPlus 的那台電腦上看 config.json 的 dashboard.host 跟 port, '
              '例如 host 是 0.0.0.0、port 是 5000, 那手機上就填「電腦的區網 IP:5000」.',
              style: TextStyle(fontSize: 13, height: 1.55, color: AgpColors.fgFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadiusSmall),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.45)),
          ),
        ],
      ),
    );
  }
}
