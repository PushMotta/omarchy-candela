### Repository URL

https://github.com/PushMotta/omarchy-candela

### Category

Hardware

### Tags

hyprland, quickshell, system

### Suggest a missing tag

_No response_

### Maintainer notes

Candela arranges displays and drives them at their real capabilities: HDR and wide gamut gated by each panel's EDID, SDR white in cd/m², and a live apply that reverts itself unless kept. Three kinds in one plugin: bar-widget (popup), overlay (studio), service.

Capabilities the baseline will report, for context:
- service-management: the revert countdown is a transient `systemd --user` timer started with `systemd-run` and cancelled with `systemctl --user stop`. No unit files are installed and nothing runs as root. The timer only ever runs the plugin's own `revert --expired --token <t>`, which is a no-op unless the token still matches the pending change.
- privilege: the only `sudo` in anything executable is `.github/workflows/test.yml` installing apt packages on the CI runner. `omarchy-hdr-contribution-brief.md`, the research note this plugin came out of, also quotes two `sudo` commands in prose. The plugin itself never uses sudo or pkexec.

Nothing is downloaded at install or runtime. The plugin writes only to its own state directory (`~/.local/state/omarchy/candela/`) and one generated rule file in Omarchy's toggles directory; it never edits the user's `monitors.lua`. It reads two things outside that: each connector's EDID from sysfs, to know what the panel can do, and `~/.local/state/omarchy/current/background` — the symlink Omarchy already maintains — so the arrangement canvas can show the current wallpaper inside each display. Removal steps, and the three commands that return a machine to stock, are in the README. Dependencies are all part of a stock Omarchy install: hyprctl, jq, edid-decode, ddcutil/brightnessctl via omarchy-brightness-display, socat, systemd-run.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
