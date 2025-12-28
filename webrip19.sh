#!/bin/bash

set -euo pipefail

SCRIPT_VERSION=2.0

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

which awk >/dev/null 2>&1 || halt "Please install \"awk\""
which file >/dev/null 2>&1 || halt "Please install \"file\""
which jq >/dev/null 2>&1 || halt "Please install \"jq\""
which yt-dlp >/dev/null 2>&1 || halt "Please install \"yt-dlp\""
which avifenc >/dev/null 2>&1 || halt "Please install \"libavif\""
which SvtAv1EncApp >/dev/null 2>&1 || halt "Please install \"svt-av1\""
which opusenc >/dev/null 2>&1 || halt "Please install \"opus-tools\""

if [[ "$VIDEO_DECODER" == vspipe ]]; then
    which vspipe >/dev/null 2>&1 || halt "Please install \"vapoursynth\""
fi
if [[ "$VIDEO_DECODER" == ffmpeg ]] || [[ "$AUDIO_DECODER" == ffmpeg ]]; then
    which ffmpeg >/dev/null 2>&1 || halt "Please install \"ffmpeg\""
fi
if [[ "$VIDEO_DECODER" == mpv ]] || [[ "$AUDIO_DECODER" == mpv ]]; then
    which mpv >/dev/null 2>&1 || halt "Please install \"mpv\""
fi
if [[ "$VIDEO_DECODER" == mplayer ]] || [[ "$AUDIO_DECODER" == mplayer ]]; then
    which mplayer >/dev/null 2>&1 || halt "Please install \"mplayer\""
fi

if [ "$DRC" -eq 1 ]; then
    which ffmpeg-normalize >/dev/null 2>&1 || \
        halt "Please install \"ffmpeg-normalize\""
fi

AUDIO_VPY_TMP_FILE=audio.vpy
VIDEO_VPY_TMP_FILE=video.vpy

# --- PREREQUISITES END

CURR_DIR="$PWD"
mkdir -p "$TMPDIR"

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
    local size="$1"

    local units=(B KB MB GB TB PB)
    local i=0

    while (( size >= 1024 && i < ${#units[@]}-1 )); do
        size=$(( size / 1024 ))
        ((++i))
    done

    echo "${size}${units[$i]}"
}

get_image_type() {
  local sig ftyp regexp

  # Read first 32 bytes (needed for ISO BMFF)
  sig=$(dd if="$1" bs=1 count=32 2>/dev/null | od -An -tx1 | tr -d ' \n')

  case "$sig" in
    89504e470d0a1a0a*) echo "image/png png" ;;
    ffd8ff*)           echo "image/jpeg jpg" ;;
    474946383761*|474946383961*) echo "image/gif gif" ;;
    424d*)             echo "image/bmp bmp" ;;
    49492a00*|4d4d002a*) echo "image/tiff tiff" ;;
    52494646*57454250*) echo "image/webp webp" ;;
    *)
      # ISO BMFF (AVIF / HEIC family)
      regexp='s/.*66747970\([0-9a-f]\{8\}\).*/\1/p'
      ftyp=$(printf '%s' "$sig" | sed -n "$regexp")
      case "$ftyp" in
        61766966|61766973) echo "image/avif avif" ;; # avif / avis
        *) echo "application/octet-stream bin" ;;
      esac
      ;;
  esac
}

app_ver_short() {
    local out
    out="$("$1" --version 2>/dev/null || "$1" -V 2>/dev/null || "$1" -v 2>/dev/null || "$1" -version 2>/dev/null)"
    echo "$out" | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n1
}

app_ver() {
    echo $("$1" --version 2>/dev/null | head -n1)
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

    local input_stream=$(ls *.mkv)
    local size_bytes=$(size_bytes_from_file "$input_stream")
    local human_size=$(human_size_from_file "$size_bytes")

    echo
    echo "* Date/time: $(date)"
    echo "* Source file: \"$input_stream\""
    echo "* File size: $human_size ($size_bytes bytes)"
}

