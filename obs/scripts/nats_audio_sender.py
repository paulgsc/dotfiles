"""
OBS Python Script - Audio Capture to NATS with Protobuf

Captures audio from Windows audio loopback and publishes to NATS using protobuf.

Requirements:
    pip install nats-py sounddevice numpy protobuf

Usage:
    1. Install VB-Audio Virtual Cable or similar loopback device
    2. Set OBS "Monitor and Output" to virtual cable
    3. Load this script in OBS (Tools → Scripts)
    4. Configure NATS URL in script properties
"""

import obspython as obs
import asyncio
import threading
import struct
import time
from queue import Queue
import sys

# Try to import NATS and audio libraries
try:
    import sounddevice as sd
    import numpy as np
    AUDIO_AVAILABLE = True
except ImportError:
    AUDIO_AVAILABLE = False
    print("[obs-nats] WARNING: sounddevice not available. Install: pip install sounddevice numpy")

try:
    from nats.aio.client import Client as NATS
    NATS_AVAILABLE = True
except ImportError:
    NATS_AVAILABLE = False
    print("[obs-nats] WARNING: NATS not available. Install: pip install nats-py")

try:
    from google.protobuf.message import Message as ProtoMessage
    PROTOBUF_AVAILABLE = True
    
    # Define inline protobuf message (avoids needing .proto compilation)
    from google.protobuf import descriptor_pb2
    from google.protobuf.descriptor import FieldDescriptor
    from google.protobuf.message import Message
    from google.protobuf.reflection import GeneratedProtocolMessageType
    
    # Create AudioChunk message dynamically
    class AudioChunk:
        """Minimal protobuf-compatible audio chunk"""
        def __init__(self):
            self.samples = b''
            self.sample_rate = 0
            self.channels = 0
            self.sequence = 0
            self.timestamp_ms = 0
        
        def SerializeToString(self):
            """Manual protobuf encoding for minimal overhead"""
            buf = bytearray()
            
            # Field 1: bytes samples (wire type 2 = length-delimited)
            if self.samples:
                buf.extend(self._encode_tag(1, 2))
                buf.extend(self._encode_varint(len(self.samples)))
                buf.extend(self.samples)
            
            # Field 2: uint32 sample_rate (wire type 0 = varint)
            if self.sample_rate:
                buf.extend(self._encode_tag(2, 0))
                buf.extend(self._encode_varint(self.sample_rate))
            
            # Field 3: uint32 channels (wire type 0 = varint)
            if self.channels:
                buf.extend(self._encode_tag(3, 0))
                buf.extend(self._encode_varint(self.channels))
            
            # Field 4: uint64 sequence (wire type 0 = varint)
            if self.sequence:
                buf.extend(self._encode_tag(4, 0))
                buf.extend(self._encode_varint(self.sequence))
            
            # Field 5: uint64 timestamp_ms (wire type 0 = varint)
            if self.timestamp_ms:
                buf.extend(self._encode_tag(5, 0))
                buf.extend(self._encode_varint(self.timestamp_ms))
            
            return bytes(buf)
        
        @staticmethod
        def _encode_tag(field_number, wire_type):
            """Encode protobuf tag (field number + wire type)"""
            return AudioChunk._encode_varint((field_number << 3) | wire_type)
        
        @staticmethod
        def _encode_varint(value):
            """Encode varint (protobuf variable-length integer)"""
            buf = bytearray()
            while value > 0x7f:
                buf.append((value & 0x7f) | 0x80)
                value >>= 7
            buf.append(value & 0x7f)
            return buf
    
except ImportError:
    PROTOBUF_AVAILABLE = False
    print("[obs-nats] WARNING: protobuf not available. Install: pip install protobuf")

# Configuration
NATS_URL = "nats://nixos.local:4222"
NATS_SUBJECT_AUDIO = "audio.chunk"
NATS_SUBJECT_STATUS = "obs.status"
SAMPLE_RATE = 48000
CHANNELS = 2
CHUNK_SIZE = 4096  # samples per chunk

# State
audio_thread = None
nats_thread = None
audio_queue = Queue(maxsize=100)
recording_active = False
streaming_active = False
nc = None


def log(message):
    """Thread-safe logging"""
    print(f"[obs-nats] {message}")


def is_capture_active():
    """Return True if either recording or streaming is active"""
    return recording_active or streaming_active


