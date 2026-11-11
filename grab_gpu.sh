#!/usr/bin/env bash
# =============================================================================
# grab_gpu.sh — 在 GCP 多区域 / 多机型 / 多计费模式之间轮询抢 GPU（GCE VM）
#
#   计费模式：ondemand（按需） / spot（抢占式） / dws（DWS Flex-start，排队）
#   抢到第一台 VM 即停止，并自动清理本次运行中其余排队/多抢到的 VM。
#
# 子命令：
#   list     查看各区域可用 GPU 机型与配额
#   grab     开始抢卡
#   cleanup  删除所有带 created-by=grab-gpu 标签的 VM
#
# 依赖：bash >= 4、gcloud（建议在 Cloud Shell 中运行）
# =============================================================================
set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
LABEL_KEY="created-by"
LABEL_VAL="grab-gpu"

# ----------------------------- 默认参数 --------------------------------------
PROJECT=""
REGIONS="asia-southeast1,asia-northeast1,asia-northeast3,me-west1"
GPUS="a100,a100-80g,h100"
MACHINE_TYPES=""
GPU_COUNT="8"
MODELS="spot,ondemand,dws"
NAME_PREFIX="gpu-test"
IMAGE_FAMILY="common-cu129-ubuntu-2204-nvidia-580"
IMAGE_PROJECT="deeplearning-platform-release"
DISK_SIZE="200"
NETWORK="default"
SUBNET=""
SERVICE_ACCOUNT=""
NO_EXTERNAL_IP=0
DWS_MAX_RUN="24h"
DWS_WAIT="2h"
INTERVAL=30
TIMEOUT=0
PARALLEL=1
DRY_RUN=0
YES=0

# ----------------------------- 工具函数 --------------------------------------
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*" >&2; }
die()  { err "$*"; exit 1; }

if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "需要 bash >= 4（macOS 自带 bash 3.2，请 brew install bash 或在 Cloud Shell 中运行）" >&2
  exit 1
fi
command -v gcloud >/dev/null 2>&1 || { echo "未找到 gcloud，请先安装 Google Cloud CLI" >&2; exit 1; }
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# GPU 简写 -> 机型前缀（正则）
gpu_to_prefix() {
  case "$1" in
    a100)       echo "a2-highgpu|a2-megagpu" ;;   # A100 40GB
    a100-80g)   echo "a2-ultragpu" ;;             # A100 80GB
    h100)       echo "a3-highgpu" ;;              # H100 80GB
    h100-mega)  echo "a3-megagpu" ;;              # H100 80GB Mega
    h100-edge)  echo "a3-edgegpu" ;;              # H100 80GB Edge
    h200)       echo "a3-ultragpu" ;;             # H200 141GB
    b200)       echo "a4-highgpu" ;;              # B200 180GB
    *) return 1 ;;
  esac
}

# 机型 -> GPU 描述
machine_gpu_desc() {
  case "$1" in
    a2-highgpu-*|a2-megagpu-*) echo "A100 40GB" ;;
    a2-ultragpu-*)  echo "A100 80GB" ;;
    a3-highgpu-*)   echo "H100 80GB" ;;
    a3-megagpu-*)   echo "H100 80GB Mega" ;;
    a3-edgegpu-*)   echo "H100 80GB Edge" ;;
    a3-ultragpu-*)  echo "H200 141GB" ;;
    a4-highgpu-*)   echo "B200 180GB" ;;
    *) echo "?" ;;
  esac
}

# 机型 -> 启动盘类型
disk_type_for() {
  case "$1" in
    a3-ultragpu-*|a4-*) echo "hyperdisk-balanced" ;;
    *) echo "pd-balanced" ;;
  esac
}

# 该机型是否支持某计费模式
model_supported() {
  local mt="$1" model="$2"
  if [[ "$model" == "ondemand" ]]; then
    case "$mt" in a3-highgpu-1g|a3-highgpu-2g|a3-highgpu-4g) return 1 ;; esac
  fi
  return 0
}

zone_region() { echo "${1%-*}"; }

