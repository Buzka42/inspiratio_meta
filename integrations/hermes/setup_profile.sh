#!/usr/bin/env bash
# Set up the Hermes "illunis" profile for the Illunis assistant bridge. Idempotent.
#
#   integrations/hermes/setup_profile.sh --worker-url https://<worker>.workers.dev [--dry-run]
#
# Options:
#   --worker-url URL   Illunis Worker base URL (https). Or set ILLUNIS_WORKER_URL.
#   --dry-run          Print the planned actions; change nothing.
#   --rotate           Generate new API_SERVER_KEY and ILLUNIS_INBOX_SECRET even if present.
#   --skip-wrangler    Do not push secrets to the Worker (see RUNBOOK.md to push later).
#   --skip-backup      Skip `hermes backup` (only if you made one minutes ago).
#
# What it touches: a backup zip in ~/hermes-backups/, and ~/.hermes/profiles/illunis/
# (config.yaml via `hermes -p illunis config set`, .env, SOUL.md, profile.yaml, plugins/).
# It never edits the default profile, never starts or stops a gateway, and never prints
# a secret value.
set -euo pipefail
umask 077

DRY=0 ROTATE=0 SKIP_WRANGLER=0 SKIP_BACKUP=0
WORKER_URL="${ILLUNIS_WORKER_URL:-}"
PROFILE=illunis
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --rotate) ROTATE=1 ;;
    --skip-wrangler) SKIP_WRANGLER=1 ;;
    --skip-backup) SKIP_BACKUP=1 ;;
    --worker-url) WORKER_URL="${2:-}"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
