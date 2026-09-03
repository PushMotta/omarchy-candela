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

# A sandbox with a fake hyprctl (test/fake-hyprctl.sh) that keeps a live
# monitor state the way Hyprland does and records every call. $1 picks the
# fixture: "desk" (default, two MateViews) or "laptop" (a built-in panel and
# one MateView).
make_sandbox() {
  local dir fixture="${1:-desk}"
  dir="$(mktemp -d)"
  # Its own runtime dir with no hypr/ inside, so the tests never lean on the
  # host's compositor — the CI runner has none, and a revert timer can fire
  # after Hyprland has gone.
  mkdir -p "$dir/bin" "$dir/state" "$dir/runtime" "$dir/drm/card1-DP-1" "$dir/drm/card1-DP-2" "$dir/drm/card1-eDP-1"
  cp "$FIXTURES/mateview-dp1.edid" "$dir/drm/card1-DP-1/edid"
  cp "$FIXTURES/mateview-dp1.edid" "$dir/drm/card1-DP-2/edid"
  cp "$FIXTURES/mateview-dp1.edid" "$dir/drm/card1-eDP-1/edid"
  cat > "$dir/bin/hyprctl" <<EOF
#!/bin/bash
FAKE_DIR="$dir" exec bash "$ROOT/test/fake-hyprctl.sh" "\$@"
EOF
  # Omarchy's clamshell script is what makes the internal-monitor-scale file
  # worth writing; its presence is all the CLI checks for.
  cat > "$dir/bin/omarchy-hyprland-monitor-clamshell" <<'EOF'
#!/bin/bash
exit 0
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
  local source="$FIXTURES/hyprctl-monitors.json"
  [[ $fixture == laptop ]] && source="$FIXTURES/hyprctl-monitors-laptop.json"
  cp "$source" "$dir/monitors.json"
  cp "$source" "$dir/monitors.pristine.json"
  echo "$dir"
}

run_cli() {
  local sandbox="$1"; shift
  PATH="$sandbox/bin:$PATH" \
  XDG_RUNTIME_DIR="$sandbox/runtime" \
  HYPRLAND_INSTANCE_SIGNATURE="" \
  OMARCHY_DRM_PATH="$sandbox/drm" \
  OMARCHY_CANDELA_STATE_DIR="$sandbox/state" \
  OMARCHY_CANDELA_LUA_FILE="$sandbox/state/candela-layout.lua" \
  OMARCHY_CANDELA_VERIFY_SECONDS="${OMARCHY_CANDELA_VERIFY_SECONDS:-0.5}" \
  HOME="$sandbox" \
    "$ROOT/bin/omarchy-candela" "$@"
}
