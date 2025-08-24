#!/bin/bash

set -e

# Usage example:
# ./yt-playlist.sh 'https://www.youtube.com/watch?v=&list=PLbpi6ZahtOH6rCGVbivmx20zx88ZKtUXl'

#
# SPDX-License-Identifier: WTFPL
#
# Authors and copyright holders provide the licensed software “as is” and do not
# provide any warranties, including the merchantability of the software and
# suitability for any purpose.
#

echo -e '#EXTM3U\n' > playlist.m3u
yt-dlp -j --flat-playlist "$1" | jq -r .url | tac >> playlist.m3u