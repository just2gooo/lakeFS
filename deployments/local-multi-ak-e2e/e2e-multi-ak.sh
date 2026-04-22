#!/usr/bin/env bash
# 端到端：compose 启动后，用 lakectl 验证多 AK/SK（list / create / delete）及仓库操作。
# 首次 setup 仍用 curl+jq（尚无凭证时 lakectl 无法调 setup API）。
#
# 依赖：lakectl、curl、jq、perl（用于去掉 lakectl 着色以便解析 create 输出）
#
# 可选环境变量：
#   LAKEFS_BASE_URL  默认 http://127.0.0.1:8000
#   ADMIN_USER       首次 setup 的用户名，默认 admin
#   LAKECTL          lakectl 可执行文件路径，默认在 PATH 中查找

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${LAKEFS_BASE_URL:-http://127.0.0.1:8000}"
API="${BASE_URL}/api/v1"
ADMIN_USER="${ADMIN_USER:-admin}"
LAKECTL="${LAKECTL:-lakectl}"
REPO_NAME="e2e-multi-ak-$(date +%s)"
STORAGE_NS="local://${REPO_NAME}"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need curl
need jq
need perl
if [[ "${LAKECTL}" == */* ]]; then
	[[ -x "${LAKECTL}" ]] || die "LAKECTL 不可执行: ${LAKECTL}"
else
	need "${LAKECTL}"
fi

# 去掉 ANSI 颜色，便于从 lakectl 文本输出里解析 Access Key / Secret。
strip_ansi() { perl -pe 's/\e\[[0-9;]*[mGK]//g'; }

# 使用指定 AK/SK 调用 lakectl（通过 LAKECTL_* 环境变量，不写配置文件）。
lakectl_as() {
	local ak="$1"
	local sk="$2"
	shift 2
	LAKECTL_SERVER_ENDPOINT_URL="${BASE_URL}" \
		LAKECTL_CREDENTIALS_ACCESS_KEY_ID="${ak}" \
		LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY="${sk}" \
		"${LAKECTL}" "$@"
}

# 统计 list 输出中的 Access Key 行数（lakeFS 生成的 key 形如 AKIAJ + 14 位 + Q）。
count_access_keys_in_list() {
	local ak="$1"
	local sk="$2"
	lakectl_as "${ak}" "${sk}" auth users credentials list --id "${ADMIN_USER}" --amount 50 --no-color 2>&1 \
		| strip_ansi | grep -cE 'AKIAJ[A-Z2-7]{14}Q' || true
}

wait_ready() {
	local i
	for i in $(seq 1 90); do
		if curl -sf "${BASE_URL}/_health" >/dev/null; then
			return 0
		fi
		sleep 1
	done
	die "lakeFS not healthy at ${BASE_URL}/_health (is compose up?)"
}

echo "==> 等待 lakeFS 就绪: ${BASE_URL}"
wait_ready

echo "==> 检查是否已 setup（curl）"
state=$(curl -sfS "${API}/setup_lakefs" | jq -r '.state // empty')
if [[ "${state}" == "initialized" ]]; then
	die "lakeFS 已是 initialized 状态；请 \`docker compose down -v\` 后重试以得到干净库。"
fi

echo "==> 首次 setup 用户: ${ADMIN_USER}（curl）"
setup_json=$(curl -sfS -X POST "${API}/setup_lakefs" -H "Content-Type: application/json" -d "{\"username\":\"${ADMIN_USER}\"}")
AK1=$(echo "${setup_json}" | jq -r .access_key_id)
SK1=$(echo "${setup_json}" | jq -r .secret_access_key)
[[ -n "${AK1}" && "${AK1}" != "null" ]] || die "setup 未返回 access_key_id: ${setup_json}"
[[ -n "${SK1}" && "${SK1}" != "null" ]] || die "setup 未返回 secret_access_key"
echo "    初始 Access Key: ${AK1}"

echo "==> lakectl: list credentials（应 1 条）"
c1=$(count_access_keys_in_list "${AK1}" "${SK1}")
[[ "${c1}" == "1" ]] || die "list 期望 1 条 access key，得到 ${c1}。输出如下：$(lakectl_as "${AK1}" "${SK1}" auth users credentials list --id "${ADMIN_USER}" --no-color 2>&1 | strip_ansi)"

echo "==> lakectl: create 第二对 credentials"
create_out=$(lakectl_as "${AK1}" "${SK1}" auth users credentials create --id "${ADMIN_USER}" --no-color 2>&1 | strip_ansi)
AK2=$(echo "${create_out}" | grep -oE 'AKIAJ[A-Z2-7]{14}Q' | head -1)
SK2=$(echo "${create_out}" | perl -ne 'print $1 if /Secret Access Key:\s*(\S+)/')
[[ -n "${AK2}" ]] || die "未能从 lakectl create 输出解析 access key。输出:\n${create_out}"
[[ -n "${SK2}" ]] || die "未能从 lakectl create 输出解析 secret key。输出:\n${create_out}"
echo "    第二 Access Key: ${AK2}"

echo "==> lakectl: list credentials（应 2 条）"
c2=$(count_access_keys_in_list "${AK1}" "${SK1}")
[[ "${c2}" == "2" ]] || die "list 期望 2 条，得到 ${c2}"

echo "==> lakectl: 使用 AK1 创建仓库 ${REPO_NAME}"
lakectl_as "${AK1}" "${SK1}" repo create "lakefs://${REPO_NAME}" "${STORAGE_NS}" -d main

echo "==> lakectl: 使用 AK2 列出仓库并确认包含 ${REPO_NAME}"
repos=$(lakectl_as "${AK2}" "${SK2}" repo list --amount 100 --no-color 2>&1 | strip_ansi)
echo "${repos}" | grep -qF "${REPO_NAME}" || die "AK2 repo list 未看到 ${REPO_NAME}"

echo "==> lakectl: 使用 AK2 列出分支 main"
br=$(lakectl_as "${AK2}" "${SK2}" branch list "lakefs://${REPO_NAME}" --amount 50 --no-color 2>&1 | strip_ansi)
echo "${br}" | grep -qF "main" || die "AK2 branch list 未看到 main"

echo "==> lakectl: 使用 AK1 删除第二把 key（${AK2}）"
lakectl_as "${AK1}" "${SK1}" auth users credentials delete --id "${ADMIN_USER}" --access-key-id "${AK2}"

echo "==> lakectl: list credentials（应回到 1 条）"
c3=$(count_access_keys_in_list "${AK1}" "${SK1}")
[[ "${c3}" == "1" ]] || die "list 期望 1 条，得到 ${c3}"

echo "==> lakectl: 已吊销的 AK2 调用 repo list（应失败）"
if lakectl_as "${AK2}" "${SK2}" repo list --amount 5 --no-color >/dev/null 2>&1; then
	die "已吊销的 AK2 仍能访问 API"
fi
echo "    （预期）AK2 请求失败"

echo "==> lakectl: 使用 AK1 仍可 list 分支"
lakectl_as "${AK1}" "${SK1}" branch list "lakefs://${REPO_NAME}" --amount 10 --no-color >/dev/null

echo ""
echo "全部通过。"
echo "  lakectl 示例: LAKECTL_SERVER_ENDPOINT_URL=${BASE_URL} LAKECTL_CREDENTIALS_ACCESS_KEY_ID='...' LAKECTL_CREDENTIALS_SECRET_ACCESS_KEY='...' ${LAKECTL} auth users credentials list --id ${ADMIN_USER}"
echo "  清理卷: 在 ${ROOT_DIR} 执行 docker compose down -v"
