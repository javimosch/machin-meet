# machin-meet

A **minimal, self-hostable Calendly for one person** — written in **[machin](https://github.com/javimosch/machin)** (MFL). A *single native binary*: HTTP server + SQLite + an embedded booking page. Visitors pick a free slot, leave their name, and get a calendar `.ics` plus a signed manage/cancel link. No accounts, no SaaS, no dependencies beyond libc + libsqlite3.

Part of [**awesome-machin**](https://github.com/javimosch/awesome-machin) — the machin ecosystem. Booking alerts via [**machin-notify**](https://github.com/javimosch/machin-notify) (Discord/Telegram) or a WhatsApp bridge.

> **Agents:** [`SKILL.md`](SKILL.md) teaches how to operate, configure, deploy, and add notifications.

## Why it exists (dogfooding)

A booking tool has to answer "**09:00 local on a given day → which Unix second?**" to enumerate slots. machin could *decompose* (`time_fields`) and *render* (`time_format`) a timestamp, but not *construct* one. Building machin-meet drove **`time_make`** into machin (v0.30.0):

```machin
time_make(2026, 6, 25, 9, 0, 0)   // -> 1782378000  (mktime, local time, DST-aware)
```

That completes machin's **time trio**: `time_make` (construct) ↔ `time_fields` (decompose) ↔ `time_format` (render). Finishing the `.ics` output then drove one more: **`time_format_utc`** (v0.31.0), strftime in UTC, for the `DTSTART:…Z` stamps. Wiring the booking page's percent-escaped query/form values drove **`url_decode`** (v0.32.0), and adding WhatsApp notifications via a cloud provider drove **`http_request`** (v0.33.0, authenticated HTTPS). machin-meet also leans on `sqlite_*` (bookings), `hmac_sha256` (signed links), and `json_get` (request bodies) — all earlier dogfood builtins, now composed into one real app.

## Build

Needs the [machin](https://github.com/javimosch/machin) compiler (v0.33.0+) on `PATH`, plus a C compiler and `libsqlite3`.

```bash
./build.sh                          # → ./machin-meet
MACHIN=~/ai/machin/machin ./build.sh
```

## Run

```bash
MEET_SECRET='a-long-random-string' \
MEET_TITLE='Book a 30-min call with Jane' \
TZ='Europe/Madrid' \
./machin-meet
```

Then open **http://localhost:48080/** to book, or **/admin?key=YOUR_SECRET** to see upcoming bookings.

### Configuration (environment)

| Var | Default | Meaning |
|-----|---------|---------|
| `MEET_SECRET` | `change-me-please` | HMAC key for manage/cancel links **and** the admin password. Set this. |
| `MEET_TITLE`  | `Book a 30-minute meeting` | Page heading + calendar event title |
| `MEET_PORT`   | `48080` | Listen port |
| `MEET_DB`     | `meet.db` | SQLite file (created on first run) |
| `TZ`          | system | Time zone everything is shown in (the page labels it) |
| `MEET_WA_CHATID` | *(unset)* | Your WhatsApp JID (e.g. `15551234567@s.whatsapp.net`). Set it to get a WhatsApp ping on every booking; leave empty to disable. |
| `MEET_WA_BRIDGE` | `127.0.0.1:3000` | host:port of the WhatsApp bridge (see below) |
| `MEET_NOTIFY_TOKEN` | *(unset)* | App token for a [machin-notify](https://github.com/javimosch/machin-notify) hub. Set it (+ channel) to get Discord/Telegram alerts on every booking. |
| `MEET_NOTIFY_CHANNEL` | *(unset)* | The machin-notify channel/route to send bookings to (e.g. `bookings`) |
| `MEET_NOTIFY_ADDR` | `127.0.0.1:48090` | host:port of the machin-notify daemon |

## Notifications (optional)

machin-meet pings you on every booking through two independent, best-effort paths — set whichever you want (or both); each is a no-op if unconfigured:

- **Discord / Telegram** via a [machin-notify](https://github.com/javimosch/machin-notify) hub — run the hub, add a channel, mint a token, then set `MEET_NOTIFY_TOKEN` + `MEET_NOTIFY_CHANNEL`. No provider code in machin-meet; add/route channels at the hub.

  ```bash
  machin-notify daemon &
  machin-notify add discord bookings <webhook-url>
  TOK=$(machin-notify token new machin-meet | grep -oE '[0-9a-f]{48}')
  MEET_NOTIFY_TOKEN=$TOK MEET_NOTIFY_CHANNEL=bookings MEET_SECRET=… ./machin-meet
  ```

- **WhatsApp** to your own number via a local Baileys bridge (below).

## WhatsApp notifications (optional)

Get a WhatsApp message to **your own number** the moment someone books — no Twilio, no Meta API keys, no per-message cost. machin-meet reuses the same simple pattern as [Hermes](https://github.com/javimosch/hermes-agent) / OpenClaw: a local **Baileys bridge** that you pair once with your number (the WhatsApp Web protocol).

1. Run the bridge and pair your number once (scan the QR with WhatsApp → Linked devices). With Hermes installed that's `hermes whatsapp`; the bridge listens on `127.0.0.1:3000` and exposes `POST /send {chatId, message}`.
2. Start machin-meet with your JID:

   ```bash
   MEET_WA_CHATID='15551234567@s.whatsapp.net' \
   MEET_SECRET='…' ./machin-meet
   ```

On each confirmed booking machin-meet POSTs a one-line summary (name, time, email, note) to the bridge's `/send`, which delivers it from your paired number to itself. It's **best-effort and fire-and-forget** — if the bridge is down the booking still succeeds. Point `MEET_WA_BRIDGE` elsewhere to use a different host/port.

> Want a cloud provider instead (Twilio / WhatsApp Cloud API)? machin's `http_request` builtin (v0.33.0) can do an authenticated HTTPS POST with a `Bearer`/Basic `Authorization` header — swap `notify_owner` in [`meet.src`](meet.src) to call it.

Availability, slot length, notice and horizon live in clearly-named functions at the top of [`meet.src`](meet.src) — edit and rebuild:

- **`work_windows(wd)`** — weekly hours per weekday (`0`=Sun…`6`=Sat). Default: **Mon–Fri 09:00–17:00**.
- **`SLOT_MIN`** (30), **`MIN_NOTICE_S`** (2 h), **`MAX_AHEAD_S`** (14 days).

## How it works

```
GET  /                      embedded booking page (date picker → slots → form)
GET  /api/slots?date=Y-M-D  free slots for that day  → JSON [{start,label}]
POST /api/book              {start,name,email,note}  → books, returns manage + ics links
POST /api/cancel            {id,token}               → cancels (HMAC-verified)
GET  /m/<id>?t=<token>      manage page (cancel button)
GET  /ics/<id>?t=<token>    iCalendar .ics (DTSTART/DTEND in UTC)
GET  /admin?key=<secret>    owner's upcoming-bookings list
```

- **Times** are the server's local zone throughout; the page states which. Stored as absolute Unix seconds, so the data is zone-independent.
- **Slot math** steps each weekly window in `SLOT_MIN` increments via `time_make` (DST-correct), then drops slots that are too soon, beyond the horizon, or already taken.
- **No double-booking**: a partial `UNIQUE` index on `start_utc` (confirmed rows only) makes a colliding insert fail at the DB layer → `409`.
- **No accounts**: the manage link *is* the auth — `token = hmac_sha256(secret, "booking:"+id)`. Tampering fails verification.
- **SQL injection-safe**: every query uses bound `?` parameters.

## Limitations (it's an MVP)

- One event type; availability is the same every week (no date overrides/holidays).
- Times display in the **server's** zone, not the visitor's (fine for a one-person link; simplest correct thing).
- No email — confirmation is the `.ics` download + manage link. (Add `https_post` to an email API to send one.)
- HMAC compare isn't constant-time; `jstr` doesn't unescape inner JSON escapes. Good enough for a personal scheduler, not a multi-tenant SaaS.

## Layout

```
machin-meet/
├── meet.src      # the app (MFL)
├── machweb.src   # vendored web framework (router/response helpers)
├── build.sh      # encode → compile to native
└── README.md
```
