import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import 'downloads.dart';

/// Keep the Wi-Fi preference effective while the app is open, including when
/// returning from Settings or switching networks in the background.
class DownloadNetwork extends WidgetsBindingObserver {
  DownloadNetwork(this.store);

  final DownloadStore store;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _wifiOnly = false;
  bool _hasWifi = false;
  bool _disposed = false;
  int _revision = 0;

  Future<void> start({required bool wifiOnly}) async {
    _wifiOnly = wifiOnly;
    await store.setNetworkAllowed(!wifiOnly);
    WidgetsBinding.instance.addObserver(this);
    _subscription = _connectivity.onConnectivityChanged.listen((networks) {
      _revision++;
      _update(networks);
    }, onError: (Object _) => _update(const []));
    await refresh();
  }

  Future<void> setWifiOnly(bool value) async {
    _wifiOnly = value;
    await store.setNetworkAllowed(!value || _hasWifi);
    await refresh();
  }

  Future<void> refresh() async {
    final revision = ++_revision;
    try {
      final networks = await _connectivity.checkConnectivity();
      if (!_disposed && revision == _revision) _update(networks);
    } catch (_) {
      // If the platform cannot confirm Wi-Fi, never silently use mobile data.
      if (!_disposed && revision == _revision) _update(const []);
    }
  }

  void _update(List<ConnectivityResult> networks) {
    if (_disposed) return;
    _hasWifi = networks.contains(ConnectivityResult.wifi);
    unawaited(store.setNetworkAllowed(!_wifiOnly || _hasWifi));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
  }
}
