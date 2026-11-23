from LocalModels import snapshot


def load_transcriber():
    import mlx.core as mx
    from mlx_audio.stt import load

    directory = snapshot(
        "mlx-community/FireRedASR2-AED-mlx",
        "f3212eacfa49b851130b97c63653c8e06ee09bdb",
        ("config.json", "cmvn.json", "dict.txt", "train_bpe1000.model", "model.safetensors"),
    )
    mx.set_cache_limit(256 * 1024**2)
    model = load(directory)

    def decode(samples):
        # The two strided convolutions need seven 25 ms feature frames.
        if len(samples) < 1360:
            return ""
        return model.generate(mx.array(samples, dtype=mx.float32)).text.strip()

    return decode
