package com.illunis.illunis_client

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `illunis/notifications` (see client/lib/alarm/notification_port.dart).
 *
 * Dart to native: `show {title, body, payload_id}`, `getLaunchPayload`.
 * Native to Dart: `onNotificationTap {payload_id}` for taps while running.
 *
 * Error codes (no details, no stack): `bad_args`, `notifications_denied`,
 * `internal`. Titles and bodies are never logged.
 */
class NotificationHandler(
    private val context: Context,
    messenger: BinaryMessenger,
    private val requestNotificationPermission: () -> Unit,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)

    /** Payload of the tap that launched the activity; read once by Dart. */
    private var launchPayload: String? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "show" -> show(call, result)
                "getLaunchPayload" -> {
                    val p = launchPayload
                    launchPayload = null
                    Log.i(TAG, "launch_payload read=${p != null}")
                    result.success(p)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("internal", "notification call failed", null)
        }
    }

    private fun show(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        val payload = call.argument<String>("payload_id")
        if (title == null || body == null || payload.isNullOrEmpty()) {
            result.error("bad_args", "title, body and payload_id are required", null)
            return
        }
        if (!DigestNotifications.post(context, title, body, payload)) {
            requestNotificationPermission()
            result.error("notifications_denied", "notifications are not allowed", null)
            return
        }
        result.success(null)
    }

    /** The intent that created the activity (cold start from a tap). */
    fun onLaunchIntent(intent: Intent?) {
        launchPayload = takePayload(intent) ?: launchPayload
    }

    /**
     * A tap while the activity exists (singleTop -> onNewIntent). After the
     * OS killed the process, the activity is recreated and the tap arrives
     * here before Dart listens; Dart then answers false (or nothing), and
     * the tap is kept for `getLaunchPayload` instead of being dropped.
     */
    fun onNewIntent(intent: Intent?) {
        val p = takePayload(intent) ?: return
        val keep: () -> Unit = { launchPayload = p; Log.i(TAG, "tap kept") }
        try {
            channel.invokeMethod("onNotificationTap", mapOf("payload_id" to p), object : MethodChannel.Result {
                override fun success(delivered: Any?) {
                    if (delivered == true) Log.i(TAG, "tap warm") else keep()
                }
                override fun error(code: String, message: String?, details: Any?) = keep()
                override fun notImplemented() = keep()
            })
        } catch (e: Exception) {
            keep()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "illunis/notifications"
        private const val TAG = "illunis_notify"

        /**
         * Reads and removes the payload extra, so a recreated activity or a
         * relaunch from Recents does not replay the tap.
         */
        fun takePayload(intent: Intent?): String? {
            if (intent == null) return null
            if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
            val p = intent.getStringExtra(DigestNotifications.EXTRA_PAYLOAD) ?: return null
            intent.removeExtra(DigestNotifications.EXTRA_PAYLOAD)
            return p.takeIf { it.isNotEmpty() }
        }
    }
}
