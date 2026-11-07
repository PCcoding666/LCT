#!/usr/bin/env python3
"""
LCT engine comparison: same model weights, different inference runtimes.

Measures what a live caption translator actually feels: time to first token,
end-to-end time per utterance, generation speed, and whether the output is a
clean translation (no preamble, no echo, numbers and names kept, no invented
endings for half sentences).

Engines are given as  name=kind:target  where kind is
  ollama   target = model name            (uses http://localhost:11434/api/chat)
  openai   target = base_url|model        (any OpenAI-compatible server, e.g. llama-server)

Usage:
  python3 run_engine_compare.py \
      --engine ollama-mlx=ollama:qwen3.5:4b-mlx \
      --engine ollama-gguf=ollama:qwen3.5:4b \
      --engine llamacpp-gguf="openai:http://127.0.0.1:8089|qwen3.5-4b" \
      --runs 2 --output engine_compare_results.json --report engine_compare_report.md
"""
import argparse, json, math, re, statistics, sys, time, urllib.request
from collections import Counter
from datetime import datetime

OLLAMA_URL = "http://localhost:11434"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
TEMPERATURE = 0.3
NUM_CTX = 4096
MAX_TOKENS = 256
TARGET_NAMES = {"zh": "Chinese (Simplified)", "en": "English", "ja": "Japanese"}

VIOLATION_PATTERNS = [
    "好的", "当然", "以下是", "翻译如下", "翻译：", "Translation:", "Here is", "Sure", "Of course",
    "The translation", "译文：", "翻译结果", "I'll translate", "Let me translate", "```", "<think>",
    "[thinking]", "🔤", "Note:", "注：", "（注", "(Note",
]

# ─── engines ────────────────────────────────────────────────────────────────

def _post_stream(url, payload, headers=None):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})})
    return OPENER.open(req, timeout=180)

def call_ollama(model, messages):
    t0 = time.perf_counter(); ttft = None; text = []; final = {}
    resp = _post_stream(f"{OLLAMA_URL}/api/chat", {
        "model": model, "messages": messages, "stream": True, "think": False,
        "keep_alive": "10m",
        "options": {"temperature": TEMPERATURE, "num_ctx": NUM_CTX, "num_predict": MAX_TOKENS},
    })
    for line in resp:
        if not line.strip():
            continue
        chunk = json.loads(line)
        piece = chunk.get("message", {}).get("content", "")
        if piece and ttft is None:
            ttft = time.perf_counter() - t0
        text.append(piece)
        if chunk.get("done"):
            final = chunk
    e2e = time.perf_counter() - t0
    gen_tokens = final.get("eval_count") or len(text)
    prompt_ms = (final.get("prompt_eval_duration") or 0) / 1e6
    return {"text": "".join(text), "ttft_s": ttft or e2e, "e2e_s": e2e, "gen_tokens": gen_tokens,
            "prompt_tokens": final.get("prompt_eval_count"), "prompt_ms": prompt_ms or None}

