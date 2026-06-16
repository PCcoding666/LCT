# 🏆 LCT Translation Benchmark Report
**生成时间**: 2026-06-11 18:38:55

## 📊 总体对比

| 指标 | gemma4:12b-mlx | qwen3.5:0.8b | qwen3.5:9b-mlx | qwen3.5:4b-mlx | translategemma:4b-it-q4_K_M | qwen3:4b-instruct-2507-q4_K_M |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **首字延迟 (TTFT) 平均** | 694ms | 343ms | 1214ms | 210ms | 748ms | 500ms |
| **首字延迟 (TTFT) P50** | 415ms | 318ms | 273ms | 134ms | 743ms | 391ms |
| **首字延迟 (TTFT) P95** | 1736ms | 431ms | 1966ms | 734ms | 941ms | 1018ms |
| **生成速度 (TPS) 平均** | 8.0 t/s | 91.4 t/s | 17.7 t/s | 36.4 t/s | 53.1 t/s | 20.1 t/s |
| **生成速度 (TPS) 最低** | 5.3 t/s | 70.5 t/s | 0.3 t/s | 31.7 t/s | 35.6 t/s | 17.4 t/s |
| **端到端耗时 平均** | 2.54s | 0.54s | 3.68s | 0.57s | 1.07s | 1.28s |
| **端到端耗时 P50** | 2.01s | 0.50s | 0.91s | 0.46s | 0.98s | 1.03s |
| **端到端耗时 P95** | 10.03s | 1.07s | 10.11s | 1.88s | 2.59s | 4.00s |
| **指令遵循率** | 100% | 95% | 100% | 100% | 99% | 100% |
| **专有名词保留率** | 79% | 60% | 79% | 81% | 79% | 71% |

## 📋 分类别详细数据

### 类别 A_short_utterances

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 660ms | 8.7 t/s | 1.35s | 15/15 |
| qwen3.5:0.8b | 345ms | 97.2 t/s | 0.41s | 15/15 |
| qwen3.5:9b-mlx | 408ms | 23.2 t/s | 0.59s | 15/15 |
| qwen3.5:4b-mlx | 222ms | 38.1 t/s | 0.34s | 15/15 |
| translategemma:4b-it-q4_K_M | 686ms | 57.6 t/s | 0.80s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 534ms | 20.5 t/s | 0.84s | 15/15 |

### 类别 B_medium_sentences

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 556ms | 8.1 t/s | 2.70s | 15/15 |
| qwen3.5:0.8b | 349ms | 80.5 t/s | 0.56s | 14/15 |
| qwen3.5:9b-mlx | 4350ms | 9.0 t/s | 10.78s | 15/15 |
| qwen3.5:4b-mlx | 178ms | 34.5 t/s | 0.61s | 15/15 |
| translategemma:4b-it-q4_K_M | 758ms | 48.3 t/s | 1.15s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 474ms | 18.2 t/s | 1.43s | 15/15 |

### 类别 C_long_paragraphs

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 1034ms | 7.0 t/s | 11.21s | 6/6 |
| qwen3.5:0.8b | 338ms | 83.1 t/s | 1.10s | 5/6 |
| qwen3.5:9b-mlx | 5621ms | 10.9 t/s | 27.98s | 6/6 |
| qwen3.5:4b-mlx | 283ms | 33.5 t/s | 2.04s | 6/6 |
| translategemma:4b-it-q4_K_M | 905ms | 36.7 t/s | 2.77s | 5/6 |
| qwen3:4b-instruct-2507-q4_K_M | 600ms | 17.4 t/s | 4.34s | 6/6 |

### 类别 D_incomplete_fragments

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 643ms | 7.4 t/s | 1.54s | 15/15 |
| qwen3.5:0.8b | 335ms | 90.4 t/s | 0.44s | 13/15 |
| qwen3.5:9b-mlx | 298ms | 21.1 t/s | 0.62s | 15/15 |
| qwen3.5:4b-mlx | 169ms | 36.3 t/s | 0.37s | 15/15 |
| translategemma:4b-it-q4_K_M | 720ms | 55.4 t/s | 0.86s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 465ms | 20.1 t/s | 0.82s | 15/15 |

### 类别 E_technical_terms

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 655ms | 7.8 t/s | 2.98s | 15/15 |
| qwen3.5:0.8b | 335ms | 81.1 t/s | 0.64s | 15/15 |
| qwen3.5:9b-mlx | 318ms | 19.8 t/s | 1.21s | 15/15 |
| qwen3.5:4b-mlx | 176ms | 34.5 t/s | 0.69s | 15/15 |
| translategemma:4b-it-q4_K_M | 767ms | 47.8 t/s | 1.16s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 458ms | 18.2 t/s | 1.48s | 15/15 |

