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
    # CHANGE_WIFI_MULTICAST_STATE: 電視等手機用 UDP 廣播來找它的時候, Wi-Fi 在
    #   省電模式下會把廣播封包濾掉, 要拿一把 MulticastLock (一般權限, 不必問)
    for needed in ('android.permission.INTERNET',
                   'android.permission.ACCESS_NETWORK_STATE',
                   'android.permission.REQUEST_INSTALL_PACKAGES',
                   'android.permission.CHANGE_WIFI_MULTICAST_STATE'):
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

    # video_player_pip uses the Activity's system PiP window on Android.
    activity = application.find('activity') if application is not None else None
    if activity is not None:
        activity.set(attr('supportsPictureInPicture'), 'true')

    # 4. Android TV. 電視的桌面只列出有 LEANBACK_LAUNCHER 的 App, 而且要一張
    #    橫幅 (android:banner, 圖在 android_extensions/). 觸控跟 leanback 都標成
    #    「不一定要有」, 同一個 APK 手機跟電視都裝得上.
    features = {
        node.get(attr('name'))
        for node in manifest.findall('uses-feature')
    }
    for feature in ('android.software.leanback',
                    'android.hardware.touchscreen'):
        if feature in features:
            continue
        node = ET.Element('uses-feature')
        node.set(attr('name'), feature)
        node.set(attr('required'), 'false')
        manifest.insert(0, node)
    if application is not None:
        application.set(attr('banner'), '@drawable/tv_banner')
    if activity is not None:
        for intent in activity.findall('intent-filter'):
            actions = {a.get(attr('name')) for a in intent.findall('action')}
            if 'android.intent.action.MAIN' not in actions:
                continue
            categories = {
                c.get(attr('name')) for c in intent.findall('category')
            }
            if 'android.intent.category.LEANBACK_LAUNCHER' not in categories:
                node = ET.SubElement(intent, 'category')
                node.set(attr('name'),
                         'android.intent.category.LEANBACK_LAUNCHER')

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


def add_android_resources(res_dir):
    # 樣板裡沒有的圖 (電視桌面的橫幅) 放在 android_extensions/res/, 照原樣疊上去
    import shutil
    shutil.copytree(os.path.join('android_extensions', 'res'), res_dir,
                    dirs_exist_ok=True)
    print('  copied android_extensions/res ->', res_dir)


def patch_main_activity(kotlin_dir):
    # 電視跟手機的版面不一樣, 而且得在 runApp 之前就知道 (直向鎖定要跳過),
    # 見 lib/src/util/device.dart. 另外兩件手機遙控用的小事: 裝置名稱 (配對時
    # 顯示「誰」), 以及電視等手機廣播時要拿的 MulticastLock. 都是幾行就好,
    # 不值得為它們另寫一個外掛.
    import glob
    paths = glob.glob(os.path.join(kotlin_dir, '**', 'MainActivity.kt'),
                      recursive=True)
    if len(paths) != 1:
        raise RuntimeError(f'expected one MainActivity.kt under {kotlin_dir}')
    path = paths[0]
    with open(path, encoding='utf-8') as handle:
        source = handle.read()

    imports = 'import io.flutter.embedding.android.FlutterActivity\n'
    declaration = 'class MainActivity : FlutterActivity()'
    if source.count(imports) != 1 or source.count(declaration) != 1:
        raise RuntimeError(f'unexpected MainActivity template in {path}')
    source = source.replace(imports, '''import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
''', 1)
    source = source.replace(declaration, '''class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agp/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision())
                    "deviceName" -> result.success(deviceName())
                    "multicastLock" -> {
                        holdMulticastLock(call.arguments == true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        holdMulticastLock(false)
        super.onDestroy()
    }

    private fun isTelevision(): Boolean {
        val uiMode = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    // 系統設定裡的「裝置名稱」(電視多半是「客廳電視」這種), 沒設就用型號
    private fun deviceName(): String {
        val named = try {
            Settings.Global.getString(contentResolver, "device_name")
        } catch (error: Exception) {
            null
        }
        return if (named.isNullOrBlank()) Build.MODEL else named
    }

    private fun holdMulticastLock(hold: Boolean) {
        if (hold) {
            if (multicastLock?.isHeld == true) return
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return
            multicastLock = wifi.createMulticastLock("agp-remote").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else {
            multicastLock?.let { if (it.isHeld) it.release() }
            multicastLock = null
        }
    }
}''', 1)

    with open(path, 'w', encoding='utf-8', newline='') as handle:
        handle.write(source)
    print('  patched', path)


