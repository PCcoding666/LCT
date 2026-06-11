# 🏆 LCT Translation Benchmark Report
**生成时间**: 2026-06-11 14:03:32

## 📊 总体对比

| 指标 | qwen3.5:4b-mlx | qwen3:4b-instruct-2507-q4_K_M |
| :--- | ---: | ---: |
| **首字延迟 (TTFT) 平均** | 263ms | 227ms |
| **首字延迟 (TTFT) P50** | 158ms | 192ms |
| **首字延迟 (TTFT) P95** | 839ms | 433ms |
| **生成速度 (TPS) 平均** | 30.8 t/s | 51.0 t/s |
| **生成速度 (TPS) 最低** | 22.6 t/s | 28.2 t/s |
| **端到端耗时 平均** | 0.70s | 0.59s |
| **端到端耗时 P50** | 0.58s | 0.42s |
| **端到端耗时 P95** | 2.19s | 2.07s |
| **指令遵循率** | 100% | 100% |
| **专有名词保留率** | 79% | 71% |

## 📋 分类别详细数据

### 类别 A_short_utterances

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 261ms | 31.1 t/s | 0.41s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 229ms | 55.9 t/s | 0.35s | 15/15 |

### 类别 B_medium_sentences

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 206ms | 28.5 t/s | 0.73s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 218ms | 38.2 t/s | 0.68s | 15/15 |

### 类别 C_long_paragraphs

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 335ms | 26.6 t/s | 2.53s | 6/6 |
| qwen3:4b-instruct-2507-q4_K_M | 284ms | 30.2 t/s | 2.43s | 6/6 |

### 类别 D_incomplete_fragments

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 208ms | 28.3 t/s | 0.43s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 214ms | 55.8 t/s | 0.34s | 15/15 |

### 类别 E_technical_terms

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 222ms | 26.8 t/s | 0.91s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 212ms | 43.8 t/s | 0.64s | 15/15 |

### 类别 F_context_aware

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 410ms | 32.0 t/s | 0.72s | 6/6 |
| qwen3:4b-instruct-2507-q4_K_M | 256ms | 50.1 t/s | 0.47s | 6/6 |

### 类别 G_reverse_direction

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 277ms | 31.3 t/s | 0.70s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 234ms | 43.4 t/s | 0.57s | 15/15 |

### 类别 H_japanese

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 300ms | 33.0 t/s | 0.58s | 9/9 |
| qwen3:4b-instruct-2507-q4_K_M | 244ms | 47.5 t/s | 0.57s | 9/9 |

### 类别 I_instruction_compliance

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| qwen3.5:4b-mlx | 294ms | 38.7 t/s | 0.36s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 210ms | 79.4 t/s | 0.26s | 15/15 |

## 🔍 专有名词丢失详情

| 模型 | 用例 | 丢失的术语 | 模型输出 |
| :--- | :--- | :--- | :--- |
| qwen3.5:4b-mlx | E01 | AWS EKS | `我们在上星期五部署了位于亚马逊云托管服务（AWS）EKS 上的新 Kubernetes 集群。` |
| qwen3.5:4b-mlx | E03 | Neural Engine | `Apple 在 WWDC 上发布了新芯片 M5，其神经网络性能有所提升。` |
| qwen3.5:4b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上发布了新 M5 芯片，提升了神经网络引擎的性能。` |
| qwen3.5:4b-mlx | E03 | Neural Engine | `Apple 在 WWDC 上推出了新款 M5 芯片，其神经引擎性能有所提升。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型使用多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3.5:4b-mlx | E05 | transformer, multi-head attention | `变体模型利用多头注意力和层归一化来处理输入嵌入。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型采用多层头注意力机制和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上发布了新款M5芯片，其神经引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上宣布了新款M5芯片，其神经引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上宣布了新款M5芯片，其神经网络引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换模型通过多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换模型通过多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换模型通过多头注意力和层归一化来处理输入嵌入。` |

## 📝 翻译样本对比


#### 用例 A01
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3.5:4b-mlx**: 我们开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3:4b-instruct-2507-q4_K_M**: 我们开始吧。


#### 用例 B02
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3.5:4b-mlx**: 与上个月相比，用户留存率下降了百分之十五，我们需要找出原因。
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3:4b-instruct-2507-q4_K_M**: 与上个月相比，用户留存率下降了百分之十五，我们需要找出原因。


#### 用例 D03
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3.5:4b-mlx**: 如果我们来看最近的数据
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3:4b-instruct-2507-q4_K_M**: 如果我们来看一下上次的数据


#### 用例 E01
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3.5:4b-mlx**: 我们在上星期五部署了位于亚马逊云托管服务（AWS）EKS 上的新 Kubernetes 集群。
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3:4b-instruct-2507-q4_K_M**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。


#### 用例 F01
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3.5:4b-mlx**: 我们从头开始，先谈谈进展情况如何？
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3:4b-instruct-2507-q4_K_M**: 我们先从第一个开始。目前进展如何？


#### 用例 I05
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3.5:4b-mlx**: 什么是机器学习？
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3:4b-instruct-2507-q4_K_M**: 什么是机器学习？
