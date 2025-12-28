v2.0

- Tested environments: ArchLinux, Termux (Android).
- Use ffmpeg as extractor and multiplexer tool, remove mkvtoolnix.
- New video encoder list: copy, svt_av1_hdr, ffmpeg.
- New image encoder list: copy, avifenc.
- Enable 10-bit avif encoding by default.
- Add MediaCodec API (HW) and VP9 lossless (SW) templates for ffmpeg encoder.
- SSH upload support for output directory.

1. Need to manually compile avifenc and VapourSynth plugins for Termux.
2. For 10-bit MediaCodec support, need to apply a patch to ffmpeg.

v1.1

- Fix mkvpropedit command line.
- Update VapourSynth scripts.
- Add ffmpeg-vaapi encoder: copy, svt_av1_hdr, ffmpeg-vaapi.
- Count output files from 1, not from 0.

v1.0

- Tested environments: ArchLinux.
- Major rework of the first variant.
- YT-DLP download for http://, https:// URLs.
- Reuse already downloaded file in the temp directory, on a script re-run.
- 4 video decoders support: vspipe, ffmpeg, mpv, mplayer.
- 4 audio decoders support: vspipe, ffmpeg, mpv, mplayer.
- 2 video encoders support: copy, svt_av1_hdr
- 2 audio encoders support: copy, opusenc.
- Matroska output files support.
- Matroska attachments: processing log, cover image, video description.