def add_cast_support(manifest_path, kotlin_dir, gradle_path):
    # 投放到 Chromecast (flutter_chrome_cast, 底下是 Google Cast SDK).
    #
    # Cast SDK 一起來就去 manifest 找 OptionsProvider. 外掛自帶的那一支要等 Dart
    # 那邊把設定傳下來才有值 (lateinit), 而 SDK 自己的 ReconnectionService 可能在
    # App 被系統收掉之後單獨重啟, 那時候 Dart 根本還沒跑 —— 所以用 App 自己的,
    # 設定寫死: Google 的預設媒體接收器, 不必另外註冊接收器.
    import glob
    paths = glob.glob(os.path.join(kotlin_dir, '**', 'MainActivity.kt'),
                      recursive=True)
    if len(paths) != 1:
        raise RuntimeError(f'expected one MainActivity.kt under {kotlin_dir}')
    with open(paths[0], encoding='utf-8') as handle:
        package = next((line.split()[1] for line in handle
                        if line.startswith('package ')), None)
    if not package:
        raise RuntimeError(f'cannot find the package of {paths[0]}')
    provider = os.path.join(os.path.dirname(paths[0]), 'CastOptionsProvider.kt')
    with open(provider, 'w', encoding='utf-8', newline='') as handle:
        handle.write(f'''package {package}

import android.content.Context
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions
import com.google.android.gms.cast.framework.media.NotificationOptions

// tool/prepare_platforms.sh 產生的, 別直接改
class CastOptionsProvider : OptionsProvider {{
    override fun getCastOptions(context: Context): CastOptions {{
        // 投放中的媒體通知 (鎖定畫面也看得到): 點下去回到 App
        val notification = NotificationOptions.Builder()
            .setTargetActivityClassName(MainActivity::class.java.name)
            .build()
        val media = CastMediaOptions.Builder()
            .setNotificationOptions(notification)
            .build()
        return CastOptions.Builder()
            .setReceiverApplicationId(
                CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
            .setCastMediaOptions(media)
            .setResumeSavedSession(true)
            .setEnableReconnectionService(true)
            .build()
    }}

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}}
''')
    print('  wrote', provider)

    ET.register_namespace('android', ANDROID)
    ET.register_namespace('tools', TOOLS)
    tree = ET.parse(manifest_path)
    manifest = tree.getroot()
    application = manifest.find('application')
    if application is None:
        raise RuntimeError(f'no <application> in {manifest_path}')
    # 投放中的媒體通知是一個前景服務. Android 14 起前景服務要宣告類型,
    # 框架自己的 manifest 沒寫, 得由 App 補上 (FOREGROUND_SERVICE 本身框架有帶)
    permission = 'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'
    if permission not in {node.get(attr('name'))
                          for node in manifest.findall('uses-permission')}:
        node = ET.Element('uses-permission')
        node.set(attr('name'), permission)
        manifest.insert(0, node)
    meta = ET.SubElement(application, 'meta-data')
    meta.set(attr('name'),
             'com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME')
    meta.set(attr('value'), package + '.CastOptionsProvider')
    service = ET.SubElement(application, 'service')
    service.set(attr('name'),
                'com.google.android.gms.cast.framework.media.MediaNotificationService')
    service.set(attr('exported'), 'false')
    service.set(attr('foregroundServiceType'), 'mediaPlayback')
    if hasattr(ET, 'indent'):
        ET.indent(tree, space='    ')
    tree.write(manifest_path, encoding='utf-8', xml_declaration=True)
    print('  patched', manifest_path, '(cast)')

    # CastOptionsProvider 在 App 這個模組裡, 編譯時要看得到 Cast SDK. 外掛是用
    # implementation 拉進來的, 不會傳給 App; 版本跟外掛的一樣, Gradle 取同一份.
    with open(gradle_path, encoding='utf-8') as handle:
        source = handle.read()
    marker = '\nflutter {\n'
    if source.count(marker) != 1:
        raise RuntimeError(f'unexpected flutter block in {gradle_path}')
    source = source.replace(marker, '''
dependencies {
    implementation("com.google.android.gms:play-services-cast-framework:21.5.0")
}
''' + marker, 1)
    with open(gradle_path, 'w', encoding='utf-8', newline='') as handle:
        handle.write(source)
    print('  patched', gradle_path, '(cast)')


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
    # 找同一個網路上的電視 (手機遙控) 也是區網存取: 逐台敲門, 不用 Bonjour
    info['NSLocalNetworkUsageDescription'] = '用來連線到你自己架設的 aniGamerPlus 伺服器，以及找到同一個網路上的電視與 Chromecast。'
    # Chromecast 是用 Bonjour 找的, 要找的服務得先列在這裡, 不然 iOS 直接擋掉.
    # CC1AD845 是 Google 的預設媒體接收器
    services = set(info.get('NSBonjourServices') or [])
    services.update(('_googlecast._tcp', '_CC1AD845._googlecast._tcp'))
    info['NSBonjourServices'] = sorted(services)
    # 鎖屏 / 切到背景時聲音不要斷
    modes = set(info.get('UIBackgroundModes') or [])
    modes.add('audio')
    info['UIBackgroundModes'] = sorted(modes)
    schemes = set(info.get('LSApplicationQueriesSchemes') or [])
    # 側載商店 (TrollStore 借用放大鏡的 apple-magnifier),
    # App 內更新要先 canLaunchUrl 問過裝了哪一個
    schemes.update(('http', 'https', 'apple-magnifier', 'sidestore',
                    'altstore', 'loadcontroller'))
    info['LSApplicationQueriesSchemes'] = sorted(schemes)
    # 下載進度的即時動態 (動態島 / 鎖定畫面), 見 add_live_activity_extension
    info['NSSupportsLiveActivities'] = True
    # 播放器自己會鎖橫向, 全部方向都要開著
    info['UISupportedInterfaceOrientations'] = [
        'UIInterfaceOrientationPortrait',
        'UIInterfaceOrientationLandscapeLeft',
        'UIInterfaceOrientationLandscapeRight',
    ]

    with open(path, 'wb') as handle:
        plistlib.dump(info, handle)
    print('  patched', path)


