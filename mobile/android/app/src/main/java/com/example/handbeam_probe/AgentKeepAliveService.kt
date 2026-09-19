package com.example.handbeam_probe

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
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Visible foreground service so Android will not freeze the BEAM after the
 * activity leaves the screen. Stop from the notification action — not a
 * silent keep-alive.
 */
class AgentKeepAliveService : Service() {

    companion object {
        const val CHANNEL_ID = "sigil_agent"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.example.handbeam_probe.STOP_AGENT"
        private const val EXTRA_TITLE = "sigil_running_title"
        private const val EXTRA_TEXT = "sigil_running_text"
        private const val EXTRA_TAP = "sigil_running_tap"

        private val running = AtomicBoolean(false)

        @JvmStatic
        fun isRunning(): Boolean = running.get()

        @JvmStatic
        fun start(context: Context) {
            val intent = Intent(context, AgentKeepAliveService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        @JvmStatic
        fun update(context: Context, copy: Pair<String, String>, tap: Intent?) {
            val intent =
                Intent(context, AgentKeepAliveService::class.java).apply {
                    putExtra(EXTRA_TITLE, copy.first)
                    putExtra(EXTRA_TEXT, copy.second)
                    if (tap != null) putExtra(EXTRA_TAP, tap)
                }
            ContextCompat.startForegroundService(context, intent)
        }

        @JvmStatic
        fun stop(context: Context) {
            val intent = Intent(context, AgentKeepAliveService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        startAsForeground()
        running.set(true)
    }

    private var title: String? = null
    private var text: String? = null
    private var tap: Intent? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutdown()
            return START_NOT_STICKY
        }
        intent?.getStringExtra(EXTRA_TITLE)?.let { title = it }
        intent?.getStringExtra(EXTRA_TEXT)?.let { text = it }
        if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_TAP, Intent::class.java)?.let { tap = it }
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra<Intent>(EXTRA_TAP)?.let { tap = it }
        }
        startAsForeground()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        super.onDestroy()
    }

    private fun shutdown() {
        try {
            HandbeamBridge.recordClose()
        } catch (_: Throwable) {
        }
        running.set(false)
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent =
            tap
                ?: Intent(this, MainActivity::class.java).setFlags(
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP,
                )
        val open =
            PendingIntent.getActivity(
                this,
                0,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val stop =
            PendingIntent.getService(
                this,
                1,
                Intent(this, AgentKeepAliveService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val zh = Locale.getDefault().language == "zh"
        val contentTitle = title ?: if (zh) "Handbeam 运行中" else "Handbeam running"
        val contentText = text
        val stopLabel = if (zh) "停止" else "Stop"
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(contentTitle)
                .setContentIntent(open)
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .addAction(0, stopLabel, stop)
        if (!contentText.isNullOrEmpty()) builder.setContentText(contentText)
        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val name = if (Locale.getDefault().language == "zh") "Agent" else "Agent"
        val channel =
            NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
        nm.createNotificationChannel(channel)
    }
}