### 类别 F_context_aware

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 1053ms | 8.1 t/s | 2.29s | 6/6 |
| qwen3.5:0.8b | 349ms | 83.9 t/s | 0.49s | 6/6 |
| qwen3.5:9b-mlx | 537ms | 21.3 t/s | 1.01s | 6/6 |
| qwen3.5:4b-mlx | 313ms | 39.3 t/s | 0.56s | 6/6 |
| translategemma:4b-it-q4_K_M | 946ms | 49.6 t/s | 1.16s | 6/6 |
| qwen3:4b-instruct-2507-q4_K_M | 575ms | 18.9 t/s | 1.14s | 6/6 |

### 类别 G_reverse_direction

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 715ms | 7.9 t/s | 2.57s | 15/15 |
| qwen3.5:0.8b | 348ms | 91.7 t/s | 0.56s | 15/15 |
| qwen3.5:9b-mlx | 431ms | 20.1 t/s | 1.13s | 15/15 |
| qwen3.5:4b-mlx | 246ms | 36.4 t/s | 0.62s | 15/15 |
| translategemma:4b-it-q4_K_M | 750ms | 49.9 t/s | 1.06s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 507ms | 18.6 t/s | 1.28s | 15/15 |

### 类别 H_japanese

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 660ms | 7.8 t/s | 1.96s | 9/9 |
| qwen3.5:0.8b | 341ms | 95.4 t/s | 0.50s | 9/9 |
| qwen3.5:9b-mlx | 495ms | 17.3 t/s | 1.09s | 9/9 |
| qwen3.5:4b-mlx | 265ms | 37.7 t/s | 0.52s | 9/9 |
| translategemma:4b-it-q4_K_M | 753ms | 49.6 t/s | 0.99s | 9/9 |
| qwen3:4b-instruct-2507-q4_K_M | 541ms | 18.5 t/s | 1.35s | 9/9 |

### 类别 I_instruction_compliance

| 模型 | TTFT(avg) | TPS(avg) | 端到端(avg) | 指令遵循 |
| :--- | ---: | ---: | ---: | ---: |
| gemma4:12b-mlx | 680ms | 8.3 t/s | 1.05s | 15/15 |
| qwen3.5:0.8b | 349ms | 111.3 t/s | 0.46s | 13/15 |
| qwen3.5:9b-mlx | 417ms | 14.8 t/s | 0.63s | 15/15 |
| qwen3.5:4b-mlx | 164ms | 37.8 t/s | 0.23s | 15/15 |
| translategemma:4b-it-q4_K_M | 664ms | 69.7 t/s | 0.73s | 15/15 |
| qwen3:4b-instruct-2507-q4_K_M | 469ms | 27.3 t/s | 0.61s | 15/15 |

## ⚠️ 指令违规详情

| 模型 | 用例 | 违规原因 | 模型原始输出 |
| :--- | :--- | :--- | :--- |
| qwen3.5:0.8b | B05 | 包含违规前缀: '当然...' | `当然可以，请您带领我看看架构图。我想让大家都保持一致的理解。` |
| qwen3.5:0.8b | C01 | 包含违规前缀: '好的...' | `好的，今天我将简要总结我们的讨论。我们同意继续推进选项 B，该方案涉及从零重构支付模块。时间窗口为八周，其中第一个里程碑` |
| qwen3.5:0.8b | D05 | 包含违规前缀: '好的...' | `好的，不过实际上是这样嘛。` |
| qwen3.5:0.8b | D05 | 包含违规前缀: '当然...' | `当然，情况是这样的：实际上是这样……` |
| qwen3.5:0.8b | I04 | 包含违规前缀: '当然...' | `当然可以，需要我帮您吗？ 没问题，请告诉我您具体需要什么帮助。 不客气！` |
| qwen3.5:0.8b | I04 | 包含违规前缀: '当然...' | `当然可以帮你吗？` |
| translategemma:4b-it-q4_K_M | C01 | 包含违规前缀: '好的...' | `好的，我来总结一下今天的讨论。我们一致同意采用方案 B，即从头开始重构支付模块。时间表为八周，第一阶段的里程碑将在三周内` |

## 🔍 专有名词丢失详情