def patch_ios_deployment(podfile_path, project_path):
    # video_player_pip's podspec requires iOS 15. The Flutter scaffold still
    # targets iOS 13, which makes CocoaPods reject the plugin during CI builds.
    # Newer flutter create releases delay creating Podfile until the first iOS
    # build. Seed it from this toolchain's own template before changing it.
    if not os.path.exists(podfile_path):
        import shutil
        flutter_exe = os.path.realpath(shutil.which('flutter') or '')
        flutter_root = os.environ.get('FLUTTER_ROOT') or os.path.dirname(
            os.path.dirname(flutter_exe))
        template = os.path.join(flutter_root, 'packages', 'flutter_tools',
                                'templates', 'cocoapods', 'Podfile-ios')
        shutil.copyfile(template, podfile_path)
    with open(podfile_path, encoding='utf-8') as handle:
        podfile = handle.read()
    podfile = "platform :ios, '15.0'\n" + podfile
    with open(podfile_path, 'w', encoding='utf-8', newline='') as handle:
        handle.write(podfile)
    with open(project_path, encoding='utf-8') as handle:
        project = handle.read()
    import re
    project, count = re.subn(r'IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;',
                             'IPHONEOS_DEPLOYMENT_TARGET = 15.0;', project)
    if count == 0:
        raise RuntimeError(f'unexpected iOS deployment target in {project_path}')
    with open(project_path, 'w', encoding='utf-8', newline='') as handle:
        handle.write(project)
    print('  patched', podfile_path)
    print('  patched', project_path)


