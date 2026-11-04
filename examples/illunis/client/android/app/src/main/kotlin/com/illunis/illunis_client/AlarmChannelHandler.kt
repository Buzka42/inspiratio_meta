package com.illunis.illunis_client

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `illunis/alarm` (see client/lib/alarm/alarm_scheduler.dart).
 *
 * Dart to native: `schedule {hour, minute}`, `cancel`, `canScheduleExact`
 * (returns bool), `openExactAlarmSettings` (returns bool: a screen opened).
 * Native to Dart: `onAlarmFired` (no arguments) while the engine is running.
 *
 * Errors go back as codes with a short message and no details, never as a
 * thrown exception or stack trace:
 *  - `bad_args`            hour/minute missing or out of range
 *  - `exact_alarm_denied`  Android 12+ exact-alarm access is off
 *  - `schedule_failed`     AlarmManager refused for another reason
 *
 * A denied `schedule` for a new time (the user just set it) also opens
 * Settings > Alarms & reminders. A re-send of the stored time (app start)
 * does not, so the screen never opens without a user request. After the
 * grant, [AlarmRestoreReceiver] schedules the stored time natively.
 */
class AlarmChannelHandler(
    private val context: Context,
    messenger: BinaryMessenger,
    /** Asks for POST_NOTIFICATIONS; the alarm is useless without it. */
    private val requestNotificationPermission: () -> Unit,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler(this)
        live = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "schedule" -> schedule(call, result)
                "cancel" -> {
                    AlarmScheduling.cancel(context)
                    AlarmScheduling.clear(context)
                    result.success(null)
                }
                "canScheduleExact" -> result.success(AlarmScheduling.canScheduleExact(context))
                "openExactAlarmSettings" -> result.success(openExactAlarmSettings())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("internal", "alarm call failed", null)
        }
    }

    private fun schedule(call: MethodCall, result: MethodChannel.Result) {
        val hour = call.argument<Int>("hour")
        val minute = call.argument<Int>("minute")
        if (hour == null || minute == null || hour !in 0..23 || minute !in 0..59) {
            result.error("bad_args", "hour 0-23 and minute 0-59 are required", null)
            return
        }
        when (scheduleAt(hour, minute)) {
            AlarmScheduling.Outcome.Scheduled -> result.success(null)
            AlarmScheduling.Outcome.ExactAlarmDenied -> result.error(
                "exact_alarm_denied",
                "exact alarms are off; open Settings > Alarms & reminders",
                null,
            )
            else -> result.error("schedule_failed", "the alarm could not be scheduled", null)
        }
    }

    /** Shared by `schedule` and the debug launch extra in [MainActivity]. */
    fun scheduleAt(hour: Int, minute: Int): AlarmScheduling.Outcome {
        // Store first so a later grant (permission-state broadcast) or a
        // reboot can schedule it without Dart.
        val isNew = AlarmScheduling.save(context, hour, minute)
        val outcome = AlarmScheduling.scheduleNext(context)
        when (outcome) {
            AlarmScheduling.Outcome.Scheduled -> requestNotificationPermission()
            AlarmScheduling.Outcome.ExactAlarmDenied -> if (isNew) openExactAlarmSettings()
            else -> Unit
        }
        return outcome
    }

    /**
     * Settings > Alarms & reminders for this app on Android 12+, else (or if
     * that screen is missing) the app details screen. [context] is the
     * application context, so the intent needs FLAG_ACTIVITY_NEW_TASK.
     */
    private fun openExactAlarmSettings(): Boolean {
        val pkg = Uri.fromParts("package", context.packageName, null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            start(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkg))
        ) {
            return true
        }
        return start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg))
    }

    private fun start(intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }

    /** Called from [AlarmReceiver] on the main thread. */
    private fun notifyFired() {
        try {
            channel.invokeMethod("onAlarmFired", null)
        } catch (e: Exception) {
            // Engine detached; the receiver's notification already covers it.
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        if (live === this) live = null
    }

    companion object {
        const val CHANNEL = "illunis/alarm"

        /** The handler of the running engine, or null when no engine is attached. */
        @Volatile
        private var live: AlarmChannelHandler? = null

        /** Returns true when a running engine was told. */
        fun dispatchFired(): Boolean {
            val h = live ?: return false
            h.notifyFired()
            return true
        }
    }
}
