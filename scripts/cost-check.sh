#!/usr/bin/env bash
# cost-check.sh — print OpenClaw session token counts + estimated USD (LLM-free, read-only).
# Reads the agent's session store SQLite directly (same numbers Cloudflare bills on).
# Usage:
#   bash cost-check.sh                 # main session of default agent
#   bash cost-check.sh --agent main    # explicit agent id
#   bash cost-check.sh --session 'agent:main:main'
#   bash cost-check.sh --all           # top sessions ranked by context size
# Pricing table: GLM-5.3-flash $0.15/M uncached in, $0.03/M cached in, $0.50/M out.
set -euo pipefail

AGENT="main"
SESSION_KEY=""
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --session) SESSION_KEY="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

DB=""
for c in /root/.openclaw/agents/*/; do
  id=$(basename "$c")
  [ "$id" = "$AGENT" ] && DB="$c/agent/openclaw-agent.sqlite"
done
[ -z "$DB" ] && { echo "agent '$AGENT' not found under /root/.openclaw/agents/" >&2; exit 2; }
[ -f "$DB" ] || { echo "no agent DB at $DB" >&2; exit 2; }

# GLM-5.3-flash list rates (USD per 1M tokens). Update here when models change.
PIN=0.15; PCACHE=0.03; POUT=0.50

python3 - "$DB" "$SESSION_KEY" "$ALL" "$PIN" "$PCACHE" "$POUT" <<'EOF'
import sqlite3, json, sys, time
db, session_key, all_flag, pin, pcache, pout = sys.argv[1], sys.argv[2], sys.argv[3] == "1", float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
cur = con.cursor()

def usd(inp, cach, out):
    return (inp * pin + cach * pcache + out * pout) / 1e6

def fmt_row(key, e):
    tot = e.get("totalTokens") or 0
    est = ((e.get("contextBudgetStatus") or {}).get("estimatedPromptTokens")) or tot
    inp, cach, out = e.get("inputTokens") or 0, e.get("cacheRead") or 0, e.get("outputTokens") or 0
    cost = usd(inp, cach, out)
    hit = (cach / (cach + inp) * 100) if (cach + inp) else 0.0
    upd = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime((e.get("updatedAt") or 0) / 1000))
    return (f"{key}\n  label={e.get('label')!r} status={e.get('status')!r} model={e.get('model')} updated={upd}\n"
            f"  context_tokens_now(est)={est:,} totalTokens={tot:,} compactions={e.get('compactionCount', 0)}\n"
            f"  lifetime: uncached_in={inp:,} cached_in={cach:,} out={out:,} cache_hit={hit:.0f}%\n"
            f"  est_cost_lifecycle=${cost:.2f} (at ${pin}/{pcache}/{pout} per M in/cached/out)")

rows = cur.execute("SELECT session_key, entry_json FROM session_nodes ORDER BY updated_at DESC").fetchall()
parsed = []
for key, raw in rows:
    try:
        e = json.loads(raw)
    except Exception:
        continue
    parsed.append((key, e))

if all_flag:
    ranked = sorted(parsed, key=lambda ke: ((ke[1].get("contextBudgetStatus") or {}).get("estimatedPromptTokens") or ke[1].get("totalTokens") or 0), reverse=True)
    print(f"== top sessions by current context tokens (db: {db}) ==")
    for key, e in ranked[:10]:
        print(fmt_row(key, e))
else:
    target = session_key or f"agent:{'main'}:main"
    match = next(((k, e) for k, e in parsed if k == target), None)
    if not match:
        cands = [k for k, _ in parsed if k.startswith("agent:")]
        print(f"session '{target}' not found. Known keys:\n  " + "\n  ".join(cands[:20]))
        sys.exit(1)
    print(fmt_row(*match))
EOF
