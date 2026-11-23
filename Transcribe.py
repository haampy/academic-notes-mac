import json
import os
import sys
import threading
from collections import deque
from pathlib import Path
from queue import Empty, SimpleQueue

from opencc import OpenCC

to_simplified = OpenCC("t2s")

MODEL_REVISIONS = {
    "qwen-1.7b": "22c8abe6a6772122dda5905967d7496d1d3e8dd2",
    "qwen-0.6b": "83ce2a8ef9a382d2ba2209aab383bc51fff366f5",
}


def emit(**event):
    for key in ("partial", "final"):
        if key in event:
            event[key] = to_simplified.convert(event[key])
    print(json.dumps(event, ensure_ascii=False), flush=True)


def model_directory(engine):
    from huggingface_hub import snapshot_download, try_to_load_from_cache

    name = f"qwen3-asr-{engine.removeprefix('qwen-')}-8bit"
    repo = f"moona3k/mlx-{name}"
    revision = MODEL_REVISIONS[engine]
    directory = Path.home() / "Library/Application Support/AcademicNotes/models" / name
    files = ("config.json", "quantization_config.json", "weights.safetensors",
             "tokenizer_config.json", "vocab.json", "merges.txt")
    cached = try_to_load_from_cache(repo, "weights.safetensors", revision=revision)
    candidates = [directory]
    if isinstance(cached, str):
        candidates.append(Path(cached).parent)
    for candidate in candidates:
        if all((candidate / filename).is_file() for filename in files):
            return candidate
    return Path(snapshot_download(repo, local_dir=directory, revision=revision, allow_patterns=list(files)))


def load_transcriber(engine="qwen-1.7b"):
    import mlx.core as mx
    from mlx_qwen3_asr import Session

    directory = model_directory(engine)
    mx.set_cache_limit(256 * 1024**2)
    session = Session(model=str(directory))
    terms = os.environ.get("ACADEMIC_NOTES_TERMS", "")

    def decode(samples):
        # A Mandarin hint helps retain Chinese phrases inside English academic speech.
        result = session.transcribe((samples, 16_000), language="Chinese", context=terms,
                                    max_new_tokens=min(512, 16 + len(samples) // 800))
        return result.text.strip()

    return decode


def run():
    engine = os.environ.get("ACADEMIC_NOTES_ENGINE") or "qwen-1.7b"
    if engine == "aliyun-api":
        import CloudASR
        return CloudASR.run()
    if engine not in MODEL_REVISIONS:
        raise ValueError("未知的转写引擎，请在设置中重新选择。")

    import numpy as np
    import sounddevice as sd
    import webrtcvad

    stopped = threading.Event()
    loading = threading.Event()
    loading.set()

    def wait_for_stop():
        while chunk := os.read(sys.stdin.fileno(), 512):
            if b"\n" in chunk:
                break
        stopped.set()
        if loading.is_set():
            # No audio exists yet. Exiting the worker also cancels any download threads.
            os._exit(0)

    threading.Thread(target=wait_for_stop, daemon=True).start()
    decode = load_transcriber(engine)
    loading.clear()
    if stopped.is_set():
        return

    incoming = SimpleQueue()
    vad = webrtcvad.Vad(2)
    utterance = []
    pre_roll = deque(maxlen=2)
    quiet_blocks = 0
    voiced_blocks = 0
    noise_level = 0.0
    next_preview = 14

    def receive(audio, count, timing, status):
        incoming.put(audio[:, 0].copy())
        if stopped.is_set():
            raise sd.CallbackStop

    def finish_utterance():
        nonlocal quiet_blocks, voiced_blocks, next_preview
        if voiced_blocks >= 2:
            end = len(utterance) - max(0, quiet_blocks - 2)
            text = decode(np.concatenate(utterance[:end]))
            if text:
                emit(final=text)
            else:
                emit(partial="")
        utterance.clear()
        quiet_blocks = voiced_blocks = 0
        next_preview = 14

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
            pcm = (np.clip(block, -1, 1) * 32767).astype("<i2")
            speech_frames = sum(vad.is_speech(frame.tobytes(), 16_000) for frame in pcm.reshape(-1, 320))
            level = np.sqrt(np.mean(block * block))
            if speech_frames < 2:
                noise_level = 0.85 * noise_level + 0.15 * level
            quiet = speech_frames < 2 or level < max(0.0005, noise_level * 1.3)
            if not utterance:
                if quiet:
                    pre_roll.append(block)
                    continue
                utterance.extend(pre_roll)
                pre_roll.clear()
            utterance.append(block)
            quiet_blocks = quiet_blocks + 1 if quiet else 0
            if not quiet:
                voiced_blocks += 1

            # Each block is 100 ms. Prefer a pause; bound the window for long speech.
            if quiet_blocks >= 9 or (len(utterance) >= 120 and quiet_blocks >= 3) or len(utterance) >= 240:
                finish_utterance()
            elif voiced_blocks >= 2 and len(utterance) >= next_preview and incoming.empty() and not stopped.is_set():
                text = decode(np.concatenate(utterance))
                if text:
                    emit(partial=text)
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
