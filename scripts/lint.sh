#!/usr/bin/env bash
# =============================================================================
# CISLC-O3 静态检查入口（棘轮第一格齿）
#
# 这一步只回答一个问题：**当前 RTL 能不能过 verilator 的前端解析**。
# 它不回答：功能是否正确、时序是否收敛、能不能上板。
#
# 用法：
#   scripts/lint.sh              # 检查 o3_core 编译单元
#   scripts/lint.sh --strict     # 把 warning 也当作失败
#
# 退出码：0 = 通过；非 0 = 失败（失败时打印错误上下文）。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERILATOR="${VERILATOR:-verilator}"
FILELIST="rtl/rtl.f"
TOP="${TOP:-o3_core}"

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

if ! command -v "$VERILATOR" >/dev/null 2>&1; then
    echo "[lint] 找不到 verilator（可用 VERILATOR 环境变量指定路径）" >&2
    exit 127
fi

echo "[lint] verilator : $("$VERILATOR" --version | head -1)"
echo "[lint] filelist  : $FILELIST"
echo "[lint] top       : $TOP"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# -Wno-fatal：warning 不升级为 error；--lint-only：只做解析，不生成模型。
"$VERILATOR" --lint-only -Wno-fatal -f "$FILELIST" --top-module "$TOP" >"$LOG" 2>&1
rc=$?

errors=$(grep -cE '^%Error' "$LOG" || true)
warnings=$(grep -cE '^%Warning' "$LOG" || true)

echo "[lint] errors=$errors warnings=$warnings"

if [[ "$errors" -gt 0 ]]; then
    echo "[lint] FAIL —— 错误上下文：" >&2
    grep -E '^%Error' -A4 "$LOG" >&2
    exit 1
fi

if [[ "$STRICT" -eq 1 && "$warnings" -gt 0 ]]; then
    echo "[lint] FAIL（--strict）—— 存在 warning：" >&2
    grep -E '^%Warning' -A4 "$LOG" | head -60 >&2
    exit 1
fi

if [[ "$rc" -ne 0 ]]; then
    echo "[lint] FAIL —— verilator 退出码 $rc（无 %Error 行，需人工查看）" >&2
    tail -40 "$LOG" >&2
    exit 1
fi

echo "[lint] PASS —— RTL 解析通过（不代表功能正确）"
exit 0
