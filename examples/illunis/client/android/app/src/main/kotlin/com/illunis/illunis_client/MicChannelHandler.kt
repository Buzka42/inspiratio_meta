package com.illunis.illunis_client

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `illunis/mic` and EventChannel `illunis/mic/pcm` (PCM16
 * chunks from [MicCaptureService] through [MicPcmBus]). Dart side:
 * client/lib/input/mic_channel.dart (not wired into main.dart yet).
 *
 * Methods:
 *  - `requestPermission` -> "granted" | "denied" (RECORD_AUDIO runtime request)
 *  - `startCapture`      starts [MicCaptureService]; refused unless the activity
 *                        is in the foreground (a user interaction) and
 *                        RECORD_AUDIO is granted
 *  - `stopCapture`
 *  - `captureInfo`       -> {source, agcAvailable, agcEnabled, nsAvailable,
 *                        nsEnabled} while capturing, else {}
 *
 * Error codes (no details, no stack): `mic_denied`, `not_foreground`,
 * `busy`, `internal`; on the PCM stream `mic_unavailable`.
 */
class MicChannelHandler(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val pcm = EventChannel(messenger, PCM_CHANNEL)
    private var pendingPermission: MethodChannel.Result? = null

    /** Set by MainActivity from onResume/onPause. */
    var inForeground = false

    init {
        channel.setMethodCallHandler(this)
        pcm.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                MicPcmBus.sink = events
            }

            override fun onCancel(arguments: Any?) {
                MicPcmBus.sink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestPermission" -> requestPermission(result)
                "startCapture" -> startCapture(result)
                "stopCapture" -> {
                    activity.startService(
                        Intent(activity, MicCaptureService::class.java)
                            .setAction(MicCaptureService.ACTION_STOP),
                    )
                    result.success(null)
                }
                "captureInfo" -> result.success(MicPcmBus.info)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("internal", "mic call failed", null)
        }
    }

    private fun granted() =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (granted()) {
            result.success("granted")
            return
        }
        if (pendingPermission != null) {
            result.error("busy", "a permission request is already open", null)
            return
        }
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_CODE)
    }

    /** Forwarded from MainActivity.onRequestPermissionsResult. Returns true if handled. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val r = pendingPermission ?: return true
        pendingPermission = null
        val ok = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        r.success(if (ok) "granted" else "denied")
        return true
    }

    private fun startCapture(result: MethodChannel.Result) {
        // The user-interaction rule: only while the activity is visible, which
        // is how a notification tap or an in-app button reaches here.
        if (!inForeground) {
            result.error("not_foreground", "capture starts only from the open app", null)
            return
        }
        if (!granted()) {
            result.error("mic_denied", "microphone permission is not granted", null)
            return
        }
        val i = Intent(activity, MicCaptureService::class.java).setAction(MicCaptureService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(i)
        } else {
            activity.startService(i)
        }
        result.success(null)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pcm.setStreamHandler(null)
        MicPcmBus.sink = null
        pendingPermission?.error("internal", "engine detached", null)
        pendingPermission = null
    }

    companion object {
        const val CHANNEL = "illunis/mic"
        const val PCM_CHANNEL = "illunis/mic/pcm"
        const val REQUEST_CODE = 4101
    }
}
