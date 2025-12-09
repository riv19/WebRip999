#!/bin/bash

set -euo pipefail

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

if [[ "$DECODER" == vspipe ]]; then
    which vspipe >/dev/null 2>&1 || halt "Please install \"vapoursynth\""
fi
if [[ "$DECODER" == ffmpeg ]]; then
    which ffmpeg >/dev/null 2>&1 || halt "Please install \"ffmpeg\""
fi
if [[ "$DECODER" == mpv ]]; then
    which mpv >/dev/null 2>&1 || halt "Please install \"mpv\""
fi
if [[ "$DECODER" == mplayer ]]; then
    which mplayer >/dev/null 2>&1 || halt "Please install \"mplayer\""
fi

if [ "$DRC" -eq 1 ]; then
    which ffmpeg-normalize >/dev/null 2>&1 || \
        halt "Please install \"ffmpeg-normalize\""
fi

# --- PREREQUISITES END

CURR_DIR="$PWD"
OUT_DIR="$HOME/Videos/WebRip19"
mkdir -p "$TMPDIR/dl"
mkdir -p "$TMPDIR/src"
mkdir -p "$TMPDIR/dst"
mkdir -p "$OUT_DIR"

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

size_bytes_from_file() {
    local file="$1"

    # Detect GNU vs BSD stat
    if stat --version >/dev/null 2>&1; then
        size=$(stat -L -c%s "$file")       # GNU stat (Linux)
    else
        size=$(stat -L -f%z "$file")       # BSD stat (macOS, FreeBSD)
    fi

    echo "$size"
}

