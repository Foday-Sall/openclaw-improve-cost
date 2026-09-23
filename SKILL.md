---
name: improve-cost
description: "Cut OpenClaw LLM spend: silent group-chat burn, unbounded main-session context, heartbeat context tax, GLM neuron/USD math, cache discipline, and the spawn-don't-grow pattern. Use when auditing token burn, tuning compaction thresholds, or before changing group/heartbeat settings."
---

# Improve Cost — stop silent token burn in OpenClaw

LLM bills are rarely eaten by the tasks you see. They are eaten by
**invisible context resend**: every model call re-sends the whole session
history, so cost grows with *session size × call count*, not with message
length. This skill codifies the four traps that produced a **$106 bill in 6
days** on a single OpenClaw instance (verified 2026-09-23 against
Cloudflare-reported per-call usage — see the audit note at the bottom) and
the fixes that hold.

## Step 0 — Measure first

Run the bundled checker (LLM-free, read-only):

```bash
bash scripts/cost-check.sh            # main session tokens + estimated $
bash scripts/cost-check.sh --all      # top sessions ranked by context size
```

**Done when:** you know which session carries the most context tokens and its
estimated USD at current model rates. Fix the biggest number first.

## Trap 1 — Group chats with `requireMention: false` (silent burn)

A wildcard channel rule like `"*": { requireMention: false }` makes **every**
group message wake the agent — even turns the agent answers with `NO_REPLY`
still pay a full model call on the group's context. Verified on WhatsApp:
a group the agent mostly ignored still burned ~$1.16 in 4 days, and the
wildcard caused every group message to create/wake a session.

Defense (both layers):

```json
channels.whatsapp.groupPolicy: "disabled"   // blocks group sessions entirely
```

- `groupPolicy: "disabled"` wins because **mention gating runs before session
  creation** — a gated-out message never creates a session or a model call.
- Per-group exceptions: add explicit per-group JID entries, **never** re-enable
  via the `"*": { requireMention: false }` wildcard.
- Same pattern applies to any channel where you did not intend full group
  participation (Telegram groups, Discord servers).

**Done when:** `config get channels.<channel>.groupPolicy` shows `disabled`
(or per-group requires are explicit) and group sessions stop appearing in
`sessions list` after group activity.

## Trap 2 — Big context window = billing trap (proactive compaction)

A huge model context window (GLM-5.3-flash: **1.31M tokens**) is a billing
trap, not a feature to fill. OpenClaw's auto-compaction triggers near
`contextTokenBudget − reserveTokens` (observed: 1,310,720 − 20,000 ≈
1.29M tokens). A session can grow for **days/weeks** before auto-compaction
ever fires. Verified: one main session ran 6 days, `compactionCount = 0`,
median per-call input **103k tokens**, p90 245k, max 395k — **$102 of a $106
bill**, with only ~37% of prompt tokens served from cache.

Why this hurts so much:

- Every call re-sends the entire history (tool loops multiply calls: 4,425
  assistant calls vs 1,335 user turns in the observed lineage).
- Uncached input is **5×** the cached rate; big evolving histories evict cache
  and push the mix toward misses.
- Rule of thumb at GLM-5.3-flash rates: **every 100k tokens of live context ≈
  $1.50–4 per 100 replies**.

Fixes, in order of preference:

1. **Byte-threshold preflight compaction** (config knob, survives restarts):
   ```bash
   openclaw config set agents.defaults.compaction.maxActiveTranscriptBytes 614400
   ```
   Triggers "normal preflight local compaction" when the transcript the model
   sees (since last compaction/reset) reaches ~600 KB. JSON-heavy transcripts
   run ~5–8 bytes/token, so 614400 ≈ **~75–120k tokens** — compacting long
   before 1.29M. `0`/unset disables (the default).
2. **Manual `/compact` at a low threshold** — after heavy multi-day chats,
   compact proactively instead of waiting; or start a `/new` session for a
   fresh topic entirely. A compaction event costs one summarization pass but
   repays it after ~a dozen subsequent calls.
3. Verify the trigger exists: `contextBudgetStatus.shouldCompact` flips true
   as `estimatedPromptTokens` approaches the budget (seen in
   `session_nodes.entry_json` in the agent DB).

**Done when:** `config get agents.defaults.compaction.maxActiveTranscriptBytes`
shows your value AND `cost-check.sh` shows the main session staying below
~120k tokens over days.

## Cache-hit strategy (short main session = high cache hit)

Cached input is $0.03/M vs $0.15/M uncached — **5× cheaper**. Cache hits
reward a *small, stable prefix*:

- **Keep the main session short.** Small history = small prefix = every call
  mostly hits cache. A 20k-token session is ~$0.001–0.003 per call; a 300k
  session is 15× that even with good caching.
- **Do heavy work in spawned child sessions** (see the pattern below) — they
  start fresh, finish, and never inflate the main prefix.
- **Don't grow main-session history**: no multi-day threads in main, no
  pasting big logs into main, no long tool loops in main. Move them out.
- Watch the hit rate: `cacheRead / (cacheRead + inputTokens)` from
  `cost-check.sh --all` per session. Observed failure mode: 37% hit rate on a
  6-day session vs near-100% on fresh short sessions.

**Done when:** main session stays small and its cache-hit ratio stays high.

