"""Select a Core Audio input and meter the same blocks delivered to the recognizer."""

import ctypes
import math
import os
import threading
import time
from contextlib import closing, contextmanager

import numpy as np
import sounddevice as sd


class InputDisconnected(RuntimeError):
    def __init__(self):
        super().__init__("麦克风已断开。重新连接后点「继续」。")


def core_audio_id(stream):
    # sounddevice exposes the PaStream pointer but doesn't bind this macOS extension.
    get_device = ctypes.CDLL(sd._libname).PaMacCore_GetStreamInputDevice
    get_device.argtypes = [ctypes.c_void_p]
    get_device.restype = ctypes.c_uint32
    return get_device(int(sd._ffi.cast("uintptr_t", stream._ptr)))


@contextmanager
def selected_stream(factory, **settings):
    selected = os.environ.get("ACADEMIC_NOTES_INPUT_ID")
    name = os.environ.get("ACADEMIC_NOTES_INPUT_NAME")
    if selected:
        expected = int(selected)
        candidates = [d for d in sd.query_devices() if d["max_input_channels"] and d["name"] == name]
    else:
        expected = None
        try:
            candidates = [sd.query_devices(kind="input")]
        except sd.PortAudioError:
            candidates = []

    for device in candidates:
        try:
            stream = factory(device=device["index"], **settings)
        except sd.PortAudioError:
            continue
        with closing(stream):
            # Equal display names are common with USB devices. Verify before starting any callbacks.
            device_id = core_audio_id(stream)
            if not device_id or (expected is not None and device_id != expected):
                continue
            try:
                stream.start()
            except sd.PortAudioError:
                raise RuntimeError("麦克风启动失败，请检查连接和麦克风权限。") from None
            try:
                yield stream, device_id, device["name"]
            finally:
                stream.stop()
            return
    raise RuntimeError("无法打开麦克风，请检查连接或切换设备。")


def meter_level(block):
    if isinstance(block, bytes):
        block = np.frombuffer(block, dtype="<i2").astype(np.float32) / 32768
    rms = math.sqrt(float(np.mean(block * block)))
    if not math.isfinite(rms) or rms <= 0.001:
        return 0.0
    return round(min(1.0, 1.0 + 20 * math.log10(rms) / 60), 4)


@contextmanager
def microphone(callback, emit, *, raw=False, finished_callback=None):
    latest = None
    done = threading.Event()

    def receive(data, frames, timing, status):
        nonlocal latest
        block = bytes(data) if raw else data[:, 0].copy()
        latest = (time.monotonic(), block)
        callback(block, status)

    def report_level():
        # Only the latest capture block matters to the meter, even while decoding an earlier sentence.
        previous = None
        while not done.wait(0.1):
            sample = latest
            level = meter_level(sample[1]) if sample and time.monotonic() - sample[0] < 0.3 else 0.0
            if level != previous:
                emit(level=level)
                previous = level

    factory = sd.RawInputStream if raw else sd.InputStream
    with selected_stream(factory, samplerate=16_000, blocksize=1_600, channels=1,
                         dtype="int16" if raw else "float32", callback=receive,
                         finished_callback=finished_callback) as (stream, device_id, device_name):
        emit(ready=True, inputID=device_id, inputName=device_name)
        reporter = threading.Thread(target=report_level, daemon=True)
        reporter.start()
        try:
            yield stream
        finally:
            done.set()
            reporter.join()
