#!/usr/bin/env bash
# =============================================================================
# OSS lakeFS 本地 E2E：多 AK/SK + 只读访问密钥（read-only credential）
# =============================================================================
# 警告：本脚本会在标准输出打印完整 Secret Access Key 与命令原始输出，
#       仅适用于本地一次性 / 可丢弃环境。请勿将日志提交到公共位置。
#
# 前置：compose 已 up；库须为**未 setup**（否则 docker compose down -v）
#
# 依赖：curl、jq、perl；默认还会在**仓库根**执行 go build 生成 lakectl（需 Go 工具链）
#
# 环境变量：
#   LAKEFS_BASE_URL、ADMIN_USER
#   LAKECTL          未设置时默认 ${REPO_ROOT}/lakectl，并在脚本内 go build 生成；若已 export 为其它路径则不再编译
#   SKIP_LAKECTL_BUILD=1  强制不编译；此时 LAKECTL 必须指向已存在的可执行文件（未设置则仍默认仓库根 ./lakectl，须事先编好）
#   NO_COLOR=1          关闭本脚本中的 ANSI 颜色（与 lakectl 约定一致）
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"
BUILT_LAKECTL="${REPO_ROOT}/lakectl"

BASE_URL="${LAKEFS_BASE_URL:-http://127.0.0.1:8000}"
API="${BASE_URL}/api/v1"
ADMIN_USER="${ADMIN_USER:-admin}"
REPO_NAME="e2e-multi-ak-$(date +%s)"
STORAGE_NS="local://${REPO_NAME}"

# 最近一次外部命令的完整合并输出与退出码（供断言与报告）
LAST_OUTPUT=""
LAST_EXIT=0

# 终端且未设 NO_COLOR 时使用 ANSI；管道/重定向时自动无色
C_RESET=$'\033[0m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
c_init() {
	if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
		C_RESET=''
		C_RED=''
		C_GREEN=''
		C_YELLOW=''
		C_BLUE=''
		C_CYAN=''
		C_DIM=''
		C_BOLD=''
	fi
}
c_init

