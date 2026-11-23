#!/bin/sh
# With no arguments, install the camera and acquire its pinned loader if needed.
if [ "$#" -eq 0 ]; then
    set -- install --download-loader
fi
exec python3 "$(dirname -- "$0")/tools/install.py" "$@"
