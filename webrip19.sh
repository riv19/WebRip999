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

. settings.txt

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
mkdir -p "$TMPDIR"
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
        yt-dlp --write-thumbnail --convert-thumbnails png \
            --abort-on-unavailable-fragments \
            -t mkv "${YTDLP_ARGS[@]}" "$line"
        input_files=( *.mkv )
        thumbnail_files=( *.png )
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

    # Prepare a thumbnail
    if [[ -f "${thumbnail_files[0]}" ]]
    then
        # Avoid recompression if already in AVIF format
        if [[ $(file -brL --mime-type "${thumbnail_files[0]}") != "image/avif" ]]
        then
            avifenc -q 71 -c svt -s 0 -j 4 -d 8 -y 420 -a avif=1 -a tune=0 \
                "${thumbnail_files[0]}" cover.avif
        elif [[ "${thumbnail_files[0]}" != cover.avif ]]
        then
            ln -s "${thumbnail_files[0]}" cover.avif
        fi
        MKVPROPEDIT_ARGS+=( --add-attachment cover.avif )
    fi

    MKVMERGE_ARGS=( )

    # Prepare chapters
    if [[ $(file -brL --mime-type "${input_files[0]}") == "video/x-matroska" ]]
    then
        mkvextract "${input_files[0]}" chapters chapters.xml
        if [[ -f chapters.xml ]]
        then
            MKVMERGE_ARGS+=( --chapters chapters.xml )
        fi
    fi

    # Process audio
    mplayer input_stream -noconsolecontrols -really-quiet -vo null \
        -ao pcm:fast:file=/dev/stdout | \
        opusenc "${OPUSENC_ARGS[@]}" --ignorelength - tmp.opus

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

    # Merge Matroska, edit tags, add attachments
    mkvmerge -o tmp.mkv "${MKVMERGE_ARGS[@]}" tmp.ivf tmp.opus
    mkvpropedit tmp.mkv --tags track:v1:video_tag.xml --add-track-statistics-tags \
        "${MKVPROPEDIT_ARGS[@]}"

    # Move resulting file and cleanup
    prefix=$(printf "%03d\n" $NUMBER)
    mv tmp.mkv "$OUT_DIR/$prefix# ${input_files[0]}"
    rm -f "$TMPDIR/"*

    NUMBER=$((NUMBER + 1))
done < "$PLAYLIST"
