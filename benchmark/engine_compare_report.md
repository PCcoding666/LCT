# LCT engine comparison: same weights, different runtimes

Generated 2026-11-07 16:48. Eval set `realtime_eval_set.json` (60 cases × 2 runs), temperature 0.3, num_ctx 4096, max_tokens 256, thinking off, streaming; latency measured client-side from request start.

Hardware: Apple M2 Pro, 16 GB, macOS 27.2. Ollama 0.40.14 (Homebrew formula, MLX runner; both `qwen3.5:4b-mlx` and `qwen3.5:4b` tags are the same safetensors/nvfp4 4.5B weights on the MLX runner in this version, so the two Ollama columns are a repeat run, not a different backend). llama.cpp build 12110 via `llama-server -c 4096 -ngl 99 -fa on -t 6 --jinja` with Metal; weights `unsloth/Qwen3.5-4B-GGUF` Q4_K_M (2.74 GB on disk, 0.95 GB phys footprint + 2.6 GB GPU) and, for the PR #27 column, the exact `Qwen/Qwen2.5-1.5B-Instruct-GGUF` q4_k_m file that PR #27 bundles. Ollama resident memory at num_ctx 4096: 4.1 GB (7.6 GB at its 32K default). Note PR #27's in-app runtime uses n_ctx 2048, temperature 0 and at most 6 threads; this benchmark runs all engines at the same 4096 / 0.3 settings.

## Overall

| Metric | ollama-mlx | ollama-4b-tag | llamacpp-metal | llamacpp-qwen2.5-1.5b(PR27) |
|---|---:|---:|---:|---:|
| Cases scored | 120 | 120 | 120 | 120 |
| TTFT avg | 209 ms | 225 ms | 175 ms | 42 ms |
| TTFT p50 | 160 ms | 162 ms | 146 ms | 40 ms |
| TTFT p95 | 489 ms | 537 ms | 353 ms | 81 ms |
| End-to-end avg | 568 ms | 593 ms | 569 ms | 193 ms |
| End-to-end p50 | 534 ms | 565 ms | 542 ms | 172 ms |
| End-to-end p95 | 1086 ms | 1260 ms | 1062 ms | 401 ms |
| Generation speed avg | 41.4 tok/s | 41.0 tok/s | 42.1 tok/s | 107.3 tok/s |
| Instruction compliance | 98% | 98% | 98% | 90% |
| Numbers / names kept | 92% | 92% | 97% | 89% |
| Over-long outputs (drafts completed, commentary) | 0 | 0 | 0 | 0 |
| chrF vs reference | 57.6 | 55.3 | 55.8 | 47.7 |

## By category (end-to-end p50 / chrF)

| Category | ollama-mlx | ollama-4b-tag | llamacpp-metal | llamacpp-qwen2.5-1.5b(PR27) |
|---|---:|---:|---:|---:|
| A_short_turns — 短对话轮次，会议里最常见 | 288 ms / 60 | 280 ms / 49 | 316 ms / 46 | 97 ms / 37 |
| B_asr_drafts — ASR 草稿：句子说到一半就被切出来，模型不能脑补结尾 | 261 ms / 53 | 260 ms / 51 | 308 ms / 52 | 78 ms / 54 |
| C_asr_noisy — 无标点、全小写、口头禅、重复词，模拟真实识别输出 | 404 ms / 40 | 420 ms / 38 | 448 ms / 33 | 152 ms / 25 |
| D_numbers_names — 数字、日期、货币、人名公司名必须原样保留 | 692 ms / 73 | 633 ms / 73 | 710 ms / 68 | 220 ms / 53 |
| E_tech_terms — 技术/产品术语，保留英文或用标准译法 | 584 ms / 67 | 626 ms / 66 | 574 ms / 66 | 245 ms / 59 |
| F_long_sentences — 讲座/会议里的长句，30-45 词 | 981 ms / 53 | 1210 ms / 52 | 1054 ms / 53 | 410 ms / 45 |
| G_zh_to_en — 中文会议发言译成英文，含口语和数字 | 689 ms / 65 | 730 ms / 64 | 610 ms / 69 | 232 ms / 60 |
| H_context_followup — 依赖上文的代词和省略，带 2 条上下文历史 | 521 ms / 46 | 556 ms / 46 | 503 ms / 60 | 154 ms / 50 |

## Problems

- **ollama-mlx**: preamble:好的 ×2; missing terms (run 0): [('D05', ['60', '40']), ('E07', ['Developer ID']), ('F06', ['SSO']), ('H03', ['Apple Silicon']), ('H04', ['Intel'])]
- **ollama-4b-tag**: preamble:好的 ×2; missing terms (run 0): [('E07', ['Developer ID']), ('F06', ['SSO']), ('H03', ['Apple Silicon']), ('H04', ['Intel'])]
- **llamacpp-metal**: preamble:好的 ×2; missing terms (run 0): [('D08', ['NPS']), ('E07', ['Developer ID'])]
- **llamacpp-qwen2.5-1.5b(PR27)**: wrong-script ×5, preamble:好的 ×4, echo ×3, preamble:The translation ×2, preamble:注： ×1; missing terms (run 0): [('D03', ['p99']), ('D06', ['Nakamura/中村']), ('E07', ['Developer ID']), ('G01', ['Wednesday']), ('G03', ['38', '45']), ('G05', ['Zhang', '500/500,000/half a million'])]

## Side-by-side samples (run 0)

**B01** `so what we found was that the`  
ref: 所以我们发现的是  
- ollama-mlx (252 ms): 所以我们发现的是……
- ollama-4b-tag (277 ms): 所以，我们发现的是……
- llamacpp-metal (336 ms): 所以，我们发现的是
- llamacpp-qwen2.5-1.5b(PR27) (82 ms): 我们发现的情况是：

