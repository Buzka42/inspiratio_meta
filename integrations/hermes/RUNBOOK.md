# Runbook: Hermes `illunis` profile behind Cloudflare Tunnel + Access

The Worker reaches the owner's PC through this chain:

```
Worker --HTTPS + CF-Access-Client-Id/Secret + Bearer--> Cloudflare Access
       --> named tunnel "illunis-hermes" --> cloudflared on the PC
       --> http://127.0.0.1:8642/p/illunis/...  (host Hermes gateway, multiplexed)
```

Everything below was checked against Hermes v0.22.5 source and `--help` output. Steps
marked **(owner)** need the owner's accounts or decisions.

## 0. Before you start

- Run `cd server && npm ci` once, so the setup script can use the repo's own wrangler.
- Decide on the Worker URL (`https://<name>.<account>.workers.dev` or a custom domain).
- You need a domain on Cloudflare (a zone) for the tunnel hostname. These steps use
  `hermes.<zone>` as the example.

## 1. Create the profile

```bash
integrations/hermes/setup_profile.sh --dry-run --worker-url https://<worker-url>   # read the plan
integrations/hermes/setup_profile.sh --worker-url https://<worker-url>
```

The script does the following:

- Makes a full `hermes backup` into `~/hermes-backups/` with `-k 0`, so older backups
  are not pruned.
- Creates the fresh `illunis` profile with `--no-skills --no-alias` and parks it (the
  `gateway.parked` marker).
- Writes the toolset and approval config, `memory.provider: illunis_memory`, `SOUL.md`,
  the Bot Mode `ui_meta` and the plugin.
- Generates `API_SERVER_KEY` and `ILLUNIS_INBOX_SECRET`. It pipes them to
  `wrangler secret put HERMES_API_KEY` and `ILLUNIS_INBOX_SECRET`, then writes them to
  `~/.hermes/profiles/illunis/.env` (mode 600).

The script is safe to re-run. It keeps existing secrets unless you pass `--rotate`.

If you used `--skip-wrangler`, push the secrets later. The values never reach the screen
or argv:

```bash
cd server
sed -n 's/^API_SERVER_KEY=//p' ~/.hermes/profiles/illunis/.env | tr -d '\n' | npx --no-install wrangler secret put HERMES_API_KEY
sed -n 's/^ILLUNIS_INBOX_SECRET=//p' ~/.hermes/profiles/illunis/.env | tr -d '\n' | npx --no-install wrangler secret put ILLUNIS_INBOX_SECRET
```

## 2. Model, Bot Chat and the host API server **(owner)**

1. Pick the bot's model: `hermes -p illunis model`. The data rule applies: use only a
   provider that does not train on prompts, such as Meta standard tier, Nebius with the
   opt-out set, or a local model. The fresh profile has no keys. Add one with
   `hermes -p illunis auth add <provider>` or through the model picker.
2. Create the canonical Bot Chat once:
   `hermes -p illunis chat -c "Bot Chat" --create-if-missing`. Say hello, then exit.
   `message_agent` only exists in a session titled exactly `Bot Chat` on a Bot-Mode-managed
   install (`tools/bot_mode_dm.py:123-138`, `website/docs/user-guide/bot-mode.md`). Find
   its session id with `hermes -p illunis sessions list` and give it to the Worker as
   `HERMES_SESSION_ID`. The Worker then calls `/p/illunis/api/sessions/<id>/chat`.
