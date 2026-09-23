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
#   ORG        套件名前綴, 預設 tw.avianjay (→ tw.avianjay.agpp)
#   APP_LABEL  桌面上顯示的名字, 預設 aniGamerPlus
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORG="${ORG:-tw.avianjay}"
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
  --project-name agpp \
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
TOOLS = 'http://schemas.android.com/tools'
LABEL = os.environ.get('APP_LABEL', 'aniGamerPlus')


def attr(name):
    return '{%s}%s' % (ANDROID, name)


def patch_manifest(path):
    ET.register_namespace('android', ANDROID)
    ET.register_namespace('tools', TOOLS)
    tree = ET.parse(path)
    manifest = tree.getroot()

    # 1. 網路權限. 新版樣板只在 debug/profile 的 manifest 裡放 INTERNET,
    #    release 版沒有 —— 這個 App 沒網路等於沒功能.
    permissions = {
        node.get(attr('name'))
        for node in manifest.findall('uses-permission')
    }
    # REQUEST_INSTALL_PACKAGES: App 內更新下載完 APK 要交給系統安裝器
    for needed in ('android.permission.INTERNET',
                   'android.permission.ACCESS_NETWORK_STATE',
                   'android.permission.REQUEST_INSTALL_PACKAGES'):
        if needed not in permissions:
            node = ET.Element('uses-permission')
            node.set(attr('name'), needed)
            manifest.insert(0, node)

    # open_filex 自帶讀相簿 / 影片 / 音樂的權限, 但更新用的 APK 放在 App 自己的
    # 快取目錄, 一個都用不到 —— 合併時拿掉, 免得安裝時多問一堆.
    for unwanted in ('android.permission.READ_EXTERNAL_STORAGE',
                     'android.permission.READ_MEDIA_IMAGES',
                     'android.permission.READ_MEDIA_VIDEO',
                     'android.permission.READ_MEDIA_AUDIO'):
        if unwanted in permissions:
            continue
        node = ET.Element('uses-permission')
        node.set(attr('name'), unwanted)
        node.set('{%s}node' % TOOLS, 'remove')
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


def patch_android_signing(path):
    with open(path, encoding='utf-8') as handle:
        source = handle.read()

    android_marker = '\nandroid {\n'
    if source.count(android_marker) != 1:
        raise RuntimeError(f'unexpected Android Gradle template in {path}')

    environment = '''
val releaseKeystorePath = System.getenv("KEYSTORE_PATH")
val releaseKeystoreAlias = System.getenv("KEYSTORE_ALIAS")
val releaseKeystorePassword = System.getenv("KEYSTORE_PASSWORD")
'''
    signing_config = '''
    signingConfigs {
        if (listOf(
                releaseKeystorePath,
                releaseKeystoreAlias,
                releaseKeystorePassword,
            ).all { !it.isNullOrBlank() }) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeystoreAlias
                keyPassword = releaseKeystorePassword
            }
        }
    }
'''

    source = source.replace(android_marker, environment + android_marker, 1)
    source = source.replace(android_marker, android_marker + signing_config, 1)

    debug_signing = 'signingConfig = signingConfigs.getByName("debug")'
    release_signing = '''signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")'''
    if source.count(debug_signing) != 1:
        raise RuntimeError(f'unexpected release signing block in {path}')
    source = source.replace(debug_signing, release_signing, 1)

    with open(path, 'w', encoding='utf-8', newline='') as handle:
        handle.write(source)
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
    # 後三個是側載商店 (TrollStore 借用放大鏡的 apple-magnifier),
    # App 內更新要先 canLaunchUrl 問過裝了哪一個
    schemes.update(('http', 'https', 'apple-magnifier', 'sidestore', 'altstore'))
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
patch_android_signing(os.path.join('android', 'app', 'build.gradle.kts'))
patch_plist(os.path.join('ios', 'Runner', 'Info.plist'))
PYTHON

echo "==> flutter pub get"
flutter pub get

echo
echo "好了. 接著可以:"
echo "  flutter run                 # 接一台手機或模擬器"
echo "  flutter build apk --release"
echo "  flutter build ios --release --no-codesign"
