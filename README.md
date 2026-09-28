# The Stack

The world is concurrent; Bobby's attention is single-threaded. The Stack is the
serializer in between: everything pulling at him (Claude agents finishing, and
email, and later calendar and a print completing) becomes one index card in front of him.

Rails 8, omakase: SQLite, Solid Queue / Cache / Cable, Hotwire, importmap, Propshaft.

## What's built (v1 plan steps 1–7)

| Step | Status |
|---|---|
| 1. Intake endpoint, Source and Card tables, phone dispenser | Done: `POST /intake`, dispenser at `/` |
| 2. Claude Code as first source (Stop + Notification hooks) | Done: `script/stack-hook`. `claude agents --json` reconciliation not yet |
| 3. Agent card type; handling sends the instruction back to the session | Done: `claude --resume <session> -p <instruction>` (configurable) |
| 4. Secretary v0: one LLM call at intake writes summary, ask, proposed action | Done: `Secretary.digest`, in a background job |
| 5. Stamps: table, tray, PR-and-merge first | Done, with successors and repeats |
| 6. Top-of-stack and later, with time triggers | Done, plus event triggers |
| 7. Email as the second source and card type | Done: Gmail API polling, reply in thread, archive |
| 8. Maintenance view, decompose, noticer | Maintenance view and decompose done; noticer not started |

## The model

- **Card**: position is height in the stack. New cards land on top and fall;
  `Card.current` is the lowest live card that isn't blocked. State is `live`,
  `held` (waiting on a trigger) or `handled`.
- **Stamp**: a saved action. `action.kind` is `instruct` (send to the agent),
  `reply`, or `handle` (just close it). `successors` are the cards it seeds,
  chained so each waits on the one before it (`"parallel": true` opts out).
  `action.repeat` (e.g. `"1 week"`) re-seeds the card, held until the next interval.
  `requires_flip` keeps the stamp disabled until the card has been flipped.
- **Trigger**: wakes a held card at a time, or when an incoming event carries a
  matching key (`<source name>`, `<source name>:<event>`, `claude_code:stop:<project>`).
- **Handling**: the event log of every gesture (stamp, reply, top_of_stack,
  later, flip, release). The noticer and the secretary's accounting will read this.
- **CardType** (`app/models/card_type.rb`): each type knows its inline tool
  (`app/views/cards/types/_<name>.html.erb`) and how to deliver a reply. Add a
  source by adding a card type.

## Maintenance mode (`/stack`)

The whole stack, front first. Per card: move up or down, to front, to top,
decompose, edit. Tick cards for bulk actions from the bar at the bottom: later
(one time for all), to front (keeping their order), to top, re-tag project,
release, done, delete (asks first).

