package dev.conest.conest

import android.app.Activity
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.AudioTrack.MODE_STREAM
import android.media.AudioManager.STREAM_VOICE_CALL
import android.os.Build
import java.util.concurrent.atomic.AtomicBoolean

/** Android device I/O. PCM is handed to Rust Opus workers through JNI; neither
 * audio callbacks nor codec/jitter work run on Flutter's UI isolate. */
internal class VoiceCallAudioEngine(
    private val activity: Activity,
    private val handle: Long,
    private val pushCapture: (Long, ShortArray, Int) -> Boolean,
    private val readPlayback: (Long, ShortArray, Int) -> Int,
    private val markFailed: (Long) -> Unit,
    private val onFailure: (String) -> Unit,
) {
    companion object {
        private const val SAMPLE_RATE = 48_000
        private const val FRAME_SAMPLES = 960
    }

    private val running = AtomicBoolean(false)
    private val focusHeld = AtomicBoolean(false)
    private val audioManager =
        activity.getSystemService(Activity.AUDIO_SERVICE) as AudioManager
    private var priorAudioMode: Int? = null
    private var priorSpeakerphoneOn: Boolean? = null
    private var priorCommunicationDevice: AudioDeviceInfo? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> focusHeld.set(true)
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> focusHeld.set(false)
            AudioManager.AUDIOFOCUS_LOSS -> {
                focusHeld.set(false)
                fail("Voice call ended because another app took audio focus.")
            }
        }
    }
    private var recorder: AudioRecord? = null
    private var track: AudioTrack? = null
    private var captureThread: Thread? = null
    private var playbackThread: Thread? = null

    fun start() {
        check(!running.get()) { "Voice audio is already active." }
        try {
            requestAudioFocus()
            val inputBufferBytes = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val outputBufferBytes = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            check(inputBufferBytes > 0 && outputBufferBytes > 0) {
                "This Android audio device does not support 48 kHz mono voice audio."
            }
            val input = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(inputBufferBytes, FRAME_SAMPLES * 4),
            )
            check(input.state == AudioRecord.STATE_INITIALIZED) {
                input.release()
                "Android could not initialize the microphone."
            }
            val output = AudioTrack(
                STREAM_VOICE_CALL,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(outputBufferBytes, FRAME_SAMPLES * 4),
                MODE_STREAM,
            )
            check(output.state == AudioTrack.STATE_INITIALIZED) {
                input.release()
                output.release()
                "Android could not initialize voice playback."
            }

            recorder = input
            track = output
            priorAudioMode = audioManager.mode
            priorSpeakerphoneOn = audioManager.isSpeakerphoneOn
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                priorCommunicationDevice = audioManager.communicationDevice
            }
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            input.startRecording()
            output.play()
            running.set(true)
            captureThread = Thread(::captureLoop, "conest-voice-microphone").apply {
                isDaemon = true
                start()
            }
            playbackThread = Thread(::playbackLoop, "conest-voice-playback").apply {
                isDaemon = true
                start()
            }
        } catch (error: Throwable) {
            stop()
            throw error
        }
    }

    private fun requestAudioFocus() {
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE,
            )
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(audioFocusListener)
                .setAcceptsDelayedFocusGain(false)
                .build()
            audioFocusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                audioFocusListener,
                STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
        check(result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            "Android audio focus is unavailable for this call."
        }
        focusHeld.set(true)
    }

    fun stop() {
        running.set(false)
        focusHeld.set(false)
        try { recorder?.stop() } catch (_: IllegalStateException) {}
        try { track?.stop() } catch (_: IllegalStateException) {}
        join(captureThread)
        join(playbackThread)
        captureThread = null
        playbackThread = null
        recorder?.release()
        track?.release()
        recorder = null
        track = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val previousDevice = priorCommunicationDevice
            if (previousDevice == null) {
                audioManager.clearCommunicationDevice()
            } else {
                audioManager.setCommunicationDevice(previousDevice)
            }
        } else {
            priorSpeakerphoneOn?.let { audioManager.isSpeakerphoneOn = it }
        }
        priorSpeakerphoneOn = null
        priorCommunicationDevice = null
        priorAudioMode?.let { audioManager.mode = it }
        priorAudioMode = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let(audioManager::abandonAudioFocusRequest)
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(audioFocusListener)
        }
    }

    fun setSpeakerphoneEnabled(enabled: Boolean) {
        check(running.get()) { "Voice audio is not active." }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val requestedType = if (enabled) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            } else {
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            }
            val device = audioManager.availableCommunicationDevices
                .firstOrNull { it.type == requestedType }
                ?: error(if (enabled) "Speaker output is unavailable." else "Earpiece output is unavailable.")
            check(audioManager.setCommunicationDevice(device)) {
                "Android rejected the requested voice output."
            }
        } else {
            @Suppress("DEPRECATION")
            run { audioManager.isSpeakerphoneOn = enabled }
        }
    }

    private fun captureLoop() {
        val input = recorder ?: return
        val pcm = ShortArray(FRAME_SAMPLES)
        while (running.get()) {
            val count = input.read(pcm, 0, pcm.size)
            if (count > 0) {
                if (focusHeld.get() && !pushCapture(handle, pcm, count)) {
                    fail("Android voice capture queue stopped.")
                    return
                }
            } else if (count == AudioRecord.ERROR_DEAD_OBJECT ||
                count == AudioRecord.ERROR_INVALID_OPERATION ||
                count == AudioRecord.ERROR_BAD_VALUE
            ) {
                fail("Android microphone stopped (code $count).")
                return
            } else if (count == 0) {
                try { Thread.sleep(3) } catch (_: InterruptedException) { return }
            }
        }
    }

    private fun playbackLoop() {
        val output = track ?: return
        val pcm = ShortArray(FRAME_SAMPLES)
        while (running.get()) {
            val count = if (focusHeld.get()) {
                readPlayback(handle, pcm, pcm.size)
            } else {
                0
            }
            if (count > 0) {
                val written = output.write(pcm, 0, count)
                if (written < 0) {
                    fail("Android voice playback stopped (code $written).")
                    return
                }
            } else {
                // Keep AudioTrack clocked through network jitter. Its blocking
                // write paces this thread at the device sample rate; polling
                // with sleeps lets the hardware stream underrun between Opus
                // frames and sounds choppy on Android.
                pcm.fill(0)
                val written = output.write(pcm, 0, pcm.size)
                if (written < 0) {
                    fail("Android voice playback stopped (code $written).")
                    return
                }
            }
        }
    }

    private fun fail(reason: String) {
        if (running.compareAndSet(true, false)) {
            markFailed(handle)
            try { recorder?.stop() } catch (_: IllegalStateException) {}
            try { track?.stop() } catch (_: IllegalStateException) {}
            activity.runOnUiThread { onFailure(reason) }
        }
    }

    private fun join(thread: Thread?) {
        if (thread == null || thread === Thread.currentThread()) return
        thread.interrupt()
        try { thread.join(500) } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }
}
