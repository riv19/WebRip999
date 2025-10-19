#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

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

. webrip19.cfg

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
[ "$VAPOURSYNTH" -eq 0 ] || which vspipe >/dev/null 2>&1 || \
    halt "Please install \"vapoursynth\""
[ "$FFMPEG_NORMALIZE" -eq 0 ] || which ffmpeg-normalize >/dev/null 2>&1 || \
    halt "Please install \"ffmpeg-normalize\""

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
[[ "$line" == "#EXTM3U" ]] || halt "Missing #EXTM3U file header in playlist"

ENCODER_TAG='<Tags>
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
</Tags>'

process_one() {
    add_url=0
    skip_line=0

    # Get the source file and extract thumbnail/cover
    if [[ "$line" == https://* || "$line" == http://* ]]; then
        yt-dlp --write-thumbnail --convert-thumbnails png \
            --abort-on-unavailable-fragments \
            -t mkv "${YTDLP_ARGS[@]}" "$line" 2>&1
        input_files=( *.mkv )
        thumbnail_files=( *.png )
        desc_files=( *.description )
        path="./${input_files[0]}"
        add_url=1
    elif [[ "$line" == file://* ]]; then
        path="${line:7}"
        filename="$(basename "$path")"
        ln -s "$path" "$filename"
        input_files=( "$filename" )
        if [[ $(file -brL --mime-type "$filename") == "video/x-matroska" ]]
        then
            # Cover/thumbnail
            json=$(mkvmerge "$filename" -J | \
                jq '.attachments | map(select(.file_name | startswith("cover")))')
            id=$(echo "$json" | jq -r .[0].id)
            file_name=$(echo "$json" | jq -r .[0].file_name)
            mkvextract attachments "$filename" "$id":"$file_name"
            thumbnail_files=( "$file_name" )
            # Description/annotation
            json=$(mkvmerge "$filename" -J | \
                jq '.attachments | map(select(.file_name == "description.txt"))')
            id=$(echo "$json" | jq -r .[0].id)
            file_name=$(echo "$json" | jq -r .[0].file_name)
            mkvextract attachments "$filename" "$id":"$file_name.description"
            desc_files=( "$file_name.description" )
        fi
    else
        skip_line=1
        return
    fi

    # Some tools may fail with Unicode file names.
    # Make a symbolic link to the input file.
    ln -sL "$path" input_stream

    # Get video tracks information in json
    jq_s=".tracks | map(select(.type == \"video\"))"
    vid=$(mkvmerge -J input_stream | jq -r "$jq_s")
    if [ $(echo "$vid" | jq -r 'length') -gt 1 ]; then
        halt "Input files with multiple video streams are not yet supported"
    fi

    # Make a VapourSynth script
    if [ "$VAPOURSYNTH" -eq 1 ]; then
        echo "$VAPOUR_SYNTH_TPL" > tmp.vpy
    fi

    # Make a XML tags file with encoder options for the video track
    svtav1_ver="$(SvtAv1EncApp --version | head -n1)"
    svtav1_args="${SVTENC_ARGS[@]}"
    echo "$ENCODER_TAG" | \
        sed "s/%%ENCODER_VERSION%%/$svtav1_ver/" | \
        sed "s/%%ENCODER_OPTIONS%%/$svtav1_args/" | tr -s '[:space:]' > video_tag.xml

    # Prepare a thumbnail
    if [[ -f "${thumbnail_files[0]}" ]]; then
        # Avoid recompression if already in AVIF format
        if [[ $(file -brL --mime-type "${thumbnail_files[0]}") != "image/avif" ]]
        then
            avifenc "${AVIFENC_ARGS[@]}" "${thumbnail_files[0]}" cover.avif
        elif [[ "${thumbnail_files[0]}" != cover.avif ]]
        then
            ln -s "${thumbnail_files[0]}" cover.avif
        fi
        MKVPROPEDIT_ARGS+=( --add-attachment cover.avif )
    fi

    MKVMERGE_ARGS=( )

    # Prepare chapters
    if [[ $(file -brL --mime-type input_stream) == "video/x-matroska" ]]
    then
        mkvextract input_stream chapters chapters.xml
        if [[ -f chapters.xml ]]
        then
            MKVMERGE_ARGS+=( --chapters chapters.xml )
        fi
    fi

    # Prepare description (it's not standardized - just add as attachment)
    if [[ -f "${desc_files[0]}" ]]; then
        mv "${desc_files[0]}" description.txt
        echo -e "\n\nProcessed with WebRip19: $SCRIPT_URL" >> description.txt
        [ $add_url -eq 0 ] || echo "Original Video: $line" >> description.txt
        MKVPROPEDIT_ARGS+=( --add-attachment description.txt )
    fi

    # Process audio.
    # Mplayer has volnorm filer, but it has low quality (noticeable).
    # FFMpeg-normalize is far better, running in two passes.
    if [ $FFMPEG_NORMALIZE -eq 1 ]; then
        NO_COLOR=1 ffmpeg-normalize input_stream -v \
            "${FFMPEG_NORMALIZE_ARGS[@]}" -vn -ar 48000 -ext wav -o norm.wav
        opusenc "${OPUSENC_ARGS[@]}" --ignorelength norm.wav tmp.opus
        rm norm.wav
    else
        mplayer input_stream -noconsolecontrols -really-quiet -vo null \
            -ao pcm:fast:file=/dev/stdout -af format=s16le | \
            opusenc "${OPUSENC_ARGS[@]}" --ignorelength - tmp.opus
    fi

    # Process video
    echo "Source video stream info:"
    echo "$vid"
    for res in "${VIDEO_RESOLUTIONS[@]}"
    do
        echo "Processing video stream in resolution $res:"
        input_res=$(echo "$vid" | jq -r '.[0].properties.pixel_dimensions')
        ew=$(echo "$input_res" | cut -d "x" -f 1)
        eh=$(echo "$input_res" | cut -d "x" -f 2)
        nh=$(echo "$res" | rev | cut -c2- | rev)
        nw=$(expr \( $ew \* $nh + $eh / 2 \) / $eh)
        echo "$nw"x"$nh" > resolution.txt
        if [ $VAPOURSYNTH -eq 1 ]; then
            # Each vps script must parse resolution.txt
            vspipe -c y4m tmp.vpy - | \
                SvtAv1EncApp "${SVTENC_ARGS[@]}" -b "$res.ivf" -i stdin
        else
            # Substitute new width/height
            for i in "${!MPLAYER_VIDEO_ARGS1[@]}"; do
                MPLAYER_VIDEO_ARGS1[$i]="${MPLAYER_VIDEO_ARGS1[$i]/\%WIDTH\%/$nw}"
                MPLAYER_VIDEO_ARGS1[$i]="${MPLAYER_VIDEO_ARGS1[$i]/\%HEIGHT\%/$nh}"
            done

            mplayer input_stream -noconsolecontrols -really-quiet \
                "${MPLAYER_VIDEO_ARGS[@]}" -vo yuv4mpeg:file=/dev/stdout -ao null | \
                SvtAv1EncApp "${SVTENC_ARGS[@]}" -b "$res.ivf" -i stdin
        fi
    done

    vid_list=""
    for i in "${!VIDEO_RESOLUTIONS[@]}"; do
        vid_list+="${VIDEO_RESOLUTIONS[$i]}.ivf "
    done

    # Merge Matroska, edit tags, add attachments
    mkvmerge -o tmp.mkv "${MKVMERGE_ARGS[@]}" $vid_list tmp.opus
}

NUMBER=0
while [ 1 ]
do
    prefix=$(printf "%03d\n" $NUMBER)
    if ls "$OUT_DIR/$prefix# "* >/dev/null 2>&1
    then
        NUMBER=$((NUMBER + 1))
        continue
    fi
    break
done

while IFS="" read -r line || [ -n "$line" ]
do
    # Process one item, logging console output
    process_one > >(tee -a "$LOG_FILE") 2>&1
    [ "$skip_line" -eq 0 ] || continue

    # Process progress bars in the log
    sed -i 's/.*\r//;:a;s/.\x08//;ta;s/\x08//' "$LOG_FILE"

    mkvpropedit tmp.mkv --tags track:v1:video_tag.xml --add-track-statistics-tags \
        "${MKVPROPEDIT_ARGS[@]}" --add-attachment "$LOG_FILE"

    # Move resulting file and cleanup
    prefix=$(printf "%03d\n" $NUMBER)
    mv tmp.mkv "$OUT_DIR/$prefix# ${input_files[0]}"
    rm -f "$TMPDIR/"*

    NUMBER=$((NUMBER + 1))
done < "$PLAYLIST"
