#!/bin/bash
# Remove Sunshift and put back what install.sh changed.
#
# Your Sunshift settings (~/.config/sunshift) and its state (~/.local/state/sunshift)
# are kept, so a later install picks up where you left off. Pass --purge to
# remove them too.

set -euo pipefail

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
STATE_ROOT=${XDG_STATE_HOME:-$HOME/.local/state}/sunshift
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/sunshift
BIN=$HOME/.local/bin
UNITS=$CONFIG_HOME/systemd/user
PLUGIN=$CONFIG_HOME/omarchy/plugins/sunshift.panel
HYPR=$CONFIG_HOME/hypr
MENU=$CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc
SHELL_JSON=$CONFIG_HOME/omarchy/shell.json
BACKUP=$STATE_ROOT/install-backup
REQUIRE_LINE='require("hypr.sunshift") -- added by Sunshift'

say() { printf '\033[1m%s\033[0m\n' "$*"; }
purge=false
[[ ${1:-} == --purge ]] && purge=true
[[ -e $BACKUP/done ]] || echo "No install backup found in $BACKUP; removing Sunshift's own files only."

# restore <file> <name>: put the saved copy back, or remove the file if there was none
restore() {
  if [[ -e $BACKUP/$2 ]]; then
    mkdir -p "$(dirname "$1")"
    cp -p -- "$BACKUP/$2" "$1"
  elif [[ -e $BACKUP/$2.absent ]]; then
    rm -f -- "$1"
  fi
}

say "Stopping the Sunshift service"
systemctl --user disable --now sunshift.service 2>/dev/null || true
rm -f -- "$UNITS/sunshift.service" "$UNITS/hyprsunset.service.d/sunshift.conf"
rmdir -- "$UNITS/hyprsunset.service.d" 2>/dev/null || true
restore "$HYPR/hyprsunset.conf" hyprsunset.conf
systemctl --user daemon-reload
if [[ -e $BACKUP/hyprsunset-was-active || ! -e $BACKUP/done ]]; then
  systemctl --user restart hyprsunset.service || true
else
  systemctl --user stop hyprsunset.service || true
fi

say "Removing Sunshift from the bar"
omarchy plugin disable sunshift.panel >/dev/null 2>&1 || true
rm -rf -- "$PLUGIN"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

# Bring Quattro's night-light indicator back to where it was.
if [[ -e $BACKUP/indicator-items.json && -e $SHELL_JSON ]]; then
  saved=$(cat "$BACKUP/indicator-items.json")
  [[ $saved == null || -z $saved ]] && saved='["Dictation","ScreenRecording","Reminder","NightLight","Dnd","StayAwake"]'
  current=$(jq -c '[.. | objects | select(.id? == "omarchy.indicators")][0] | if . == null then null else (.items // null) end' "$SHELL_JSON")
  if [[ $current != null ]] && jq -e --argjson saved "$saved" '($saved | index("NightLight")) != null and index("NightLight") == null' <<<"$current" >/dev/null; then
    items=$(jq -c --argjson saved "$saved" '($saved | index("NightLight")) as $at | .[:$at] + ["NightLight"] + .[$at:]' <<<"$current")
    omarchy bar set omarchy.indicators items "$items" --json >/dev/null || echo "Could not restore the night-light indicator; add it back under omarchy.indicators in $SHELL_JSON."
  fi
fi

say "Giving Super+Ctrl+N and the menu back to Omarchy"
rm -f -- "$HYPR/sunshift.lua"
if [[ -e $HYPR/hyprland.lua ]] && grep -qxF "$REQUIRE_LINE" "$HYPR/hyprland.lua"; then
  python3 - "$HYPR/hyprland.lua" "$REQUIRE_LINE" <<'EOF'
import sys
path, line = sys.argv[1:]
text = open(path).read()
# install.sh appended a newline and the require line; take both away again.
tail = '\n' + line + '\n'
text = text[:-len(tail)] if text.endswith(tail) else text.replace(line + '\n', '', 1)
open(path, 'w').write(text)
EOF
fi

if [[ -e $MENU ]] && grep -q '// sunshift:begin' "$MENU"; then
  python3 - "$MENU" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r'\n[ \t]*// sunshift:begin.*?// sunshift:end[^\n]*', '', text, count=1, flags=re.S)
open(path, 'w').write(text)
EOF
  [[ -e $BACKUP/omarchy-menu.jsonc.absent ]] && [[ $(tr -d '[:space:]' < "$MENU") == '{}' ]] && rm -f -- "$MENU"
fi
hyprctl reload >/dev/null 2>&1 || true

say "Removing the program"
rm -rf -- "$DATA"
rm -f -- "$BIN/sunshift"
if $purge; then
  rm -rf -- "$CONFIG_HOME/sunshift" "$STATE_ROOT"
  say "Sunshift and its settings are removed."
else
  rm -rf -- "$BACKUP"
  rmdir -- "$STATE_ROOT" 2>/dev/null || true
  say "Sunshift is removed. Your settings stay in $CONFIG_HOME/sunshift (remove with --purge)."
fi
