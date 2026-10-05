#!/bin/bash

# The compositor the CLI tests talk to. It keeps a monitors JSON the way
# Hyprland keeps its outputs: `eval` applies hl.monitor rules to the live
# state; `reload` rebuilds it from the pristine fixture plus whatever the
# toggles files say, in sorted filename order like Omarchy's loader; a global
# set by the layout file answers the load probe. Knobs, all env vars:
#   FAKE_HYPRCTL_EVAL_FAIL=1          eval is rejected outright
#   FAKE_HYPRCTL_IGNORE_SCALE=1       eval lands everything but the scale
#   FAKE_HYPRCTL_TOGGLES_NOT_LOADED=1 reload reads no toggles files at all
#   FAKE_HYPRCTL_PRESERVE_OMITTED=1   reload starts from current, non-pristine state
#   FAKE_HYPRCTL_RELOAD_FAIL=1        reload fails before changing live state
#   FAKE_HYPRCTL_MOVE_IGNORED=1       a workspace move answers ok and does nothing
#
# Workspaces follow Hyprland 0.56.2's rules as read in its source: an
# hl.workspace_rule merges into an earlier rule with the same workspace text
# (later fields win), a reload clears every rule and re-reads the files, and
# neither moves a workspace that is already open; only a dispatched move does.
# Outputs made with `output create headless` survive a reload, take their rule
# the moment they exist, and open on their default workspace when a rule names
# one; `output remove` refuses a real display.

dir="$FAKE_DIR"
echo "$*" >> "$dir/hyprctl.log"

# lua text on stdin → one JSON object per hl.monitor rule
rules_from() {
  grep -oE 'hl\.monitor\(\{.*\}\)' \
    | sed -E 's/^hl\.monitor\(\{ ?//; s/ ?\}\)$//; s/\[==\[([^]]*)\]==\]/"\1"/g; s/(^|, )([a-z_]+) = /\1"\2": /g; s/^/{/; s/$/}/'
}

# lua text on stdin → one JSON object per hl.workspace_rule
workspace_rules_from() {
  grep -oE 'hl\.workspace_rule\(\{.*\}\)' \
    | sed -E 's/^hl\.workspace_rule\(\{ ?//; s/ ?\}\)$//; s/(^|, )([a-z_]+) = /\1"\2": /g; s/^/{/; s/$/}/'
}

# lua text on stdin, merged into wsrules.json the way replaceOrAdd does
apply_workspace_rules() {
  local rule
  while IFS= read -r rule; do
    [[ -n $rule ]] || continue
    jq --argjson r "$rule" '
      ($r | {workspaceString: .workspace, enabled: true}
        + (if has("monitor") then {monitor} else {} end)
        + (if has("default") then {default} else {} end)
        + (if has("layout") then {layout} else {} end)) as $new
      | (map(.workspaceString) | index($r.workspace)) as $i
      | if $i == null then . + [$new] else .[$i] += ($new | del(.workspaceString)) end' "$dir/wsrules.json" > "$dir/wsrules.json.tmp" && mv "$dir/wsrules.json.tmp" "$dir/wsrules.json"
  done < <(workspace_rules_from)
}