def patch_app_delegate(path):
    # 背景下載 (background_download 外掛) 做完時, 系統會把 App 在背景叫醒並呼叫
    # handleEventsForBackgroundURLSession. 那時候不一定有 Flutter engine —— 背景
    # 啟動不會連上 scene, 隱式 engine 也就不會建 —— 外掛根本還沒註冊, 所以這一段
    # 得直接寫在 AppDelegate 裡.
    with open(path, encoding='utf-8') as handle:
        source = handle.read()

    if source.count('import UIKit\n') != 1:
        raise RuntimeError(f'unexpected imports in {path}')
    source = source.replace('import UIKit\n',
                            'import UIKit\nimport background_download\n', 1)

    launch = ('    return super.application(application, '
              'didFinishLaunchingWithOptions: launchOptions)\n')
    if source.count(launch) != 1:
        raise RuntimeError(f'unexpected didFinishLaunching in {path}')
    source = source.replace(
        launch,
        '    // 背景下載的 session 要一啟動就接回來, 上一輪沒送到的事件才收得到\n'
        '    BackgroundDownloadSession.shared.activate()\n' + launch, 1)

    handler = '''
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    if BackgroundDownloadSession.shared.handleEvents(
      identifier: identifier, completionHandler: completionHandler)
    {
      return
    }
    super.application(
      application, handleEventsForBackgroundURLSession: identifier,
      completionHandler: completionHandler)
  }
'''
    end = source.rstrip().rfind('}')
    if end < 0:
        raise RuntimeError(f'unexpected AppDelegate in {path}')
    source = source[:end] + handler + source[end:]

    with open(path, 'w', encoding='utf-8', newline='') as handle:
        handle.write(source)
    print('  patched', path)


