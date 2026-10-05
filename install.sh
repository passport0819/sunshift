#!/bin/bash
# Install Sunshift for the current user on Omarchy (Quattro shell).
#
# Run it again to update: program files are replaced, settings are kept, and
# changes to your own files are only made once. Undo everything with
# ./uninstall.sh, which restores the files saved under
# ~/.local/state/sunshift/install-backup.

set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/sunshift
BIN=$HOME/.local/bin
UNITS=$CONFIG_HOME/systemd/user
PLUGIN=$CONFIG_HOME/omarchy/plugins/sunshift.panel
HYPR=$CONFIG_HOME/hypr
MENU=$CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc
SHELL_JSON=$CONFIG_HOME/omarchy/shell.json
BACKUP=${XDG_STATE_HOME:-$HOME/.local/state}/sunshift/install-backup
REQUIRE_LINE='require("hypr.sunshift") -- added by Sunshift'
MENU_BEGIN='  // sunshift:begin (removed by Sunshift uninstall.sh)'
MENU_END='  // sunshift:end'

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { echo "sunshift install: $*" >&2; exit 1; }

for tool in python3 jq omarchy omarchy-shell hyprsunset systemctl hyprctl; do
  command -v "$tool" >/dev/null || fail "$tool is missing. Sunshift needs Omarchy with its Quattro shell."
done
[[ -n ${WAYLAND_DISPLAY:-} ]] || fail "run this inside your Omarchy desktop session, not over SSH or a TTY."

# ---------------------------------------------------------------- backups
# Saved once, before Sunshift touches anything, so uninstall.sh can put it back.
if [[ ! -e $BACKUP/done ]]; then
  say "Saving the files Sunshift changes"
  mkdir -p "$BACKUP"
  save() {  # save <file> <name>: copy it, or note that it did not exist
    if [[ -e $1 ]]; then cp -p -- "$1" "$BACKUP/$2"; else : > "$BACKUP/$2.absent"; fi
  }
  save "$HYPR/hyprsunset.conf" hyprsunset.conf
  save "$MENU" omarchy-menu.jsonc
  save "$HYPR/hyprland.lua" hyprland.lua
  systemctl --user is-active --quiet hyprsunset.service && : > "$BACKUP/hyprsunset-was-active"
  # Where Quattro's own night-light indicator sat, so it can come back to the same place.
  if [[ -e $SHELL_JSON ]]; then
    jq -c '[.. | objects | select(.id? == "omarchy.indicators")][0].items // null' "$SHELL_JSON" > "$BACKUP/indicator-items.json" || true
  fi
  date -Is > "$BACKUP/done"
fi

# ---------------------------------------------------------------- program
say "Installing the program"
mkdir -p "$(dirname "$DATA")" "$BIN"
rm -rf -- "$DATA.new"
cp -r -- "$SRC/share" "$DATA.new"
find "$DATA.new" -name __pycache__ -prune -exec rm -rf {} +
rm -rf -- "$DATA"
mv -- "$DATA.new" "$DATA"
install -m 0755 "$SRC/bin/sunshift" "$BIN/sunshift"

# ---------------------------------------------------------------- services
say "Starting the Sunshift service"
mkdir -p "$UNITS/hyprsunset.service.d"
install -m 0644 "$SRC/systemd/sunshift.service" "$UNITS/sunshift.service"
install -m 0644 "$SRC/systemd/hyprsunset.service.d/sunshift.conf" "$UNITS/hyprsunset.service.d/sunshift.conf"
# hyprsunset's own schedule would fight Sunshift; the original stays in the backup.
mkdir -p "$HYPR"
printf '%s\n' '# Temperature is managed by Sunshift.' \
  '# Your previous settings are saved in ~/.local/state/sunshift/install-backup.' > "$HYPR/hyprsunset.conf"
