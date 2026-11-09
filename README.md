# CodeBuddy patch

对 [CodeBuddy Code](https://www.codebuddy.ai/) CLI（`@tencent-ai/codebuddy-code`）的本地补丁集合。
所有补丁都直接改安装目录里的文件，**升级/重装会整目录覆盖、补丁随之丢失**，重跑脚本即可。

| 补丁 | 作用 | 实测版本 |
|---|---|---|
| [`CodeBuddy-Context-patch/`](CodeBuddy-Context-patch/) | `deepseek-v4.1-flash` 上下文预算 300k → 1M，新会话/恢复的旧会话都生效 | 2.160.0 · 2.168.2 · 2.181.0 |

## 快速开始

```bash
cd CodeBuddy-Context-patch
DRY_RUN=1 ./apply.sh    # 只校验锚点、打印将做的改动，不写盘
./apply.sh              # 应用（幂等；改动前自动备份）
./uninstall.sh          # 卸载
```

安装根目录自动探测（`CODEBUDDY_ROOT` → `npm root -g` → `~/.local/lib/node_modules`
→ `/usr/local/lib/node_modules` → `$PREFIX/lib/node_modules`），也可显式指定：

```bash
CODEBUDDY_ROOT=~/.local/lib/node_modules/@tencent-ai/codebuddy-code ./apply.sh
```

改完需**完全退出并重启** codebuddy，然后 `/context` 看分母。

## 设计原则

- **锚点不符就放弃，不猜**：正则命中数不等于 1 时脚本直接退出，不写任何文件。
- **改动前备份**：每次落盘前把 `bin/codebuddy` 与 `dist/codebuddy.js` 拷到 `backups/<时间戳>_v<版本>/`。
- **可精确还原**：被替换的原文写进状态文件，`uninstall.sh` 按它逐字还原。
- **版本差异不写死**：模块别名、压缩变量名一律用带反向引用的正则匹配。

## 注意

- `backups/` 与 `*-patch-state.json` 不入库（见 `.gitignore`）：备份可从 npm 同版本重装再生
  （bundle 约 34 MB），状态文件每次重放都变。
- 只在 Linux 上验证过；Windows 的路径与换行差异未适配。