def add_live_activity_extension(project_path):
    # 下載進度的即時動態 (動態島 / 鎖定畫面) 得是一個 widget extension, 也就是
    # Runner.xcodeproj 裡的另一個 target. 平台外殼每次都是重新產生的, 所以
    # 這個 target 也每次重新加: 原始碼在 ios_extensions/DownloadActivity/,
    # 資料格式的正本在外掛裡 (App 跟 extension 兩邊得是同一個型別).
    import hashlib
    import re
    import shutil

    name = 'DownloadActivity'
    ios_dir = os.path.dirname(os.path.dirname(project_path))
    target_dir = os.path.join(ios_dir, name)
    if os.path.exists(target_dir):
        shutil.rmtree(target_dir)
    shutil.copytree(os.path.join('ios_extensions', name), target_dir)
    shutil.copyfile(
        os.path.join('packages', 'background_download', 'ios', 'Classes',
                     'DownloadActivityAttributes.swift'),
        os.path.join(target_dir, 'DownloadActivityAttributes.swift'))

    with open(project_path, encoding='utf-8') as handle:
        project = handle.read()
    if f'/* {name}.appex */' in project:
        raise RuntimeError(f'{name} is already in {project_path}')

    def find(pattern, what):
        match = re.search(pattern, project)
        if match is None:
            raise RuntimeError(f'cannot find {what} in {project_path}')
        return match.group(1)

    root = find(r'rootObject = (\w{24})', 'the project object')
    main_group = find(r'mainGroup = (\w{24});', 'the main group')
    products = find(r'productRefGroup = (\w{24})', 'the products group')
    runner = find(r'(\w{24}) /\* Runner \*/ = \{\n\t\t\tisa = PBXNativeTarget;',
                  'the Runner target')
    generated = find(r'(\w{24}) /\* Generated\.xcconfig \*/ = \{isa = PBXFileReference',
                     'Flutter/Generated.xcconfig')
    bundle = next((value for value in re.findall(
        r'PRODUCT_BUNDLE_IDENTIFIER = ([^;\s]+);', project)
        if not value.endswith('.RunnerTests')), None)
    if bundle is None:
        raise RuntimeError(f'cannot find the app bundle id in {project_path}')

    def oid(key):
        # 固定的 ID: 同一份樣板每次產生出來的專案檔都一樣, diff 看得懂
        return hashlib.md5(f'agp-{name}-{key}'.encode()).hexdigest()[:24].upper()

    ids = {key: oid(key) for key in (
        'product', 'widget_ref', 'attrs_ref', 'plist_ref', 'widget_build',
        'attrs_build', 'embed_build', 'group', 'sources', 'frameworks',
        'resources', 'target', 'proxy', 'dependency', 'embed_phase',
        'config_list', 'Debug', 'Release', 'Profile')}
    ids.update(root=root, generated=generated, bundle=bundle, name=name)

    def fill(text):
        return re.sub(r'@(\w+)@', lambda m: ids[m.group(1)], text)

    def add_to_section(section, text):
        nonlocal project
        end = f'/* End {section} section */\n'
        if end in project:
            project = project.replace(end, fill(text) + end, 1)
        else:
            marker = '\t};\n\trootObject = '
            project = project.replace(
                marker,
                f'\n/* Begin {section} section */\n{fill(text)}'
                f'/* End {section} section */\n' + marker, 1)

    def edit_object(object_id, change):
        nonlocal project
        # 物件的定義是縮兩格的那一行; 清單裡、TargetAttributes 裡也會出現同一個 ID
        match = re.search(
            r'(?<=\n)\t\t' + object_id + r' (?:/\* [^\n]*? \*/ )?= \{\n.*?\n\t\t\};\n',
            project, re.S)
        if match is None:
            raise RuntimeError(f'cannot find object {object_id} in {project_path}')
        project = project[:match.start()] + change(match.group(0)) + project[match.end():]

    def add_to_list(block, key, item, after=None):
        match = re.search(r'\b' + re.escape(key) + r' = \((.*?)(\n(\t*)\);)', block, re.S)
        if match is None:
            raise RuntimeError(f'cannot find list {key}')
        items = match.group(1)
        line = '\n' + match.group(3) + '\t' + fill(item) + ','
        if after is None:
            items += line
        else:
            at = items.find(after)
            if at < 0:
                raise RuntimeError(f'cannot find {after} in list {key}')
            eol = items.find('\n', at)
            eol = len(items) if eol < 0 else eol
            items = items[:eol] + line + items[eol:]
        return block[:match.start(1)] + items + block[match.end(1):]

    add_to_section('PBXBuildFile', '''\
\t\t@widget_build@ /* DownloadActivityWidget.swift in Sources */ = {isa = PBXBuildFile; fileRef = @widget_ref@ /* DownloadActivityWidget.swift */; };
\t\t@attrs_build@ /* DownloadActivityAttributes.swift in Sources */ = {isa = PBXBuildFile; fileRef = @attrs_ref@ /* DownloadActivityAttributes.swift */; };
\t\t@embed_build@ /* @name@.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = @product@ /* @name@.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };
''')
    add_to_section('PBXContainerItemProxy', '''\
\t\t@proxy@ /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = @root@ /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = @target@;
\t\t\tremoteInfo = @name@;
\t\t};
''')
    # dstSubfolderSpec 13 = PlugIns
    add_to_section('PBXCopyFilesBuildPhase', '''\
\t\t@embed_phase@ /* Embed Foundation Extensions */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t@embed_build@ /* @name@.appex in Embed Foundation Extensions */,
\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
''')
    add_to_section('PBXFileReference', '''\
\t\t@product@ /* @name@.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = @name@.appex; sourceTree = BUILT_PRODUCTS_DIR; };
\t\t@widget_ref@ /* DownloadActivityWidget.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DownloadActivityWidget.swift; sourceTree = "<group>"; };
\t\t@attrs_ref@ /* DownloadActivityAttributes.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DownloadActivityAttributes.swift; sourceTree = "<group>"; };
\t\t@plist_ref@ /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
''')
    add_to_section('PBXFrameworksBuildPhase', '''\
\t\t@frameworks@ /* Frameworks */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
''')
    add_to_section('PBXGroup', '''\
\t\t@group@ /* @name@ */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t@widget_ref@ /* DownloadActivityWidget.swift */,
\t\t\t\t@attrs_ref@ /* DownloadActivityAttributes.swift */,
\t\t\t\t@plist_ref@ /* Info.plist */,
\t\t\t);
\t\t\tpath = @name@;
\t\t\tsourceTree = "<group>";
\t\t};
''')
    add_to_section('PBXNativeTarget', '''\
\t\t@target@ /* @name@ */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = @config_list@ /* Build configuration list for PBXNativeTarget "@name@" */;
\t\t\tbuildPhases = (
\t\t\t\t@sources@ /* Sources */,
\t\t\t\t@frameworks@ /* Frameworks */,
\t\t\t\t@resources@ /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = @name@;
\t\t\tproductName = @name@;
\t\t\tproductReference = @product@ /* @name@.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t};
''')
    add_to_section('PBXResourcesBuildPhase', '''\
\t\t@resources@ /* Resources */ = {
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
''')
    add_to_section('PBXSourcesBuildPhase', '''\
\t\t@sources@ /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t@widget_build@ /* DownloadActivityWidget.swift in Sources */,
\t\t\t\t@attrs_build@ /* DownloadActivityAttributes.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
''')
    add_to_section('PBXTargetDependency', '''\
\t\t@dependency@ /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = @target@ /* @name@ */;
\t\t\ttargetProxy = @proxy@ /* PBXContainerItemProxy */;
\t\t};
''')

    # 版本號跟著 App 走 (Generated.xcconfig 的 FLUTTER_BUILD_*), 不然上架 / 側載
    # 會抱怨 extension 跟 App 的版本對不上. 即時動態要 iOS 16.1, 內容更新的
    # API (ActivityContent) 要 16.2.
    configs = ''
    for config in ('Debug', 'Release', 'Profile'):
        optimization = ('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n'
                        '\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n'
                        if config == 'Debug' else
                        '\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n'
                        '\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";\n')
        configs += f'''\
\t\t@{config}@ /* {config} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReference = @generated@ /* Generated.xcconfig */;
\t\t\tbuildSettings = {{
\t\t\t\tAPPLICATION_EXTENSION_API_ONLY = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)";
\t\t\t\tINFOPLIST_FILE = @name@/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.2;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = "$(FLUTTER_BUILD_NAME)";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = @bundle@.@name@;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSKIP_INSTALL = YES;
{optimization}\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = {config};
\t\t}};
'''
    add_to_section('XCBuildConfiguration', configs)
    add_to_section('XCConfigurationList', '''\
\t\t@config_list@ /* Build configuration list for PBXNativeTarget "@name@" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t@Debug@ /* Debug */,
\t\t\t\t@Release@ /* Release */,
\t\t\t\t@Profile@ /* Profile */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};
''')

    # 嵌進 App 的那一步要排在 Flutter 的 Thin Binary 之前, 不然 Xcode 會報
    # 「Cycle inside Runner」.
    edit_object(runner, lambda block: add_to_list(
        add_to_list(block, 'buildPhases',
                    '@embed_phase@ /* Embed Foundation Extensions */',
                    after='/* Embed Frameworks */'),
        'dependencies', '@dependency@ /* PBXTargetDependency */'))
    edit_object(main_group, lambda block: add_to_list(
        block, 'children', '@group@ /* @name@ */'))
    edit_object(products, lambda block: add_to_list(
        block, 'children', '@product@ /* @name@.appex */'))

    def patch_project(block):
        block = add_to_list(block, 'targets', '@target@ /* @name@ */')
        attributes = 'TargetAttributes = {\n'
        if block.count(attributes) != 1:
            raise RuntimeError(f'unexpected TargetAttributes in {project_path}')
        return block.replace(
            attributes,
            attributes + fill('\t\t\t\t\t@target@ = {\n'
                              '\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n'
                              '\t\t\t\t\t};\n'), 1)
    edit_object(root, patch_project)

    with open(project_path, 'w', encoding='utf-8', newline='') as handle:
        handle.write(project)
    print('  patched', project_path, f'(+{name} extension)')