**Talk to the secretary.** Ask why something sits where it does, or tell it
to change things. It can move, hold, release and re-tag cards, and save or drop
standing instructions; it cannot delete, handle or send anything, and every
change it makes is listed under its reply. **Standing instructions** ("Hold
receipts until 18:00") go into every digest, which can now also put a new card
straight to the front or hold it.

**Decompose** (on every card, and from the list) breaks a card into
single-action cards. The secretary drafts the steps (a clarifying question
first when the card is vague) and you edit them before anything is created.
Each step waits on the one before it; the first goes to the front and the rest
land on top and fall, so steps spread through the stack by dependency. Steps
keep the original card's type and context, so an agent step's instruction still
goes to that session.

## Running it on the Mac Studio

```sh
bin/setup --skip-server
bin/rails db:seed          # prints the claude-code source token
bin/dev                    # or: RAILS_ENV=production bin/rails server
```

Open `http://<mac-studio>.<tailnet>.ts.net:3000` on the phone. Add it to the
home screen for full screen.

### Environment

| Variable | Default | What it does |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Secretary's credentials. Without them, cards keep the intake's plain front |
| `STACK_SECRETARY` | on | `off` disables the LLM entirely |
| `STACK_SECRETARY_MODEL` | `claude-opus-5-5` | Model for digests and deferrals |
| `STACK_TIME_ZONE` | `UTC` | Where "tonight" and "tomorrow" resolve. Set this, e.g. `Pacific Time (US & Canada)` |
| `STACK_AGENT_COMMAND` | `claude --resume {session_id} -p {instruction}` | How an instruction reaches a session. `{session_id}`, `{instruction}`, `{cwd}` are substituted per argument (no shell). Runs in the session's cwd |
| `STACK_PASSWORD` / `STACK_USER` | unset / `bobby` | Optional HTTP basic auth on the views. Tailscale is the main perimeter |
| `GMAIL_CLIENT_ID` / `GMAIL_CLIENT_SECRET` | — | OAuth client for the email source (see below) |

The secretary calls the API with server-side refusal fallbacks enabled
(`fallbacks: :default`), so a declined request is retried on another model
instead of failing the digest. Remove it in `app/models/secretary.rb` if you don't want it.

Held cards wake when a page loads, and every minute through the Solid Queue
recurring job (`config/recurring.yml`, production).

### Wiring Claude Code

Add the hooks to `~/.claude/settings.json` (see `script/claude-settings.example.json`):

```json
{
  "env": { "STACK_URL": "http://mac-studio:3000", "STACK_TOKEN": "<claude-code token>" },
  "hooks": {
    "Stop":         [{ "hooks": [{ "type": "command", "command": "/path/to/onbox/script/stack-hook" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "/path/to/onbox/script/stack-hook" }] }]
  }
}
```

The hook sends its JSON input untouched and never blocks or fails the agent's
turn. `session_id` is the card's key, so a session holds one open card at a
time; a new Stop refreshes it and puts it back on top. When the hook input has
no last assistant message, the intake reads it from `transcript_path`, which
works because the server and the agents share a machine.

When you send an instruction, the next Stop hook brings the result back as a
fresh card. If the send fails, the failure comes back as a card.

### Wiring Gmail

Email cards come from polling Gmail every two minutes. Each thread holds one
open card: sender and subject on the front, the secretary's drafted reply as
the proposed action, the full message on the back. **Send reply** (or the
**Approve** stamp) replies in the thread; the **Archive** stamp archives it.

One-time setup:

1. In Google Cloud Console, create a project, enable the **Gmail API**, and
   create an OAuth client of type **Desktop app**. If the consent screen is in
   testing mode, add your address as a test user. (Testing-mode refresh tokens
   expire after 7 days; publish the app, still unverified, to keep them.)
2. Export `GMAIL_CLIENT_ID` and `GMAIL_CLIENT_SECRET` for the Rails process.
3. On the Mac: `bin/rails gmail:connect[gmail]`. Open the printed URL, approve,
   and paste back the `localhost` URL the browser lands on (the page itself
   won't load; the code is in the address).

The scope is `gmail.modify` (read, send, label and archive; no permanent delete). The refresh token
is stored encrypted in the `sources` table. Which mail becomes a card is a
Gmail search, `in:inbox category:primary` by default, editable on `/sources`,
where **Check now** also polls on demand. Each poll takes at most 25 messages,
and the first one looks back one day.

Mail from someone emits the event `gmail:from:<address>`, so a card can be held
until they write back: on an email card, **Later** with "until Ada replies" is
resolved by the secretary to that event key.

Other mail bridges can POST the same shape to `/intake` on an email source:
`thread_id`, `message_id`, `from`, `reply_to`, `subject`, `body`,
`rfc822_message_id`, `references`.

### Other sources

Create a `generic` source at `/sources` and POST JSON:

```sh
curl -X POST "$STACK_URL/intake" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"summary":"Print finished","project":"shop","ask":"acknowledge","event":"print.done"}'
```

Fields: `summary`, `project`, `ask` (decision / reply / review / acknowledge),
`proposed_action`, `body`, `key` (dedupes open cards), `event` (wakes cards
held on `<source>:<event>`). Senders that can't set headers can pass `?token=`.

## Known gaps

- `claude -p --resume` can't answer a permission prompt. A Notification card
  asking for permission can only be handled by instruction or by going to the
  terminal. A tmux `send-keys` command is the likely fix
  (`STACK_AGENT_COMMAND="tmux send-keys -t {session_id} {instruction} Enter"`
  with sessions named to match).
- If the interactive session is still open in a terminal, `--resume` continues
  it in a separate headless process.
- There is no `claude agents --json` reconciliation yet, so a card for a session
  you already answered at the terminal stays until its next Stop refreshes it.
- Email is polled, not pushed. Gmail push via Pub/Sub needs a public URL
  (e.g. Tailscale Funnel); when there is one, the push endpoint can call the
  same `Gmail::Sync`.
- Sending a reply is one tap. If that proves too easy for an irreversible
  action, the per-stamp `requires_flip` flag is the lever.
- The secretary only places a card when it arrives (or when asked); it doesn't
  yet re-judge the whole order as things change.
- Not built yet: the noticer, the secretary's periodic accounting, noticing
  when grooming time outruns handling time, and calendar.

## Tests

```sh
bin/rails test && bin/rubocop && bin/brakeman
```
