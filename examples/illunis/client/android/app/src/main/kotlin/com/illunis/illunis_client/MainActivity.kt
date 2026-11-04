package com.illunis.illunis_client

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.util.Calendar

class MainActivity : FlutterActivity() {
    private var alarm: AlarmChannelHandler? = null
    private var notifications: NotificationHandler? = null
    private var mic: MicChannelHandler? = null
    private var audioPlayer: AudioPlayerChannel? = null
    private var health: HealthChannel? = null

    /**
     * True when Android recreates the activity (for example after killing the
     * process). It then hands back the ORIGINAL launch intent, so its tap
     * payload and debug extra must not be replayed.
     */
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        restored = savedInstanceState != null
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        alarm = AlarmChannelHandler(applicationContext, messenger, ::requestNotificationPermission)
        notifications = NotificationHandler(applicationContext, messenger, ::requestNotificationPermission)
            .also { if (!restored) it.onLaunchIntent(intent) }
        if (!restored) debugAlarm(intent)
        mic = MicChannelHandler(this, messenger)
        audioPlayer = AudioPlayerChannel(messenger)
        health = HealthChannel(this, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        alarm?.dispose()
        notifications?.dispose()
        mic?.dispose()
        audioPlayer?.dispose()
        audioPlayer = null
        health?.dispose()
        health = null
        alarm = null
        notifications = null
        mic = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        notifications?.onNewIntent(intent)
        debugAlarm(intent)
    }

    /**
     * Debuggable builds only: `am start ... --ei illunis.debug_alarm_in_min N`
     * sets the alarm N minutes ahead through the same native path as Dart's
     * `schedule`, for device checks; N = 0 cancels it. Release builds ignore it.
     */
    private fun debugAlarm(intent: Intent?) {
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) return
        val min = intent?.getIntExtra(DEBUG_ALARM_EXTRA, -1) ?: -1
        if (min !in 0..1440) return
        intent?.removeExtra(DEBUG_ALARM_EXTRA)
        if (min == 0) {
            AlarmScheduling.cancel(this)
            AlarmScheduling.clear(this)
            return
        }
        val at = Calendar.getInstance().apply { add(Calendar.MINUTE, min) }
        alarm?.scheduleAt(at.get(Calendar.HOUR_OF_DAY), at.get(Calendar.MINUTE))
    }

    override fun onResume() {
        super.onResume()
        mic?.inForeground = true
        // An alarm scheduled natively (the exact-alarm grant broadcast, a
        // reboot) never passed through `schedule`; ask here so it can post.
        if (AlarmScheduling.isSet(this)) requestNotificationPermission()
    }

    override fun onPause() {
        mic?.inForeground = false
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        if (mic?.onPermissionResult(requestCode, grantResults) == true) return
        // NOTIFICATION_REQUEST needs no reply to Dart: show() reports
        // notifications_denied until it is granted.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    @Deprecated("Health Connect's sheet result arrives here; FlutterActivity has no result API.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (health?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    /** Android 13+ runtime request; the system stops showing it after two denials. */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
    }

    private companion object {
        const val NOTIFICATION_REQUEST = 4102
        const val DEBUG_ALARM_EXTRA = "illunis.debug_alarm_in_min"
    }
}