PDIR="$HERMES_ROOT/profiles/$PROFILE"
ENV_FILE="$PDIR/.env"
HERMES_PY="${HERMES_PY:-$HERMES_ROOT/hermes-agent/venv/bin/python}"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '==> %s\n' "$*"; }
plan() { printf '[dry-run] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() { if (( DRY )); then plan "$*"; else "$@"; fi; }
hp() { run hermes -p "$PROFILE" "$@"; }

# -- preflight -------------------------------------------------------------
command -v hermes >/dev/null || die "hermes not on PATH"
command -v openssl >/dev/null || die "openssl not found"
(( SKIP_WRANGLER )) || command -v npx >/dev/null || die "npx not found (or pass --skip-wrangler)"
[[ -f "$HERE/plugins/illunis_memory/__init__.py" && -f "$HERE/profile/SOUL.md" ]] || die "run from the repo checkout"
[[ -f "$REPO/server/wrangler.jsonc" ]] || (( SKIP_WRANGLER )) || die "server/wrangler.jsonc not found"
(( SKIP_WRANGLER )) || [[ -x "$REPO/server/node_modules/.bin/wrangler" ]] || (( DRY )) || \
  die "wrangler not installed in server/ (run: cd server && npm ci), or pass --skip-wrangler"
if [[ -z "$WORKER_URL" ]]; then
  (( DRY )) && WORKER_URL="https://WORKER.example.workers.dev" || die "--worker-url is required"
fi
[[ "$WORKER_URL" =~ ^https://[A-Za-z0-9.-]+(/.*)?$ ]] || die "--worker-url must be https://..."
WORKER_URL="${WORKER_URL%/}"

# -- 1. backup ---------------------------------------------------------------
if (( SKIP_BACKUP )); then
  say "backup skipped (--skip-backup)"
else
  BK="$HOME/hermes-backups/pre-illunis-$STAMP.zip"
  say "backup -> $BK"
  run mkdir -p "$HOME/hermes-backups"
  # -k 0: never prune the owner's older backups.
  run hermes backup -o "$BK" -k 0
  run chmod 600 "$BK"
fi

# -- 2. profile --------------------------------------------------------------
if [[ -f "$PDIR/config.yaml" || -f "$PDIR/profile.yaml" ]]; then
  say "profile '$PROFILE' exists at $PDIR"
else
  say "create profile '$PROFILE' (fresh, no bundled skills, no wrapper alias)"
  run hermes profile create "$PROFILE" --no-skills --no-alias \
    --description "Illunis memory keeper and liaison: long-term memory for the Illunis app and messages to the owner's other bots."
  # Keep the new profile offline until the owner unparks it (the multiplexing host
  # rescans every 30 s; gateway.parked is the documented provisioning marker,
  # website/docs/user-guide/multi-profile-gateways.md "Stopping one profile").
  run touch "$PDIR/gateway.parked"
fi
(( DRY )) || [[ -d "$PDIR" ]] || die "profile dir $PDIR missing after create"

# -- 3. config (all through `hermes -p illunis config set`) ----------------
# platform_toolsets.<platform> is the key read by hermes_cli/tools_config.py:573-574
# (_get_platform_tools); the API server resolves it as "api_server" at
# gateway/platforms/api_server.py:2229. memory must stay on: provider tools are withheld
# without it (agent/memory_manager_tools.py:62-83). message_agent is injected only in a
# Bot Chat session, never through a toolset (tools/bot_mode_dm.py:1-14).
say "restrict toolsets and approvals"
ALLOWED='["memory","web"]'
for platform in api_server cli cron; do
  hp config set "platform_toolsets.$platform" "$ALLOWED"
done
# Subtracted last, for every platform (hermes_cli/tools_config.py:638-642), so a future
# "recently shipped" toolset or a desktop toggle cannot re-add them.
hp config set agent.disabled_toolsets \
  '["terminal","file","code_execution","computer_use","kanban","browser","delegation","cronjob","skills","image_gen","video_gen","tts","connections"]'
hp config set approvals.mode manual
hp config set approvals.unattended_mode deny   # default deny: hermes_cli/config_defaults.py:1682
hp config set approvals.cron_mode deny
hp config set memory.provider illunis_memory

# -- 4. SOUL.md ------------------------------------------------------------
if [[ -f "$PDIR/SOUL.md" ]] && cmp -s "$HERE/profile/SOUL.md" "$PDIR/SOUL.md"; then
  say "SOUL.md up to date"
else
  say "install SOUL.md"
  [[ -f "$PDIR/SOUL.md" ]] && run cp -p "$PDIR/SOUL.md" "$PDIR/SOUL.md.bak-$STAMP"
  run install -m 600 "$HERE/profile/SOUL.md" "$PDIR/SOUL.md"
fi

# -- 5. Bot Mode marker in profile.yaml (merge, keep other keys) ------------
say "Bot Mode ui_meta in profile.yaml"
if (( DRY )); then
  plan "merge ui_meta['hermes-bots'] = {title: Illunis, description: ...} into $PDIR/profile.yaml"
else
  [[ -x "$HERMES_PY" ]] || die "Hermes venv python not found at $HERMES_PY"
  "$HERMES_PY" -I - "$PDIR/profile.yaml" <<'PY'
import os, sys, tempfile, yaml
path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
if not isinstance(data, dict):
    sys.exit("profile.yaml is not a mapping; fix it by hand")
ui = data.setdefault("ui_meta", {})
if not isinstance(ui, dict):
    sys.exit("profile.yaml ui_meta is not a mapping; fix it by hand")
bots = ui.setdefault("hermes-bots", {})
if not isinstance(bots, dict):
    sys.exit("profile.yaml ui_meta.hermes-bots is not a mapping; fix it by hand")
bots.setdefault("title", "Illunis")
bots.setdefault("description", "Memory keeper and liaison for the Illunis app")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".profile.yaml.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False, allow_unicode=True)
os.replace(tmp, path)
PY
fi

# -- 6. plugin -------------------------------------------------------------
say "install plugin -> $PDIR/plugins/illunis_memory"
SRC="$HERE/plugins/illunis_memory"
DST="$PDIR/plugins/illunis_memory"
if (( DRY )); then
  plan "copy $SRC (*.py, plugin.yaml) to $DST, replacing the old copy"
else
  mkdir -p "$PDIR/plugins"
  STAGE="$(mktemp -d "$PDIR/plugins/.illunis_memory.XXXXXX")"
  install -m 600 "$SRC"/*.py "$SRC/plugin.yaml" "$STAGE/"
  chmod 700 "$STAGE"
  [[ -d "$DST" ]] && rm -rf "$DST.old" && mv "$DST" "$DST.old"
  mv "$STAGE" "$DST"
  rm -rf "$DST.old"
fi

# -- 7. secrets in the profile .env -----------------------------------------
# Values live only in shell variables and the 600 .env; printf is a builtin, so they
# never appear in argv or a process listing.
env_has() { [[ -f "$ENV_FILE" ]] && grep -q "^$1=." "$ENV_FILE"; }
env_set() { # env_set NAME  (value on stdin)
  local name="$1" value tmp
  IFS= read -r value
  tmp="$(mktemp "$PDIR/.env.XXXXXX")"
  [[ -f "$ENV_FILE" ]] && grep -v "^$name=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$name" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}
push_secret() { # push_secret WORKER_NAME  (value on stdin)
  if (( SKIP_WRANGLER )); then cat >/dev/null; say "  skipped wrangler for $1"; return; fi
  ( cd "$REPO/server" && npx --no-install wrangler secret put "$1" >/dev/null )
  say "  pushed $1 to the Worker"
}

say "secrets"
if (( DRY )); then
  [[ -f "$ENV_FILE" ]] && plan "chmod 600 $ENV_FILE"
  for n in API_SERVER_KEY ILLUNIS_INBOX_SECRET; do
    if env_has "$n" && (( ! ROTATE )); then plan "keep existing $n (not pushed again; --rotate to replace)"
    else plan "generate $n with openssl rand -hex 32, write to $ENV_FILE (value not shown)"
         (( SKIP_WRANGLER )) || plan "pipe $n to: (cd server && npx wrangler secret put $([[ $n == API_SERVER_KEY ]] && echo HERMES_API_KEY || echo ILLUNIS_INBOX_SECRET))"
    fi
  done
  plan "set ILLUNIS_WORKER_URL=$WORKER_URL in $ENV_FILE"
else
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  for pair in API_SERVER_KEY:HERMES_API_KEY ILLUNIS_INBOX_SECRET:ILLUNIS_INBOX_SECRET; do
    local_name="${pair%%:*}" worker_name="${pair##*:}"
    if env_has "$local_name" && (( ! ROTATE )); then
      say "  keep existing $local_name (--rotate to replace)"
      continue
    fi
    secret="$(openssl rand -hex 32)"
    # Push first: if wrangler fails, nothing is written locally and a rerun starts clean.
    printf '%s' "$secret" | push_secret "$worker_name"
    printf '%s\n' "$secret" | env_set "$local_name"
    say "  wrote $local_name to $ENV_FILE"
    unset secret
  done
  printf '%s\n' "$WORKER_URL" | env_set ILLUNIS_WORKER_URL
fi

# -- 8. show the result (no secrets) ---------------------------------------
if (( ! DRY )); then
  say "check"
  for k in platform_toolsets.api_server agent.disabled_toolsets approvals.unattended_mode memory.provider; do
    printf '  %s = ' "$k"; hermes -p "$PROFILE" config get "$k" 2>/dev/null || echo "?"
  done
  printf '  .env mode = %s\n' "$(stat -c %a "$ENV_FILE")"
  printf '  .env keys = %s\n' "$(grep -o '^[A-Z_][A-Z0-9_]*' "$ENV_FILE" | sort | tr '\n' ' ')"
fi

cat <<EOF

Next (owner, see integrations/hermes/RUNBOOK.md):
  1. Make sure the default profile's gateway has the API server on (port 8642); the
     illunis profile is served at /p/$PROFILE/ on that listener.
  2. hermes -p $PROFILE model            # pick a non-training provider for this bot
  3. hermes -p $PROFILE chat -c "Bot Chat" --create-if-missing   # once, creates the Bot Chat
  4. hermes -p $PROFILE gateway start    # unparks; the host gateway serves /p/$PROFILE/
  5. Tunnel + Access steps, then the CF_ACCESS_* Worker secrets.
EOF
