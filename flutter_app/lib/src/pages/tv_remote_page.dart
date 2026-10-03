/// 手機上的「遙控電視」: 找電視、配對, 然後就是一支遙控器.
///
/// 除了方向鍵跟確認鍵, 手機比遙控器多會的幾件事:
///   * 打字 —— 電視上有輸入框在等就填進去, 沒有就直接幫你搜尋
///   * 看到電視上在播什麼, 拖進度條
///   * 把這支手機的伺服器設定 (連同登入) 整包交給電視, 電視不必自己設
///   * 從播放頁「在電視上播放」: 連上就叫電視接著播同一集、同一秒
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../state/remote_setup.dart';
import '../state/tv_remote_client.dart';
import '../state/tv_remote_protocol.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';

/// 從播放頁丟過來的那一集
class TvCast {
  const TvCast({required this.sn, this.at, this.streaming = false});

  final String sn;
  final double? at;
  final bool streaming;
}

class TvRemotePage extends StatefulWidget {
  const TvRemotePage({
    super.key,
    required this.state,
    this.cast,
    this.discovery,
    this.remote,
  });

  final AppState state;

  /// 一連上就叫電視播這一集
  final TvCast? cast;

  /// 測試換掉用
  final TvDiscovery? discovery;
  final TvRemoteClient? remote;

  @override
  State<TvRemotePage> createState() => _TvRemotePageState();
}

class _TvRemotePageState extends State<TvRemotePage> {
  AppState get state => widget.state;
  TvRemoteClient get remote => widget.remote ?? state.tvRemote;