# #######################
# AUDIO CAPTURE
# #######################
class AudioCapture:
    def __init__(self, device_index=None):
        self.device_index = device_index
        self.stream = None
        self.running = False
        self._chunk_counter = 0  # counts chunks for logging and sequence
        self._start_time = None
        self._sent_format = False  # track if we've sent format info
    
    def audio_callback(self, indata, frames, time_info, status):
        """Called by sounddevice for each audio chunk"""
        if status:
            log(f"Audio callback status: {status}")
        
        if is_capture_active() and not audio_queue.full():
            # Convert float32 numpy array to bytes
            # indata shape: (frames, channels)
            audio_bytes = indata.tobytes()
            
            # Create protobuf message
            chunk = AudioChunk()
            chunk.samples = audio_bytes
            chunk.sequence = self._chunk_counter
            
            # Include format info in first chunk or periodically (every 100 chunks)
            # This helps if receiver reconnects
            if not self._sent_format or self._chunk_counter % 100 == 0:
                chunk.sample_rate = SAMPLE_RATE
                chunk.channels = CHANNELS
                chunk.timestamp_ms = int(time.time() * 1000)
                self._sent_format = True
            
            # Serialize and queue
            try:
                serialized = chunk.SerializeToString()
                audio_queue.put(serialized)
            except Exception as e:
                log(f"ERROR serializing chunk: {e}")
            
            # Periodic logging (every 50 chunks ≈ 1 second at 48kHz/4096 samples)
            self._chunk_counter += 1
            if self._chunk_counter % 50 == 0:
                elapsed = time.time() - self._start_time if self._start_time else 0
                queue_size = audio_queue.qsize()
                log(f"Captured {self._chunk_counter} chunks ({elapsed:.1f}s) | Queue: {queue_size}/100")
    
    def start(self):
        """Start audio capture"""
        if not AUDIO_AVAILABLE:
            log("ERROR: sounddevice not available")
            return False
        
        if not PROTOBUF_AVAILABLE:
            log("ERROR: protobuf not available")
            return False
        
        try:
            self.stream = sd.InputStream(
                device=self.device_index,
                channels=CHANNELS,
                samplerate=SAMPLE_RATE,
                blocksize=CHUNK_SIZE,
                callback=self.audio_callback,
                dtype='float32'
            )
            self.stream.start()
            self.running = True
            self._start_time = time.time()
            self._chunk_counter = 0
            self._sent_format = False
            log(f"Audio capture started (device={self.device_index}, rate={SAMPLE_RATE}Hz, {CHANNELS}ch)")
            return True
        except Exception as e:
            log(f"ERROR starting audio capture: {e}")
            return False
    
    def stop(self):
        """Stop audio capture"""
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.running = False
            log("Audio capture stopped")


# #######################
# NATS PUBLISHER WITH RETRY BACKOFF
# #######################
async def nats_publisher():
    """Async NATS publisher loop with exponential backoff"""
    global nc
    
    if not NATS_AVAILABLE:
        log("ERROR: NATS client not available")
        return
    
    # Retry configuration
    MAX_RETRIES = 5
    INITIAL_BACKOFF = 1.0  # seconds
    MAX_BACKOFF = 60.0  # seconds
    retry_count = 0
    backoff = INITIAL_BACKOFF
    
    while retry_count < MAX_RETRIES:
        try:
            # Connect to NATS
            nc = NATS()
            await nc.connect(NATS_URL)
            log(f"Connected to NATS at {NATS_URL}")
            
            # Reset retry counter on successful connection
            retry_count = 0
            backoff = INITIAL_BACKOFF
            
            # Publish initial status
            try:
                await nc.publish(NATS_SUBJECT_STATUS, b"idle")
            except Exception as e:
                log(f"Failed to publish initial status: {e}")
            
            chunks_published = 0
            last_log_time = time.time()
            
            # Main publish loop
            while True:
                try:
                    # Get audio from queue (blocking with timeout)
                    serialized_chunk = audio_queue.get(timeout=0.1)
                    
                    # Publish to NATS
                    await nc.publish(NATS_SUBJECT_AUDIO, serialized_chunk)
                    chunks_published += 1
                    
                    # Log publish stats every 5 seconds
                    now = time.time()
                    if now - last_log_time >= 5.0:
                        log(f"Published {chunks_published} chunks to NATS")
                        last_log_time = now
                    
                except:
                    # Queue timeout - no audio available, just continue
                    await asyncio.sleep(0.01)
            
        except Exception as e:
            retry_count += 1
            
            if retry_count >= MAX_RETRIES:
                log(f"NATS connection failed after {MAX_RETRIES} attempts. Giving up.")
                log(f"Last error: {e}")
                log("Please check NATS server and restart OBS script to retry.")
                break
            
            # Log with backoff info
            log(f"NATS connection error (attempt {retry_count}/{MAX_RETRIES}): {e}")
            log(f"Retrying in {backoff:.1f} seconds...")
            
            # Wait with exponential backoff
            await asyncio.sleep(backoff)
            
            # Increase backoff for next retry (exponential)
            backoff = min(backoff * 2, MAX_BACKOFF)
        
        finally:
            # Clean up connection
            if nc:
                try:
                    await nc.close()
                except:
                    pass
                nc = None
    
    log("NATS publisher thread terminated")


