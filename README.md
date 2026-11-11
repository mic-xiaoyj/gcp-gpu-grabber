# grab_gpu.sh：在 GCP 上抢 A100 / H100 GPU

脚本在多个区域、多种 GPU 机型、多种计费模式（按需 / Spot / DWS Flex-start）之间循环尝试创建 GCE VM，**抢到第一台就停止**。停止时会自动清理本次运行中其余还在排队或多抢到的 VM。

## 1. 环境要求

- 推荐直接在 **Cloud Shell** 中运行，环境已经齐全
- 本地运行需要：bash ≥ 4（macOS 请先 `brew install bash`）和 Google Cloud CLI（`gcloud auth login` 登录）
- 执行账号需要 `roles/compute.instanceAdmin.v1` 权限；如果为 VM 指定了服务账号，还需要 `roles/iam.serviceAccountUser`
- 项目中要有对应 GPU 的**配额**，见第 4 节

```bash
chmod +x grab_gpu.sh
```

## 2. 可选规格速查

| `--gpu` 简写 | GPU | 机型（每台 GPU 数） | 说明 |
|---|---|---|---|
| `a100` | A100 40GB | a2-highgpu-1g/2g/4g/8g、a2-megagpu-16g | |
| `a100-80g` | A100 80GB | a2-ultragpu-1g/2g/4g/8g | |
| `h100` | H100 80GB | a3-highgpu-1g/2g/4g/8g | 1g/2g/4g 只支持 spot 和 dws |
| `h100-mega` | H100 80GB | a3-megagpu-8g | 网络带宽更高 |
| `h100-edge` | H100 80GB | a3-edgegpu-8g | |
| `h200` | H200 141GB | a3-ultragpu-8g | 下列区域目前都没有 |
| `b200` | B200 180GB | a4-highgpu-8g | |

各区域的机型分布（2026-11 查询结果，以 `list` 子命令的实时输出为准）：

| 区域 | A100 40G | A100 80G | H100 | B200 |
|---|---|---|---|---|
| asia-southeast1 新加坡 | a, b, c | c | b, c | b |
| asia-northeast1 东京 | a, c | – | b, c | b |
| asia-northeast3 首尔 | a, b | – | c（edge：a, c） | – |
| me-west1 特拉维夫 | a, c | – | – | – |
| me-central1 多哈 / me-central2 达曼 | – | – | – | – |
| asia-northeast2 大阪 | – | – | – | – |

> 中东地区目前只有 me-west1（特拉维夫）提供 A100，me-central1/2 没有 A100/H100。

## 3. 三种计费模式

| `--models` | 说明 | 适合场景 |
|---|---|---|
| `spot` | 价格最低（约为按需价的 30%–40%），可能随时被抢占，抢占后 VM 会被删除 | 测试、可以中断的任务 |
| `ondemand` | 按需计费，不会被抢占，但资源最紧张 | 长时间稳定运行 |
| `dws` | DWS Flex-start：请求进入**排队**，有资源时自动分配。最长运行时长由 `--dws-max-run` 设置（上限 7 天），到期自动删除。价格比按需低 | 抢 H100/A100 8 卡成功率最高 |

`--models` 中的顺序就是尝试的优先级。DWS 请求每轮只提交一次然后排队等待，不会重复占用资源。

## 4. 先查规格和配额

```bash
./grab_gpu.sh list --project <PROJECT_ID>
# 只看某些区域或 GPU
./grab_gpu.sh list --project <PROJECT_ID> --regions asia-southeast1,asia-northeast1 --gpu h100,a100
```

- `spot` 和 `dws` 使用 `PREEMPTIBLE_NVIDIA_*` 配额，`ondemand` 使用 `NVIDIA_*` 配额
- H100 / H200 / B200 的配额在控制台 **IAM 与管理 > 配额** 中，搜索 “GPUs per GPU family” 查看
- 配额不够时，脚本会提示是哪个配额不足，并跳过对应组合

## 5. 抢卡