# 后台删除 VM（gcloud instances delete 没有 --async），用 wait_deletes 等待完成
DEL_PIDS=()
declare -A DELETED
delete_vm() {
  local n="$1" z="$2"
  [[ -n "${DELETED[$n]:-}" ]] && return 0
  DELETED[$n]=1
  ( gcloud compute instances delete "$n" --zone="$z" --project="$PROJECT" --quiet </dev/null >/dev/null 2>&1 \
      || echo "[$(ts)] WARN  删除 $n ($z) 失败，请手动删除" ) &
  DEL_PIDS+=($!)
}
wait_deletes() {
  [[ ${#DEL_PIDS[@]} -eq 0 ]] && return 0
  info "等待 ${#DEL_PIDS[@]} 个删除操作完成..."
  wait "${DEL_PIDS[@]}" 2>/dev/null
  DEL_PIDS=()
}

rand4() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 4; }

usage() {
  cat <<EOF
用法：
  $SCRIPT_NAME list    --project P [--regions R1,R2] [--gpu a100,h100,...]
  $SCRIPT_NAME grab    --project P [选项...]
  $SCRIPT_NAME cleanup --project P [--yes]

GPU 简写（--gpu）：
  a100       A100 40GB    a2-highgpu-{1,2,4,8}g, a2-megagpu-16g
  a100-80g   A100 80GB    a2-ultragpu-{1,2,4,8}g
  h100       H100 80GB    a3-highgpu-{1,2,4,8}g   (1/2/4g 仅支持 spot/dws)
  h100-mega  H100 Mega    a3-megagpu-8g
  h100-edge  H100 Edge    a3-edgegpu-8g
  h200       H200 141GB   a3-ultragpu-8g
  b200       B200 180GB   a4-highgpu-8g

grab 选项（括号内为默认值）：
  --project P              GCP 项目（必填）
  --regions LIST           区域，逗号分隔 ($REGIONS)
                             新加坡 asia-southeast1 | 东京 asia-northeast1 | 大阪 asia-northeast2
                             首尔 asia-northeast3   | 特拉维夫 me-west1 | 多哈 me-central1 | 达曼 me-central2
  --gpu LIST               GPU 简写，逗号分隔 ($GPUS)
  --machine-types LIST     直接指定机型，覆盖 --gpu，如 a3-highgpu-8g,a2-ultragpu-8g
  --gpu-count LIST         每台 VM 的 GPU 数，逗号分隔或 any ($GPU_COUNT)
  --models LIST            计费模式及优先级：spot,ondemand,dws ($MODELS)
  --name-prefix S          VM 名称前缀 ($NAME_PREFIX)
  --image-family S         ($IMAGE_FAMILY)
  --image-project S        ($IMAGE_PROJECT)
  --disk-size GB           启动盘大小 ($DISK_SIZE)
  --network S              VPC 网络 ($NETWORK)
  --subnet S               子网名（各区域同名），默认自动选该网络在各区域的第一个子网
  --service-account S      VM 服务账号（默认 Compute 默认服务账号）
  --no-external-ip         不分配外网 IP
  --dws-max-run DUR        Flex-start 最长运行时长，如 24h / 7d ($DWS_MAX_RUN)
  --dws-wait DUR           Flex-start 排队等待时长，如 2h ($DWS_WAIT)
  --interval SEC           每轮间隔秒数 ($INTERVAL)
  --timeout SEC            总超时秒数，0 为不限 ($TIMEOUT)
  --parallel N             每轮并发创建数 ($PARALLEL)，>1 时可能同时抢到多台，多余的会自动删除
  --dry-run                只打印命令，不实际创建
  -h, --help               显示帮助

示例：
  $SCRIPT_NAME list --project my-proj
  $SCRIPT_NAME grab --project my-proj --gpu h100,a100 --gpu-count 8
  $SCRIPT_NAME grab --project my-proj --regions asia-southeast1 --machine-types a3-highgpu-8g --models dws --dws-max-run 3d
EOF
}

# ----------------------------- 参数解析 --------------------------------------
CMD="${1:-}"
[[ -z "$CMD" || "$CMD" == "-h" || "$CMD" == "--help" ]] && { usage; exit 0; }
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)         PROJECT="$2"; shift 2 ;;
    --regions)         REGIONS="$2"; shift 2 ;;
    --gpu)             GPUS="$2"; shift 2 ;;
    --machine-types)   MACHINE_TYPES="$2"; shift 2 ;;
    --gpu-count)       GPU_COUNT="$2"; shift 2 ;;
    --models)          MODELS="$2"; shift 2 ;;
    --name-prefix)     NAME_PREFIX="$2"; shift 2 ;;
    --image-family)    IMAGE_FAMILY="$2"; shift 2 ;;
    --image-project)   IMAGE_PROJECT="$2"; shift 2 ;;
    --disk-size)       DISK_SIZE="$2"; shift 2 ;;
    --network)         NETWORK="$2"; shift 2 ;;
    --subnet)          SUBNET="$2"; shift 2 ;;
    --service-account) SERVICE_ACCOUNT="$2"; shift 2 ;;
    --no-external-ip)  NO_EXTERNAL_IP=1; shift ;;
    --dws-max-run)     DWS_MAX_RUN="$2"; shift 2 ;;
    --dws-wait)        DWS_WAIT="$2"; shift 2 ;;
    --interval)        INTERVAL="$2"; shift 2 ;;
    --timeout)         TIMEOUT="$2"; shift 2 ;;
    --parallel)        PARALLEL="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -y|--yes)          YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
