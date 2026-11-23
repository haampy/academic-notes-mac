import asyncio
import os
import unittest
from contextlib import asynccontextmanager, contextmanager
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import numpy as np

import CloudASR
import Transcribe


class InputDisconnectTests(unittest.TestCase):
    def worker_errors(self, worker):
        events = []
        with patch.object(Transcribe, "emit", side_effect=lambda **e: events.append(e)):
            with self.assertRaises(SystemExit) as exit_status:
                Transcribe.run_worker(worker)
        self.assertEqual(exit_status.exception.code, 1)
        return events

    def test_local_disconnect_requires_successful_final_decode(self):
        @contextmanager
        def microphone(receive, emit, finished_callback):
            for _ in range(2):
                receive(np.full(1600, 0.2, np.float32), None)
            finished_callback()
            yield SimpleNamespace(active=False)

        for fail in (False, True):
            with self.subTest(decode_fails=fail):
                def decode(samples):
                    if fail:
                        raise RuntimeError("解码失败")
                    return "最后一句"

                with (patch.dict(os.environ, ACADEMIC_NOTES_ENGINE="qwen-1.7b"),
                      patch.object(Transcribe, "microphone", microphone),
                      patch.object(Transcribe.threading, "Thread"),
                      patch.object(Transcribe, "load_transcriber", return_value=decode)):
                    events = self.worker_errors(Transcribe.run)
                if fail:
                    self.assertEqual(events, [{"error": "解码失败"}])
                else:
                    self.assertEqual(events[0], {"final": "最后一句"})
                    self.assertTrue(events[-1]["inputDisconnected"])

    def test_cloud_disconnect_requires_flushed_audio_and_provider_ack(self):
        for failure in (None, "overflow", "send", "provider"):
            with self.subTest(failure=failure):
                sent = []
                finished = asyncio.Event()

                @contextmanager
                def microphone(callback, emit, raw):
                    callback(b"last PCM", SimpleNamespace(input_overflow=failure == "overflow"))
                    yield SimpleNamespace(active=False)

                async def send(data):
                    if isinstance(data, bytes):
                        if failure == "send":
                            raise RuntimeError("发送失败")
                        sent.append(data)
                    elif '"finish-task"' in data:
                        finished.set()

                @asynccontextmanager
                async def connect(*args, **kwargs):
                    yield SimpleNamespace(send=send)

                async def receive_results(*args):
                    await finished.wait()
                    if failure == "provider":
                        raise RuntimeError("定稿失败")
                    Transcribe.emit(final="最后一句")

                async def run():
                    await CloudASR.session("test", asyncio.Event(), asyncio.Event())

                with (patch.object(CloudASR, "microphone", microphone),
                      patch.object(CloudASR, "ProviderConnection", connect),
                      patch.object(CloudASR, "event", AsyncMock(return_value=("task-started", {}))),
                      patch.object(CloudASR, "receive_results", receive_results)):
                    events = self.worker_errors(lambda: asyncio.run(run()))
                if failure is None:
                    self.assertEqual(sent, [b"last PCM"])
                    self.assertEqual(events[0], {"final": "最后一句"})
                    self.assertTrue(events[-1]["inputDisconnected"])
                else:
                    self.assertNotIn("inputDisconnected", events[-1])
                    self.assertIn({"overflow": "积压", "send": "发送失败", "provider": "定稿失败"}[failure],
                                  events[-1]["error"])