# lua text on stdin, applied rule by rule to monitors.json
apply_rules() {
  local rule
  while IFS= read -r rule; do
    [[ -n $rule ]] || continue
    jq --argjson r "$rule" --arg ignore_scale "${FAKE_HYPRCTL_IGNORE_SCALE:-}" --slurpfile pristine "$dir/monitors.pristine.json" '
      def r2: (. * 100 | round) / 100;
      map(if .name != $r.output then . else
        if $r.disabled == true then .disabled = true | .width = 0 | .height = 0 | .x = 0 | .y = 0
        else
          ([$pristine[0][] | select(.name == $r.output)][0]) as $p
          | .disabled = false
          | (if ($r.mode // "" | test("^[0-9]+x[0-9]+")) then
               ($r.mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)(@(?<r>[0-9.]+))?")) as $m
               | .width = ($m.w | tonumber) | .height = ($m.h | tonumber) | (if $m.r then .refreshRate = ($m.r | tonumber) else . end)
             elif .width == 0 then .width = $p.width | .height = $p.height | .refreshRate = $p.refreshRate
             else . end)
          | (if ($r.position // "" | test("^-?[0-9]+x-?[0-9]+$")) then
               ($r.position | capture("^(?<x>-?[0-9]+)x(?<y>-?[0-9]+)$")) as $pos | .x = ($pos.x | tonumber) | .y = ($pos.y | tonumber)
             else . end)
          | (if ($r.scale | type) == "number" and $ignore_scale != "1" then .scale = ($r.scale | r2) else . end)
          | (if $r.transform != null then .transform = $r.transform else . end)
          | (if $r|has("mirror") then .mirrorOf = (if $r.mirror == "" then "none" else $r.mirror end) else . end)
          | (if $r|has("bitdepth") then .currentFormat = (if $r.bitdepth == 10 then "XBGR2101010" else "XRGB8888" end) else . end)
          | (if $r|has("cm") then .colorManagementPreset = $r.cm else . end)
          | (if $r|has("sdr_max_luminance") then .sdrMaxLuminance = $r.sdr_max_luminance else . end)
          | (if $r|has("sdr_min_luminance") then .sdrMinLuminance = $r.sdr_min_luminance else . end)
          | (if $r|has("sdrbrightness") then .sdrBrightness = $r.sdrbrightness else . end)
          | (if $r|has("sdrsaturation") then .sdrSaturation = $r.sdrsaturation else . end)
          | (if $r|has("vrr") then .vrr = ($r.vrr != 0) else . end)
        end end)' "$dir/monitors.json" > "$dir/monitors.json.tmp" && mv "$dir/monitors.json.tmp" "$dir/monitors.json"
  done < <(rules_from)
}

case "$1 $2" in
  "monitors all") cat "$dir/monitors.json" ;;
  "getoption render:cm_auto_hdr") jq '{option:"render:cm_auto_hdr",int:.cm_auto_hdr}' "$dir/global.json" ;;
  "getoption render:cm_sdr_eotf") jq '{option:"render:cm_sdr_eotf",str:.cm_sdr_eotf}' "$dir/global.json" ;;
  "getoption animations:enabled") jq '{option:"animations:enabled",bool:(if has("animations") then .animations else true end)}' "$dir/global.json" ;;
  "eval "*)
    printf '%s\n' "$2" > "$dir/eval-last.txt"
    if [[ ${FAKE_HYPRCTL_EVAL_FAIL:-} == 1 ]]; then
      echo "fake hyprctl: eval rejected" >&2
      exit 1
    fi
    if [[ $2 == *"assert(omarchy_candela_layout_probe == "* ]]; then
      want="$(sed -nE 's/.*omarchy_candela_layout_probe == "([^"]+)".*/\1/p' <<<"$2")"
      have="$(cat "$dir/probe.txt" 2>/dev/null || true)"
      if [[ -n $want && $want == "$have" ]]; then echo ok; exit 0; fi
      echo "error: [string ...]: candela-layout.lua did not run"
      exit 7
    fi
    apply_rules <<<"$2"
    apply_workspace_rules <<<"$2"
    if [[ $2 =~ cm_auto_hdr[[:space:]]*=[[:space:]]*([012]) ]]; then
      jq --argjson v "${BASH_REMATCH[1]}" '.cm_auto_hdr=$v' "$dir/global.json" > "$dir/global.json.tmp" && mv "$dir/global.json.tmp" "$dir/global.json"
    fi
    echo ok
    ;;
  "reload "*|"reload")
    if [[ ${FAKE_HYPRCTL_RELOAD_FAIL:-} == 1 ]]; then echo "fake hyprctl: reload rejected" >&2; exit 1; fi
    if [[ ${FAKE_HYPRCTL_PRESERVE_OMITTED:-} != 1 ]]; then
      jq -s '.[0] + .[1]' "$dir/monitors.pristine.json" "$dir/virtual.json" > "$dir/monitors.json"
    fi
    : > "$dir/probe.txt"
    echo '[]' > "$dir/wsrules.json"
    if [[ ${FAKE_HYPRCTL_TOGGLES_NOT_LOADED:-} != 1 ]]; then
      # Sorted like require_all: candela-layout, candela-pending, internal-monitor-*.
      for f in "$dir/state/candela-layout.lua" "$dir/state/candela-pending.lua" "$dir/state/internal-monitor-disable.lua"; do
        [[ -f $f ]] || continue
        apply_rules < "$f"
        apply_workspace_rules < "$f"
        sed -nE 's/^omarchy_candela_layout_probe = "([^"]+)"$/\1/p' "$f" >> "$dir/probe.txt"
      done
    fi
    echo ok
    ;;
  "configerrors "*|"configerrors") echo ok ;;
  "version "*|"version") echo "Hyprland 0.56.2 (fake)" ;;
  "output create")
    name="$4"
    if jq -e --arg n "$name" 'any(.name == $n)' "$dir/monitors.json" >/dev/null; then echo "Name already taken"; exit 0; fi
    entry="$(jq -nc --arg n "$name" '{name:$n, description:"", make:"", model:"", serial:"", disabled:false, focused:false, dpmsStatus:true,
      width:1920, height:1080, refreshRate:60, x:0, y:0, scale:1, transform:0, vrr:false, mirrorOf:"none", physicalWidth:0, physicalHeight:0,
      currentFormat:"XRGB8888", colorManagementPreset:"srgb", availableModes:[], activeWorkspace:{id:0, name:""}}')"
    jq --argjson e "$entry" '. + [$e]' "$dir/monitors.json" > "$dir/monitors.json.tmp" && mv "$dir/monitors.json.tmp" "$dir/monitors.json"
    for f in "$dir/state/candela-layout.lua" "$dir/state/candela-pending.lua"; do [[ -f $f ]] && apply_rules < "$f"; done
    jq --arg n "$name" '[.[] | select(.name == $n)]' "$dir/monitors.json" > "$dir/v.tmp"
    jq -s --arg n "$name" '(.[0] | map(select(.name != $n))) + .[1]' "$dir/virtual.json" "$dir/v.tmp" > "$dir/virtual.json.tmp" && mv "$dir/virtual.json.tmp" "$dir/virtual.json"
    rm -f "$dir/v.tmp"
    ws="$(jq -r --arg n "$name" '[.[] | select(.monitor == $n and .default == true)][0].workspaceString // ""' "$dir/wsrules.json")"
    if [[ $ws == name:* ]]; then
      jq --arg w "${ws#name:}" --arg n "$name" '. + [{id: (-1338 - length), name: $w, monitor: $n, windows: 0}]' "$dir/workspaces.json" > "$dir/w.tmp" && mv "$dir/w.tmp" "$dir/workspaces.json"
    fi
    echo ok
    ;;
  "output remove")
    name="$3"
    if ! jq -e --arg n "$name" 'any(.name == $n)' "$dir/virtual.json" >/dev/null; then echo "cannot remove a real display. Use the monitor keyword."; exit 0; fi
    jq --arg n "$name" 'map(select(.name != $n))' "$dir/monitors.json" > "$dir/m.tmp" && mv "$dir/m.tmp" "$dir/monitors.json"
    jq --arg n "$name" 'map(select(.name != $n))' "$dir/virtual.json" > "$dir/m.tmp" && mv "$dir/m.tmp" "$dir/virtual.json"
    first="$(jq -r '.[0].name' "$dir/monitors.json")"
    jq --arg n "$name" --arg f "$first" 'map(select(.monitor != $n or .windows > 0 or .id > 0) | if .monitor == $n then .monitor = $f else . end)' "$dir/workspaces.json" > "$dir/w.tmp" && mv "$dir/w.tmp" "$dir/workspaces.json"
    echo ok
    ;;
  "workspaces -j"|"workspaces ") cat "$dir/workspaces.json" ;;
  "workspacerules -j"|"workspacerules ") cat "$dir/wsrules.json" ;;
  "activeworkspace -j"|"activeworkspace ") jq '[.[] | select(.focused == true)][0].activeWorkspace // {id: 1}' "$dir/monitors.json" ;;
  "dispatch "*)
    if [[ $2 =~ hl\.dsp\.workspace\.move\(\{\ workspace\ =\ \"([^\"]+)\",\ monitor\ =\ \"([^\"]+)\"\ \}\) ]]; then
      ws="${BASH_REMATCH[1]}" mon="${BASH_REMATCH[2]}"
      if ! jq -e --arg w "$ws" 'any(.name == $w)' "$dir/workspaces.json" >/dev/null; then echo "Workspace not found"; exit 1; fi
      if [[ ${FAKE_HYPRCTL_MOVE_IGNORED:-} != 1 ]]; then
        jq --arg w "$ws" --arg m "$mon" 'map(if .name == $w then .monitor = $m else . end)' "$dir/workspaces.json" > "$dir/workspaces.json.tmp" && mv "$dir/workspaces.json.tmp" "$dir/workspaces.json"
      fi
    fi
    echo ok
    ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
