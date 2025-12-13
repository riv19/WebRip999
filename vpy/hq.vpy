# Simple script for high quality video - no heavy filtering required.
# * Resize to resolution specified in VIDEO_WIDTH and VIDEO_HEIGHT.
# * yuv420p10 output.

# Prerequisites (assuming Arch Linux):
# vapoursynth-plugin-bestsource

import vapoursynth as vs

core = vs.core
core.num_threads = 1
clip = core.bs.VideoSource(source='%%INPUT_STREAM%%')

clip = core.resize.Spline36(clip, %%VIDEO_WIDTH%%, %%VIDEO_HEIGHT%%, format=vs.YUV420P10, matrix_in_s="709")
clip.set_output()
