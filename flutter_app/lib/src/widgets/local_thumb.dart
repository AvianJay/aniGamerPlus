/// 片庫縮圖的前端: 磁碟上有就直接畫, 沒有就去 ThumbnailStore 問.
///
/// 之前這裡是拿自家伺服器的 /thumbnail.jpg 當 CachedNetworkImage 的 url ——
/// 那條代理一出問題整面卡片就只剩漸層. 現在圖片是手機自己跟巴哈要、存在
/// 手機上的, 離線也畫得出來.
///
/// 行為:
///   - build 裡只讀同步快照 (offlineFile / cachedFile), 從不直接啟動網路;
///   - 缺圖時在 initState / sn 改變時打一次 `store.load`, 回來才 setState;
///   - 失敗就 quiet, 本來墊在底下的漸層繼續留著;
///   - 不在 dispose 之後 setState, 也不在 rebuild 裡重打 (同一個 sn 同時
///     很多張卡片在問時, store 那層已經合併成一次請求).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../state/thumbnail_store.dart';
import '../theme.dart';
import 'common.dart';

class LocalThumb extends StatefulWidget {
  const LocalThumb({
    super.key,
    required this.store,
    required this.sn,
    required this.name,
    this.offlineFile,
    this.aspectRatio = 16 / 9,
    this.radius = kRadiusSmall,
    this.fit = BoxFit.cover,
    this.art = true,
  });

  final ThumbnailStore store;
  final String sn;
  final String name;

  /// 已經下載到手機的那一集附的封面 (DownloadStore.localThumb).
  /// 有它就不用等縮圖快取.
  final File? offlineFile;

  /// 下面直接轉交給 CoverImage, 參數語意跟那邊一致.
  final double? aspectRatio;
  final double radius;
  final BoxFit fit;
  final bool art;

  @override
  State<LocalThumb> createState() => _LocalThumbState();
}

class _LocalThumbState extends State<LocalThumb> {
  File? _file;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    _file = widget.offlineFile ?? widget.store.cachedFile(widget.sn);
    if (_file == null) unawaited(_fetch());
  }

  @override
  void didUpdateWidget(covariant LocalThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sn != widget.sn ||
        oldWidget.store != widget.store ||
        oldWidget.offlineFile?.path != widget.offlineFile?.path) {
      _file = widget.offlineFile ?? widget.store.cachedFile(widget.sn);
      if (_file == null) unawaited(_fetch());
    }
  }

  Future<void> _fetch() async {
    if (_waiting) return;
    _waiting = true;
    try {
      final file = await widget.store.load(widget.sn);
      // 回來時這張卡片可能已經滑掉 / 換成別集了
      if (!mounted || file == null) return;
      setState(() => _file = file);
    } finally {
      _waiting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CoverImage(
      name: widget.name,
      file: _file,
      aspectRatio: widget.aspectRatio,
      radius: widget.radius,
      fit: widget.fit,
      art: widget.art,
    );
  }
}
