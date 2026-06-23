---
name: machin-meet
description: >-
  Operate, configure, and deploy machin-meet — a single-binary, self-hostable
  Calendly (one-person booking page) written in machin/MFL. Use this skill to set
  up a personal booking page, change availability/slot rules, read or cancel
  bookings, wire booking notifications (Discord/Telegram via machin-notify, or
  WhatsApp), or deploy it behind HTTPS.
---

# machin-meet — self-hostable booking page

## Mental model

A single native binary = HTTP server (`machweb`) + SQLite + an embedded booking
page. Visitors pick a free slot, leave a name, and get a `.ics` plus an
HMAC-signed manage/cancel link. The owner sees bookings at `/admin?key=<secret>`.
All times are the **server's local zone** (`$TZ`); stored as absolute Unix
seconds, so the data is zone-independent.

## Build & run

Needs the `machin` compiler (v0.33.0+), a C compiler, and `libsqlite3`.

```bash
./build.sh                                  # → ./machin-meet
MEET_SECRET='a-long-random-string' TZ='Europe/Paris' ./machin-meet
# open http://localhost:48080/   ·   admin at /admin?key=$MEET_SECRET
```

## Configuration (environment)

| var | default | meaning |
|-----|---------|---------|
| `MEET_SECRET` | `change-me-please` | HMAC key for manage links **and** the admin password — **always set this** |
| `MEET_TITLE` | `Book a 30-minute meeting` | page heading + calendar event title |
| `MEET_PORT` | `48080` | listen port |
| `MEET_DB` | `meet.db` | SQLite file (use an absolute path for deploys) |
| `TZ` | system | zone all times display in (the page labels it) |
| `MEET_NOTIFY_TOKEN` / `MEET_NOTIFY_CHANNEL` | — | send booking alerts via a [machin-notify](https://github.com/javimosch/machin-notify) hub (Discord/Telegram) |
| `MEET_NOTIFY_ADDR` | `127.0.0.1:48090` | machin-notify daemon address |
| `MEET_WA_CHATID` / `MEET_WA_BRIDGE` | — | WhatsApp alert via a local Baileys bridge |

## Availability & slot rules

These are functions at the top of `meet.src` — edit and rebuild:

- **`work_windows(wd)`** — weekly hours per weekday (`0`=Sun…`6`=Sat) as flat
  `[]int{startMin, endMin, …}`. Default: **Mon–Fri 09:00–17:00**.
- **`SLOT_MIN`** (30), **`MIN_NOTICE_S`** (2 h), **`MAX_AHEAD_S`** (14 days).

## HTTP surface

```
GET  /                      booking page (date picker → slots → form)
GET  /api/slots?date=Y-M-D  free slots → JSON [{start,label}]
POST /api/book              {start,name,email,note} → books; returns manage + ics links
POST /api/cancel            {id,token}              → cancels (HMAC-verified)
GET  /m/<id>?t=<token>      manage page (cancel)
GET  /ics/<id>?t=<token>    iCalendar .ics (DTSTART/DTEND in UTC)
GET  /admin?key=<secret>    owner's upcoming-bookings list
```

Read bookings: `GET /admin?key=$MEET_SECRET`. Cancel one programmatically: take
the `token` from the booking response (or the manage link) and
`POST /api/cancel {"id":N,"token":"…"}`.

## Notifications

machin-meet fires on every confirmed booking through two independent best-effort
paths (each a no-op if unset):

- **Discord/Telegram via [machin-notify](https://github.com/javimosch/machin-notify):**
  run that hub, add a channel, mint a token, then set `MEET_NOTIFY_TOKEN` +
  `MEET_NOTIFY_CHANNEL`. No provider code lives in machin-meet. (See that repo's
  SKILL.md.)
- **WhatsApp** to your own number via a local Baileys bridge (`MEET_WA_*`).

## Deploy behind HTTPS

Run the binary under **systemd** (robust; survives reboot), and put a reverse
proxy (Traefik/Caddy/nginx) in front for TLS, routing to `localhost:$MEET_PORT`.

```ini
# /etc/systemd/system/machin-meet.service
[Service]
User=appuser
Environment=MEET_SECRET=<48-hex>
Environment=MEET_PORT=48080
Environment=TZ=Europe/Paris
Environment=MEET_DB=/home/appuser/machin-meet.db
ExecStart=/home/appuser/machin-meet
Restart=always
[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now machin-meet
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:48080/   # expect 200
```

### Deploy gotchas (learned the hard way)

- **Don't pass spaces in env values via a process-manager `--cmd`** — wrap with
  `/usr/bin/env VAR=val …` or (better) use systemd `Environment=` lines.
- **A booking writes SQLite in the process CWD** unless `MEET_DB` is absolute —
  always set `MEET_DB=/abs/path` for deploys so bookings persist.
- **Reverse-proxy host rules:** if your tool auto-appends a base domain, pass the
  **subdomain only** (e.g. `app.dk1`), or you get a doubled `Host(app.dk1.base.base)`
  that 404s.
- **ACME DNS-01 "identical record already exists":** a stale `_acme-challenge`
  TXT from a previous attempt blocks issuance — delete it via the DNS provider's
  API, then restart the proxy to re-issue.
- The binary is dynamically linked (`libsqlite3` + glibc) — the target host needs
  a compatible glibc and `libsqlite3.so`.

## Build/runtime gotchas

- `json_get` returns string values **with surrounding quotes** (numbers bare);
  machin-meet's `jstr` strips + unescapes them — reuse it when reading request
  fields.
- A partial `UNIQUE` index on `start_utc` (confirmed rows) makes a colliding
  insert fail at the DB layer → `409`, preventing double-booking.
