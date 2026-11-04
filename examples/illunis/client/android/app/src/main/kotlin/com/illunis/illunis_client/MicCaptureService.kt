package com.illunis.illunis_client

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service of type microphone. Records with [MicAudioRecorder]
 * (VOICE_RECOGNITION, AGC and NS off) and forwards PCM16 chunks to Dart via
 * [MicPcmBus] on `illunis/mic/pcm`. Compiled; not yet run on a device.
 *
 * Start it ONLY from a user interaction while the activity is visible (see
 * [MicChannelHandler.startCapture]). Never start it from [AlarmReceiver] or
 * the boot receiver: Android 14+ refuses a microphone foreground service
 * started from the background (ForegroundServiceStartNotAllowedException or
 * SecurityException), and Android 14+ also requires RECORD_AUDIO to be
 * granted before startForeground with this type.
 */
class MicCaptureService : Service() {

    private var recorder: MicAudioRecorder? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopCapture()
            return START_NOT_STICKY
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val n = ongoingNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
        } catch (e: Exception) {
            // Started from the background or permission missing: give up quietly.
            stopSelf()
            return START_NOT_STICKY
        }
        if (recorder == null) {
            val r = MicAudioRecorder(MicPcmBus::send)
            if (!r.start()) {
                MicPcmBus.fail("mic_unavailable")
                stopCapture()
                return START_NOT_STICKY
            }
            recorder = r
            MicPcmBus.info = r.info
        }
        // Never log or persist the audio.
        // Not sticky: a restart by the system would be a background start.
        return START_NOT_STICKY
    }

    private fun stopCapture() {
        releaseRecorder()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        releaseRecorder()
        super.onDestroy()
    }

    private fun releaseRecorder() {
        recorder?.stop()
        recorder = null
        MicPcmBus.info = emptyMap()
    }

    private fun ongoingNotification(): Notification {
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val m = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (m.getNotificationChannel(CHANNEL_ID) == null) {
                m.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Listening", NotificationManager.IMPORTANCE_LOW),
                )
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b.setSmallIcon(R.drawable.ic_stat_illunis)
            .setContentTitle("Illunis is listening")
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "illunis_listening"
        private const val NOTIFICATION_ID = 3001
        const val ACTION_START = "com.illunis.illunis_client.MIC_START"
        const val ACTION_STOP = "com.illunis.illunis_client.MIC_STOP"
    }
}
