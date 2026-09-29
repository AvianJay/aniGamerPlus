package tw.avianjay.background_download;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/** Dart 端下載進行中 -> 起 / 更新 / 收掉 {@link DownloadService}. */
public class BackgroundDownloadPlugin implements FlutterPlugin, ActivityAware, MethodCallHandler {
    private static final int REQUEST_NOTIFICATIONS = 47311;

    private MethodChannel channel;
    private Context context;
    private Activity activity;
    private boolean askedNotifications = false;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "background_download");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
        context = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        switch (call.method) {
            case "update": {
                requestNotificationPermissionOnce();
                Intent intent = new Intent(context, DownloadService.class);
                intent.putExtra("title", (String) call.argument("title"));
                intent.putExtra("text", (String) call.argument("text"));
                intent.putExtra("shortText", (String) call.argument("shortText"));
                Integer progress = call.argument("progress");
                intent.putExtra("progress", progress == null ? -1 : progress);
                Integer segments = call.argument("segments");
                intent.putExtra("segments", segments == null ? 1 : segments);
                if (DownloadService.updateIfRunning(intent)) {
                    result.success(null);
                    break;
                }
                try {
                    if (Build.VERSION.SDK_INT >= 26) {
                        context.startForegroundService(intent);
                    } else {
                        context.startService(intent);
                    }
                    result.success(null);
                } catch (RuntimeException e) {
                    // Android 12+: App 在背景時不能新起前景服務
                    result.error("start_failed", e.getMessage(), null);
                }
                break;
            }
            case "stop": {
                DownloadService.forget();
                context.stopService(new Intent(context, DownloadService.class));
                String doneTitle = call.argument("doneTitle");
                if (doneTitle != null) {
                    DownloadService.notifyDone(context, doneTitle, call.argument("doneText"));
                }
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    /** Android 13+ 通知要使用者同意; 不同意前景服務照跑, 只是通知不會出現. 只問一次. */
    private void requestNotificationPermissionOnce() {
        if (askedNotifications || Build.VERSION.SDK_INT < 33 || activity == null) return;
        askedNotifications = true;
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(
                    new String[] {Manifest.permission.POST_NOTIFICATIONS}, REQUEST_NOTIFICATIONS);
        }
    }
}
