import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/discord_presence.dart';

/// Credentials are consumed inside the app and never returned through navigation.
class DiscordLoginPage extends StatefulWidget {
  const DiscordLoginPage({super.key, required this.presence});
  final DiscordPresence presence;
  @override
  State<DiscordLoginPage> createState() => _DiscordLoginPageState();
}

class _DiscordLoginPageState extends State<DiscordLoginPage> {
  WebViewController? _controller;
  Timer? _poll;
  bool _reading = false, _linking = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          return uri?.scheme == 'https' &&
                  (!request.isMainFrame || uri?.host == 'discord.com')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageFinished: (_) => unawaited(_read()),
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted) {
            setState(() => _error = '登入頁載入失敗，請檢查網路後重新開啟。');
          }
        },
      ));
      await WebViewCookieManager().clearCookies();
      await controller.clearLocalStorage();
      if (!mounted) return;
      _controller = controller;
      setState(() {});
      await controller.loadRequest(Uri.parse('https://discord.com/login'));
      _poll =
          Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_read()));
    } catch (_) {
      if (mounted) setState(() => _error = '這台裝置無法開啟 WebView。TV 請使用手機傳送登入。');
    }
  }

  Future<void> _read() async {
    final controller = _controller;
    if (controller == null || !mounted || _reading || _linking) return;
    _reading = true;
    try {
      final uri = Uri.tryParse(await controller.currentUrl() ?? '');
      if (uri?.scheme != 'https' ||
          uri?.host != 'discord.com' ||
          !(uri!.path.startsWith('/channels') || uri.path == '/app')) {
        return;
      }
      final result = await controller.runJavaScriptReturningResult('''
        (() => {
          if (location.origin !== 'https://discord.com') return '';
          let frame;
          try {
            frame = document.createElement('iframe');
            document.body.appendChild(frame);
            const value = frame.contentWindow.localStorage.getItem('token');
            return value ? JSON.parse(value) : '';
          } catch (_) { return ''; }
          finally { if (frame) frame.remove(); }
        })()
      ''');
      var token = result is String ? result : '';
      // Android returns the JSON-encoded JavaScript string; WebKit returns it raw.
      if (token.startsWith('"')) {
        final decoded = jsonDecode(token);
        token = decoded is String ? decoded : '';
      }
      if (token.isEmpty || !mounted) return;
      _linking = true;
      _poll?.cancel();
      await widget.presence.link(token);
      await controller.clearLocalStorage();
      await WebViewCookieManager().clearCookies();
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (_linking && mounted) {
        setState(() => _error = 'Discord 登入驗證失敗，請返回後重新登入。');
      }
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_controller?.clearLocalStorage().catchError((Object _) {}));
    unawaited(
        WebViewCookieManager().clearCookies().catchError((Object _) => false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('登入 Discord')),
        body: Column(children: [
          if (_error.isNotEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error)),
          if (_controller != null)
            Expanded(child: WebViewWidget(controller: _controller!))
          else if (_error.isEmpty)
            const Expanded(child: Center(child: CircularProgressIndicator())),
        ]),
      );
}
