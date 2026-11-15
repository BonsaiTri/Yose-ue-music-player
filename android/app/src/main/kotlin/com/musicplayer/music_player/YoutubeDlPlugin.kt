package com.musicplayer.music_player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import java.io.FileOutputStream

/**
 * Bridges the bundled yt-dlp runtime (youtubedl-android library, which ships
 * a private Python runtime + the yt-dlp script) to Dart.
 *
 * Methods:
 *  - init      : one-time extraction of the runtime (backgrounded)
 *  - list      : flat JSON listing of a video or playlist (--dump-json)
 *  - title     : playlist title only (--print playlist_title)
 *  - download  : download best audio for a URL into a work directory
 *  - cancel    : kill an in-flight download process
 *
 * Progress events flow on the companion EventChannel as
 * {key, progress, eta, line} maps.
 */
class YoutubeDlPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var progressSink: EventChannel.EventSink? = null

    // EventSink.success() dispatches a platform message, which Flutter only
    // allows on the main thread. The library's progress callback arrives on
    // its worker thread, so every event is posted to the main looper.
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        const val TAG = "yose_ue/youtube_dl"
        const val PROGRESS_TAG = "yose_ue/youtube_dl/progress"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.flutterEngine.dartExecutor, TAG).also {
            it.setMethodCallHandler(this)
        }
        EventChannel(binding.flutterEngine.dartExecutor, PROGRESS_TAG).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    progressSink = sink
                }
                override fun onCancel(args: Any?) {
                    progressSink = null
                }
            }
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        progressSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> Thread {
                val appCtx = context!!
                val base = File(appCtx.noBackupFilesDir, "youtubedl-android")
                val failedMarker = File(appCtx.noBackupFilesDir, "youtubedl-android.init-failed")
                try {
                    // Self-heal: a previous init may have died mid-extraction,
                    // leaving partial state that makes re-extraction fail (the
                    // library's own cleanup is not recursive). Wipe it so a
                    // retry always starts from a clean slate.
                    if (failedMarker.exists()) {
                        deleteRecursively(base)
                        failedMarker.delete()
                    }
                    installPinnedYtDlp(appCtx, base)
                    YoutubeDL.init(appCtx)
                    failedMarker.delete()
                    result.success(true)
                } catch (t: Throwable) {
                    Log.e(TAG, "yt-dlp init failed", t)
                    try { failedMarker.writeText(describe(t)) } catch (_: Exception) {}
                    result.error("init_failed", describe(t), null)
                }
            }.start()

            "list" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("bad_args", "url is required", null)
                    return
                }
                Thread {
                    try {
                        Log.i(TAG, "list: $url")
                        val request = YoutubeDLRequest(url)
                            .addOption("--dump-json")
                            .addOption("--flat-playlist")
                            .addOption("--ignore-errors")
                        val response = YoutubeDL.execute(request, null, null)
                        Log.i(TAG, "list ok: ${response.out.length} chars")
                        result.success(response.out)
                    } catch (t: Throwable) {
                        Log.e(TAG, "yt-dlp list failed", t)
                        result.error("ytdlp_failed", describe(t), null)
                    }
                }.start()
            }

            "download" -> {
                val url = call.argument<String>("url")
                val workDir = call.argument<String>("workDir")
                val processKey = call.argument<String>("processKey")
                val format = call.argument<String>("format")
                    ?: "bestaudio[ext=m4a]/bestaudio"
                if (url == null || workDir == null || processKey == null) {
                    result.error("bad_args", "url, workDir and processKey are required", null)
                    return
                }
                Thread {
                    try {
                        val request = YoutubeDLRequest(url)
                            .addOption("-f", format)
                            .addOption("--no-part")
                            .addOption("--no-playlist")
                            .addOption("--restrict-filenames")
                            .addOption("-o", "$workDir/%(id)s.%(ext)s")
                        val response = YoutubeDL.execute(request, processKey) { progress, eta, line ->
                            val event = mapOf(
                                "key" to processKey,
                                "progress" to progress,
                                "eta" to eta,
                                "line" to (line ?: "")
                            )
                            mainHandler.post {
                                progressSink?.success(event)
                            }
                        }
                        result.success(
                            mapOf(
                                "exitCode" to response.exitCode,
                                "out" to response.out,
                                "err" to response.err
                            )
                        )
                    } catch (e: YoutubeDL.CanceledException) {
                        result.error("cancelled", "download cancelled", null)
                    } catch (t: Throwable) {
                        Log.e(TAG, "yt-dlp download failed", t)
                        result.error("ytdlp_failed", describe(t), null)
                    }
                }.start()
            }

            "title" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("bad_args", "url is required", null)
                    return
                }
                Thread {
                    try {
                        // Cheap metadata-only fetch: prints the playlist title
                        // (once per entry); Dart takes the first line.
                        val request = YoutubeDLRequest(url)
                            .addOption("--flat-playlist")
                            .addOption("--print", "playlist_title")
                            .addOption("--ignore-errors")
                        val response = YoutubeDL.execute(request, null, null)
                        result.success(response.out)
                    } catch (t: Throwable) {
                        Log.e(TAG, "yt-dlp title failed", t)
                        result.error("ytdlp_failed", describe(t), null)
                    }
                }.start()
            }

            "cancel" -> {
                val processKey = call.argument<String>("processKey")
                result.success(
                    processKey != null && YoutubeDL.destroyProcessById(processKey)
                )
            }

            "guard_start" -> {
                val appCtx = context
                result.success(appCtx != null).also {
                    if (appCtx != null) DownloadGuardService.start(appCtx)
                }
            }

            "guard_stop" -> {
                context?.let { DownloadGuardService.stop(it) }
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Flattens an exception chain (including causes) into a single
     * readable message. The library wraps low-level IO failures in
     * YoutubeDLException("failed to initialize", cause), and the cause
     * is what actually tells us what went wrong.
     */
    private fun deleteRecursively(f: File) {
        if (!f.exists()) return
        if (f.isDirectory) f.listFiles()?.forEach { deleteRecursively(it) }
        f.delete()
    }

    /**
     * Installs our pinned yt-dlp script (assets/yt-dlp/yt-dlp, v2026.10.26 —
     * the same version pinned on desktop) into the location the library
     * expects (youtubedl-android/yt-dlp/yt-dlp) BEFORE YoutubeDL.init runs,
     * because the library only copies its bundled script when the file is
     * absent. The bundled script lags the upstream release and mishandles
     * YouTube's current SABR/PO-token responses (HTTP 403), so we pin.
     * A marker file pins the version so upgrades are idempotent.
     */
    private fun installPinnedYtDlp(appCtx: Context, base: File) {
        // 2026.10.26-doh1: the pinned script carries a DNS-over-HTTPS
        // fallback for the AAR's flaky in-sandbox hostname resolution.
        val pinned = "2026.10.26-doh1"
        val script = File(File(base, "yt-dlp"), "yt-dlp")
        val marker = File(base, ".yt-dlp-version")
        if (script.exists() && marker.exists() && marker.readText().trim() == pinned) return
        try {
            if (script.exists()) script.delete()
            script.parentFile?.mkdirs()
            appCtx.assets.open("flutter_assets/assets/yt-dlp/yt-dlp").use { input ->
                FileOutputStream(script).use { input.copyTo(it) }
            }
            marker.writeText(pinned)
            Log.i(TAG, "installed pinned yt-dlp $pinned at ${script.absolutePath}")
        } catch (e: Exception) {
            // Non-fatal: the library's own bundled script remains usable.
            Log.w(TAG, "could not install pinned yt-dlp; using bundled script", e)
        }
    }

    private fun describe(e: Throwable): String {
        val sb = StringBuilder()
        var cur: Throwable? = e
        var depth = 0
        while (cur != null && depth < 6) {
            if (depth > 0) sb.append("\n  caused by: ")
            sb.append(cur.javaClass.simpleName)
            if (!cur.message.isNullOrBlank()) sb.append(": ").append(cur.message)
            cur = cur.cause
            depth++
        }
        return sb.toString().take(900)
    }
}
