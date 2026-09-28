### Repository URL

https://github.com/PushMotta/omarchy-candela

### Category

Hardware

### Tags

Hyprland, Quickshell, System

### Suggest a missing tag

_No response_

### Maintainer notes

Candela arranges displays and drives them at their real capabilities: HDR and wide gamut gated by each panel's EDID, SDR white in cd/m², and a live apply that reverts itself unless kept. Three kinds in one plugin: bar-widget (popup), overlay (studio), service.

This is a new submission of #4744, which was closed on 22 September after the maintainer review. That review asked for `HANDOFF.md`, an agent/session handoff file, to be removed from the installable tree together with any equivalent material. It has been removed, and so has the research brief the plugin grew out of, because it also addressed a coding agent. Both now live outside the repository. What remains is ordinary user and developer documentation (`README.md`, `DESIGN.md`, this submission text), and the tree was checked for agent-directed wording before submitting.

Since the first submission the apply path has also become transactional: apply records a recovery journal with byte-exact snapshots of every file it touches, keep and revert only report success after the compositor's readback matches, a failed keep puts the previous configuration back, external calls are time-bounded, and the confirmation bar shows failures instead of a countdown. It was exercised on a two-display desk as well as in the sandboxed test suite.

Capabilities the baseline will report, for context:
- service-management: the revert countdown is a transient `systemd --user` timer started with `systemd-run` and cancelled with `systemctl --user stop`. No unit files are installed and nothing runs as root. The timer only ever runs the plugin's own `revert --expired --token <t>`, which is a no-op unless the token still matches the pending change.

The only `sudo` in the repository is `.github/workflows/test.yml` installing apt packages on the CI runner. The plugin itself never uses sudo or pkexec. The workflow's actions are pinned to full commit SHAs and it declares `permissions: contents: read`.

Nothing is downloaded at install or runtime. The plugin writes only to its own state directory (`~/.local/state/omarchy/candela/`) and to generated rule files in Omarchy's toggles directory; it never edits the user's `monitors.lua`. It reads two things outside that: each connector's EDID from sysfs, to know what the panel can do, and `~/.local/state/omarchy/current/background` — the symlink Omarchy already maintains — so the arrangement canvas can show the current wallpaper inside each display. Removal steps, and the commands that return a machine to stock, are in the README. Dependencies are all part of a stock Omarchy install: hyprctl, jq, edid-decode, ddcutil/brightnessctl via omarchy-brightness-display, socat, systemd-run.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