done

[[ -n "$PROJECT" ]] || die "必须指定 --project"
NAME_PREFIX="$(echo "$NAME_PREFIX" | tr 'A-Z_' 'a-z-')"

IFS=',' read -r -a REGION_ARR <<<"$REGIONS"
IFS=',' read -r -a MODEL_ARR  <<<"$MODELS"
for m in "${MODEL_ARR[@]}"; do
  case "$m" in spot|ondemand|dws) ;; *) die "未知计费模式：$m（可选 spot,ondemand,dws）" ;; esac
done

# 构造机型匹配正则
build_machine_regex() {
  local parts=() g p
  if [[ -n "$MACHINE_TYPES" ]]; then
    IFS=',' read -r -a parts <<<"$MACHINE_TYPES"
    local joined; joined="$(IFS='|'; echo "${parts[*]}")"
    echo "^(${joined})\$"
    return
  fi
  IFS=',' read -r -a parts <<<"$GPUS"
  local prefixes=()
  for g in "${parts[@]}"; do
    p="$(gpu_to_prefix "$g")" || die "未知 GPU 简写：$g（--help 查看可选值）"
    prefixes+=("$p")
  done
  local pj; pj="$(IFS='|'; echo "${prefixes[*]}")"
  local cnt
  if [[ "$GPU_COUNT" == "any" ]]; then
    cnt="[0-9]+"
  else
    cnt="(${GPU_COUNT//,/|})"
  fi
  echo "^(${pj})-${cnt}g\$"
}

# 输出 "zone machine_type"，限定在所选区域
discover_machines() {
  local regex="$1" region_re
  region_re="^($(IFS='|'; echo "${REGION_ARR[*]}"))-[a-z]\$"
  gcloud compute machine-types list --project="$PROJECT" \
    --filter="name~'^(a2|a3|a4)-'" --format="value(zone.basename(),name)" 2>/dev/null \
    | awk -v rre="$region_re" -v mre="$regex" '$1 ~ rre && $2 ~ mre {print $1, $2}' \
    | sort -u
}

# =============================================================================
# list
# =============================================================================
cmd_list() {
  local regex
  if [[ -z "$MACHINE_TYPES" && "$GPU_COUNT" == "8" && "$GPUS" == "a100,a100-80g,h100" ]]; then
    # list 默认展示所有 GPU 与所有卡数
    GPUS="a100,a100-80g,h100,h100-mega,h100-edge,h200,b200"; GPU_COUNT="any"
  fi
  regex="$(build_machine_regex)"
  info "项目：$PROJECT  区域：$REGIONS"
  local data; data="$(discover_machines "$regex")"

  local r
  for r in "${REGION_ARR[@]}"; do
    echo
    echo "==================== $r ===================="
    local rows; rows="$(echo "$data" | awk -v r="$r" 'NF && $1 ~ "^"r"-[a-z]$"')"
    if [[ -z "$rows" ]]; then
      echo "  （该区域没有匹配的 A100/H100/H200/B200 机型，或项目无权限访问该区域）"
    else
      printf "  %-18s %-16s %s\n" "机型" "GPU" "可用 Zone"
      echo "$rows" | awk '{z[$2]=z[$2]" "$1} END{for(k in z) print k, z[k]}' | sort \
        | while read -r mt zones; do
            printf "  %-20s %-16s %s\n" "$mt" "$(machine_gpu_desc "$mt")" "$zones"
          done
    fi
    echo "  --- 配额（metric 已用/上限，Compute regional quota）---"
    gcloud compute regions describe "$r" --project="$PROJECT" --flatten=quotas \
      --format="csv[no-heading](quotas.metric,quotas.usage,quotas.limit)" 2>/dev/null \
      | grep -E 'A100|H100|H200|B200|GPUS_ALL_REGIONS|^PREEMPTIBLE_CPUS|^CPUS,' \
      | grep -v COMMITTED \
      | awk -F, '{printf "  %-40s %s/%s\n", $1, int($2), int($3)}' \
      || echo "  （无法读取）"
  done

  echo
  info "尝试通过 Cloud Quotas API 读取 GPU family 配额（H100/H200/B200 等新 GPU 的配额在这里）..."
  local q
  q="$(timeout 60 gcloud beta quotas info describe GPUS-PER-GPU-FAMILY-per-project-region \
        --service=compute.googleapis.com --project="$PROJECT" \
        --format="json(dimensionsInfos)" 2>/dev/null)"
  if [[ -n "$q" ]]; then
    echo "$q" | python3 -c '
import json, sys
regions = sys.argv[1].split(",")
d = json.load(sys.stdin)
for x in d.get("dimensionsInfos", []):
    dims = x.get("dimensions", {})
    reg = dims.get("region", "")
    if reg in regions:
        print("  %-18s %-28s limit=%s" % (reg, dims.get("gpu_family", ""), x.get("details", {}).get("value", "?")))
' "$REGIONS" 2>/dev/null || echo "  （解析失败）"
  else
    echo "  无法读取（可能未启用 cloudquotas.googleapis.com 或无权限）。"
    echo "  请到控制台 IAM 与管理 > 配额 中搜索 \"GPUs per GPU family\" 或 \"NVIDIA_H100\" 查看。"
  fi
  echo
  echo "提示：spot 与 dws(Flex-start) 使用 PREEMPTIBLE_* 配额，ondemand 使用非 PREEMPTIBLE 配额。"
}