def call_openai(base_url, model, messages):
    t0 = time.perf_counter(); ttft = None; text = []; usage = None; timings = None; n_chunks = 0
    resp = _post_stream(f"{base_url}/v1/chat/completions", {
        "model": model, "messages": messages, "stream": True, "temperature": TEMPERATURE,
        "max_tokens": MAX_TOKENS, "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    })
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        body = line[5:].strip()
        if body == "[DONE]":
            break
        chunk = json.loads(body)
        if chunk.get("usage"):
            usage = chunk["usage"]
        if chunk.get("timings"):
            timings = chunk["timings"]
        for choice in chunk.get("choices", []):
            piece = (choice.get("delta") or {}).get("content") or ""
            if piece:
                n_chunks += 1
                if ttft is None:
                    ttft = time.perf_counter() - t0
                text.append(piece)
    e2e = time.perf_counter() - t0
    gen_tokens = (usage or {}).get("completion_tokens") or (timings or {}).get("predicted_n") or n_chunks
    prompt_ms = (timings or {}).get("prompt_ms")
    return {"text": "".join(text), "ttft_s": ttft or e2e, "e2e_s": e2e, "gen_tokens": gen_tokens,
            "prompt_tokens": (usage or {}).get("prompt_tokens") or (timings or {}).get("prompt_n"),
            "prompt_ms": prompt_ms}

def make_engine(spec):
    name, _, rest = spec.partition("=")
    kind, _, target = rest.partition(":")
    if kind == "ollama":
        return name, (lambda msgs, m=target: call_ollama(m, msgs))
    if kind == "openai":
        base, _, model = target.partition("|")
        return name, (lambda msgs, b=base.rstrip("/"), m=model or "default": call_openai(b, m, msgs))
    raise SystemExit(f"unknown engine kind in {spec!r}")

# ─── scoring ────────────────────────────────────────────────────────────────

def clean(text):
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"<think>.*", "", text, flags=re.DOTALL)
    return text.replace("🔤", "").strip().strip('"').strip()

def cjk_ratio(s):
    letters = [c for c in s if c.isalpha()]
    if not letters:
        return 0.0
    return sum(1 for c in letters if "一" <= c <= "鿿") / len(letters)

def chrf(hyp, ref, n_max=4, beta=2.0):
    hyp = re.sub(r"\s+", "", hyp.lower()); ref = re.sub(r"\s+", "", ref.lower())
    if not hyp or not ref:
        return 0.0
    precs, recs = [], []
    for n in range(1, n_max + 1):
        h = Counter(hyp[i:i+n] for i in range(len(hyp) - n + 1))
        r = Counter(ref[i:i+n] for i in range(len(ref) - n + 1))
        if not h or not r:
            continue
        common = sum((h & r).values())
        precs.append(common / max(1, sum(h.values()))); recs.append(common / max(1, sum(r.values())))
    if not precs:
        return 0.0
    p, r = statistics.mean(precs), statistics.mean(recs)
    if p + r == 0:
        return 0.0
    return (1 + beta**2) * p * r / (beta**2 * p + r)

def score(case, direction, output):
    out = clean(output)
    problems = []
    low = out.lower()
    for pat in VIOLATION_PATTERNS:
        if pat.lower() in low:
            problems.append(f"preamble:{pat}"); break
    if len(case["input"]) >= 12 and case["input"].lower() in low:
        problems.append("echo")
    if "\n" in out.strip():
        problems.append("multiline")
    target = direction.split("->")[1]
    ratio = cjk_ratio(out)
    if target == "zh" and ratio < 0.3:
        problems.append("wrong-script")
    if target == "en" and ratio > 0.05:
        problems.append("wrong-script")
    ref = case.get("reference", "")
    max_ratio = case.get("max_ratio", 3.0)
    if ref and len(out) > max_ratio * max(len(ref), 6):
        problems.append("too-long")
    missing = []
    for t in case.get("terms", []):
        if t.lower() not in low:
            missing.append(t)
    for group in case.get("terms_any", []):
        if not any(t.lower() in low for t in group):
            missing.append("/".join(group))
    n_terms = len(case.get("terms", [])) + len(case.get("terms_any", []))
    return {
        "output": out, "compliant": not problems, "problems": problems,
        "terms_total": n_terms, "terms_kept": n_terms - len(missing), "terms_missing": missing,
        "chrf": round(chrf(out, ref), 3) if ref else None,
    }

# ─── run ────────────────────────────────────────────────────────────────────

def build_messages(system_prompt, direction, text, history):
    target = TARGET_NAMES[direction.split("->")[1]]
    msgs = [{"role": "system", "content": system_prompt.replace("{TARGET_LANGUAGE}", target)}]
    for src, out in history:
        msgs.append({"role": "user", "content": f"🔤{src}🔤"})
        msgs.append({"role": "assistant", "content": out})
    msgs.append({"role": "user", "content": f"🔤{text}🔤"})
    return msgs

def run_engine(name, call, data, categories, runs):
    results = []
    sp = data["system_prompt"]
    # warm-up (not recorded)
    for _ in range(2):
        call(build_messages(sp, "en->zh", "Let's begin.", []))
    for ckey in categories:
        cat = data["categories"][ckey]
        direction = cat["direction"]; use_ctx = cat.get("context", False)
        for run in range(runs):
            history = []
            for case in cat["cases"]:
                msgs = build_messages(sp, direction, case["input"], history[-2:] if use_ctx else [])
                try:
                    r = call(msgs)
                except Exception as e:  # noqa: BLE001
                    print(f"  {name} {case['id']} run{run}: ERROR {e}", file=sys.stderr)
                    continue
                s = score(case, direction, r["text"])
                gen_s = max(1e-6, r["e2e_s"] - r["ttft_s"])
                rec = {"engine": name, "category": ckey, "id": case["id"], "run": run,
                       "input": case["input"], "reference": case.get("reference"),
                       "ttft_ms": round(r["ttft_s"] * 1000), "e2e_ms": round(r["e2e_s"] * 1000),
                       "gen_tokens": r["gen_tokens"], "tps": round(r["gen_tokens"] / gen_s, 1) if r["gen_tokens"] else None,
                       "prompt_tokens": r["prompt_tokens"], "prompt_ms": round(r["prompt_ms"]) if r["prompt_ms"] else None,
                       **s}
                results.append(rec)
                if use_ctx:
                    history.append((case["input"], s["output"]))
                flag = "" if s["compliant"] and not s["terms_missing"] else f"  !! {s['problems']} missing={s['terms_missing']}"
                print(f"  {name} {case['id']} r{run}: ttft {rec['ttft_ms']}ms e2e {rec['e2e_ms']}ms | {s['output'][:60]}{flag}")
    return results

def pct(v, p):
    if not v:
        return float("nan")
    v = sorted(v); k = (len(v) - 1) * p / 100; f = math.floor(k); c = min(f + 1, len(v) - 1)
    return v[f] + (v[c] - v[f]) * (k - f)

def summarize(rows):
    ttft = [r["ttft_ms"] for r in rows]; e2e = [r["e2e_ms"] for r in rows]
    tps = [r["tps"] for r in rows if r["tps"]]
    chrfs = [r["chrf"] for r in rows if r["chrf"] is not None]
    tt = sum(r["terms_total"] for r in rows); tk = sum(r["terms_kept"] for r in rows)
    return {
        "n": len(rows),
        "ttft_avg": statistics.mean(ttft), "ttft_p50": pct(ttft, 50), "ttft_p95": pct(ttft, 95),
        "e2e_avg": statistics.mean(e2e), "e2e_p50": pct(e2e, 50), "e2e_p95": pct(e2e, 95),
        "tps_avg": statistics.mean(tps) if tps else float("nan"),
        "compliance": 100 * sum(r["compliant"] for r in rows) / len(rows),
        "terms": 100 * tk / tt if tt else float("nan"),
        "too_long": sum("too-long" in r["problems"] for r in rows),
        "chrf": 100 * statistics.mean(chrfs) if chrfs else float("nan"),
    }

def report(results, engines, data, args):
    lines = ["# LCT engine comparison: same weights, different runtimes", "",
             f"Generated {datetime.now():%Y-%m-%d %H:%M}. Eval set `{args.data}` "
             f"({sum(len(c['cases']) for c in data['categories'].values())} cases × {args.runs} runs), "
             f"temperature {TEMPERATURE}, num_ctx {NUM_CTX}, max_tokens {MAX_TOKENS}, thinking off, streaming; "
             "latency measured client-side from request start.", ""]
    if args.note:
        lines += [args.note, ""]
    lines += ["## Overall", "", "| Metric | " + " | ".join(engines) + " |", "|---|" + "---:|" * len(engines)]
    sums = {e: summarize([r for r in results if r["engine"] == e]) for e in engines}
    def row(label, key, fmt):
        lines.append(f"| {label} | " + " | ".join(fmt.format(sums[e][key]) for e in engines) + " |")
    row("Cases scored", "n", "{}")
    row("TTFT avg", "ttft_avg", "{:.0f} ms"); row("TTFT p50", "ttft_p50", "{:.0f} ms"); row("TTFT p95", "ttft_p95", "{:.0f} ms")
    row("End-to-end avg", "e2e_avg", "{:.0f} ms"); row("End-to-end p50", "e2e_p50", "{:.0f} ms"); row("End-to-end p95", "e2e_p95", "{:.0f} ms")
    row("Generation speed avg", "tps_avg", "{:.1f} tok/s")
    row("Instruction compliance", "compliance", "{:.0f}%"); row("Numbers / names kept", "terms", "{:.0f}%")
    row("Over-long outputs (drafts completed, commentary)", "too_long", "{}")
    row("chrF vs reference", "chrf", "{:.1f}")
    lines += ["", "## By category (end-to-end p50 / chrF)", "", "| Category | " + " | ".join(engines) + " |", "|---|" + "---:|" * len(engines)]
    for ckey, cat in data["categories"].items():
        cells = []
        for e in engines:
            rows = [r for r in results if r["engine"] == e and r["category"] == ckey]
            if not rows:
                cells.append("—"); continue
            s = summarize(rows); cells.append(f"{s['e2e_p50']:.0f} ms / {s['chrf']:.0f}")
        lines.append(f"| {ckey} — {cat['description']} | " + " | ".join(cells) + " |")
    lines += ["", "## Problems", ""]
    for e in engines:
        probs = Counter(p for r in results if r["engine"] == e for p in r["problems"])
        miss = [(r["id"], r["terms_missing"]) for r in results if r["engine"] == e and r["terms_missing"] and r["run"] == 0]
        lines.append(f"- **{e}**: " + (", ".join(f"{k} ×{v}" for k, v in probs.most_common()) or "none") +
                     (f"; missing terms (run 0): {miss}" if miss else ""))
    lines += ["", "## Side-by-side samples (run 0)", ""]
    sample_ids = ["B01", "B06", "C01", "D01", "D03", "D05", "G03", "G05", "H02", "F03"]
    for sid in sample_ids:
        rows = {r["engine"]: r for r in results if r["id"] == sid and r["run"] == 0}
        if not rows:
            continue
        any_row = next(iter(rows.values()))
        lines.append(f"**{sid}** `{any_row['input']}`  ")
        if any_row.get("reference"):
            lines.append(f"ref: {any_row['reference']}  ")
        for e in engines:
            if e in rows:
                lines.append(f"- {e} ({rows[e]['e2e_ms']} ms): {rows[e]['output']}")
        lines.append("")
    return "\n".join(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", action="append", default=[], help="name=ollama:model or name=openai:base_url|model")
    ap.add_argument("--report-only", action="store_true", help="rebuild the report from --output without running anything")
    ap.add_argument("--data", default="realtime_eval_set.json")
    ap.add_argument("--categories", nargs="*")
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--output", default="engine_compare_results.json")
    ap.add_argument("--report", default="engine_compare_report.md")
    ap.add_argument("--append", action="store_true", help="merge into an existing results file (re-run one engine)")
    ap.add_argument("--note", default="", help="free text placed at the top of the report (hardware, versions)")
    args = ap.parse_args()

    data = json.load(open(args.data))
    categories = args.categories or list(data["categories"])
    engines = []; results = []
    if args.append or args.report_only:
        try:
            results = json.load(open(args.output))["results"]
        except FileNotFoundError:
            pass
    if not args.engine and not args.report_only:
        ap.error("give at least one --engine, or --report-only")
    for spec in args.engine:
        name, call = make_engine(spec)
        print(f"=== {name} ===")
        results = [r for r in results if r["engine"] != name]
        results += run_engine(name, call, data, categories, args.runs)
        engines.append(name)
    all_engines = list(dict.fromkeys([r["engine"] for r in results]))
    json.dump({"generated": datetime.now().isoformat(), "config": vars(args), "results": results},
              open(args.output, "w"), ensure_ascii=False, indent=1)
    md = report(results, all_engines, data, args)
    open(args.report, "w").write(md)
    print(md)

if __name__ == "__main__":
    main()
