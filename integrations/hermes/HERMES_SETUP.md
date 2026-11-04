# Hermes: set up the Illunis bot (feed this file to Hermes)

You are Hermes Agent, running on the owner's PC. The owner wants you to set up a separate Hermes profile called `illunis`, then connect it to the Illunis Worker through a Cloudflare Tunnel. Work through the steps below in order.

The full reference is `~/Projects/illunis-rework/integrations/hermes/RUNBOOK.md`, and the message format is in `CONTRACT.md` in the same folder. If this file and the runbook disagree, the runbook wins. Tell the owner when that happens.

## Hard rules (apply to every step)

1. **Never show a secret.** No API key, token, service-token secret or `.env` value may appear in your output, in chat, in command arguments, in logs or in any file outside `~/.hermes/profiles/illunis/.env` and `~/.cloudflared/`. Pass secrets by pipe or process substitution, as the runbook does. Don't `cat`, `grep` or `echo` a `.env` file.
2. **Never touch the default profile or other profiles**, except in step 4, and only after the owner says yes. Don't edit `~/.hermes/config.yaml`, `~/.hermes/.env`, memories or sessions.
3. **Don't edit anything in `~/Projects/illunis`.** That is the owner's private repo. Work only from `~/Projects/illunis-rework`.
4. **Stop and ask** at every step marked **ASK OWNER**. Wait for an explicit answer. Don't guess a domain, a model or a provider.
5. If any command fails, stop, show the error with secrets redacted, and ask the owner how to proceed. Don't improvise workarounds that change security settings.
6. **Health-data rule:** the `illunis` bot sees the owner's real health data. Default: use only a provider that does not train on prompts. **Owner exception 2026-10-25 (owner_any mode, owner's data only):** the owner explicitly allows Contributor and free tiers for their own data (Meta Contributor trains on prompts; NVIDIA logs free-endpoint data). If `owner_any` is ever unset, the default guard comes back. Never extends to anyone else's data.
7. Keep a short checklist as you go, and report it at the end (see "Final report").

## Fixed values

- Repo: `~/Projects/illunis-rework`
- Worker URL: `https://<worker>.<account>.workers.dev`
- Profile name: `illunis`
- Tunnel name: `illunis-hermes`
- Local API server: `http://127.0.0.1:8642`

## Step 0: Preflight

```bash
cd ~/Projects/illunis-rework
hermes --version
hermes gateway status
command -v openssl npx cloudflared || true
ls server/node_modules/.bin/wrangler || (cd server && npm ci)
```

If the profile `illunis` already exists (`hermes profile list`), say so and ask the owner whether to keep it and re-run the script (safe, because it keeps existing secrets) or stop. **ASK OWNER** only in that case.

## Step 1: Dry run, then create the profile

```bash
cd ~/Projects/illunis-rework
integrations/hermes/setup_profile.sh --dry-run --worker-url https://<worker>.<account>.workers.dev
```

Show the owner the planned actions as a short summary. **ASK OWNER:** "Run the setup for real?" On yes:

```bash
integrations/hermes/setup_profile.sh --worker-url https://<worker>.<account>.workers.dev
```

The script backs up Hermes to `~/hermes-backups/`, creates the parked `illunis` profile, and installs the persona and the `illunis_memory` plugin. It also generates two secrets and pushes them to the Worker (`HERMES_API_KEY`, `ILLUNIS_INBOX_SECRET`). If wrangler asks for a Cloudflare login, tell the owner to complete it in the browser, then continue.

Check:

```bash
hermes profile list                      # illunis present
hermes -p illunis memory status          # provider: illunis_memory
hermes -p illunis tools list --platform api_server   # memory and web only; no terminal, file, computer-use or kanban
```

If terminal or file tools show as enabled for `api_server`, stop and report it.

## Step 2: Model for the bot (ASK OWNER)

Ask the owner which non-training provider and model the `illunis` bot should use (rule 6). Then run `hermes -p illunis model` interactively with them, or `hermes -p illunis auth add <provider>`. The owner enters any key themselves at the prompt, never in chat.

## Step 3: Bot Chat session

```bash
hermes -p illunis chat -c "Bot Chat" --create-if-missing
```

Send one line ("hello, setup check"), confirm the bot answers, then exit. Then:

```bash
hermes -p illunis sessions list
```

Note the id of the session titled exactly `Bot Chat`. The owner sets it as a Worker var later (step 8). The session id is not a secret, so you may show it.

## Step 4: Host API server (ASK OWNER, changes the default profile)

The `/p/illunis/...` routes are served by the default profile's API server on port 8642.

Run `hermes gateway status`. If the API server already listens on 8642, skip to step 5.

Otherwise, explain to the owner: "This turns on the API server for your main Hermes profile, bound to localhost only, with its own new key. Only `/p/illunis/` will be forwarded through the tunnel." **ASK OWNER:** "Enable it?" On yes, add the settings without printing the key:

