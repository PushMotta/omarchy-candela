#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

out="$("$ROOT/bin/omarchy-candela-edid" "$FIXTURES/mateview-dp1.edid")"
jq -e . <<<"$out" >/dev/null || fail "edid output is valid JSON" "$out"
pass "edid output is valid JSON"

assert_eq "$(jq -r .manufacturer <<<"$out")" "HWV" "manufacturer parsed"
assert_eq "$(jq -r .productName <<<"$out")" "MateView" "product name parsed"
assert_eq "$(jq -r .productSerial <<<"$out")" "" "blank product serial stays blank"
assert_eq "$(jq -r .bitsPerPrimary <<<"$out")" "10" "bits per primary parsed"
assert_eq "$(jq -r .hdr.st2084 <<<"$out")" "true" "ST 2084 detected"
assert_eq "$(jq -r .hdr.maxLuminance <<<"$out")" "496.743" "max luminance parsed"
assert_eq "$(jq -r .hdr.maxFrameAverageLuminance <<<"$out")" "496.743" "max average luminance parsed"
assert_eq "$(jq -r .hdr.minLuminance <<<"$out")" "0.000" "min luminance parsed"
assert_eq "$(jq -r '.colorimetry | join(",")' <<<"$out")" "BT2020cYCC,BT2020YCC,BT2020RGB" "colorimetry block parsed"
assert_eq "$(jq -r .supportsHdr <<<"$out")" "true" "supportsHdr derived"
assert_eq "$(jq -r .supportsWideColor <<<"$out")" "true" "supportsWideColor derived"
assert_eq "$(jq -r '.primaries.red | join(",")' <<<"$out")" "0.6796,0.3203" "red primary parsed"
assert_eq "$(jq -r '.primaries.white | join(",")' <<<"$out")" "0.3134,0.3291" "white point parsed"
assert_eq "$(jq -r .physicalWidthMm <<<"$out")" "596" "physical width from DTD"
assert_eq "$(jq -r .physicalHeightMm <<<"$out")" "397" "physical height from DTD"
assert_eq "$(jq -r .diagonalInch <<<"$out")" "28.2" "diagonal computed"
assert_eq "$(jq -r .ppi <<<"$out")" "164" "ppi computed"
assert_eq "$(jq -r '.preferredMode.width' <<<"$out")" "3840" "preferred mode parsed"
assert_contains "$(jq -r .hash <<<"$out")" "sha256:" "hash present"
pass "all EDID fields parsed"

sandbox="$(make_sandbox)"
trap 'rm -rf "$sandbox"' EXIT
byname="$(OMARCHY_DRM_PATH="$sandbox/drm" "$ROOT/bin/omarchy-candela-edid" DP-2)"
assert_eq "$(jq -r .connector <<<"$byname")" "DP-2" "lookup by connector name"
missing="$(OMARCHY_DRM_PATH="$sandbox/drm" "$ROOT/bin/omarchy-candela-edid" HDMI-A-9)"
assert_eq "$(jq -r .available <<<"$missing")" "false" "missing connector reports unavailable"
pass "connector lookup"

if OMARCHY_DRM_PATH="$sandbox/drm" "$ROOT/bin/omarchy-candela-edid" 'DP-2;rm' 2>/dev/null; then
  fail "unsafe connector name rejected"
fi
pass "unsafe connector name rejected"
