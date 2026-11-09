#!/bin/sh
# CodeBuddy Context Window Patch — 应用脚本（幂等，可重复执行）
#
# 把 deepseek-v4.1-flash 的上下文预算从服务端默认 300k 提升到 1M，
# 新会话 / 恢复的旧会话 / 切换会话均生效。
#
# 版本适配：2.160.0 / 2.168.2 / 2.181.0（2026-11-09 适配 2.181.0）
#   - 安装根目录自动探测（CODEBUDDY_ROOT 可覆盖）
#   - 补丁 B 用带反向引用的正则匹配 seedContextWindow 调用点：
#     模块别名（ck.G4C / uE.SessionUtils / tQ.SessionUtils）与会话变量名
#     （2.168.2 的 eh/eg、2.181.0 的 eg/eh）都不写死
#   - 补丁 C（~/bin wrapper）改为 opt-in：INSTALL_WRAPPER=1
#
# 详见 README.md。卸载用 ./uninstall.sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE="$SCRIPT_DIR/.context-window-patch-state.json"
CTX="${CONTEXT_WINDOW:-1000000}"

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

[ -f "$BIN" ]    || { log "✗ 找不到 $BIN（用 CODEBUDDY_ROOT 指定安装根目录）"; exit 1; }
[ -f "$BUNDLE" ] || { log "✗ 找不到 $BUNDLE"; exit 1; }
command -v python3 >/dev/null 2>&1 || { log "✗ 需要 python3"; exit 1; }

VER=$(node -p "require('$CB_ROOT/package.json').version" 2>/dev/null || echo unknown)
log "目标：$CB_ROOT（v$VER）"

