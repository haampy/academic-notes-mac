import os
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np

from Transcribe import load_transcriber


class QwenDecodeTests(unittest.TestCase):
    def setUp(self):
        self.samples = np.zeros(16000, dtype=np.float32)
        self.session = Mock()
        with (patch("Transcribe.model_directory", return_value="local-model"),
              patch("mlx.core.set_cache_limit"),
              patch("mlx_qwen3_asr.Session", return_value=self.session),
              patch.dict(os.environ, ACADEMIC_NOTES_TERMS="机器学习")):
            self.decode = load_transcriber()

    def test_quiet_window_with_glossary_can_remain_empty(self):
        self.session.transcribe.return_value = SimpleNamespace(language="", text=" ")
        self.assertEqual(self.decode(self.samples), "")
        self.session.transcribe.assert_called_once()
        options = self.session.transcribe.call_args.kwargs
        self.assertIsNone(options["language"])
        self.assertEqual(options["context"], "机器学习")

    def test_preview_does_not_run_a_second_decode(self):
        self.session.transcribe.return_value = SimpleNamespace(language="English", text="our topic")
        self.assertEqual(self.decode(self.samples, preview=True), "our topic")
        self.session.transcribe.assert_called_once()

    def test_english_final_uses_hint_only_for_a_bilingual_result(self):
        original = SimpleNamespace(language="English", text="our topic")
        for hinted, expected in [("our topic 机器学习", "our topic 机器学习"),
                                 ("", "our topic"), ("嗯。", "our topic"), ("are topic", "our topic")]:
            with self.subTest(hinted=hinted):
                self.session.transcribe.reset_mock()
                self.session.transcribe.side_effect = [original, SimpleNamespace(text=hinted)]
                self.assertEqual(self.decode(self.samples), expected)
                calls = self.session.transcribe.call_args_list
                self.assertEqual([call.kwargs["language"] for call in calls], [None, "Chinese"])

    def test_chinese_final_returns_the_first_result(self):
        self.session.transcribe.return_value = SimpleNamespace(language="Chinese", text="机器学习。")
        self.assertEqual(self.decode(self.samples), "机器学习。")
        self.session.transcribe.assert_called_once()
