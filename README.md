# A batch video archiving tool - WebRip19

Source files: an M3U playlist containing URLs to streams from web resources such
as video hostings, file servers; or local files.

Output file format: AV1 video + Opus audio + AVIF thumbnail in Matroska
container.

TODO:

1. Copy audio/video stream by setting an option, without transcoding.
2. dvd:// URL support
3. Other encoders support.

## Usage

1. Install prerequisites from the corresponding section of the script. In case
of missing something, the script will produce an error message with a hint.

2. Edit the playlist file "playlist.m3u" to replace samples with your actual
video files. Use the following URL types:

* file://
* http:// or https://

Or run `yt-playlist.sh` to save YouTube playlists as M3U.

3. Adjust settings in the config file: select encoder for tracks, video
resolutions, VapourSynth script, etc.

4. Run the batch archiving: `./webrip19.sh`

5. Freely edit this script if your system does not provide what it expects.

5. After completion, check the output folder (`~/Videos/WebRip19` by default)
for the resulting files.
