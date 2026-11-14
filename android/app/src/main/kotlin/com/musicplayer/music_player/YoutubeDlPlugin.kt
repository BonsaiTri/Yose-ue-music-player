package com.musicplayer.music_player

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest

/**
 * Bridges the bundled yt-dlp runtime (youtubedl-android library, which ships
 * a private Python runtime + the yt-dlp script) to Dart.
 *
 * Methods:
 *  - init      : one-time extraction of the runtime (backgrounded)
 *  - list      : flat JSON listing of a video or playlist (--dump-json)
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
                try {
                    YoutubeDL.init(context!!)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("init_failed", e.message ?: "yt-dlp init failed", null)
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
                        val request = YoutubeDLRequest(url)
                            .addOption("--dump-json")
                            .addOption("--flat-playlist")
                            .addOption("--ignore-errors")
                        val response = YoutubeDL.execute(request, null, null)
                        result.success(response.out)
                    } catch (e: Exception) {
                        result.error("ytdlp_failed", e.message ?: "yt-dlp listing failed", null)
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
                            progressSink?.success(
                                mapOf(
                                    "key" to processKey,
                                    "progress" to progress,
                                    "eta" to eta,
                                    "line" to (line ?: "")
                                )
                            )
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
                    } catch (e: Exception) {
                        result.error("ytdlp_failed", e.message ?: "yt-dlp download failed", null)
                    }
                }.start()
            }

            "cancel" -> {
                val processKey = call.argument<String>("processKey")
                result.success(
                    processKey != null && YoutubeDL.destroyProcessById(processKey)
                )
            }

            else -> result.notImplemented()
        }
    }
}