| 模型 | 用例 | 丢失的术语 | 模型输出 |
| :--- | :--- | :--- | :--- |
| gemma4:12b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上发布了搭载改进型神经网络引擎性能的新款 M5 芯片。` |
| gemma4:12b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上发布了搭载性能更强的神经网络引擎的新款 M5 芯片。` |
| gemma4:12b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上发布了搭载改进型神经网络引擎性能的新款 M5 芯片。` |
| gemma4:12b-mlx | E05 | multi-head attention | `Transformer 模型采用多头注意力机制和层归一化来处理输入嵌入。` |
| gemma4:12b-mlx | E05 | multi-head attention | `Transformer 模型利用多头注意力机制和层归一化来处理输入的嵌入向量。` |
| gemma4:12b-mlx | E05 | multi-head attention | `Transformer 模型使用多头注意力机制和层归一化来处理输入的嵌入表示。` |
| qwen3.5:0.8b | E01 | AWS EKS | `我們於星期五將新構建的Kubernetes集群部署在AWS提供的EKS上。` |
| qwen3.5:0.8b | E01 | Kubernetes, AWS EKS | `我们在上周五将新版本的 K8s 集群部署在 Azure Active Directory (E)K，请注意。我确认了这些` |
| qwen3.5:0.8b | E01 | AWS EKS | `我们上周五部署了新的Kubernetes集群至AWS EC2。` |
| qwen3.5:0.8b | E02 | React Native | `应用在 17+ ios上出现崩溃，原因是 WebSocket 超时问题。 🔥` |
| qwen3.5:0.8b | E03 | Apple, Neural Engine | `苹果在WWDC会议上宣布了新的M5处理器，以提升神经网络引擎的性能。` |
| qwen3.5:0.8b | E03 | Neural Engine | `Apple 宣布新 M5 芯片在 WWDC 上具有更好的神经引擎性能。` |
| qwen3.5:0.8b | E03 | Apple, Neural Engine | `苹果在WWDC发布了新的M5芯片，该设计增强了Neural引擎的性能。` |
| qwen3.5:0.8b | E04 | Stripe, API | `我们需要在将 Paytm 支付集成前实现 OAuth v2 认证。` |
| qwen3.5:0.8b | E05 | multi-head attention | `Transformer 模型使用多头注意力机制和层归一化来处理嵌入表示。` |
| qwen3.5:0.8b | E05 | transformer, multi-head attention | `转储模型通过使用多头注意力机制和层归一化处理来处理输入嵌入。` |
| qwen3.5:0.8b | E05 | transformer, multi-head attention | `该转换器模型通过将嵌入数据输入到多头注意力机制和层归一化中，进行处理。` |
| qwen3.5:9b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上发布了新款 M5 芯片，其神经网络引擎性能得到提升。` |
| qwen3.5:9b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上发布了新款 M5 芯片，其神经网络引擎性能得到提升。` |
| qwen3.5:9b-mlx | E03 | Apple, Neural Engine | `苹果在WWDC上发布了性能更强大的神经引擎的M5芯片。` |
| qwen3.5:9b-mlx | E05 | multi-head attention | `该 Transformer 模型采用多头注意力和层归一化来处理输入嵌入。` |
| qwen3.5:9b-mlx | E05 | multi-head attention | `Transformer 模型使用多头注意力和层归一化来处理输入嵌入。` |
| qwen3.5:9b-mlx | E05 | multi-head attention | `Transformer 模型采用多头注意力机制和层归一化方法对输入嵌入进行处理。` |
| qwen3.5:4b-mlx | E02 | WebSocket | `React Native 应用因 Web Socket 超时问题在 iOS 17 上崩溃。` |
| qwen3.5:4b-mlx | E03 | Neural Engine | `Apple 在 WWDC 上发布了具有改进神经引擎性能的新 M5 芯片。` |
| qwen3.5:4b-mlx | E03 | Neural Engine | `Apple 在 WWDC 上发布了新款 M5 芯片，其神经网络引擎性能得到显著提升。` |
| qwen3.5:4b-mlx | E03 | Apple, Neural Engine | `苹果在 WWDC 上发布了性能更优的新 M5 芯片，其神经网络引擎得到显著提升。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型利用多头注意力和层归一化处理输入嵌入。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型利用多头注意力机制和层归一化处理输入嵌入。` |
| qwen3.5:4b-mlx | E05 | multi-head attention | `Transformer 模型利用多头注意力和层归一化来处理输入嵌入。` |
| translategemma:4b-it-q4_K_M | E03 | Apple, Neural Engine | `苹果在WWDC上宣布了搭载改进型神经网络引擎的M5芯片。` |
| translategemma:4b-it-q4_K_M | E03 | Apple, Neural Engine | `苹果在WWDC上宣布了搭载改进型神经网络引擎的M5芯片。` |
| translategemma:4b-it-q4_K_M | E03 | Apple, Neural Engine | `苹果在WWDC上宣布推出搭载改进型神经网络引擎的M5芯片。` |
| translategemma:4b-it-q4_K_M | E05 | multi-head attention | `该 Transformer 模型使用多头注意力机制和层归一化来处理输入嵌入。` |
| translategemma:4b-it-q4_K_M | E05 | multi-head attention | `Transformer模型使用多头注意力机制和层归一化来处理输入嵌入。` |
| translategemma:4b-it-q4_K_M | E05 | multi-head attention | `Transformer模型使用多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上宣布了新款M5芯片，其神经网络引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上发布了新款M5芯片，其神经网络引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E03 | Apple, Neural Engine | `苹果公司在WWDC上宣布了新款M5芯片，其神经引擎性能得到提升。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换器模型通过多头注意力机制和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换模型使用多头注意力和层归一化来处理输入嵌入。` |
| qwen3:4b-instruct-2507-q4_K_M | E05 | transformer, multi-head attention | `变换模型通过多头注意力机制和层归一化来处理输入嵌入。` |