#retrieve_stream_local() {
#    path="${line:7}"
#    filename="$(basename "$path")"
#    ln -s "$path" "$filename"
#    input_files=( "$filename" )
#    if [[ $(file -brL --mime-type "$filename") == "video/x-matroska" ]]
#    then
#        # Cover/thumbnail
#        json=$(mkvmerge "$filename" -J | \
#            jq '.attachments | map(select(.file_name | startswith("cover")))')
#        id=$(echo "$json" | jq -r .[0].id)
#        file_name=$(echo "$json" | jq -r .[0].file_name)
#        mkvextract attachments "$filename" "$id":"$file_name"
#        thumbnail_files=( "$file_name" )
#        # Description/annotation
#        json=$(mkvmerge "$filename" -J | \
#            jq '.attachments | map(select(.file_name == "description.txt"))')
#        id=$(echo "$json" | jq -r .[0].id)
#        file_name=$(echo "$json" | jq -r .[0].file_name)
#        mkvextract attachments "$filename" "$id":"$file_name.description"
#        desc_files=( "$file_name.description" )
#    fi
#}

extract_tracks() {
    echo "$STEP.) Extracting tracks"

    ln -sL ../dl/*.mkv input_stream
    if [ -f ../dl/*.png ]; then ln -sL ../dl/*.png cover; fi
    if [ -f ../dl/*.description ]; then
        ln -sL ../dl/*.description description
    fi

    # This step looks like not necessary, although some tools like
    # ffmpeg-normalize can't read from stdin or can parse only certain container
    # formats. Also it catches possible corrupted input files early.
    local source_info=$(ffprobe -v error -print_format json -show_format \
                        -show_streams input_stream)
    local -a tracks=()
    while IFS= read -r item; do
        local type=$(echo "$item" | jq -r '.codec_type')
        local tid=$(echo "$item" | jq -r '.index')
        if [[ "$type" == "audio" ]]; then
            echo "Source audio (id $tid) stream info:"
            echo "$(echo "$item" | jq -r 'del(.disposition)')"
            tracks+=("$tid audio")
        elif [[ "$type" == "video" ]]; then
            echo "Source video (id $tid) stream info:"
            echo "$(echo "$item" | jq -r 'del(.disposition)')"
            tracks+=("$tid video")
        else
            echo "BUG: Unsupported track type: $type"
        fi
    done < <(echo "$source_info" | jq -rc '.streams[]')

    for track in "${tracks[@]}"; do
        local tid=$(echo "$track" | cut -d" " -f1)
        local type=$(echo "$track" | cut -d" " -f2)
        ffmpeg -hide_banner -nostdin -loglevel quiet -i input_stream \
               -map 0:"$tid" -c copy -f matroska "$type$tid"
    done

    echo "$source_info" > source_info
}

process_cover() {
    echo "$STEP.) Processing cover image"

    if [[ -f "../src/cover" ]]; then
        if [[ "$IMAGE_ENCODER" == copy ]]; then
            echo "Copying image without encoding"
            ln -s ../src/cover cover
        elif [[ "$IMAGE_ENCODER" == avifenc ]]; then
            echo "Encoding image with avifenc v$(app_ver_short avifenc)"
            echo "Arguments: ${AVIFENC_ARGS[@]}"
            avifenc "${AVIFENC_ARGS[@]}" ../src/cover cover
        fi
    else
        echo "No cover image in source stream"
    fi
}

process_audio() {
    echo "$STEP.) Processing audio"
    local ss_info=$(cat ../src/source_info)

    for track in ../src/audio*; do
        local regex='s/.*audio\([0-9]*\)/\1/p'
        local track_id=$(echo "$track" | sed -n "$regex")

        if [ $DRC -eq 1 ]; then
            echo "Applying DRC with ffmpeg-normalize v$(app_ver_short ffmpeg-normalize)"
            echo "Arguments: ${FFMPEG_NORMALIZE_ARGS[@]}"
            local jq_s=".streams[] | select(.index == $track_id) | .sample_rate"
            local sample_rate=$(echo "$ss_info" | jq -r "$jq_s")
            NO_COLOR=1 ffmpeg-normalize "$track" -ar $sample_rate -c:a flac \
                -v "${FFMPEG_NORMALIZE_ARGS[@]}" -e="-sample_fmt s16" -o norm.flac
            mv -f norm.flac "$track"
        fi

        if [[ "$AUDIO_ENCODER" == copy ]]; then
            echo "Skipping re-encoding: \"copy\" encoder specified"
            ln -sL "$track" $(basename $track)
            return
        fi

        if [[ "$AUDIO_DECODER" == vspipe ]]; then
            echo "Using decoder: vspipe v$(app_ver_short vspipe)"
            echo "Preparing VapourSynth script \"$VAPOURSYNTH_AUDIO_SCRIPT\""
            echo "$(cat "$CURR_DIR/vpy/$VAPOURSYNTH_AUDIO_SCRIPT")" > \
                "$TMPDIR/$AUDIO_VPY_TMP_FILE"
            sed -i "s/%%INPUT_STREAM%%/src\/$(basename $track)/g" \
                "$TMPDIR/$AUDIO_VPY_TMP_FILE"

            if [[ "$AUDIO_ENCODER" == opusenc ]]; then
                echo "Using encoder: opusenc v$(app_ver_short opusenc)"
                echo "Arguments: ${OPUSENC_ARGS[@]}"
                vspipe -c wav "$TMPDIR/$AUDIO_VPY_TMP_FILE" - | \
                    opusenc "${OPUSENC_ARGS[@]}" --ignorelength - $(basename "$track")
            fi

        elif [[ "$AUDIO_DECODER" == ffmpeg ]]; then
            echo "Using decoder: ffmpeg v$(app_ver_short ffmpeg)"
            echo "Arguments: ${FFMPEG_AUDIO_ARGS[@]}"

            if [[ "$AUDIO_ENCODER" == opusenc ]]; then
                echo "Using encoder: opusenc v$(app_ver_short opusenc)"
                echo "Arguments: ${OPUSENC_ARGS[@]}"
                ffmpeg -nostdin -loglevel quiet -i "$track" -f wav \
                    "${FFMPEG_AUDIO_ARGS[@]}" - | opusenc "${OPUSENC_ARGS[@]}" \
                    --ignorelength - $(basename "$track")
            fi

        elif [[ "$AUDIO_DECODER" == mpv ]]; then
            echo "Using decoder: mpv v$(app_ver_short mpv)"
            echo "Arguments: ${MPV_AUDIO_ARGS[@]}"

            if [[ "$AUDIO_ENCODER" == opusenc ]]; then
                echo "Using encoder: opusenc v$(app_ver_short opusenc)"
                echo "Arguments: ${OPUSENC_ARGS[@]}"
                mpv --no-video --ao=pcm --ao-pcm-waveheader=yes \
                    --ao-pcm-file=/dev/stdout "$track" --no-input-cursor \
                    --really-quiet --no-input-default-bindings \
                    --input-vo-keyboard=no "${MPV_AUDIO_ARGS[@]}" | \
                    opusenc "${OPUSENC_ARGS[@]}" --ignorelength - $(basename "$track")
            fi

        elif [[ "$AUDIO_DECODER" == mplayer ]]; then
            echo "Using decoder: mplayer v$(app_ver_short mplayer)"
            echo "Arguments: ${MPLAYER_AUDIO_ARGS[@]}"

            if [[ "$AUDIO_ENCODER" == opusenc ]]; then
                echo "Using encoder: opusenc v$(app_ver_short opusenc)"
                echo "Arguments: ${OPUSENC_ARGS[@]}"
                mplayer -noconsolecontrols -really-quiet -vo null \
                    -ao pcm:fast:file=/dev/stdout "${MPLAYER_AUDIO_ARGS[@]}" "$track" | \
                    opusenc "${OPUSENC_ARGS[@]}" --ignorelength - $(basename "$track")
            fi
        fi
    done
}

process_video() {
    echo "$STEP.) Processing video"

    for track in ../src/video*; do
        local regex='s/.*video\([0-9]*\)/\1/p'
        local track_id=$(echo "$track" | sed -n "$regex")
        local ss_info=$(cat ../src/source_info)
        local jq_s=".streams[] | select(.index == $track_id) | .width"
        local width=$(echo "$ss_info" | jq -r "$jq_s")
        local jq_s=".streams[] | select(.index == $track_id) | .height"
        local height=$(echo "$ss_info" | jq -r "$jq_s")
        local jq_s=".streams[] | select(.index == $track_id) | .r_frame_rate"
        local frame_rate=$(echo "$ss_info" | jq -r "$jq_s")
        local fps=$(echo "$frame_rate" | awk -F/ '{print $1/$2}')

        if [[ "$VIDEO_ENCODER" == copy ]]; then
            echo "Skipping re-encoding: \"copy\" encoder specified"
            ln -sL "$track" $(basename $track)
            return
        fi

        echo "Video track source resolution: ${width}x${height}"

        if [[ "$VIDEO_DECODER" == vspipe ]]; then
            echo "Using decoder: vspipe v$(app_ver_short vspipe)"
            echo "Preparing VapourSynth script \"$VAPOURSYNTH_VIDEO_SCRIPT\""
            echo "$(cat "$CURR_DIR/vpy/$VAPOURSYNTH_VIDEO_SCRIPT")" > \
                "$TMPDIR/$VIDEO_VPY_TMP_FILE"
            sed -i "s/%%INPUT_STREAM%%/src\/$(basename $track)/g" \
                "$TMPDIR/$VIDEO_VPY_TMP_FILE"
            sed -i "s/%%VIDEO_WIDTH%%/$width/g" "$TMPDIR/$VIDEO_VPY_TMP_FILE"
            sed -i "s/%%VIDEO_HEIGHT%%/$height/g" "$TMPDIR/$VIDEO_VPY_TMP_FILE"

            if [[ "$VIDEO_ENCODER" == svt_av1_hdr ]]; then
                echo "Using encoder: SvtAv1EncApp v$(app_ver_short SvtAv1EncApp)"
                echo "Arguments: ${SVT_AV1_HDR_ARGS[@]}"
                vspipe -c y4m "$TMPDIR/$VIDEO_VPY_TMP_FILE" - | \
                    SvtAv1EncApp "${SVT_AV1_HDR_ARGS[@]}" -b $(basename $track) -i stdin

            elif [[ "$VIDEO_ENCODER" == ffmpeg ]]; then
                echo "Using encoder: ffmpeg v$(app_ver_short ffmpeg)"
                echo "Arguments: ${FFMPEG_VENC_ARGS[@]}"
                vspipe -c y4m "$TMPDIR/$VIDEO_VPY_TMP_FILE" - | \
                    ffmpeg -hide_banner -nostdin -i - "${FFMPEG_VENC_ARGS[@]}" \
                           -f matroska -stats_period 10 $(basename $track)
            fi

        elif [[ "$VIDEO_DECODER" == ffmpeg ]]; then
            local ffmpeg_args=$(echo "${FFMPEG_VIDEO_ARGS[@]}" | \
                sed "s/%%VIDEO_WIDTH%%/$width/g" | \
                sed "s/%%VIDEO_HEIGHT%%/$height/g")
            echo "Using decoder: ffmpeg v$(app_ver_short ffmpeg)"
            echo "Arguments: $ffmpeg_args"

            if [[ "$VIDEO_ENCODER" == svt_av1_hdr ]]; then
                echo "Using encoder: SvtAv1EncApp v$(app_ver_short SvtAv1EncApp)"
                echo "Arguments: ${SVT_AV1_HDR_ARGS[@]}"
                ffmpeg -nostdin -loglevel quiet -i "$track" $ffmpeg_args \
                       -f yuv4mpegpipe - | SvtAv1EncApp "${SVT_AV1_HDR_ARGS[@]}"\
                       -b $(basename $track) -i stdin

            elif [[ "$VIDEO_ENCODER" == ffmpeg ]]; then
                echo "Using encoder: ffmpeg v$(app_ver_short ffmpeg)"
                echo "Arguments: ${FFMPEG_VENC_ARGS[@]}"
                ffmpeg -nostdin -loglevel quiet -i "$track" $ffmpeg_args \
                       -f yuv4mpegpipe - | ffmpeg -i - "${FFMPEG_VENC_ARGS[@]}" \
                       -f matroska -stats_period 10 $(basename $track)
            fi

        elif [[ "$VIDEO_DECODER" == mpv ]]; then
            # MPV has buggy y4m output (fps multiplied by 1000).
            # Use raw video output.
            local mpv_args=$(echo "${MPV_VIDEO_ARGS[@]}" | \
                sed "s/%%VIDEO_WIDTH%%/$width/g" | \
                sed "s/%%VIDEO_HEIGHT%%/$height/g")
            echo "Using decoder: mpv v$(app_ver_short mpv)"
            echo "Arguments: $mpv_args"
            local regex='s/.*format=\([[:alnum:]]*\).*/\1/p'
            local pix_fmt=$(echo "$mpv_args" | sed -n "$regex")
            if [[ "$pix_fmt" == yuv420p ]]; then
                local depth=8
            elif [[ "$pix_fmt" == yuv420p10le ]]; then
                local depth=10
            else
                halt "Unsupported pixel format. Check mpv options."
            fi

            if [[ "$VIDEO_ENCODER" == svt_av1_hdr ]]; then
                local -n args="${VIDEO_ENCODER}_ARGS"
                echo "Using encoder: SvtAv1EncApp v$(app_ver_short SvtAv1EncApp)"
                echo "Arguments: ${SVT_AV1_HDR_ARGS[@]}"
                mpv --no-audio --o=- --no-input-cursor --really-quiet \
                    --no-input-default-bindings --input-vo-keyboard=no \
                    $mpv_args --of=rawvideo "$track" | \
                    SvtAv1EncApp "${SVT_AV1_HDR_ARGS[@]}" -b $(basename $track) -i stdin \
                        -w $width -h $height --input-depth $depth --fps $fps

            elif [[ "$VIDEO_ENCODER" == ffmpeg ]]; then
                echo "Using encoder: ffmpeg v$(app_ver_short ffmpeg)"
                echo "Arguments: ${FFMPEG_VENC_ARGS[@]}"
                mpv --no-audio --o=- --no-input-cursor --really-quiet \
                    --no-input-default-bindings --input-vo-keyboard=no \
                    $mpv_args --of=rawvideo "$track" | \
                    ffmpeg -hide_banner -nostdin -f rawvideo -pix_fmt $pix_fmt \
                           -s ${width}:${height} -r $fps -i - \
                           "${FFMPEG_VENC_ARGS[@]}" -f matroska \
                           -stats_period 10 $(basename $track)
            fi

        elif [[ "$VIDEO_DECODER" == mplayer ]]; then
            # MPlayer only supports 8-bit y4m output and no raw video output.
            local mplayer_args=$(echo "${MPLAYER_VIDEO_ARGS[@]}" | \
                sed "s/%%VIDEO_WIDTH%%/$width/g" | \
                sed "s/%%VIDEO_HEIGHT%%/$height/g")
            echo "Using decoder: mplayer v$(app_ver_short mplayer)"
            echo "Arguments: $mplayer_args"

            if [[ "$VIDEO_ENCODER" == svt_av1_hdr ]]; then
                echo "Using encoder: SvtAv1EncApp v$(app_ver_short SvtAv1EncApp)"
                echo "Arguments: ${SVT_AV1_HDR_ARGS[@]}"
                mplayer -ao null -vo yuv4mpeg:file=/dev/stdout -noconsolecontrols \
                    -really-quiet $mplayer_args "$track" | \
                    SvtAv1EncApp "${SVT_AV1_HDR_ARGS[@]}" -b $(basename $track) -i stdin

            elif [[ "$VIDEO_ENCODER" == ffmpeg ]]; then
                echo "Using encoder: ffmpeg v$(app_ver_short ffmpeg)"
                echo "Arguments: ${FFMPEG_VENC_ARGS[@]}"
                mplayer -ao null -vo yuv4mpeg:file=/dev/stdout -noconsolecontrols \
                    -really-quiet $mplayer_args "$track" | \
                    ffmpeg -hide_banner -nostdin -i - "${FFMPEG_VENC_ARGS[@]}" \
                           -f matroska -stats_period 10 $(basename $track)
            fi

        else
            halt "Unsupported decoder specified"
        fi
    done
}

