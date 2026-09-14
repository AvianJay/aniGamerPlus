/// tearDown 用的暫存目錄清理.
///
/// Windows 不讓人刪掉還有 handle 開著的檔案 (errno 32), 而 app 裡有好幾筆
/// 「排程之後才落盤」的寫入是刻意不 await 的 (進度合併、下載索引…). Linux 上
/// 就算 handle 還開著也刪得掉, 所以 CI 從來看不到這件事, 在 Windows 上跑同一
/// 批測試卻會在 tearDown 掛掉 —— 掛的還是上一個測試的名字.
///
/// 清不掉不該讓一個本來會過的測試變紅: 退讓幾次, 真的不行就交給系統自己的
/// 暫存清理.
library;

import 'dart:io';

Future<void> deleteTempDir(Directory dir) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (!dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
