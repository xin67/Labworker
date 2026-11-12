#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Labworker 文档与代码数字单一来源校验脚本 (P01: Single Source of Truth Checker)
# 提取 CloneStudioVerify 与 clonestudio_mcp_server.py 的三个真实计数值：
#   1. 测试通过总数 (tests)
#   2. MCP 工具总数 (tools)
#   3. 导航模块总数 (modules)
# 并与 README.md / ARCHITECTURE.md 中的声明比对，任何不一致均以非 0 状态码退出。
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "🔍 [check_doc_counts] Running CloneStudioVerify to extract ground-truth counts..."
VERIFY_OUTPUT="$(swift run --disable-sandbox CloneStudioVerify)"

COUNTS_LINE="$(echo "$VERIFY_OUTPUT" | grep -E '^COUNTS tests=[0-9]+ tools=[0-9]+ modules=[0-9]+$' | tail -n 1 || true)"
if [[ -z "$COUNTS_LINE" ]]; then
    echo "❌ Error: CloneStudioVerify did not emit machine-readable COUNTS line." >&2
    exit 1
fi

TRUE_TESTS="$(echo "$COUNTS_LINE" | sed -E 's/.*tests=([0-9]+).*/\1/')"
TRUE_TOOLS="$(echo "$COUNTS_LINE" | sed -E 's/.*tools=([0-9]+).*/\1/')"
TRUE_MODULES="$(echo "$COUNTS_LINE" | sed -E 's/.*modules=([0-9]+).*/\1/')"

BANNER_TESTS="$(echo "$VERIFY_OUTPUT" | grep -E 'ALL [0-9]+ AUTOMATED VERIFICATION TESTS PASSED' | sed -E 's/.*ALL ([0-9]+) AUTOMATED.*/\1/' | tail -n 1 || true)"
PASS_LINES_COUNT="$(echo "$VERIFY_OUTPUT" | grep -c '✅' || true)"
PY_MCP_TOOLS="$(/usr/bin/python3 Sources/CloneStudioCore/Resources/clonestudio_mcp_server.py --count-tools | tr -d '[:space:]')"

echo "   📊 Ground Truth -> tests=${TRUE_TESTS} (banner=${BANNER_TESTS}, pass_lines=${PASS_LINES_COUNT}), tools=${TRUE_TOOLS} (python=${PY_MCP_TOOLS}), modules=${TRUE_MODULES}"

if [[ "$TRUE_TESTS" != "$BANNER_TESTS" || "$TRUE_TESTS" != "$PASS_LINES_COUNT" ]]; then
    echo "❌ Mismatch inside CloneStudioVerify: tests=${TRUE_TESTS}, banner=${BANNER_TESTS}, pass_lines=${PASS_LINES_COUNT}" >&2
    exit 1
fi

if [[ "$TRUE_TOOLS" != "$PY_MCP_TOOLS" ]]; then
    echo "❌ Mismatch between Verify tools (${TRUE_TOOLS}) and clonestudio_mcp_server.py --count-tools (${PY_MCP_TOOLS})" >&2
    exit 1
fi

# 使用 Python 精确校验 README.md 与 ARCHITECTURE.md 中的所有数字引用
/usr/bin/python3 - "$TRUE_TESTS" "$TRUE_TOOLS" "$TRUE_MODULES" <<'PYEOF'
import re
import sys

true_tests = int(sys.argv[1])
true_tools = int(sys.argv[2])
true_modules = int(sys.argv[3])

errors = []

with open("README.md", "r", encoding="utf-8") as f:
    readme = f.read()

with open("ARCHITECTURE.md", "r", encoding="utf-8") as f:
    arch = f.read()

# 1. 校验 README.md 中的测试数量声明 (如 "38 项端到端自动化验证测试"、"运行全部 38 项自动化验证测试")
test_mentions = [int(m) for m in re.findall(r'(\d+)\s*项(?:端到端)?自动化验证测试', readme)]
if not test_mentions:
    errors.append("README.md missing 'N 项自动化验证测试' declaration.")
for val in test_mentions:
    if val != true_tests:
        errors.append(f"README.md test count mismatch: found {val}, expected {true_tests}")

# 2. 校验 README.md 与 ARCHITECTURE.md 中的 MCP 工具数量声明
readme_tool_mentions = [int(m) for m in re.findall(r'(\d+)\s*(?:个全栈实验工具|项工具清单|大工具清单|个\s*MCP\s*工具)', readme)]
if not readme_tool_mentions:
    errors.append("README.md missing MCP tool count declarations.")
for val in readme_tool_mentions:
    if val != true_tools:
        errors.append(f"README.md MCP tool count mismatch: found {val}, expected {true_tools}")

arch_tool_mentions = [int(m) for m in re.findall(r'\((\d+)\s*工具\)', arch)]
if not arch_tool_mentions:
    errors.append("ARCHITECTURE.md missing '(N 工具)' declaration.")
for val in arch_tool_mentions:
    if val != true_tools:
        errors.append(f"ARCHITECTURE.md MCP tool count mismatch: found {val}, expected {true_tools}")

# 3. 校验 README.md 与 ARCHITECTURE.md 中的模块总数声明
readme_mod_mentions = [int(m) for m in re.findall(r'(\d+)\s*个(?:功能)?模块', readme)]
if not readme_mod_mentions:
    errors.append("README.md missing module count declarations.")
for val in readme_mod_mentions:
    if val != true_modules:
        errors.append(f"README.md module count mismatch: found {val}, expected {true_modules}")

arch_mod_mentions = [int(m) for m in re.findall(r'(\d+)\s*模块', arch)]
if not arch_mod_mentions:
    errors.append("ARCHITECTURE.md missing 'N 模块' declaration.")
for val in arch_mod_mentions:
    if val != true_modules:
        errors.append(f"ARCHITECTURE.md module count mismatch: found {val}, expected {true_modules}")

if errors:
    for e in errors:
        print(f"❌ {e}", file=sys.stderr)
    sys.exit(1)

print(f"✅ [check_doc_counts] All document counts match ground truth (tests={true_tests}, tools={true_tools}, modules={true_modules}).")
PYEOF
