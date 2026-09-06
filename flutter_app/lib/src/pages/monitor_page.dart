/// 任務監控 —— 對應 templates/monitor.html + static/js/monitor.js.
///
/// 伺服器把整份佇列 (不是差分) 從 WebSocket /data/tasks_progress 推過來:
///   `{ "<sn>": { "filename": ..., "status": ..., "rate": 0~100 }, ... }`
/// 網頁版斷線後 1500 毫秒重連, 這裡照抄, 只是多了退避上限跟畫面上的連線狀態,
/// 手機常常在切網路, 一直閃「連線中」比較難看。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class MonitorTask {
  MonitorTask({
    required this.sn,
    required this.filename,
    required this.status,
    required this.rate,
  });

  final String sn;
  final String filename;
  final String status;
  final double rate;

  factory MonitorTask.fromJson(String sn, Map<dynamic, dynamic> json) {
    final raw = json['rate'];
    final rate = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
    return MonitorTask(
      sn: sn,
      filename: '${json['filename'] ?? ''}',
      status: '${json['status'] ?? ''}',
      rate: rate.clamp(0, 100).toDouble(),
    );
  }
}

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key, required this.state});

  final AppState state;

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;

  List<MonitorTask> _tasks = const [];
  bool _connected = false;
  bool _disposed = false;
  int _attempts = 0;
  String _error = '';

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- 連線

  void _connect() {
    if (_disposed) return;
    _retry?.cancel();
    _sub?.cancel();
    _channel?.sink.close();

    if (!state.client.hasServer) {
      setState(() => _error = '還沒設定伺服器位址。');
      return;
    }

    try {
      final channel = state.client.connectTasksProgress();
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object error) => _drop('連線發生錯誤: $error'),
        onDone: () => _drop(''),
        cancelOnError: true,
      );
      setState(() {
        _error = '';
        _connected = true;
      });
    } catch (error) {
      _drop('連不上任務監控: $error');
    }
  }

  void _drop(String message) {
    if (_disposed) return;
    setState(() {
      _connected = false;
      if (message.isNotEmpty) _error = message;
    });
    _scheduleReconnect();
  }

  /// 網頁版固定 1500 毫秒, 手機上連不上時往後拉到最多 10 秒, 省點電
  void _scheduleReconnect() {
    if (_disposed) return;
    _attempts += 1;
    final delay = Duration(
      milliseconds: (1500 * _attempts).clamp(1500, 10000),
    );
    _retry?.cancel();
    _retry = Timer(delay, _connect);
  }

  void _onMessage(dynamic raw) {
    if (_disposed) return;
    _attempts = 0;
    Map<dynamic, dynamic> payload;
    try {
      final decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (decoded is! Map) return;
      payload = decoded;
    } catch (_) {
      // monitor.js 也是靜靜吞掉解析失敗
      return;
    }

    final tasks = <MonitorTask>[];
    payload.forEach((sn, value) {
      if (value is Map) tasks.add(MonitorTask.fromJson('$sn', value));
    });
    tasks.sort((a, b) => b.rate.compareTo(a.rate));

    setState(() {
      _tasks = tasks;
      _connected = true;
      _error = '';
    });
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('任務監控'),
        actions: [
          IconButton(
            tooltip: '立即檢查更新',
            icon: const Icon(Icons.bolt_rounded),
            onPressed: _checkNow,
          ),
          IconButton(
            tooltip: '重新連線',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              _attempts = 0;
              _connect();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _statusBar(),
          Expanded(
            child: _tasks.isEmpty
                ? EmptyState(
                    icon: Icons.playlist_play_rounded,
                    title: '當前無任務',
                    message: _error.isNotEmpty
                        ? _error
                        : '伺服器的下載佇列是空的。排了新任務之後這裡會即時跳出來。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _tasks.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) => _card(_tasks[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    final colour = _connected ? const Color(0xFF34D399) : AgpColors.accent;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _connected
                  ? '已連線 · ${_tasks.length} 個任務進行中'
                  : (_error.isEmpty ? '連線中斷，正在重連…' : _error),
              style: const TextStyle(fontSize: 12.5, color: AgpColors.fgDim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(MonitorTask task) {
    final percent = task.rate.round();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: AgpColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.filename.isEmpty ? 'sn=${task.sn}' : task.filename,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  task.status.isEmpty ? '處理中' : task.status,
                  style: const TextStyle(fontSize: 12.5, color: AgpColors.fgDim),
                ),
              ),
              Text(
                '$percent%',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: AgpColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          ThinProgress(value: percent / 100),
        ],
      ),
    );
  }

  Future<void> _checkNow() async {
    try {
      await state.client.checkNow();
      if (!mounted) return;
      toast(context, '已要求伺服器立即檢查更新。');
    } catch (error) {
      if (!mounted) return;
      toast(context, '檢查失敗: $error');
    }
  }
}
