package com.illunis.illunis_client

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Posts high-importance notifications whose tap opens [MainActivity] with the
 * payload id as an extra. Platform APIs only (no androidx.core dependency).
 */
object DigestNotifications {
    const val CHANNEL_ID = "illunis_digest"
    const val EXTRA_PAYLOAD = "com.illunis.illunis_client.PAYLOAD_ID"

    // Mirrors client/lib/app/alarm_coordinator.dart (digestPayloadId,
    // digestNotificationTitle, digestNotificationBody). Keep them in sync,
    // or pass them through `schedule` later.
    const val DIGEST_PAYLOAD = "morning_digest"
    const val DIGEST_TITLE = "Good morning"
    const val DIGEST_BODY = "Tap to hear your morning digest."

    /** False when the user blocked notifications or (13+) has not granted them. */
    fun canPost(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        return manager(context).areNotificationsEnabled()
    }

    /** Returns false when posting is not allowed. */
    fun post(context: Context, title: String, body: String, payloadId: String): Boolean {
        if (!canPost(context)) return false
        ensureChannel(context)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }
        val n = b.setSmallIcon(R.drawable.ic_stat_illunis)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(Notification.CATEGORY_REMINDER)
            // The fixed digest title and body hold no user data: show on the lock screen.
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            // Same id for the same payload: the receiver and Dart may both post.
            .setOnlyAlertOnce(true)
            .setContentIntent(tapIntent(context, payloadId))
            .build()
        manager(context).notify(notificationId(payloadId), n)
        return true
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val m = manager(context)
        if (m.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(CHANNEL_ID, "Morning digest", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "The daily alarm. Tap it to hear the digest."
        m.createNotificationChannel(ch)
    }

    private fun tapIntent(context: Context, payloadId: String): PendingIntent {
        val i = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .putExtra(EXTRA_PAYLOAD, payloadId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context, notificationId(payloadId), i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Stable per payload id; payload ids are short opaque ascii strings. */
    private fun notificationId(payloadId: String): Int = 2000 + (payloadId.hashCode() and 0xFFFF)

    private fun manager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
