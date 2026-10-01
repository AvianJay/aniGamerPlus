/// 選一台 Chromecast 投放, 或停止投放.
///
/// 面板開著的時候會主動找裝置; 播放頁本身也在找 (附近有裝置才把按鈕擺出來),
/// 兩邊各開各關, 見 CastController.startDiscovery.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/cast.dart';
import 'common.dart';

Future<void> showCastSheet(BuildContext context, {required CastController cast}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => CastSheet(cast: cast),
  );
}

class CastSheet extends StatefulWidget {
  const CastSheet({super.key, required this.cast});

  final CastController cast;

  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  CastController get cast => widget.cast;

  /// 找了一陣子還是空的, 就把「為什麼找不到」寫出來
  bool _waitedLong = false;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    cast.startDiscovery();
    _hintTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _waitedLong = true);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    cast.stopDiscovery();
    super.dispose();
  }

  Future<void> _connect(CastDevice device) async {
    final ok = await cast.connect(device);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      toast(context, '連不上「${device.name}」。');
    }
  }

  Future<void> _stop() async {
    Navigator.of(context).pop();
    await cast.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListenableBuilder(
        listenable: cast,
        builder: (context, _) {
          final children = <Widget>[];
          if (cast.connected) {
            children.addAll([
              ListTile(
                leading: Icon(Icons.cast_connected_rounded, color: colors.primary),
                title: Text(cast.deviceName ?? ''),
                subtitle: const Text('正在投放'),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('cast-stop'),
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('停止投放'),
                subtitle: const Text('回到手機上，從電視停下的地方接著看'),
                onTap: () => unawaited(_stop()),
              ),
            ]);
          } else {
            children.add(Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('投放到電視',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('Chromecast 或內建 Chromecast 的電視、喇叭',
                      style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant)),
                ],
              ),
            ));
            for (final device in cast.devices) {
              final busy = cast.connecting == device;
              children.add(ListTile(
                key: ValueKey('cast-device-${device.id}'),
                leading: const Icon(Icons.tv_rounded),
                title: Text(device.name),
                subtitle: device.model.isEmpty ? null : Text(device.model),
                trailing: busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                enabled: cast.connecting == null,
                onTap: () => unawaited(_connect(device)),
              ));
            }
            if (cast.devices.isEmpty) {
              children.add(ListTile(
                leading: const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                title: const Text('正在找同一個 Wi-Fi 上的裝置…'),
                subtitle: _waitedLong
                    ? const Text('找不到的話，確認手機跟電視連的是同一個 Wi-Fi，'
                        '而且路由器沒有開「AP 隔離」。')
                    : null,
              ));
            }
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          );
        },
      ),
    );
  }
}
