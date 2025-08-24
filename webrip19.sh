#!/bin/bash

set -e

# See README.md for help.

#
# SPDX-License-Identifier: WTFPL
#
# Authors and copyright holders provide the licensed software “as is” and do not
# provide any warranties, including the merchantability of the software and
# suitability for any purpose.
#

halt() {
    echo "$1"
    exit 1
}

# --- SETTINGS BEGIN
PLAYLIST="$PWD/playlist.m3u"
TMPDIR=/tmp/WebRip19
YTDLP_ARGS=( --extractor-args "youtube:player-client=tv_embedded" \
    --cookies "$PWD/www.youtube.com_cookies.txt" \
    --abort-on-unavailable-fragments \
    --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:142.0) Gecko/20100101 Firefox/142.0" \
    -S vcodec:h264 )
MPLAYER_VIDEO_ARGS=( -vf scale=1280:720 )
SVTENC_ARGS=( --crf 38 --enable-variance-boost 1 --tune 2 --preset 0 )
OPUSENC_ARGS=( --bitrate 64 )
MKVPROPEDIT_ARGS=( --edit track:a1 --set language=ukr )
BYPASS_VAPOURSYNTH=1

VAPOUR_SYNTH_TPL='
import vapoursynth as vs
import havsfunc as haf

core = vs.core
clip = core.ffms2.Source(source='\''input_stream'\'')
clip = haf.QTGMC(clip, Preset='\''Slower'\'', FPSDivisor=2, TFF=False)
clip = core.resize.Spline36(clip, 1280, 720)
clip.set_output()
'

ENCODER_TAG='
<Tags>
  <Tag>
    <Simple>
      <Name>ENCODER</Name>
      <String>%%ENCODER_VERSION%%</String>
    </Simple>
    <Simple>
      <Name>ENCODER_OPTIONS</Name>
      <String>%%ENCODER_OPTIONS%%</String>
    </Simple>
  </Tag>
</Tags>
'
# --- SETTINGS END

# --- PREREQUISITES BEGIN

which file >/dev/null 2>&1 || halt "Please install \"file\""
which jq >/dev/null 2>&1 || halt "Please install \"jq\""
which yt-dlp >/dev/null 2>&1 || halt "Please install \"yt-dlp\""
which avifenc >/dev/null 2>&1 || halt "Please install \"libavif\""
which SvtAv1EncApp >/dev/null 2>&1 || halt "Please install \"svt-av1\""
which opusenc >/dev/null 2>&1 || halt "Please install \"opus-tools\""
which mkvmerge >/dev/null 2>&1 || halt "Please install \"mkvtoolnix\""
which mkvpropedit >/dev/null 2>&1 || halt "Please install \"mkvtoolnix\""
which mplayer >/dev/null 2>&1 || halt "Please install \"mplayer\""
which magick >/dev/null 2>&1 || halt "Please install \"imagemagick\""
if [[ "$BYPASS_VAPOURSYNTH" != 1 ]]
then
    which vspipe >/dev/null 2>&1 || halt "Please install \"vapoursynth\""
fi

# --- PREREQUISITES END

if [[ -d "$TMPDIR" ]]
then
    rm -rf "$TMPDIR"
fi

CURR_DIR="$PWD"
OUT_DIR="$HOME/Videos/WebRip19"
mkdir "$TMPDIR"
mkdir -p "$OUT_DIR"

cd "$TMPDIR"

line=$(head -n 1 "$PLAYLIST")
if [[ "$line" != "#EXTM3U" ]]
then
    halt "Missing #EXTM3U file header in playlist"
fi

NUMBER=0

while IFS="" read -r line || [ -n "$line" ]
do
    # Get the source file and extract thumbnail/cover
    if [[ "$line" == https://* || "$line" == http://* ]]
    then
        yt-dlp --write-thumbnail --abort-on-unavailable-fragments \
            -t mkv "${YTDLP_ARGS[@]}" "$line"
        input_files=( *.mkv )
        thumbnail_files=( *.webp )
        path="./${input_files[0]}"
    elif [[ "$line" == file://* ]]
    then
        path="${line:7}"
        filename="$(basename "$path")"
        ln -s "$path" "$filename"
        input_files=( "$filename" )
        if [[ $(file -brL --mime-type "$filename") == "video/x-matroska" ]]
        then
            json=$(mkvmerge "$filename" -J | \
                jq '.attachments | map(select(.file_name | startswith("cover")))')
            id=$(echo "$json" | jq -r .[0].id)
            file_name=$(echo "$json" | jq -r .[0].file_name)
            mkvextract attachments "$filename" "$id":"$file_name"
            thumbnail_files=( "$file_name" )
        fi
    else
        continue
    fi

    # Make a VapourSynth script
    ln -sL "$path" input_stream
    echo "$VAPOUR_SYNTH_TPL" > tmp.vpy

    # Make a XML tags file with encoder options for the video track
    svtav1_ver="$(SvtAv1EncApp --version)"
    svtav1_args="${SVTENC_ARGS[@]}"
    echo "$ENCODER_TAG" \
        | sed "s/%%ENCODER_VERSION%%/$svtav1_ver/" \
        | sed "s/%%ENCODER_OPTIONS%%/$svtav1_args/" > video_tag.xml

    # Process video
    if [[ $BYPASS_VAPOURSYNTH == "1" ]]
    then
        mplayer input_stream -noconsolecontrols -really-quiet \
            "${MPLAYER_VIDEO_ARGS[@]}" -vo yuv4mpeg:file=/dev/stdout -ao null | \
            SvtAv1EncApp "${SVTENC_ARGS[@]}" -b tmp.ivf -i stdin
    else
        vspipe -c y4m tmp.vpy - | \
            SvtAv1EncApp "${SVTENC_ARGS[@]}" -b tmp.ivf -i stdin
    fi

    # Process audio
    mplayer input_stream -noconsolecontrols -really-quiet -vo null \
        -ao pcm:fast:file=/dev/stdout | \
        opusenc "${OPUSENC_ARGS[@]}" --ignorelength - tmp.opus

    # Merge Matroska
    mkvmerge -o tmp.mkv tmp.ivf tmp.opus

    # Update tags and optionally attach the thumbnail
    if [[ -f "${thumbnail_files[0]}" ]]
    then
        # Avoid recompression if already in AVIF format
        if [[ $(file -brL --mime-type "${thumbnail_files[0]}") != "image/avif" ]]
        then
            magick "${thumbnail_files[0]}" cover.png
            avifenc -q 51 -c svt -s 0 -j 4 -d 8 -y 420 -a avif=1 -a tune=0 \
                cover.png cover.avif
        elif [[ "${thumbnail_files[0]}" != cover.avif ]]
        then
            ln -s "${thumbnail_files[0]}" cover.avif
        fi
        MKVPROPEDIT_ARGS+=( --add-attachment cover.avif )
    fi
    mkvpropedit tmp.mkv --tags track:v1:video_tag.xml --add-track-statistics-tags \
        "${MKVPROPEDIT_ARGS[@]}"

    # Move resulting file and cleanup
    prefix=$(printf "%03d\n" $NUMBER)
    mv tmp.mkv "$OUT_DIR/$prefix# ${input_files[0]}"
    rm -f *.mkv *.vpy *.xml *.ivf *.opus *.jpg *.png *.avif *.ffindex

    NUMBER=$((NUMBER + 1))
done < "$PLAYLIST"