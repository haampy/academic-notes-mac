import os
import unittest
from unittest.mock import Mock, patch

import numpy as np

from AudioInput import meter_level, selected_stream


class AudioInputTests(unittest.TestCase):
    def test_only_the_selected_same_name_device_starts(self):
        devices = [dict(name="USB Mic", index=i, max_input_channels=1) for i in range(2)]
        streams = [Mock(audio_id=21), Mock(audio_id=84)]

        def factory(device):
            return streams[device]

        with (patch.dict(os.environ, ACADEMIC_NOTES_INPUT_ID="84", ACADEMIC_NOTES_INPUT_NAME="USB Mic"),
              patch("AudioInput.sd.query_devices", return_value=devices),
              patch("AudioInput.core_audio_id", side_effect=lambda stream: stream.audio_id)):
            with selected_stream(factory) as (stream, device_id, name):
                self.assertIs(stream, streams[1])
                self.assertEqual((device_id, name), (84, "USB Mic"))
            streams[0].start.assert_not_called()
            streams[0].close.assert_called_once()
            streams[1].start.assert_called_once()
            with patch.dict(os.environ, ACADEMIC_NOTES_INPUT_ID="99"):
                with self.assertRaises(RuntimeError), selected_stream(factory):
                    self.fail("A disconnected device must not capture from a namesake")
            streams[1].start.assert_called_once()

    def test_float_and_pcm_blocks_share_the_meter_scale(self):
        for amplitude, expected in [(0.0, 0.0), (0.0001, 0.0), (0.1, 2 / 3), (1.0, 1.0)]:
            block = np.full(1600, amplitude, dtype=np.float32)
            pcm = (block * 32767).astype("<i2").tobytes()
            for samples in (block, pcm):
                self.assertAlmostEqual(meter_level(samples), expected, places=3)
