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
  # A transient unit counts as running from systemd-run until systemctl stops it.
  cat > "$dir/bin/systemd-run" <<EOF
#!/bin/bash
echo "\$*" >> "$dir/systemd-run.log"
for a in "\$@"; do case \$a in --unit=*) mkdir -p "$dir/units"; touch "$dir/units/\${a#--unit=}.service" ;; esac; done
exit 0
EOF
  cat > "$dir/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$dir/systemctl.log"
case "\$1 \$2" in
  "--user is-active") [[ -e "$dir/units/\${@: -1}" ]]; exit \$? ;;
  "--user stop") shift 2; for u in "\$@"; do rm -f "$dir/units/\$u"; done ;;
esac
exit 0
EOF
  # wayvnc and friends, so the virtual display paths run without the real ones.
  cat > "$dir/bin/wayvnc" <<EOF
#!/bin/bash
echo "\$*" >> "$dir/wayvnc.log"
EOF
  cat > "$dir/bin/wayvncctl" <<EOF
#!/bin/bash
echo "\$*" >> "$dir/wayvncctl.log"
case "\$*" in *client-list*) echo '[{"id":"7","address":"192.168.1.40"}]' ;; esac
exit 0
EOF
  cat > "$dir/bin/vncviewer" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$dir/bin/ssh-keygen" <<'EOF'
#!/bin/bash
while (( $# )); do [[ $1 == -f ]] && { printf 'not a key: the test stand-in for ssh-keygen\n' > "$2"; : > "$2.pub"; }; shift; done
EOF
  # The desk's addresses: loopback, the LAN, and libvirt's bridge.
  cat > "$dir/bin/ip" <<'EOF'
#!/bin/bash
printf '1: lo    inet 127.0.0.1/8 scope host lo\n2: enp5s0    inet 192.168.1.89/24 brd 192.168.1.255 scope global enp5s0\n4: virbr0    inet 192.168.122.1/24 brd 192.168.122.255 scope global virbr0\n'
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
  printf '%s\n' '{"cm_auto_hdr":1,"cm_sdr_eotf":"default"}' > "$dir/global.json"
  # The open workspaces on this desk on 5 October 2026: 1 on DP-1 with four
  # windows, 2 on DP-2 with one. The laptop has one, on its panel.
  if [[ $fixture == laptop ]]; then
    printf '%s\n' '[{"id":1,"name":"1","monitor":"eDP-1","windows":2}]' > "$dir/workspaces.json"
  else
    printf '%s\n' '[{"id":1,"name":"1","monitor":"DP-1","windows":4},{"id":2,"name":"2","monitor":"DP-2","windows":1}]' > "$dir/workspaces.json"
  fi
  echo '[]' > "$dir/wsrules.json"
  echo '[]' > "$dir/virtual.json"
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
  OMARCHY_CANDELA_VNC_WAIT_SECONDS=0 \
  HOME="$sandbox" \
    "$ROOT/bin/omarchy-candela" "$@"
}
