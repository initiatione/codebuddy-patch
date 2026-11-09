# CodeBuddy Context Window Patch

把 `deepseek-v4.1-flash` 的上下文预算从服务端默认 **300k** 永久提升到 **1M**，
且**新会话、恢复的旧会话、切换会话全部生效**。

- 适用版本：CodeBuddy Code **2.181.0**（2026-11-09 实测在位）、2.168.2、2.160.0
  补丁 B 依赖压缩产物里的 `seedContextWindow` 调用点，模块别名与会话变量名随版本变化，
  `apply.sh` 用**带反向引用**的正则匹配、两者都不写死（见「版本兼容」）
- 适用模型：任何服务端配置为多档预算的模型（本补丁针对 `deepseek-v4.1-flash`，档位 `[300000, 1000000]`）

---

## 1. 背景：为什么是 300k

服务端下发的模型目录里，`deepseek-v4.1-flash` 的能力与档位如下：

```json
{
  "id": "deepseek-v4.1-flash",
  "maxInputTokens": 1000000,
  "maxAllowedSize": 1000000,
  "contextWindow": { "defaultLength": 300000, "supportedLengths": [300000, 1000000] },
  "descriptionZh": "DeepSeek 旗舰模型，支持 1M 上下文窗口，原生多模态"
}
```

即：**能力 1M，但默认档 300k**，可选档 `[300k, 1M]`。

生效值由 `resolveEffectiveContextBudget()` 决定，优先级：

```
overrideContextWindow(会话级) > defaultLength(300000) > supportedLengths 最小值 > maxInputTokens
```

没有 override 时命中 `defaultLength=300000`，所以默认 300k。

### 关键约束（官方设计）

- 档位是**会话级临时配置**：进程内有效，重启后回落模型默认档（`acp.md` 明确说明）。
- 持久化档位**没有 settings 项**：`settingsManager` / `cliSettingsProvider` 都不读 `settings.json` 里的 `contextWindow`。
- 唯一可持久注入的通道是 **CLI `--settings`**：
  `CliSettingsProvider` 读取 → `seedContextWindow()` 在建会话时写入会话 override。

---

## 2. 补丁原理（两处，缺一不可）

### 补丁 A：注入 `--settings`（提供 1M 的值）

在 `bin/codebuddy` 启动早期，把 `--settings '{"contextWindow":1000000}'` 注入 `process.argv`。
放在 `--version` 快速路径之后，不影响其秒退。

```js
// >>> codebuddy-context-window patch
const __cbCtxSub = new Set(['config','mcp','sandbox','plugin','plugins','project',
    'doctor','update','install','cleanup','daemon','ps','logs','attach','kill',
    'stop','rm','respawn','agents','auto-mode']);
const __cbCtxPos = process.argv.slice(2).find((a) => !a.startsWith('-'));
if (!process.argv.includes('--settings') && !__cbCtxSub.has(__cbCtxPos)) {
    process.argv.push('--settings', '{"contextWindow":1000000}');
}
// <<< codebuddy-context-window patch
```

覆盖所有启动路径（终端、绝对路径、IDE、bash hash 缓存）。

**子命令必须跳过注入**（2.181.0 适配）：`codebuddy config get …` 这类子命令的 commander
实例没有声明 `--settings`，注入后直接 `error: unknown option '--settings'`。上表里的
子命令一律不注入；主路径（TUI / `-p` / `--serve`）的第一个位置参数是提示词或不存在，
照常注入。

### 补丁 B：让旧会话也执行 seed（修掉短路）

`seedContextWindow()` 唯一调用点带 `eh===eg` 短路：

```js
ed.acp || isSubAgent(eh) || eh===eg || await this.seedContextWindow(eh)
```

- 新会话：`sessionSubject.value` 是旧值 → `eh!==eg` → seed 跑 → 1M
- 恢复/切换旧会话：当前会话已被设成它 → `eh===eg` → **seed 被跳过** → 回落 300k

去掉 `eh===eg||`：

```diff
- ed.acp||ck.G4C.isSubAgent(eh)||eh===eg||await this.seedContextWindow(eh)
+ ed.acp||ck.G4C.isSubAgent(eh)||await this.seedContextWindow(eh)
```

`seedContextWindow` 内部有 `void 0===getOverrideContextWindow(id)` 守卫，
所以去掉短路后：无 override 的会话（含恢复的旧会话）补 1M；已手动选档的会话不会被覆盖。

