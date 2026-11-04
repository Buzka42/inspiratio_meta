package com.illunis.illunis_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Fires at the alarm time. It ONLY posts the digest notification, tells a
 * running engine, and schedules tomorrow.
 *
 * It must never start [MicCaptureService]: on Android 14+ a microphone
 * foreground service cannot start from a receiver with the screen off (the
 * while-in-use restriction). The user's tap on the notification opens the
 * app, and listening starts from there.
 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AlarmScheduling.ACTION_FIRE) return
        if (!AlarmScheduling.isSet(context)) return
        val posted = try {
            // Always post natively so the user is woken even with no engine.
            // Dart's own show() for the same payload reuses the notification
            // id and alerts only once, so there is no duplicate.
            DigestNotifications.post(
                context,
                DigestNotifications.DIGEST_TITLE,
                DigestNotifications.DIGEST_BODY,
                DigestNotifications.DIGEST_PAYLOAD,
            )
        } catch (e: Exception) {
            // Notifications blocked or the channel failed; nothing else to do here.
            false
        }
        val engine = AlarmChannelHandler.dispatchFired()
        Log.i(AlarmScheduling.TAG, "fired posted=$posted engine=$engine")
        AlarmScheduling.scheduleNext(context)
    }
}

/**
 * Restores the alarm after reboot, a clock or time zone change, or when the
 * user grants exact-alarm access (Android 12+). AlarmManager drops alarms on
 * reboot.
 */
class AlarmRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            ACTION_EXACT_ALARM_STATE_CHANGED,
            -> if (AlarmScheduling.isSet(context)) {
                Log.i(AlarmScheduling.TAG, "restore")
                AlarmScheduling.scheduleNext(context)
            }
        }
    }

    private companion object {
        // AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED (API 31),
        // spelled out so the `when` compiles against any compileSdk.
        const val ACTION_EXACT_ALARM_STATE_CHANGED =
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED"
    }
}
