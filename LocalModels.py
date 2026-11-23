import json
from pathlib import Path

from huggingface_hub import snapshot_download
from huggingface_hub.errors import HfHubHTTPError, LocalEntryNotFoundError


def snapshot(repo: str, revision: str, files: tuple[str, ...]) -> Path:
    options = dict(repo_id=repo, revision=revision, allow_patterns=list(files))
    try:
        cached = Path(snapshot_download(**options, local_files_only=True))
        if all((cached / name).is_file() for name in files):
            return cached
    except LocalEntryNotFoundError:
        pass

    print(json.dumps({"status": "正在下载所选转写模型…"},
                     ensure_ascii=False), flush=True)
    try:
        directory = Path(snapshot_download(**options))
    except (LocalEntryNotFoundError, HfHubHTTPError) as error:
        raise RuntimeError("模型下载未完成，请检查网络后继续记录。") from error
    missing = [name for name in files if not (directory / name).is_file()]
    if missing:
        raise RuntimeError("请联网补全转写模型文件：" + "、".join(missing))
    return directory