process_one() {
    local stream="$1"
    local start_seconds=$(date +%s)

    echo "WebRip19 Batch Video Archiving tool v$SCRIPT_VERSION: $SCRIPT_URL"
    echo
    echo "::: Processing stream $STREAM_NUM of $STREAM_COUNT: $stream"
    echo

    mkdir -p "$TMPDIR/dl"
    mkdir -p "$TMPDIR/src"
    mkdir -p "$TMPDIR/dst"

    # Get the source file
    cd "$TMPDIR/dl"
    if [[ "$stream" == https://* || "$stream" == http://* ]]; then
        retrieve_stream_yt_dlp "$stream"
        echo
    elif [[ "$stream" == file://* ]]; then
        #retrieve_stream_local "$stream"
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

    # Move remaining unprocessed files to destination dir
    if [ -f ../src/description ]; then
        mv -f ../src/description .
    fi

    local tot_size=0
    for f in video* audio* cover description; do
        [ -f "$f" ] || continue
        ((tot_size += $(size_bytes_from_file "$f")))
    done

    # Remove unnecessary files
    rm -f ../src/audio*
    rm -f ../src/video*

    echo "* Output data size: $(human_size_from_file $tot_size) ($tot_size bytes)"

    local end_seconds=$(date +%s)
    local elapsed=$((end_seconds - start_seconds))
    printf '* Processing time: %dd %02dh %02dm %02ds\n' \
        $((elapsed/86400)) $((elapsed%86400/3600)) \
        $((elapsed%3600/60)) $((elapsed%60))
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
        halt "Error: Playlist '$playlist' not found."
    fi

    # Read playlist line by line
    while IFS="" read -r line || [ -n "$line" ]; do
        # Skip empty lines or lines starting with '#'
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        out_array+=("$line")
    done < "$playlist"
}


REGEX_SCHEMA='s|^\([a-zA-Z][a-zA-Z0-9+.-]*\)://.*|\1|; t; d'
REGEX_HOST='s|^[^:]*://||; s|/.*$||; s|;.*$||'
REGEX_PATH1='s|^[^:]*://[^/]*||; s|;.*$||'
REGEX_PATH2='s|.*;path=\([^;]*\).*|\1|; t; d'
OUTPUT_DIR_SCHEMA=$(echo "$OUTPUT_DIR" | sed -e "$REGEX_SCHEMA")
OUTPUT_DIR_HOST=$(echo "$OUTPUT_DIR" | sed -e "$REGEX_HOST")
OUTPUT_DIR_PATH=$(echo "$OUTPUT_DIR" | sed -e "$REGEX_PATH2")
if [ -z "$OUTPUT_DIR_PATH" ]; then
    OUTPUT_DIR_PATH=$(echo "$OUTPUT_DIR" | sed -e "$REGEX_PATH1")
fi

declare -a streams
extract_m3u_paths "$PLAYLIST" streams

STREAM_NUM=1
STREAM_COUNT="${#streams[@]}"

finalize_stream() {
    # Prepare tracks mapping
    local -a inputs=()
    local -a maps=()
    local track_idx=0
    for f in video*; do
        [[ -e "$f" ]] || continue
        inputs+=( -i "$f" )
        maps+=( -map "$track_idx:v:0" )
        ((++track_idx))
    done
    for f in audio*; do
        [[ -e "$f" ]] || continue
        inputs+=( -i "$f" )
        maps+=( -map "$track_idx:a:0" )
        ((++track_idx))
    done

    # Prepare attachments mapping
    local -a attach_args=()
    local cover_type=$(get_image_type cover)
    local cover_mime=$(echo "$cover_type" | cut -d' ' -f1)
    local cover_ext=$(echo "$cover_type" | cut -d' ' -f2)
    local attach_idx=0
    if [ -f cover ]; then
        if [[ "$cover_ext" == bin ]]; then
            halt "Unknown cover image format"
        fi
        attach_args+=( -attach cover -metadata:s:t:$attach_idx \
                        mimetype="$cover_mime",filename=cover."$cover_ext" )
        ((++attach_idx))
    fi
    if [ -f description ]; then
        attach_args+=( -attach description -metadata:s:t:$attach_idx \
                        mimetype=text/plain,filename=description.txt )
        ((++attach_idx))
    fi
    attach_args+=( -attach "../$LOG_FILE" -metadata:s:t:$attach_idx \
                    mimetype=text/x-log,filename="$LOG_FILE" )
    ((++attach_idx))

    # Prepare output file name
    local listing prefix
    local output_num=1
    if [ -z "$OUTPUT_DIR_SCHEMA" ]; then
        mkdir -p "$OUTPUT_DIR"
        listing=$(ls "$OUTPUT_DIR")
    elif [[ "$OUTPUT_DIR_SCHEMA" == "ssh" ]]; then
        listing=$(ssh "$OUTPUT_DIR_HOST" \
                  "mkdir -p $OUTPUT_DIR_PATH && ls $OUTPUT_DIR_PATH" )
    fi
    while [ 1 ]; do
        prefix=$(printf "%04d\n" $output_num)
        if echo "$listing" | grep "^$prefix#" >/dev/null 2>&1; then
            ((++output_num))
            continue
        fi
        break
    done

    # Mux output file
    local old_name=$(readlink ../src/input_stream)
    local old_basename=$(basename "$old_name")
    local output_file_path
    local -a mux_args=( "${inputs[@]}" -i ../src/input_stream "${maps[@]}" \
                        -map_chapters $track_idx "${attach_args[@]}" )
    echo "Using multiplexer: ffmpeg v$(app_ver_short ffmpeg)"
    echo "Arguments: ${mux_args[@]}"

    if [ -z "$OUTPUT_DIR_SCHEMA" ]; then
        output_file_path=$(printf '%q' "$OUTPUT_DIR/$prefix# $old_basename" | \
            sed 's|\\~|~|g')
        ffmpeg -hide_banner -nostdin -loglevel error "${mux_args[@]}" -c copy \
            -f matroska "$(eval echo $output_file_path)"
    elif [[ "$OUTPUT_DIR_SCHEMA" == "ssh" ]]; then
        output_file_path=$(printf '%q' \
            "$OUTPUT_DIR_PATH/$prefix# $old_basename" | sed 's|\\~|~|g')
        ffmpeg -hide_banner -nostdin -loglevel error "${mux_args[@]}" -c copy \
            -f matroska - | ssh "$OUTPUT_DIR_HOST" \
                "cat > \"\$(eval echo \"$output_file_path\")\""
    fi
}

main_loop() {
    for stream in "${streams[@]}"; do
        STEP=0

        # Cleanup remainings from previous runs
        cd "$TMPDIR"
        rm -f "$LOG_FILE"
        rm -f "$AUDIO_VPY_TMP_FILE"
        rm -f "$VIDEO_VPY_TMP_FILE"
        rm -rf src
        rm -rf dst

        # Process one item, logging console output
        process_one $stream > >(tee -a "$TMPDIR/$LOG_FILE") 2>&1
        sync

        # Squash progress bars in the log
        sed -i 's/.*\r//;:a;s/.\x08//;ta;s/\x08//;s/[[:space:]]\+$//' \
            "$TMPDIR/$LOG_FILE"

        cd "$TMPDIR/dst"
        finalize_stream

        # Cleanup
        cd "$TMPDIR"
        rm -rf dl
        rm -rf src
        rm -rf dst
        rm -f "$LOG_FILE"
        rm -f "$AUDIO_VPY_TMP_FILE"
        rm -f "$VIDEO_VPY_TMP_FILE"

        STREAM_NUM=$((STREAM_NUM + 1))
        echo
    done
}

main_loop
