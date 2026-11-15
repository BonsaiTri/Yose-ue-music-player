package com.musicplayer.music_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that protects the app (and its yt-dlp worker
 * child processes) from the low-memory killer while downloads run in
 * the background.
 *
 * Why this is needed: a backgrounded (cached) app gets a high oom_adj,
 * and native child processes inherit their parent's oom_adj at fork
 * time. With five Python workers each holding ~150 MB, LMK happily
 * reaps them mid-download whenever the app is backgrounded. Running as
 * a foreground service keeps the whole process group at a low oom_adj,
 * so the workers survive.
 *
 * Type `dataSync` (Android 14+) is the honest description of what this
 * service does. It is started while the app is in the foreground (the
 * user just queued work), which is a permitted start condition.
 *
 * The partial wake lock keeps the CPU out of deep sleep so queued
 * workers can finish when the screen is off.
 */
class DownloadGuardService : Service() {

    private var wakeLock: PowerWakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Downloads",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Shown while Yose-ue is downloading tracks" }
        )

        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Yose-ue Music Player")
            .setContentText("Downloading tracks\u2026")
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(openApp)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = PowerWakeLock(pm)
        wakeLock?.acquire()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "yose-ue-downloads"
        private const val NOTIF_ID = 4242

        /** Starts the guard (idempotent: restarts are cheap). */
        fun start(context: Context) {
            val intent = Intent(context, DownloadGuardService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadGuardService::class.java))
        }
    }
}

/** A reference-counted partial wake lock with a hard hold cap. */
private class PowerWakeLock(private val pm: PowerManager) {
    private val maxHoldMs = 6 * 60 * 60 * 1000L // hard cap; FGS itself has none

    private val lock = pm.newWakeLock(
        PowerManager.PARTIAL_WAKE_LOCK,
        "yose-ue:download-guard"
    ).apply { setReferenceCounted(false) }

    fun acquire() {
        if (!lock.isHeld) lock.acquire(maxHoldMs)
    }

    fun release() {
        if (lock.isHeld) lock.release()
    }
}