systemctl --user daemon-reload
systemctl --user restart hyprsunset.service
systemctl --user enable sunshift.service
systemctl --user restart sunshift.service
if grep -v '^[[:space:]]*--' "$HYPR/autostart.lua" 2>/dev/null | grep -q 'hyprsunset'; then
  echo "Note: $HYPR/autostart.lua also starts hyprsunset. Remove that line, Sunshift starts it itself."
fi

# ---------------------------------------------------------------- bar
say "Adding Sunshift to the bar"
mkdir -p "$(dirname "$PLUGIN")"
updating=false
[[ -e $PLUGIN ]] && updating=true
rm -rf -- "$PLUGIN"
cp -r -- "$SRC/panel/sunshift.panel" "$PLUGIN"
omarchy-shell shell rescanPlugins >/dev/null
for attempt in $(seq 40); do
  omarchy plugin list --json | jq -e 'any(.[]; .id == "sunshift.panel")' >/dev/null && break
  sleep 0.05
done
omarchy plugin enable sunshift.panel --after omarchy.tray >/dev/null 2>&1 ||
  omarchy plugin enable sunshift.panel --section right >/dev/null

# Quattro's night-light indicator would show Sunshift's warm hours as "night light on".
items=$(jq -c '[.. | objects | select(.id? == "omarchy.indicators")][0] | if . == null then null else (.items // ["Dictation","ScreenRecording","Reminder","NightLight","Dnd","StayAwake"]) end' "$SHELL_JSON" 2>/dev/null || echo null)
if [[ $items != null ]] && jq -e 'index("NightLight") != null' <<<"$items" >/dev/null; then
  omarchy bar set omarchy.indicators items "$(jq -c 'map(select(. != "NightLight"))' <<<"$items")" --json >/dev/null
fi

# ---------------------------------------------------------------- shortcut and menu
say "Pointing Super+Ctrl+N and the menu's night light at Sunshift"
cat > "$HYPR/sunshift.lua" <<'EOF'
-- Sunshift takes over Omarchy's night-light shortcut: pause / resume.
-- Written by Sunshift's install.sh, removed by uninstall.sh.
o.rebind("SUPER + CTRL + N", "Sunshift: pause / resume", os.getenv("HOME") .. "/.local/bin/sunshift toggle")
EOF
if [[ -e $HYPR/hyprland.lua ]] && ! grep -qF 'require("hypr.sunshift")' "$HYPR/hyprland.lua"; then
  printf '\n%s\n' "$REQUIRE_LINE" >> "$HYPR/hyprland.lua"
fi

mkdir -p "$(dirname "$MENU")"
[[ -s $MENU ]] || printf '{\n}\n' > "$MENU"
if ! grep -qF "$MENU_BEGIN" "$MENU"; then
  if grep -q '"trigger.toggle.nightlight"' "$MENU"; then
    echo "Note: $MENU already changes the night-light entry, so Sunshift leaves the menu alone."
  else
    entry="  \"trigger.toggle.nightlight\": $(jq -cn --arg action "$BIN/sunshift toggle" '{icon: "\udb81\udda8", label: "Sunshift pause / resume", action: $action}'),"
    python3 - "$MENU" "$MENU_BEGIN" "$entry" "$MENU_END" <<'EOF'
import sys
path, *block = sys.argv[1:]
text = open(path).read()
brace = text.index('{') + 1
open(path, 'w').write(text[:brace] + '\n' + '\n'.join(block) + text[brace:])
EOF
  fi
fi

hyprctl reload >/dev/null || true
if errors=$(hyprctl configerrors 2>/dev/null) && [[ -n ${errors//[[:space:]]/} && $errors != *"no errors"* ]]; then
  echo "Hyprland reports config errors after the change:" >&2
  echo "$errors" >&2
fi

if $updating; then
  # The bar caches plugin code until it restarts (rescanPlugins is not enough).
  say "Restarting the bar to load the new panel"
  omarchy restart shell >/dev/null 2>&1 || echo "Restart the bar yourself: omarchy restart shell"
fi

say "Sunshift is installed."
echo "Click the sun or moon icon in the bar to choose your location and schedule."
echo "Undo everything with: $SRC/uninstall.sh"
