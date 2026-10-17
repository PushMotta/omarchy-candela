#!/bin/bash

# Kept settings belong to the display they were chosen for: a different
# display plugged into the same port never takes them. The case that found
# this, on the desk on 17 October 2026: two MateViews replaced by two ASUS
# PA278QV, and the rule kept for the MateView on DP-1 (off) kept switching the
# new display off.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

sandboxes=()
trap 'rm -rf "${sandboxes[@]}"' EXIT
new_sandbox() {
  local dir
  dir="$(make_sandbox "$@")"
  sandboxes+=("$dir")
  echo "$dir"
}

MV1='desc:Huawei Technologies Co. Inc. MateView               (DP-1)'
MV2='desc:Huawei Technologies Co. Inc. MateView               (DP-2)'

mon() { jq -r --arg n "$2" ".[] | select(.name == \$n) | .$3" "$1/monitors.json"; }
reload() { PATH="$1/bin:$PATH" hyprctl reload >/dev/null; }
reloads() { grep -c '^reload' "$1/hyprctl.log" || true; }

# Plug a different display into a port: the fixture's live and pristine
# state both change, the way Hyprland's would, and it comes up the way the
# compositor's own defaults put it.
plug() {
  local sandbox="$1" port="$2" kind="$3" serial="${4:-}" display
  case $kind in
    asus) display="$(jq -nc --arg s "$serial" '{make:"ASUSTek COMPUTER INC", model:"PA278QV", serial:$s,
            description:("ASUSTek COMPUTER INC PA278QV " + $s), width:2560, height:1440, refreshRate:59.951, scale:1,
            availableModes:["2560x1440@59.95Hz","2560x1440@74.92Hz","1920x1080@60.00Hz"]}')" ;;
    mateview) display="$(jq -c --arg p "$port" '.[] | select(.name == $p) | {make, model, serial, description, width, height, refreshRate, scale, availableModes}' "$FIXTURES/hyprctl-monitors.json")" ;;
  esac
  for f in monitors.json monitors.pristine.json; do
    jq --arg p "$port" --argjson d "$display" 'map(if .name == $p then . + $d + {disabled: false} else . end)' "$sandbox/$f" > "$sandbox/m.tmp" && mv "$sandbox/m.tmp" "$sandbox/$f"
  done
}

# ---- a display swapped in on a port never takes the old one's rule
sandbox="$(new_sandbox)"
run_cli "$sandbox" apply --now '{"displays":[{"name":"DP-2","scale":2}]}' >/dev/null
run_cli "$sandbox" apply --now '{"displays":[{"name":"DP-1","enabled":false}]}' >/dev/null
assert_eq "$(mon "$sandbox" DP-1 disabled)" "true" "the MateView on DP-1 is kept off"
lua="$(cat "$sandbox/state/candela-layout.lua")"
assert_contains "$lua" "hl.monitor({ output = \"$MV1\", disabled = true })" "its rule names the MateView on DP-1"
assert_not_contains "$lua" 'output = "DP-1"' "and never the port alone"
assert_eq "$(jq -c '.displays["DP-1"].identity' "$sandbox/state/intent.json")" \
  '{"make":"Huawei Technologies Co., Inc.","model":"MateView","serial":"             "}' "intent records whose settings they are"

plug "$sandbox" DP-1 asus R1LMQS047678
reload "$sandbox"
assert_eq "$(mon "$sandbox" DP-1 disabled)" "false" "the ASUS plugged into DP-1 stays on"
assert_eq "$(mon "$sandbox" DP-1 width)" "2560" "at its own mode"
assert_eq "$(mon "$sandbox" DP-2 scale)" "2" "and the MateView left on DP-2 keeps its settings"
state="$(run_cli "$sandbox" state)"
assert_eq "$(jq -c '.displays[] | select(.name == "DP-1") | .kept' <<<"$state")" "{}" "state shows nothing kept for the ASUS"
assert_eq "$(jq -r '.displays[] | select(.name == "DP-1") | .keptForOther' <<<"$state")" "Huawei Technologies Co. Inc. MateView" "and whose settings the port holds"
assert_eq "$(jq -r '.displays[] | select(.name == "DP-2") | .kept.scale' <<<"$state")" "2" "the MateView on DP-2 still shows its own"
out="$(run_cli "$sandbox" doctor || true)"
assert_contains "$out" "DP-1: the settings kept there are for a Huawei Technologies Co. Inc. MateView; the ASUSTek COMPUTER INC PA278QV on it now has your monitors.lua settings" "doctor says so"
assert_eq "$(run_cli "$sandbox" reconcile)" "up to date" "nothing to reconcile: no display here has a rule missing"
pass "a different display on the port gets the user's own settings, not the old display's"

