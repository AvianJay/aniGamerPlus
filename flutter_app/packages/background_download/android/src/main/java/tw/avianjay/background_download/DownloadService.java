package tw.avianjay.background_download;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.PowerManager;

import java.util.ArrayList;
import java.util.List;

/**
 * 前景服務本身不下載任何東西 —— 下載還是在 Dart 端跑. 它的工作是讓行程被系統
 * 視為「使用者看得到的工作」, 並持有 CPU / Wi-Fi 鎖, 螢幕關掉後網路不會被睡掉.
 *
 * <p>Android 16 起通知改用 {@link Notification.ProgressStyle}, 並要求升級成
 * Live Update: 鎖定畫面跟通知欄置頂, 狀態列多一顆顯示百分比的膠囊. 系統認不認
 * 是系統的事 (使用者可以在設定裡關掉), 不認的話就是一則普通的進度通知.
 */
public class DownloadService extends Service {
    static final String CHANNEL_ID = "downloads";
    static final String DONE_CHANNEL_ID = "download_done";
    static final int NOTIFICATION_ID = 47312;
    static final int DONE_NOTIFICATION_ID = 47313;

    // Notification.EXTRA_REQUEST_PROMOTED_ONGOING, 36.1 的 SDK 才有常數,
    // 但 36 的系統就認這個 key
    private static final String EXTRA_REQUEST_PROMOTED_ONGOING =
            "android.requestPromotedOngoing";
    // 進度條切段: 一集一段, 太多段就糊成一條
    private static final int MAX_SEGMENTS = 10;
    private static final int SEGMENT_LENGTH = 1000;
    private static final int ACCENT = 0xFF00B5D4;

    // 只在主執行緒上讀寫
    private static DownloadService running;

    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;

    /**
     * 服務已經在前景了的話直接換通知內容. 進度一秒更新一次, 每次都走
     * startForegroundService 的話, Android 12 起 App 在背景時那一支會被擋下來.
     */
    static boolean updateIfRunning(Intent intent) {
        DownloadService service = running;
        if (service == null) return false;
        NotificationManager manager =
                (NotificationManager) service.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return false;
        manager.notify(NOTIFICATION_ID, service.build(intent));
        return true;
    }

    /** 要收掉了: stopService 到 onDestroy 之間進來的進度不要再貼回去. */
    static void forget() {
        running = null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        running = this;
        Notification notification = build(intent);
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        acquireLocks();
        // 行程被殺就算了: Dart 端的下載狀態重開後會被重新整理成「已暫停」
        return START_NOT_STICKY;
    }

    /** Android 15+: dataSync 前景服務累計跑滿時限, 系統會通知並要求停下來. */
    @Override
    public void onTimeout(int startId, int fgsType) {
        stopSelf();
    }

    @Override
    public void onDestroy() {
        if (running == this) running = null;
        releaseLocks();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /** 一批下載做完了. 跟進度那一則分開: 那一則會跟著服務一起消失. */
    static void notifyDone(Context context, String title, String text) {
        NotificationManager manager =
                (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return;
        ensureChannels(context, manager);
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(context, DONE_CHANNEL_ID)
                : new Notification.Builder(context);
        builder.setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title)
                .setContentText(text == null ? "" : text)
                .setColor(ACCENT)
                .setAutoCancel(true);
        PendingIntent open = launchIntent(context);
        if (open != null) builder.setContentIntent(open);
        // Android 13+ 沒有通知權限的話 notify 什麼都不會做, 不會丟例外
        manager.notify(DONE_NOTIFICATION_ID, builder.build());
    }

    private Notification build(Intent intent) {
        String title = intent == null ? null : intent.getStringExtra("title");
        String text = intent == null ? null : intent.getStringExtra("text");
        String shortText = intent == null ? null : intent.getStringExtra("shortText");
        int progress = intent == null ? -1 : intent.getIntExtra("progress", -1);
        int segments = intent == null ? 1 : intent.getIntExtra("segments", 1);
        return build(
                title == null ? "aniGamerPlus" : title,
                text == null ? "" : text,
                shortText,
                progress,
                segments);
    }

    private Notification build(
            String title, String text, String shortText, int progress, int segments) {
        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        ensureChannels(this, manager);

        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        builder.setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(text)
                .setColor(ACCENT)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_PROGRESS);

        if (Build.VERSION.SDK_INT >= 36) {
            int count = segments < 1 || segments > MAX_SEGMENTS ? 1 : segments;
            List<Notification.ProgressStyle.Segment> list = new ArrayList<>();
            for (int i = 0; i < count; i++) {
                list.add(new Notification.ProgressStyle.Segment(SEGMENT_LENGTH).setColor(ACCENT));
            }
            Notification.ProgressStyle style = new Notification.ProgressStyle()
                    .setProgressSegments(list);
            if (progress >= 0) {
                // progress 是 0~1000 的整批進度, 整條長度是 count * 1000
                style.setProgress(progress * count * SEGMENT_LENGTH / 1000);
            } else {
                style.setProgressIndeterminate(true);
            }
            builder.setStyle(style);
            if (shortText != null && !shortText.isEmpty()) {
                builder.setShortCriticalText(shortText);
            }
            Bundle extras = new Bundle();
            extras.putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true);
            builder.addExtras(extras);
        } else if (progress >= 0) {
            builder.setProgress(1000, progress, false);
        } else {
            builder.setProgress(0, 0, true);
        }

        PendingIntent open = launchIntent(this);
        if (open != null) builder.setContentIntent(open);
        return builder.build();
    }

    private static void ensureChannels(Context context, NotificationManager manager) {
        if (Build.VERSION.SDK_INT < 26 || manager == null) return;
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            // Live Update 要求頻道不能是 IMPORTANCE_MIN; LOW 不響不跳, 剛好
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "下載進度", NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            manager.createNotificationChannel(channel);
        }
        if (manager.getNotificationChannel(DONE_CHANNEL_ID) == null) {
            manager.createNotificationChannel(new NotificationChannel(
                    DONE_CHANNEL_ID, "下載完成", NotificationManager.IMPORTANCE_DEFAULT));
        }
    }

    private static PendingIntent launchIntent(Context context) {
        Intent launch = context.getPackageManager()
                .getLaunchIntentForPackage(context.getPackageName());
        if (launch == null) return null;
        int flags = PendingIntent.FLAG_UPDATE_CURRENT
                | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
        return PendingIntent.getActivity(context, 0, launch, flags);
    }

    private void acquireLocks() {
        if (wakeLock == null) {
            PowerManager power = (PowerManager) getSystemService(Context.POWER_SERVICE);
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "agp:download");
            wakeLock.setReferenceCounted(false);
        }
        if (!wakeLock.isHeld()) wakeLock.acquire();

        if (wifiLock == null) {
            WifiManager wifi = (WifiManager) getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wifi != null) {
                int mode = Build.VERSION.SDK_INT >= 29
                        ? WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                        : WifiManager.WIFI_MODE_FULL_HIGH_PERF;
                wifiLock = wifi.createWifiLock(mode, "agp:download");
                wifiLock.setReferenceCounted(false);
            }
        }
        if (wifiLock != null && !wifiLock.isHeld()) wifiLock.acquire();
    }

    private void releaseLocks() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
    }
}
