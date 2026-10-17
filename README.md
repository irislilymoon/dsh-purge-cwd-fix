# DSH × dsh-purge「unknown prompt variable "{{cwd}}"」故障修复手册

> **文档定位**：这是给“人”和“自动化 Agent”共用的修复手册。人按第 1、7、11 节操作即可；
> Agent 请先完整阅读 **第 0 节（操作契约）**，再按第 7、10 节的流程执行。
>
> **修复对象**：`dsh-purge` 插件（实测 1.1.71）与较新 `@deepseek-ai/dsh`（实测 0.2.1-alpha.2）
> 的 prompt 插值变量不兼容问题。附带修复插件启动时的 PowerShell 注册表扫描噪音。
>
> **安全声明**：本仓库是**非官方兼容性修复**，只修改 `dsh-purge` 插件自己的两个文件。
> 不修改宿主、模型、凭据、端口、会话数据，不包含第三方插件/宿主的完整源文件。

---

## 目录

- [0. 给自动化 Agent：阅读顺序与操作契约](#0-给自动化-agent阅读顺序与操作契约)
- [1. 一页速查](#1-一页速查)
- [2. 现象](#2-现象)
- [3. 环境与版本](#3-环境与版本)
- [4. 根因：完整故障链](#4-根因完整故障链)
- [5. 内核：DSH 的提示词装配与插值机制](#5-内核dsh-的提示词装配与插值机制)
- [6. 修复方案与完整代码](#6-修复方案与完整代码)
- [7. 手动修复步骤（不依赖脚本也能做）](#7-手动修复步骤不依赖脚本也能做)
- [8. 仓库脚本手册](#8-仓库脚本手册)
- [9. 验证方法](#9-验证方法)
- [10. 更新 / 重装后复发](#10-更新--重装后复发)
- [11. 撤销修复、停用、彻底卸载](#11-撤销修复停用彻底卸载)
- [12. 常见问题](#12-常见问题)
- [13. 隐私与可迁移性](#13-隐私与可迁移性)
- [14. 附录](#14-附录)

---

## 0. 给自动化 Agent：阅读顺序与操作契约

> 本章是给自动化修复 Agent 的“规格说明”。如果你是人，可以跳过到第 1 节。

### 0.1 阅读顺序

1. 第 2、3 节：确认现场是否属于本问题；
2. 第 4、5 节：理解“为什么”和“改哪里”，避免乱改宿主；
3. 第 6 节：确认要插入的完整代码；
4. 第 7 节：执行修复（或直接运行第 8 节的脚本）；
5. 第 9 节：执行验收；
6. 失败时按第 10 节决策树处理；
7. 需要撤销/停用/卸载时看第 11 节。

### 0.2 前置检查（必须先全部满足）

```powershell
# 1) dsh 存在
dsh --version

# 2) 定位 DSH_HOME 与插件
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
$lib = Join-Path $dshHome "profiles\web\node_modules\dsh-purge\lib"
Test-Path $lib
Test-Path (Join-Path $lib "index.js")
Test-Path (Join-Path $lib "desktop.js")

# 3) 确认插件版本与锚点（不是 1.1.71 时先看第 10 节）
Get-Content (Join-Path $dshHome "profiles\web\node_modules\dsh-purge\package.json") -Raw | ConvertFrom-Json |
  Select-Object name, version, dshTarget

Select-String -Path (Join-Path $lib "index.js") -Pattern "export function registerPromptSections\(ctx, config\) \{"
Select-String -Path (Join-Path $lib "index.js") -Pattern "function installRewindDeriveFilter\(ctx\) \{"

# 4) 确认出错现场（至少满足一条）
#    页面报错含 unknown prompt variable "{{cwd}}"
#    或 diagnose.ps1 报 index.js 补丁缺失
```

**前置检查不通过时不要继续写入**，按 `FAIL` 原因进入第 10 节。

### 0.3 允许修改的文件白名单（正常路径）

只允许修改：

```text
<DSH_HOME>\profiles\<profile>\node_modules\dsh-purge\lib\index.js
<DSH_HOME>\profiles\<profile>\node_modules\dsh-purge\lib\desktop.js
```

允许创建（备份/快照，均在你的 DSH_HOME 下）：

```text
<DSH_HOME>\dsh-purge\patch-backup\...
<DSH_HOME>\dsh-purge\patch-backup\lifecycle\...
```

**只有在第 10.5 节 fallback 场景**才允许修改宿主：

```text
<npm global>\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-agent-loop\lib\index.js
```

### 0.4 禁止事项（硬约束）

- 不删除、不重写、不迁移用户的 `sessions\`、`.credentials.yaml`、`settings.yaml`、`storages\`；
- 不修改 `profiles\web\package.json` 的 bundles（除非用户明确要求停用/卸载，走第 11 节脚本）；
- 不修改 `cordis.patch.yml`（除非执行第 10.5 节 fallback 的明确步骤）；
- 不kill/重启用户正在使用的桌面端或其它 dsh 实例；`dsh web` 是否重启由用户或第 7 节流程决定；
- 不删除任何日志、备份、快照；
- 不把本机的绝对路径、用户名、token 写进仓库文件；
- 不直接覆盖 pnpm 的硬链接目标（见 6.4，必须先断链）。

### 0.5 标准执行流程

```text
1. 前置检查（0.2）
2. 只读体检：powershell -File scripts\diagnose.ps1
3. 预览：node scripts\reapply-fix.mjs --dry-run
4. 若未修复：node scripts\reapply-fix.mjs
5. 语法检查（脚本内部已做；手工时 node --check）
6. 关闭并重启 dsh web（或让用户重启）
7. 验收（第 9 节）
8. 输出报告（0.8）
```

### 0.6 验收断言（必须全部为真）

| # | 断言 | 检查方式 |
|---|---|---|
| A1 | `index.js` 同时包含 `CWD_PROMPT_VARIABLE` 与 `installCwdVariable` | `Select-String` |
| A2 | `desktop.js` 使用 `Get-ItemProperty -LiteralPath` | `Select-String` |
| A3 | 两个文件语法通过 | `node --check <file>` 退出码 0 |
| A4 | 只读体检无 FAIL | `diagnose.ps1` 输出无 `[FAIL]` |
| A5 | `dsh web` 发消息能收到回复，且日志无 `unknown prompt variable` | 人工或 `verify-dsh-web.ps1` |

### 0.7 失败处理路径

| 失败断言 | 处理 |
|---|---|
| 前置检查找不到插件 | 确认 profile / 用 `--lib-dir`；插件未安装则先安装（`安装命令.md`） |
| `reapply-fix.mjs` 报锚点不一致 | 按第 7 节手工插入；或走第 10.5 宿主 fallback |
| 写入后语法检查失败 | 立即用 `rollback.ps1` 恢复备份，再排查 |
| A5 失败但 A1-A4 通过 | 确认 `dsh web` 已重启；再查是否其它变量报错（10.8） |
| 出现 `has no value` | 重新运行 `reapply-fix.mjs`（provider 被改坏） |

### 0.8 必须输出的报告格式

修复完成后，Agent 应向用户报告：

```text
问题: <复述 unknown prompt variable 报错>
环境: dsh <版本>, dsh-purge <版本>, profile <名称>, DSH_HOME <路径>
根因: dsh-purge 硬编码 {{cwd}}，新版 DSH 未注册该变量
改动: <文件1>, <文件2>（各改了什么）
备份: <备份目录>
验证: A1/A2/A3/A4/A5 结果；dsh web 重启方式；测试消息与回复
未做: <明确列出未执行的高风险操作，如卸载/停用>
```

---

## 1. 一页速查

### 1.1 症状对照（30 秒判断）

| 现象 | 是否本问题 |
|---|---|
| 每轮显示“本轮运行失败”，附带 `unknown prompt variable "{{cwd}}" in section "deployment:persona-suffix"; registered variables: provider, model` | ✅ 是 |
| 只有 `dsh web` 不行，桌面端/其它客户端正常 | ✅ 典型（不同宿主版本/不同加载路径） |
| 重启、换 token、换模型、换网络都无效 | ✅ 本问题与这些无关 |
| 终端出现 `Get-ItemProperty : 指定的转换无效。` | ⚠️ 同插件另一个小问题，一并修 |
| 报错是其它变量名 `{{xxx}}`，或 `has no value for this assembly` | ❌ 变体，看第 10.8 节 |

### 1.2 最快恢复

```powershell
# 1) 关闭正在运行的 dsh web（Ctrl+C）

# 2) 打补丁（幂等，已修好会提示跳过）
node ".\scripts\reapply-fix.mjs"

# 3) 重启
dsh web
```

也可以双击 `1-一键修复.cmd`。不确定状态先双击 `0-先体检.cmd`（只读）。

### 1.3 仓库结构

```text
dsh-purge-cwd-fix\
├─ README.md                          ← 本文档
├─ 命令清单.txt                        ← 命令复制粘贴版
├─ 持久终端冲突修复.md                  ← 另一个 DSH 问题（可选）
├─ 安装命令.md                         ← 插件安装/代理示例
├─ LICENSE
├─ 0-先体检.cmd                        ← 只读体检
├─ 1-一键修复.cmd                      ← 打补丁（幂等）
├─ 2-验证对话.cmd                      ← 端到端验证（调一次模型）
├─ 3-回滚至报错状态.cmd                 ← 撤销补丁（恢复自动备份）
├─ 4-启动dsh-web.cmd                   ← 启动 dsh web
├─ 5-停用插件.cmd                      ← 停用 dsh-purge（可回溯）
├─ 6-重新启用插件.cmd                  ← 恢复停用
├─ 7-卸载插件.cmd                      ← 彻底卸载（先快照）
├─ patches\
│  ├─ cwd-variable.patch
│  └─ desktop-registry-scan.patch
└─ scripts\
   ├─ reapply-fix.mjs
   ├─ diagnose.ps1
   ├─ rollback.ps1
   ├─ verify-dsh-web.ps1
   ├─ disable-plugin.ps1
   ├─ enable-plugin.ps1
   ├─ uninstall-plugin.ps1
   └─ patch-data\cwd-variable-helper.txt
```

---

## 2. 现象

### 2.1 页面报错原文

```text
本轮运行失败unknown prompt variable "{{cwd}}" in section "deployment:persona-suffix";
registered variables: provider, model
```

拆解：

- `unknown prompt variable "{{cwd}}"`：渲染 system prompt 时遇到 `{{cwd}}`，但变量表里没有 `cwd`；
- `in section "deployment:persona-suffix"`：出错的是 persona-suffix 段；
- `registered variables: provider, model`：宿主当前只注册了 `provider`、`model` 两个变量。

### 2.2 终端现场（脱敏）

```text
dsh web: http://127.0.0.1:<port>/?token=<redacted>
dsh web: opening the default browser; pass --no-open to disable
Get-ItemProperty : 指定的转换无效。
所在位置 行:11 字符: 10
+     $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
+          ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Get-ItemProperty], InvalidCastException
```

### 2.3 影响边界

- **受影响**：`dsh web` 加载了 `dsh-purge` 的 profile（默认 `profiles\web`）；
- **不受影响**：同一账号/模型/网络下的其它宿主或客户端（版本/插件组合不同）；
- 失败发生在**模型调用之前**的提示词渲染阶段，所以换 token、换模型、换端口、换浏览器都不解决；
- 会话记录本身没有损坏，只是插件无法正常工作。

### 2.4 两个独立问题

| # | 问题 | 影响 | 处理 |
|---|---|---|---|
| 1 | `{{cwd}}` 变量未注册 | 所有对话失败（高优先级） | 补丁 A（6.1） |
| 2 | PowerShell 注册表扫描 `InvalidCastException` | 启动噪音，不影响对话 | 补丁 B（6.2） |

> 问题 2 不是用户的 `$PROFILE` 问题，而是 `dsh-purge\lib\desktop.js` 内联 PowerShell 的行为。

---

## 3. 环境与版本

### 3.1 实测环境（修复时的版本，供核对）

| 项 | 值 |
|---|---|
| OS | Windows 11（仅代表实测环境，脚本逻辑与平台无关） |
| Node.js | v24（Node ≥ 18 均可） |
| dsh | `@deepseek-ai/dsh` **0.2.1-alpha.2** |
| dsh-purge | **1.1.71**（`dshTarget: 0.2.0-rc.2`） |
| profile | `web` |
| DSH_HOME | `%USERPROFILE%\.dsh`（默认值；已设置 `DSH_HOME` 时以环境变量为准） |

> 版本可以在任何机器上用 `dsh --version` 和插件的 `package.json` 重新确认。
> 行号、代码片段以实测版本为准；升级后可能偏移，以“锚点文本”为准而不是行号。

### 3.2 版本代差

```text
dsh-purge 按 dshTarget: 0.2.0-rc.2 编写，认为 {{cwd}} 是宿主内置变量
                    ↓
实际宿主可能是 0.2.1-alpha.2 或更新，prompt 变量集合收窄为 { provider, model }
                    ↓
插件写死的 {{cwd}} 在插值阶段抛错 → 全部对话失败
```

这不是插件或宿主的单方面 bug，而是**插件与宿主版本不匹配**。本仓库选择“在插件侧补回变量”
的最小改动方案。

### 3.3 路径约定

| 名称 | 默认位置 / 获取方式 |
|---|---|
| DSH_HOME | `$env:DSH_HOME`，否则 `%USERPROFILE%\.dsh` |
| profile 目录 | `<DSH_HOME>\profiles\<profile>`，默认 `web` |
| 插件目录 | `<profile>\node_modules\dsh-purge` |
| 插件 lib | `<插件目录>\lib` |
| DSH 安装目录 | 用 `(Get-Command dsh.cmd).Source` 反推：`<npm bin>\node_modules\@deepseek-ai\dsh` |

---

## 4. 根因：完整故障链

### 4.1 一句话

`dsh-purge` 的 bundle 补丁给核心 `system-prompt` 服务配置了
`personaSuffix: Your working directory is {{cwd}}.`；运行时代码每轮还会把 person-suffix
强制改写回含 `{{cwd}}` 的文本。而新版 DSH 只注册 `provider`、`model` 两个插值变量，
严格插值器遇到 `{{cwd}}` 直接抛错，导致每轮 system prompt 渲染失败。

### 4.2 逐层拆解

1. **启动组装插件树**：`dsh web` 按 `profiles\web\package.json` 的 `dsh.profile.bundles`
   依次叠加：`@deepseek-ai/dsh-base` → `@deepseek-ai/dsh-web-app` → `dsh-purge`（以及其它可选 bundle）。
2. **dsh-purge 的 bundle 补丁改核心配置**（`dsh-purge\cordis.patch.yml`）：

   ```yaml
   - id: system-prompt
     config:
       includeHarnessIdentity: false
       personaPrefix: ""
       personaSuffix: Your working directory is {{cwd}}.
   ```

3. **DSH 核心服务把配置变成 section**：`@deepseek-ai/dsh-system-prompt` 的 `SystemPrompt`
   构造函数把 `personaSuffix` 注册为 section `deployment:persona-suffix`，
   `order: 10200`，默认 `interpolate: true`。
4. **宿主只注册两个变量**（`@deepseek-ai/dsh-agent-loop`）：

   ```js
   ctx.systemPrompt.variable("provider", (context) => context.agent?.options.provider);
   ctx.systemPrompt.variable("model", (context) => context.agent?.options.model);
   ```

   → 变量表 = `{ provider, model }`，与报错完全对应。
5. **渲染时严格插值**：`renderPrompt()` → `interpolate()` 遇到 `{{cwd}}`，
   `Object.hasOwn(variables, "cwd") === false`，抛
   `unknown prompt variable "{{cwd}}" in section "deployment:persona-suffix"`。
6. **错误被 turn 捕获**：agent-loop 把异常转成 `turn/end { kind: "error" }` 并发出
   `agent/error`，UI 显示“本轮运行失败 + 错误消息”。模型调用没有发生。

### 4.3 链路图

```text
profiles\web\package.json
  bundles: [dsh-base, dsh-web-app, dsh-purge, ...]
        │
        ▼
dsh-purge\cordis.patch.yml
  system-prompt.config.personaSuffix = "Your working directory is {{cwd}}."
        │
        ▼
dsh-system-prompt: section "deployment:persona-suffix"（interpolate 默认 true）
        │
        ▼
dsh-agent-loop: variable("provider")、variable("model")   ← 只有两个变量
        │
        ▼
renderPrompt() → interpolate(section)
        │   Object.hasOwn(variables, "cwd") === false
        ▼
throw: unknown prompt variable "{{cwd}}" ...
        │
        ▼
turn catch → turn/end { kind: "error" } → UI「本轮运行失败」
```

### 4.4 可以排除的原因

- 报错来自 DSH 自己的插值器，不是模型 API 返回；
- 失败发生在 `ctx.llm` 调用之前；
- 同模型/账号在其它宿主正常 → 凭据与网络没问题；
- 与端口无关：web 能启动、能建会话、能接收消息。

### 4.5 为什么“桌面端正常、web 不正常”

桌面端与 `dsh web` 可能是**不同版本的 DSH 宿主**（桌面端自带运行时，CLI 是另一份 npm 全局安装），
即使共享同一个 `DSH_HOME`，插件组合与宿主版本也可能不同。会话记录互通问题另见第 10.9 节。

---

## 5. 内核：DSH 的提示词装配与插值机制

> 本节解释“为什么必须在变量层补 `cwd`”，是判断同类问题的依据。

### 5.1 四个概念

`SystemPrompt` 服务管理四类注册物（`@deepseek-ai/dsh-system-prompt`）：

| 概念 | 注册方法 | 渲染行为 | 本问题中的角色 |
|---|---|---|---|
| **section** | `ctx.systemPrompt.section({name, order, text, interpolate})` | 按 order 拼接；`interpolate !== false` 时解析 `{{变量}}` | `deployment:persona-suffix` 是 section，内容含 `{{cwd}}` |
| **context** | `ctx.systemPrompt.context({...})` | 动态上下文快照；通常 `interpolate: false` | 新版 cwd 放在这里（`working-directory:current`） |
| **tools** | `ctx.systemPrompt.tools(provider)` | 工具 schema | 无关 |
| **variables** | `ctx.systemPrompt.variable(name, provider)` | 每次 assemble 求值，填变量表 | **缺的就是这个** |

关键点：**新版 cwd 是 context，不是 variable**。context 用 `interpolate: false` 输出字面文本
（`Current working directory: "..."`），不会帮助解析 section 里的 `{{cwd}}`。

### 5.2 assemble 的执行顺序

```js
async assemble(context = {}) {
  const scope = context.scope;
  const scopeLayers = this.layers.chainLayers(scope);
  const variables = {};
  // ① 先求值变量（全局层 + 作用域层）
  for (const [name, provider] of this.layers.global.variables.entries()) variables[name] = provider(context);
  for (const layer of scopeLayers) for (const [name, provider] of layer.variables.entries()) variables[name] = provider(context);
  // ② 再收集 sections / contexts / tools
  ...
  const assembly = { sections, contexts, tools, variables };
  // ③ 最后跑 waterfall（插件在这里改写 sections）
  const transformed = await this.ctx.waterfall(..., "system-prompt/assemble", assembly, context, ...);
  return transformed;
}
```

推论：

- 插件在 waterfall 里“顺手注册变量”没用——变量在 waterfall 之前就求值完了；
- 插件在 waterfall 里把 section 文本改写成 `{{cwd}}`（它确实这么做了）也改变不了变量表；
- 唯一正确位置：**变量注册层**，且必须在本次 assemble 之前注册好。

### 5.3 严格插值器

```js
function interpolate(input, variables, kind) {
  const text = typeof input.text === "string" ? input.text : "";
  let result = "";
  let last = 0;
  for (let open = text.indexOf("{{"); open >= 0; open = text.indexOf("{{", last)) {
    const group = GROUP_AT.exec(text.slice(open));          // /^\{\{([^{}]*)\}\}/
    if (group === null) { /* 没有成对 }} 时按字面文本处理 */ }
    const name = group[0].slice(2, -2);
    if (!VARIABLE_NAME.test(name)) throw new Error(`malformed prompt variable reference ...`);
    if (!Object.hasOwn(variables, name)) {
      const known = Object.keys(variables);
      throw new Error(`unknown prompt variable "{{${name}}}" in ${kind} "${input.name}"; registered variables: ${known.join(", ")}`);
    }
    const value = variables[name];
    if (value === void 0) throw new Error(`prompt variable "{{${name}}}" has no value for this assembly ...`);
    result += text.slice(last, open) + value;
    last = open + group[0].length;
  }
  return result + text.slice(last);
}
```

规则：

1. 只认完整 `{{name}}`，`name` 必须匹配 `/^[a-z][a-z0-9_]*$/`；
2. 未注册变量 → **抛错**（不跳过、不留空）；
3. provider 返回 `undefined` → 也抛错（所以 provider 必须返回字符串）；
4. `interpolate: false` 的 section/context 原样保留；
5. 单独一个 `{{` 而没有后续 `}}` 当普通文本。

### 5.4 cwd 在新版宿主里是 context

`@deepseek-ai/dsh-working-directory`：

```js
ctx.systemPrompt.context({
  name: "working-directory:current",
  order: ctx.systemPrompt.getContextOrder("WORKING_DIRECTORY"),
  required: true,
  interpolate: false,                 // ← 不参与变量插值
  text: (context) => context.agent === void 0 ? "" : this.contextText(context.agent.session)
});
...
contextText(session) {
  return `Current working directory: ${JSON.stringify(this.get(session))}.`;
}
```

所以模型其实能看到工作目录，只是它不在 `variables` 表里，救不了 persona-suffix。

### 5.5 宿主只注册两个变量

`@deepseek-ai/dsh-agent-loop` 中相关行（实测版本）：

```js
ctx.systemPrompt.variable("provider", (context) => context.agent?.options.provider);
ctx.systemPrompt.variable("model", (context) => context.agent?.options.model);
```

全安装内再无 `systemPrompt.variable("cwd", ...)`。这就是 `registered variables: provider, model` 的来源。

### 5.6 插件里 `{{cwd}}` 的三个来源

**来源 1：bundle 补丁配置**（`dsh-purge\cordis.patch.yml`）

```yaml
- id: system-prompt
  config:
    includeHarnessIdentity: false
    personaPrefix: ""
    personaSuffix: Your working directory is {{cwd}}.
```

**来源 2：运行时代码每轮强制改写**（`dsh-purge\lib\identity.js`）

```js
export const CWD_ONLY_SUFFIX = "Your working directory is {{cwd}}.";
...
if (name === "deployment:persona-suffix" || name === "persona-suffix") {
  sawSuffix = true;
  const raw = String(section.text || "");
  if (!raw.trim() || looksLikeOfficialIdentity(raw) || isCwdOnlyText(raw)) {
    out.push({ ...section, text: CWD_ONLY_SUFFIX });
  } else {
    out.push(section);
  }
  continue;
}
...
if (!sawSuffix) {
  out.push({ name: "deployment:persona-suffix", text: CWD_ONLY_SUFFIX, order: 10200 });
}
```

**来源 3：插件自己的插值白名单**

```js
const DSH_INTERPOLATE_ALLOWED = new Set(["cwd", "model", "provider"]);
```

`escapeDshInterpolation()` 会把不在白名单里的 `{{...}}` 改写成 `{ {`；它故意放行 `cwd`，
因为按旧宿主行为 `cwd` 是合法变量。所以：

- 只改 `cordis.patch.yml` 没用 → 运行时又写回 `{{cwd}}`；
- 只改 `identity.js` 常量可以绕过，但会失去真实路径语义；
- 最小正确修复 → 把 `cwd` 变量补齐。

### 5.7 插件自带的 assemble guard 为什么救不了

它包住的是 `prompt.assemble()`：

```js
const wrapped = async function assembleWithPurge(...args) {
  let assembled;
  try { assembled = await orig(...args); }
  catch (err) { return { sections: [], contexts: [], tools: [] }; } // 只兜 assemble 内部异常
  ...
};
```

而 `{{cwd}}` 的抛错发生在 `assemble()` 返回之后、agent-loop 调
`renderPrompt(assembly)` 时（`@deepseek-ai/dsh-agent-loop/lib/index.js` 中
`let renderedPrompt = renderPrompt(assembly);`），guard 不在那条调用链上。

### 5.8 错误为什么定位到 `deployment:persona-suffix`

`@deepseek-ai/dsh-system-prompt` 顶部：

```js
const PERSONA_PREFIX_SECTION = "deployment:persona-prefix";
const PERSONA_SUFFIX_SECTION = "deployment:persona-suffix";
```

构造函数把 `config.personaSuffix` 注册为该 section；补丁配置里写了 `{{cwd}}`，所以报错指向它。

### 5.9 最小正确修复的三条件

1. `variables` 层存在 `cwd`；
2. provider **必须返回字符串**；
3. 注册发生在第一轮 assemble 之前（插件 `apply()` 阶段）。

### 5.10 候选方案对比

| 方案 | 改动位置 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| **A. 插件内注册 `cwd` 变量** | `dsh-purge\lib\index.js` | 只动插件；语义不变；宿主升级不覆盖；可回滚；宿主将来自己注册也能兼容 | 插件升级/重装会覆盖，需重打（脚本已处理） | ✅ 采用 |
| B. 宿主补注册 | `dsh-agent-loop\lib\index.js` | 一次改完全局生效 | DSH 每次升级被覆盖；影响所有 profile | 仅作 10.5 兜底 |
| C. 改插件文本为静态 | `identity.js` + `cordis.patch.yml` | 不依赖宿主变量 | 丢失真实路径；改点多、易漏；语义退化 | 不推荐，10.7 最后兜底 |

---

## 6. 修复方案与完整代码

### 6.1 补丁 A：在插件里注册 `cwd` 变量

**文件**：`<DSH_HOME>\profiles\<profile>\node_modules\dsh-purge\lib\index.js`

**插入点 1**：`registerPromptSections()` 函数开头

```js
export function registerPromptSections(ctx, config) {
  installCwdVariable(ctx);      // ← 新增这一行
  addPromptSection(ctx, {
    name: "dsh-purge",
    ...
```

**插入点 2**：`function installRewindDeriveFilter(ctx) {` 之前插入完整代码块：

```js
const CWD_PROMPT_VARIABLE = "cwd";

/** 组装期解析当前工作目录；任何异常都退回启动目录，变量必须有字符串值。 */
function promptCwdFor(ctx, context) {
  try {
    const session = context?.agent?.session;
    if (session) {
      const service = typeof ctx?.get === "function" ? ctx.get("workingDirectory") : undefined;
      if (service && typeof service.get === "function") {
        const live = String(service.get(session) || "").trim();
        if (live) return live;
      }
      const recorded = String(session?.header?.cwd || "").trim();
      if (recorded) return recorded;
    }
  } catch { /* 变量补齐永不阻断组装 */ }
  try { return process.cwd(); } catch { return ""; }
}

/** 与 addPromptSection 同源的多 ctx 注册；宿主已注册同名变量时保留宿主实现。 */
function addPromptVariable(ctx, name, provider) {
  const hosts = [];
  const push = (host) => {
    if (host && !hosts.includes(host)) hosts.push(host);
  };
  try { push(ctx?.systemPrompt?.ctx); } catch { /* 代理未注入时点属性会抛 */ }
  push(ctx);
  const disposers = [];
  let covered = false;
  for (const host of hosts) {
    try {
      const prompt = host?.systemPrompt;
      if (!prompt || typeof prompt.variable !== "function") continue;
      const d = prompt.variable(name, provider);
      covered = true;
      if (typeof d === "function") disposers.push(d);
    } catch (error) {
      const msg = String(error && error.message || error);
      if (msg.includes("already registered")) covered = true;
      else console.warn(`[dsh-purge] prompt variable ${name}: ${msg}`);
    }
  }
  if (disposers.length && typeof ctx?.effect === "function") {
    try {
      ctx.effect(() => () => {
        for (const d of disposers) {
          try { d(); } catch { /* ignore */ }
        }
      });
    } catch { /* 死 ctx */ }
  }
  return covered;
}

/**
 * DSH 0.2.1-alpha 起 prompt 插值只注册 provider/model，不再注册 cwd。
 * 插件自己写的 `Your working directory is {{cwd}}.` 在渲染阶段会整段抛
 * unknown prompt variable，导致每一轮都「本轮运行失败」。这里把 cwd 补回
 * 变量层，保持旧宿主的行为；注册失败只告警，不拖垮插件。
 */
function installCwdVariable(ctx) {
  if (!ctx || ctx.__dshPurgeCwdVariable) return;
  let covered = false;
  try {
    covered = addPromptVariable(ctx, CWD_PROMPT_VARIABLE, (context) => promptCwdFor(ctx, context));
  } catch { covered = false; }
  if (covered) ctx.__dshPurgeCwdVariable = true;
}
```

**设计要点（改的时候不要丢）**：

| 要点 | 原因 |
|---|---|
| 从 `workingDirectory` 服务取实时值 | 会话内 `cd` 后跟着变 |
| 回退 `session.header.cwd` | 服务不可用/会话未投影时仍能取到目录 |
| 最后回退 `process.cwd()` | 保证永远返回字符串，避免 `has no value` |
| `try/catch` 全包 | 变量补齐失败不能拖垮插件启动 |
| 多 host 注册 | 兼容 Cordis 代理/预设切换 |
| `already registered` 视为成功 | 宿主未来自己注册时保留宿主实现 |
| `ctx.__dshPurgeCwdVariable` 标记 | 幂等，避免重复注册 |
| `ctx.effect` 回收 disposer | 插件热重载/卸载时自动注销 |

> 该代码块的权威副本在 `scripts\patch-data\cwd-variable-helper.txt`，`reapply-fix.mjs` 直接读取它。

### 6.2 补丁 B：`desktop.js` 注册表扫描噪音

**文件**：`<DSH_HOME>\profiles\<profile>\node_modules\dsh-purge\lib\desktop.js`

原始行（实测 1.1.71）：

```powershell
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
```

改为：

```powershell
    try { $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop } catch { return }
```

原因：`REGISTRY_INSTALL_SCRIPT` 通过 `powershell.exe -NoProfile`（Windows PowerShell 5.1）
遍历卸载登记表，个别注册表键会抛 `InvalidCastException`；`-ErrorAction SilentlyContinue`
压不住这种错误输出，加 `try/catch` 跳过该键即可。修完仍能正常读到安装信息。

### 6.3 为什么改插件而不是宿主/配置

- 改**宿主**：会被 `npm i -g @deepseek-ai/dsh` / 官方更新覆盖，且影响所有 profile；
- 改**配置**：运行时的 `overlayOfficialIdentity()` 每轮会写回 `{{cwd}}`，单改配置无效；
- 改**插件文本**：丢失真实工作目录语义；
- **补变量**：只加一层注册，不改变其它行为，最小且可逆。

### 6.4 pnpm 硬链接注意事项（手工改文件必看）

`profiles` 的 `node_modules` 由 pnpm 安装，插件文件可能是**硬链接**
（同一 inode 同时被 pnpm 内容寻址仓库和 `node_modules` 引用）。原地覆盖可能污染 store。

先检查：

```powershell
fsutil hardlink list "<lib>\index.js"
```

如果列出多行，先断开硬链接：

```powershell
function Break-HardLink($path) {
  $tmp = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
  Copy-Item -LiteralPath $path -Destination $tmp -Force
  Remove-Item -LiteralPath $path -Force
  Move-Item -LiteralPath $tmp -Destination $path
}
Break-HardLink "<lib>\index.js"
```

`reapply-fix.mjs` 使用“写临时文件 → unlink → rename”的方式，会自动断链。

---

## 7. 手动修复步骤（不依赖脚本也能做）

> 推荐先直接运行 `scripts\reapply-fix.mjs`。本节是等价手工流程，供脚本锚点失效或
> 需要理解细节时使用。**每一步都先确认上一步成功，再继续。**

### Step 0：关闭 dsh web

在运行 `dsh web` 的终端按 `Ctrl+C`。不重启不会加载新代码。

### Step 1：定位路径

```powershell
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
$profileDir = Join-Path $dshHome "profiles\web"
$plugin = Join-Path $profileDir "node_modules\dsh-purge"
$lib = Join-Path $plugin "lib"
Write-Host "DSH_HOME : $dshHome"
Write-Host "插件目录 : $plugin"
```

### Step 2：前置检查

```powershell
Test-Path (Join-Path $lib "index.js")
Test-Path (Join-Path $lib "desktop.js")
(Get-Content (Join-Path $plugin "package.json") -Raw | ConvertFrom-Json) |
  Select-Object name, version, dshTarget
Select-String -Path (Join-Path $lib "index.js") -Pattern "export function registerPromptSections\(ctx, config\) \{"
Select-String -Path (Join-Path $lib "index.js") -Pattern "function installRewindDeriveFilter\(ctx\) \{"
```

两个锚点都必须存在，否则按第 10.5 节处理。

### Step 3：备份

```powershell
$bak = Join-Path $dshHome ("dsh-purge\patch-backup\manual-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item -LiteralPath (Join-Path $lib "index.js")   -Destination $bak -Force
Copy-Item -LiteralPath (Join-Path $lib "desktop.js") -Destination $bak -Force
Write-Host "已备份到 $bak"
```

### Step 4：断硬链接

```powershell
function Break-HardLink($path) {
  $tmp = "$path.tmp-$([guid]::NewGuid().ToString('N'))"
  Copy-Item -LiteralPath $path -Destination $tmp -Force
  Remove-Item -LiteralPath $path -Force
  Move-Item -LiteralPath $tmp -Destination $path
}
Break-HardLink (Join-Path $lib "index.js")
Break-HardLink (Join-Path $lib "desktop.js")
```

### Step 5：给 `index.js` 打补丁

1. 在 `export function registerPromptSections(ctx, config) {` 下一行插入 `installCwdVariable(ctx);`；
2. 在 `function installRewindDeriveFilter(ctx) {` 之前插入 6.1 的完整 helper 代码块；
3. 保存。

也可以直接运行脚本完成等价的字符串插入：

```powershell
node ".\scripts\reapply-fix.mjs" --dry-run   # 先看
node ".\scripts\reapply-fix.mjs"             # 写入
```

### Step 6：给 `desktop.js` 打补丁

按 6.2 替换那一行（或脚本会做）。

### Step 7：语法检查

```powershell
node --check (Join-Path $lib "index.js")
node --check (Join-Path $lib "desktop.js")
```

两条都退出码 0 才继续。

### Step 8：重启

```powershell
dsh web
```

### Step 9：验收

见第 9 节。

### Step 10：失败回滚

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\rollback.ps1"
```

---

## 8. 仓库脚本手册

> 所有脚本都可从任意工作目录用绝对/相对路径调用；路径基于脚本自身位置或 `$DSH_HOME` 自动解析。

### 8.1 `scripts\reapply-fix.mjs`（一键打补丁）

| 项 | 说明 |
|---|---|
| 作用 | 检查并在需要时写入补丁 A + B；幂等 |
| 依赖 | Node.js ≥ 18；同目录 `patch-data\cwd-variable-helper.txt` |
| 默认目标 | `$DSH_HOME\profiles\web\node_modules\dsh-purge\lib` |
| 备份 | 写前备份到 `$DSH_HOME\dsh-purge\patch-backup` |
| 断链 | 自动（临时文件 + unlink + rename） |
| 自检 | 写入后 `node --check` |
| 退出码 | `0` 成功/已修好；`1` 锚点不匹配或文件缺失 |

参数：

```text
--dry-run              只检查不写文件
--profile <name>       指定 profile（默认 web）
--lib-dir <path>       直接指定 dsh-purge\lib
--backup-dir <path>    指定备份目录
```

### 8.2 `scripts\diagnose.ps1`（只读体检）

检查 dsh/node/插件版本、`index.js` 补丁、宿主变量注册、`desktop.js` 补丁、
插件是否仍依赖 `{{cwd}}`、补丁数据文件是否完整，并给出结论。参数：`-DshHome`、`-Profile`、`-LibDir`。
**只读，不修改任何文件。**

### 8.3 `scripts\rollback.ps1`（撤销补丁）

| 项 | 说明 |
|---|---|
| 作用 | 从 `reapply-fix.mjs` 写入前的自动备份恢复 `index.js` / `desktop.js` |
| 备份查找 | `$DSH_HOME\dsh-purge\patch-backup\index.js.*`、`desktop.js.*`（取最新） |
| 找不到备份 | 不修改文件，提示用 `dsh plugin --profile web add github:YuJunZhiXue/dsh-purge` 重装恢复官方版 |
| 安全副本 | 恢复前把当前文件另存到 `patch-backup\rollback-safety-<时间戳>\` |
| 参数 | `-DshHome`、`-Profile`、`-LibDir`、`-BackupDir`、`-DryRun` |
| 效果 | 回到“打补丁前/报错”状态；插件仍安装 |

> 这是“撤销本修复”，不是卸载。恢复后当前 DSH 会重新出现 `{{cwd}}` 报错，属预期。

### 8.4 `scripts\verify-dsh-web.ps1`（端到端验证）

临时启动随机端口的 `dsh web --no-open` → token 换 cookie → `/api/session/create` →
`/api/session/prompt` 发“只回复两个字：收到” → 轮询 `/api/session/list` →
检查回复非空且日志无 `unknown prompt variable` → 关闭实例、删除测试会话、保留日志。

参数：`-DshHome`、`-Prompt`、`-TimeoutSeconds`、`-KeepSession`。
**会真实调用一次模型**（需要凭据）；建议先关闭其它 `dsh web`。

### 8.5 `scripts\disable-plugin.ps1`（停用，可回溯）

1. 快照 `package.json` / `prompt-inject.md` / 补丁状态；
2. 运行插件官方 `dsh-purge --revert`：把之前写到 DSH 程序文件上的补丁还原成官方原版；
3. 从 profile 的 `dsh.profile.bundles` 移除 `dsh-purge`（保留依赖、node_modules、规则、提示词）；
4. 快照写到 `$DSH_HOME\dsh-purge\patch-backup\lifecycle\plugin-state-*-disable\`；
5. 重启 dsh web 生效。

参数：`-DshHome`、`-Profile`、`-ProfileDir`、`-DryRun`、`-SkipHostPatches`（仅测试用）。

### 8.6 `scripts\enable-plugin.ps1`（重新启用）

读取最近一次停用快照，把 `dsh-purge` 插回原 bundles 索引，运行 `dsh-purge --apply` 重打宿主补丁。
参数：`-DshHome`、`-Profile`、`-ProfileDir`、`-DryRun`、`-SkipHostPatches`、`-Apply`。

### 8.7 `scripts\uninstall-plugin.ps1`（彻底卸载）

流程：运行中 dsh web 检查 → 交互确认（输入 `YES`）→ 快照（profile 配置、`prompt-inject.md`、
`AGENTS.md`、`$DSH_HOME\dsh-purge`、`$DSH_HOME\redteam`、插件 package.json、补丁状态）→
运行 `dsh-purge --uninstall` 还原全部宿主补丁/注入/规则 → 删除插件文件与数据 →
清理所有 profile 的 bundles 与依赖 → `dsh plugin --profile web install --prefer-offline`。
参数：`-DshHome`、`-Profile`、`-ProfileDir`、`-DryRun`、`-Yes`、`-Force`、`-SkipHostPatches`（测试用）。

### 8.8 `.cmd` 双击入口

| 文件 | 对应脚本 | 说明 |
|---|---|---|
| `0-先体检.cmd` | `diagnose.ps1` | 只读 |
| `1-一键修复.cmd` | `reapply-fix.mjs` | 先关 dsh web |
| `2-验证对话.cmd` | `verify-dsh-web.ps1` | 会调一次模型 |
| `3-回滚至报错状态.cmd` | `rollback.ps1` | 撤销补丁，回到报错状态 |
| `4-启动dsh-web.cmd` | — | 当前目录启动 dsh web |
| `5-停用插件.cmd` | `disable-plugin.ps1` | 可回溯 |
| `6-重新启用插件.cmd` | `enable-plugin.ps1` | 恢复停用 |
| `7-卸载插件.cmd` | `uninstall-plugin.ps1` | 不可逆，先快照 |

---

## 9. 验证方法

### 9.1 人工验证

重启 `dsh web`，发一句“你好”，能收到回复即成功；终端不应再出现 `Get-ItemProperty` 错误。

### 9.2 脚本验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-dsh-web.ps1"
```

### 9.3 只读断言（Agent 必做）

```powershell
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
$lib = Join-Path $dshHome "profiles\web\node_modules\dsh-purge\lib"

# A1
Select-String -Path "$lib\index.js" -Pattern "CWD_PROMPT_VARIABLE|installCwdVariable"
# A2
Select-String -Path "$lib\desktop.js" -Pattern "Get-ItemProperty -LiteralPath"
# A3
node --check "$lib\index.js"; node --check "$lib\desktop.js"
# A4
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\diagnose.ps1"
```

### 9.4 验证记录模板（Agent 报告用）

```text
[前置] dsh=<版本> dsh-purge=<版本> profile=<名称> DSH_HOME=<路径>
[A1] index.js 补丁：PASS/FAIL（证据：匹配行）
[A2] desktop.js 补丁：PASS/FAIL（证据：匹配行）
[A3] node --check：PASS/FAIL
[A4] diagnose：PASS/FAIL（FAIL 项）
[A5] 对话验证：通过/未执行（原因）
[备份] <备份目录>
```

---

## 10. 更新 / 重装后复发

### 10.1 先做三件事

1. **确认重启过**：旧 `dsh web` 进程不会热加载插件文件；
2. **跑体检**：`powershell -File scripts\diagnose.ps1`；
3. **看报错原文**：仍是 `{{cwd}}`？变成其它变量？`has no value`？

### 10.2 场景速查

| 更新了什么 | 典型现象 | 处理 |
|---|---|---|
| dsh-purge 升级/重装/重跑 `dsh plugin` | 问题原样复发；体检显示补丁缺失 | 运行 `reapply-fix.mjs`（10.4） |
| DSH 升级（npm 全局） | 插件文件通常还在，补丁仍有效；若报错变化看 10.5/10.8 | 先体检；多数无需处理 |
| 宿主未来自己注册 `cwd` | 体检显示“宿主原生 cwd 变量 已注册” | 无需补丁；可保留（重复注册被吞）或回滚 |
| 插件自己修好了（不再用 `{{cwd}}`） | identity.js 不再含 `{{cwd}}` | 可回滚本补丁 |
| 只出现 `Get-ItemProperty` 噪音 | 对话正常 | 重跑 `reapply-fix.mjs` 或手工 6.2 |

### 10.3 决策树

```text
重启 dsh web 后仍然不能对话
│
├─ 报错还是 unknown prompt variable "{{cwd}}"
│   ├─ 体检：index.js 补丁缺失     → dsh-purge 被更新/重装 → 运行 reapply-fix.mjs
│   ├─ 体检：补丁在但宿主无 cwd    → 插件可能没加载/别的 profile → 10.5 / 10.9
│   └─ 体检：宿主原生已注册 cwd    → 不应再报；确认是否旧进程/别的 profile
│
├─ 报错变成 prompt variable "{{cwd}}" has no value  → 10.8
├─ 报错是其它 {{xxx}}                              → 10.8
└─ 不是变量问题（网络/模型/凭据）                    → 按普通 DSH 故障排查
```

### 10.4 情况 A：插件更新/重装后复发

```powershell
# 关闭 dsh web 后
node ".\scripts\reapply-fix.mjs"
dsh web
```

如果报 `[FAIL] 锚点与 1.1.71 不一致`：

1. **推荐**：按第 7 节手工插入（语义相同即可，位置不必与旧版完全一致；只要在插件 `apply`
   阶段能拿到 `ctx.systemPrompt` 就能注册）；
2. **兜底**：用 10.5 的宿主补丁（不依赖插件锚点）。

### 10.5 情况 B：宿主升级后需要 Fallback（改宿主）

> 只在插件无法修改/锚点找不到时使用。**DSH 每次 npm 升级都会覆盖这个文件。**

文件：`(Get-Command dsh.cmd).Source` 反推的
`<npm bin>\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-agent-loop\lib\index.js`。

找到：

```js
ctx.systemPrompt.variable("provider", (context) => context.agent?.options.provider);
ctx.systemPrompt.variable("model", (context) => context.agent?.options.model);
```

在下一行插入：

```js
ctx.systemPrompt.variable("cwd", (context) => {
  try {
    const session = context.agent?.session;
    if (session !== undefined) {
      const service = ctx.get("workingDirectory");
      if (service !== undefined) {
        const live = String(service.get(session) || "").trim();
        if (live) return live;
      }
      const recorded = String(session?.header?.cwd || "").trim();
      if (recorded) return recorded;
    }
  } catch { /* ignore */ }
  return process.cwd();
});
```

保存后 `node --check` 该文件，重启 `dsh web`。副作用：所有 profile 都拥有 `cwd` 变量；
若宿主以后自己注册 `cwd`，删掉这段即可。

### 10.6 情况 C：宿主未来原生支持 `cwd`

```powershell
$dsh = Split-Path (Get-Command dsh.cmd).Source -Parent
Select-String -Path "$dsh\node_modules\@deepseek-ai\dsh-agent-loop\lib\index.js" -Pattern 'systemPrompt\.variable\('
```

输出里出现 `"cwd"` → 插件补丁非必需；重复注册会被安全忽略。若出现重复注册告警/异常，
用 `rollback.ps1` 回滚插件补丁即可。

### 10.7 情况 D：插件自己修复了

体检显示 `identity.js` 不再含 `{{cwd}}` → 可保留补丁（无害）或回滚；先跑验证确认。

### 10.8 其它报错

**`prompt variable "{{cwd}}" has no value for this assembly`**
变量已注册但 provider 返回 `undefined`。通常是补丁被改坏（漏了最后的 `return process.cwd()`），
或宿主 API 变化。重新运行 `reapply-fix.mjs`。

**其它 `{{xxx}}` 变量**
同一机制：给宿主补注册 `xxx`（provider 返回字符串），或让插件不再使用它。
快速定位已注册变量：

```powershell
$dsh = Split-Path (Get-Command dsh.cmd).Source -Parent
Select-String -Path "$dsh\node_modules\@deepseek-ai\dsh-agent-loop\lib\index.js" -Pattern 'systemPrompt\.variable\('
```

### 10.9 桌面端与 `dsh web` 的历史不互通（另一个问题）

如果桌面端与 CLI 版本不同却共享同一个 `DSH_HOME\sessions`，较旧的一侧读取较新一侧写的
会话时可能报：

```text
failed to observe session ...: contains event type "job/registered" (seq N)
unknown to this harness and not marked ignorable; refusing to interpret the log
```

这是**宿主版本前向不兼容**，不是会话损坏，也不是本修复能解决的。处理方式二选一：

1. 把 CLI 升级到与桌面端一致的版本（版本对齐后历史可互通）；
2. 让 CLI 使用独立的 `DSH_HOME`（历史隔离）。

> 改版本/换 DSH_HOME 前请先备份会话目录。此问题不属于本仓库补丁范围。

---

## 11. 撤销修复、停用、彻底卸载

### 11.1 四概念对比

| 操作 | 入口 | 插件文件 | 插件是否加载 | DSH 程序补丁 | 对话 | 可恢复 |
|---|---|---|---|---|---|---|
| 保持修复 | `1-一键修复.cmd` | 在 | 是 | 已打 | ✅ | — |
| **撤销修复** | `3-回滚至报错状态.cmd` | 在 | 是 | 维持现状 | ❌ 报 `{{cwd}}` | ✅ 重新运行 `1` |
| **停用** | `5-停用插件.cmd` | 在 | 否 | 还原官方原版 | ✅ 无插件功能 | ✅ 用 `6` |
| **彻底卸载** | `7-卸载插件.cmd` | 删除 | 否 | 还原官方原版 | ✅ 无插件 | ⚠️ 按快照手工恢复 |

> `3-回滚至报错状态.cmd` 是“撤销本修复”，不是卸载。名字里的“报错状态”指补丁前、
> 当前 DSH 上会报 `{{cwd}}` 的状态。

### 11.2 `3-回滚至报错状态` 的细节

`rollback.ps1` 从 `reapply-fix.mjs` 写入前的自动备份恢复：

```text
%USERPROFILE%\.dsh\dsh-purge\patch-backup\
  index.js.index.js-<时间戳>
  desktop.js.desktop.js-<时间戳>
```

- 存在备份 → 恢复两个文件（恢复前把当前文件另存到 `rollback-safety-<时间戳>\`）；
- 不存在备份（例如补丁是手工打的、备份被清理、插件重装过）→ 不修改文件，提示重装插件恢复官方版；
- 恢复后需要重启 `dsh web`；此时 `{{cwd}}` 报错与 `Get-ItemProperty` 噪音都会回来，属预期。

### 11.3 停用（`5-停用插件.cmd`）

1. 快照 `package.json`、`prompt-inject.md`、补丁状态；
2. `dsh-purge --revert` 还原宿主程序补丁；
3. 从 `dsh.profile.bundles` 移除 `dsh-purge`；
4. 保留插件文件、依赖、规则库、提示词；
5. 快照目录：`%USERPROFILE%\.dsh\dsh-purge\patch-backup\lifecycle\plugin-state-*-disable\`；
6. 需重启 `dsh web`。

### 11.4 重新启用（`6-重新启用插件.cmd`）

读取最近一次停用快照，把 `dsh-purge` 插回原来的 bundles 索引，执行
`dsh-purge --apply` 重打宿主补丁；需重启 `dsh web`。
若提示“提示词和规则集都是空的”，打开插件界面手动点「应用」，或补 `prompt-inject.md`。

### 11.5 彻底卸载（`7-卸载插件.cmd`）

先做快照，再还原全部宿主补丁/注入/规则，删除插件文件与数据
（`node_modules\dsh-purge`、`$DSH_HOME\dsh-purge`、`$DSH_HOME\redteam`），
清理所有 profile 的 bundles 与依赖，最后 `dsh plugin install` 清理 lockfile。
其它插件不受影响。卸载后想装回来：

```powershell
dsh plugin --profile web add github:YuJunZhiXue/dsh-purge
# 把 "dsh-purge" 加回 profiles\web\package.json 的 dsh.profile.bundles
dsh web
node ".\scripts\reapply-fix.mjs"
```

### 11.6 快照与手工恢复

| 快照目录 | 由谁生成 | 用途 |
|---|---|---|
| `patch-backup\index.js.*` / `desktop.js.*` | `reapply-fix.mjs` | `rollback.ps1` 使用 |
| `patch-backup\rollback-safety-*` | `rollback.ps1` | 回滚前的当前文件 |
| `patch-backup\lifecycle\plugin-state-*-disable` | 停用 | `enable-plugin.ps1` 读取 |
| `patch-backup\lifecycle\plugin-uninstall-*` | 卸载 | 手工恢复（复制 `home\`、`profile\` 后重装插件） |

---

## 12. 常见问题

| 问题 | 处理 |
|---|---|
| 双击 `1-一键修复.cmd` 提示找不到 Node.js | 安装 Node.js，或改 `node .\scripts\reapply-fix.mjs` |
| 提示找不到插件目录 | 确认插件已安装；用 `--profile`/`--lib-dir` 指定实际路径 |
| 脚本报锚点不一致 | 插件大改版：按第 7 节手工插入，或 10.5 宿主兜底 |
| 修复后仍报 `unknown prompt variable` | 确认 `dsh web` 已重启；再跑 `0-先体检.cmd` |
| 报 `prompt variable "{{cwd}}" has no value` | provider 被改坏，重新运行 `1-一键修复.cmd` |
| 报的是其它变量 `{{xxx}}` | 给宿主补注册该变量，或让插件不再使用（10.8） |
| 停用/启用后没变化 | 必须重启 `dsh web` |
| 双击 `3-回滚至报错状态.cmd` 提示没有自动备份 | 说明补丁不是通过 `1` 打的、备份被清理、或插件重装过。重装插件恢复官方版；或继续用修复就重跑 `1` |
| 卸载时提示 dsh web 在运行 | 先关闭 dsh web，再重试；确认要强删可加 `-Force` |
| 卸载删不干净（目录被占用） | 关闭所有 dsh/node 进程后重跑 `7`；快照不会丢 |
| 想恢复官方原版插件 | 重装插件覆盖本地补丁：`dsh plugin --profile web add github:YuJunZhiXue/dsh-purge` |
| 桌面端与 web 历史不互通 | 见 10.9（宿主版本不一致，与本修复无关） |

---

## 13. 隐私与可迁移性

### 13.1 仓库内没有个人信息

- 没有用户名、机器名、`C:\Users\<name>` 绝对路径、邮箱、token、API key、代理地址、
  会话 ID、聊天记录；
- 脚本运行时才从 `$env:DSH_HOME` / `%USERPROFILE%` 解析路径，且只用于定位用户自己的环境；
- 验证脚本创建的测试会话结束后删除；日志在系统临时目录。

可用以下命令自检（应无输出）：

```powershell
Get-ChildItem -Recurse . -File |
  Select-String -Pattern 'C:\\Users\\[^\\]+|@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|token=[A-Za-z0-9_-]{8,}'
```

### 13.2 换机器/换 profile 也能用

| 场景 | 用法 |
|---|---|
| 默认 profile `web` | 直接运行脚本 |
| 其它 profile | `--profile tui` / `-Profile tui` |
| 非默认安装路径 | `--lib-dir "<...>\dsh-purge\lib"` |
| 非 Windows | `.ps1/.cmd` 不可用；按第 7 节手工插入 helper，或把 diff 应用到插件文件 |
| 宿主未来注册 `cwd` | 补丁可保留（重复注册被吞）；或回滚 |

### 13.3 不修改的东西

宿主文件、其它插件、模型配置、API 凭据、会话记录、profile 的其它 bundle。
正常路径只写：

```text
<DSH_HOME>\profiles\<profile>\node_modules\dsh-purge\lib\index.js
<DSH_HOME>\profiles\<profile>\node_modules\dsh-purge\lib\desktop.js
<DSH_HOME>\dsh-purge\patch-backup\...
```

---

## 14. 附录

### A. 原始报错与终端输出

```text
本轮运行失败unknown prompt variable "{{cwd}}" in section "deployment:persona-suffix";
registered variables: provider, model
```

```text
Get-ItemProperty : 指定的转换无效。
所在位置 行:11 字符: 10
+     $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
+          ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (:) [Get-ItemProperty], InvalidCastException
```

### B. 宿主源码摘录

> 基于 `@deepseek-ai/dsh` 0.2.1-alpha.2 实测；升级后行号可能变化，以函数/常量名为准。

#### B.1 `dsh-system-prompt/lib/index.js`

```js
const PERSONA_PREFIX_SECTION = "deployment:persona-prefix";
const PERSONA_SUFFIX_SECTION = "deployment:persona-suffix";
const VARIABLE_NAME = /^[a-z][a-z0-9_]*$/;
const GROUP_AT = /^\{\{([^{}]*)\}\}/;

function renderPrompt(assembly) {
  return assembly.sections
    .map((section) => section.interpolate === false ? section.text : interpolate(section, assembly.variables, "section"))
    .filter((text) => typeof text === "string" && text.length > 0)
    .join("\n\n");
}

function interpolate(input, variables, kind) {
  // 见 5.3；未知变量与 undefined 值都会抛错
}

variable(name, provider) {
  if (!VARIABLE_NAME.test(name)) throw new Error(`invalid prompt variable name "${name}" ...`);
  return this.layers.effect(this.ctx, (layer) => layer.variables.insert(name, provider), { label: "systemPrompt.variable()" });
}

async assemble(context = {}) {
  const scope = context.scope;
  const scopeLayers = this.layers.chainLayers(scope);
  const variables = {};
  for (const [name, provider] of this.layers.global.variables.entries()) variables[name] = provider(context);
  for (const layer of scopeLayers) for (const [name, provider] of layer.variables.entries()) variables[name] = provider(context);
  ...
  const assembly = { sections, contexts, tools, variables };
  const transformed = await this.ctx.waterfall(..., "system-prompt/assemble", assembly, context, ...);
  return transformed;
}
```

#### B.2 `dsh-agent-loop/lib/index.js`

```js
ctx.systemPrompt.variable("provider", (context) => context.agent?.options.provider);
ctx.systemPrompt.variable("model", (context) => context.agent?.options.model);
...
const assembly = await dshPurgeAssemble.assemble(assembleContextFor(this, signal));
...
let renderedPrompt = renderPrompt(assembly);   // ← 这里抛 unknown prompt variable
```

#### B.3 `dsh-working-directory/lib/index.js`

```js
ctx.systemPrompt.context({
  name: "working-directory:current",
  order: ctx.systemPrompt.getContextOrder("WORKING_DIRECTORY"),
  required: true,
  interpolate: false,
  text: (context) => context.agent === void 0 ? "" : this.contextText(context.agent.session)
});
...
contextText(session) {
  return `Current working directory: ${JSON.stringify(this.get(session))}.`;
}
```

### C. 插件源码摘录（dsh-purge 1.1.71）

```yaml
# cordis.patch.yml
- id: system-prompt
  config:
    includeHarnessIdentity: false
    personaPrefix: ""
    personaSuffix: Your working directory is {{cwd}}.
```

```js
// lib/identity.js
export const CWD_ONLY_SUFFIX = "Your working directory is {{cwd}}.";
const DSH_INTERPOLATE_ALLOWED = new Set(["cwd", "model", "provider"]);

export function escapeDshInterpolation(text) {
  const src = String(text || "");
  if (!src.includes("{{")) return src;
  return src.replace(/\{\{([^{}]*)\}\}|(\{\{)/g, (all, name, open) => {
    if (name !== undefined && DSH_INTERPOLATE_ALLOWED.has(name)) return all;
    if (open) return "{ {";
    return `{ {${name}}}`;
  });
}

// overlayOfficialIdentity() 中：
if (name === "deployment:persona-suffix" || name === "persona-suffix") {
  sawSuffix = true;
  const raw = String(section.text || "");
  if (!raw.trim() || looksLikeOfficialIdentity(raw) || isCwdOnlyText(raw)) {
    out.push({ ...section, text: CWD_ONLY_SUFFIX });
  } else {
    out.push(section);
  }
  continue;
}
...
if (!sawSuffix) {
  out.push({ name: "deployment:persona-suffix", text: CWD_ONLY_SUFFIX, order: 10200 });
}
```

```js
// lib/desktop.js（原始行）
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
```

### D. 完整 diff

**D.1 `patches/cwd-variable.patch`**

```diff
diff --git a/lib/index.js b/lib/index.js
index 8e43938..5092e80 100644
--- a/lib/index.js
+++ b/lib/index.js
@@ -377,6 +377,7 @@ function addPromptSection(ctx, section) {
 }
 
 export function registerPromptSections(ctx, config) {
+  installCwdVariable(ctx);
   addPromptSection(ctx, {
     name: "dsh-purge",
     order: GLOBAL_PROMPT_ORDER,
@@ -670,6 +671,75 @@ function installCwdCapture(ctx) {
   });
 }
 
+const CWD_PROMPT_VARIABLE = "cwd";
+
+/** 组装期解析当前工作目录；任何异常都退回启动目录，变量必须有字符串值。 */
+function promptCwdFor(ctx, context) {
+  try {
+    const session = context?.agent?.session;
+    if (session) {
+      const service = typeof ctx?.get === "function" ? ctx.get("workingDirectory") : undefined;
+      if (service && typeof service.get === "function") {
+        const live = String(service.get(session) || "").trim();
+        if (live) return live;
+      }
+      const recorded = String(session?.header?.cwd || "").trim();
+      if (recorded) return recorded;
+    }
+  } catch { /* 变量补齐永不阻断组装 */ }
+  try { return process.cwd(); } catch { return ""; }
+}
+
+/** 与 addPromptSection 同源的多 ctx 注册；宿主已注册同名变量时保留宿主实现。 */
+function addPromptVariable(ctx, name, provider) {
+  const hosts = [];
+  const push = (host) => {
+    if (host && !hosts.includes(host)) hosts.push(host);
+  };
+  try { push(ctx?.systemPrompt?.ctx); } catch { /* 代理未注入时点属性会抛 */ }
+  push(ctx);
+  const disposers = [];
+  let covered = false;
+  for (const host of hosts) {
+    try {
+      const prompt = host?.systemPrompt;
+      if (!prompt || typeof prompt.variable !== "function") continue;
+      const d = prompt.variable(name, provider);
+      covered = true;
+      if (typeof d === "function") disposers.push(d);
+    } catch (error) {
+      const msg = String(error && error.message || error);
+      if (msg.includes("already registered")) covered = true;
+      else console.warn(`[dsh-purge] prompt variable ${name}: ${msg}`);
+    }
+  }
+  if (disposers.length && typeof ctx?.effect === "function") {
+    try {
+      ctx.effect(() => () => {
+        for (const d of disposers) {
+          try { d(); } catch { /* ignore */ }
+        }
+      });
+    } catch { /* 死 ctx */ }
+  }
+  return covered;
+}
+
+/**
+ * DSH 0.2.1-alpha 起 prompt 插值只注册 provider/model，不再注册 cwd。
+ * 插件自己写的 `Your working directory is {{cwd}}.` 在渲染阶段会整段抛
+ * unknown prompt variable，导致每一轮都「本轮运行失败」。这里把 cwd 补回
+ * 变量层，保持旧宿主的行为；注册失败只告警，不拖垮插件。
+ */
+function installCwdVariable(ctx) {
+  if (!ctx || ctx.__dshPurgeCwdVariable) return;
+  let covered = false;
+  try {
+    covered = addPromptVariable(ctx, CWD_PROMPT_VARIABLE, (context) => promptCwdFor(ctx, context));
+  } catch { covered = false; }
+  if (covered) ctx.__dshPurgeCwdVariable = true;
+}
+
 function installRewindDeriveFilter(ctx) {
   if (!ctx || ctx.__dshPurgeRewindDerive) return;
   ctx.__dshPurgeRewindDerive = true;
```

**D.2 `patches/desktop-registry-scan.patch`**

```diff
diff --git a/lib/desktop.js b/lib/desktop.js
index 6c60439..cc4f3bb 100644
--- a/lib/desktop.js
+++ b/lib/desktop.js
@@ -316,7 +316,7 @@ $roots = @(
 $rows = foreach ($root in $roots) {
   if (-not (Test-Path $root)) { continue }
   Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
-    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
+    try { $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop } catch { return }
     if (-not $p.DisplayName) { return }
     $hit = $false
     foreach ($n in $names) { if ($p.DisplayName -like ('*' + $n + '*')) { $hit = $true } }
```

> diff 里的 `index 8e43938..` 等是 git 对文件内容的缩略哈希，仅用于人工核对；
> 插件升级后哈希变化不代表补丁失效。

### E. 术语表

| 术语 | 含义 |
|---|---|
| system prompt assembly | 每轮请求前把 sections/contexts/tools/variables 组装成系统提示词 |
| section | 系统提示词的有序段落（如 `deployment:persona-suffix`） |
| context | 动态运行时上下文（工作目录、沙箱策略等），通常原样输出 |
| variable | 插值变量，`{{name}}` 渲染时被 provider 返回值替换 |
| interpolate: false | 该段不做 `{{}}` 替换 |
| waterfall | Cordis 中间件式事件链；插件可在 `system-prompt/assemble` 改写结果 |
| provider / model | 宿主原本注册的两个变量 |
| pnpm 硬链接 | 内容寻址仓库与 node_modules 共享 inode 的链接方式 |

### F. 命令速查

```powershell
# 版本 / 路径
dsh --version
node -v
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
$lib = Join-Path $dshHome "profiles\web\node_modules\dsh-purge\lib"

# 就诊 / 修复 / 撤销 / 验证
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\diagnose.ps1"
node ".\scripts\reapply-fix.mjs"
node ".\scripts\reapply-fix.mjs" --dry-run
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\rollback.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-dsh-web.ps1"

# 断言
Select-String -Path "$lib\index.js" -Pattern "CWD_PROMPT_VARIABLE|installCwdVariable"
Select-String -Path "$lib\desktop.js" -Pattern "Get-ItemProperty -LiteralPath"
node --check "$lib\index.js"; node --check "$lib\desktop.js"

# 宿主变量
$dsh = Split-Path (Get-Command dsh.cmd).Source -Parent
Select-String -Path "$dsh\node_modules\@deepseek-ai\dsh-agent-loop\lib\index.js" -Pattern 'systemPrompt\.variable\('

# 停用 / 启用 / 卸载
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\disable-plugin.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\enable-plugin.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\uninstall-plugin.ps1"
```

### G. 相关故障

- [持久终端冲突修复.md](持久终端冲突修复.md)：启用 `optional-terminal-bash` 时
  `PTY backend "shell" already registered` 的处理（与本文无关）。
- 桌面端与 `dsh web` 历史不互通：见 10.9。

### H. 变更记录

| 日期 | 版本 | 内容 |
|---|---|---|
| 2026-10-17 | 1.0 | 首次修复：确认根因，插件内补注册 `cwd` 变量 + 注册表扫描噪音；实机验证 |
| 2026-10-17 | 1.1 | 增加中文双击入口、只读体检、端到端验证、停用/启用/卸载脚本 |
| 2026-10-17 | 1.2 | 仓库化：脚本自包含、路径自动探测、去隐私、撤销修复语义明确化 |
| 2026-10-17 | 1.3 | 详细版 README：补充 DSH 内核机制、完整代码/diff、Agent 操作契约与验收断言 |

### I. License 与致谢

[MIT](LICENSE)。非官方兼容性修复，与 DeepSeek 无关。
`DeepSeek Harness`、`DSH`、`@deepseek-ai/*`、`dsh-purge` 等名称归各自所有者。
感谢 [dsh-purge](https://github.com/YuJunZhiXue/dsh-purge) 作者。
本仓库只包含兼容代码、diff 与说明，不重新分发第三方完整源文件。
