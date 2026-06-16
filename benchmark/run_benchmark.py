#!/usr/bin/env python3
"""
LCT Translation Benchmark v1.0
================================
专为 LCT (LiveCaptions Translator) 项目设计的本地翻译模型性能测试工具。
模拟真实同声传译场景，覆盖：短句、中句、长段落、不完整片段、技术术语、
上下文连贯性、反向翻译、多语言、指令遵循等维度。

测试指标：
  - TTFT (Time To First Token): 首字延迟
  - TPS (Tokens Per Second): 生成速度
  - Prompt Eval Speed: 输入处理速度
  - Total Latency: 端到端总耗时
  - Instruction Compliance: 指令遵循率
  - Term Preservation: 专有名词保留率

Usage:
  python3 run_benchmark.py
  python3 run_benchmark.py --models qwen3.5:4b-mlx qwen3:4b-instruct-2507-q4_K_M
  python3 run_benchmark.py --categories A B E --runs 5
  python3 run_benchmark.py --output results.json
"""

import urllib.request
import json
import time
import sys
import os
import argparse
import statistics
from datetime import datetime

# ─── Configuration ───────────────────────────────────────────────────────────

OLLAMA_BASE_URL = "http://localhost:11434"
OLLAMA_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

DEFAULT_MODELS = [
    "qwen3.5:4b-mlx",
    "qwen3:4b-instruct-2507-q4_K_M",
]

TEMPERATURE = 0.3
KEEP_ALIVE = "5m"

# 指令遵循检测：如果翻译结果包含这些前缀，说明模型没有严格遵循指令
INSTRUCTION_VIOLATION_PATTERNS = [
    "好的", "当然", "以下是", "翻译如下", "翻译：", "Translation:",
    "Here is", "Sure", "Of course", "The translation",
    "译文：", "翻译结果", "I'll translate", "Let me translate",
    "```", "<think>", "[thinking]", "🔤",
]

# ─── Ollama API Calls ────────────────────────────────────────────────────────

