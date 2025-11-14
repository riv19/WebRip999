# * Repair badly deinterlaced progressive content - 1px horizontal combing
# effect on movement. NNEDI3 in anti-alias mode outperforms QTGMC in this case,
# but it is more aggressive - does not distinguish between artifacts and real
# information, but it is simply lost in this case.
# * Remove over-saturation by adjusting brightness/contrast only to specified
# frame ranges and in speficied areas for some frames - edit the arrays below.
# * Apply deblock and deband for low-bitrate yuv420p8 material.
# * Resize to resolution specified in `resolution.txt`
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

import functools
import vapoursynth as vs
import adjust as adj
from vsaa.deinterlacers import AntiAliaser
from vsaa.deinterlacers import NNEDI3

core = vs.core
core.num_threads = 2
clip = core.bs.VideoSource(source='input_stream')
orig_num_frames = clip.num_frames

clip = NNEDI3(opencl=True).antialias(clip, direction=AntiAliaser.AADirection.VERTICAL)
clip = core.resize.Bicubic(clip, format=vs.YUV420P10, matrix=1)

bright = 32
cont = 0.80

# ----- Apply brightness/contrast in specific areas per frame

# Format: frame_number: (x, y, w, h)
tweak_regions = {
    437: (0, 0, 208, 1080),
    438: (0, 0, 208, 1080),
    439: (0, 0, 542, 1080),
    440: (0, 0, 854, 1080),
    441: (0, 0, 1142, 1080),
    442: (0, 0, 1398, 1080),
    443: (0, 0, 1618, 1080),
    444: (0, 0, 1618, 1080),
    445: (0, 0, 1792, 1080),
}

# Function: apply filter only to given rectangle
def apply_filter(clip, n, x, y, w, h):
    mask = core.std.BlankClip(clip, width=w, height=h, length=1, color=[1023, 1023, 1023])
    mask = core.std.AddBorders(mask, 0, clip.width - w, clip.height - h, color=[0, 0, 0])
    frame = adj.Tweak(clip[n], bright=bright, cont=cont)
    #frame = core.std.BlankClip(clip, length=1, color=[304, 340, 1020]) # reference

    return core.std.MaskedMerge(clip[n], frame, mask)

# FrameEval: dynamically select which frames to modify
def process_frame(n, clip):
    if n in tweak_regions:
        x, y, w, h = tweak_regions[n]
        return apply_filter(clip, n, x, y, w, h)
    else:
        return clip

# Apply per-frame logic dynamically
clip = core.std.FrameEval(clip, functools.partial(process_frame, clip=clip))

# ----- Apply brightness/contrast per frame ranges

def inverse_ranges(total_start, total_end, used_ranges):
    # Sort the ranges to process in order
    used_ranges = sorted(used_ranges)
    result = []
    prev_end = total_start

    for start, end in used_ranges:
        if start > prev_end:
            result.append((prev_end, start))
        prev_end = max(prev_end, end)  # in case of overlapping input ranges

    # Check for final gap
    if prev_end < total_end:
        result.append((prev_end, total_end))

    return result

# (start, end) (not inclusive, `end` is the stop frame)
tweak_ranges = [
    (446,     9982),
    (11746,   17205),
    (17312,   17811),
    (18969,   19593),
    (20807,   21110),
    (22400,   22879),
    (23847,   24277),
    (27625,   28814),
    (28971,   32096),
    (34256,   36839),
    (37215,   39448),
    (39771,   42437),
    (43220,   45988),
    (47102,   53524),
    (53805,   54380),
    (55472,   55888),
    (56467,   57993),
    (59084,   61409),
    (62415,   63297),
    (63592,   65903),
    (67186,   72344),
    (89931,   97934),
    (98231,   112563),
    (113601,  117741),
    (119206,  123241),
]

total = (0, clip.num_frames)
skip_ranges = inverse_ranges(*total, tweak_ranges)
final_ranges = sorted(tweak_ranges + skip_ranges, key=lambda r: r[0])

clips = []

for x in final_ranges:
    if x in tweak_ranges:
        clips.append(adj.Tweak(clip[x[0] : x[1]], bright=bright, cont=cont))
    elif x in skip_ranges:
        clips.append(clip[x[0] : x[1]])

clip = core.std.Splice(clips, mismatch=False)

# ----- Deblock, deband, etc.

clip = core.deblock.Deblock(clip, quant=20, aoffset=0, boffset=0)
clip = core.neo_f3kdb.Deband(clip, range=15, y=64, cb=64, cr=64, grainy=0, grainc=0, opt=0)

# ----- Resize

with open('resolution.txt', 'r', encoding='utf-8') as f:
    newres = f.read().split('x')
clip = core.resize.Spline36(clip, int(newres[0]), int(newres[1]))

# Verify that resulting clip has exactly the same length
assert orig_num_frames == clip.num_frames
clip.set_output()
