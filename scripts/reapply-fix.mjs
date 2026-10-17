#!/usr/bin/env node
/**
 * DSH × dsh-purge「unknown prompt variable "{{cwd}}"」一键修复
 * =============================================================================
 * 适用：dsh web 每轮都报
 *   unknown prompt variable "{{cwd}}" in section "deployment:persona-suffix";
 *   registered variables: provider, model
 *
 * 做两件事（幂等，可重复运行）：
 *   1) lib/index.js    —— 给 DSH 的 systemPrompt 变量层补注册一个 `cwd` 变量
 *   2) lib/desktop.js  —— 修掉启动时 PowerShell 注册表扫描的
 *                          "Get-ItemProperty : 指定的转换无效" 噪音
 *
 * 只在插件自己的文件里加兼容代码；不改宿主、模型、凭据、端口、会话数据。
 *
 * 用法（先关闭 dsh web）：
 *   node scripts/reapply-fix.mjs                 # 自动定位 %USERPROFILE%\.dsh\profiles\web
 *   node scripts/reapply-fix.mjs --dry-run       # 只检查，不写文件
 *   node scripts/reapply-fix.mjs --profile tui   # 其它 profile
 *   node scripts/reapply-fix.mjs --lib-dir "C:\...\node_modules\dsh-purge\lib"
 *
 * 退出码：0 = 修复完成 / 本来已修好；1 = 锚点不匹配，需要按 README 手工处理。
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RAW_ARGS = process.argv.slice(2);

function argValue(name, fallback = "") {
  const i = RAW_ARGS.indexOf(name);
  if (i < 0) return fallback;
  return RAW_ARGS[i + 1] ?? fallback;
}
function hasFlag(name) {
  return RAW_ARGS.includes(name);
}
function info(message) {
  console.log(message);
}
function fail(message) {
  console.error("\n[FAIL] " + message);
  console.error("       请打开 README.md 的「更新 / 重装后复发」一节手工处理。");
  process.exit(1);
}

const dryRun = hasFlag("--dry-run");
const dshHome = process.env.DSH_HOME || path.join(os.homedir(), ".dsh");
const profile = argValue("--profile", "web");
const libDir = path.resolve(
  argValue("--lib-dir", path.join(dshHome, "profiles", profile, "node_modules", "dsh-purge", "lib")),
);
const backupDir = path.resolve(argValue("--backup-dir", path.join(dshHome, "dsh-purge", "patch-backup")));
const helperFile = path.join(HERE, "patch-data", "cwd-variable-helper.txt");

// ── 锚点与标记（dsh-purge 1.1.71 实测）──────────────────────────────────────
const INDEX_MARKERS = ["CWD_PROMPT_VARIABLE", "installCwdVariable"];
const INDEX_CALL_ANCHOR = "export function registerPromptSections(ctx, config) {\n  addPromptSection(ctx, {";
const INDEX_HELPER_ANCHOR = "function installRewindDeriveFilter(ctx) {";
const DESKTOP_BROKEN_LINE =
  "    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue";
const DESKTOP_FIXED_LINE =
  "    try { $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop } catch { return }";

const indexPath = path.join(libDir, "index.js");
const desktopPath = path.join(libDir, "desktop.js");

function readUtf8(file) {
  return fs.readFileSync(file, "utf8");
}

function pluginVersion() {
  try {
    const pkg = JSON.parse(readUtf8(path.join(libDir, "..", "package.json")));
    return { version: pkg.version || "unknown", dshTarget: pkg.dshTarget || "unknown" };
  } catch {
    return { version: "unknown", dshTarget: "unknown" };
  }
}

/** 从 scripts/patch-data/cwd-variable-helper.txt 读取要插入 index.js 的补丁代码块。 */
function loadHelperBlock() {
  if (!fs.existsSync(helperFile)) fail(`缺少补丁代码文件：${helperFile}`);
  const block = readUtf8(helperFile).replace(/\s+$/, "") + "\n\n";
  if (!block.includes("function installCwdVariable(ctx)")) {
    fail(`补丁代码文件内容异常：${helperFile}`);
  }
  return block;
}

