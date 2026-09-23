# openclaw-improve-cost

An OpenClaw skill that stops **silent LLM token burn** — the invisible costs that don't come from the tasks you see, but from context being re-sent on every model call.

## The $106 lesson (real, verified 2026-09-23)

One OpenClaw instance on Cloudflare Workers AI (GLM-5.3-flash) burned **$106 in 6 days**. Where it went:

| Eater | Cost | Mechanism |
|---|---|---|
| One main chat session | **~$102 (96%)** | 6 days without compaction → every call re-read the whole ~300k-token history (median 103k, p90 245k tokens per call), only ~37% served from cache at 5× the price |
| Heartbeat every 30 min | ~$9.94 | Each poll runs *inside* the main session, paying its full context — ~$1.65/day of pure idle |
| WhatsApp groups on wildcard `requireMention: false` | ~$1.16 | Every group message woke the agent, even when it replied NO_REPLY |
| Everything else (TTS, bots, embeddings, cron watchers) | < $0.10 | — |

Numbers are Cloudflare-reported per-call usage, reconciled with the invoice within ~8%. A 1.31M-token context window is a **billing trap**: auto-compaction only fires near ~1.29M tokens, so a session can grow for days before it ever triggers. Rule of thumb at GLM rates: **every 100k tokens of live context ≈ $1.50–4 per 100 replies.**

Projection if unchanged: ~$100/week. With this skill's fixes: ~$1–3/day.

## What the skill covers

1. **The WhatsApp/group silent-burn trap** — why wildcard `requireMention: false` wakes the agent for every message, and why `groupPolicy: "disabled"` + explicit per-group entries is the defense (mention gating runs *before* session creation).
2. **The long-session context trap** — why huge model context windows bill like leaks, why proactive compaction at a *low* threshold beats waiting for auto-compaction, and the cache-hit strategy: keep the main session short and stable, spawn heavy work into child sessions.
3. **Heartbeat cadence trade-offs** — 30m vs 2h vs off, with the cost math for each at fat vs compact session sizes.
4. **Neuron cost math** — per-model tables for GLM-5.3-flash / GLM-4.7-flash, the neuron↔USD formula, and how to estimate a session's $ from its token counters.
5. **The spawn-don't-grow pattern** — always spawn ordered agents for real tasks; the main session orchestrates, it doesn't labor.

## What's inside

- `SKILL.md` — the full playbook (traps, fixes, math, verification criteria)
- `scripts/cost-check.sh` — LLM-free, read-only checker: prints each session's current context tokens, lifetime usage, cache-hit rate, and estimated USD straight from the agent's session store

```bash
bash scripts/cost-check.sh        # main session tokens + estimated $
bash scripts/cost-check.sh --all  # all sessions ranked by context size
```

A companion **watchdog** (`cost-watch.sh`) ships only in the source workspace — it embeds a Telegram chat id, so it is not published here. SKILL.md's "Watchdog pattern" section documents the full recipe (cron command job, 6h cadence, quiet hours, LLM-free state summaries) to write your own.

## Install

Via the OpenClaw CLI (git):

```bash
openclaw skills install git:https://github.com/Foday-Sall/openclaw-improve-cost
```

Or manually copy the folder into your workspace's skills directory:

```bash
git clone https://github.com/Foday-Sall/openclaw-improve-cost
cp -r openclaw-improve-cost <your-workspace>/skills/improve-cost
```

## Provenance

Built 2026-09-23 from a live audit of a production OpenClaw gateway. All dollar figures come from Cloudflare-reported per-call token usage stored by the gateway, reconciled against the provider invoice. No credentials, tokens, or account identifiers are included in this repo.
