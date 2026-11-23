#!/bin/sh
# Keep relative folder arguments relative to the caller's working directory.
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1

show_error() {
    printf '%s\n' "$1" >&2
    if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
        if command -v kdialog >/dev/null 2>&1; then
            kdialog --title "TerraTech Legion Photo Developer" --error "$1"
        elif command -v zenity >/dev/null 2>&1; then
            zenity --error --title="TerraTech Legion Photo Developer" --no-markup --text="$1"
        elif command -v xmessage >/dev/null 2>&1; then
            xmessage -center "$1"
        fi
    fi
}

python="$package_dir/.venv/bin/python"
if [ ! -x "$python" ]; then
    python=$(command -v python3) || {
        show_error "Install Python 3 with Tk support to launch TerraTech Legion Photo Developer."
        exit 1
    }
fi

output=$("$python" "$package_dir/tools/develop_photos.py" "$@" 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
    show_error "TerraTech Legion Photo Developer could not run. Check that your Python installation includes Tk (tkinter).

$output"
elif [ -n "$output" ]; then
    printf '%s\n' "$output"
fi
exit "$status"