# 检查与写入共用同一段 Python；APPLY=0 只检查，APPLY=1 才落盘。
# 退出码：0 = 有改动待做，10 = 已是最新（幂等跳过），1 = 锚点不符（放弃）
run_patch() {
    APPLY="$1" python3 - "$BIN" "$BUNDLE" "$STATE" "$CTX" "$CB_ROOT" "$VER" <<'PY'
import json, os, re, sys, time

bin_path, bundle_path, state_path, ctx, root, ver = sys.argv[1:7]
apply = os.environ.get("APPLY") == "1"
ctx = int(ctx)

BIN_ANCHOR = "// Route to headless bundle when TUI is not needed\nconst args = process.argv.slice(2);"
BIN_MARK = "codebuddy-context-window patch"

# 原厂：X.isSubAgent(V)||V===W||await this.seedContextWindow(V)
# 补丁：X.isSubAgent(V)||await this.seedContextWindow(V)
#   X = 模块别名，V/W = 会话变量名，逐版本重排，故一律用反向引用
OLD_RE = re.compile(
    r"\.isSubAgent\(([A-Za-z_$][\w$]*)\)\|\|[A-Za-z_$][\w$]*===[A-Za-z_$][\w$]*"
    r"\|\|await this\.seedContextWindow\(\1\)"
)
NEW_RE = re.compile(
    r"\.isSubAgent\(([A-Za-z_$][\w$]*)\)\|\|await this\.seedContextWindow\(\1\)"
)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    tmp = path + ".ctxpatch.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, os.stat(path).st_mode)
    os.replace(tmp, path)


bin_src = read(bin_path)
bundle_src = read(bundle_path)

need_bin = BIN_MARK not in bin_src
need_bundle = not NEW_RE.search(bundle_src)

if not need_bin and not need_bundle:
    print("[i] 两处补丁均已在位，无需改动")
    sys.exit(10)

plan = []

if need_bin:
    n = bin_src.count(BIN_ANCHOR)
    if n != 1:
        sys.exit(
            f"✗ bin/codebuddy 锚点出现 {n} 次（期望 1），结构可能已变，放弃。\n"
            f"  锚点：// Route to headless bundle when TUI is not needed\\n"
            f"        const args = process.argv.slice(2);"
        )
    plan.append(f"[1/3] bin/codebuddy 注入 --settings '{{\"contextWindow\":{ctx}}}'")

original = patched = None

if need_bundle:
    matches = list(OLD_RE.finditer(bundle_src))
    if len(matches) != 1:
        sys.exit(
            f"✗ seedContextWindow 调用点匹配 {len(matches)} 次（期望 1），版本不匹配，放弃。\n"
            f"  参考 README「版本兼容」重新定位：\n"
            f"  grep -o '.\\{{60\\}}seedContextWindow.\\{{40\\}}' dist/codebuddy.js"
        )
    m = matches[0]
    var = m.group(1)
    original = m.group(0)
    patched = f".isSubAgent({var})||await this.seedContextWindow({var})"
    plan.append(f"[2/3] dist/codebuddy.js 移除 {var}===* 短路")

if not apply:
    for line in plan:
        print(line)
    sys.exit(0)

if need_bin:
    block = (
        "// >>> codebuddy-context-window patch (delete this block to uninstall)\n"
        "// 注入上下文档位 1M：CliSettingsProvider -> seedContextWindow 每次建会话写 override。\n"
        "// 子命令（config/mcp/plugin/...）不接受 --settings，必须跳过注入，\n"
        "// 否则 commander 直接报 \"unknown option '--settings'\"。\n"
        "const __cbCtxSub = new Set(['config','mcp','sandbox','plugin','plugins','project',\n"
        "    'doctor','update','install','cleanup','daemon','ps','logs','attach','kill',\n"
        "    'stop','rm','respawn','agents','auto-mode']);\n"
        "const __cbCtxPos = process.argv.slice(2).find((a) => !a.startsWith('-'));\n"
        "if (!process.argv.includes('--settings') && !__cbCtxSub.has(__cbCtxPos)) {\n"
        "    process.argv.push('--settings', '{\"contextWindow\":" + str(ctx) + "}');\n"
        "}\n"
        "// <<< codebuddy-context-window patch\n\n"
    )
    write(bin_path, bin_src.replace(BIN_ANCHOR, block + BIN_ANCHOR, 1))
    print("[1/3] bin/codebuddy 已注入 --settings")

if need_bundle:
    write(bundle_path, bundle_src.replace(original, patched, 1))
    state = {
        "version": ver,
        "root": root,
        "bundle": bundle_path,
        "context_window": ctx,
        "original": original,
        "patched": patched,
        "applied_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("[2/3] dist/codebuddy.js 已移除短路（原串已记入状态文件，供 --restore 精确还原）")
PY
}

rc=0
run_patch 0 || rc=$?
[ "$rc" = 10 ] && { log ""; log "✓ 已是补丁态。重启 CodeBuddy 后 /context 分母应为 1M。"; exit 0; }
[ "$rc" = 0 ] || exit 1

if [ "${DRY_RUN:-0}" = 1 ]; then
    log ""
    log "（dry-run：锚点校验通过，未写入任何文件）"
    exit 0
fi

# ---------------------------------------------------------------- 备份（改动前）
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$SCRIPT_DIR/backups/${STAMP}_v${VER}"
mkdir -p "$BACKUP"
cp -p "$BIN" "$BACKUP/bin-codebuddy"
cp -p "$BUNDLE" "$BACKUP/dist-codebuddy.js"
log "[0/3] 已备份到 ${BACKUP}"

run_patch 1

# ---------------------------------------------------------------- 3) ~/bin wrapper（可选，默认不装）
if [ "${INSTALL_WRAPPER:-0}" = 1 ]; then
    WBIN="$HOME/bin"
    if [ -e "$WBIN/codebuddy" ] && grep -q 'codebuddy-context-window wrapper' "$WBIN/codebuddy" 2>/dev/null; then
        log "[3/3] ~/bin wrapper 已存在，跳过"
    else
        mkdir -p "$WBIN"
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' '# codebuddy-context-window wrapper (PATH 兜底；卸载：删除本文件及同目录 cbc/codebuddy-code 软链)'
            printf '%s\n' "exec \"$BIN\" --settings '{\"contextWindow\":$CTX}' \"\$@\""
        } > "$WBIN/codebuddy"
        chmod +x "$WBIN/codebuddy"
        ln -sf codebuddy "$WBIN/cbc"
        ln -sf codebuddy "$WBIN/codebuddy-code"
        log "[3/3] ~/bin wrapper 已安装（指向 $BIN）"
        case ":$PATH:" in
            *":$WBIN:"*) ;;
            *) log "    ⚠ $WBIN 不在 PATH 中，wrapper 不会生效（补丁 A 已覆盖启动路径，可不装）" ;;
        esac
    fi
else
    log "[3/3] 跳过 ~/bin wrapper（需要时 INSTALL_WRAPPER=1 ./apply.sh）"
fi

log ""
log "✓ 补丁应用完成。请完全退出并重启 CodeBuddy，然后执行 /context 验证分母为 1M。"
log "  若 /context 仍是 300k：说明服务端模型目录的 supportedLengths 已不含 1000000，"
log "  override 会被静默丢弃（见 README「关键约束」），此时补丁无效但不影响运行。"
