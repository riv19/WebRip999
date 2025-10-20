# Repair badly deinterlaced progressive content - 1px horizontal combing effect
# on movement. NNEDI3 in anti-alias mode outperforms QTGMC in this case, but it
# is more aggressive. Adjust brightness/contrast only to specified frame ranges.
# Apply deblock and deband for low-bitrate material. Resize to 720p.

import vapoursynth as vs
import adjust as adj
from vsaa.deinterlacers import AntiAliaser
from vsaa.deinterlacers import NNEDI3

core = vs.core
core.num_threads = 2
clip = core.bs.VideoSource(source='input_stream')
clip = NNEDI3().antialias(clip, direction=AntiAliaser.AADirection.VERTICAL)
clip = core.resize.Bicubic(clip, format=vs.YUV420P10, matrix=1)

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
    (0,      5685),
    (20118,  22277),
    (24585,  26007),
    (26215,  27364),
    (27389,  27394),
    (30817,  33506),
    (33952,  34267),
    (34731,  37587),
    (40500,  42469),
    (42888,  43339),
    (43461,  44725),
    (45819,  47484),
    (47766,  48002),
    (48027,  49620),
    (51177,  51190),
    (51291,  51842),
    (51861,  57062),
    (57554,  57845),
    (58029,  60019),
    (60221,  63339),
    (63689,  65102),
    (66962,  68727),
    (68871,  69743),
    (71552,  72053),
    (72214,  75879),
    (76298,  77224),
    (77426,  78156),
    (79182,  79667),
    (80015,  80393),
    (80691,  81579),
    (81672,  84090),
    (84617,  84794),
    (85325,  87573),
    (90603,  93941),
    (94477,  97651),
    (103072, 105509)
]

total = (0, clip.num_frames)
skip_ranges = inverse_ranges(*total, tweak_ranges)

clips = []

for x, y in zip(tweak_ranges, skip_ranges):
    clips.append(adj.Tweak(clip[x[0] : x[1]], bright=32, cont=1.10))
    clips.append(clip[y[0] : y[1]])

with open('resolution.txt', 'r', encoding='utf-8') as f:
    newres = f.read().split('x')

clip = core.std.Splice(clips, mismatch=False)
clip = core.deblock.Deblock(clip, quant=20, aoffset=0, boffset=0)
clip = core.neo_f3kdb.Deband(clip, range=15, y=64, cb=64, cr=64, grainy=0, grainc=0)
clip = core.resize.Spline36(clip, int(newres[0]), int(newres[1]))
clip.set_output()