## 📝 翻译样本对比


#### 用例 A01
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **gemma4:12b-mlx**: 让我们开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3.5:0.8b**: 让我们开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3.5:9b-mlx**: 开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3.5:4b-mlx**: 让我们开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **translategemma:4b-it-q4_K_M**: 让我们开始吧。
- **原文**: Let's get started.
- **参考**: 让我们开始吧。
- **qwen3:4b-instruct-2507-q4_K_M**: 我们开始吧。


#### 用例 B02
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **gemma4:12b-mlx**: 用户留存率较上月下降了百分之十五，我们需要找出原因。
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3.5:0.8b**: 用户留存率相比上个月下降了 15%。我们需要查明这一现象的原因，并且还需要继续讨论这个议题。
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3.5:9b-mlx**: 用户留存率较上月下降了百分之十五，我们需要找出原因。
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3.5:4b-mlx**: 用户留存率较去年同期下降了百分之十五，我们需要找出原因。
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **translategemma:4b-it-q4_K_M**: 用户留存率相较上个月下降了百分之十五，我们需要找出原因。
- **原文**: The user retention rate dropped by fifteen percent compared to last month, and we need to figure out why.
- **参考**: 用户留存率与上个月相比下降了百分之十五，我们需要找出原因。
- **qwen3:4b-instruct-2507-q4_K_M**: 与上个月相比，用户留存率下降了百分之十五，我们需要找出原因。


#### 用例 D03
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **gemma4:12b-mlx**: 如果我们看一下过去的数据
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3.5:0.8b**: 如果您能查看最新的统计数据。
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3.5:9b-mlx**: 如果我们查看去年的数据，
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3.5:4b-mlx**: 如果从最近的数据来看
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **translategemma:4b-it-q4_K_M**: 如果我们看一下上一次的数据
- **原文**: If we look at the data from last
- **参考**: 如果我们看一下上
- **qwen3:4b-instruct-2507-q4_K_M**: 如果我们回顾一下上次的数据


#### 用例 E01
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **gemma4:12b-mlx**: 我们上周五在 AWS EKS 上部署了新的 Kubernetes 集群。
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3.5:0.8b**: 我們於星期五將新構建的Kubernetes集群部署在AWS提供的EKS上。
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3.5:9b-mlx**: 上周五我们在 AWS EKS 上部署了新的 Kubernetes 集群。
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3.5:4b-mlx**: 我们于上星期五在 AWS EKS 上部署了新的 Kubernetes 集群。
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **translategemma:4b-it-q4_K_M**: 我们上周五在 AWS EKS 上部署了新的 Kubernetes 集群。
- **原文**: We deployed the new Kubernetes cluster on AWS EKS last Friday.
- **参考**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。
- **qwen3:4b-instruct-2507-q4_K_M**: 我们上周五在AWS EKS上部署了新的Kubernetes集群。


#### 用例 F01
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **gemma4:12b-mlx**: 让我们从第一个开始。目前进展如何？
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3.5:0.8b**: 我们正在开始讨论第一个重点问题，进度如何？
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3.5:9b-mlx**: 我们首先从第一点开始，目前进展如何？
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3.5:4b-mlx**: 我们首先从第一项开始，目前的进展如何？
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **translategemma:4b-it-q4_K_M**: 我们先从第一个开始。目前进展如何？
- **原文**: Let's start with the first one. How is it going so far?
- **参考**: 让我们从第一个开始。目前进展如何？
- **qwen3:4b-instruct-2507-q4_K_M**: 我们先从第一个开始。目前进展如何？


#### 用例 I05
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **gemma4:12b-mlx**: 什么是机器学习？
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3.5:0.8b**: 机器学习是什么？
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3.5:9b-mlx**: 机器学习是什么？
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3.5:4b-mlx**: 什么是机器学习？
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **translategemma:4b-it-q4_K_M**: 什么是机器学习？
- **原文**: What is machine learning?
- **参考**: 什么是机器学习？
- **qwen3:4b-instruct-2507-q4_K_M**: 什么是机器学习？