function backupFile(file, tag) {
  if (dryRun) return "(dry-run 未备份)";
  if (!fs.existsSync(backupDir)) fs.mkdirSync(backupDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const dst = path.join(backupDir, path.basename(file) + "." + tag + "-" + stamp);
  fs.copyFileSync(file, dst);
  return dst;
}

/**
 * 原子写入并断开 pnpm 硬链接：先写临时文件，再 unlink 目标、rename 覆盖。
 * 这样不会把内容写进 pnpm 的内容寻址仓库，避免后续 install 校验异常。
 */
function writeAtomic(file, text) {
  const tmp = path.join(path.dirname(file), "." + path.basename(file) + ".dshfix-" + process.pid + ".tmp");
  fs.writeFileSync(tmp, text, "utf8");
  try {
    fs.unlinkSync(file);
  } catch {
    /* 目标不存在时忽略 */
  }
  fs.renameSync(tmp, file);
}

// ── 开始 ─────────────────────────────────────────────────────────────────────
const version = pluginVersion();
info("============================================================");
info(" dsh-purge {{cwd}} 变量修复工具");
info("------------------------------------------------------------");
info(` 插件目录 : ${libDir}`);
info(` 插件版本 : ${version.version}  (dshTarget: ${version.dshTarget})`);
info(` 备份目录 : ${backupDir}`);
info(` 模式     : ${dryRun ? "DRY-RUN（只检查）" : "写入"}`);
info("============================================================");

for (const target of [indexPath, desktopPath]) {
  if (!fs.existsSync(target)) {
    fail(`找不到插件文件：${target}\n       请确认 --profile / --lib-dir 是否正确。`);
  }
}

// 1) index.js —— 补注册 cwd 变量
const indexText = readUtf8(indexPath);
const indexMarkerCount = INDEX_MARKERS.filter((marker) => indexText.includes(marker)).length;
if (indexMarkerCount === INDEX_MARKERS.length) {
  info("[OK] index.js：cwd 变量补丁已在，跳过。");
} else if (indexMarkerCount > 0) {
  fail("index.js：检测到“部分补丁”状态（只命中部分标记）。请先重装插件或按 README 手工处理。");
} else {
  if (!indexText.includes(INDEX_CALL_ANCHOR) || !indexText.includes(INDEX_HELPER_ANCHOR)) {
    fail(
      "index.js：锚点与 dsh-purge 1.1.71 不一致（插件可能大改）。\n" +
        `       需要原样出现：\n         A) ${JSON.stringify(INDEX_CALL_ANCHOR.split("\n")[0])} …\n         B) ${JSON.stringify(INDEX_HELPER_ANCHOR)}`,
    );
  }
  const block = loadHelperBlock();
  const backup = backupFile(indexPath, "index.js");
  let patched = indexText.replace(
    INDEX_CALL_ANCHOR,
    "export function registerPromptSections(ctx, config) {\n  installCwdVariable(ctx);\n  addPromptSection(ctx, {",
  );
  const insertAt = patched.indexOf(INDEX_HELPER_ANCHOR);
  if (insertAt < 0) fail("index.js：插入点消失，已中止（原文件未动）。");
  patched = patched.slice(0, insertAt) + block + patched.slice(insertAt);
  if (dryRun) {
    info("[DRY] index.js：将插入 cwd 变量补丁。");
  } else {
    writeAtomic(indexPath, patched);
    info(`[OK] index.js：cwd 变量补丁已写入。备份 -> ${backup}`);
  }
}

// 2) desktop.js —— 修掉注册表扫描的 InvalidCastException 噪音
const desktopText = readUtf8(desktopPath);
if (desktopText.includes(DESKTOP_FIXED_LINE.trim())) {
  info("[OK] desktop.js：注册表扫描补丁已在，跳过。");
} else if (desktopText.includes(DESKTOP_BROKEN_LINE)) {
  const backup = backupFile(desktopPath, "desktop.js");
  const patched = desktopText.replace(DESKTOP_BROKEN_LINE, DESKTOP_FIXED_LINE);
  if (dryRun) {
    info("[DRY] desktop.js：将替换注册表扫描那一行。");
  } else {
    writeAtomic(desktopPath, patched);
    info(`[OK] desktop.js：注册表扫描噪音已修。备份 -> ${backup}`);
  }
} else {
  info("[OK] desktop.js：没有找到 1.1.71 的原始行（可能插件已改版），跳过。");
}

// 3) 语法自检（不启动 dsh）
for (const file of [indexPath, desktopPath]) {
  try {
    const { spawnSync } = await import("node:child_process");
    const result = spawnSync(process.execPath, ["--check", file], { stdio: "ignore", windowsHide: true });
    if (result.status !== 0) fail(`语法检查失败：${file}（请从备份恢复）`);
    info(`[OK] 语法检查通过：${path.basename(file)}`);
  } catch {
    info(`[SKIP] 语法检查未能执行：${path.basename(file)}（可手工 node --check）`);
  }
}

info("");
info(dryRun ? "[DRY-RUN] 未修改任何文件。" : "[DONE] 补丁处理完成。请重启 dsh web，然后发一句话验证。");
process.exit(0);
