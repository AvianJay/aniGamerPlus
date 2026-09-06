#!/usr/bin/env bash
#
# 產生 android/ 與 ios/ 平台外殼, 然後打上這個 App 需要的幾個補丁.
#
# 平台目錄不進版控 (見 .gitignore): 那些是 `flutter create` 的樣板, 每次跟著
# Flutter 版本走比較不會過期, 留在 repo 裡只會變成沒人維護的死碼.
# CI 每次建置前都會跑這支, 本機第一次要跑 flutter run 之前也跑一次:
#
#     bash tool/prepare_platforms.sh
#
# 可用環境變數:
#   ORG        套件名前綴, 預設 tw.com.anigamerplus (→ tw.com.anigamerplus.agp_mobile)
#   APP_LABEL  桌面上顯示的名字, 預設 aniGamerPlus
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORG="${ORG:-tw.com.anigamerplus}"
APP_LABEL="${APP_LABEL:-aniGamerPlus}"

cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "找不到 flutter, 先裝好 Flutter SDK 再跑這支." >&2
  exit 1
fi

PYTHON="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON" ]; then
  echo "找不到 python3, 補丁那一段需要它." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 直接在專案目錄跑 flutter create 會蓋掉 lib/main.dart, 所以先生在別的地方再搬過來
echo "==> 產生平台樣板 (org=$ORG)"
flutter create \
  --platforms=android,ios \
  --org "$ORG" \
  --project-name agp_mobile \
  --overwrite \
  "$TMP/scaffold" >/dev/null

rm -rf android ios
cp -R "$TMP/scaffold/android" android
cp -R "$TMP/scaffold/ios" ios

echo "==> 打補丁"
APP_LABEL="$APP_LABEL" "$PYTHON" - <<'PYTHON'
import os
import plistlib
import xml.etree.ElementTree as ET

ANDROID = 'http://schemas.android.com/apk/res/android'
LABEL = os.environ.get('APP_LABEL', 'aniGamerPlus')


def attr(name):
    return '{%s}%s' % (ANDROID, name)


def patch_manifest(path):
    ET.register_namespace('android', ANDROID)
    tree = ET.parse(path)
    manifest = tree.getroot()

    # 1. 網路權限. 新版樣板只在 debug/profile 的 manifest 裡放 INTERNET,
    #    release 版沒有 —— 這個 App 沒網路等於沒功能.
    permissions = {
        node.get(attr('name'))
        for node in manifest.findall('uses-permission')
    }
    for needed in ('android.permission.INTERNET',
                   'android.permission.ACCESS_NETWORK_STATE'):
        if needed not in permissions:
            node = ET.Element('uses-permission')
            node.set(attr('name'), needed)
            manifest.insert(0, node)

    application = manifest.find('application')
    if application is not None:
        application.set(attr('label'), LABEL)
        # 2. 自架的伺服器多半是區網 http://192.168.x.x:5000, 沒有憑證可言
        application.set(attr('usesCleartextTraffic'), 'true')

    # 3. url_launcher 在 API 30 以上要先宣告想問哪些 scheme,
    #    不然「在動畫瘋開啟」會靜靜地什麼都不做.
    queries = manifest.find('queries')
    if queries is None:
        queries = ET.SubElement(manifest, 'queries')
    declared = set()
    for intent in queries.findall('intent'):
        data = intent.find('data')
        if data is not None:
            declared.add(data.get(attr('scheme')))
    for scheme in ('http', 'https'):
        if scheme in declared:
            continue
        intent = ET.SubElement(queries, 'intent')
        action = ET.SubElement(intent, 'action')
        action.set(attr('name'), 'android.intent.action.VIEW')
        data = ET.SubElement(intent, 'data')
        data.set(attr('scheme'), scheme)

    if hasattr(ET, 'indent'):  # Python 3.9+
        ET.indent(tree, space='    ')
    tree.write(path, encoding='utf-8', xml_declaration=True)
    print('  patched', path)


def patch_plist(path):
    with open(path, 'rb') as handle:
        info = plistlib.load(handle)

    info['CFBundleDisplayName'] = LABEL
    # 同樣是為了區網 http, NSAllowsLocalNetworking 單獨不夠,
    # 使用者也可能把伺服器放在自己的網域上而沒有憑證.
    info['NSAppTransportSecurity'] = {
        'NSAllowsArbitraryLoads': True,
        'NSAllowsLocalNetworking': True,
    }
    # iOS 14 起連區網位址要先問過使用者
    info['NSLocalNetworkUsageDescription'] = '用來連線到你自己架設的 aniGamerPlus 伺服器。'
    # 鎖屏 / 切到背景時聲音不要斷
    modes = set(info.get('UIBackgroundModes') or [])
    modes.add('audio')
    info['UIBackgroundModes'] = sorted(modes)
    schemes = set(info.get('LSApplicationQueriesSchemes') or [])
    schemes.update(('http', 'https'))
    info['LSApplicationQueriesSchemes'] = sorted(schemes)
    # 播放器自己會鎖橫向, 全部方向都要開著
    info['UISupportedInterfaceOrientations'] = [
        'UIInterfaceOrientationPortrait',
        'UIInterfaceOrientationLandscapeLeft',
        'UIInterfaceOrientationLandscapeRight',
    ]

    with open(path, 'wb') as handle:
        plistlib.dump(info, handle)
    print('  patched', path)


patch_manifest(os.path.join('android', 'app', 'src', 'main', 'AndroidManifest.xml'))
patch_plist(os.path.join('ios', 'Runner', 'Info.plist'))
PYTHON

echo "==> flutter pub get"
flutter pub get

echo
echo "好了. 接著可以:"
echo "  flutter run                 # 接一台手機或模擬器"
echo "  flutter build apk --release"
echo "  flutter build ios --release --no-codesign"
