package com.illunis.illunis_client

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Bridge from [MicCaptureService] to the EventChannel `illunis/mic/pcm`
 * owned by [MicChannelHandler]. Sends always happen on the main thread.
 * Chunks are dropped while Dart is not listening; nothing is buffered or kept.
 */
object MicPcmBus {
    private val main = Handler(Looper.getMainLooper())

    @Volatile var sink: EventChannel.EventSink? = null

    /** Set by the service while capturing (source and effect state). */
    @Volatile var info: Map<String, Any> = emptyMap()

    fun send(chunk: ByteArray) {
        if (sink == null) return
        main.post { sink?.success(chunk) }
    }

    /** Fixed codes only, for example `mic_unavailable`. */
    fun fail(code: String) {
        main.post { sink?.error(code, "capture failed", null) }
    }
}