# =============================================================================
# cleanup
# =============================================================================
cmd_cleanup() {
  local list
  list="$(gcloud compute instances list --project="$PROJECT" \
            --filter="labels.${LABEL_KEY}=${LABEL_VAL}" \
            --format="value(name,zone.basename(),status,machineType.basename())" 2>/dev/null)"
  if [[ -z "$list" ]]; then info "没有找到 ${LABEL_KEY}=${LABEL_VAL} 的 VM"; return 0; fi
  echo "将删除以下 VM："
  echo "$list" | awk '{printf "  %-45s %-20s %-12s %s\n", $1, $2, $3, $4}'
  if [[ $YES -ne 1 ]]; then
    read -r -p "确认删除？[y/N] " a
    [[ "$a" == "y" || "$a" == "Y" ]] || { info "已取消"; return 0; }
  fi
  while read -r n z _; do
    info "删除 $n ($z)"
    delete_vm "$n" "$z"
  done <<<"$list"
  wait_deletes
  info "清理完成"
}

# =============================================================================
# grab
# =============================================================================
RUN_ID="$(date +%Y%m%d%H%M%S)-$(rand4)"
LOG_FILE=""
WINNER=""            # "name zone machine model"
declare -A SKIP      # key -> reason
declare -A SUBNET_OF # region -> subnet name
declare -A DWS_NAME  # "zone|mt" -> instance name
declare -A DWS_OP    # "zone|mt" -> operation name
declare -A DWS_BACKOFF # "zone|mt" -> 剩余跳过轮数

# 错误分类：stockout / quota / unsupported / exists / fatal / other
classify_error() {
  local e="$1"
  if   grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|resource_availability|STOCKOUT|currently unavailable|not enough resources' <<<"$e"; then echo stockout
  elif grep -qiE 'QUOTA_EXCEEDED|Quota .* exceeded|quota exceeded|exceeded quota' <<<"$e"; then echo quota
  elif grep -qiE 'already exists' <<<"$e"; then echo exists
  elif grep -qiE 'PERMISSION_DENIED|Required .compute\.|does not have permission|billing' <<<"$e"; then echo fatal
  elif grep -qiE 'not supported|Invalid value|INVALID_ARGUMENT|Unsupported|is not available in zone|was not found|does not exist|not compatible|incompatible' <<<"$e"; then echo unsupported
  else echo other
  fi
}

short_err() { grep -E 'ERROR|code|message|-' <<<"$1" | grep -v '^\s*$' | head -3 | tr '\n' ' ' | cut -c1-300; }

quota_name() { grep -oE "Quota '[A-Z0-9_-]+'|quota metric '[^']+'|[A-Z0-9_]*GPUS[A-Z0-9_]*" <<<"$1" | head -1; }