**B06** `we need to decide by`  
ref: 我们需要在……之前决定  
- ollama-mlx (311 ms): 我们需要做出决定。
- ollama-4b-tag (251 ms): 我们需要做出决定。
- llamacpp-metal (307 ms): 我们需要在...做出决定。
- llamacpp-qwen2.5-1.5b(PR27) (56 ms): 我们需要决定。

**C01** `um so yeah basically what we're gonna do is we're gonna ship it next week`  
ref: 所以基本上我们要做的就是下周发布。  
- ollama-mlx (447 ms): 嗯，所以基本上我们要做的事情是，我们下周发货。
- ollama-4b-tag (441 ms): 嗯，所以基本上我们要做的就是把货物下周发货。
- llamacpp-metal (392 ms): 所以基本上，我们下周就发货。
- llamacpp-qwen2.5-1.5b(PR27) (172 ms): 我们下周会发货。

**D01** `Revenue grew 12% year over year to $4.3 billion.`  
ref: 收入同比增长12%，达到43亿美元。  
- ollama-mlx (582 ms): 收入同比增长 12%，达到 43 亿美元。
- ollama-4b-tag (465 ms): 收入同比增长 12%，达到 43 亿美元。
- llamacpp-metal (492 ms): 收入同比增长 12%，达到 43 亿美元。
- llamacpp-qwen2.5-1.5b(PR27) (141 ms): 营业收入同比增长12%至43亿元。

**D03** `We processed 2.7 million requests with a p99 latency of 180 milliseconds.`  
ref: 我们处理了270万个请求，p99延迟为180毫秒。  
- ollama-mlx (767 ms): 我们处理了 270 万次请求，p99 延迟为 180 毫秒。
- ollama-4b-tag (805 ms): 我们处理了 270 万请求，p99 延迟为 180 毫秒。
- llamacpp-metal (876 ms): 我们处理了 270 万次请求，p99 延迟为 180 毫秒。
- llamacpp-qwen2.5-1.5b(PR27) (261 ms): 我们处理了270万请求，99百分位的延迟为180毫秒。

**D05** `The budget is 850 thousand euros, split 60-40 between the two teams.`  
ref: 预算是85万欧元，两个团队按60比40分配。  
- ollama-mlx (697 ms): 预算为 85 万欧元，两个团队按 6:4 比例分配。
- ollama-4b-tag (732 ms): 预算为 85 万欧元，两个团队按 60:40 分配。
- llamacpp-metal (873 ms): 预算为 85 万欧元，在两个团队之间按 60 比 40 分配。
- llamacpp-qwen2.5-1.5b(PR27) (234 ms): 预算为85万欧元，两队各分60%和40%。

**G03** `上个季度我们的留存率从百分之三十八涨到了百分之四十五`  
ref: Last quarter our retention rate went from 38% to 45%.  
- ollama-mlx (603 ms): Last quarter, our retention rate rose from 38 percent to 45 percent.
- ollama-4b-tag (605 ms): Last quarter, our retention rate rose from 38 percent to 45 percent.
- llamacpp-metal (589 ms): Last quarter, our retention rate rose from 38 percent to 45 percent.
- llamacpp-qwen2.5-1.5b(PR27) (235 ms): Last quarter, our retention rate increased from 3.8% to 4.5%.

**G05** `张总说预算最多给到五十万，超了要重新审批`  
ref: Mr. Zhang said the budget is capped at 500 thousand; anything above that needs re-approval.  
- ollama-mlx (778 ms): Mr. Zhang says the budget cap is 500,000; anything exceeding that requires re-approval.
- ollama-4b-tag (730 ms): Mr. Zhang said the budget cap is 500,000; any excess requires re-approval.
- llamacpp-metal (788 ms): Mr. Zhang said the budget is capped at 500,000; anything exceeding that requires re-approval.
- llamacpp-qwen2.5-1.5b(PR27) (277 ms): The CEO said the budget can be given up to fifty thousand, and exceeding it will require a re-approval.

**H02** `It was about twice as fast on first token.`  
ref: 它的首字速度大约快了一倍。  
- ollama-mlx (479 ms): 首词速度大约快了一倍。
- ollama-4b-tag (456 ms): 首词生成速度大约快了一倍。
- llamacpp-metal (454 ms): 首字生成速度大约快了两倍。
- llamacpp-qwen2.5-1.5b(PR27) (133 ms): 第一次 token 上它快了两倍。

**F03** `If the benchmark shows that the embedded runtime is within twenty percent of the Ollama path on first-token latency, I'm comfortable making it the default and keeping Ollama as an advanced option.`  
ref: 如果基准测试显示内置运行时的首字延迟与Ollama路径相差在百分之二十以内，我可以接受把它设为默认，并把Ollama保留为高级选项。  
- ollama-mlx (1225 ms): 如果基准测试显示，在首令牌延迟方面，嵌入式运行时处于 Ollama 路径的百分之二十以内，我就可以将其设为默认选项，并将 Ollama 保留为高级选项。
- ollama-4b-tag (1259 ms): 如果基准测试显示，在首字延迟方面，嵌入式运行时处于 Ollama 路径的百分之二十以内，我就可以将其设为默认选项，并将 Ollama 保留为高级选项。
- llamacpp-metal (1250 ms): 如果基准测试显示，在首字延迟方面，嵌入式运行时距离 Ollama 路径在二十个百分点以内，那么我乐意将其设为默认选项，并将 Ollama 保留为高级选项。
- llamacpp-qwen2.5-1.5b(PR27) (474 ms): 如果基准显示嵌入式运行时在首次令牌延迟上与Ollama路径的误差不超过20%，我有信心将其设置为默认选项，同时保留Ollama作为高级选项。
