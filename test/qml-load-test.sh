#!/bin/bash
# Every QML file of the plugin, compiled by a real Quickshell against
# Omarchy's own shell modules (Commons, Ui, services). A file that does not
# compile does not load at all, and qmllint misses some of those: the studio
# would not open on 5 October 2026 over a function declared twice, and lint
# was clean. Runs where the shell runs; skips anywhere else (CI has neither
# Quickshell nor a Wayland session).
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
shell_dir="${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}"
if ! command -v quickshell >/dev/null 2>&1 || [[ ! -d $shell_dir/Commons || -z ${WAYLAND_DISPLAY:-} ]]; then
  echo "  skip qml load (needs quickshell, $shell_dir and a Wayland session)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'kill "${pid:-}" 2>/dev/null; rm -rf "$tmp"' EXIT
# A config of our own whose qs.* modules are the shell's.
for d in "$shell_dir"/*/; do ln -s "${d%/}" "$tmp/$(basename "$d")"; done
cat > "$tmp/shell.qml" <<'QML'
import QtQuick
import Quickshell

ShellRoot {
  Component.onCompleted: {
    var files = Quickshell.env("CANDELA_QML_FILES").split(":")
    var bad = 0
    for (var i = 0; i < files.length; i++) {
      if (!files[i]) continue
      var c = Qt.createComponent("file://" + files[i], Component.PreferSynchronous)
      if (c.status === Component.Ready) console.log("CANDELA-LOAD ok " + files[i])
      else { bad++; console.log("CANDELA-LOAD FAIL " + files[i] + ": " + c.errorString().replace(/\n/g, " | ")) }
    }
    console.log("CANDELA-LOAD done " + bad)
  }
}
QML

files="$(ls "$root"/*.qml "$root"/components/*.qml | tr '\n' ':')"
CANDELA_QML_FILES="$files" quickshell -p "$tmp/shell.qml" > "$tmp/out" 2>&1 &
pid=$!
# Quickshell does not act on Qt.quit(): wait for the verdict, then stop it.
for _ in $(seq 1 150); do grep -q 'CANDELA-LOAD done' "$tmp/out" 2>/dev/null && break; sleep 0.2; done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

status=0
if ! grep -q 'CANDELA-LOAD done' "$tmp/out"; then
  echo "  FAIL quickshell gave no verdict within 30 s" >&2; tail -5 "$tmp/out" >&2; exit 1
fi
while IFS= read -r line; do
  case "$line" in
    "ok "*) ;;
    "FAIL "*) echo "  FAIL ${line#FAIL }" >&2; status=1 ;;
  esac
done < <(grep -o 'CANDELA-LOAD .*' "$tmp/out" | sed 's/^CANDELA-LOAD //')
(( status == 0 )) && echo "  ok   every QML file compiles against the shell's modules ($(grep -c 'CANDELA-LOAD ok' "$tmp/out") files)"
exit $status