# 生成 create 命令参数（输出到全局数组 CREATE_ARGS）
build_create_args() {
  local name="$1" zone="$2" mt="$3" model="$4"
  local region; region="$(zone_region "$zone")"
  local nic="nic-type=GVNIC,network=${NETWORK},subnet=projects/${PROJECT}/regions/${region}/subnetworks/${SUBNET_OF[$region]}"
  [[ $NO_EXTERNAL_IP -eq 1 ]] && nic="${nic},no-address"
  CREATE_ARGS=(compute instances create "$name"
    --project="$PROJECT" --zone="$zone" --machine-type="$mt"
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT"
    --boot-disk-size="${DISK_SIZE}GB" --boot-disk-type="$(disk_type_for "$mt")"
    --network-interface="$nic"
    --maintenance-policy=TERMINATE
    --scopes=cloud-platform
    --metadata=install-nvidia-driver=True
    --labels="${LABEL_KEY}=${LABEL_VAL},grab-run=${RUN_ID//[^a-z0-9-]/},grab-model=${model}")
  [[ -n "$SERVICE_ACCOUNT" ]] && CREATE_ARGS+=(--service-account="$SERVICE_ACCOUNT")
  case "$model" in
    spot) CREATE_ARGS+=(--provisioning-model=SPOT --instance-termination-action=DELETE) ;;
    dws)  CREATE_ARGS+=(--provisioning-model=FLEX_START --max-run-duration="$DWS_MAX_RUN"
                        --request-valid-for-duration="$DWS_WAIT"
                        --instance-termination-action=DELETE --reservation-affinity=none --async) ;;
    ondemand) ;;
  esac
}

make_name() {
  local zone="$1" model="$2" m
  case "$model" in spot) m=s ;; ondemand) m=o ;; dws) m=d ;; esac
  echo "${NAME_PREFIX}-${zone}-${m}$(rand4)" | cut -c1-63
}

# 同步创建一次，结果写入文件：第一行 OK/类别，后续为输出
try_create_sync() {
  local zone="$1" mt="$2" model="$3" outfile="$4"
  local name; name="$(make_name "$zone" "$model")"
  build_create_args "$name" "$zone" "$mt" "$model"
  local out rc
  out="$(gcloud "${CREATE_ARGS[@]}" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    printf 'OK %s\n%s\n' "$name" "$out" >"$outfile"
  else
    printf '%s %s\n%s\n' "$(classify_error "$out")" "$name" "$out" >"$outfile"
  fi
}

# 处理一次同步尝试结果，成功返回 0
handle_sync_result() {
  local zone="$1" mt="$2" model="$3" outfile="$4"
  local region; region="$(zone_region "$zone")"
  local head kind name body
  head="$(head -1 "$outfile")"; kind="${head%% *}"; name="${head#* }"
  body="$(tail -n +2 "$outfile")"
  case "$kind" in
    OK)
      info "✅ 成功：$name  $zone  $mt  [$model]"
      if [[ -z "$WINNER" ]]; then WINNER="$name $zone $mt $model"; return 0; fi
      warn "已抢到其他 VM，删除多余的 $name"
      delete_vm "$name" "$zone"
      return 0 ;;
    stockout)
      info "  ✗ 无资源 $zone $mt [$model]" ;;
    quota)
      warn "  ✗ 配额不足 $region $mt [$model] $(quota_name "$body") —— 本次运行跳过该区域该机型该模式"
      SKIP["$region|$mt|$model"]="quota" ;;
    exists)
      info "  ✗ 名称冲突 $name，下轮重试" ;;
    unsupported)
      warn "  ✗ 不支持 $zone $mt [$model]：$(short_err "$body") —— 已剔除"
      SKIP["$zone|$mt|$model"]="unsupported" ;;
    fatal)
      err "权限/计费错误：$(short_err "$body")"
      cleanup_pending; exit 2 ;;
    *)
      warn "  ✗ 其他错误 $zone $mt [$model]：$(short_err "$body")" ;;
  esac
  return 1
}

is_skipped() {
  local zone="$1" mt="$2" model="$3" region; region="$(zone_region "$zone")"
  [[ -n "${SKIP["$zone|$mt|$model"]:-}" || -n "${SKIP["$region|$mt|$model"]:-}" ]]
}

# ---------- DWS（Flex-start）----------
dws_submit() {
  local zone="$1" mt="$2" key="$1|$2"
  local name; name="$(make_name "$zone" dws)"
  build_create_args "$name" "$zone" "$mt" dws
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] gcloud ${CREATE_ARGS[*]}"; return
  fi
  local out rc
  out="$(gcloud "${CREATE_ARGS[@]}" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    DWS_NAME[$key]="$name"
    DWS_OP[$key]="$(grep -oE 'operation-[A-Za-z0-9-]+' <<<"$out" | head -1)"
    info "  ⏳ DWS 已提交排队 $name  $zone $mt（最长等待 $DWS_WAIT）"
  else
    local kind; kind="$(classify_error "$out")"
    local region; region="$(zone_region "$zone")"
    case "$kind" in
      quota)
        # 本脚本自己排队中的请求也可能占用配额，若同区域有排队请求则仅退避
        if dws_region_has_pending "$region"; then
          info "  ✗ DWS 配额暂不足 $zone $mt（同区域已有排队请求），稍后重试"; DWS_BACKOFF[$key]=5
        else
          warn "  ✗ DWS 配额不足 $region $mt $(quota_name "$out") —— 本次运行跳过"; SKIP["$region|$mt|dws"]=quota
        fi ;;
      unsupported) warn "  ✗ DWS 不支持 $zone $mt：$(short_err "$out") —— 已剔除"; SKIP["$zone|$mt|dws"]=unsupported ;;
      fatal) err "权限/计费错误：$(short_err "$out")"; cleanup_pending; exit 2 ;;
      *) info "  ✗ DWS 提交失败 $zone $mt [$kind]：$(short_err "$out")"; DWS_BACKOFF[$key]=2 ;;
    esac
  fi
}