human_size_from_file() {
    local file="$1"
    local size=$(size_bytes_from_file "$file")

    local units=(B KB MB GB TB PB)
    local i=0

    while (( size >= 1024 && i < ${#units[@]}-1 )); do
        size=$(( size / 1024 ))
        ((i++))
    done

    echo "${size}${units[$i]}"
}

app_ver_short() {
    local out
    out="$("$1" --version 2>/dev/null || "$1" -V 2>/dev/null || "$1" -v 2>/dev/null || "$1" -version 2>/dev/null)"
    echo "$out" | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n1
}

app_ver() {
    echo $("$1" --version 2>/dev/null | head -n1)
}

get_sample_rate_from_file() {
    local filepath="$1"
    local info regex sr_hz sr_khz int_khz dec_khz hz

    info=$(file "$filepath")

    # Match "... 44100 Hz ..."
    regex='s/.* \([0-9]\+\) Hz.*/\1/p'
    sr_hz=$(echo "$info" | sed -n "$regex")
    if [[ -n "$sr_hz" ]]; then
        echo "$sr_hz"
        return
    fi

    # Match "... 44.1 kHz ..." or "... 48 kHz ..."
    regex='s/.* \([0-9.]\+\) kHz.*/\1/p'
    sr_khz=$(echo "$info" | sed -n "$regex")
    if [[ -n "$sr_khz" ]]; then
        int_khz="${sr_khz%.*}"
        dec_khz="${sr_khz#*.}"

        if [[ "$int_khz" == "$dec_khz" ]]; then
            # No decimal part: "48"
            hz=$(( int_khz * 1000 ))
        else
            # Has decimal part: "44.1"
            # decimal digit * 100 (only one decimal place expected from file)
            hz=$(( int_khz * 1000 + dec_khz * 100 ))
        fi

        echo "$hz"
        return
    fi

    # No match — echo empty
    echo ""
}

calc_resolution() {
    local width="$1"
    local height="$2"
    local target_height="$3"

    # Compute proportional width (integer division)
    local new_width=$(expr $width \* $target_height / $height)

    # Ensure width is even (FFmpeg requires this)
    local remainder=$(expr $new_width % 2 || :)
    if [ $remainder -ne 0 ]; then
        new_width=$(expr $new_width + 1)
    fi

    echo "${new_width}x${target_height}"
}

retrieve_stream_yt_dlp() {
    echo "$STEP.) Retrieving files (yt-dlp)"

    local stream="$1"

    # Do not reget source MKV, if exists and URL matches
    if [[ -f source_url ]] && [[ "$(cat source_url)" == "$stream" ]]; then
        echo "Skipping download: Source file already exists for this URL"
    else
        rm -rf "$TMPDIR/dl/source_url" "$TMPDIR/dl/"*.description \
            "$TMPDIR/dl/"*.json "$TMPDIR/dl/"*.mkv "$TMPDIR/dl/"*.png
        yt-dlp --write-thumbnail --convert-thumbnails png \
            --abort-on-unavailable-fragments \
            -t mkv "${YTDLP_ARGS[@]}" "$stream" 2>&1
        echo "$stream" > source_url
    fi

    local size_bytes=$(size_bytes_from_file *.mkv)
    local human_size=$(human_size_from_file *.mkv)

    echo
    echo "* Source file size: $human_size ($size_bytes bytes)"
}

retrieve_stream_local() {
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
}

extract_tracks() {
    echo "$STEP.) Extracting tracks"

    ln -sL ../dl/*.mkv input_stream
    if [ -f ../dl/*.png ]; then ln -sL ../dl/*.png cover; fi
    if [ -f ../dl/*.description ]; then
        ln -sL ../dl/*.description description
    fi

    # This looks like not necessary, but some tools like ffmpeg-normalize can't
    # read from stdin or can parse only certain container formats. Also it
    # throws possible errors early, in case of corrupted source.
    local source_info=$(mkvmerge -J input_stream)
    local -a tracks=()
    while IFS= read -r item; do
        local type=$(echo "$item" | jq -r '.type')
        local tid=$(echo "$item" | jq -r '.id')
        if [[ "$type" == "audio" ]]; then
            echo "Source audio (id $tid) stream info:"
            echo "$(echo "$item" | jq -r '.properties')"
            tracks+=("$tid audio")
        elif [[ "$type" == "video" ]]; then
            echo "Source video (id $tid) stream info:"
            echo "$(echo "$item" | jq -r '.properties')"
            tracks+=("$tid video")
        else
            echo "BUG: Unsupported track type: $type"
        fi
    done < <(echo "$source_info" | jq -rc '.tracks[]')

    for track in "${tracks[@]}"; do
        local tid=$(echo "$track" | cut -d" " -f1)
        local type=$(echo "$track" | cut -d" " -f2)
        mkvextract tracks input_stream $tid:$type$tid
    done

    echo "$source_info" > source_info
}

process_cover() {
    echo "$STEP.) Processing cover image"

    if [[ -f "../src/cover" ]]; then
        # Avoid recompression if already in target format
        if [[ $(file -brL --mime-type "../src/cover") != "image/avif" ]]
        then
            echo "Encoding image with avifenc v$(app_ver_short avifenc)"
            echo "Arguments: ${AVIFENC_ARGS[@]}"
            avifenc "${AVIFENC_ARGS[@]}" "../src/cover" cover
        else
            echo "Skipping encoding: Already in required format"
            ln -sL "../src/cover" cover
        fi
    else
        echo "No cover image in source stream"
    fi
}

process_audio() {
    echo "$STEP.) Processing audio"

    for track in ../src/audio*; do
        if [ $DRC -eq 1 ]; then
            echo "Applying Dynamic Range Compression (DRC) with ffmpeg-normalize v$(app_ver_short ffmpeg-normalize)"
            echo "Arguments: ${FFMPEG_NORMALIZE_ARGS[@]}"
            local sample_rate=$(get_sample_rate_from_file "$track")
            NO_COLOR=1 ffmpeg-normalize "$track" -ar $sample_rate -c:a flac -v \
                "${FFMPEG_NORMALIZE_ARGS[@]}" -e="-sample_fmt s16" -o norm.flac
            mv -f norm.flac "$track"
        fi

        echo "Encoding audio track with opusenc v$(app_ver_short opusenc)"
        echo "Arguments: ${OPUSENC_ARGS[@]}"
        mplayer "$track" -noconsolecontrols -really-quiet -vo null \
            -ao pcm:fast:file=/dev/stdout -af format=s16le | \
            opusenc "${OPUSENC_ARGS[@]}" --ignorelength - $(basename "$track")
    done
}

process_video() {
    echo "$STEP.) Processing video"

    for track in ../src/video*; do
        local ss_info=$(cat ../src/source_info)
        local jq_s=".tracks[] | select(.id == 1) | .properties.pixel_dimensions"
        local resolution=$(echo "$ss_info" | jq -r "$jq_s")
        local width=$(echo "$resolution" | cut -d'x' -f1)
        local height=$(echo "$resolution" | cut -d'x' -f2)
        local jq_s=".tracks[] | select(.id == 1) | .properties.default_duration"
        local fps=$((1000000000 / $(echo "$ss_info" | jq -r "$jq_s")))
        echo "Video track source resolution: $resolution"

        if [[ "$DECODER" == vspipe ]]; then
            echo "Preparing Vapoursynth script \"$VPY_FILE\""
            echo "$VAPOURSYNTH_TPL" > "$TMPDIR/$VPY_FILE"
            sed -i "s/%%INPUT_STREAM%%/src\/$(basename $track)/g" "$TMPDIR/$VPY_FILE"
            sed -i "s/%%VIDEO_WIDTH%%/$width/g" "$TMPDIR/$VPY_FILE"
            sed -i "s/%%VIDEO_HEIGHT%%/$height/g" "$TMPDIR/$VPY_FILE"
        fi

        echo "Encoding video track with SvtAv1EncApp v$(app_ver_short SvtAv1EncApp)"
        echo "Arguments: ${SVTENC_ARGS[@]}"

        if [[ "$DECODER" == vspipe ]]; then
            echo "Using decoder: vspipe v$(app_ver_short vspipe)"
            vspipe -c y4m "$TMPDIR/$VPY_FILE" - | \
                SvtAv1EncApp "${SVTENC_ARGS[@]}" -b $(basename $track) -i stdin
        elif [[ "$DECODER" == ffmpeg ]]; then
            echo "Using decoder: ffmpeg v$(app_ver_short ffmpeg)"
            local ffmpeg_args=$(echo "${FFMPEG_VIDEO_ARGS[@]}" | \
                sed "s/%%VIDEO_WIDTH%%/$width/g" | \
                sed "s/%%VIDEO_HEIGHT%%/$height/g")
            ffmpeg -loglevel quiet -i "$track" $ffmpeg_args -f yuv4mpegpipe - | \
                SvtAv1EncApp "${SVTENC_ARGS[@]}" -b $(basename $track) -i stdin
        elif [[ "$DECODER" == mpv ]]; then
            # MPV has buggy y4m output (fps multiplied by 1000).
            # Use raw video output.
            echo "Using decoder: mpv v$(app_ver_short mpv)"
            local mpv_args=$(echo "${MPV_VIDEO_ARGS[@]}" | \
                sed "s/%%VIDEO_WIDTH%%/$width/g" | \
                sed "s/%%VIDEO_HEIGHT%%/$height/g")
            local regex='s/.*format=\([[:alnum:]]*\).*/\1/p'
            local pix_fmt=$(echo "$mpv_args" | sed -n "$regex")
            if [[ "$pix_fmt" == yuv420p ]]; then
                local depth=8
            elif [[ "$pix_fmt" == yuv420p10le ]]; then
                local depth=10
            else
                halt "Unsupported pixel format. Check mpv options."
            fi
            mpv --no-audio --o=- --no-input-cursor --really-quiet \
                --no-input-default-bindings --input-vo-keyboard=no \
                $mpv_args --of=rawvideo "$track" | \
                SvtAv1EncApp "${SVTENC_ARGS[@]}" -b $(basename $track) -i stdin \
                    -w $width -h $height --input-depth $depth --fps $fps
        elif [[ "$DECODER" == mplayer ]]; then
            # MPlayer only supports 8-bit y4m output and no raw video output.
            echo "Using decoder: mplayer v$(app_ver_short mplayer)"
            local mplayer_args=$(echo "${MPLAYER_VIDEO_ARGS[@]}" | \
                sed "s/%%VIDEO_WIDTH%%/$width/g" | \
                sed "s/%%VIDEO_HEIGHT%%/$height/g")
            mplayer -ao null -vo yuv4mpeg:file=/dev/stdout -noconsolecontrols \
                -really-quiet $mplayer_args "$track" | \
                SvtAv1EncApp "${SVTENC_ARGS[@]}" -b $(basename $track) -i stdin
        else
            halt "Unsupported decoder specified"
        fi
    done
}

merge_files() {
    echo "$STEP.) Merging files"

    # Move remaining unprocessed files to destination dir
    if [ -f ../src/description ]; then
        ln -sL ../src/description
    fi

    # Make a XML tags file with encoder options for the video track
    local svtav1_ver="$(SvtAv1EncApp --version | head -n1)"
    local svtav1_args="${SVTENC_ARGS[@]}"
    echo "$ENCODER_TAG" | \
        sed "s/%%ENCODER_VERSION%%/$svtav1_ver/" | \
        sed "s/%%ENCODER_OPTIONS%%/$svtav1_args/" | \
        tr -s '[:space:]' > "$TMPDIR/video_tag"

    # Merge Matroska
    mkvmerge -o output_stream video* audio*

    local size_bytes=$(size_bytes_from_file output_stream)
    local human_size=$(human_size_from_file output_stream)

    echo
    echo "* Resulting file size (without attachments): $human_size ($size_bytes bytes)"
}

process_one() {
    local stream="$1"

    echo "::: Processing stream $STREAM_NUM of $STREAM_COUNT: $stream"
    echo

    # Get the source file
    cd "$TMPDIR/dl"
    if [[ "$stream" == https://* || "$stream" == http://* ]]; then
        retrieve_stream_yt_dlp "$stream"
        echo
    elif [[ "$stream" == file://* ]]; then
        retrieve_stream_local "$stream"
        echo
    else
        echo "Unsupported URL schema: $stream"
        return
    fi

    # Extract audio and video tracks
    STEP=$((STEP + 1))
    cd "$TMPDIR/src"
    extract_tracks
    echo

    # Compress or copy cover image
    STEP=$((STEP + 1))
    cd "$TMPDIR/dst"
    process_cover
    echo

    # Compress or copy audio
    STEP=$((STEP + 1))
    cd "$TMPDIR/dst"
    process_audio
    echo

    # Compress or copy video
    STEP=$((STEP + 1))
    cd "$TMPDIR/dst"
    process_video
    echo

    # Merge processed tracks and attachments
    STEP=$((STEP + 1))
    cd "$TMPDIR/dst"
    merge_files
    echo
}

# Function: extract file paths from M3U/M3U8 into a Bash array
extract_m3u_paths() {
    local playlist="$1"
    local line=
    local -n out_array="$2"

    # Initialize output array
    out_array=()

    # Check if playlist exists
    if [[ ! -f "$playlist" ]]; then
        echo "Error: Playlist '$playlist' not found." >&2
        exit 1
    fi

    # Read playlist line by line
    while IFS="" read -r line || [ -n "$line" ]; do
        # Skip empty lines or lines starting with '#'
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        out_array+=("$line")
    done < "$playlist"
}

echo "WebRip19 Batch Video Archiving tool: $SCRIPT_URL"
echo

declare -a streams
extract_m3u_paths "$PLAYLIST" streams

OUTPUT_NUM=0
STREAM_NUM=1
STREAM_COUNT="${#streams[@]}"
while [ 1 ]
do
    prefix=$(printf "%04d\n" $OUTPUT_NUM)
    if ls "$OUT_DIR/$prefix# "* >/dev/null 2>&1
    then
        OUTPUT_NUM=$((OUTPUT_NUM + 1))
        continue
    fi
    break
done

finalize_stream() {
    local -a edit_args=()
    if [ -f cover ]; then
        local cover_param="name=cover.avif,mime-type=image/avif"
        edit_args+=( --add-attachment "$cover_param" cover )
    fi
    if [ -f description ]; then
        local desc_param="name=description.txt,mime-type=text/plain"
        edit_args+=( --add-attachment "$desc_param" description )
    fi
    edit_args+=( --add-attachment "../$LOG_FILE" )

    # Mux tracks into the container
    mkvpropedit output_stream --add-track-statistics-tags \
        "${MKVPROPEDIT_ARGS[@]}" "${edit_args[@]}"
}

main_loop() {
    for stream in "${streams[@]}"; do
        STEP=0

        # Cleanup remainings from previous runs
        cd "$TMPDIR"
        rm -f "$LOG_FILE"
        rm -f "$VPY_FILE"
        rm -f video_tag
        rm -rf src/*
        rm -rf dst/*

        # Process one item, logging console output
        process_one $stream > >(tee -a "$TMPDIR/$LOG_FILE") 2>&1

        # Squash progress bars in the log
        sed -i 's/.*\r//;:a;s/.\x08//;ta;s/\x08//;s/[[:space:]]\+$//' \
            "$TMPDIR/$LOG_FILE"

        cd "$TMPDIR/dst"
        finalize_stream

        # Move resulting file
        local prefix=$(printf "%04d\n" $OUTPUT_NUM)
        local old_name=$(readlink ../src/input_stream)
        local old_basename=$(basename "$old_name")
        mv output_stream "$OUT_DIR/$prefix# $old_basename"

        # Cleanup
        rm -rf dl/*
        rm -rf src/*
        rm -rf dst/*
        rm -f "$TMPDIR/$LOG_FILE"
        rm -f "$TMPDIR/$VPY_FILE"

        OUTPUT_NUM=$((OUTPUT_NUM + 1))
        STREAM_NUM=$((STREAM_NUM + 1))
        echo
    done
}

main_loop
