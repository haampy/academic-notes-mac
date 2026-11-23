"""Local Confucius4-R2T2 streaming ASR using the existing MLX Qwen runtime."""

import mlx.core as mx
import numpy as np
from mlx_qwen3_asr.audio import compute_features
from mlx_qwen3_asr.generate import GenerationConfig, generate
from mlx_qwen3_asr.load_models import load_model
from mlx_qwen3_asr.tokenizer import Tokenizer

from LocalModels import snapshot


REPO = "mlx-community/Confucius4-R2T2-8bit"
REVISION = "2d6d997c3e09c65a65b1b2576b6b9b7728df8eab"
FILES = ("config.json", "model.safetensors", "vocab.json", "merges.txt",
         "tokenizer_config.json", "LICENSE", "MODEL_LICENSE_zh", "NOTICE")


def load_streamer(terms):
    directory = str(snapshot(REPO, REVISION, FILES))
    mx.set_cache_limit(256 * 1024**2)
    model, _ = load_model(directory, dtype=mx.float16)
    return R2T2Stream(model, Tokenizer(directory), terms)


class R2T2Stream:
    def __init__(self, model, tokenizer, terms):
        self.model = model
        self.tokenizer = tokenizer
        self.terms = terms
        self.stop_ids = tokenizer.EOS_TOKEN_IDS + tokenizer.encode("|")
        self.audio = []
        self.prefix = ""

    def _decode(self, final):
        # The VAD bounds the utterance. Each new decode sees its entire audio
        # and only the text already committed by the R2T2 stable-prefix loop.
        audio = np.concatenate(self.audio)
        if len(audio) <= 200:  # Whisper's STFT needs a half-window of real samples.
            return ""
        if final:
            # A stop or VAD cut can land on the last syllable. Give the
            # model acoustic right context so it can release words held at |.
            audio = np.pad(audio, (0, 12_800))
        mel, lengths = compute_features(audio)
        features, _ = self.model.audio_tower(mel.astype(mx.float16), lengths)
        prompt = self.tokenizer.build_prompt_tokens(features.shape[1], context=self.terms)
        prompt += self.tokenizer.encode(self.prefix)
        positions = mx.broadcast_to(mx.arange(len(prompt)), (1, 3, len(prompt)))
        # Leave headroom for delayed words without letting one noisy live
        # chunk monopolize the recognizer. At endpoint allow the complete tail.
        budget_samples = len(audio) if final else len(self.audio[-1])
        budget = min(512, 12 + budget_samples // 800)
        generated = generate(self.model, mx.array([prompt]), features, positions,
                             GenerationConfig(max_new_tokens=budget, eos_token_ids=self.stop_ids))

        # A vertical bar means that the model wants more audio. Withhold one
        # further token before publishing; a BPE boundary can also split UTF-8.
        suffix = self.tokenizer.decode(generated).partition("|")[0]
        tokens = self.tokenizer.encode(suffix)
        if not final:
            tokens = tokens[:-1]
        new_text = self.tokenizer.decode(tokens)
        while tokens and "\ufffd" in new_text:
            tokens.pop()
            new_text = self.tokenizer.decode(tokens)

        candidate = self.prefix + new_text
        # Automatic bilingual mode starts with "language …<asr_text>".
        # Short, ambiguous audio can produce only this header or "language None".
        _, tag, text = candidate.partition("<asr_text>")
        if tag and text.strip():
            self.prefix = candidate
            return text.strip()
        return ""

    def feed(self, samples):
        if not len(samples):
            return None
        self.audio.append(samples)
        previous = self.prefix
        text = self._decode(final=False)
        return text if self.prefix != previous else None

    def finish(self, tail=None):
        if tail is not None and len(tail):
            self.audio.append(tail)
        try:
            return self._decode(final=True) if self.audio else ""
        finally:
            self.audio.clear()
            self.prefix = ""
