package com.illunis.illunis_client

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.util.Log

/**
 * AudioRecord for whispered speech: 16 kHz mono PCM16, source
 * VOICE_RECOGNITION (falls back to MIC), AutomaticGainControl and
 * NoiseSuppressor turned off on the session. AOSP says NS must not be on for
 * VOICE_RECOGNITION; AGC is off because Dart normalises each utterance once
 * (client/lib/input/utterance_gain.dart). No AEC is attached.
 *
 * Reads on its own thread and hands chunks to [onChunk] on that thread.
 * Never logs or stores audio; logs carry the source and effect state only.
 * The caller must hold RECORD_AUDIO.
 */
class MicAudioRecorder(private val onChunk: (ByteArray) -> Unit) {

    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var agc: AutomaticGainControl? = null
    private var ns: NoiseSuppressor? = null

    /** Source and effect state, for `captureInfo`. Empty when stopped. */
    @Volatile var info: Map<String, Any> = emptyMap()
        private set

    /** Returns false (and holds nothing) when no source can be opened. */
    fun start(): Boolean {
        if (running) return true
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL, ENCODING)
        if (minBuf <= 0) return false
        val size = maxOf(minBuf, CHUNK_BYTES * 4)
        var source = "voice_recognition"
        val r = open(MediaRecorder.AudioSource.VOICE_RECOGNITION, size)
            ?: open(MediaRecorder.AudioSource.MIC, size).also { source = "mic" }
            ?: return false
        val session = r.audioSessionId
        agc = effectOff { if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(session) else null }
        ns = effectOff { if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(session) else null }
        try {
            r.startRecording()
        } catch (e: IllegalStateException) {
            release(r)
            return false
        }
        if (r.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            release(r)
            return false
        }
        info = mapOf(
            "source" to source,
            "agcAvailable" to AutomaticGainControl.isAvailable(),
            "agcEnabled" to (agc?.enabled ?: false),
            "nsAvailable" to NoiseSuppressor.isAvailable(),
            "nsEnabled" to (ns?.enabled ?: false),
        )
        Log.i(TAG, "mic: source=$source agc=${info["agcEnabled"]} ns=${info["nsEnabled"]}")
        record = r
        running = true
        thread = Thread({ loop(r) }, "illunis-mic").also { it.start() }
        return true
    }

    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        record?.let { release(it) }
        record = null
        info = emptyMap()
    }

    private fun loop(r: AudioRecord) {
        val buf = ByteArray(CHUNK_BYTES)
        while (running) {
            val n = r.read(buf, 0, buf.size)
            if (n < 0) break
            if (n > 0) onChunk(buf.copyOf(n))
        }
    }

    /** Creates the effect on the session (taking over any platform default) and disables it. */
    private fun <T : AudioEffect> effectOff(create: () -> T?): T? = try {
        create()?.also { it.enabled = false }
    } catch (e: RuntimeException) {
        // Effect refused by the device: nothing attached by us; logged as unavailable state.
        null
    }

    @SuppressLint("MissingPermission") // checked by MicCaptureService before start
    private fun open(source: Int, size: Int): AudioRecord? = try {
        val r = AudioRecord(source, SAMPLE_RATE, CHANNEL, ENCODING, size)
        if (r.state == AudioRecord.STATE_INITIALIZED) r else { r.release(); null }
    } catch (e: IllegalArgumentException) {
        null
    } catch (e: SecurityException) {
        null
    }

    private fun release(r: AudioRecord) {
        try { r.stop() } catch (_: IllegalStateException) {}
        r.release()
        agc?.release(); agc = null
        ns?.release(); ns = null
    }

    companion object {
        private const val TAG = "IllunisMic"
        const val SAMPLE_RATE = 16000
        private const val CHANNEL = AudioFormat.CHANNEL_IN_MONO
        private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT

        /** 100 ms of PCM16 mono at 16 kHz. */
        private const val CHUNK_BYTES = SAMPLE_RATE / 10 * 2
    }
}