dws_region_has_pending() {
  local region="$1" k
  for k in "${!DWS_NAME[@]}"; do [[ "$(zone_region "${k%%|*}")" == "$region" ]] && return 0; done
  return 1
}

# 检查所有排队中的 DWS 请求；有 RUNNING 的返回 0
dws_poll() {
  local key zone mt name st op opst operr found=1
  for key in "${!DWS_NAME[@]}"; do
    zone="${key%%|*}"; mt="${key#*|}"; name="${DWS_NAME[$key]}"; op="${DWS_OP[$key]:-}"
    st="$(gcloud compute instances describe "$name" --zone="$zone" --project="$PROJECT" \
            --format='value(status)' 2>/dev/null)"
    if [[ "$st" == "RUNNING" ]]; then
      info "✅ DWS 成功：$name  $zone  $mt  [dws]"
      if [[ -z "$WINNER" ]]; then WINNER="$name $zone $mt dws"; else
        warn "已抢到其他 VM，删除多余的 $name"
        delete_vm "$name" "$zone"
      fi
      unset "DWS_NAME[$key]" "DWS_OP[$key]"; found=0; continue
    fi
    if [[ -n "$op" ]]; then
      read -r opst operr < <(gcloud compute operations describe "$op" --zone="$zone" --project="$PROJECT" \
            --format='value(status,error.errors[0].code)' 2>/dev/null)
      if [[ "$opst" == "DONE" && -n "$operr" ]]; then
        [[ -n "$st" ]] && delete_vm "$name" "$zone"
        unset "DWS_NAME[$key]" "DWS_OP[$key]"
        local region; region="$(zone_region "$zone")"
        case "$(classify_error "$operr")" in
          quota)
            if dws_region_has_pending "$region"; then
              info "  ✗ DWS 配额暂不足 $name $zone $mt（同区域已有排队请求），稍后重试"; DWS_BACKOFF[$key]=5
            else
              warn "  ✗ DWS 配额不足 $region $mt（$operr）—— 本次运行跳过"; SKIP["$region|$mt|dws"]=quota
            fi ;;
          unsupported)
            warn "  ✗ DWS 不支持 $zone $mt（$operr）—— 已剔除"; SKIP["$zone|$mt|dws"]=unsupported ;;
          fatal)
            err "DWS 权限/计费错误：$operr"; cleanup_pending; exit 2 ;;
          *)
            info "  ✗ DWS 请求结束未成功 $name $zone $mt：$operr，将重新提交" ;;
        esac
        continue
      fi
    fi
    if [[ "$st" == "TERMINATED" || "$st" == "STOPPED" ]]; then
      info "  ✗ DWS 实例 $name 状态 $st，删除后重新提交"
      delete_vm "$name" "$zone"
      unset "DWS_NAME[$key]" "DWS_OP[$key]"; continue
    fi
    if [[ -z "$st" && -z "$op" ]]; then
      unset "DWS_NAME[$key]" "DWS_OP[$key]"; continue
    fi
    info "  ⏳ DWS 排队中 $name $zone $mt ${st:+(status=$st)}"
  done
  return $found
}

