# * Repair badly deinterlaced progressive content - 1px horizontal combing
#   effect on movement. QTGMC does not remove all combing in this case, NNEDI
#   anti-aliaser does.
# * Video editing: Apply a filter in manually specified areas of frame ranges.
#   Can be easily used for blurring areas. Here it is brightness/contrast.
# * Apply deblock and deband for low-bitrate yuv420p8 material.
# * Resize to resolution specified in VIDEO_WIDTH and VIDEO_HEIGHT.
# * yuv420p10 output.
#
# * Edit this script at least in places marked with --->>>
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
core.num_threads = 1
clip = core.bs.VideoSource(source='%%INPUT_STREAM%%')
orig_num_frames = clip.num_frames

clip = NNEDI3(opencl=True).antialias(clip, direction=AntiAliaser.AADirection.VERTICAL)
clip = core.resize.Spline36(clip, format=vs.YUV420P10, matrix_in_s="709")

bright = -8
cont = 0.95

# ----- Video editing: Apply filters in rectangular areas of frame ranges

def inverse_ranges(total_start, total_end, used_ranges):
    # Sort the ranges to process in order
    used_ranges = sorted(used_ranges, key=lambda r: r[0])
    result = []
    prev_end = total_start

    for start, end, x, y, w, h in used_ranges:
        if start > prev_end:
            result.append((prev_end, start))
        prev_end = max(prev_end, end)  # in case of overlapping input ranges

    # Check for final gap
    if prev_end < total_end:
        result.append((prev_end, total_end))

    return result

# --->>> Edit your frame ranges here.
# (start, end, x, y, w, h) (not inclusive, `end` is the stop frame)
tweak_ranges = [
    (58,      59,       0,     0,     208,   1080),
    (59,      60,       0,     0,     542,   1080),
    (60,      61,       0,     0,     854,   1080),
    (61,      62,       0,     0,     1142,  1080),
    (62,      63,       0,     0,     1398,  1080),
    (63,      64,       0,     0,     1398,  1080),
    (64,      65,       0,     0,     1618,  1080),
    (65,      66,       0,     0,     1792,  1080),
    (66,      5147,     0,     0,     1920,  1080),
    (5521,    5588,     0,     0,     1920,  1080),
    (5916,    6860,     0,     0,     1920,  1080),
    (7001,    8381,     0,     0,     1920,  1080),
    (8802,    12370,    0,     0,     1920,  1080),
    (12974,   13553,    0,     0,     1920,  1080),
    (13645,   13943,    0,     0,     1920,  1080),
    (14083,   14508,    0,     0,     1920,  1080),
    (14563,   14714,    0,     0,     1920,  1080),
    (14968,   15338,    0,     0,     1920,  1080),
    (15490,   16280,    0,     0,     1920,  1080),
    (16526,   16886,    0,     0,     1920,  1080),
    (17016,   25369,    0,     0,     1920,  1080),
    (25981,   26552,    0,     0,     1920,  1080),
    (27043,   28168,    0,     0,     960,   1080),
    (28168,   29624,    0,     0,     1920,  1080),
    (29624,   29874,    0,     0,     1920,  1080),
    (29874,   30646,    0,     0,     1920,  1080),
    (30929,   38312,    0,     0,     1920,  1080),
    (51186,   61190,    0,     0,     1920,  1080),
    (61511,   62443,    0,     0,     960,   1080),
    (62716,   64884,    0,     0,     1920,  1080),
    (65384,   65886,    0,     0,     1920,  1080),
    (65886,   66388,    0,     0,     960,   1080),
    (66388,   66629,    0,     0,     1920,  1080),
    (66678,   67585,    0,     0,     1920,  1080),
    (68250,   68834,    0,     0,     1920,  1080),
    (69060,   71996,    0,     0,     1920,  1080),
    (79208,   82841,    0,     0,     1920,  1080),
    (83393,   83671,    0,     0,     1920,  1080),
    (83934,   85414,    0,     0,     1920,  1080),
    (85804,   87522,    0,     0,     1920,  1080),
    (87703,   94126,    0,     0,     1920,  1080),
    (94688,   98560,    0,     0,     1920,  1080),
    (98560,   99907,    0,     0,     960,   1080),
    (99907,   101136,   0,     0,     1920,  1080),
    (101956,  107718,   0,     0,     1920,  1080),
    (108026,  110020,   0,     0,     960,   1080),
    (110020,  110760,   0,     0,     1920,  1080),
    (110760,  113384,   0,     0,     960,   1080),
    (113574,  118637,   0,     0,     1920,  1080)
]

total = (0, clip.num_frames)
skip_ranges = inverse_ranges(*total, tweak_ranges)
final_ranges = sorted(tweak_ranges + skip_ranges, key=lambda r: r[0])

clips = []

def red_fill(clip):
    return core.std.BlankClip(clip, color=[304, 340, 1020])

def tweak(clip):
    return adj.Tweak(clip, bright=bright, cont=cont)

def box_filter(clip, flt, x, y, w, h):
    mask = core.std.BlankClip(clip, width=w, height=h, length=1, color=[1023, 1023, 1023])
    mask = core.std.AddBorders(mask, 0, clip.width - w, clip.height - h, color=[0, 0, 0])
    filtered = flt(clip)
    return core.std.MaskedMerge(clip, filtered, mask)

for x in final_ranges:
    if x in tweak_ranges:
        # --->>> Replace red_fill with your desired filter.
        clips.append(box_filter(clip[x[0] : x[1]], red_fill, x[2], x[3], x[4], x[5]))
    elif x in skip_ranges:
        clips.append(clip[x[0] : x[1]])

clip = core.std.Splice(clips, mismatch=False)

# ----- Deblock, deband, etc.

clip = core.deblock.Deblock(clip, quant=20, aoffset=0, boffset=0)
clip = core.neo_f3kdb.Deband(clip, range=15, y=64, cb=64, cr=64, grainy=0, grainc=0, opt=0)

# ----- Resize

clip = core.resize.Bicubic(clip, %%VIDEO_WIDTH%%, %%VIDEO_HEIGHT%%)

# Verify that resulting clip has exactly the same length
assert orig_num_frames == clip.num_frames
clip.set_output()
