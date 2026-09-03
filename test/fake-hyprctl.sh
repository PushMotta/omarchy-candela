#!/bin/bash

# The compositor the CLI tests talk to. It keeps a monitors JSON the way
# Hyprland keeps its outputs: `eval` applies hl.monitor rules to the live
# state; `reload` rebuilds it from the pristine fixture plus whatever the
# toggles files say, in sorted filename order like Omarchy's loader; a global
# set by the layout file answers the load probe. Knobs, all env vars:
#   FAKE_HYPRCTL_EVAL_FAIL=1          eval is rejected outright
#   FAKE_HYPRCTL_IGNORE_SCALE=1       eval lands everything but the scale
#   FAKE_HYPRCTL_TOGGLES_NOT_LOADED=1 reload reads no toggles files at all

dir="$FAKE_DIR"
echo "$*" >> "$dir/hyprctl.log"

# lua text on stdin → one JSON object per hl.monitor rule
rules_from() {
  grep -oE 'hl\.monitor\(\{.*\}\)' \
    | sed -E 's/^hl\.monitor\(\{ ?//; s/ ?\}\)$//; s/\[==\[([^]]*)\]==\]/"\1"/g; s/(^|, )([a-z_]+) = /\1"\2": /g; s/^/{/; s/$/}/'
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
          | .mirrorOf = (if ($r.mirror // "") == "" then "none" else $r.mirror end)
          | .currentFormat = (if $r.bitdepth == 10 then "XBGR2101010" else "XRGB8888" end)
          | .colorManagementPreset = ($r.cm // "srgb")
          | .sdrMaxLuminance = ($r.sdr_max_luminance // 80)
          | .sdrMinLuminance = ($r.sdr_min_luminance // 0.005)
          | .sdrBrightness = ($r.sdrbrightness // 1)
          | .sdrSaturation = ($r.sdrsaturation // 1)
          | .vrr = (($r.vrr // 0) != 0)
        end end)' "$dir/monitors.json" > "$dir/monitors.json.tmp" && mv "$dir/monitors.json.tmp" "$dir/monitors.json"
  done < <(rules_from)
}

case "$1 $2" in
  "monitors all") cat "$dir/monitors.json" ;;
  "getoption render:cm_auto_hdr") echo '{"option":"render:cm_auto_hdr","int":1}' ;;
  "getoption render:cm_sdr_eotf") echo '{"option":"render:cm_sdr_eotf","str":"default"}' ;;
  "eval "*)
    printf '%s\n' "$2" > "$dir/eval-last.txt"
    if [[ ${FAKE_HYPRCTL_EVAL_FAIL:-} == 1 ]]; then
      echo "fake hyprctl: eval rejected" >&2
      exit 1
    fi
    if [[ $2 == *"assert(omarchy_displays_layout_probe == "* ]]; then
      want="$(sed -nE 's/.*omarchy_displays_layout_probe == "([^"]+)".*/\1/p' <<<"$2")"
      have="$(cat "$dir/probe.txt" 2>/dev/null || true)"
      if [[ -n $want && $want == "$have" ]]; then echo ok; exit 0; fi
      echo "error: [string ...]: displays-layout.lua did not run"
      exit 7
    fi
    apply_rules <<<"$2"
    echo ok
    ;;
  "reload "*|"reload")
    cp "$dir/monitors.pristine.json" "$dir/monitors.json"
    : > "$dir/probe.txt"
    if [[ ${FAKE_HYPRCTL_TOGGLES_NOT_LOADED:-} != 1 ]]; then
      # Sorted like require_all: displays-layout, displays-pending, internal-monitor-*.
      for f in "$dir/state/displays-layout.lua" "$dir/state/displays-pending.lua" "$dir/state/internal-monitor-disable.lua"; do
        [[ -f $f ]] || continue
        apply_rules < "$f"
        sed -nE 's/^omarchy_displays_layout_probe = "([^"]+)"$/\1/p' "$f" >> "$dir/probe.txt"
      done
    fi
    echo ok
    ;;
  "configerrors "*|"configerrors") echo ok ;;
  "version "*|"version") echo "Hyprland 0.56.2 (fake)" ;;
  "dispatch "*) echo ok ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
