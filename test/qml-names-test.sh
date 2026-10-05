#!/bin/bash
# A QML file that declares the same function twice does not load at all, and
# a parse-only lint does not notice: the studio failed to open this way on
# 5 October 2026. Fail on any repeated `function name(` within a file.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
status=0
for f in "$root"/*.qml "$root"/components/*.qml; do
  dupes="$(grep -oE '^  function [A-Za-z0-9_]+\(' "$f" | sort | uniq -d)"
  if [[ -n $dupes ]]; then echo "  FAIL $(basename "$f") declares twice: $(tr '\n' ' ' <<<"$dupes")" >&2; status=1; fi
done
(( status == 0 )) && echo "  ok   no QML file declares a function twice"
exit $status
