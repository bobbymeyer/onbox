# The Stack

The world is concurrent; Bobby's attention is single-threaded. The Stack is the
serializer in between: everything pulling at him (Claude agents finishing, and
later email, calendar, a print completing) becomes one index card in front of him.

Rails 8, omakase: SQLite, Solid Queue / Cache / Cable, Hotwire, importmap, Propshaft.

## What's built (v1 plan steps 1–6)

| Step | Status |
|---|---|
| 1. Intake endpoint, Source and Card tables, phone dispenser | Done: `POST /intake`, dispenser at `/` |
| 2. Claude Code as first source (Stop + Notification hooks) | Done: `script/stack-hook`. `claude agents --json` reconciliation not yet |
| 3. Agent card type; handling sends the instruction back to the session | Done: `claude --resume <session> -p <instruction>` (configurable) |
| 4. Secretary v0: one LLM call at intake writes summary, ask, proposed action | Done: `Secretary.digest`, in a background job |
| 5. Stamps: table, tray, PR-and-merge first | Done, with successors and repeats |
| 6. Top-of-stack and later, with time triggers | Done, plus event triggers |
| 7. Email | Not started |
| 8. Maintenance view, decompose, noticer | Basic maintenance view only; no decompose or noticer yet |

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
- Not built yet: decompose, the noticer, the secretary reordering the stack,
  the secretary's periodic accounting, email, and calendar.

## Tests

```sh
bin/rails test && bin/rubocop && bin/brakeman
```
