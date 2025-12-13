# * Repair badly deinterlaced progressive content - 1px horizontal combing
#   effect on movement. QTGMC does not remove all combing in this case, NNEDI
#   anti-aliaser does.
# * Remove over-saturation by adjusting brightness/contrast.
# * Apply deblock and deband for low-bitrate yuv420p8 material.
# * Resize to resolution specified in VIDEO_WIDTH and VIDEO_HEIGHT.
# * yuv420p10 output.
#
# Prerequisites (assuming Arch Linux):
# vapoursynth-plugin-bestsource
# vapoursynth-plugin-adjust
# vapoursynth-plugin-vsjetpack
# vapoursynth-plugin-nnedi3 (CPU)
# vapoursynth-plugin-sneedif (GPU)
# vapoursynth-plugin-deblock
# vapoursynth-plugin-neo_f3kdb
# ?

import vapoursynth as vs
import adjust as adj
from vsaa.deinterlacers import AntiAliaser
from vsaa.deinterlacers import NNEDI3

core = vs.core
core.num_threads = 1
clip = core.bs.VideoSource(source='%%INPUT_STREAM%%')

clip = NNEDI3(opencl=True).antialias(clip, direction=AntiAliaser.AADirection.VERTICAL)
clip = core.resize.Spline36(clip, format=vs.YUV420P10, matrix_in_s="709")

# ----- Apply brightness/contrast

clip = adj.Tweak(clip, bright=0, cont=0.90)

# ----- Deblock, deband, etc.

clip = core.deblock.Deblock(clip, quant=20, aoffset=0, boffset=0)
clip = core.neo_f3kdb.Deband(clip, range=15, y=64, cb=64, cr=64, grainy=0, grainc=0)

# ----- Resize

clip = core.resize.Bicubic(clip, %%VIDEO_WIDTH%%, %%VIDEO_HEIGHT%%)

# Verify that resulting clip has exactly the same length
assert old_num_frames == new_num_frames
clip.set_output()
