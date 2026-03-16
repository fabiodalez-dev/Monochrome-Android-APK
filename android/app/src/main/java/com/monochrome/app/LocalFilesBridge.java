package com.monochrome.app;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import androidx.documentfile.provider.DocumentFile;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Bridge for selecting and reading local music files on Android.
 * Accessible from JS as window.AndroidLocalFiles
 */
public class LocalFilesBridge {
    private final Activity activity;
    private final WebView webView;
    private static final int PICK_FOLDER_REQUEST = 42;

    public LocalFilesBridge(Activity activity, WebView webView) {
        this.activity = activity;
        this.webView = webView;
    }

    @JavascriptInterface
    public boolean isAvailable() {
        return true;
    }

    @JavascriptInterface
    public void pickFolder() {
        activity.runOnUiThread(() -> {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                    | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
            activity.startActivityForResult(intent, PICK_FOLDER_REQUEST);
        });
    }

    /**
     * Called from MainActivity.onActivityResult when folder is picked.
     * Scans for audio files and sends them to JS one by one.
     */
    public void handleFolderResult(Uri treeUri) {
        new Thread(() -> {
            try {
                DocumentFile dir = DocumentFile.fromTreeUri(activity, treeUri);
                if (dir == null) {
                    callJs("window._androidLocalFilesError('Could not open folder')");
                    return;
                }

                List<DocumentFile> audioFiles = new ArrayList<>();
                scanForAudio(dir, audioFiles);

                callJs("window._androidLocalFilesStart(" + audioFiles.size() + ")");

                for (int i = 0; i < audioFiles.size(); i++) {
                    DocumentFile file = audioFiles.get(i);
                    try {
                        InputStream is = activity.getContentResolver().openInputStream(file.getUri());
                        if (is == null) continue;

                        ByteArrayOutputStream baos = new ByteArrayOutputStream();
                        byte[] buffer = new byte[8192];
                        int len;
                        while ((len = is.read(buffer)) != -1) {
                            baos.write(buffer, 0, len);
                        }
                        is.close();

                        String base64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP);
                        String name = file.getName() != null ? file.getName() : "unknown";
                        String safeName = name.replace("'", "\\'").replace("\\", "\\\\");

                        callJs("window._androidLocalFileReady('" + safeName + "','" + base64 + "'," + i + "," + audioFiles.size() + ")");
                    } catch (Exception e) {
                        // Skip unreadable files
                    }
                }

                callJs("window._androidLocalFilesDone()");
            } catch (Exception e) {
                callJs("window._androidLocalFilesError('" + e.getMessage().replace("'", "\\'") + "')");
            }
        }).start();
    }

    private void scanForAudio(DocumentFile dir, List<DocumentFile> results) {
        if (dir == null || !dir.isDirectory()) return;
        for (DocumentFile file : dir.listFiles()) {
            if (file.isDirectory()) {
                scanForAudio(file, results);
            } else if (file.isFile() && file.getName() != null) {
                String name = file.getName().toLowerCase();
                if (name.endsWith(".flac") || name.endsWith(".mp3") ||
                        name.endsWith(".m4a") || name.endsWith(".wav") ||
                        name.endsWith(".ogg")) {
                    results.add(file);
                }
            }
        }
    }

    private void callJs(String js) {
        activity.runOnUiThread(() -> webView.evaluateJavascript(js, null));
    }
}
