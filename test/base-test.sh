#!/bin/bash

# Shared helpers for the bash tests. Source this file.

# Name the site of a silent set -e death in the sourcing test file.
set -E
trap 'echo "  ABORT ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/test/fixtures"

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; [[ -n ${2:-} ]] && echo "       $2" >&2; exit 1; }

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ $actual == "$expected" ]] || fail "$label" "expected: $expected
       actual:   $actual"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ $haystack == *"$needle"* ]] || fail "$label" "missing: $needle
       in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ $haystack != *"$needle"* ]] || fail "$label" "unexpected: $needle"
}

# A sandbox with a fake hyprctl that serves the fixture and records calls.
make_sandbox() {
  local dir
  dir="$(mktemp -d)"
  # Its own runtime dir with no hypr/ inside, so the tests never lean on the
  # host's compositor — the CI runner has none, and a revert timer can fire
  # after Hyprland has gone.
  mkdir -p "$dir/bin" "$dir/state" "$dir/runtime" "$dir/drm/card1-DP-1" "$dir/drm/card1-DP-2"
  cp "$FIXTURES/mateview-dp1.edid" "$dir/drm/card1-DP-1/edid"
  cp "$FIXTURES/mateview-dp1.edid" "$dir/drm/card1-DP-2/edid"
  cat > "$dir/bin/hyprctl" <<EOF
#!/bin/bash
echo "\$*" >> "$dir/hyprctl.log"
case "\$1 \$2" in
  "monitors all") cat "$dir/monitors.json" ;;
  "getoption render:cm_auto_hdr") echo '{"option":"render:cm_auto_hdr","int":1}' ;;
  "getoption render:cm_sdr_eotf") echo '{"option":"render:cm_sdr_eotf","str":"default"}' ;;
  "eval "*)
    printf '%s\n' "\$2" > "$dir/eval-last.txt"
    if [[ "\${FAKE_HYPRCTL_EVAL_FAIL:-}" == "1" ]]; then
      echo "fake hyprctl: eval rejected" >&2
      exit 1
    fi
    echo ok
    ;;
  "reload "*|"reload") echo ok ;;
  "configerrors "*|"configerrors") echo ok ;;
  *) echo "unhandled: \$*" >&2; exit 1 ;;
esac
EOF
  cat > "$dir/bin/omarchy-brightness-display" <<'EOF'
#!/bin/bash
echo 62
EOF
  cat > "$dir/bin/omarchy-shell" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$dir/bin/systemd-run" <<EOF
#!/bin/bash
echo "\$*" >> "$dir/systemd-run.log"
EOF
  cat > "$dir/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$dir/systemctl.log"
exit 0
EOF
  cat > "$dir/bin/omarchy-notification-send" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$dir"/bin/*
  cp "$FIXTURES/hyprctl-monitors.json" "$dir/monitors.json"
  echo "$dir"
}

run_cli() {
  local sandbox="$1"; shift
  PATH="$sandbox/bin:$PATH" \
  XDG_RUNTIME_DIR="$sandbox/runtime" \
  HYPRLAND_INSTANCE_SIGNATURE="" \
  OMARCHY_DRM_PATH="$sandbox/drm" \
  OMARCHY_DISPLAYS_STATE_DIR="$sandbox/state" \
  OMARCHY_DISPLAYS_LUA_FILE="$sandbox/state/displays-layout.lua" \
  HOME="$sandbox" \
    "$ROOT/bin/omarchy-displays" "$@"
}