# Back comes the MateView, before the ASUS was set up: its rule was kept.
plug "$sandbox" DP-1 mateview
reload "$sandbox"
assert_eq "$(mon "$sandbox" DP-1 disabled)" "true" "the MateView back on DP-1 is off again, as kept"
pass "the display the settings were kept for gets them back"

# Set up the ASUS: the port's settings become its own, from a clean start.
plug "$sandbox" DP-1 asus R1LMQS047678
reload "$sandbox"
run_cli "$sandbox" apply --now '{"displays":[{"name":"DP-1","scale":1.25}]}' >/dev/null
assert_eq "$(jq -c '.displays["DP-1"] | {identity, enabled}' "$sandbox/state/intent.json")" \
  '{"identity":{"make":"ASUSTek COMPUTER INC","model":"PA278QV","serial":"R1LMQS047678"},"enabled":null}' "the entry is the ASUS's now, with nothing of the MateView's"
lua="$(cat "$sandbox/state/candela-layout.lua")"
assert_contains "$lua" 'output = "desc:ASUSTek COMPUTER INC PA278QV R1LMQS047678 (DP-1)", disabled = false, mode = "2560x1440@59.95", position = "0x0", scale = 1.25' "the rule names the ASUS on DP-1"
assert_not_contains "$lua" "$MV1" "and the MateView's rule is gone"
assert_eq "$(mon "$sandbox" DP-1 scale)" "1.25" "the compositor agrees"
pass "setting up the new display replaces the old one's settings"

# ---- two displays of the same model with no serial keep a rule each
sandbox="$(new_sandbox)"
run_cli "$sandbox" apply --now '{"displays":[{"name":"DP-1","scale":1.25},{"name":"DP-2","scale":2}]}' >/dev/null
reload "$sandbox"
assert_eq "$(mon "$sandbox" DP-1 scale)" "1.25" "DP-1's MateView has its scale"
assert_eq "$(mon "$sandbox" DP-2 scale)" "2" "and DP-2's its own"
pass "identical displays without a serial are told apart by port"

# ---- Candela 1.3.0 kept settings by port. The desk's state on 17 October:
# DP-1's MateView kept off, DP-2's at 3840x2560, both since swapped for ASUS.
legacy_desk() {
  local sandbox="$1"
  cat > "$sandbox/state/intent.json" <<'EOF'
{"version":1,"displays":{
  "DP-2":{"bitdepth":8,"cm":"srgb","scale":1.6,"enabled":true,"mode":"3840x2560@59.98","position":"2400x0","transform":0},
  "DP-1":{"bitdepth":8,"cm":"srgb","sdrsaturation":0.9,"enabled":false,"mode":"3840x2560@59.98","position":"0x0","scale":1.6,"transform":0},
  "DP-3":{"enabled":false,"mode":"1920x1080@60","position":"6000x0","scale":1,"transform":0}},"global":{}}
EOF
  cat > "$sandbox/state/candela-layout.lua" <<'EOF'
-- Generated by io.github.pushmotta.candela (omarchy-candela). Do not edit: it is rewritten on every keep.
-- Kept 2026-10-16T16:42:43+01:00. Change displays with the Candela panel or `omarchy-candela`.

hl.monitor({ output = "DP-2", disabled = false, mode = "3840x2560@59.98", position = "2400x0", scale = 1.6, transform = 0, bitdepth = 8, cm = "srgb" })
hl.monitor({ output = "DP-1", disabled = true })

-- Not connected now. Kept as last written, so it comes back the same way.
hl.monitor({ output = "DP-3", disabled = true })

omarchy_candela_layout_probe = "1792165363-1194847-4047"
EOF
}

