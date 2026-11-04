package com.illunis.illunis_client

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.util.Calendar

/**
 * Daily alarm state and AlarmManager calls, shared by the channel handler,
 * the alarm receiver (next-day reschedule) and the boot receiver.
 *
 * setAlarmClock is one-shot, so the receiver schedules the next day each time
 * it fires. Only hour and minute are stored, never user text.
 *
 * Log lines (tag illunis_alarm) carry outcome codes only.
 */
object AlarmScheduling {
    const val TAG = "illunis_alarm"
    private const val PREFS = "illunis_alarm"
    private const val KEY_HOUR = "hour"
    private const val KEY_MINUTE = "minute"
    private const val REQUEST_FIRE = 1001
    private const val REQUEST_SHOW = 1002

    const val ACTION_FIRE = "com.illunis.illunis_client.ALARM_FIRE"

    sealed class Outcome {
        object Scheduled : Outcome()
        object ExactAlarmDenied : Outcome()
        object NotSet : Outcome()
        object Failed : Outcome()
    }

    /** Returns true when the time differs from the stored one (a new request). */
    fun save(context: Context, hour: Int, minute: Int): Boolean {
        val p = prefs(context)
        val changed = p.getInt(KEY_HOUR, -1) != hour || p.getInt(KEY_MINUTE, -1) != minute
        p.edit().putInt(KEY_HOUR, hour).putInt(KEY_MINUTE, minute).apply()
        return changed
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }

    /** True when an alarm time is stored (the alarm is on). */
    fun isSet(context: Context): Boolean = prefs(context).contains(KEY_HOUR)

    /** Android 12+ needs the exact-alarm grant, which the user can revoke. */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return alarmManager(context).canScheduleExactAlarms()
    }

    /** Schedules the next occurrence of the stored time. */
    fun scheduleNext(context: Context): Outcome = scheduleStored(context).also {
        Log.i(TAG, "schedule ${it.javaClass.simpleName}")
    }

    private fun scheduleStored(context: Context): Outcome {
        val p = prefs(context)
        if (!p.contains(KEY_HOUR)) return Outcome.NotSet
        if (!canScheduleExact(context)) return Outcome.ExactAlarmDenied
        return try {
            val trigger = nextTrigger(p.getInt(KEY_HOUR, 0), p.getInt(KEY_MINUTE, 0))
            val info = AlarmManager.AlarmClockInfo(trigger, showIntent(context))
            alarmManager(context).setAlarmClock(info, fireIntent(context))
            Outcome.Scheduled
        } catch (e: SecurityException) {
            // Grant revoked between the check and the call.
            Outcome.ExactAlarmDenied
        } catch (e: RuntimeException) {
            Outcome.Failed
        }
    }

    fun cancel(context: Context) {
        try {
            alarmManager(context).cancel(fireIntent(context))
        } catch (e: RuntimeException) {
            // Nothing to cancel, or the service is unavailable; either way no alarm.
        }
    }

    /** Next local wall-clock time at hour:minute, strictly in the future. */
    fun nextTrigger(hour: Int, minute: Int, now: Calendar = Calendar.getInstance()): Long {
        val c = now.clone() as Calendar
        c.set(Calendar.HOUR_OF_DAY, hour)
        c.set(Calendar.MINUTE, minute)
        c.set(Calendar.SECOND, 0)
        c.set(Calendar.MILLISECOND, 0)
        if (!c.after(now)) c.add(Calendar.DAY_OF_YEAR, 1)
        return c.timeInMillis
    }

    private fun fireIntent(context: Context): PendingIntent {
        val i = Intent(context, AlarmReceiver::class.java).setAction(ACTION_FIRE)
        return PendingIntent.getBroadcast(
            context, REQUEST_FIRE, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Opened when the user taps the alarm icon in the status bar or clock. */
    private fun showIntent(context: Context): PendingIntent {
        val i = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context, REQUEST_SHOW, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun alarmManager(context: Context) =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