```bash
# 默认：新加坡、东京、首尔、特拉维夫，A100 / A100-80G / H100 的 8 卡机型，按 spot → ondemand → dws 的顺序
./grab_gpu.sh grab --project <PROJECT_ID>

# 只抢 H100 8 卡，DWS 优先，运行 3 天
./grab_gpu.sh grab --project <PROJECT_ID> --gpu h100 --models dws,spot --dws-max-run 3d

# 指定精确机型和区域
./grab_gpu.sh grab --project <PROJECT_ID> --regions asia-southeast1,asia-northeast1 \
    --machine-types a3-highgpu-8g,a2-ultragpu-8g

# 1 卡测试；使用自定义 VPC；不分配外网 IP
./grab_gpu.sh grab --project <PROJECT_ID> --gpu a100,h100 --gpu-count 1 \
    --network my-vpc --no-external-ip

# 先看会执行哪些命令（不实际创建）
./grab_gpu.sh grab --project <PROJECT_ID> --dry-run
```

建议用 `nohup` 或 `tmux` 让脚本在后台持续运行：

```bash
nohup ./grab_gpu.sh grab --project <PROJECT_ID> --gpu h100 > grab.out 2>&1 &
tail -f grab.out
```

### 常用参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--project` | 必填 | GCP 项目 |
| `--regions` | asia-southeast1,asia-northeast1,asia-northeast3,me-west1 | 区域，逗号分隔 |
| `--gpu` | a100,a100-80g,h100 | GPU 简写，见第 2 节 |
| `--machine-types` | – | 直接指定机型，优先于 `--gpu` |
| `--gpu-count` | 8 | 每台 VM 的 GPU 数，可写 `1,8` 或 `any` |
| `--models` | spot,ondemand,dws | 计费模式及优先级 |
| `--network` / `--subnet` | default / 自动选择 | VPC 网络；子网默认自动选该网络在各区域的第一个子网 |
| `--no-external-ip` | 关闭 | 不分配外网 IP |
| `--image-family` / `--image-project` | common-cu129-ubuntu-2204-nvidia-580 / deeplearning-platform-release | 默认使用 Deep Learning VM 镜像，已预装 CUDA 和驱动 |
| `--disk-size` | 200 | 启动盘大小（GB） |
| `--service-account` | 默认服务账号 | VM 使用的服务账号 |
| `--dws-max-run` | 24h | Flex-start 最长运行时长（如 `3d`，上限 `7d`） |
| `--dws-wait` | 2h | Flex-start 单次排队最长等待时间，超时后自动重新提交 |
| `--interval` | 30 | 每轮之间的间隔秒数 |
| `--timeout` | 0（不限） | 总超时秒数 |
| `--parallel` | 1 | 每轮并发创建数。调大可以加快速度，但可能同时抢到多台，多余的会被自动删除 |
| `--dry-run` | – | 只打印命令，不创建 |

## 6. 抢到之后

脚本会打印 VM 名称、Zone、机型和 SSH 命令，例如：

```
  🎉 抢到 GPU！
  VM 名称   : gpu-test-asia-southeast1-c-s1a2b
  SSH       : gcloud compute ssh gpu-test-asia-southeast1-c-s1a2b --zone=asia-southeast1-c --project=...
  验证 GPU  : gcloud compute ssh ... --command='nvidia-smi'
```

DLVM 镜像首次启动时会自动安装 / 加载驱动，需要几分钟，之后就可以运行 `nvidia-smi`。

## 7. 中断与清理

- 按 **Ctrl-C** 会删除本次运行中还在排队的 DWS 请求；已经创建成功的 VM 会保留
- 删除所有脚本创建的 VM（带 `created-by=grab-gpu` 标签）：

```bash
./grab_gpu.sh cleanup --project <PROJECT_ID>        # 删除前会列出并确认
./grab_gpu.sh cleanup --project <PROJECT_ID> --yes  # 不确认，直接删除
```

- 日志文件：在当前目录下生成 `grab_gpu_<时间>.log`

## 8. 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 抢到 GPU |
| 2 | 权限或计费错误 |
| 3 | 所有候选都因配额不足或不支持被跳过 |
| 4 | 达到 `--timeout` 仍未抢到 |
| 130 | 被 Ctrl-C 中断 |

## 9. 提高成功率的建议

1. H100 / A100 8 卡优先用 **dws**，排队成功率比反复尝试 ondemand 高很多
2. 多选区域和机型（例如同时选 `a100,a100-80g,h100`）
3. 能接受 1/2/4 卡时，用 `--gpu-count 1,2,4,8` 扩大候选范围
4. 长期或稳定需求，建议联系 Google 客户团队申请**预留（Reservation）**或 DWS Calendar 模式
