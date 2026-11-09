#!/bin/sh
# CodeBuddy Context Window Patch — 卸载脚本
# 还原 apply.sh 的全部改动。
#
# 2.181.0 起补丁 B 的会话变量名逐版本重排（2.168.2 为 eh/eg，2.181.0 为 eg/eh），
# 无法从补丁态反推原串，故 apply.sh 把被替换的原文记入
# .context-window-patch-state.json，本脚本按该文件精确还原。
# 状态文件缺失时拒绝改 bundle，改为提示按同版本重装。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE="$SCRIPT_DIR/.context-window-patch-state.json"

log() { printf '%s\n' "$*"; }

detect_root() {
    if [ -n "${CODEBUDDY_ROOT:-}" ]; then printf '%s\n' "$CODEBUDDY_ROOT"; return; fi
    for r in \
        "$(npm root -g 2>/dev/null || true)/@tencent-ai/codebuddy-code" \
        "$HOME/.local/lib/node_modules/@tencent-ai/codebuddy-code" \
        "/usr/local/lib/node_modules/@tencent-ai/codebuddy-code" \
        "${PREFIX:-/usr}/lib/node_modules/@tencent-ai/codebuddy-code"
    do
        if [ -f "$r/bin/codebuddy" ]; then printf '%s\n' "$r"; return; fi
    done
    printf '%s\n' "/usr/local/lib/node_modules/@tencent-ai/codebuddy-code"
}

CB_ROOT=$(detect_root)
BIN="$CB_ROOT/bin/codebuddy"
BUNDLE="$CB_ROOT/dist/codebuddy.js"

# ---------------------------------------------------------------- 1) bin/codebuddy
if grep -q 'codebuddy-context-window patch' "$BIN" 2>/dev/null; then
    python3 - "$BIN" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
start = "// >>> codebuddy-context-window patch"
end = "// <<< codebuddy-context-window patch\n\n"
i = src.find(start)
j = src.find(end)
if i == -1 or j == -1:
    sys.exit("✗ 未找到 patch 块边界，放弃")
open(path, 'w', encoding='utf-8').write(src[:i] + src[j + len(end):])
print("[1/3] bin/codebuddy 已还原")
PY
else
    log "[1/3] bin/codebuddy 无补丁，跳过"
fi

# ---------------------------------------------------------------- 2) dist/codebuddy.js
if [ -f "$STATE" ]; then
    python3 - "$BUNDLE" "$STATE" <<'PY'
import json, os, sys

bundle_path, state_path = sys.argv[1], sys.argv[2]
state = json.load(open(state_path, encoding='utf-8'))
original, patched = state["original"], state["patched"]

src = open(bundle_path, encoding='utf-8').read()
n = src.count(patched)
if n != 1:
    sys.exit(f"✗ 补丁串出现 {n} 次（期望 1）。可能已被升级覆盖或重复打过补丁，放弃。\n"
             f"  当前安装版本为原厂时无需还原。")

tmp = bundle_path + ".ctxpatch.tmp"
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(src.replace(patched, original, 1))
os.chmod(tmp, os.stat(bundle_path).st_mode)
os.replace(tmp, bundle_path)
print("[2/3] dist/codebuddy.js 已还原原始调用点")
PY
    rm -f "$STATE"
else
    log "[2/3] 无状态文件，跳过 bundle 还原"
    if ! grep -qF '.isSubAgent(eh)||eh===eg||await this.seedContextWindow(eh)' "$BUNDLE" 2>/dev/null \
       && grep -qF 'seedContextWindow' "$BUNDLE"; then
        log "    如需彻底还原 bundle：npm i -g @tencent-ai/codebuddy-code@$(node -p "require('$CB_ROOT/package.json').version" 2>/dev/null || echo latest)"
    fi
fi

# ---------------------------------------------------------------- 3) ~/bin wrapper
WBIN="$HOME/bin"
removed=0
for f in codebuddy cbc codebuddy-code; do
    if [ -e "$WBIN/$f" ] || [ -L "$WBIN/$f" ]; then
        rm -f "$WBIN/$f"; removed=1
    fi
done
if [ "$removed" = 1 ]; then log "[3/3] ~/bin wrapper 已删除"; else log "[3/3] ~/bin 无 wrapper，跳过"; fi

log ""
log "✓ 卸载完成。重启 CodeBuddy 后恢复服务端默认档（300k）。"