## Trap 3 — Heartbeat cadence (the context tax rider)

Heartbeats **run inside the main session**, so every poll pays the session's
full context. Observed: 477 polls over 6 days at ~154k tokens average context
= **~$9.94 (~$1.65/day)** of pure idle cost — the #2 eater.

| Cadence | Polls/day | Cost/day @300k-token main session | Cost/day @20k-token main session |
|---|---|---|---|
| 30m (default) | 48 | ~$1.65 (observed) | ~$0.10 |
| 2h | 12 | ~$0.40 | ~$0.03 |
| off (`target: none` / disabled) | 0 | $0 | $0 |

Two independent levers, both valid: **lower the cadence** and/or **shrink the
session** (Trap 2). After compaction lands, even 30m heartbeats get cheap —
but on a fat session they compound the burn.

**Done when:** heartbeat cadence is a deliberate choice (`heartbeat` config or
per-automation `target`), not an accident, and its daily cost from
`cost-check.sh` deltas is known.

## Neuron cost math (GLM models on Cloudflare Workers AI)

Neurons are Cloudflare's compute currency: **$0.011 per 1,000 neurons**.
Pricing per **1M tokens** (source: `/ai/models/search`):

| Model | Uncached input | Cached input | Output | Neurons/M uncached | Neurons/M cached | Neurons/M output |
|---|---|---|---|---|---|---|
| glm-5.3-flash | $0.15 | $0.03 | $0.50 | 13,636 | 2,727 | 45,455 |
| glm-4.7-flash | $0.0605 | (not listed) | $0.40 | ~5,500 | — | ~36,364 |

Key semantics (pinned from data, not docs): the `input` usage field
**excludes** cached tokens. Billed neurons for a call:

```
neurons = input×13636 + cacheRead×2727 + output×45455   (per 1M)
USD     = neurons × 0.000011
```

**Estimate a session's $ from its token counters** (what `cost-check.sh`
does; counters live in the agent DB `session_nodes.entry_json`, same numbers
`/status`-style tooling surfaces):

```
USD = (inputTokens×0.15 + cacheRead×0.03 + outputTokens×0.50) / 1_000_000
```

Worked example (observed main lineage): 508M uncached + 284M cached in +
4.1M out → (508×0.15 + 284×0.03 + 4.1×0.5) ≈ **$86.80**. Whole instance over
6 days: 9.64M neurons ≈ **$106.03**.

Model choice: glm-4.7-flash is **2.5× cheaper on input** and would have cost
~$40 for the same 6 days — but it has a 128k window (compaction becomes
*mandatory*, which is fine) and no listed cached rate. For chat it wins; for
long tool-heavy sessions the 1.31M window of 5.3-flash avoids mid-work
compaction — paired with Trap 2's threshold so the window is never *filled*.

**Done when:** you can compute a session's USD from its counters in <1 minute
with `cost-check.sh`.

## Pattern — always spawn ordered agents for real tasks

The main session should **orchestrate, not labor**. Every token of heavy work
done in main becomes a permanent resend tax on every future call in that
session, including heartbeats.

- Heavy research, multi-file edits, audits, video/image pipelines, long tool
  loops → spawn a child session (`sessions_spawn`, `visible:true` when the
  user should see it) with a crisp objective and output location.
- Main receives only the **result summary** (a few hundred tokens), not the
  work transcript.
- Long-lived children repeat the main-session failure mode if they never end —
  prefer short-lived, single-objective children.
- Multi-day chat topics belong in fresh `/new` sessions, not appended to main.

**Done when:** main-session token count stays flat across a workday despite
real work happening (check with `cost-check.sh` deltas).

## Watchdog pattern (LLM-free, cheap)

A cron **command** job (no model calls) can police context growth:

```bash
openclaw automations add --name context-cost-watch --every 6h \
  --command "bash /path/to/your/workspace/scripts/cost-watch.sh" \
  --no-deliver
```

The script (`cost-watch.sh`, deployed in your workspace's `scripts/`
directory — not shipped in this repo because it embeds your Telegram chat id;
the pattern here is enough to write your own) reads the agent DB read-only,
appends a state-log line, and self-delivers a Telegram alert through
`/usr/bin/openclaw message send` when the main session crosses a token
threshold (the automation `--announce` path proved unreliable — scripts
should send themselves). Quiet hours (23:00–08:00 UTC) suppress alerts unless
critically oversized. On threshold trip it also writes an LLM-free state
summary to `memory/` so a subsequent `/compact` or `/new` loses nothing.

**Done when:** `openclaw automations runs <id>` shows exit-0 runs and the
state log grows every 6h.

## Case study (the $106 lesson, 2026-09-23)

| Eater | Cost share | Fix |
|---|---|---|
| Main session, 6 days, 0 compactions, ~300k-token context re-read per call | ~$102 (96%) | Byte-threshold compaction + /new per topic + spawn children |
| Heartbeat 30m riding that same context | ~$9.94 | Lower cadence and/or compact (either works; both better) |
| WhatsApp groups on wildcard `requireMention:false` | ~$1.16 | `groupPolicy: "disabled"` + per-group exceptions |
| Everything else (TTS, bots, embeddings, watcher crons) | < $0.10 | — |

Projection if unchanged: ~$100/week. With the fixes: ~$1–3/day, dominated by
actual use.
