# Simple script for high quality video - no heavy filtering required.
# Resize to 720p YUV420P10.

import vapoursynth as vs

core = vs.core
core.num_threads = 2
clip = core.bs.VideoSource(source='input_stream')
clip = core.resize.Spline36(clip, 1280, 720, format=vs.YUV420P10, matrix=1)
clip.set_output()