# 删除本次运行中除赢家外的所有 VM / 排队请求
cleanup_pending() {
  [[ $DRY_RUN -eq 1 ]] && return
  local winner_name="${WINNER%% *}"
  local list n z
  list="$(gcloud compute instances list --project="$PROJECT" \
            --filter="labels.grab-run=${RUN_ID//[^a-z0-9-]/}" --format="value(name,zone.basename())" 2>/dev/null)"
  # 加上本地记录的排队请求（列表可能尚未显示）
  local key
  for key in "${!DWS_NAME[@]}"; do list+=$'\n'"${DWS_NAME[$key]} ${key%%|*}"; done
  while read -r n z; do
    [[ -z "$n" || "$n" == "$winner_name" ]] && continue
    info "清理本次运行的其他请求/VM：$n ($z)"
    delete_vm "$n" "$z"
  done < <(echo "$list" | sort -u)
  wait_deletes
}

on_interrupt() {
  echo
  warn "收到中断信号，清理排队中的 DWS 请求（已创建成功的 VM 不会删除）..."
  # 中断时保留已经 RUNNING 的 VM
  local key zone name st
  for key in "${!DWS_NAME[@]}"; do
    zone="${key%%|*}"; name="${DWS_NAME[$key]}"
    st="$(gcloud compute instances describe "$name" --zone="$zone" --project="$PROJECT" --format='value(status)' 2>/dev/null)"
    if [[ "$st" == "RUNNING" ]]; then
      warn "DWS 实例 $name 已 RUNNING，保留"; continue
    fi
    info "删除排队请求 $name ($zone)"
    delete_vm "$name" "$zone"
  done
  wait_deletes
  info "日志：$LOG_FILE"
  exit 130
}

print_winner() {
  local name zone mt model
  read -r name zone mt model <<<"$WINNER"
  echo
  echo "================================================================"
  echo "  🎉 抢到 GPU！"
  echo "  VM 名称   : $name"
  echo "  Zone      : $zone"
  echo "  机型      : $mt ($(machine_gpu_desc "$mt"))"
  echo "  计费模式  : $model"
  [[ "$model" == "dws" ]] && echo "  注意      : Flex-start VM 最长运行 $DWS_MAX_RUN，到期自动删除"
  [[ "$model" == "spot" ]] && echo "  注意      : Spot VM 可能随时被抢占（抢占后自动删除）"
  echo "  SSH       : gcloud compute ssh $name --zone=$zone --project=$PROJECT"
  echo "  验证 GPU  : gcloud compute ssh $name --zone=$zone --project=$PROJECT --command='nvidia-smi'"
  echo "  删除      : gcloud compute instances delete $name --zone=$zone --project=$PROJECT"
  echo "================================================================"
  echo "  日志：$LOG_FILE"
}

cmd_grab() {
  LOG_FILE="grab_gpu_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1

  info "运行 ID：$RUN_ID"
  info "项目：$PROJECT | 区域：$REGIONS | 模式：$MODELS"
  info "GPU：${MACHINE_TYPES:-$GPUS} | 卡数：$GPU_COUNT | 镜像：$IMAGE_PROJECT/$IMAGE_FAMILY"

  # 预检：镜像
  gcloud compute images describe-from-family "$IMAGE_FAMILY" --project="$IMAGE_PROJECT" \
    --format='value(name)' >/dev/null 2>&1 || die "镜像族不存在或无权限：$IMAGE_PROJECT/$IMAGE_FAMILY"

  # 预检：子网（未指定 --subnet 时自动选该网络在该区域的第一个子网）
  local r sn ok_regions=()
  for r in "${REGION_ARR[@]}"; do
    if [[ -n "$SUBNET" ]]; then
      sn="$(gcloud compute networks subnets describe "$SUBNET" --region="$r" --project="$PROJECT" \
              --format='value(name)' 2>/dev/null)"
    else
      sn="$(gcloud compute networks subnets list --project="$PROJECT" --network="$NETWORK" \
              --regions="$r" --format='value(name)' --limit=1 2>/dev/null)"
    fi
    if [[ -n "$sn" ]]; then
      SUBNET_OF[$r]="$sn"; ok_regions+=("$r")
      info "区域 $r 使用子网 $sn（网络 $NETWORK）"
    else
      warn "区域 $r 中找不到网络 $NETWORK 的子网${SUBNET:+ $SUBNET}，跳过该区域（可用 --network/--subnet 指定）"
    fi
  done
  [[ ${#ok_regions[@]} -gt 0 ]] || die "没有可用区域"
  REGION_ARR=("${ok_regions[@]}")

  # 发现候选
  local regex; regex="$(build_machine_regex)"
  local machines; machines="$(discover_machines "$regex")"
  [[ -n "$machines" ]] || die "所选区域中没有匹配的机型（regex: $regex）。可先运行 list 查看。"

  for r in "${REGION_ARR[@]}"; do
    grep -q "^$r-" <<<"$machines" || warn "区域 $r 没有匹配的机型"
  done

  # 候选：按 models 顺序展开
  local SYNC_CANDS=() DWS_CANDS=() z mt m
  for m in "${MODEL_ARR[@]}"; do
    while read -r z mt; do
      [[ -z "$z" ]] && continue
      model_supported "$mt" "$m" || continue
      if [[ "$m" == "dws" ]]; then DWS_CANDS+=("$z $mt"); else SYNC_CANDS+=("$z $mt $m"); fi
    done <<<"$machines"
  done
  info "候选：同步(ondemand/spot) ${#SYNC_CANDS[@]} 个，DWS ${#DWS_CANDS[@]} 个"
  local c; for c in "${SYNC_CANDS[@]}"; do echo "    - $c"; done
  for c in "${DWS_CANDS[@]}"; do echo "    - $c dws"; done

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 将执行的命令示例："
    for c in "${SYNC_CANDS[@]}"; do
      read -r z mt m <<<"$c"
      build_create_args "$(make_name "$z" "$m")" "$z" "$mt" "$m"
      echo "  gcloud ${CREATE_ARGS[*]}"
    done
    for c in "${DWS_CANDS[@]}"; do read -r z mt <<<"$c"; dws_submit "$z" "$mt"; done
    exit 0
  fi

  trap on_interrupt INT TERM

  local start round=0 tmpdir
  start="$(date +%s)"
  tmpdir="$(mktemp -d)"
  while :; do
    round=$((round + 1))
    info "========== 第 $round 轮 =========="

    # 1) DWS：检查排队状态 & 补交请求
    if [[ ${#DWS_CANDS[@]} -gt 0 ]]; then
      dws_poll
      if [[ -z "$WINNER" ]]; then
        for c in "${DWS_CANDS[@]}"; do
          read -r z mt <<<"$c"
          is_skipped "$z" "$mt" dws && continue
          [[ -n "${DWS_NAME["$z|$mt"]:-}" ]] && continue
          if [[ "${DWS_BACKOFF["$z|$mt"]:-0}" -gt 0 ]]; then
            DWS_BACKOFF["$z|$mt"]=$(( DWS_BACKOFF["$z|$mt"] - 1 )); continue
          fi
          dws_submit "$z" "$mt"
        done
      fi
    fi

    # 2) ondemand / spot：同步尝试（可并发）
    if [[ -z "$WINNER" ]]; then
      local batch=() i=0
      for c in "${SYNC_CANDS[@]}" ""; do
        if [[ -n "$c" ]]; then
          read -r z mt m <<<"$c"
          is_skipped "$z" "$mt" "$m" && continue
          batch+=("$c")
        fi
        if [[ ${#batch[@]} -ge $PARALLEL || ( -z "$c" && ${#batch[@]} -gt 0 ) ]]; then
          i=0
          local pids=()
          for b in "${batch[@]}"; do
            read -r z mt m <<<"$b"
            info "  → 尝试 $z $mt [$m]"
            try_create_sync "$z" "$mt" "$m" "$tmpdir/r$i" &
            pids+=($!)
            i=$((i + 1))
          done
          # 只等待本批创建进程（不能用裸 wait，否则会等待日志 tee 进程而卡死）
          wait "${pids[@]}"
          i=0
          for b in "${batch[@]}"; do
            read -r z mt m <<<"$b"
            handle_sync_result "$z" "$mt" "$m" "$tmpdir/r$i"
            i=$((i + 1))
          done
          batch=()
          [[ -n "$WINNER" ]] && break
        fi
      done
    fi

    # 3) 收尾判断
    if [[ -z "$WINNER" && ${#DWS_NAME[@]} -gt 0 ]]; then dws_poll; fi
    if [[ -n "$WINNER" ]]; then
      cleanup_pending
      rm -rf "$tmpdir"
      print_winner
      exit 0
    fi

    # 所有候选都被剔除
    local alive=0
    for c in "${SYNC_CANDS[@]}"; do read -r z mt m <<<"$c"; is_skipped "$z" "$mt" "$m" || { alive=1; break; }; done
    if [[ $alive -eq 0 ]]; then
      for c in "${DWS_CANDS[@]}"; do read -r z mt <<<"$c"; is_skipped "$z" "$mt" dws || { alive=1; break; }; done
    fi
    if [[ $alive -eq 0 ]]; then
      err "所有候选都因配额不足或不支持被跳过，退出。请检查配额（$SCRIPT_NAME list）或调整参数。"
      cleanup_pending; rm -rf "$tmpdir"; exit 3
    fi

    if [[ $TIMEOUT -gt 0 && $(( $(date +%s) - start )) -ge $TIMEOUT ]]; then
      warn "已达到超时 ${TIMEOUT}s，未抢到 GPU"
      cleanup_pending; rm -rf "$tmpdir"; exit 4
    fi
    info "等待 ${INTERVAL}s 进入下一轮（Ctrl-C 退出）"
    sleep "$INTERVAL"
  done
}

case "$CMD" in
  list)    cmd_list ;;
  grab)    cmd_grab ;;
  cleanup) cmd_cleanup ;;
  *) usage; exit 1 ;;
esac