### 补丁 C（可选）：`~/bin` wrapper 兜底

`~/bin/codebuddy`（`cbc` / `codebuddy-code` 为软链）在 PATH 中优先，
启动时追加 `--settings`。有 `--settings` 存在性守卫，与补丁 A 不会重复注入。
**默认不装**（`INSTALL_WRAPPER=1 ./apply.sh` 才装）：补丁 A 已覆盖所有启动路径，
且 wrapper 只在 `~/bin` 位于 PATH 前部时才有意义；安装时会写入探测到的绝对路径，
若 `~/bin` 不在 PATH 会给出提示。

---

## 3. 使用

```sh
DRY_RUN=1 ./apply.sh   # 只校验锚点、打印将要做的改动，不写盘
./apply.sh             # 应用补丁（幂等，可重复执行；改动前自动备份）
./uninstall.sh         # 卸载，按状态文件精确还原
```

安装根目录自动探测（顺序：`CODEBUDDY_ROOT` → `npm root -g` → `~/.local/lib/node_modules`
→ `/usr/local/lib/node_modules` → `$PREFIX/lib/node_modules`），也可显式指定：

```sh
CODEBUDDY_ROOT=~/.local/lib/node_modules/@tencent-ai/codebuddy-code ./apply.sh
```

改完需**完全退出并重启** CodeBuddy 才生效。验证：

```
/context      # 分母应为 1M
```

---

## 4. 注意事项

- **升级会冲掉补丁**：`npm install -g` 覆盖同一 install root 的 `bin/` 与 `dist/`。
  已设 `DISABLE_AUTOUPDATER=1`；手动升级后重新执行 `./apply.sh`。
  实测（2.168.2 / 2.181.0）：升级后 `bin/codebuddy` 与 `dist/codebuddy.js` 均回到原厂，
  重跑 `apply.sh` 后两处补丁就位（`bin` 有 `codebuddy-context-window patch` 块，
  bundle 内 `===<会话变量>||` 短路归零）。
- **ACP/IDE 会话仍为 300k**：补丁 B 保留 `ed.acp` 短路，IDE 集成会话不 seed。
  需在 IDE 的 config picker 里选 1M，或自行改 `ed.acp` 分支。
- **不修改 `~/.codebuddy/settings.json`**：该文件的 `contextWindow` 键无效，补丁不使用它。

---

## 5. 版本兼容

补丁 B 依赖压缩产物中的 `seedContextWindow` 调用点。`isSubAgent` 前的模块别名与会话变量名
都由压缩器分配，**逐版本变化**：

| 版本 | 调用点原文 |
|---|---|
| 2.160.0 | `ck.G4C.isSubAgent(eh)\|\|eh===eg\|\|await this.seedContextWindow(eh)` |
| 2.168.2 | `uE.SessionUtils.isSubAgent(eh)\|\|eh===eg\|\|await this.seedContextWindow(eh)` |
| 2.181.0 | `tQ.SessionUtils.isSubAgent(eg)\|\|eg===eh\|\|await this.seedContextWindow(eg)` |

因此 `apply.sh` 不写死任何符号，用带反向引用的正则
`\.isSubAgent\(([\w$]+)\)\|\|\w+===\w+\|\|await this\.seedContextWindow\(\1\)`
匹配（`\1` 保证 `isSubAgent` 与 `seedContextWindow` 的参数是同一个变量），
并先校验出现次数**恰为 1 次**，不等于 1 次即中止（不做修改）。

补丁态无法反推原串（`eg===eh` 里的 `eh` 补丁后已丢失），所以 `apply.sh` 把被替换的原文
写进 `.context-window-patch-state.json`，`uninstall.sh` 按它精确还原。状态文件缺失时
`uninstall.sh` 不会动 bundle，改为提示按同版本重装：

```sh
npm i -g @tencent-ai/codebuddy-code@<当前版本>
```

若升级后补丁失败，按下面方法重新定位：

```sh
cd "$(npm root -g)/@tencent-ai/codebuddy-code/dist"
grep -o '.\{60\}seedContextWindow.\{40\}' codebuddy.js
```

正常情况无需手改 `PAT` —— 正则只要求"同一个变量名"这一结构，改名不影响命中。
只有结构本身变了（例如多了别的短路条件）才需要改 `apply.sh` 里的 `OLD_RE`。
