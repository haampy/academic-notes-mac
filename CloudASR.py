"""Aliyun Model Studio's duplex ASR protocol. Audio stays in memory."""

import asyncio
import json
import os
import re
import sys
import threading
import uuid

import sounddevice as sd
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus, WebSocketException

from AudioInput import InputDisconnected, microphone
from Transcribe import emit, run_worker


REGIONS = {
    "beijing": ("dashscope.aliyuncs.com", "cn-beijing"),
    "singapore": ("dashscope-intl.aliyuncs.com", "ap-southeast-1"),
}


class ProviderConnection(connect):
    def process_redirect(self, exc):
        # Never forward an Authorization header to a redirected destination.
        return exc


def endpoint():
    region = os.environ.get("ACADEMIC_NOTES_API_REGION", "beijing")
    if region not in REGIONS:
        raise ValueError("百炼地域无效，请选择北京或新加坡。")
    hostname, location = REGIONS[region]
    workspace = os.environ.get("ACADEMIC_NOTES_API_WORKSPACE", "").strip()
    if workspace:
        if not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", workspace):
            raise ValueError("请检查百炼 Workspace ID 的格式。")
        hostname = f"{workspace}.{location}.maas.aliyuncs.com"
    return f"wss://{hostname}/api-ws/v1/inference"


def start_payload():
    parameters = {"format": "pcm", "sample_rate": 16000, "language_hints": ["zh", "en"]}
    terms = os.environ.get("ACADEMIC_NOTES_TERMS", "")
    vocabulary = {word.strip(): 5 for word in re.split(r"[,，、;；\n]", terms) if word.strip()}
    if vocabulary:
        parameters["vocabulary"] = vocabulary
    return {"task_group": "audio", "task": "asr", "function": "recognition",
            "model": "qwen-audio-3.1-asr-flash-streaming", "parameters": parameters, "input": {}}


async def command(socket, task_id, action, payload):
    header = {"action": action, "task_id": task_id, "streaming": "duplex"}
    await asyncio.wait_for(socket.send(json.dumps({"header": header, "payload": payload})), 5)


async def event(socket, task_id):
    message = json.loads(await socket.recv())
    header = message["header"]
    if header["task_id"] != task_id:
        raise RuntimeError("百炼返回的结果与当前记录不符。")
    if header["event"] == "task-failed":
        code = header.get("error_code", "")
        if code in ("InvalidApiKey", "InvalidAccessToken", "AccessDenied", "Forbidden"):
            raise RuntimeError("百炼授权失败，请检查 API Key、地域和模型权限。")
        if code in ("Throttling", "Throttling.RateQuota", "QuotaExhausted", "Arrearage"):
            raise RuntimeError("百炼额度或调用频率受限，请检查账户后重试。")
        # Provider messages may contain request details. Surface only an error category.
        raise RuntimeError("百炼转写失败，请检查模型权限、额度和网络。")
    return header["event"], message.get("payload", {})


async def receive_results(socket, task_id):
    completed = set()
    while True:
        kind, payload = await event(socket, task_id)
        if kind == "task-finished":
            return
        if kind != "result-generated":
            continue
        sentence = payload["output"]["sentence"]
        number = sentence.get("sentence_id")
        if sentence.get("heartbeat") or number in completed:
            continue
        text = sentence.get("text", "").strip()
        if sentence.get("sentence_end"):
            if number is not None:
                completed.add(number)
            if text:
                emit(final=text)
            else:
                emit(partial="")
        elif text:
            emit(partial=text)