  late final TvDiscovery _discovery = widget.discovery ?? TvDiscovery();
  StreamSubscription<TvDevice>? _scan;
  StreamSubscription<String>? _notices;
  final List<TvDevice> _found = [];
  bool _scanning = false;
  bool _autoScanned = false;
  TvCast? _cast;
  Timer? _ticker;
  double? _dragging;
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cast = widget.cast;
    remote.addListener(_changed);
    _notices = remote.notices.listen((message) {
      if (mounted) toast(context, message);
    });
    // 電視在播的時候進度條自己往前走
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && remote.playing?.playing == true && _dragging == null) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  void _boot() {
    if (!mounted) return;
    if (remote.connected) {
      _sendCast();
      return;
    }
    if (remote.phase == TvRemotePhase.connecting ||
        remote.phase == TvRemotePhase.pairing) {
      return;
    }
    // 上次連的那一台配對過的話直接連, 不必每次都從清單裡挑
    final last = remote.saved.isEmpty ? null : remote.saved.first;
    if (last != null && last.token.isNotEmpty) {
      unawaited(remote.connect(last));
    } else {
      _startScan();
    }
  }

  void _changed() {
    if (!mounted) return;
    if (remote.connected) _sendCast();
    // 自動連上一台失敗了: 改成列出這個網路上的電視
    if (remote.phase == TvRemotePhase.failed && !_autoScanned) _startScan();
    setState(() {});
  }

  void _sendCast() {
    final cast = _cast;
    if (cast == null || !remote.connected) return;
    _cast = null;
    remote.play(cast.sn, at: cast.at, streaming: cast.streaming);
    toast(context, '已經丟到「${remote.device?.name ?? '電視'}」上播放。');
  }

  void _startScan() {
    _autoScanned = true;
    unawaited(_scan?.cancel());
    setState(() {
      _found.clear();
      _scanning = true;
    });
    _scan = _discovery.scan().listen(
      (tv) {
        if (mounted) setState(() => _found.add(tv));
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  @override
  void dispose() {
    remote.removeListener(_changed);
    unawaited(_scan?.cancel());
    unawaited(_notices?.cancel());
    _ticker?.cancel();
    _pin.dispose();
    _text.dispose();
    // 連線刻意不斷: 回到播放頁還要能「在電視上播放」
    super.dispose();
  }

  // ------------------------------------------------------------------ 動作

  void _connect(TvDevice tv) {
    unawaited(_scan?.cancel());
    setState(() => _scanning = false);
    unawaited(remote.connect(tv));
  }

  void _disconnect() {
    remote.disconnect();
    _startScan();
  }

  Future<void> _manual() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (raw == null || !mounted) return;
    final target = TvDevice.parseAddress(raw);
    if (target == null) {
      toast(context, '看不懂這個位址。像這樣填：192.168.1.20');
      return;
    }
    try {
      final tv = await _discovery.probe(target);
      if (!mounted) return;
      _connect(tv);
    } on RemoteSetupException catch (error) {
      if (mounted) toast(context, error.message);
    }
  }

  void _submitPin() {
    final pin = _pin.text.trim();
    if (pin.length != 4) return;
    remote.submitPin(pin);
    _pin.clear();
  }

  void _key(RemoteKey key) => remote.key(key);

  void _sendText() {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    remote.text(value, submit: true);
    _text.clear();
  }

  Future<void> _pushConfig() async {
    final server = state.client.baseUrl;
    final user = state.currentUser?.username ?? '';
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('把設定傳給電視？'),
        content: Text(user.isEmpty
            ? '電視會改連 $server。'
            : '電視會改連 $server，並用「$user」的身分登入 —— 觀看紀錄跟這支手機是同一份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('傳過去'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    remote.configure(server, user.isEmpty ? '' : state.prefs.token);
  }

  // ------------------------------------------------------------------ 畫面

  @override
  Widget build(BuildContext context) {
    final phase = remote.phase;
    final busy = phase == TvRemotePhase.connected ||
        phase == TvRemotePhase.pairing ||
        phase == TvRemotePhase.connecting;
    return Scaffold(
      appBar: AppBar(
        title: Text(phase == TvRemotePhase.connected
            ? remote.device?.name ?? '遙控電視'
            : '遙控電視'),
        actions: [
          if (busy)
            IconButton(
              tooltip: '中斷連線',
              icon: const Icon(Icons.link_off_rounded),
              onPressed: _disconnect,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: switch (phase) {
          TvRemotePhase.connected => _remotePad(),
          TvRemotePhase.pairing => _pairing(),
          TvRemotePhase.connecting => _connecting(),
          _ => _chooser(),
        },
      ),
    );
  }

  Widget _connecting() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 18),
          Text('正在連線到「${remote.device?.name ?? '電視'}」…'),
          const SizedBox(height: 8),
          TextButton(onPressed: _disconnect, child: const Text('取消')),
        ],
      ),
    );
  }

  Widget _pairing() {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
      children: [
        const Icon(Icons.tv_rounded, size: 46, color: AgpColors.accent),
        const SizedBox(height: 14),
        Text(
          '輸入「${remote.device?.name ?? '電視'}」上的配對碼',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          '電視上應該跳出了一組四位數。只要配對一次，之後這支手機會直接連上。',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13.5, height: 1.5, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        TextField(
          key: const ValueKey('remote-pin'),
          controller: _pin,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 4,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
              fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 14),
          decoration: const InputDecoration(counterText: '', hintText: '0000'),
          onChanged: (value) {
            if (value.length == 4) _submitPin();
          },
          onSubmitted: (_) => _submitPin(),
        ),
        if (remote.message.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(remote.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AgpColors.accent)),
        ],
        const SizedBox(height: 20),
        FilledButton(onPressed: _submitPin, child: const Text('配對')),
      ],
    );
  }

  Widget _chooser() {
    final colors = Theme.of(context).colorScheme;
    final earlier = [
      for (final tv in remote.saved)
        if (!_found.any((found) => found.same(tv))) tv
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        if (remote.phase == TvRemotePhase.failed && remote.message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child:
                _Note(icon: Icons.error_outline_rounded, text: remote.message),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('這個網路上的電視',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: colors.onSurfaceVariant)),
              ),
              if (_scanning)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                IconButton(
                  tooltip: '重新找',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: _startScan,
                ),
            ],
          ),
        ),
        for (final tv in _found) _tvTile(tv),
        if (!_scanning && _found.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '沒找到電視。確認電視上開著 aniGamerPlus、「我的 → 手機遙控」是開的，'
              '而且手機跟電視連同一個網路。',
              style: TextStyle(
                  fontSize: 13, height: 1.55, color: colors.onSurfaceVariant),
            ),
          ),
        if (earlier.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
            child: Text('連過的電視',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurfaceVariant)),
          ),
          for (final tv in earlier) _tvTile(tv),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: OutlinedButton.icon(
            onPressed: _manual,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('手動輸入電視位址'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '電視上「我的 → 手機遙控」看得到它的位址。',
            style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _tvTile(TvDevice tv) {
    final known = remote.saved.any((saved) => saved.same(tv));
    return ListTile(
      leading: const Icon(Icons.tv_rounded),
      title: Text(tv.name),
      subtitle: Text(known ? '${tv.address} · 配對過' : tv.address),
      trailing: known
          ? PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (_) => unawaited(remote.forget(tv)),
              itemBuilder: (_) =>
                  const [PopupMenuItem(value: 'forget', child: Text('忘記這台'))],
            )
          : const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () => _connect(tv),
    );
  }

  Widget _remotePad() {
    final playing = remote.playing;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _statusCard(),
        if (playing != null) ...[
          const SizedBox(height: 12),
          _nowPlaying(playing),
        ],
        const SizedBox(height: 22),
        Center(child: _DPad(onKey: _key)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _PadKey(
              label: '返回',
              icon: Icons.arrow_back_rounded,
              size: 60,
              ring: true,
              repeat: false,
              onPress: () => _key(RemoteKey.back),
            ),
            _PadKey(
              label: '首頁',
              icon: Icons.home_rounded,
              size: 60,
              ring: true,
              repeat: false,
              onPress: () => _key(RemoteKey.home),
            ),
            _PadKey(
              label: '播放或暫停',
              icon: Icons.play_arrow_rounded,
              size: 60,
              ring: true,
              repeat: false,
              onPress: () => _key(RemoteKey.playPause),
            ),
          ],
        ),
        const SizedBox(height: 26),
        const Text('電視音量', textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _PadKey(
                label: '降低音量',
                icon: Icons.volume_down_rounded,
                size: 60,
                ring: true,
                onPress: () => _key(RemoteKey.volumeDown)),
            _PadKey(
                label: '靜音或取消靜音',
                icon: Icons.volume_off_rounded,
                size: 60,
                ring: true,
                repeat: false,
                onPress: () => _key(RemoteKey.mute)),
            _PadKey(
                label: '提高音量',
                icon: Icons.volume_up_rounded,
                size: 60,
                ring: true,
                onPress: () => _key(RemoteKey.volumeUp)),
          ],
        ),
        const SizedBox(height: 8),
        Text('擴大機的音量連動取決於電視的音訊輸出設定。',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 26),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('remote-text'),
                controller: _text,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  hintText: '打字到電視上',
                  prefixIcon: Icon(Icons.keyboard_rounded),
                ),
                onSubmitted: (_) => _sendText(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '送到電視',
              onPressed: _sendText,
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '電視上有輸入框在等就填進去；沒有的話直接幫你搜尋片名。',
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _statusCard() {
    final colors = Theme.of(context).colorScheme;
    final phoneServer = state.client.hasServer ? state.client.baseUrl : '';
    final phoneUser = state.currentUser?.username ?? '';
    final tvServer = remote.tvServer;
    final tvUser = remote.tvUser;
    // 手機有的、電視沒有 (或不一樣) 才問要不要傳過去
    final differs = phoneServer.isNotEmpty &&
        (tvServer != phoneServer ||
            (phoneUser.isNotEmpty && tvUser != phoneUser));
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tv_rounded, color: AgpColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(remote.device?.name ?? '電視',
                        style: const TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(
                      tvServer.isEmpty
                          ? '電視還沒設定伺服器'
                          : '$tvServer${tvUser.isEmpty ? '' : ' · $tvUser'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (differs) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                key: const ValueKey('remote-push-config'),
                onPressed: _pushConfig,
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: Text(tvServer.isEmpty ? '把這支手機的設定傳給電視' : '讓電視改用這支手機的設定'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _nowPlaying(NowPlaying playing) {
    final colors = Theme.of(context).colorScheme;
    final duration = playing.duration;
    final max = duration > 0 ? duration : 1.0;
    final position = (_dragging ?? remote.position).clamp(0.0, max).toDouble();
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(playing.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          if (playing.episode.isNotEmpty)
            Text(playing.episode,
                style:
                    TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant)),
          Slider(
            key: const ValueKey('remote-seek'),
            value: position,
            max: max,
            onChanged: duration > 0
                ? (value) => setState(() => _dragging = value)
                : null,
            onChangeEnd: duration > 0
                ? (value) {
                    setState(() => _dragging = null);
                    remote.seek(value);
                  }
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(formatPlayerClock(position),
                    style: const TextStyle(
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()])),
                const Spacer(),
                Text(formatPlayerClock(duration),
                    style: const TextStyle(
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                tooltip: '上一集',
                icon: const Icon(Icons.skip_previous_rounded),
                onPressed: () => _key(RemoteKey.previous),
              ),
              IconButton(
                tooltip: '倒退 10 秒',
                icon: const Icon(Icons.replay_10_rounded),
                onPressed: () => _key(RemoteKey.rewind),
              ),
              IconButton.filled(
                tooltip: playing.playing ? '暫停' : '播放',
                iconSize: 30,
                icon: Icon(playing.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
                onPressed: () => _key(RemoteKey.playPause),
              ),
              IconButton(
                tooltip: '快進 10 秒',
                icon: const Icon(Icons.forward_10_rounded),
                onPressed: () => _key(RemoteKey.fastForward),
              ),
              IconButton(
                tooltip: '下一集',
                icon: const Icon(Icons.skip_next_rounded),
                onPressed: () => _key(RemoteKey.next),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 上下左右 + 中間的確認
class _DPad extends StatelessWidget {
  const _DPad({required this.onKey});

  final void Function(RemoteKey key) onKey;

  static const double _size = 244;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget arrow(RemoteKey key, IconData icon, String label) => _PadKey(
          label: label,
          icon: icon,
          size: 76,
          onPress: () => onKey(key),
        );
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceContainerHighest,
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
            ),
          ),
          Align(
              alignment: Alignment.topCenter,
              child: arrow(RemoteKey.up, Icons.keyboard_arrow_up_rounded, '上')),
          Align(
              alignment: Alignment.bottomCenter,
              child: arrow(
                  RemoteKey.down, Icons.keyboard_arrow_down_rounded, '下')),
          Align(
              alignment: Alignment.centerLeft,
              child: arrow(
                  RemoteKey.left, Icons.keyboard_arrow_left_rounded, '左')),
          Align(
              alignment: Alignment.centerRight,
              child: arrow(
                  RemoteKey.right, Icons.keyboard_arrow_right_rounded, '右')),
          Center(
            child: _PadKey(
              label: '確認',
              text: 'OK',
              size: 92,
              filled: true,
              repeat: false,
              onPress: () => onKey(RemoteKey.ok),
            ),
          ),
        ],
      ),
    );
  }
}

/// 遙控器上的一顆鍵. 按下去當下就送 (不等放開), 按住不放會一直送 —— 清單很長
/// 的時候不必一格一格按.
class _PadKey extends StatefulWidget {
  const _PadKey({
    required this.label,
    required this.onPress,
    this.icon,
    this.text,
    this.size = 72,
    this.filled = false,
    this.ring = false,
    this.repeat = true,
  });

  final String label;
  final VoidCallback onPress;
  final IconData? icon;
  final String? text;
  final double size;
  final bool filled;
  final bool ring;
  final bool repeat;

  @override
  State<_PadKey> createState() => _PadKeyState();
}

class _PadKeyState extends State<_PadKey> {
  Timer? _delay;
  Timer? _repeat;
  bool _down = false;

  void _start() {
    HapticFeedback.selectionClick();
    widget.onPress();
    setState(() => _down = true);
    if (!widget.repeat) return;
    _delay = Timer(const Duration(milliseconds: 420), () {
      _repeat = Timer.periodic(
          const Duration(milliseconds: 120), (_) => widget.onPress());
    });
  }

  void _stop() {
    _delay?.cancel();
    _repeat?.cancel();
    if (_down && mounted) setState(() => _down = false);
  }

  @override
  void dispose() {
    _delay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final Color background;
    if (widget.filled) {
      background = _down ? const Color(0xFF0092AB) : AgpColors.accent;
    } else {
      background =
          _down ? AgpColors.accent.withValues(alpha: 0.22) : Colors.transparent;
    }
    final foreground = widget.filled ? Colors.white : colors.onSurface;
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onPress,
      excludeSemantics: true,
      // 在會捲動的頁面裡: 手指一動就算是在捲, 不算按
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _start(),
        onTapUp: (_) => _stop(),
        onTapCancel: _stop,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: background,
            border: widget.ring
                ? Border.all(color: Theme.of(context).dividerColor)
                : null,
          ),
          child: widget.text != null
              ? Text(widget.text!,
                  style: TextStyle(
                      color: foreground,
                      fontSize: 20,
                      fontWeight: FontWeight.w800))
              : Icon(widget.icon, size: widget.size * 0.46, color: foreground),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: child,
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AgpColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadiusSmall),
        border: Border.all(color: AgpColors.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AgpColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 13.5, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('電視的位址'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(hintText: '192.168.1.20'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('連線'),
        ),
      ],
    );
  }
}