3. Turn on the host API server. The `/p/illunis/` routes are mirrored by the **default**
   profile's API server listener. A named profile never opens its own listener under the
   multiplexer (`website/docs/user-guide/multi-profile-gateways.md`, "api_server and
   webhook are mirrored"). If `hermes gateway status` shows no API server on port 8642,
   set `API_SERVER_ENABLED=true` and the default profile's own `API_SERVER_KEY` in
   `~/.hermes/.env` (use `openssl rand -hex 32`), then run `hermes gateway restart`.
   This changes the default profile, so it is the owner's call. The default profile's
   full-tool agent then also listens on `127.0.0.1:8642` unprefixed. The tunnel below
   forwards only `/p/illunis/...`.
4. Unpark the bot: `hermes -p illunis gateway start`.

Check that it works locally. The key goes in through a process substitution, so it never
appears in argv:

```bash
hermes gateway status                       # 'illunis' in the served profiles, not parked
hermes -p illunis tools list --platform api_server   # only memory and web enabled
hermes -p illunis memory status             # provider illunis_memory
curl -s -H @<(printf 'Authorization: Bearer %s\n' "$(sed -n 's/^API_SERVER_KEY=//p' ~/.hermes/profiles/illunis/.env)") \
  http://127.0.0.1:8642/p/illunis/v1/toolsets | head -c 600; echo
```

## 3. cloudflared and the named tunnel

Install on Arch or Omarchy with `sudo pacman -S cloudflared`. Otherwise use the package
from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/.

```bash
cloudflared tunnel login                         # browser: pick the zone (owner)
cloudflared tunnel create illunis-hermes         # writes ~/.cloudflared/<UUID>.json
cloudflared tunnel route dns illunis-hermes hermes.<zone>
```

Create `~/.cloudflared/illunis-hermes.yml`. Only the routes the Worker needs are
forwarded. Everything else, including the unprefixed default-profile API, `/api/jobs`
and other profiles, gets a 404 at the edge of the PC:

```yaml
tunnel: <UUID>
credentials-file: /home/<user>/.cloudflared/<UUID>.json
ingress:
  - hostname: hermes.<zone>
    path: ^/p/illunis/(health|v1/health|v1/runs(/[A-Za-z0-9_-]+(/(events|stop))?)?|api/sessions/[A-Za-z0-9_-]+/chat(/stream)?)$
    service: http://127.0.0.1:8642
    originRequest:
      connectTimeout: 10s
  - service: http_status:404
```

Check and run it:

```bash
cloudflared tunnel --config ~/.cloudflared/illunis-hermes.yml ingress validate
cloudflared tunnel --config ~/.cloudflared/illunis-hermes.yml ingress rule https://hermes.<zone>/p/illunis/v1/runs
cloudflared tunnel --config ~/.cloudflared/illunis-hermes.yml run illunis-hermes      # foreground
```

To run it as a user service instead, create `~/.config/systemd/user/cloudflared-illunis.service`:

```ini
[Unit]
Description=cloudflared tunnel illunis-hermes
After=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --config %h/.cloudflared/illunis-hermes.yml run illunis-hermes
Restart=on-failure

[Install]
WantedBy=default.target
```

Then run `systemctl --user daemon-reload && systemctl --user enable --now cloudflared-illunis`.

## 4. Cloudflare Access application and service token **(owner, Zero Trust dashboard)**

1. Go to **Zero Trust** (one.dash.cloudflare.com), then **Access**, then **Service auth**,
   then **Service Tokens**, then **Create Service Token**.
   - Name: `illunis-worker`. Duration: 1 year, or shorter if you prefer.
   - Copy the **Client ID** and **Client Secret** now. The secret is shown only once.
2. Go to **Access**, then **Applications**, then **Add an application**, then **Self-hosted**.
   - Application name: `Illunis Hermes`.
   - Application domain: subdomain `hermes`, domain `<zone>`, path empty. The whole host
     is protected.
   - Session duration: 24 hours. It barely matters, because service tokens send their
     headers on every request.
   - Identity providers: none needed.
3. Add a policy to that application:
   - Policy name: `Worker service token`.
   - Action: **Service Auth**. Use Service Auth, not Allow. Allow would send a browser
     login page to the Worker.
   - Include: **Service Token**, value `illunis-worker`.
   - Add no other include rules, and no Bypass or Everyone rules.
4. Save the application.
5. Store the token as Worker secrets. The owner types or pastes the values at the
   prompt, never into chat:

   ```bash
   cd server
   npx --no-install wrangler secret put CF_ACCESS_CLIENT_ID
   npx --no-install wrangler secret put CF_ACCESS_CLIENT_SECRET
   ```

   Set `HERMES_BASE_URL=https://hermes.<zone>` as a Worker var. the Worker adds it to
   `wrangler.jsonc` `vars`.

Check from outside the PC. The responses show only status codes:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://hermes.<zone>/p/illunis/health        # 403: Access blocks
curl -s -o /dev/null -w '%{http_code}\n' https://hermes.<zone>/p/hermes/v1/models      # 403 (no token), 404 with one
```

## 5. How the Worker calls Hermes

```js
const res = await fetch(`${env.HERMES_BASE_URL}/p/illunis/api/sessions/${env.HERMES_SESSION_ID}/chat`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${env.HERMES_API_KEY}`,
    "CF-Access-Client-Id": env.CF_ACCESS_CLIENT_ID,
    "CF-Access-Client-Secret": env.CF_ACCESS_CLIENT_SECRET,
    "Idempotency-Key": crypto.randomUUID(),
  },
  body: JSON.stringify({ message: JSON.stringify(request) }),  // request per CONTRACT.md
  signal: AbortSignal.timeout(45_000),
});
```

The handler reads the turn text from `message` or `input` (`gateway/platforms/api_server.py:576`).
It also accepts `system_message` and `instructions` (`api_server.py:2844`). The Worker must
never send either. The SOUL is the only instruction source. The reply text must pass
`validate_reply` (CONTRACT.md). Inbox pushes arrive at
`POST /assistant/inbox`, signed as described in CONTRACT.md. The 300 s skew rule and
nonce replay protection apply.

## 6. Start and stop

| Goal | Command |
|---|---|
| Serve the bot (unpark) | `hermes -p illunis gateway start` |
| Take only the bot offline (park) | `hermes -p illunis gateway stop` |
| Reload the bot's config or .env | `hermes -p illunis gateway restart` |
| Status | `hermes gateway status`, `hermes -p illunis gateway status` |
| Tunnel off / on | `systemctl --user stop cloudflared-illunis` / `start` |
| Everything off (host gateway) | `hermes gateway stop` (this stops the owner's other bots too) |

To rotate the keys, run `setup_profile.sh --rotate --skip-backup --worker-url ...`
(which pushes the new values), then run `hermes -p illunis gateway restart`.

## 7. Rollback

1. Stop the traffic: `systemctl --user disable --now cloudflared-illunis`, then
   `hermes -p illunis gateway stop`.
2. Remove the bot. This permanently deletes its sessions and `illunis_memory/memory.db`.
   Export first if you want them, with `hermes -p illunis sessions export`.
   ```bash
   hermes profile delete illunis -y
   ```
3. Remove the Worker secrets: `cd server && npx --no-install wrangler secret delete HERMES_API_KEY`.
   Repeat for `ILLUNIS_INBOX_SECRET`, `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`.
4. **(owner)** In Zero Trust, delete the `Illunis Hermes` application and revoke the
   `illunis-worker` service token. Then run `cloudflared tunnel delete illunis-hermes`
   and delete the `hermes.<zone>` DNS record.
5. If something else in Hermes changed, restore the backup the script made:
   `hermes import ~/hermes-backups/pre-illunis-<stamp>.zip`. It asks before
   overwriting. `--force` skips the prompt.
6. If you turned on the default profile's API server only for this, remove
   `API_SERVER_ENABLED` and its key from `~/.hermes/.env`, then run `hermes gateway restart`.

## Known limits

- Replies between bots are asynchronous. `message_agent` returns `queued`. In an
  `api_server` session the reply is not pushed back on its own. It lands in the Bot Chat
  transcript when the delivery process exits (`tools/bot_mode_dm.py:758-770`), and
  `process(wait)` is unavailable because the terminal toolset is off. The bot forwards it
  with `illunis_push` on its next turn. the Worker can trigger that turn with a `message` request
  after the inbox poll.
- `message_agent` runs its delivery through Hermes's internal `terminal_tool(_host_local=True)`.
  `agent.disabled_toolsets` hides the terminal *tool* from the model. It is not verified
  that this leaves the internal delivery path working. Test one approved `message_bot`
  action before the demo. If it fails, remove `"terminal"` from `agent.disabled_toolsets`;
  the platform lists still keep it off the model.
- Under the multiplexer, every profile shares one listener, so the tunnel path filter
  and the Access policy are the boundary. The per-profile `API_SERVER_KEY` is enforced
  on `/p/illunis/` (`api-server.md`, "Multi-profile routing").

## Quick tunnel without a zone (owner choice, 2026-10-25)

Used until a domain is on Cloudflare. No Access: the boundary is the path filter plus the illunis bearer key.

- `proxy/path_filter.py` listens on `127.0.0.1:8643` and forwards only the `/p/illunis/` allowlist (same regex as section 3) to `127.0.0.1:8642`; everything else is 404 locally. Tests: `tests/test_path_filter.py`.
- User services (copies in `proxy/`): `illunis-path-filter.service`, `illunis-quick-tunnel.service` (`cloudflared tunnel --url http://127.0.0.1:8643`). Never point a quick tunnel at 8642 directly: that exposes the default profile's full-tool API.
- The URL changes on every tunnel restart. Read it with
  `journalctl --user -u illunis-quick-tunnel -n 60 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1`
  and redeploy the Worker with `--var HERMES_BASE_URL:<url> --var HERMES_ACCESS_MODE:quick_tunnel`.
- Off: `systemctl --user disable --now illunis-quick-tunnel illunis-path-filter`.
- Live check 2026-10-25 through the tunnel: memory write 200, recall 200 (3.5 s), message 200 (2.6 s), inbox poll 200. Outside probes: `/p/illunis/health` 200, `/health`, `/v1/models`, `/api/jobs`, `/p/default/health` all 404.
