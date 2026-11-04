#!/usr/bin/env bash
# Meta demo deploy (owner decision 2026-11-03): the demo settings live here and are applied at deploy time as
# --var flags; nothing is committed to wrangler.jsonc. Secrets (META_API_KEY and the rest) are set beforehand with
# `wrangler secret put` and are never read or printed here.
#   tools/meta/deploy-demo.sh                 prints the command only
#   tools/meta/deploy-demo.sh deploy [args]   runs it; extra args go to wrangler (for example more --var flags)
# QUOTA_COUNCIL_PER_DAY sets the council quota (default 50; restore 5 before submission).
# COUNCIL_MEDICAL is left unset, so the medical experts stay off.
# Muse answers the council and the daily reply (REPLY_PROVIDER=meta). Embedding and knowledge stay on Nebius;
# REPLY_LLM_MODEL stays because /log/parse falls back to it (src/logs/parse.js).
set -euo pipefail
SERVER="$(cd "$(dirname "$0")/../../server" && pwd)"
QUOTA="${QUOTA_COUNCIL_PER_DAY:-50}"
# ASSISTANT_OWNER_DEVICE_ID is the one device allowed to change settings and pair the bot (the spec routes return
# 503 without it). Default: the demo phone device used by scratchpad mint (phone-owner-test).
OWNER="${ASSISTANT_OWNER_DEVICE_ID:-phone-owner-test}"
[[ "$OWNER" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { echo "ASSISTANT_OWNER_DEVICE_ID has invalid characters" >&2; exit 1; }
[[ "$QUOTA" =~ ^[0-9]+$ ]] || { echo "QUOTA_COUNCIL_PER_DAY must be a whole number" >&2; exit 1; }

MODE="${1:-}"
[ $# -gt 0 ] && shift
CMD=(npx wrangler deploy
  --var DATA_MODE:synthetic
  --var COUNCIL_COACHING:off
  --var META_MODEL:muse-spark-1.3
  --var "QUOTA_COUNCIL_PER_DAY:$QUOTA"
  --var "ASSISTANT_OWNER_DEVICE_ID:$OWNER"
  --var COUNCIL_NEBIUS_MODEL:nvidia/nemotron-3-super-120b-a12b
  --var KNOWLEDGE_EMBED_MODEL:Qwen/Qwen3-Embedding-8B
  --var KNOWLEDGE_EMBED_PROVIDER:nebius
  --var REPLY_PROVIDER:meta
  --var REPLY_LLM_MODEL:nvidia/Nemotron-3-Ultra-550b-a55b
  "$@")

if [ "$MODE" != "deploy" ]; then
  echo "(cd server && ${CMD[*]})"
  exit 0
fi
cd "$SERVER"
"${CMD[@]}"
echo "deployed; now run: ILLUNIS_DEVICE_TOKEN=... node scripts/check-deploy.mjs --smoke <base_url> --meta-demo"
