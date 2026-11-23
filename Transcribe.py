import json
import os
import sys
import threading
from collections import deque
from queue import Empty, SimpleQueue


def emit(**event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def run():
    import numpy as np
    import sounddevice as sd
    from faster_whisper import WhisperModel
    from huggingface_hub.errors import LocalEntryNotFoundError

    stopped = threading.Event()

    def wait_for_stop():
        while chunk := os.read(sys.stdin.fileno(), 512):
            if b"\n" in chunk:
                break
        stopped.set()

    threading.Thread(target=wait_for_stop, daemon=True).start()
    options = dict(device="cpu", compute_type="int8", cpu_threads=4)
    try:
        model = WhisperModel("base", local_files_only=True, **options)
    except LocalEntryNotFoundError:
        model = WhisperModel("base", **options)
    if stopped.is_set():
        return

    incoming = SimpleQueue()
    utterance = []
    pre_roll = deque(maxlen=2)
    quiet_blocks = 0
    next_preview = 15
    hotwords = os.environ.get("ACADEMIC_NOTES_TERMS") or None

    def receive(audio, count, timing, status):
        incoming.put(audio[:, 0].copy())
        if stopped.is_set():
            raise sd.CallbackStop

    def decode():
        segments, _ = model.transcribe(
            np.concatenate(utterance), task="transcribe", beam_size=1,
            temperature=0, condition_on_previous_text=False,
            vad_filter=True, hotwords=hotwords,
        )
        return "".join(segment.text for segment in segments).strip()

    def finish_utterance():
        nonlocal quiet_blocks, next_preview
        if utterance:
            text = decode()
            if text:
                emit(final=text)
            else:
                emit(partial="")
            utterance.clear()
        quiet_blocks = 0
        next_preview = 15

    with sd.InputStream(
        samplerate=16_000, blocksize=1_600, channels=1, dtype="float32",
        callback=receive, finished_callback=lambda: incoming.put(None),
    ) as stream:
        emit(ready=True)
        while True:
            try:
                block = incoming.get(timeout=0.25)
            except Empty:
                if stopped.is_set() or not stream.active:
                    break
                continue
            if block is None:
                break
            quiet = np.sqrt(np.mean(block * block)) < 0.002
            if not utterance:
                if quiet:
                    pre_roll.append(block)
                    continue
                utterance.extend(pre_roll)
                pre_roll.clear()
            utterance.append(block)
            quiet_blocks = quiet_blocks + 1 if quiet else 0

            # Each block is 100 ms. Prefer a pause; bound the window for long speech.
            if quiet_blocks >= 7 or (len(utterance) >= 80 and quiet_blocks >= 2) or len(utterance) >= 150:
                finish_utterance()
            elif len(utterance) >= next_preview and incoming.empty() and not stopped.is_set():
                emit(partial=decode())
                next_preview = len(utterance) + 20
    finish_utterance()
    if not stopped.is_set():
        raise RuntimeError("麦克风已断开，请重新开始记录。")


if __name__ == "__main__":
    try:
        run()
    except Exception as error:
        emit(error=str(error))
        sys.exit(1)