def nats_thread_func():
    """Thread wrapper for async NATS publisher"""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(nats_publisher())
    except Exception as e:
        log(f"NATS thread error: {e}")
    finally:
        loop.close()


# #######################
# OBS EVENT HANDLERS
# #######################
def on_recording_started():
    """Called when OBS starts recording"""
    global recording_active
    recording_active = True
    log("Recording started - audio capture active")
    
    # Publish status to NATS
    if nc:
        try:
            loop = asyncio.get_event_loop()
            asyncio.run_coroutine_threadsafe(
                nc.publish(NATS_SUBJECT_STATUS, b"recording"),
                loop
            )
        except:
            pass


def on_recording_stopped():
    """Called when OBS stops recording"""
    global recording_active
    recording_active = False
    log("Recording stopped" + (" - audio capture still active (streaming)" if streaming_active else ""))
    
    # Publish status to NATS
    if nc:
        try:
            loop = asyncio.get_event_loop()
            asyncio.run_coroutine_threadsafe(
                nc.publish(NATS_SUBJECT_STATUS, b"stopped"),
                loop
            )
        except:
            pass


def on_streaming_started():
    """Called when OBS starts streaming"""
    global streaming_active
    streaming_active = True
    log("Streaming started - audio capture active")
    
    # Publish status to NATS
    if nc:
        try:
            loop = asyncio.get_event_loop()
            asyncio.run_coroutine_threadsafe(
                nc.publish(NATS_SUBJECT_STATUS, b"streaming"),
                loop
            )
        except:
            pass


def on_streaming_stopped():
    """Called when OBS stops streaming"""
    global streaming_active
    streaming_active = False
    log("Streaming stopped" + (" - audio capture still active (recording)" if recording_active else ""))
    
    # Publish status to NATS
    if nc:
        try:
            loop = asyncio.get_event_loop()
            asyncio.run_coroutine_threadsafe(
                nc.publish(NATS_SUBJECT_STATUS, b"stopped"),
                loop
            )
        except:
            pass


def on_event(event):
    """OBS frontend event callback"""
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED:
        on_recording_started()
    elif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED:
        on_recording_stopped()
    elif event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED:
        on_streaming_started()
    elif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED:
        on_streaming_stopped()


# #######################
# SCRIPT LIFECYCLE
# #######################
def script_load(settings):
    """Called when script is loaded"""
    global audio_thread, nats_thread, audio_capture
    
    log("Script loaded")
    
    # Check dependencies
    if not AUDIO_AVAILABLE:
        log("ERROR: Install sounddevice: pip install sounddevice numpy")
    if not NATS_AVAILABLE:
        log("ERROR: Install NATS: pip install nats-py")
    if not PROTOBUF_AVAILABLE:
        log("ERROR: Install protobuf: pip install protobuf")
    
    if not (AUDIO_AVAILABLE and NATS_AVAILABLE and PROTOBUF_AVAILABLE):
        return
    
    # Register OBS event callback
    obs.obs_frontend_add_event_callback(on_event)
    
    # Start audio capture
    audio_capture = AudioCapture()
    audio_capture.start()
    
    # Start NATS publisher thread
    nats_thread = threading.Thread(target=nats_thread_func, daemon=True)
    nats_thread.start()
    
    log("Audio capture and NATS publisher started")
    log(f"Protobuf encoding: Minimal overhead (~10 bytes/chunk)")