```bash
grep -q '^API_SERVER_ENABLED=' ~/.hermes/.env || printf 'API_SERVER_ENABLED=true\n' >> ~/.hermes/.env
grep -q '^API_SERVER_KEY=' ~/.hermes/.env || printf 'API_SERVER_KEY=%s\n' "$(openssl rand -hex 32)" >> ~/.hermes/.env
hermes gateway restart
```

The `grep -q` lines only test for presence and print nothing. Don't read the file in any other way.

## Step 5: Start the bot and check locally

```bash
hermes -p illunis gateway start
hermes gateway status                     # illunis served, not parked
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8642/p/illunis/health
curl -s -H @<(printf 'Authorization: Bearer %s\n' "$(sed -n 's/^API_SERVER_KEY=//p' ~/.hermes/profiles/illunis/.env)") \
  -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8642/p/illunis/v1/toolsets
```

Expect `200` for both. Report the status codes only, not the response bodies.

## Step 6: Cloudflare Tunnel

1. If `cloudflared` is missing: **ASK OWNER** to run `sudo pacman -S cloudflared` themselves. You don't use sudo.
2. **ASK OWNER:** "Which domain on your Cloudflare account should host the tunnel?" Call the answer `<zone>`. The hostname will be `hermes.<zone>`.
3. Run:
   ```bash
   cloudflared tunnel login                        # owner picks the zone in the browser
   cloudflared tunnel create illunis-hermes        # note the UUID it prints (not a secret)
   cloudflared tunnel route dns illunis-hermes hermes.<zone>
   ```
4. Write `~/.cloudflared/illunis-hermes.yml` exactly as in RUNBOOK.md section 3. Fill in the UUID, your home path and `hermes.<zone>`, and keep the path filter regex as written. Then:
   ```bash
   cloudflared tunnel --config ~/.cloudflared/illunis-hermes.yml ingress validate
   cloudflared tunnel --config ~/.cloudflared/illunis-hermes.yml ingress rule https://hermes.<zone>/p/illunis/v1/runs
   ```
   The rule check must match the `127.0.0.1:8642` service. Also check that `https://hermes.<zone>/p/hermes/v1/models` maps to `http_status:404`.
5. Create the user service from RUNBOOK.md section 3 at `~/.config/systemd/user/cloudflared-illunis.service`, then:
   ```bash
   systemctl --user daemon-reload && systemctl --user enable --now cloudflared-illunis
   systemctl --user status cloudflared-illunis --no-pager | head -5
   ```

## Step 7: Cloudflare Access (owner does this in the dashboard)

You can't click the dashboard. Give the owner these steps, exactly as in RUNBOOK.md section 4, and wait until they say "done":

1. Zero Trust, then Access, then Service auth, then Service Tokens: create `illunis-worker`, and copy the Client ID and Secret (the secret is shown once).
2. Access, then Applications, then Add, then Self-hosted: name `Illunis Hermes`, domain `hermes.<zone>`, path empty.
3. Policy `Worker service token`: action **Service Auth**, include Service Token `illunis-worker`, and nothing else.

Then check from the PC, which should return `403` because there is no token:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://hermes.<zone>/p/illunis/health
```

## Step 8: Worker secrets and vars (owner types the values)

Tell the owner to run these from `~/Projects/illunis-rework/server`, and to paste the values at the prompt, never in chat:

```bash
npx --no-install wrangler secret put CF_ACCESS_CLIENT_ID
npx --no-install wrangler secret put CF_ACCESS_CLIENT_SECRET
```

Then tell the owner to give Claude (the Illunis lead) these non-secret values, so the Worker vars get set on the next deploy:

- `HERMES_BASE_URL=https://hermes.<zone>`
- `HERMES_SESSION_ID=<Bot Chat session id from step 3>`

Confirm that the secret names exist, which lists names only:

```bash
cd ~/Projects/illunis-rework/server && npx --no-install wrangler secret list
```

Expected: `HERMES_API_KEY`, `ILLUNIS_INBOX_SECRET`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` (plus the existing ones).

## Step 9: Bot messaging test (one message, owner approves)

**ASK OWNER** which of their other bots (profiles) to test with, then run one test in the Bot Chat session: `hermes -p illunis chat -c "Bot Chat"`, asking the bot to send that bot a harmless "ping from illunis" message.

- If it is delivered, note **PASS**.
- If delivery fails with a terminal-related error, report it. The known fix in RUNBOOK.md "Known limits" is to remove `"terminal"` from the illunis profile's `agent.disabled_toolsets`. **ASK OWNER** before applying it.

## Final report

Reply to the owner with a checklist (no secrets) covering:

- the backup file path
- profile created (yes/no), memory provider, api_server tools
- the model and provider chosen
- the Bot Chat session id
- whether the default profile's API server was enabled (yes/no/already)
- local health codes
- tunnel name, hostname, and whether the service is active
- Access done (owner), and the 403 check
- secret names present on the Worker
- the bot-messaging test result
- anything skipped or failed

## Rollback (only if the owner asks)

Follow RUNBOOK.md section 7.
