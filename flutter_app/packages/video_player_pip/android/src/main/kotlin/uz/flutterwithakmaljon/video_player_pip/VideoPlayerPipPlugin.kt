package uz.flutterwithakmaljon.video_player_pip

import android.annotation.TargetApi
import android.app.Activity
import android.app.Application
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/**
 * 系統子母畫面 (整個 Activity 縮進一個小視窗).
 *
 * 播放器那一頁用 updatePip 把設定送下來: 離開 App 時要不要自動進去、影片比例、
 * 播放器在視窗裡的位置 (進出動畫用)、視窗裡畫播放鍵還是暫停鍵. 自動進入在
 * Android 12 起交給 setAutoEnterEnabled, 更早的版本在 onUserLeaveHint 自己進.
 */
class VideoPlayerPipPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
  private val TAG = "VideoPlayerPipPlugin"

  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var componentCallback: ComponentCallbacks? = null
  private var lifecycleCallback: Application.ActivityLifecycleCallbacks? = null
  private var actionReceiver: BroadcastReceiver? = null
  private var isInPipMode = false

  // 播放頁最後一次送下來的設定
  private var autoEnter = false
  private var playing = false
  private var aspectRatio: Rational? = null
  private var sourceRect: Rect? = null

  private val userLeaveHint = PluginRegistry.UserLeaveHintListener { onUserLeaveHint() }

  private val actionName: String
    get() = "${context.packageName}.VIDEO_PLAYER_PIP_ACTION"

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "video_player_pip")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
    registerActionReceiver()
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "isPipSupported" -> result.success(isPipSupported())
      "enterPipMode" -> {
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        if (aspectRatio == null && width != null && height != null) {
          aspectRatio = clampRatio(width, height)
        }
        result.success(enterPipMode())
      }
      "exitPipMode" -> result.success(exitPipMode())
      "isInPipMode" -> result.success(currentPipMode())
      "updatePip" -> {
        autoEnter = call.argument<Boolean>("autoEnter") == true &&
          call.argument<Int>("playerId") != null
        playing = call.argument<Boolean>("playing") == true
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        if (width != null && height != null) aspectRatio = clampRatio(width, height)
        sourceRect = call.argument<List<Int>>("rect")
          ?.takeIf { it.size == 4 && it[2] > it[0] && it[3] > it[1] }
          ?.let { Rect(it[0], it[1], it[2], it[3]) }
        result.success(applyParams())
      }
      else -> result.notImplemented()
    }
  }

  private fun isPipSupported(): Boolean {
    return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
      context.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
  }

  /** 系統只接受 1:2.39 到 2.39:1 之間的比例, 超出去整個 PiP 都會失敗 */
  private fun clampRatio(width: Int, height: Int): Rational? {
    if (width <= 0 || height <= 0) return null
    val ratio = width.toDouble() / height
    return when {
      ratio > 2.39 -> Rational(239, 100)
      ratio < 1 / 2.39 -> Rational(100, 239)
      else -> Rational(width, height)
    }
  }

  private fun buildParams(): PictureInPictureParams? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
    val builder = PictureInPictureParams.Builder()
      .setAspectRatio(aspectRatio ?: Rational(16, 9))
      .setActions(buildActions())
    sourceRect?.let { builder.setSourceRectHint(it) }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setAutoEnterEnabled(autoEnter)
      builder.setSeamlessResizeEnabled(true)
    }
    return builder.build()
  }

  /** 子母畫面視窗裡的按鈕: 倒退、播放 / 暫停、快轉 */
  private fun buildActions(): List<RemoteAction> {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()
    val toggle = if (playing) {
      action("pause", android.R.drawable.ic_media_pause, "暫停", 1)
    } else {
      action("play", android.R.drawable.ic_media_play, "播放", 1)
    }
    val max = activity?.maxNumPictureInPictureActions ?: 3
    if (max < 3) return if (max >= 1) listOf(toggle) else emptyList()
    return listOf(
      action("rewind", android.R.drawable.ic_media_rew, "倒退 10 秒", 0),
      toggle,
      action("forward", android.R.drawable.ic_media_ff, "快轉 10 秒", 2),
    )
  }

  @TargetApi(Build.VERSION_CODES.O)
  private fun action(name: String, icon: Int, title: String, requestCode: Int): RemoteAction {
    val intent = Intent(actionName)
      .setPackage(context.packageName)
      .putExtra("action", name)
    val pending = PendingIntent.getBroadcast(
      context, requestCode, intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    return RemoteAction(Icon.createWithResource(context, icon), title, title, pending)
  }

  /** 把設定交給系統. 不在子母畫面裡也要先交: Android 12 起的自動進入就是看它 */
  private fun applyParams(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    val activity = activity ?: return false
    if (!isPipSupported()) return false
    val params = buildParams() ?: return false
    return try {
      activity.setPictureInPictureParams(params)
      true
    } catch (e: Exception) {
      // 例如 manifest 沒開 supportsPictureInPicture, 或比例不被接受
      Log.w(TAG, "setPictureInPictureParams failed", e)
      false
    }
  }

  private fun enterPipMode(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    val activity = activity ?: return false
    if (!isPipSupported()) return false
    val params = buildParams() ?: return false
    return try {
      activity.enterPictureInPictureMode(params)
    } catch (e: Exception) {
      Log.w(TAG, "enterPictureInPictureMode failed", e)
      false
    }
  }

  /** Android 12 以前沒有自動進入, 使用者按 Home / 最近使用時自己進 */
  private fun onUserLeaveHint() {
    if (!autoEnter || currentPipMode()) return
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
    enterPipMode()
  }

  private fun exitPipMode(): Boolean {
    val activity = activity ?: return false
    if (!currentPipMode()) return false
    return try {
      // 把 Activity 叫回前景, 系統就會把子母畫面放大回全螢幕
      val intent = activity.packageManager.getLaunchIntentForPackage(activity.packageName)
        ?.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
      if (intent != null) activity.startActivity(intent)
      true
    } catch (e: Exception) {
      Log.w(TAG, "exit PiP failed", e)
      false
    }
  }

  private fun currentPipMode(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
    return activity?.isInPictureInPictureMode ?: isInPipMode
  }

  /** 每一個可能改變子母畫面狀態的時間點都來這裡對一次, 變了才通知 */
  private fun updatePipState() {
    val now = currentPipMode()
    if (now == isInPipMode) return
    isInPipMode = now
    try {
      channel.invokeMethod("pipModeChanged", mapOf("isInPipMode" to now))
    } catch (e: Exception) {
      Log.w(TAG, "notify PiP mode failed", e)
    }
  }

  private fun registerActionReceiver() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) {
        val name = intent.getStringExtra("action") ?: return
        channel.invokeMethod("pipAction", mapOf("action" to name))
      }
    }
    val filter = IntentFilter(actionName)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      // PendingIntent 是用這支 App 的身分送的, 不必對外開放
      context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      context.registerReceiver(receiver, filter)
    }
    actionReceiver = receiver
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    actionReceiver?.let {
      try {
        context.unregisterReceiver(it)
      } catch (_: Exception) {
      }
    }
    actionReceiver = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    attach(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    detach()
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    attach(binding)
  }

  override fun onDetachedFromActivity() {
    // 播放頁已經不在了, 別讓下一次回到桌面又自動縮進子母畫面
    autoEnter = false
    applyParams()
    detach()
    isInPipMode = false
  }

  private fun attach(binding: ActivityPluginBinding) {
    activity = binding.activity
    activityBinding = binding
    binding.addOnUserLeaveHintListener(userLeaveHint)

    // 子母畫面進出會改變 Activity 的大小 (configChanges 裡有 screenSize)
    val callback = object : ComponentCallbacks {
      override fun onConfigurationChanged(newConfig: Configuration) = updatePipState()

      @Deprecated("Deprecated in Java")
      override fun onLowMemory() {
      }
    }
    binding.activity.registerComponentCallbacks(callback)
    componentCallback = callback

    // 上面那一條在某些版本收不到 Activity 自己的設定變更. 進子母畫面一定經過
    // onPause, 放大回來經過 onResume, 被關掉經過 onStop —— 在這三個點各對一次.
    val lifecycle = object : Application.ActivityLifecycleCallbacks {
      override fun onActivityPaused(a: Activity) {
        if (a === activity) updatePipState()
      }

      override fun onActivityResumed(a: Activity) {
        if (a === activity) updatePipState()
      }

      override fun onActivityStopped(a: Activity) {
        if (a === activity) updatePipState()
      }

      override fun onActivityCreated(a: Activity, savedInstanceState: Bundle?) {}
      override fun onActivityStarted(a: Activity) {}
      override fun onActivitySaveInstanceState(a: Activity, outState: Bundle) {}
      override fun onActivityDestroyed(a: Activity) {}
    }
    binding.activity.application.registerActivityLifecycleCallbacks(lifecycle)
    lifecycleCallback = lifecycle
  }

  private fun detach() {
    val current = activity
    componentCallback?.let { current?.unregisterComponentCallbacks(it) }
    componentCallback = null
    lifecycleCallback?.let { current?.application?.unregisterActivityLifecycleCallbacks(it) }
    lifecycleCallback = null
    activityBinding?.removeOnUserLeaveHintListener(userLeaveHint)
    activityBinding = null
    activity = null
  }
}
