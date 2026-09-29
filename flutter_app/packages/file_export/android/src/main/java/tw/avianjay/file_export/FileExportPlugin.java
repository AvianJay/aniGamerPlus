package tw.avianjay.file_export;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.DocumentsContract;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;

/**
 * 把 App 沙盒裡的檔案複製到使用者用系統選擇器挑的位置.
 *
 * 走的是儲存空間存取架構 (SAF): 一個檔案用 ACTION_CREATE_DOCUMENT, 好幾個檔案用
 * ACTION_OPEN_DOCUMENT_TREE 選資料夾再一支一支建. 寫進去的是選擇器發下來的
 * content:// URI, 所以從 Android 5 到最新版都不需要任何儲存空間權限.
 */
public class FileExportPlugin implements FlutterPlugin, ActivityAware, MethodCallHandler,
        PluginRegistry.ActivityResultListener {
    private static final int REQUEST_CREATE = 47301;
    private static final int REQUEST_TREE = 47302;
    private static final int BUFFER_SIZE = 1 << 20;
    // 每個緩衝區都回報的話, 光是跨執行緒丟訊息就比複製還忙
    private static final long PROGRESS_INTERVAL_MS = 200;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean cancelled = new AtomicBoolean(false);
    private ExecutorService executor;
    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding activity;

    // 下面兩個只在主執行緒上讀寫
    private Pending pending;
    private boolean copying;

    private static final class Source {
        final String path;
        final String name;
        final String mimeType;

        Source(String path, String name, String mimeType) {
            this.path = path;
            this.name = name;
            this.mimeType = mimeType;
        }
    }

    private static final class Pending {
        final List<Source> files;
        final Result result;

        Pending(List<Source> files, Result result) {
            this.files = files;
            this.result = result;
        }
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        executor = Executors.newSingleThreadExecutor();
        channel = new MethodChannel(binding.getBinaryMessenger(), "file_export");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        cancelled.set(true);
        channel.setMethodCallHandler(null);
        channel = null;
        executor.shutdown();
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding;
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activity != null) activity.removeActivityResultListener(this);
        activity = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        switch (call.method) {
            case "save":
                save(call, result);
                break;
            case "cancel":
                cancelled.set(true);
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }

    private void save(MethodCall call, Result result) {
        if (pending != null || copying) {
            result.error("busy", "上一個匯出還沒結束", null);
            return;
        }
        if (activity == null) {
            result.error("no_activity", "找不到可以開啟選擇器的畫面", null);
            return;
        }
        List<Source> files = new ArrayList<>();
        Object raw = call.argument("files");
        if (raw instanceof List) {
            for (Object item : (List<?>) raw) {
                if (!(item instanceof Map)) continue;
                Map<?, ?> map = (Map<?, ?>) item;
                Object path = map.get("path");
                Object name = map.get("name");
                Object mimeType = map.get("mimeType");
                if (!(path instanceof String) || !(name instanceof String)) continue;
                files.add(new Source((String) path, (String) name,
                        mimeType instanceof String ? (String) mimeType : "application/octet-stream"));
            }
        }
        if (files.isEmpty()) {
            result.error("bad_args", "沒有要匯出的檔案", null);
            return;
        }
        for (Source file : files) {
            if (!new File(file.path).isFile()) {
                result.error("missing", "找不到 " + file.name, null);
                return;
            }
        }

        Intent intent;
        int request;
        if (files.size() == 1) {
            // 單一檔案: 使用者在選擇器裡還可以順便改名
            intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType(files.get(0).mimeType);
            intent.putExtra(Intent.EXTRA_TITLE, files.get(0).name);
            request = REQUEST_CREATE;
        } else {
            intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            request = REQUEST_TREE;
        }
        cancelled.set(false);
        pending = new Pending(files, result);
        try {
            activity.getActivity().startActivityForResult(intent, request);
        } catch (ActivityNotFoundException e) {
            pending = null;
            result.error("unavailable", "這支手機沒有可以選擇儲存位置的檔案管理員", null);
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_CREATE && requestCode != REQUEST_TREE) return false;
        final Pending job = pending;
        pending = null;
        if (job == null) return true;
        final Uri picked = data == null ? null : data.getData();
        if (resultCode != Activity.RESULT_OK || picked == null) {
            job.result.success(outcome(0, true));
            return true;
        }
        copying = true;
        final boolean tree = requestCode == REQUEST_TREE;
        executor.execute(() -> copy(job, picked, tree));
        return true;
    }

    /** 在背景執行緒上跑. 結果一律丟回主執行緒再交給 Dart. */
    private void copy(Pending job, Uri picked, boolean tree) {
        ContentResolver resolver = context.getContentResolver();
        long total = 0;
        for (Source file : job.files) total += new File(file.path).length();
        long copied = 0;
        long reportedAt = 0;
        int saved = 0;
        // 正在寫的那一個. 中途停下或出錯時要刪掉, 不留半個檔案給使用者
        Uri current = null;
        try {
            Uri parent = tree
                    ? DocumentsContract.buildDocumentUriUsingTree(
                            picked, DocumentsContract.getTreeDocumentId(picked))
                    : null;
            report(0, total);
            byte[] buffer = new byte[BUFFER_SIZE];
            for (Source file : job.files) {
                if (cancelled.get()) break;
                // 資料夾裡有同名檔案的話, 提供者會自己在檔名後面加 (1)
                current = tree
                        ? DocumentsContract.createDocument(resolver, parent, file.mimeType, file.name)
                        : picked;
                if (current == null) throw new IOException("無法在選擇的資料夾建立 " + file.name);
                try (InputStream input = new FileInputStream(file.path);
                     OutputStream output = resolver.openOutputStream(current, "w")) {
                    if (output == null) throw new IOException("無法寫入選擇的位置");
                    int read;
                    while (!cancelled.get() && (read = input.read(buffer)) >= 0) {
                        output.write(buffer, 0, read);
                        copied += read;
                        long now = SystemClock.uptimeMillis();
                        if (now - reportedAt >= PROGRESS_INTERVAL_MS) {
                            reportedAt = now;
                            report(copied, total);
                        }
                    }
                }
                if (cancelled.get()) break;
                current = null;
                saved++;
            }
            if (current != null) deleteQuietly(resolver, current);
            report(copied, total);
            final int done = saved;
            final boolean stopped = cancelled.get();
            finish(() -> job.result.success(outcome(done, stopped)));
        } catch (Exception e) {
            if (current != null) deleteQuietly(resolver, current);
            final int done = saved;
            final String message = e.getMessage() != null ? e.getMessage() : e.toString();
            finish(() -> job.result.error("copy_failed", message, outcome(done, false)));
        }
    }

    private void report(long copied, long total) {
        final Map<String, Object> args = new HashMap<>();
        args.put("copied", copied);
        args.put("total", total);
        main.post(() -> {
            if (channel != null) channel.invokeMethod("progress", args);
        });
    }

    private void finish(Runnable deliver) {
        main.post(() -> {
            copying = false;
            deliver.run();
        });
    }

    private static void deleteQuietly(ContentResolver resolver, Uri uri) {
        try {
            DocumentsContract.deleteDocument(resolver, uri);
        } catch (Exception ignored) {
            // 提供者不讓刪就算了, 最多留下一個不完整的檔案
        }
    }

    private static Map<String, Object> outcome(int saved, boolean cancelled) {
        Map<String, Object> map = new HashMap<>();
        map.put("saved", saved);
        map.put("cancelled", cancelled);
        return map;
    }
}
