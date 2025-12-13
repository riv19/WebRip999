# A simple script for audio decoding

# Prerequisites (assuming Arch Linux):
# vapoursynth-plugin-bestsource

import vapoursynth as vs
core = vs.core

audio = core.bs.AudioSource('%%INPUT_STREAM%%')
audio.set_output(0)
