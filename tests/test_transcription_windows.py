import os
import sys
import unittest
from contextlib import contextmanager
from queue import SimpleQueue
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

import FireRedASR
import Transcribe
from AudioInput import InputDisconnected


class TranscriptionWindowTests(unittest.TestCase):
    def replay(self, blocks, engine, live=False):
        events = []
        calls = []
        queue = SimpleQueue()

        @contextmanager
        def microphone(receive, emit, finished_callback):
            def captured():
                for block in blocks:
                    receive(block, None)
                    yield
                finished_callback()
                yield

            capture = captured()
            if live:
                # Deliver one block at each read, as if there were no microphone backlog.
                def read(timeout):
                    next(capture)
                    return queue.get_nowait()
                incoming.get = read
            else:
                for _ in capture:
                    pass
            yield SimpleNamespace(active=False)

        def decode(samples, *, preview=False):
            if not preview:
                calls.append(("final", samples))
            return "文本" if engine == "firered-aed" else "文本。"

        def feed(samples):
            calls.append(("feed", samples))
            return "临时字幕"

        def finish(tail=None):
            calls.append(("finish", tail))
            return "文本。"

        incoming = SimpleNamespace(put=queue.put, get=queue.get, empty=queue.empty)
        r2t2 = SimpleNamespace(load_streamer=lambda _: SimpleNamespace(feed=feed, finish=finish))
        with (patch.dict(os.environ, ACADEMIC_NOTES_ENGINE=engine),
              patch.dict(sys.modules, R2T2=r2t2),
              patch.object(Transcribe, "microphone", microphone),
              patch.object(Transcribe, "SimpleQueue", return_value=incoming),
              patch.object(Transcribe.threading, "Thread"),
              patch.object(Transcribe, "load_transcriber", return_value=decode),
              patch.object(FireRedASR, "load_transcriber", return_value=decode),
              patch.object(Transcribe, "emit", side_effect=lambda **event: events.append(event))):
            with self.assertRaises(InputDisconnected):
                Transcribe.run()
        return events, calls

    def transcribe(self, counts, engine="qwen-1.7b"):
        blocks = [np.full(1600, 0.2 if count > 0 else 0.0, dtype=np.float32)
                  for count in counts for _ in range(abs(count))]
        return self.replay(blocks, engine)[0]

    def test_every_nonzero_block_reaches_the_model_in_order(self):
        # Sub-threshold beginnings, endings, and a full quiet utterance between pauses.
        silence = np.zeros(1600, np.float32)
        blocks = [silence] * 20
        for n in range(47):
            block = np.zeros(1600, np.float32)
            block[50 + n] = (n + 1) * (0.01 if 5 <= n <= 15 else 1e-7)
            blocks.append(block)
            if n in (22, 45):
                blocks.extend([silence] * 18)
        expected = np.array([b for b in blocks if b.any()])
        for engine in ("qwen-1.7b", "qwen-0.6b", "firered-aed", "r2t2-8bit"):
            for live in (False, True):
                with self.subTest(engine=engine, live=live):
                    _, calls = self.replay(blocks, engine, live=live)
                    self.assertTrue(calls)
                    if engine == "r2t2-8bit" and live:
                        self.assertIn("feed", [method for method, _ in calls])
                        self.assertEqual(calls[-1][0], "finish")
                    received = np.concatenate([s for _, s in calls if s is not None]).reshape(-1, 1600)
                    np.testing.assert_array_equal(received[received.any(axis=1)], expected)

    def test_digital_silence_alone_does_not_invoke_any_decoder(self):
        silence = [np.zeros(1600, np.float32)] * 260
        for engine in ("qwen-1.7b", "firered-aed", "r2t2-8bit"):
            with self.subTest(engine=engine):
                self.assertEqual(self.replay(silence, engine, live=True), ([], []))

    def test_streaming_technical_cut_delivers_its_tail_and_the_next_block_once(self):
        blocks = [np.full(1600, (i + 1) * 1e-6, np.float32) for i in range(241)]
        events, calls = self.replay(blocks, "r2t2-8bit", live=True)
        finals = [event for event in events if "final" in event]
        self.assertEqual(finals, [{"final": "文本。", "continues": True}, {"final": "文本。"}])
        np.testing.assert_array_equal(np.concatenate([s for _, s in calls if s is not None]),
                                      np.concatenate(blocks))

    def test_hesitation_inside_a_short_sentence_keeps_the_audio_together(self):
        self.assertEqual(self.transcribe([10, -14, 10]), [{"final": "文本。"}])

    def test_brief_hesitation_in_long_speech_keeps_the_audio_together(self):
        for blocks in ([125, -3, 12], [200, -4, 12]):
            with self.subTest(blocks=blocks):
                self.assertEqual(self.transcribe(blocks), [{"final": "文本。"}])

    def test_sustained_pause_ends_a_window_and_takes_priority_over_the_short_cut(self):
        # Total duration reaches 20 seconds exactly as the silence reaches 1.5.
        blocks = [185, -15, 3]
        self.assertEqual(self.transcribe(blocks), [{"final": "文本。"}, {"final": "文本。"}])
        self.assertEqual(self.transcribe(blocks, "firered-aed"),
                         [{"final": "文本", "pauseBoundary": True}, {"final": "文本"}])

    def test_restart_of_speech_after_a_technical_cut_cancels_pause_confirmation(self):
        for blocks in ([195, -5, 10], [195, -14, 10], [240, 3]):
            with self.subTest(blocks=blocks):
                self.assertEqual(self.transcribe(blocks),
                                 [{"final": "文本。", "continues": True}, {"final": "文本。"}])

    def test_silence_after_technical_cuts_confirms_the_boundary_once(self):
        for blocks in ([195, -25, 3], [240, -25, 3]):
            for engine, text in (("qwen-1.7b", "文本。"), ("firered-aed", "文本")):
                with self.subTest(blocks=blocks, engine=engine):
                    self.assertEqual(self.transcribe(blocks, engine), [
                        {"final": text, "continues": True},
                        {"pauseBoundary": True},
                        {"final": text},
                    ])
