# 🏆 LCT Translation Benchmark Report
**生成时间**: 2026-06-05 11:30:04

## 📊 总体对比

| 指标 | qwen3:4b-instruct-2507-q4_K_M | qwen3.5:4b-mlx | qwen3.5:9b-mlx |
| :--- | ---: | ---: | ---: |
| **首字延迟 (TTFT) 平均** | 992ms | 308012ms | 124519ms |
| **首字延迟 (TTFT) P50** | 399ms | 258959ms | 120998ms |
| **首字延迟 (TTFT) P95** | 2336ms | 697851ms | 149605ms |
| **生成速度 (TPS) 平均** | 34.7 t/s | 8.6 t/s | 10.1 t/s |
| **生成速度 (TPS) 最低** | 2.1 t/s | 2.4 t/s | 6.8 t/s |
| **端到端耗时 平均** | 1.72s | 309.80s | 449.71s |
| **端到端耗时 P50** | 0.83s | 262.61s | 135.62s |
| **端到端耗时 P95** | 4.84s | 699.26s | 1424.39s |
| **指令遵循率** | 100% | 99% | 100% |
| **专有名词保留率** | 71% | 79% | 100% |

## 📋 分类别详细数据

### 类别 A_short_utterances

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 487ms | 39.0 t/s | 0.69s | 15/15 |
| qwen3.5:4b-mlx | 288355ms | 10.5 t/s | 289.15s | 15/15 |
| qwen3.5:9b-mlx | 124519ms | 10.1 t/s | 449.71s | 4/4 |

### 类别 B_medium_sentences

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 3964ms | 24.4 t/s | 5.75s | 15/15 |
| qwen3.5:4b-mlx | 492503ms | 6.6 t/s | 495.43s | 15/15 |

### 类别 C_long_paragraphs

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 1242ms | 17.4 t/s | 5.12s | 6/6 |
| qwen3.5:4b-mlx | 261809ms | 8.0 t/s | 269.15s | 5/6 |

### 类别 D_incomplete_fragments

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 826ms | 39.5 t/s | 1.00s | 15/15 |
| qwen3.5:4b-mlx | 359946ms | 8.0 t/s | 360.85s | 15/15 |

### 类别 E_technical_terms

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 556ms | 29.3 t/s | 1.22s | 15/15 |
| qwen3.5:4b-mlx | 290125ms | 7.9 t/s | 292.39s | 15/15 |

### 类别 F_context_aware

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 419ms | 27.3 t/s | 0.82s | 6/6 |
| qwen3.5:4b-mlx | 165963ms | 8.1 t/s | 167.26s | 6/6 |

### 类别 G_reverse_direction

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 390ms | 30.9 t/s | 0.87s | 15/15 |
| qwen3.5:4b-mlx | 311601ms | 7.4 t/s | 313.49s | 15/15 |

### 类别 H_japanese

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 321ms | 28.9 t/s | 0.85s | 9/9 |
| qwen3.5:4b-mlx | 412295ms | 8.2 t/s | 413.58s | 9/9 |

### 类别 I_instruction_compliance

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3:4b-instruct-2507-q4_K_M | 264ms | 58.5 t/s | 0.32s | 15/15 |
| qwen3.5:4b-mlx | 118274ms | 12.3 t/s | 118.47s | 15/15 |

## ⚠️ 指令违规详情

| 模型 | 用例 | 违规原因 | 模型原始输出 |
| :--- | :--- | :--- | :--- |
| qwen3.5:4b-mlx | C01 | 包含违规前缀: '好的...' | `好的，我总结一下今天的讨论：我们一致同意推进 B 方案，即从头开始重构支付模块。工期为八周，首个里程碑需在三周内完成。J` |

## 🔍 专有名词丢失详情

| 模型 | 用例 | 丢失的术语 | 模型输出 |
| :--- | :--- | :--- | :--- |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上宣布了新款M5芯片，其神经网络引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上发布了新款M5芯片，其神经引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上宣布了新款M5芯片，其神经网络引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换模型通过多头注意力和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换器模型通过多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换模型通过多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3.5:4b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 宣布发布新款 M5 芯片，搭载改进后的神经网络引擎性能。` |
| qwen3.5:4b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上宣布推出新款 M5 芯片，其神经网络引擎性能得到提升。` |
| qwen3.5:4b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上宣布发布新一代 M5 芯片，其神经引擎性能得到显著提升。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型使用多头注意力和层归一化来处理输入嵌入。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型利用多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型利用多头注意力和层归一化来处理输入嵌入。` |

## 📝 翻译样本对比


#### 用例 A01
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3:4b-instruct-2507-q4_K_M**: 我们开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3.5:4b-mlx**: 我们开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3.5:9b-mlx**: 我们开始吧。


#### 用例 B02
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3:4b-instruct-2507-q4_K_M**: 与上个月相比，用户留存率下降了百分之十五，我们需要找出原因。
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3.5:4b-mlx**: 与上月相比，用户留存率下降了百分之十五，我们需要查明原因。


#### 用例 D03
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3:4b-instruct-2507-q4_K_M**: 如果我们来看上次的数据
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3.5:4b-mlx**: 如果我们回顾此前的数据


#### 用例 E01
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3:4b-instruct-2507-q4_K_M**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3.5:4b-mlx**: 上周五，我们在 AWS EKS 上部署了新的 Kubernetes 集群。


#### 用例 F01
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3:4b-instruct-2507-q4_K_M**: 我们先从第一个开始。目前进展如何？
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3.5:4b-mlx**: 我们首先从第一项谈起，目前的进展如何？


#### 用例 I05
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3:4b-instruct-2507-q4_K_M**: 什么是机器学习？
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3.5:4b-mlx**: 什么是机器学习？