sandbox="$(new_sandbox)"
legacy_desk "$sandbox"
plug "$sandbox" DP-1 asus R1LMQS047678
plug "$sandbox" DP-2 asus NCLMQS025395
reload "$sandbox"
assert_eq "$(mon "$sandbox" DP-1 disabled)" "true" "with the 1.3.0 layout, the new display on DP-1 is switched off (the bug)"
out="$(run_cli "$sandbox" doctor || true)"
assert_contains "$out" "the kept layout names DP-1, DP-2, DP-3 by port" "doctor names the old rules"
before="$(reloads "$sandbox")"
out="$(run_cli "$sandbox" reconcile)"
assert_contains "$out" "reconciled" "reconcile rewrites them"
assert_eq "$(mon "$sandbox" DP-1 disabled)" "false" "and DP-1 is on"
assert_eq "$(mon "$sandbox" DP-1 width)" "2560" "at the ASUS's own mode"
assert_eq "$(jq -c '.displays | keys' "$sandbox/state/intent.json")" '["DP-3"]' "entries naming a mode the ASUS lacks are dropped; DP-3's waits"
lua="$(cat "$sandbox/state/candela-layout.lua")"
assert_not_contains "$lua" 'output = "DP-' "no rule names a port any more"
assert_contains "$lua" 'output = "desc:ASUSTek COMPUTER INC PA278QV R1LMQS047678 (DP-1)", disabled = false, mode = "2560x1440@59.95", position = "0x0", scale = 1,' "the ASUS on DP-1 is declared where monitors.lua put it"
assert_contains "$lua" 'output = "desc:ASUSTek COMPUTER INC PA278QV NCLMQS025395 (DP-2)", disabled = false, mode = "2560x1440@59.95", position = "2400x0", scale = 1,' "and so is DP-2'"'"'s, at its own mode and scale, not the MateView'"'"'s"
assert_eq "$(mon "$sandbox" DP-2 scale)" "1" "the compositor agrees"
out="$(run_cli "$sandbox" doctor || true)"
assert_not_contains "$out" "by port" "doctor has nothing left to say about ports"
before="$(reloads "$sandbox")"
assert_eq "$(run_cli "$sandbox" reconcile)" "up to date" "a second reconcile has nothing to do"
assert_eq "$(reloads "$sandbox")" "$before" "and does not reload"
pass "1.3.0's port rules: reconcile drops the ones that were for another display"

# The same 1.3.0 state with the MateViews still there: their settings are
# theirs, and they keep them.
sandbox="$(new_sandbox)"
legacy_desk "$sandbox"
reload "$sandbox"
run_cli "$sandbox" reconcile >/dev/null
assert_eq "$(jq -r '.displays["DP-1"].identity.model + " " + (.displays["DP-2"].identity.model)' "$sandbox/state/intent.json")" "MateView MateView" "both entries are taken to be the MateViews'"
lua="$(cat "$sandbox/state/candela-layout.lua")"
assert_contains "$lua" "hl.monitor({ output = \"$MV1\", disabled = true })" "DP-1's is written for its MateView"
assert_contains "$lua" "output = \"$MV2\", disabled = false, mode = \"3840x2560@59.98\", position = \"2400x0\", scale = 1.6" "and DP-2's"
assert_eq "$(mon "$sandbox" DP-1 disabled)" "true" "DP-1 stays off"
assert_eq "$(mon "$sandbox" DP-2 scale)" "1.6" "DP-2 keeps its scale"
pass "1.3.0's port rules: reconcile keeps the ones that fit, under the display's name"

# An entry from 1.3.0 that is off and names no mode can belong to nobody.
sandbox="$(new_sandbox)"
printf '%s\n' '{"version":1,"displays":{"DP-1":{"enabled":false}},"global":{}}' > "$sandbox/state/intent.json"
printf '%s\n' 'hl.monitor({ output = "DP-1", disabled = true })' > "$sandbox/state/candela-layout.lua"
run_cli "$sandbox" reconcile >/dev/null
assert_eq "$(mon "$sandbox" DP-1 disabled)" "false" "an old 'off' with nothing to tell whose it was turns nothing off"
pass "an old entry that is off and names no mode is dropped"

# ---- the report says no serials
sandbox="$(new_sandbox)"
plug "$sandbox" DP-1 asus R1LMQS047678
run_cli "$sandbox" apply --now '{"displays":[{"name":"DP-1","scale":1.25}]}' >/dev/null
out="$(run_cli "$sandbox" report)"
assert_not_contains "$out" "R1LMQS047678" "the serial is not in the report"
assert_contains "$out" '"serial": "(removed)"' "it is said to be removed"
pass "the report keeps serials out"
