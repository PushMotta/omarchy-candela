#!/bin/bash
# Offscreen QML component checks. They need the Qt 6 qml runtime and the
# QtQuick modules, which the CI runner lacks (it has qmllint only), so a
# missing runtime is a skip, not a failure; a runtime that cannot load the
# modules is a skip too. Qt sends its logging to journald when stderr is
# not a terminal, hence the two logging variables.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
QML="$(command -v /usr/lib/qt6/bin/qml || command -v qml6 || true)"
if [[ -z $QML ]]; then echo "  skip qml (Qt 6 runtime not found)"; exit 0; fi
status=0
for t in decimal-field.test.qml apply-bar.test.qml; do
  out="$(cd "$root/test" && QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES='*=true' QT_FORCE_STDERR_LOGGING=1 \
         timeout 30 "$QML" -I "$root/test/qml-stubs" "$t" 2>&1 | grep -E '^qml: (ok |FAIL |QML |.*not installed|.*is not a type)' | sed 's/^qml: //')"
  if grep -q 'not installed\|is not a type' <<<"$out"; then echo "  skip $t (QtQuick modules unavailable)"; continue; fi
  if [[ -z $out ]]; then echo "  FAIL $t: the runtime produced no result" >&2; status=1; continue; fi
  sed '/QML PASSED/d;/QML FAILURES/d;s/^/  /' <<<"$out"
  grep -q '^QML PASSED$' <<<"$out" || status=1
done
exit $status
