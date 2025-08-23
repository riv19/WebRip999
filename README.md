# A batch video conversion script - WebRip19

Source files: an M3U playlist containing links to videos from any video hosting,
supported by `yt-dlp` tool, or file:// URLs with local files.

Output file format: AV1 video + Opus audio + AVIF thumbnail in Matroska
container.

TODO:

1. Copy audio/video stream by setting an option, without transcoding.
2. dvd:// URL support
3. Other encoders support.

## Usage

1. Install prerequisites from the corresponding section of the script.

*Vapoursynth may be difficult to install e.g. on Arch Linux, but it has nice
filters such as QTGMC deinterlacer. Thus, it is optional and may be enabled
by setting the option BYPASS_VAPOURSYNTH=0.*

2. Edit the playlist file "playlist.m3u" to replace samples with your actual
video files. Use the following URL types:

* file://
* http:// or https://

3. Adjust settings in the settings section, if needed.

4. Run the batch conversion: `./webrip19.sh`

5. Freely edit this script if your installed prerequisites are incompatible or
if you want to use alternatives.

5. After completion, check `~/Videos/WebRip19` folder for the resulting files.
