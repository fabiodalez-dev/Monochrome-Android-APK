package com.monochrome.app;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.ContentValues;
import android.content.Context;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.net.Uri;
import android.util.Base64;
import android.webkit.JavascriptInterface;

import androidx.core.app.NotificationCompat;

import java.io.OutputStream;

/**
 * Direct JavaScript bridge for file downloads.
 * Accessible from JS as window.AndroidDownload.saveBase64(data, filename, mimeType)
 */
public class DownloadBridge {
    private final Context context;
    private int notifId = 200;

    public DownloadBridge(Context context) {
        this.context = context;
    }

    @JavascriptInterface
    public void saveBase64(String base64Data, String filename, String mimeType) {
        try {
            byte[] data = Base64.decode(base64Data, Base64.DEFAULT);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ContentValues values = new ContentValues();
                values.put(MediaStore.Downloads.DISPLAY_NAME, filename);
                values.put(MediaStore.Downloads.MIME_TYPE,
                        mimeType != null ? mimeType : "application/octet-stream");
                values.put(MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/FabiodalezMusic");
                Uri uri = context.getContentResolver().insert(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                if (uri != null) {
                    OutputStream os = context.getContentResolver().openOutputStream(uri);
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

            showNotification(filename, true);
        } catch (Exception e) {
            showNotification(filename, false);
        }
    }

    @JavascriptInterface
    public boolean isAvailable() {
        return true;
    }

    private void showNotification(String filename, boolean success) {
        String channelId = "fabiodalez_downloads";
        NotificationManager nm = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    channelId, "Downloads", NotificationManager.IMPORTANCE_DEFAULT);
            nm.createNotificationChannel(channel);
        }

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, channelId)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(success ? "Download complete" : "Download failed")
                .setContentText(success
                        ? filename + " → Downloads/FabiodalezMusic"
                        : "Failed to save " + filename)
                .setAutoCancel(true);

        nm.notify(notifId++, builder.build());
    }
}
