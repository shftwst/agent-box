#!/bin/bash
# Claude payload-init — run by the cage entrypoint (as root, before the engine)
# for Claude-specific in-box prep the generic cage doesn't do. HOME and
# CAGE_STATE_MOUNT (== ${HOME}/.claude) are already set.
set -e

# Clean up stale directories that Docker auto-creates when a bind-mount source
# doesn't exist. On Colima this is common because virtiofs cache delays can make
# freshly-written host files invisible to the VM at mount time. These root-owned
# directories persist in the state volume and shadow the real files on subsequent
# runs, so remove them at startup. Only paths inside the state volume
# (${HOME}/.claude); ${HOME}/.claude.json is a separate bind mount.
for _stale in "${HOME}/.claude/CLAUDE.md" "${HOME}/.claude/.credentials.json" \
              "${HOME}/.claude/.claude.json" "${HOME}/.claude/settings.json"; do
  [ -d "$_stale" ] && rm -rf "$_stale"
done

# Workers get a private ~/.claude.json copied from the shared state, so they never
# read another box's half-written copy (which Claude discards, losing folder trust)
# or write their own back.
_seed=/usr/local/share/cage/claude.json.seed
if [ -n "${BOX_WORKER:-}" ] && [ -f "$_seed" ]; then
  python3 - "$_seed" "${HOME}/.claude/backups" "${HOME}/.claude.json" <<'PY' || true
import glob, json, os, sys, time

seed, backups, target = sys.argv[1:]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


config = None
for _ in range(10):
    config = load(seed)
    if config is not None:
        break
    time.sleep(0.2)
if config is None:
    for path in sorted(glob.glob(os.path.join(backups, ".claude.json.backup.*")), reverse=True):
        config = load(path)
        if config is not None:
            break
with open(target, "w") as f:
    json.dump(config or {}, f, indent=2)
PY
  chown "${HOST_UID}:${HOST_GID}" "${HOME}/.claude.json" 2>/dev/null || true
fi

# Install the baked-in claude-box theme so the container is visually distinct.
mkdir -p "${HOME}/.claude/themes"
cp -f /usr/local/share/claude-box-theme.json "${HOME}/.claude/themes/claude-box.json" 2>/dev/null || true