async def send_microphone(socket, task_id, stopped, recording):
    loop = asyncio.get_running_loop()
    audio = asyncio.Queue(maxsize=40)
    overflowed = False
    disconnected = False

    def enqueue(data, overflow):
        nonlocal overflowed
        if overflowed:
            return
        if overflow or audio.full():
            overflowed = True
            stopped.set()
        else:
            audio.put_nowait(data)

    def callback(data, status):
        loop.call_soon_threadsafe(enqueue, data, status.input_overflow)

    with microphone(callback, emit, raw=True) as mic:
        recording.set()
        while not stopped.is_set():
            if not mic.active:
                disconnected = True
                stopped.set()
                break
            try:
                block = await asyncio.wait_for(audio.get(), 0.2)
            except TimeoutError:
                continue
            await asyncio.wait_for(socket.send(block), 5)

    # Capture is closed. Flush callbacks already posted by PortAudio before finish-task.
    await asyncio.sleep(0)
    async with asyncio.timeout(8):
        while not audio.empty():
            await socket.send(audio.get_nowait())
        await command(socket, task_id, "finish-task", {"input": {}})
    if overflowed:
        return RuntimeError("音频积压，转写已停止。请检查麦克风和网络。")
    if disconnected:
        return InputDisconnected()


async def session(key, stopped, recording):
    async with ProviderConnection(endpoint(), additional_headers={"Authorization": f"Bearer {key}"},
                                  open_timeout=8, close_timeout=2, ping_interval=15,
                                  ping_timeout=10, compression=None) as socket:
        task_id = str(uuid.uuid4())
        await command(socket, task_id, "run-task", start_payload())
        kind, _ = await asyncio.wait_for(event(socket, task_id), 8)
        if kind != "task-started":
            raise RuntimeError("百炼未确认启动，请重试。")
        sender = asyncio.create_task(send_microphone(socket, task_id, stopped, recording))
        receiver = asyncio.create_task(receive_results(socket, task_id))
        try:
            done, _ = await asyncio.wait((sender, receiver), return_when=asyncio.FIRST_COMPLETED)
            if receiver in done:
                await receiver
                if not sender.done() and not stopped.is_set():
                    raise RuntimeError("百炼提前结束转写，请重试。")
            capture_error = await sender
            await asyncio.wait_for(receiver, 10)
            if capture_error:
                raise capture_error
        finally:
            for task in (sender, receiver):
                task.cancel()
            await asyncio.gather(sender, receiver, return_exceptions=True)


async def listen(key):
    loop = asyncio.get_running_loop()
    stopped, recording = asyncio.Event(), asyncio.Event()
    worker = asyncio.create_task(session(key, stopped, recording))

    def request_stop():
        stopped.set()
        if not recording.is_set():
            worker.cancel()

    def read_stdin():
        while chunk := os.read(sys.stdin.fileno(), 512):
            if b"\n" in chunk:
                break
        if not loop.is_closed():
            loop.call_soon_threadsafe(request_stop)

    threading.Thread(target=read_stdin, daemon=True).start()
    try:
        await worker
    except asyncio.CancelledError:
        if not stopped.is_set():
            raise


def run():
    key = os.environ.get("ACADEMIC_NOTES_API_KEY", "").strip()
    if not key or any(ord(character) < 33 or ord(character) > 126 for character in key):
        raise ValueError("请在设置中填写有效的百炼 API Key。")
    try:
        asyncio.run(listen(key))
    except InvalidStatus as error:
        status = error.response.status_code
        if status in (401, 403):
            raise RuntimeError("百炼拒绝连接，请检查 API Key、地域和模型权限。") from None
        raise RuntimeError(f"百炼连接失败（HTTP {status}），请检查地域、工作空间和服务状态。") from None
    except TimeoutError:
        raise RuntimeError("百炼响应超时，请检查网络。") from None
    except (OSError, WebSocketException):
        raise RuntimeError("百炼连接中断，请检查网络和地域设置。") from None
    except (KeyError, TypeError, json.JSONDecodeError):
        raise RuntimeError("无法读取百炼的转写结果。") from None
    except sd.PortAudioError:
        raise RuntimeError("无法读取麦克风，请检查设备和录音权限。") from None


if __name__ == "__main__":
    run_worker(run)
