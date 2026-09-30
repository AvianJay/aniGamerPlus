/// 電視上的「手機遙控」: 開關、這台的名字跟位址、配對過的手機.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/remote_setup.dart';
import '../state/tv_remote_host.dart';
import '../state/tv_remote_protocol.dart';
import '../util/device.dart';
import 'tv_remote_actions.dart';

class TvRemoteSettingsPage extends StatefulWidget {
  const TvRemoteSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<TvRemoteSettingsPage> createState() => _TvRemoteSettingsPageState();
}

class _TvRemoteSettingsPageState extends State<TvRemoteSettingsPage> {
  TvRemoteHost? _host;
  String _address = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bind();
    unawaited(_loadAddress());
  }

  /// 開關切換之後是另一台 host, 要重新聽
  void _bind() {
    _host?.removeListener(_changed);
    _host = TvRemoteHost.current;
    _host?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAddress() async {
    final address = await RemoteSetupServer.lanAddress();
    if (mounted) setState(() => _address = address?.address ?? '');
  }

  @override
  void dispose() {
    _host?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    await TvRemoteService.setEnabled(on);
    if (!mounted) return;
    _bind();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final host = _host;
    final enabled = widget.state.prefs.remoteEnabled && host != null;
    final port = host?.boundPort ?? kRemotePort;
    final connected = host?.connectedPhones ?? const [];
    final paired = host?.paired ?? const [];

    Widget group(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
          child: Text(title,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('手機遙控')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 30),
        children: [
          SwitchListTile(
            title: const Text('允許手機遙控'),
            subtitle: const Text('手機 App 的「我的 → 遙控電視」可以找到這台'),
            value: enabled,
            onChanged: _busy ? null : (value) => unawaited(_toggle(value)),
          ),
          if (enabled) ...[
            ListTile(
              leading: const Icon(Icons.tv_rounded),
              title: Text(Device.name),
              subtitle: const Text('手機上看到的名字 (在系統設定的「裝置名稱」改)'),
            ),
            ListTile(
              leading: const Icon(Icons.lan_outlined),
              title: Text(_address.isEmpty
                  ? '找不到這台的區網位址'
                  : (port == kRemotePort ? _address : '$_address:$port')),
              subtitle: const Text('手機找不到這台的話，在手機上選「手動輸入電視位址」填這個'),
            ),
            group('正連著的手機'),
            if (connected.isEmpty)
              const ListTile(
                leading: Icon(Icons.phonelink_off_rounded),
                title: Text('沒有'),
              )
            else
              for (final name in connected)
                ListTile(
                  leading: const Icon(Icons.phone_android_rounded),
                  title: Text(name),
                ),
            group('配對過的手機'),
            if (paired.isEmpty)
              const ListTile(
                leading: Icon(Icons.phone_android_rounded),
                title: Text('還沒有'),
                subtitle: Text('第一次連線時電視上會跳出配對碼'),
              )
            else
              for (final phone in paired)
                ListTile(
                  leading: const Icon(Icons.phone_android_rounded),
                  title: Text(phone.name),
                  subtitle: Text('配對於 ${_date(phone.added)}'),
                  trailing: TextButton(
                    onPressed: () => unawaited(host.forget(phone.id)),
                    child: const Text('移除'),
                  ),
                ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Text(
              '手機跟電視連同一個網路，在手機 App 的「我的 → 遙控電視」就能當遙控器用：'
              '方向鍵、打字搜尋、拖進度條，也能把手機正在看的那一集丟到電視上接著播。'
              '電視還沒設定伺服器的話，手機可以把自己的設定 (連同登入) 直接傳過來。',
              style: TextStyle(
                  fontSize: 13, height: 1.6, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  static String _date(int millis) {
    if (millis <= 0) return '—';
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}/${two(time.month)}/${two(time.day)}';
  }
}
