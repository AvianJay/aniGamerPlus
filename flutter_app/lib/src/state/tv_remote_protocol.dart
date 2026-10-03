/// 手機遙控電視: 兩邊共用的常數、按鍵跟資料格式.
///
/// 電視 (TvRemoteHost) 在區網上開一台 WebSocket 伺服器, 手機 (TvRemoteClient)
/// 連上去送按鍵、文字、「播這一集」. 第一次連要在手機上輸入電視顯示的配對碼,
/// 之後憑配對時拿到的 token 直接連.
///
/// 訊息都是一個 JSON 物件, `t` 是種類:
///
/// 手機 → 電視
///   hello   {id, name, token}     第一句. token 空的就要配對
///   pair    {pin}                 電視上顯示的四位數
///   key     {k}                   RemoteKey 的名字
///   text    {value, submit}       填進電視上的輸入框 (沒有就開搜尋)
///   play    {sn, at?, streaming?} 在電視上播這一集
///   seek    {to}                  播放中跳到第幾秒
///   config  {server, token}       把手機的伺服器設定跟登入狀態交給電視
///
/// 電視 → 手機
///   welcome {id, name, server, user}  認得這支手機了
///   pair-required                     電視上已經顯示配對碼
///   paired  {token}                   配對成功, 下次憑這個直接連
///   pair-failed {left}                配對碼不對
///   state   {playing?, server, user}  電視現在在播什麼
///   notice  {message}                 要在手機上跳出來的一句話
///   error   {message}                 之後就會斷線
library;

/// 電視上的 WebSocket 與 /remote/info. 固定一個埠, 手機才掃得到
const int kRemotePort = 47811;

/// UDP 廣播找電視用的埠
const int kRemoteDiscoveryPort = 47810;

const int kRemoteProtocol = 1;

/// 手機上的遙控器那幾顆鍵. 名字就是線上傳的字串, 不要改.
enum RemoteKey {
  up,
  down,
  left,
  right,
  ok,
  back,
  home,
  playPause,
  fastForward,
  rewind,
  next,
  previous,
  volumeUp,
  volumeDown,
  mute;

  static RemoteKey? parse(Object? name) {
    for (final key in values) {
      if (key.name == name) return key;
    }
    return null;
  }
}

/// 電視上正在播的那一集, 給手機畫進度條
class NowPlaying {
  const NowPlaying({
    required this.sn,
    required this.title,
    required this.episode,
    required this.position,
    required this.duration,
    required this.playing,
  });

  final String sn;
  final String title;
  final String episode;
  final double position;
  final double duration;
  final bool playing;

  factory NowPlaying.fromJson(Map<String, dynamic> json) => NowPlaying(
        sn: '${json['sn'] ?? ''}',
        title: '${json['title'] ?? ''}',
        episode: '${json['episode'] ?? ''}',
        position: _number(json['position']),
        duration: _number(json['duration']),
        playing: json['playing'] == true,
      );

  Map<String, dynamic> toJson() => {
        'sn': sn,
        'title': title,
        'episode': episode,
        'position': position,
        'duration': duration,
        'playing': playing,
      };
}

/// 手機記得的一台電視
class TvDevice {
  const TvDevice({
    required this.id,
    required this.name,
    required this.host,
    this.port = kRemotePort,
    this.token = '',
  });

  /// 電視自己的隨機 id. 手動輸入位址、還沒連上之前是空的
  final String id;
  final String name;
  final String host;
  final int port;

  /// 配對時電視給的. 空的就要重新配對
  final String token;

  String get address => port == kRemotePort ? host : '$host:$port';

  /// 同一台: 有 id 比 id, 沒有就比位址
  bool same(TvDevice other) => id.isNotEmpty && other.id.isNotEmpty
      ? id == other.id
      : host == other.host && port == other.port;

  TvDevice copyWith(
          {String? id, String? name, String? host, int? port, String? token}) =>
      TvDevice(
        id: id ?? this.id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        token: token ?? this.token,
      );

  factory TvDevice.fromJson(Map<String, dynamic> json) => TvDevice(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        host: '${json['host'] ?? ''}',
        port: _number(json['port']).toInt() > 0
            ? _number(json['port']).toInt()
            : kRemotePort,
        token: '${json['token'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'token': token,
      };

  /// 手動輸入的「192.168.1.20」或「192.168.1.20:47811」
  static TvDevice? parseAddress(String raw) {
    var text = raw.trim();
    text = text.replaceFirst(RegExp(r'^[a-z]+://'), '');
    text = text.split('/').first;
    if (text.isEmpty) return null;
    var port = kRemotePort;
    final colon = text.lastIndexOf(':');
    if (colon > 0) {
      final parsed = int.tryParse(text.substring(colon + 1));
      if (parsed == null || parsed <= 0 || parsed > 65535) return null;
      port = parsed;
      text = text.substring(0, colon);
    }
    if (!RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(text)) return null;
    return TvDevice(id: '', name: text, host: text, port: port);
  }
}

/// 電視記得的一支配對過的手機
class PairedPhone {
  const PairedPhone({
    required this.id,
    required this.name,
    required this.token,
    required this.added,
  });

  final String id;
  final String name;
  final String token;

  /// 毫秒
  final int added;

  factory PairedPhone.fromJson(Map<String, dynamic> json) => PairedPhone(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        token: '${json['token'] ?? ''}',
        added: _number(json['added']).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'token': token,
        'added': added,
      };
}

double _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}
