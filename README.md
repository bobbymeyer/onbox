# onbox — The Stack

The world is concurrent; Bobby's attention is single-threaded. The Stack is the
serializer in between: everything pulling at him (Claude Code agents finishing,
email, calendar invitations, reminders, anything else that can POST) becomes
one index card in front of him, and a secretary decides which one.

Rails 8, omakase: SQLite, Solid Queue / Cache / Cable, Hotwire, importmap,
Propshaft. It runs natively on the Mac Studio and is reached from the phone
over Tailscale.

## Sources

| Source | How it arrives | What handling it does |
|---|---|---|
| Claude Code | Stop and Notification hooks (`script/stack-hook`) | Sends your instruction back to the session (`claude --resume … -p`) on your Max plan |
| Gmail | Polled every 2 minutes | Replies in the thread, or archives it |
| Calendar (the Mac's) | Read every 2 minutes through EventKit | Invitations you answer in Calendar clear themselves; moves and cancellations are heads-ups |
| Reminders (the Mac's) | Read every 2 minutes through EventKit | Done completes the reminder; Later moves its due time |
| Anything else | `POST /intake` with a source token | Whatever the card says |

## Setting it up on the Mac

```sh
bin/setup --skip-server
bin/rails db:seed    # creates the sources and first stamps; prints the claude-code token
bin/serve            # production mode, with the job scheduler, on port 3000
```

`bin/serve` is how onbox should run: in production mode with Solid Queue inside
the server, so polling, digests and timed wake-ups happen. It makes a
`SECRET_KEY_BASE` once and keeps it in `storage/secret_key_base`; keep that file,
since it encrypts the stored tokens. (`bin/dev` runs development mode, where the
schedule doesn't run.)

Reach it over Tailscale. With `tailscale serve --bg 3000` you get
`https://<mac-studio>.<tailnet>.ts.net` and the defaults are right. For plain
`http://<mac-studio>:3000`, set `STACK_FORCE_SSL=false`. Add it to the phone's
home screen for full screen.

Calendar, Reminders and agent replies need the host's Calendar, Reminders and
`claude` sessions, so run onbox natively rather than in the Docker image.

### Claude: your login, your Max plan

Everything Claude does for the stack goes through Claude Code on your Claude
account: replies to agent sessions and the secretary's deeper duties. Connect it
on `/secretary`: **Connect Claude** → **Sign in to Claude** (approve on
claude.com; works from the phone) → paste the code Claude shows → **Connect**.

Behind the button onbox runs Claude Code's own sign-in (`claude setup-token`) on
the Mac and relays the link and your code; it never talks to Claude's sign-in
itself. The long-lived token Claude Code prints (inference only, one year) is
stored encrypted and handed only to the `claude` CLI as `CLAUDE_CODE_OAUTH_TOKEN`.
`/secretary` shows when to renew. Until you connect, onbox uses whatever login
Claude Code on the Mac already has. Every `claude` run the stack starts has
`ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` removed, so usage lands on your
subscription rather than an API key.

### The secretary: mostly local

The secretary writes card fronts, resolves "later", places cards, drafts
decompositions, talks with you in maintenance mode and writes digests. Its
duties run in two tiers:

| Tier | Duties | Setting | Default |
|---|---|---|---|
| routine | card fronts, "later", hourly and daily digests | `STACK_SECRETARY` | `local` |
| deep | conversation, decompose, weekly and monthly digests | `STACK_SECRETARY_DEEP` | `claude_code` (your Max plan) |

`local` is any OpenAI-compatible endpoint that supports a `json_schema`
response format (llama-swap on the Mac Studio): set `STACK_SECRETARY_URL`
(default `https://chat.bobbymeyer.com/v1`) and `STACK_SECRETARY_MODEL` to a model
id from its `/v1/models`. Replies are constrained to each duty's schema. Either
tier can also be `off`; set `STACK_SECRETARY_DEEP=local` to keep everything
local. When a tier is off or its model fails, every duty falls back: cards keep
the intake's plain front, "later" uses the built-in phrase parser, digests are
the plain numbers.

`/secretary` shows each tier's backend, whether the endpoint and model are
ready, the Claude connection, and a **Test** button per tier.

### The Judge: OpenJev beside the secretary

Set `STACK_JUDGE_URL` to an [OpenJev](https://github.com/razorback16/openjev)
server (on the Studio, `http://127.0.0.1:9300`) and each new card's front gets
a second, typed reading. OpenJev answers questions as probabilities rather
than writing text, so it takes the parts of the front that are a choice:

| Question | Type | What it decides |
|---|---|---|
| What does this card need? | choice | the ask: decision, reply, review, acknowledge |
| Does it need you now? | yes/no | front of the stack, or where new cards land |
| Would you stamp it X? | yes/no per stamp (up to 12) | the likely stamps, up to three |
| Does this instruction apply? | yes/no per standing instruction | which instructions the secretary sees |

The Judge reads first. The secretary then writes the summary and proposed
action with only the standing instructions that weren't clearly irrelevant,
and the Judge's clear answers stand over its own. Only answers at
`STACK_JUDGE_THRESHOLD` (default `0.8`) or past it either way count; anything
in between stays with the secretary. A hold stays the secretary's call, since
it needs a time. With the secretary off, the Judge still sets the ask,
placement and stamps on the intake's own front. When the Judge is unset or
doesn't answer (it waits up to 20 seconds, which covers a slow first read after
the model was paged out), cards are written exactly as without it.

Each card keeps the Judge's probabilities under "Raw payload" on its back and
in the log (`[judge] card 12: …`, with how many answers were unclear), so the
threshold can be tuned from real cards. `/secretary` shows whether the Judge is
reachable and lists its model, with a **Test** button. The stack's order stays
positional; the Judge only chooses between "front" and where new cards land.

### Claude Code hooks

Add the hooks to `~/.claude/settings.json` (see `script/claude-settings.example.json`):

```json
{
  "env": { "STACK_URL": "https://mac-studio.<tailnet>.ts.net", "STACK_TOKEN": "<claude-code token>" },
  "hooks": {
    "Stop":         [{ "hooks": [{ "type": "command", "command": "/path/to/onbox/script/stack-hook" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "/path/to/onbox/script/stack-hook" }] }]
  }
}
```

The hook POSTs its JSON input untouched and never blocks or fails the agent's
turn. `session_id` is the card's key, so a session holds one open card; a new
Stop refreshes it and puts it back on top. When the hook input has no last
assistant message, the intake reads it from `transcript_path`. When you send an
instruction, the next Stop brings the result back as a fresh card; a failed send
comes back as a card too. The secretary's own `claude` runs are marked
`STACK_INTERNAL=1`, which the hook ignores.

### Gmail

1. In Google Cloud Console, create a project, enable the **Gmail API**, and
   create an OAuth client of type **Desktop app**. If the consent screen is in
   testing mode, add yourself as a test user (testing-mode tokens expire after
   7 days; publish the app, still unverified, to keep them).
2. On `/sources`, paste the client ID and secret under **Google** (stored
   encrypted; or set `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`).
3. On the `gmail` source, **Connect** → **Sign in with Google** → allow. Google
   then sends the browser to a `localhost` address that won't load; copy that
   address, paste it into onbox, **Connect**. (`bin/rails gmail:connect[gmail]`
   does the same from a terminal.)

Each thread holds one open card: sender and subject on the front, the
secretary's drafted reply as the proposed action, the message on the back.
**Send reply** (or **Approve**) replies in the thread; **Archive** archives it.
The scope is `gmail.modify` (no permanent delete). Which mail becomes a card is
a Gmail search, `in:inbox category:primary` by default, editable on `/sources`.
Mail from someone emits `gmail:from:<address>`, so "later, until Ada replies"
wakes the card when she does.

### Calendar and Reminders

onbox reads the Mac's Calendar (which already syncs your Google calendars) and
Reminders through a small Swift helper using EventKit (`script/eventkit/`). It
builds the helper on first use, so the Mac needs the Xcode command line tools
(`xcode-select --install`). On `/sources`, tap **Allow access** on the
`calendar` and `reminders` sources and click Allow in the macOS prompt. If no
prompt appears (a server started by launchd can't show one), run
`tmp/bin/onbox-eventkit request` once in Terminal, or allow it in System
Settings → Privacy & Security.

**Calendar** makes a decision card for each invitation you haven't answered (one
per series), with when, where, any clash with a meeting you're going to, and the
secretary's advice. Apple offers no way for an app to answer an invitation, so
you answer in Calendar and the card clears itself once that syncs. Meetings you
were going to that move or are cancelled become heads-ups. "Later … after my
3pm" wakes the card when that meeting ends.

**Reminders** become cards when they come due, from any list, and everything in
the **Stack** list becomes a card at once, so "Hey Siri, add renew passport to
Stack" lands in front of you. **Done** completes the reminder, **Later** moves
its due time, completing it in Reminders clears the card. The list name is
editable on `/sources`.

### Anything else

Create a `generic` source on `/sources` and POST JSON:

```sh
curl -X POST "$STACK_URL/intake" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"summary":"Print finished","project":"shop","ask":"acknowledge","event":"print.done"}'
```

Fields: `summary`, `project`, `ask` (decision / reply / review / acknowledge),
`proposed_action`, `body`, `key` (dedupes open cards), `event` (wakes cards held
on `<source>:<event>`). Senders that can't set headers can pass `?token=`.

## Using it

**The dispenser (`/`)** shows one card, full screen, with no count. Its front
has the source, project, age, summary, the ask, and the secretary's proposed
action. Below that: the stamp tray, the card's own tool (instruction, reply,
note), **Flip** for the full payload, and **Top of the stack** / **Later**.

- **Stamps** apply a saved action in one tap. A stamp can send a templated
  message (`{{project}}`, `{{summary}}`), seed successor cards that wait on each
  other, repeat on an interval, and require a flip first for anything
  irreversible. Manage them on `/stamps`.
- **Top of the stack** puts the card back to fall again; **Later** holds it
  until a time ("2h", "tonight", "friday", "after my 3pm") or an event.
- **Decompose** breaks a card into single-action cards. The secretary drafts
  the steps and you edit them; each waits on the one before, the first goes to
  the front and the rest land on top.
- **The noticer** watches your free-text replies. A phrase typed three times in
  60 days that no stamp covers becomes an offer card: make it a stamp, or don't
  (`STACK_NOTICER_THRESHOLD`).

**Maintenance mode (`/stack`)** shows the whole stack. Move cards, edit,
decompose, and act on a selection in bulk (later, to front, to top, re-tag,
release, done, delete). **Talk to the secretary** there: ask why a card sits
where it does, or have it move, hold, release and re-tag cards. It can't delete,
handle or send anything, and it lists every change it makes. **Standing
instructions** ("hold receipts until 18:00") apply to every new card.

**Digests (`/digests`)** are the secretary's accounting: what it held and why,
what it put in front, what came and went, and drift (stale cards, repeated
deferrals, a rising flip rate). They're written for each hour, day, week and
month in which you worked cards, each built from the shorter ones inside it.
Daily and longer ones also become a card: right away if you're still working,
otherwise after your next gesture. Idle periods get nothing.

## Environment

| Variable | Default | What it does |
|---|---|---|
| `STACK_TIME_ZONE` | `UTC` | Where "tonight" and digest days resolve, e.g. `Pacific Time (US & Canada)` |
| `STACK_FORCE_SSL` | `true` | `false` to serve plain HTTP over the tailnet |
| `STACK_PASSWORD` / `STACK_USER` | unset / `bobby` | Optional HTTP basic auth on the views; Tailscale is the main perimeter |
| `STACK_SECRETARY` / `STACK_SECRETARY_DEEP` | `local` / `claude_code` | Backend per tier: `local`, `claude_code`, `off` |
| `STACK_SECRETARY_URL` / `STACK_SECRETARY_MODEL` | `https://chat.bobbymeyer.com/v1` / — | The local, OpenAI-compatible model |
| `STACK_JUDGE_URL` / `STACK_JUDGE_MODEL` / `STACK_JUDGE_THRESHOLD` | unset (off) / `jev-latest` / `0.8` | The OpenJev server beside the secretary, its model, and how sure an answer must be to count |
| `STACK_CLAUDE_BIN` / `STACK_CLAUDE_MODEL` | `claude` / CLI default | The claude CLI, and the model for the secretary's Claude runs |
| `STACK_AGENT_COMMAND` | `{claude} --resume {session_id} -p {instruction}` | How an instruction reaches a session; placeholders are substituted per argument, never through a shell |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | — | Gmail's OAuth client, if not entered on `/sources` |
| `STACK_REMINDERS_LIST` | `Stack` | Reminders list that lands whole (also on `/sources`) |
| `STACK_DIGEST_CARDS` | `daily,weekly,monthly` | Which digests become cards |
| `STACK_ACTIVE_MINUTES` | `30` | How recently you must have worked a card to count as still working |
| `STACK_NOTICER_THRESHOLD` | `3` | Repeats before the noticer offers a stamp |

## How it's built

- **Card**: position is height in the stack; new cards land on top and fall,
  and `Card.current` is the lowest live card that isn't blocked. State is
  `live`, `held` (waiting on a Trigger) or `handled`.
- **CardType** (`app/models/card_type.rb`): each type has its tool
  (`app/views/cards/types/_<name>.html.erb`) and carries out its actions
  (`perform`). A new source is a normalizer in `app/models/intake/` plus a card
  type.
- **Stamp**: a saved action with a template, successors and repeat.
- **Trigger**: wakes a held card at a time or on a matching event key.
- **Handling**: the log of every gesture, and of the secretary's own moves. The
  noticer and the digests read it.
- **Secretary** (`app/models/secretary.rb`): schemas and prompts per duty,
  routed to a backend by tier (`app/models/secretary/backends/`).
- Intake is one endpoint (`IntakeController`); pollers (`Gmail::Sync`,
  `MacCalendar::Sync`, `MacReminders::Sync`) feed the same `Intake.receive`.

## Known gaps

- `claude -p --resume` can't answer a permission prompt, and if the session is
  still open in a terminal it continues in a separate headless process. A tmux
  `send-keys` command via `STACK_AGENT_COMMAND` is the likely fix.
- No `claude agents --json` reconciliation yet: a card for a session you
  answered at the terminal stays until its next Stop.
- Gmail is polled, not pushed (push needs a public URL).
- Invitations can't be answered from onbox (Apple has no API for it).
- The secretary places a card when it arrives or when asked; it doesn't yet
  re-judge the whole order as things change.
- The noticer matches phrases exactly after normalizing, so it won't see that
  "PR and merge" and "open a PR then merge" are the same request.
- Not built: noticing when grooming time outruns handling time.
- The Judge reads only new cards' fronts. The noticer ("should I offer a
  stamp for this?") and the digests' "what needs you" don't ask it yet.

## Development

```sh
bin/rails test              # unit and integration
bin/rails test:system       # the phone flow in headless Chrome
bin/rubocop && bin/brakeman
```