def script_unload():
    """Called when script is unloaded"""
    global audio_capture, recording_active, streaming_active
    
    recording_active = False
    streaming_active = False
    
    if audio_capture:
        audio_capture.stop()
    
    log("Script unloaded")


def script_properties():
    """Script properties (shown in OBS UI)"""
    props = obs.obs_properties_create()
    
    obs.obs_properties_add_text(props, "nats_url", "NATS URL", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "audio_subject", "Audio Subject", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "status_subject", "Status Subject", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_int(props, "sample_rate", "Sample Rate", 8000, 96000, 1000)
    obs.obs_properties_add_int(props, "channels", "Channels", 1, 2, 1)
    
    # Audio device selection
    if AUDIO_AVAILABLE:
        device_list = obs.obs_properties_add_list(
            props, "audio_device", "Audio Device",
            obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT
        )
        
        try:
            devices = sd.query_devices()
            for idx, device in enumerate(devices):
                if device['max_input_channels'] > 0:
                    obs.obs_property_list_add_int(
                        device_list,
                        f"{device['name']} ({device['max_input_channels']} ch)",
                        idx
                    )
        except:
            pass
    
    return props


def script_description():
    """Script description shown in OBS"""
    return """<h2>OBS Audio to NATS Publisher (Protobuf)</h2>
    
<p>Captures audio from system loopback and publishes to NATS in real-time using protobuf encoding.</p>
<p><strong>Now captures during both recording AND streaming!</strong></p>

<h3>Setup:</h3>
<ol>
    <li>Install dependencies: <code>pip install nats-py sounddevice numpy protobuf</code></li>
    <li>Install VB-Audio Virtual Cable (or similar loopback device)</li>
    <li>In OBS Audio Settings, set "Monitor and Output" to virtual cable</li>
    <li>Configure NATS URL below</li>
    <li>Select the virtual cable as audio device</li>
</ol>

<h3>Protobuf Format:</h3>
<p>Each audio chunk is encoded as a minimal protobuf message with:</p>
<ul>
    <li><strong>samples:</strong> Raw float32 audio bytes</li>
    <li><strong>sequence:</strong> Chunk counter for drop detection</li>
    <li><strong>sample_rate/channels:</strong> Sent in first chunk and every 100 chunks</li>
    <li><strong>Overhead:</strong> ~3 bytes per chunk (0.02%)</li>
</ul>

<p><strong>Status:</strong></p>
<ul>
    <li>sounddevice: """ + ("✅ Available" if AUDIO_AVAILABLE else "❌ Not installed") + """</li>
    <li>NATS client: """ + ("✅ Available" if NATS_AVAILABLE else "❌ Not installed") + """</li>
    <li>protobuf: """ + ("✅ Available" if PROTOBUF_AVAILABLE else "❌ Not installed") + """</li>
</ul>
"""


def script_update(settings):
    """Called when script settings are updated"""
    global NATS_URL, NATS_SUBJECT_AUDIO, NATS_SUBJECT_STATUS, SAMPLE_RATE, CHANNELS
    
    NATS_URL = obs.obs_data_get_string(settings, "nats_url") or NATS_URL
    NATS_SUBJECT_AUDIO = obs.obs_data_get_string(settings, "audio_subject") or NATS_SUBJECT_AUDIO
    NATS_SUBJECT_STATUS = obs.obs_data_get_string(settings, "status_subject") or NATS_SUBJECT_STATUS
    SAMPLE_RATE = obs.obs_data_get_int(settings, "sample_rate") or SAMPLE_RATE
    CHANNELS = obs.obs_data_get_int(settings, "channels") or CHANNELS


def script_defaults(settings):
    """Set default values for script settings"""
    obs.obs_data_set_default_string(settings, "nats_url", NATS_URL)
    obs.obs_data_set_default_string(settings, "audio_subject", NATS_SUBJECT_AUDIO)
    obs.obs_data_set_default_string(settings, "status_subject", NATS_SUBJECT_STATUS)
    obs.obs_data_set_default_int(settings, "sample_rate", SAMPLE_RATE)
    obs.obs_data_set_default_int(settings, "channels", CHANNELS)

