import json
import os
import sys
import threading
from collections import deque
from pathlib import Path
from queue import Empty, SimpleQueue

from opencc import OpenCC

from AudioInput import InputDisconnected, microphone

to_simplified = OpenCC("t2s")
output_lock = threading.Lock()

MODEL_REVISIONS = {
    "qwen-1.7b": "22c8abe6a6772122dda5905967d7496d1d3e8dd2",
    "qwen-0.6b": "83ce2a8ef9a382d2ba2209aab383bc51fff366f5",
}
PAUSE_BLOCKS = 15  # 1.5 seconds at 100 ms per microphone block.


def emit(**event):
    for key in ("partial", "final"):
        if key in event:
            event[key] = to_simplified.convert(event[key])
    with output_lock:
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

    def decode(samples, *, preview=False):
        audio = (samples, 16_000)
        options = dict(context=terms, max_new_tokens=min(512, 16 + len(samples) // 800))
        # Automatic detection can return no speech even when a glossary is set.
        result = session.transcribe(audio, language=None, **options)
        text = result.text.strip()
        if preview or not text or result.language != "English":
            return text

        # A Mandarin hint can recover Chinese phrases omitted inside English speech.
        hinted = session.transcribe(audio, language="Chinese", **options).text.strip()
        if any("\u3400" <= ch <= "\u9fff" for ch in hinted) and any(
            ch.isascii() and ch.isalpha() for ch in hinted
        ):
            return hinted
        return text

    return decode


def run():
    engine = os.environ.get("ACADEMIC_NOTES_ENGINE") or "qwen-1.7b"
    if engine == "aliyun-api":
        import CloudASR
        return CloudASR.run()
    if engine not in (*MODEL_REVISIONS, "firered-aed", "r2t2-8bit"):
        raise ValueError("转写引擎无效，请在设置中重选。")

    import numpy as np
    import sounddevice as sd

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
    streamer = None
    if engine == "r2t2-8bit":
        from R2T2 import load_streamer
        streamer = load_streamer(os.environ.get("ACADEMIC_NOTES_TERMS", ""))
    elif engine == "firered-aed":
        from FireRedASR import load_transcriber as load_firered
        decode = load_firered()
    else:
        decode = load_transcriber(engine)
    loading.clear()
    if stopped.is_set():
        return

    incoming = SimpleQueue()
    utterance = []
    recent_power = deque(maxlen=30)  # Three seconds of local acoustic context.
    quiet_blocks = 0
    next_preview = 14
    streamed_blocks = 0
    cut_awaiting_pause = False

    def receive(block, status):
        incoming.put(block)
        if stopped.is_set():
            raise sd.CallbackStop

    def finish_utterance(*, continues=False, pause_boundary=False):
        nonlocal next_preview, streamed_blocks
        event = {}
        if utterance:
            if streamer is not None:
                tail = utterance[streamed_blocks:]
                text = streamer.finish(np.concatenate(tail) if tail else None)
            else:
                text = decode(np.concatenate(utterance))
            if text:
                event["final"] = text
                if continues:
                    event["continues"] = True
            else:
                event["partial"] = ""
        if pause_boundary:
            event["pauseBoundary"] = True
        if event:
            emit(**event)
        utterance.clear()
        streamed_blocks = 0
        next_preview = 14
        return "final" in event

    with microphone(receive, emit, finished_callback=lambda: incoming.put(None)) as stream:
        while True:
            try:
                block = incoming.get(timeout=0.25)
            except Empty:
                if stopped.is_set() or not stream.active:
                    break
                continue
            if block is None:
                break
            digital_silence = not np.any(block)
            power = float(np.mean(block * block))
            recent_power.append(power)
            # A 10 dB drop suggests a pause. It can end a window but cannot discard audio.
            quiet = power <= 0.1 * max(recent_power)
            quiet_blocks = quiet_blocks + 1 if quiet else 0
            if not quiet:
                cut_awaiting_pause = False
            if not utterance and digital_silence:
                if cut_awaiting_pause and quiet_blocks >= PAUSE_BLOCKS:
                    emit(pauseBoundary=True)
                    cut_awaiting_pause = False
                continue
            utterance.append(block)

            if quiet_blocks == PAUSE_BLOCKS:
                # FireRed usually omits punctuation; use a sustained pause as its endpoint.
                finish_utterance(pause_boundary=cut_awaiting_pause or engine == "firered-aed")
                cut_awaiting_pause = False
                continue
            # From 20 s, look for a half-second pause before reaching the 24 s model window.
            if (len(utterance) >= 200 and quiet_blocks >= 5) or len(utterance) >= 240:
                cut_awaiting_pause = finish_utterance(continues=True)
                continue
            if digital_silence or not incoming.empty() or stopped.is_set():
                continue
            if streamer is not None and len(utterance) - streamed_blocks >= 4:
                text = streamer.feed(np.concatenate(utterance[streamed_blocks:]))
                streamed_blocks = len(utterance)
                if text:
                    emit(partial=text)
            elif engine in MODEL_REVISIONS and len(utterance) >= next_preview:
                text = decode(np.concatenate(utterance), preview=True)
                if text:
                    emit(partial=text)
                next_preview = len(utterance) + 20
    finish_utterance()
    if not stopped.is_set():
        raise InputDisconnected()


def run_worker(worker):
    try:
        worker()
    except Exception as error:
        details = {"inputDisconnected": True} if isinstance(error, InputDisconnected) else {}
        emit(error=str(error), **details)
        sys.exit(1)


if __name__ == "__main__":
    run_worker(run)
