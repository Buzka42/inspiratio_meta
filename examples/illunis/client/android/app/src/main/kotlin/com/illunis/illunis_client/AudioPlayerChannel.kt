package com.illunis.illunis_client

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * MethodChannel `illunis/audio_player`, the Dart side is
 * client/lib/output/kokoro/player.dart (AudioTrackPlayer).
 *
 * Plays 16-bit mono PCM through one streaming AudioTrack (USAGE_ASSISTANT,
 * CONTENT_TYPE_SPEECH). No recording, no foreground service, no audio focus.
 * Never logs samples.
 *
 * Methods:
 *  - `init` {sampleRate}  creates the track (released first if the rate changed)
 *  - `write` bytes        little-endian Int16 PCM; answers "played" when the last
 *                         sample is out, or "stopped" after `stop`
 *  - `stop`               pause + flush now, release right after the current write
 *  - `dispose`            stop and forget the rate
 *
 * Error codes: `bad_args`, `not_initialised`, `internal`.
 *
 * Threading: writes run one at a time on [worker]; only `stop` touches the
 * track from the main thread (pause/flush, which unblocks a blocking write).
 * The track is created and released on [worker] only.
 */
class AudioPlayerChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile private var track: AudioTrack? = null
    @Volatile private var generation = 0
    private var sampleRate = 0 // main thread

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "init" -> {
                    val rate = call.argument<Int>("sampleRate")
                    if (rate == null || rate !in 8000..96000) {
                        result.error("bad_args", "sampleRate out of range", null)
                        return
                    }
                    sampleRate = rate
                    worker.execute {
                        val ok = try { ensureTrack(rate); true } catch (e: Exception) { false }
                        main.post {
                            if (ok) result.success(null) else result.error("internal", "audio track failed", null)
                        }
                    }
                }
                "write" -> {
                    val bytes = call.arguments as? ByteArray
                    if (bytes == null || bytes.size % 2 != 0) {
                        result.error("bad_args", "expected Int16 PCM bytes", null)
                        return
                    }
                    if (sampleRate == 0) {
                        result.error("not_initialised", "init first", null)
                        return
                    }
                    val gen = generation
                    val rate = sampleRate
                    worker.execute {
                        val answer = try {
                            if (writeAndDrain(bytes, rate, gen)) "played" else "stopped"
                        } catch (e: Exception) {
                            null
                        }
                        main.post {
                            if (answer == null) result.error("internal", "audio write failed", null)
                            else result.success(answer)
                        }
                    }
                }
                "stop" -> {
                    stopNow()
                    result.success(null)
                }
                "dispose" -> {
                    stopNow()
                    sampleRate = 0
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("internal", "audio call failed", null)
        }
    }

    /** Main thread. Cancels the current and queued-before-now writes. */
    private fun stopNow() {
        generation++
        track?.let {
            try {
                it.pause()
                it.flush()
            } catch (e: IllegalStateException) {
                // Not initialised or already released.
            }
        }
        worker.execute { releaseTrack() }
    }

    /** Worker thread. */
    private fun ensureTrack(rate: Int): AudioTrack {
        track?.let { if (it.sampleRate == rate && it.state == AudioTrack.STATE_INITIALIZED) return it }
        releaseTrack()
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) throw IllegalStateException("bad buffer size")
        val usage = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioAttributes.USAGE_ASSISTANT
        } else {
            AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY
        }
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(usage)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(min * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            t.release()
            throw IllegalStateException("track not initialised")
        }
        track = t
        return t
    }

    /** Worker thread. */
    private fun releaseTrack() {
        val t = track ?: return
        track = null
        try {
            t.release()
        } catch (e: IllegalStateException) {
            // Already gone.
        }
    }

    /**
     * Worker thread. Writes [bytes] in chunks, then stop() so the tail plays
     * even below the start threshold, and waits for the head to reach the end.
     * Returns false when `stop` came first.
     */
    private fun writeAndDrain(bytes: ByteArray, rate: Int, gen: Int): Boolean {
        if (gen != generation) return false
        val t = ensureTrack(rate)
        t.play()
        val chunk = CHUNK_FRAMES * 2
        var off = 0
        while (off < bytes.size) {
            if (gen != generation) return false
            val n = t.write(bytes, off, minOf(chunk, bytes.size - off), AudioTrack.WRITE_BLOCKING)
            if (n < 0) throw IllegalStateException("write error")
            if (n == 0 && gen != generation) return false
            off += n
        }
        if (gen != generation) return false
        t.stop() // streaming: plays what is queued, then stops
        val frames = bytes.size / 2
        val deadline = SystemClock.elapsedRealtime() + frames * 1000L / rate + DRAIN_SLACK_MS
        var last = -1
        while (gen == generation && SystemClock.elapsedRealtime() < deadline) {
            val head = try { t.playbackHeadPosition } catch (e: IllegalStateException) { return false }
            if (head >= frames || head < last) break // reached the end, or reset after draining
            last = head
            Thread.sleep(POLL_MS)
        }
        return gen == generation
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        generation++
        track?.let { try { it.pause(); it.flush() } catch (e: IllegalStateException) { } }
        worker.execute { releaseTrack() }
        worker.shutdown()
    }

    companion object {
        const val CHANNEL = "illunis/audio_player"
        private const val CHUNK_FRAMES = 2048
        private const val POLL_MS = 10L
        private const val DRAIN_SLACK_MS = 1000L
    }
}