patch_manifest(os.path.join('android', 'app', 'src', 'main', 'AndroidManifest.xml'))
add_android_resources(os.path.join('android', 'app', 'src', 'main', 'res'))
patch_main_activity(os.path.join('android', 'app', 'src', 'main', 'kotlin'))
patch_android_signing(os.path.join('android', 'app', 'build.gradle.kts'))
add_cast_support(os.path.join('android', 'app', 'src', 'main', 'AndroidManifest.xml'),
                 os.path.join('android', 'app', 'src', 'main', 'kotlin'),
                 os.path.join('android', 'app', 'build.gradle.kts'))
patch_plist(os.path.join('ios', 'Runner', 'Info.plist'))
patch_ios_deployment(os.path.join('ios', 'Podfile'),
                     os.path.join('ios', 'Runner.xcodeproj', 'project.pbxproj'))
patch_app_delegate(os.path.join('ios', 'Runner', 'AppDelegate.swift'))
# 要在 patch_ios_deployment 之後: 那一支把專案裡每一個部署目標都改成 15.0,
# 這個 extension 得是 16.2
add_live_activity_extension(os.path.join('ios', 'Runner.xcodeproj', 'project.pbxproj'))
PYTHON

echo "==> flutter pub get"
flutter pub get

echo
echo "好了. 接著可以:"
echo "  flutter run                 # 接一台手機或模擬器"
echo "  flutter build apk --release"
echo "  flutter build ios --release --no-codesign"
