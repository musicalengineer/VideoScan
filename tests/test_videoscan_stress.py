#!/usr/bin/env python3
# test_videoscan_stress.py — VideoScan Stress Tests (headless)
from __future__ import annotations
import time, unittest
from scripts.VideoScan import extract_metadata, human_size, format_duration, partial_md5

class ExtractMetadataLogicTests(unittest.TestCase):
    def test_empty_probe(self):
        self.assertEqual(extract_metadata({})['stream_type'], 'No A/V streams')
    def test_video_only(self):
        p = {'format':{'format_name':'mov'},'streams':[{'codec_type':'video','codec_name':'h264','width':1920,'height':1080}]}
        m = extract_metadata(p)
        self.assertEqual(m['stream_type'], 'Video only')
    def test_audio_only(self):
        p = {'format':{'format_name':'mov'},'streams':[{'codec_type':'audio','codec_name':'pcm_s16le','channels':2}]}
        self.assertEqual(extract_metadata(p)['stream_type'], 'Audio only')
    def test_video_plus_audio(self):
        p = {'format':{'format_name':'mp4'},'streams':[
             {'codec_type':'video','codec_name':'dnxhd','width':1920,'height':1080},
             {'codec_type':'audio','codec_name':'pcm_s16le','channels':2}]}
        self.assertEqual(extract_metadata(p)['stream_type'], 'Video+Audio')
    def test_all_stream_types(self):
        for probe, exp in [({'streams':[{'codec_type':'video'}]},'Video only'),
                            ({'streams':[{'codec_type':'audio'}]},'Audio only'),
                            ({'streams':[{'codec_type':'video'},{'codec_type':'audio'}]},'Video+Audio')]:
            self.assertEqual(extract_metadata(probe)['stream_type'], exp)
    def test_frame_rate_parsing(self):
        m = extract_metadata({'streams':[{'codec_type':'video','r_frame_rate':'30000/1001'}]})
        self.assertTrue(m['frame_rate'].startswith('29.97'))
    def test_non_video_stream_ignored(self):
        m = extract_metadata({'streams':[{'codec_type':'subtitle'}]})
        self.assertEqual(m['stream_type'], 'No A/V streams')

class HelperLogicTests(unittest.TestCase):
    def test_human_size_bytes(self):
        self.assertEqual(human_size(0), '0.0 B')
        self.assertEqual(human_size(512), '512.0 B')
    def test_human_size_kb_mb(self):
        self.assertEqual(human_size(1024), '1.0 KB')
        self.assertEqual(human_size(1048576), '1.0 MB')
    def test_human_size_gb_tb(self):
        self.assertEqual(human_size(1073741824), '1.0 GB')
        self.assertEqual(human_size(1099511627776), '1.0 TB')
    def test_human_size_negative(self):
        self.assertEqual(human_size(-1), '-1.0 B')
    def test_format_duration_zero(self):
        self.assertEqual(format_duration(0), '00:00:00')
    def test_format_duration_seconds(self):
        self.assertEqual(format_duration(1), '00:00:01')
        self.assertEqual(format_duration(59), '00:00:59')
    def test_format_duration_minutes_hours(self):
        self.assertEqual(format_duration(60), '00:01:00')
        self.assertEqual(format_duration(3599), '00:59:59')
        self.assertEqual(format_duration(3600), '01:00:00')

class MediaMatrixTests(unittest.TestCase):
    def test_h264_mp4(self):
        m = extract_metadata({'format':{'format_name':'mov'},'streams':[{'codec_type':'video','codec_name':'h264'}]})
        self.assertEqual(m['stream_type'], 'Video only')
    def test_dnxhd_mxf(self):
        m = extract_metadata({'format':{'format_name':'mxf'},'streams':[{'codec_type':'video','codec_name':'dnxhd'}]})
        self.assertEqual(m['video_codec'], 'dnxhd')
    def test_pcm_s16le_mov_audio_only(self):
        # JustPatsHouse.mov: PCM must NOT be video
        m = extract_metadata({'format':{'format_name':'mov'},'streams':[{'codec_type':'audio','codec_name':'pcm_s16le','channels':2}]})
        self.assertEqual(m['stream_type'], 'Audio only')
    def test_ffv1_matroska(self):
        p = {'format':{'format_name':'matroska'},'streams':[{'codec_type':'video','codec_name':'ffv1'},{'codec_type':'audio','codec_name':'pcm_s24le'}]}
        self.assertEqual(extract_metadata(p)['stream_type'], 'Video+Audio')
    def test_hevc_h265(self):
        m = extract_metadata({'format':{'format_name':'mp4'},'streams':[{'codec_type':'video','codec_name':'h265'}]})
        self.assertEqual(m['video_codec'], 'h265')

class IsolationPoisonTests(unittest.TestCase):
    def test_none_format(self):
        self.assertEqual(extract_metadata({'format':None})['stream_type'], 'No A/V streams')
    def test_null_streams(self):
        p = {'format':{'format_name':'mov'},'streams':None}
        self.assertEqual(extract_metadata(p)['stream_type'], 'No A/V streams')
    def test_empty_probe(self):
        self.assertEqual(extract_metadata({})['stream_type'], 'No A/V streams')
    def test_list_instead_of_dict(self):
        p = {'streams':{'codec_type':'video'}}
        self.assertEqual(extract_metadata(p)['stream_type'], 'No A/V streams')
    def test_mixed_none_and_valid(self):
        p = {'format':{'duration':'100.0'},'streams':[None,{'codec_type':'audio'}]}
        self.assertEqual(extract_metadata(p)['stream_type'], 'Audio only')

class ScaleStressTests(unittest.TestCase):
    def _p(self, i):
        return {'format':{'format_name':['mov','mp4','mxf'][i%3]},'streams':[{'codec_type':'video','codec_name':'h264','width':1920,'height':1080}]}
    def test_10k_under_5s(self):
        start = time.time()
        for i in range(10000):
            m = extract_metadata(self._p(i))
            self.assertIn(m['stream_type'], ['Video only'])
        elapsed = time.time() - start
        self.assertLess(elapsed, 5.0)
    def test_50k_under_15s(self):
        start = time.time()
        for i in range(50000):
            m = extract_metadata(self._p(i))
            self.assertIn(m['stream_type'], ['Video only'])
        elapsed = time.time() - start
        self.assertLess(elapsed, 15.0)

class RegressionSensorTests(unittest.TestCase):
    def test_pcm_pin_audio_only_not_video(self):
        # Pin: pcm_s16le-only must NOT be video
        m = extract_metadata({'streams':[{'codec_type':'audio','codec_name':'pcm_s16le'}]})
        self.assertEqual(m['stream_type'], 'Audio only')
    def test_vplus_a_pin(self):
        m = extract_metadata({'streams':[{'codec_type':'video'},{'codec_type':'audio'}]})
        self.assertEqual(m['stream_type'], 'Video+Audio')
    def test_resolution_intxint(self):
        m = extract_metadata({'streams':[{'codec_type':'video','width':1920,'height':1080}]})
        self.assertEqual(m['resolution'], '1920x1080')
    def test_human_size_boundary(self):
        for v in [1023, 1024, 1025]:
            self.assertIsInstance(human_size(v), str)
    def test_format_duration_3600_boundary(self):
        self.assertEqual(format_duration(3599), '00:59:59')
        self.assertEqual(format_duration(3600), '01:00:00')

if __name__ == '__main__':
    unittest.main(verbosity=2)