die() {
	printf '%b%b %s\n' "${C_RED}" "${C_BOLD}✖ ERROR:${C_RESET}" "${C_RED}${*}${C_RESET}" >&2
	exit 1
}
ok() { printf '%b %s\n' "${C_GREEN}[✓]${C_RESET}" "$*"; }
# 步骤标题（▶ 青色 + 粗体标题，便于扫日志）
step() { printf '\n%b▶%b %s\n' "${C_CYAN}" "${C_RESET}" "${C_BOLD}$*${C_RESET}"; }
# 子说明（期望/说明）
hint() { printf '%b    %s%b\n' "${C_DIM}" "$*" "${C_RESET}"; }
# 预期内的「负向」结果（如 exit≠0）
note_ok_expected_fail() { printf '%b %s\n' "${C_YELLOW}[! 预期失败]${C_RESET}" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need curl
need jq
need perl

strip_ansi() { perl -pe 's/\e\[[0-9;]*[mGK]//g'; }

raw_sep() {
	printf '\n%b%s%b\n' "${C_DIM}" "------------------------------------------------------------------------------" "${C_RESET}"
	printf '%b%s%b\n' "${C_BLUE}" "$*" "${C_RESET}"
	printf '%b%s%b\n' "${C_DIM}" "------------------------------------------------------------------------------" "${C_RESET}"
}

# 与在仓库根执行 `go build -o ./lakectl ./cmd/lakectl` 等价：产物为 ${REPO_ROOT}/lakectl
LAKECTL="${LAKECTL:-${BUILT_LAKECTL}}"
if [[ "${SKIP_LAKECTL_BUILD:-0}" != "1" ]] && [[ "${LAKECTL}" == "${BUILT_LAKECTL}" ]]; then
	need go
	raw_sep "编译 lakectl（仓库根: ${REPO_ROOT}）"
	echo "COMMAND: cd $(printf '%q' "${REPO_ROOT}") && go build -o ./lakectl ./cmd/lakectl"
	echo "（实际输出路径: $(printf '%q' "${BUILT_LAKECTL}")）"
	set +e
	build_log="$(cd "${REPO_ROOT}" && go build -o "${BUILT_LAKECTL}" ./cmd/lakectl 2>&1)"
	build_ec=$?
	set -e
	if [[ -n "${build_log}" ]]; then
		echo "--- go build stdout/stderr ---"
		printf '%s\n' "${build_log}"
	fi
	[[ "${build_ec}" -eq 0 ]] || die "go build lakectl 失败 exit=${build_ec}"
	[[ -x "${BUILT_LAKECTL}" ]] || die "未生成可执行文件: ${BUILT_LAKECTL}"
	echo "--- RAW: ${BUILT_LAKECTL} version ---"
	"${BUILT_LAKECTL}" version 2>&1 || true
fi

if [[ "${LAKECTL}" == */* ]]; then
	[[ -x "${LAKECTL}" ]] || die "LAKECTL 不可执行（去掉 SKIP_LAKECTL_BUILD 以自动编译，或 export LAKECTL=有效路径）: ${LAKECTL}"
else
	need "${LAKECTL}"
fi

# 执行 lakectl：打印完整环境（含明文 SK）、参数与合并 stdout/stderr；写入 LAST_OUTPUT / LAST_EXIT
lakectl_exec() {
	local ak="$1"
	local sk="$2"
	shift 2
	raw_sep "EXEC lakectl $*"
	echo "LAKECTL_SERVER_ENDPOINT_URL=${BASE_URL}"
	echo "LAKECTL_CREDENTIALS_ACCESS_KEY_ID=${ak}"
	echo "LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY=${sk}"
	echo "COMMAND: $(printf '%q ' "${LAKECTL}" "$@")"
	set +e
	LAST_OUTPUT="$(
		LAKECTL_SERVER_ENDPOINT_URL="${BASE_URL}" \
			LAKECTL_CREDENTIALS_ACCESS_KEY_ID="${ak}" \
			LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY="${sk}" \
			"${LAKECTL}" "$@" 2>&1
	)"
	LAST_EXIT=$?
	set -e
	echo "--- RAW OUTPUT (exit=${LAST_EXIT}) ---"
	printf '%s\n' "${LAST_OUTPUT}"
}

# 执行 curl：打印 URL/方法与 body；写入 LAST_OUTPUT / LAST_EXIT（HTTP 错误时 curl 可能非 0）
curl_exec() {
	raw_sep "EXEC curl $*"
	echo "COMMAND: curl $(printf '%q ' "$@")"
	set +e
	LAST_OUTPUT="$(curl "$@" 2>&1)"
	LAST_EXIT=$?
	set -e
	echo "--- RAW OUTPUT (exit=${LAST_EXIT}) ---"
	printf '%s\n' "${LAST_OUTPUT}"
}

count_access_keys_in_text() {
	printf '%s' "$1" | strip_ansi | grep -cE 'AKIAJ[A-Z2-7]{14}Q' || true
}

wait_ready() {
	local i out code
	for i in $(seq 1 90); do
		raw_sep "EXEC curl GET ${BASE_URL}/_health (attempt ${i}/90)"
		echo "COMMAND: curl -sS -o <stdout> -w HTTP_CODE:%{http_code} ${BASE_URL}/_health"
		set +e
		out="$(curl -sS -w "\nHTTP_CODE:%{http_code}" "${BASE_URL}/_health" 2>&1)"
		code=$?
		set -e
		LAST_OUTPUT="${out}"
		LAST_EXIT="${code}"
		echo "--- RAW OUTPUT (curl exit=${LAST_EXIT}) ---"
		printf '%s\n' "${LAST_OUTPUT}"
		if [[ "${out}" == *HTTP_CODE:200 ]]; then
			return 0
		fi
		sleep 1
	done
	die "lakeFS not healthy at ${BASE_URL}/_health (is compose up?)"
}

print_plan() {
	printf '\n%b%s%b\n' "${C_BLUE}" "================================================================================" "${C_RESET}"
	printf '%b  E2E 测试计划  %b\n' "${C_BLUE}${C_BOLD}" "${C_RESET}"
	printf '%b%s%b\n' "${C_BLUE}" "================================================================================" "${C_RESET}"
	cat <<EOF
  目标服务 : ${BASE_URL}
  仓库根   : ${REPO_ROOT}（默认在此 go build 生成 lakectl）
  lakectl  : ${LAKECTL}
  管理员   : ${ADMIN_USER}

  日志策略 : 每次 curl/lakectl 均打印完整命令侧信息 + 原始合并输出；Secret 不省略。
  结束     : 打印「执行报告」汇总密钥与步骤。

【本脚本会验证】(A)–(G) 同前版说明。

【本脚本不覆盖（需另测）】
  - S3 Gateway 签名访问、multipart、delete object 等
  - 除 repo list / branch list / repo create 外的其它 REST 写路径
  - 多用户 / 企业版 ACL
  - lakectl 与 server 版本不一致时的兼容性
EOF
	printf '%b%s%b\n' "${C_BLUE}" "================================================================================" "${C_RESET}"
}

ok() { echo "  [OK] $*"; }

print_final_report() {
	local ro_repo_status="未执行"
	if [[ -n "${REPO_RO:-}" ]]; then
		ro_repo_status="已尝试 lakefs://${REPO_RO}（只读 create 应失败）"
	fi
	printf '\n%b%s%b\n' "${C_GREEN}" "================================================================================" "${C_RESET}"
	printf '%b  执行报告 · 全部步骤已通过  %b\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
	printf '%b%s%b\n' "${C_GREEN}" "================================================================================" "${C_RESET}"
	cat <<EOF
  时间戳       : $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)
  BASE_URL     : ${BASE_URL}
  ADMIN_USER   : ${ADMIN_USER}
  测试仓库     : lakefs://${REPO_NAME}
  storage ns   : ${STORAGE_NS}
  只读拒绝仓库 : ${ro_repo_status}

--- 凭证（完整打印，勿泄露）---
  AK1 (setup)  : ${AK1}
  SK1          : ${SK1}
  AK2 (可写)   : ${AK2}
  SK2          : ${SK2}
  AK_RO (只读) : ${AK_RO}
  SK_RO        : ${SK_RO}

--- 计数校验结果 ---
  步骤[4]  凭证条数 期望=1 实际=${c1}
  步骤[6]  凭证条数 期望=2 实际=${c2}
  步骤[10] 凭证条数 期望=3 实际=${c_ro}
  步骤[12] 删只读后 期望=2 实际=${c_mid}
  步骤[13] 删 AK2 后 期望=1 实际=${c3}

--- 步骤索引 ---
  [1] _health 就绪  [2] setup 状态  [3] setup POST
  [4] list=1  [5] create AK2  [6] list=2  [7] repo create
  [8] AK2 repo/branch list  [9] create read-only  [10] list=3
  [11] RO list OK / RO repo create fail  [12] delete RO  [13] delete AK2
  [14] AK2 吊销验证  [15] AK1 branch list

  复现 lakectl（AK1）:
    LAKECTL_SERVER_ENDPOINT_URL=${BASE_URL} \\
    LAKECTL_CREDENTIALS_ACCESS_KEY_ID='${AK1}' \\
    LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY='${SK1}' \\
    ${LAKECTL} auth users credentials list --id ${ADMIN_USER} --no-color

  清理卷: cd ${ROOT_DIR} && docker compose down -v
EOF
	printf '%b%s%b\n' "${C_GREEN}" "================================================================================" "${C_RESET}"
}

# -----------------------------------------------------------------------------
print_plan

step "[1] 等待 lakeFS 就绪"
hint "期望: GET ${BASE_URL}/_health 最终 HTTP 200"
wait_ready
ok "_health 可用"

step "[2] 检查 setup 状态（须为未初始化）"
hint "期望: state 非 initialized（否则需 docker compose down -v）"
curl_exec -sS "${API}/setup_lakefs"
state=$(printf '%s' "${LAST_OUTPUT}" | jq -r '.state // empty')
if [[ "${state}" == "initialized" ]]; then
	die "lakeFS 已是 initialized；请: docker compose down -v 后重试"
fi
ok "state=${state:-<empty>}，可执行首次 setup"

step "[3] 首次 setup（curl POST）"
hint "期望: JSON 含 access_key_id / secret_access_key（即 AK1/SK1）"
raw_sep "EXEC curl POST ${API}/setup_lakefs"
setup_body="{\"username\":\"${ADMIN_USER}\"}"
echo "REQUEST_BODY: ${setup_body}"
echo "COMMAND: curl -sS -X POST -H Content-Type: application/json -d ${setup_body} ${API}/setup_lakefs"
set +e
LAST_OUTPUT="$(curl -sS -X POST "${API}/setup_lakefs" -H "Content-Type: application/json" -d "${setup_body}" 2>&1)"
LAST_EXIT=$?
set -e
echo "--- RAW OUTPUT (exit=${LAST_EXIT}) ---"
printf '%s\n' "${LAST_OUTPUT}"
[[ "${LAST_EXIT}" -eq 0 ]] || die "setup POST 非 0 退出: ${LAST_EXIT}"
setup_json="${LAST_OUTPUT}"
AK1=$(printf '%s' "${setup_json}" | jq -r .access_key_id)
SK1=$(printf '%s' "${setup_json}" | jq -r .secret_access_key)
[[ -n "${AK1}" && "${AK1}" != "null" ]] || die "setup 未返回 access_key_id"
[[ -n "${SK1}" && "${SK1}" != "null" ]] || die "setup 未返回 secret_access_key"
ok "AK1=${AK1} SK1=${SK1}"

step "[4] 凭证列表条数 = 1"
hint "期望: 输出中含 1 个 AKIAJ...Q"
lakectl_exec "${AK1}" "${SK1}" auth users credentials list --id "${ADMIN_USER}" --amount 50 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "list credentials 失败 exit=${LAST_EXIT}"
c1=$(count_access_keys_in_text "${LAST_OUTPUT}")
[[ "${c1}" == "1" ]] || die "期望 1 条，实际 ${c1}"
ok "凭证条数: 期望=1 实际=${c1}"

step "[5] 创建第二把可写 AK"
hint "期望: 返回与 AK1 不同的 AK2/SK2"
lakectl_exec "${AK1}" "${SK1}" auth users credentials create --id "${ADMIN_USER}" --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "create credentials 失败 exit=${LAST_EXIT}"
create_out=$(printf '%s' "${LAST_OUTPUT}" | strip_ansi)
AK2=$(printf '%s' "${create_out}" | grep -oE 'AKIAJ[A-Z2-7]{14}Q' | head -1)
SK2=$(printf '%s' "${create_out}" | perl -ne 'print $1 if /Secret Access Key:\s*(\S+)/')
[[ -n "${AK2}" ]] || die "未能解析 AK2"
[[ -n "${SK2}" ]] || die "未能解析 SK2"
[[ "${AK2}" != "${AK1}" ]] || die "AK2 不应与 AK1 相同"
ok "AK2=${AK2} SK2=${SK2}"

step "[6] 凭证列表条数 = 2"
hint "期望: 输出中含 2 个 AKIAJ...Q"
lakectl_exec "${AK1}" "${SK1}" auth users credentials list --id "${ADMIN_USER}" --amount 50 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "list credentials 失败 exit=${LAST_EXIT}"
c2=$(count_access_keys_in_text "${LAST_OUTPUT}")
[[ "${c2}" == "2" ]] || die "期望 2 条，实际 ${c2}"
ok "凭证条数: 期望=2 实际=${c2}"

step "[7] 用 AK1 创建测试仓库"
hint "期望: lakectl repo create exit=0"
lakectl_exec "${AK1}" "${SK1}" repo create "lakefs://${REPO_NAME}" "${STORAGE_NS}" -d main
[[ "${LAST_EXIT}" -eq 0 ]] || die "repo create 失败 exit=${LAST_EXIT}"
ok "仓库 lakefs://${REPO_NAME} 已创建"

step "[8] 用 AK2 验证读权限"
hint "期望: repo list / branch list 均成功且含本仓库与 main"
lakectl_exec "${AK2}" "${SK2}" repo list --amount 100 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "AK2 repo list 失败 exit=${LAST_EXIT}"
printf '%s' "${LAST_OUTPUT}" | strip_ansi | grep -qF "${REPO_NAME}" || die "AK2 repo list 未包含 ${REPO_NAME}"
ok "AK2 repo list 含 ${REPO_NAME}"

lakectl_exec "${AK2}" "${SK2}" branch list "lakefs://${REPO_NAME}" --amount 50 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "AK2 branch list 失败 exit=${LAST_EXIT}"
printf '%s' "${LAST_OUTPUT}" | strip_ansi | grep -qF "main" || die "AK2 branch list 未见 main"
ok "AK2 branch list 含 main"

step "[9] 创建只读 AK（--read-only）"
hint "期望: 返回 AK_RO/SK_RO，且与 AK1/AK2 不同"
lakectl_exec "${AK1}" "${SK1}" auth users credentials create --id "${ADMIN_USER}" --read-only --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "create read-only 失败 exit=${LAST_EXIT}"
create_ro=$(printf '%s' "${LAST_OUTPUT}" | strip_ansi)
AK_RO=$(printf '%s' "${create_ro}" | grep -oE 'AKIAJ[A-Z2-7]{14}Q' | head -1)
SK_RO=$(printf '%s' "${create_ro}" | perl -ne 'print $1 if /Secret Access Key:\s*(\S+)/')
[[ -n "${AK_RO}" ]] || die "未能解析只读 AK"
[[ -n "${SK_RO}" ]] || die "未能解析只读 SK"
ok "AK_RO=${AK_RO} SK_RO=${SK_RO}"

step "[10] 凭证列表条数 = 3"
hint "期望: 输出中含 3 个 AKIAJ...Q"
lakectl_exec "${AK1}" "${SK1}" auth users credentials list --id "${ADMIN_USER}" --amount 50 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "list credentials 失败 exit=${LAST_EXIT}"
c_ro=$(count_access_keys_in_text "${LAST_OUTPUT}")
[[ "${c_ro}" == "3" ]] || die "期望 3 条，实际 ${c_ro}"
ok "凭证条数: 期望=3 实际=${c_ro}"

step "[11] 只读 AK：repo list 成功；repo create 须失败"
hint "期望: list 成功；create 须非 0 退出"
lakectl_exec "${AK_RO}" "${SK_RO}" repo list --amount 100 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "只读 AK repo list 失败 exit=${LAST_EXIT}"
printf '%s' "${LAST_OUTPUT}" | strip_ansi | grep -qF "${REPO_NAME}" || die "只读 repo list 未包含 ${REPO_NAME}"
ok "只读 AK repo list 含 ${REPO_NAME}"

REPO_RO="e2e-ro-deny-$(date +%s)"
note_ok_expected_fail "负向用例：只读凭证不应能 create repo"
lakectl_exec "${AK_RO}" "${SK_RO}" repo create "lakefs://${REPO_RO}" "local://${REPO_RO}" -d main --no-color
if [[ "${LAST_EXIT}" -eq 0 ]]; then
	die "只读 AK 不应 repo create 成功（exit=0）。原始输出已打印在上文。"
fi
note_ok_expected_fail "只读 AK repo create 失败 exit=${LAST_EXIT}（符合预期）"

step "[12] 删除只读 AK"
hint "期望: delete 成功；list 后条数回到 2"
lakectl_exec "${AK1}" "${SK1}" auth users credentials delete --id "${ADMIN_USER}" --access-key-id "${AK_RO}"
[[ "${LAST_EXIT}" -eq 0 ]] || die "delete AK_RO 失败 exit=${LAST_EXIT}"

lakectl_exec "${AK1}" "${SK1}" auth users credentials list --id "${ADMIN_USER}" --amount 50 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "list credentials 失败 exit=${LAST_EXIT}"
c_mid=$(count_access_keys_in_text "${LAST_OUTPUT}")
[[ "${c_mid}" == "2" ]] || die "删只读后期望 2 条，实际 ${c_mid}"
ok "已删 AK_RO；凭证条数: 期望=2 实际=${c_mid}"

step "[13] 删除第二把可写 AK2"
hint "期望: delete 成功；list 后条数回到 1"
lakectl_exec "${AK1}" "${SK1}" auth users credentials delete --id "${ADMIN_USER}" --access-key-id "${AK2}"
[[ "${LAST_EXIT}" -eq 0 ]] || die "delete AK2 失败 exit=${LAST_EXIT}"

lakectl_exec "${AK1}" "${SK1}" auth users credentials list --id "${ADMIN_USER}" --amount 50 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "list credentials 失败 exit=${LAST_EXIT}"
c3=$(count_access_keys_in_text "${LAST_OUTPUT}")
[[ "${c3}" == "1" ]] || die "删 AK2 后期望 1 条，实际 ${c3}"
ok "已删 AK2；凭证条数: 期望=1 实际=${c3}"

step "[14] 吊销验证：已删 AK2 不可再用"
hint "期望: 已删 AK2 调用 lakectl 须非 0 退出"
note_ok_expected_fail "负向用例：吊销后的 AK2 不可再用"
lakectl_exec "${AK2}" "${SK2}" repo list --amount 5 --no-color
if [[ "${LAST_EXIT}" -eq 0 ]]; then
	die "已删除的 AK2 仍返回 exit=0。原始输出已打印在上文。"
fi
note_ok_expected_fail "AK2 repo list 失败 exit=${LAST_EXIT}（符合预期）"

step "[15] 回归：主 AK1 branch list"
hint "期望: AK1 仍可 branch list"
lakectl_exec "${AK1}" "${SK1}" branch list "lakefs://${REPO_NAME}" --amount 10 --no-color
[[ "${LAST_EXIT}" -eq 0 ]] || die "AK1 branch list 失败 exit=${LAST_EXIT}"
ok "AK1 branch list 成功"

print_final_report