def ollama_chat(model: str, messages: list, stream: bool = False) -> dict | None:
    """Call Ollama /api/chat endpoint."""
    url = f"{OLLAMA_BASE_URL}/api/chat"
    payload = {
        "model": model,
        "messages": messages,
        "stream": stream,
        "temperature": TEMPERATURE,
        "keep_alive": KEEP_ALIVE,
        "think": False,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with OLLAMA_OPENER.open(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"    ❌ API Error ({model}): {e}")
        return None


def ollama_chat_streaming(model: str, messages: list) -> dict | None:
    """Call Ollama /api/chat with streaming to measure real TTFT."""
    url = f"{OLLAMA_BASE_URL}/api/chat"
    payload = {
        "model": model,
        "messages": messages,
        "stream": True,
        "temperature": TEMPERATURE,
        "keep_alive": KEEP_ALIVE,
        "think": False,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        t_start = time.perf_counter()
        t_first_token = None
        full_response = ""
        total_eval_count = 0
        final_chunk = {}

        with OLLAMA_OPENER.open(req, timeout=120) as resp:
            for line in resp:
                chunk = json.loads(line.decode("utf-8"))
                content = chunk.get("message", {}).get("content", "")
                if content and t_first_token is None:
                    t_first_token = time.perf_counter()
                full_response += content
                if chunk.get("done", False):
                    final_chunk = chunk

        t_end = time.perf_counter()

        return {
            "response": full_response,
            "ttft_real": (t_first_token - t_start) if t_first_token else None,
            "total_real": t_end - t_start,
            "eval_count": final_chunk.get("eval_count", 0),
            "eval_duration": final_chunk.get("eval_duration", 0),
            "prompt_eval_count": final_chunk.get("prompt_eval_count", 0),
            "prompt_eval_duration": final_chunk.get("prompt_eval_duration", 0),
            "load_duration": final_chunk.get("load_duration", 0),
        }
    except Exception as e:
        print(f"    ❌ Streaming API Error ({model}): {e}")
        return None


def warmup_model(model: str):
    """Pre-load model into memory."""
    print(f"  ⏳ 预热模型（加载到内存）...")
    t0 = time.perf_counter()
    ollama_chat(model, [{"role": "user", "content": "hi"}])
    # Send a second warmup to ensure JIT caches are populated for MLX
    ollama_chat(model, [{"role": "user", "content": "hello"}])
    t1 = time.perf_counter()
    print(f"  ✅ 模型已就绪 (预热耗时: {t1 - t0:.1f}s)")


# ─── Test Data Loading ───────────────────────────────────────────────────────

def load_test_data(filepath: str) -> dict:
    """Load test cases from JSON file."""
    with open(filepath, "r", encoding="utf-8") as f:
        return json.load(f)


def build_messages(system_prompt: str, text: str, target_lang: str,
                   context_history: list | None = None) -> list:
    """Build the chat message array matching LCT's real format."""
    prompt = system_prompt.replace("{TARGET_LANGUAGE}", target_lang)
    messages = [{"role": "system", "content": prompt}]

    if context_history:
        for ctx in context_history:
            messages.append({"role": "user", "content": ctx["user"]})
            messages.append({"role": "assistant", "content": ctx["assistant"]})

    messages.append({"role": "user", "content": f"🔤 {text} 🔤"})
    return messages


# ─── Quality Checks ─────────────────────────────────────────────────────────

def clean_response(text: str) -> str:
    """Clean model response the same way LCT does."""
    import re
    # Remove think tags
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"\[thinking\].*?\[/thinking\]", "", text, flags=re.DOTALL)
    # Remove 🔤 markers
    text = text.replace("🔤", "")
    # Remove common prefixes
    for prefix in ["Translation:", "翻译：", "译文：", "Here is the translation:",
                   "Here's the translation:", "翻译结果："]:
        if text.strip().startswith(prefix):
            text = text.strip()[len(prefix):]
    return text.strip()


def check_instruction_compliance(response: str) -> tuple[bool, str | None]:
    """Check if the model strictly followed instructions (no extra chatter)."""
    raw = response.strip()
    for pattern in INSTRUCTION_VIOLATION_PATTERNS:
        if raw.startswith(pattern):
            return False, f"包含违规前缀: '{pattern}...'"
    # Check for multi-line output (should be single line)
    lines = [l for l in raw.split("\n") if l.strip()]
    if len(lines) > 2:
        return False, f"输出了 {len(lines)} 行（应为单行）"
    return True, None


def check_term_preservation(response: str, terms: list[str]) -> tuple[int, int, list[str]]:
    """Check how many technical terms were preserved in the translation."""
    preserved = 0
    missing = []
    for term in terms:
        if term.lower() in response.lower():
            preserved += 1
        else:
            missing.append(term)
    return preserved, len(terms), missing


# ─── Core Benchmark Runner ───────────────────────────────────────────────────

def run_single_case(model: str, messages: list, case: dict,
                    run_idx: int) -> dict | None:
    """Run a single test case and collect all metrics."""
    result = ollama_chat_streaming(model, messages)
    if not result:
        return None

    response_raw = result["response"]
    response_clean = clean_response(response_raw)

    # --- Performance metrics ---
    ttft = result["ttft_real"]
    total_time = result["total_real"]
    eval_count = result["eval_count"]
    eval_duration_s = result["eval_duration"] / 1e9 if result["eval_duration"] else 0
    prompt_eval_count = result["prompt_eval_count"]
    prompt_eval_duration_s = result["prompt_eval_duration"] / 1e9 if result["prompt_eval_duration"] else 0

    tps = eval_count / eval_duration_s if eval_duration_s > 0 else 0
    prompt_tps = prompt_eval_count / prompt_eval_duration_s if prompt_eval_duration_s > 0 else 0

    # --- Quality metrics ---
    compliant, violation = check_instruction_compliance(response_raw)

    term_preserved = term_total = 0
    missing_terms = []
    if "preserve_terms" in case:
        term_preserved, term_total, missing_terms = check_term_preservation(
            response_clean, case["preserve_terms"]
        )

    return {
        "case_id": case["id"],
        "run": run_idx,
        "input": case["input"],
        "output_raw": response_raw,
        "output_clean": response_clean,
        "reference": case.get("reference", ""),
        # Performance
        "ttft_s": round(ttft, 4) if ttft else None,
        "total_s": round(total_time, 4),
        "tps": round(tps, 2),
        "prompt_tps": round(prompt_tps, 2),
        "eval_tokens": eval_count,
        "prompt_tokens": prompt_eval_count,
        # Quality
        "instruction_compliant": compliant,
        "violation_detail": violation,
        "term_preserved": term_preserved,
        "term_total": term_total,
        "missing_terms": missing_terms,
    }


def run_category(model: str, category_key: str, category: dict,
                 system_prompt: str, num_runs: int) -> list[dict]:
    """Run all test cases in a category."""
    direction = category.get("direction", "en->zh")
    _, target = direction.split("->")
    target_lang_map = {
        "zh": "Chinese", "en": "English", "ja": "Japanese",
        "ko": "Korean", "es": "Spanish", "fr": "French",
        "de": "German", "ru": "Russian",
    }
    target_lang = target_lang_map.get(target, "Chinese")

    context_history = category.get("context_history", None)
    results = []

    desc = category.get("description", "")
    print(f"\n  📋 类别 {category_key}: {desc}")
    print(f"     方向: {direction} | 用例数: {len(category['cases'])} | 重复: {num_runs}次")

    for case in category["cases"]:
        messages = build_messages(system_prompt, case["input"], target_lang, context_history)

        for run_idx in range(1, num_runs + 1):
            r = run_single_case(model, messages, case, run_idx)
            if r:
                r["category"] = category_key
                r["direction"] = direction
                results.append(r)

                # Print concise progress
                status = "✅" if r["instruction_compliant"] else "⚠️"
                ttft_str = f"{r['ttft_s']*1000:.0f}ms" if r["ttft_s"] else "N/A"
                print(f"     {status} {r['case_id']}(run{run_idx}): "
                      f"TTFT={ttft_str} | TPS={r['tps']:.1f} | "
                      f"Total={r['total_s']:.2f}s | "
                      f"「{r['output_clean'][:40]}{'...' if len(r['output_clean'])>40 else ''}」")

    return results


# ─── Report Generation ───────────────────────────────────────────────────────

def generate_report(all_results: dict[str, list[dict]]) -> str:
    """Generate a comprehensive markdown report."""
    lines = []
    lines.append("# 🏆 LCT Translation Benchmark Report")
    lines.append(f"**生成时间**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")

    # ── Per-model summary ──
    model_summaries = {}

    for model, results in all_results.items():
        if not results:
            continue

        ttfts = [r["ttft_s"] * 1000 for r in results if r["ttft_s"] is not None]
        tpss = [r["tps"] for r in results if r["tps"] > 0]
        totals = [r["total_s"] for r in results]
        compliant_count = sum(1 for r in results if r["instruction_compliant"])
        total_terms = sum(r["term_total"] for r in results)
        preserved_terms = sum(r["term_preserved"] for r in results)

        model_summaries[model] = {
            "ttft_avg": statistics.mean(ttfts) if ttfts else 0,
            "ttft_p50": statistics.median(ttfts) if ttfts else 0,
            "ttft_p95": sorted(ttfts)[int(len(ttfts) * 0.95)] if ttfts else 0,
            "ttft_min": min(ttfts) if ttfts else 0,
            "ttft_max": max(ttfts) if ttfts else 0,
            "tps_avg": statistics.mean(tpss) if tpss else 0,
            "tps_min": min(tpss) if tpss else 0,
            "tps_max": max(tpss) if tpss else 0,
            "total_avg": statistics.mean(totals),
            "total_p50": statistics.median(totals),
            "total_p95": sorted(totals)[int(len(totals) * 0.95)],
            "compliance_rate": compliant_count / len(results) * 100,
            "compliance_detail": f"{compliant_count}/{len(results)}",
            "term_rate": preserved_terms / total_terms * 100 if total_terms > 0 else 100,
            "term_detail": f"{preserved_terms}/{total_terms}",
            "total_cases": len(results),
        }

    # ── Overall comparison table ──
    lines.append("## 📊 总体对比")
    lines.append("")
    lines.append("| 指标 | " + " | ".join(all_results.keys()) + " |")
    lines.append("| :--- | " + " | ".join(["---:" for _ in all_results]) + " |")

    metrics = [
        ("首字延迟 (TTFT) 平均", "ttft_avg", "ms", "{:.0f}ms"),
        ("首字延迟 (TTFT) P50", "ttft_p50", "ms", "{:.0f}ms"),
        ("首字延迟 (TTFT) P95", "ttft_p95", "ms", "{:.0f}ms"),
        ("生成速度 (TPS) 平均", "tps_avg", "", "{:.1f} t/s"),
        ("生成速度 (TPS) 最低", "tps_min", "", "{:.1f} t/s"),
        ("端到端耗时 平均", "total_avg", "s", "{:.2f}s"),
        ("端到端耗时 P50", "total_p50", "s", "{:.2f}s"),
        ("端到端耗时 P95", "total_p95", "s", "{:.2f}s"),
        ("指令遵循率", "compliance_rate", "%", "{:.0f}%"),
        ("专有名词保留率", "term_rate", "%", "{:.0f}%"),
    ]

    for label, key, _, fmt in metrics:
        row = f"| **{label}** |"
        vals = []
        for model in all_results:
            s = model_summaries.get(model, {})
            val = s.get(key, 0)
            vals.append(val)
            row += f" {fmt.format(val)} |"
        lines.append(row)

    lines.append("")

    # ── Per-category breakdown ──
    lines.append("## 📋 分类别详细数据")

    categories_seen = []
    for results in all_results.values():
        for r in results:
            if r["category"] not in categories_seen:
                categories_seen.append(r["category"])

    for cat in categories_seen:
        lines.append(f"\n### 类别 {cat}")
        lines.append("")
        lines.append("| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |")
        lines.append("| :--- | ---: | ---: | ---: | ---: |")

        for model, results in all_results.items():
            cat_results = [r for r in results if r["category"] == cat]
            if not cat_results:
                continue
            ttfts = [r["ttft_s"] * 1000 for r in cat_results if r["ttft_s"]]
            tpss = [r["tps"] for r in cat_results if r["tps"] > 0]
            totals = [r["total_s"] for r in cat_results]
            comp = sum(1 for r in cat_results if r["instruction_compliant"])
            lines.append(
                f"| {model} | "
                f"{statistics.mean(ttfts):.0f}ms | "
                f"{statistics.mean(tpss):.1f} t/s | "
                f"{statistics.mean(totals):.2f}s | "
                f"{comp}/{len(cat_results)} |"
            )

    # ── Instruction violations ──
    violations = []
    for model, results in all_results.items():
        for r in results:
            if not r["instruction_compliant"]:
                violations.append((model, r))

    if violations:
        lines.append("\n## ⚠️ 指令违规详情")
        lines.append("")
        lines.append("| 模型 | 用例 | 违规原因 | 模型原始输出 |")
        lines.append("| :--- | :--- | :--- | :--- |")
        for model, r in violations:
            output_preview = r["output_raw"][:60].replace("\n", "↵").replace("|", "\\|")
            lines.append(
                f"| {model} | {r['case_id']} | {r['violation_detail']} | `{output_preview}` |"
            )

    # ── Missing terms ──
    term_issues = []
    for model, results in all_results.items():
        for r in results:
            if r["missing_terms"]:
                term_issues.append((model, r))

    if term_issues:
        lines.append("\n## 🔍 专有名词丢失详情")
        lines.append("")
        lines.append("| 模型 | 用例 | 丢失的术语 | 模型输出 |")
        lines.append("| :--- | :--- | :--- | :--- |")
        for model, r in term_issues:
            output_preview = r["output_clean"][:60].replace("|", "\\|")
            lines.append(
                f"| {model} | {r['case_id']} | {', '.join(r['missing_terms'])} | `{output_preview}` |"
            )

    # ── Translation samples ──
    lines.append("\n## 📝 翻译样本对比")
    lines.append("")

    sample_ids = ["A01", "B02", "D03", "E01", "F01", "I05"]
    for sid in sample_ids:
        lines.append(f"\n#### 用例 {sid}")
        for model, results in all_results.items():
            for r in results:
                if r["case_id"] == sid and r["run"] == 1:
                    lines.append(f"- **原文**: {r['input']}")
                    lines.append(f"- **参考**: {r['reference']}")
                    break
            for r in results:
                if r["case_id"] == sid and r["run"] == 1:
                    lines.append(f"- **{model}**: {r['output_clean']}")
                    break
        lines.append("")

    return "\n".join(lines)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="LCT Translation Benchmark")
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS,
                        help="Models to benchmark")
    parser.add_argument("--categories", nargs="+", default=None,
                        help="Category prefixes to run (e.g., A B E). Default: all")
    parser.add_argument("--runs", type=int, default=3,
                        help="Number of repetitions per test case (default: 3)")
    parser.add_argument("--data", type=str,
                        default=os.path.join(os.path.dirname(__file__), "test_data.json"),
                        help="Path to test data JSON file")
    parser.add_argument("--output", type=str, default=None,
                        help="Path to save raw results JSON")
    parser.add_argument("--report", type=str, default=None,
                        help="Path to save markdown report")
    args = parser.parse_args()

    # Load test data
    print("=" * 60)
    print("  LCT Translation Benchmark v1.0")
    print("=" * 60)
    print(f"\n📂 加载测试数据: {args.data}")
    data = load_test_data(args.data)
    system_prompt = data["system_prompt"]
    test_cases = data["test_cases"]

    # Filter categories if specified
    if args.categories:
        filtered = {}
        for key, val in test_cases.items():
            prefix = key.split("_")[0]
            if prefix in args.categories:
                filtered[key] = val
        test_cases = filtered

    total_cases = sum(len(cat["cases"]) for cat in test_cases.values())
    print(f"📊 测试类别: {len(test_cases)} 个")
    print(f"📝 测试用例: {total_cases} 个 × {args.runs} 次 = {total_cases * args.runs} 次调用")
    print(f"🤖 测试模型: {', '.join(args.models)}")
    print(f"   总调用次数: {total_cases * args.runs * len(args.models)} 次")
    print(f"   (预计耗时取决于模型加载和每次调用延迟)\n")

    # Check Ollama connectivity
    try:
        req = urllib.request.Request(f"{OLLAMA_BASE_URL}/api/tags")
        with OLLAMA_OPENER.open(req, timeout=5) as resp:
            tags = json.loads(resp.read().decode("utf-8"))
            available = [m["name"] for m in tags.get("models", [])]
            print(f"✅ Ollama 已连接，可用模型: {', '.join(available)}")
    except Exception as e:
        print(f"❌ 无法连接 Ollama ({OLLAMA_BASE_URL}): {e}")
        sys.exit(1)

    # Verify requested models exist
    for model in args.models:
        if model not in available:
            print(f"⚠️  警告: 模型 '{model}' 不在 Ollama 已安装列表中")

    # Run benchmarks
    all_results = {}

    for model_idx, model in enumerate(args.models, 1):
        print(f"\n{'='*60}")
        print(f"🤖 [{model_idx}/{len(args.models)}] 测试模型: {model}")
        print(f"{'='*60}")

        warmup_model(model)

        model_results = []
        for cat_key, cat_data in test_cases.items():
            cat_results = run_category(model, cat_key, cat_data,
                                       system_prompt, args.runs)
            model_results.extend(cat_results)

        all_results[model] = model_results
        print(f"\n  📊 模型 {model} 完成: {len(model_results)} 个结果")

    # Generate report
    print(f"\n{'='*60}")
    print("📊 生成测试报告...")
    print(f"{'='*60}\n")

    report = generate_report(all_results)

    # Save report
    report_path = args.report or os.path.join(os.path.dirname(__file__), "benchmark_report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"📄 报告已保存: {report_path}")

    # Save raw results
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(all_results, f, ensure_ascii=False, indent=2)
        print(f"💾 原始数据已保存: {args.output}")

    # Also save raw results by default
    raw_path = os.path.join(os.path.dirname(__file__), "benchmark_raw.json")
    with open(raw_path, "w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    print(f"💾 原始数据已保存: {raw_path}")

    # Print summary to terminal
    print("\n" + report)
    print("\n✅ Benchmark 完成！")


if __name__ == "__main__":
    main()
