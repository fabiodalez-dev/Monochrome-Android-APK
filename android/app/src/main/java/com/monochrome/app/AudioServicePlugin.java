package com.monochrome.app;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.PowerManager;
import android.provider.MediaStore;
import android.provider.Settings;
import android.util.Base64;

import androidx.core.app.NotificationCompat;

import java.io.OutputStream;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "AudioService")
public class AudioServicePlugin extends Plugin {

    private BroadcastReceiver mediaCommandReceiver;

    @Override
    public void load() {
        // Listen for media commands from the foreground service
        mediaCommandReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String command = intent.getStringExtra("command");
                if (command != null) {
                    JSObject data = new JSObject();
                    data.put("command", command);
                    notifyListeners("mediaCommand", data);
                }
            }
        };

        IntentFilter filter = new IntentFilter("com.monochrome.app.MEDIA_COMMAND");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getContext().registerReceiver(mediaCommandReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            getContext().registerReceiver(mediaCommandReceiver, filter);
        }
    }

    @PluginMethod()
    public void start(PluginCall call) {
        String title = call.getString("title", "Monochrome");
        String text = call.getString("text", "Playing music");
        String cover = call.getString("cover", null);
        Boolean playing = call.getBoolean("playing", true);
        long position = call.getData().optLong("position", 0L);
        long duration = call.getData().optLong("duration", 0L);

        Intent intent = new Intent(getContext(), AudioForegroundService.class);
        intent.putExtra("title", title);
        intent.putExtra("text", text);
        intent.putExtra("cover", cover);
        intent.putExtra("playing", playing);
        intent.putExtra("position", position);
        intent.putExtra("duration", duration);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getContext().startForegroundService(intent);
        } else {
            getContext().startService(intent);
        }

        call.resolve();
    }

    @PluginMethod()
    public void stop(PluginCall call) {
        // Don't stop the service — just update state to paused
        Intent intent = new Intent(getContext(), AudioForegroundService.class);
        intent.putExtra("playing", false);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getContext().startForegroundService(intent);
        } else {
            getContext().startService(intent);
        }
        call.resolve();
    }

    @PluginMethod()
    public void isBatteryOptimized(PluginCall call) {
        JSObject result = new JSObject();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PowerManager pm = (PowerManager) getContext().getSystemService(Context.POWER_SERVICE);
            boolean isOptimized = !pm.isIgnoringBatteryOptimizations(getContext().getPackageName());
            result.put("optimized", isOptimized);
        } else {
            result.put("optimized", false);
        }
        call.resolve(result);
    }

    @PluginMethod()
    public void requestBatteryExclusion(PluginCall call) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PowerManager pm = (PowerManager) getContext().getSystemService(Context.POWER_SERVICE);
            if (!pm.isIgnoringBatteryOptimizations(getContext().getPackageName())) {
                Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                intent.setData(Uri.parse("package:" + getContext().getPackageName()));
                intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(intent);
            }
        }
        call.resolve();
    }

    @PluginMethod()
    public void saveFile(PluginCall call) {
        String dataUri = call.getString("data", null);
        String filename = call.getString("filename", "download");

        if (dataUri == null || !dataUri.contains(",")) {
            call.reject("No data provided");
            return;
        }

        try {
            String base64Data = dataUri.substring(dataUri.indexOf(",") + 1);
            byte[] data = Base64.decode(base64Data, Base64.DEFAULT);

            // Detect MIME type from data URI
            String mimeType = "application/octet-stream";
            if (dataUri.startsWith("data:")) {
                mimeType = dataUri.substring(5, dataUri.indexOf(";"));
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ContentValues values = new ContentValues();
                values.put(MediaStore.Downloads.DISPLAY_NAME, filename);
                values.put(MediaStore.Downloads.MIME_TYPE, mimeType);
                values.put(MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/FabiodalezMusic");
                Uri uri = getContext().getContentResolver().insert(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                if (uri != null) {
                    OutputStream os = getContext().getContentResolver().openOutputStream(uri);
                    if (os != null) {
                        os.write(data);
                        os.close();
                    }
                }
            } else {
                java.io.File dir = new java.io.File(
                        Environment.getExternalStoragePublicDirectory(
                                Environment.DIRECTORY_DOWNLOADS), "FabiodalezMusic");
                dir.mkdirs();
                java.io.FileOutputStream fos = new java.io.FileOutputStream(
                        new java.io.File(dir, filename));
                fos.write(data);
                fos.close();
            }

            showDownloadNotification(filename, true);
            call.resolve();
        } catch (Exception e) {
            showDownloadNotification(filename, false);
            call.reject("Save failed: " + e.getMessage());
        }
    }

    private int downloadNotifId = 100;

    private void showDownloadNotification(String filename, boolean success) {
        String channelId = "fabiodalez_downloads";
        NotificationManager nm = (NotificationManager) getContext().getSystemService(Context.NOTIFICATION_SERVICE);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    channelId, "Downloads", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("File download notifications");
            nm.createNotificationChannel(channel);
        }

        String title = success ? "Download complete" : "Download failed";
        String text = success
                ? filename + " saved to Downloads/FabiodalezMusic"
                : "Failed to save " + filename;

        NotificationCompat.Builder builder = new NotificationCompat.Builder(getContext(), channelId)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title)
                .setContentText(text)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT);

        nm.notify(downloadNotifId++, builder.build());
    }

    @Override
    protected void handleOnDestroy() {
        if (mediaCommandReceiver != null) {
            getContext().unregisterReceiver(mediaCommandReceiver);
        }
    }
}
