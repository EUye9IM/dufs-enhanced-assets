# Implement · MVP-A 视频播放入口

> 执行顺序有意义：先备验证环境，再改代码，每步都可独立验证。**任一步失败即停，不要继续叠加改动。**

## 步骤 0 · 验证环境（前置，非代码改动）

- [x] 0.1 取得 dufs 二进制（三选一，按顺序试）：
  1. 官方 release（优先，走代理 `http://localhost:10808`）：
     ```bash
     export https_proxy=http://localhost:10808 http_proxy=http://localhost:10808
     cd /tmp && curl -fL -o dufs.tgz \
       https://github.com/sigoden/dufs/releases/download/v0.47.0/dufs-v0.47.0-x86_64-unknown-linux-musl.tar.gz \
       && tar xzf dufs.tgz && ./dufs --version
     ```
     若资产名不对，先 `curl -s https://api.github.com/repos/sigoden/dufs/releases/tags/v0.47.0 | grep browser_download_url` 确认
  2. `cargo install dufs --version 0.47.0 --root /tmp/dufs-install`（同样挂代理）
  3. 本地编译：`cd ../dufs && cargo build --release`（不联网，但耗时）
- [x] 0.2 生成夹具到 `/tmp/dufs-fixtures`（命令见 `design.md` §6：`hevc.mkv` / `mpeg4.avi` / `h264.mp4`）
- [x] 0.3 用 `ffprobe` 确认夹具编码：`ffprobe -v error -show_entries stream=codec_name -of csv /tmp/dufs-fixtures/hevc.mkv` 应输出 `hevc`
- [x] 0.4 起服务：`DUFS_BIN=/tmp/dufs`（或 `../dufs/target/release/dufs`）；`$DUFS_BIN /tmp/dufs-fixtures --assets "$PWD" --allow-upload --allow-delete --bind 127.0.0.1 --port 5000`

**Gate 0**：`P=/__dufs_v0.47.0__`；`curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://127.0.0.1:5000$P/movi.wasm` 应为 `200 application/wasm`；`.../movi.js` 应为 `200 text/javascript`。
→ 已验证（见 `research/verified-contracts.md` §1、§2）：**必须带 `/__dufs_v0.47.0__/` 前缀，否则 404**。不通过就不要往下做。

## 步骤 1 · `index.html`：暴露资源前缀

- [x] 1.1 在 `<head>` 内、`<link rel="stylesheet">` 之后加 `<meta name="dufs-assets-prefix" content="__ASSETS_PREFIX__">`
- [x] 1.2 检查占位符已被替换（**注意：curl 会被识别为终端浏览器而返回 noscript 页，必须带浏览器 UA**）：
  ```bash
  UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
  curl -s -A "$UA" http://127.0.0.1:5000/ | grep -o '<meta name="dufs-assets-prefix"[^>]*>'
  # 	→ <meta name="dufs-assets-prefix" content="/__dufs_v0.47.0__/">
  ```

**Gate 1**：渲染后的 HTML 里不再出现字面量 `__ASSETS_PREFIX__`，且 meta 的 content 以 `/` 开头以 `/` 结尾。
（已实测：`?view` 页不受 noscript 分支影响，可直接 curl；仅目录页需要 UA。）

## 步骤 2 · `index.js`：常量 + 图标 + 播放入口

- [x] 2.1 新增 `MEDIA_VIDEO_FORMATS` 常量（D6 的 16 个扩展名，全小写）
- [x] 2.2 新增 `ICONS.play`（16×16 SVG，风格与 `ICONS.view` / `ICONS.download` 一致）
- [x] 2.3 `addPath()`：计算 `isVideo`（复用 `extName()`，`toLowerCase()`），生成 `actionPlay`（带 `target="_blank"`，D7），插入 `actionCell` 中 `actionDownload` 之前
- [x] 2.3b **去重**：把 `actionView` 的条件（`index.js:566`）改为 `!actionEdit && !isDir && !isVideo`，避免与 ▶ 重复
- [x] 2.4 确认 `actionPlay` 的条件**不依赖** `DATA.allow_upload` / `DATA.allow_delete`（`actionView` 的 `!actionEdit` 抑制逻辑与本按钮无关）

**Gate 2**：目录页上 `.mkv/.avi/.mp4` 有 ▶；`.txt/.pdf/.jpg/.zip` 无 ▶；视频行**没有**重复的「View file」图标；点 ▶ 后**目录页仍在**且播放页在新标签（D7）。分别在「`--allow-upload --allow-delete`」与「只读」两种启动参数下各看一遍（AC-1、AC-2、AC-2b）。

## 步骤 3 · `index.js`：播放器加载器

- [x] 3.1 新增模块级 `moviLoadPromise` 与 `loadMovi()`（实现见 `design.md` §3.2d）
- [x] 3.2 `script.src = prefix + MOVI_SCRIPT`，其中 `prefix` 从 meta 读取，**缺省 `""`**
- [x] 3.3 `onload` 后等 `customElements.whenDefined("movi-player")` 再 resolve；`onerror` reject
- [x] 3.4 **不要**在本文件里手改 `movi.js` 的任何内容

**Gate 3**：在浏览器 console 执行 `await loadMovi()` → `customElements.get("movi-player")` 返回构造函数；连续执行两次不产生第二个 `script[src*="movi.js"]` 节点。

## 步骤 4 · `index.js`：播放页分支

- [x] 4.1 `setupEditorPage()` 的 `if (!DATA.editable)` 块内，**最先**判 `MEDIA_VIDEO_FORMATS.includes(ext)` → 调 `mountVideoPlayer(baseUrl(), $notEditable)` 并 `return`
- [x] 4.2 原有 iframe 分支与 "Cannot edit..." 分支**保持原样**，仅位置下移
- [x] 4.3 新增 `mountVideoPlayer()`（见 `design.md` §3.2f）：先 `await loadMovi()`，再创建 `<movi-player src=url controls>`，失败只改文案
- [x] 4.4 确认传给元素的 `src` 来自 `baseUrl()`（不含 `?view`）

**Gate 4**：点 `.mkv` 的 ▶ → URL 变为 `<file>?view` → 播放器出现 → **可播、可拖进度条**（AC-3、AC-4）。`.ts`/`.rmvb` 至少手动试一个。

## 步骤 5 · `index.css`：布局

- [x] 5.1 加 `body.has-movi-player` 作用域的 `.editor-page` 高度规则
- [x] 5.2 `.movi-player { display:block; width:100%; height:100%; background:#000 }`
- [x] 5.3 `movi-player:not(:defined) { display:none }`
- [x] 5.4 校准 `.head` 实际高度，不要留白或溢出滚动条

**Gate 5**：播放器占满视口剩余区域；文本 `?view` / `?edit` 页布局**未变**（AC-11 回归的一部分）。

## 步骤 6 · 降级与认证验证（不改代码，只验证）

- [x] 6.1 AC-7：目录页 / 文本页 Network 里无 `movi.js`、`movi.wasm`
- [x] 6.2 AC-8：临时 `mv movi.js movi.js.bak` → 播放页出现可读错误 + 下载可用 → 还原
- [x] 6.3 AC-9：`--auth 'a:pass123@/:rw' --auth-method basic` 下播放 + seek
- [x] 6.4 AC-10：`--auth 'a:pass123@/:rw' --auth-method digest`（**注意语法**：`user:pass@/path:rw`，写成 `a:b` 会报 `Invalid auth`）下播放 + seek；HTTP 层已实测 206（见 research §7），**浏览器内的并行 Range 仍需实测**；失败不要绕过，记录结论
- [x] 6.5 AC-11：上传 / 断点续传 / 删除 / 移动 / 文本编辑保存 / 搜索 / zip / 排序 / 登出 逐项点一遍
- [x] 6.6 AC-6：文件名链接仍是新标签直开
- [ ] 6.7 多标签并发：同时开 3 个视频标签，确认不串台、不全部卡死（**本版未做**，见 prd Known Issues）

**Gate 6（最终验收）**：AC-1 ~ AC-12 全部勾选；`git diff --stat` 只含 `index.html` / `index.js` / `index.css`。

## 步骤 7 · 收尾

- [x] 7.1 更新 `prd.md` 的 Known Risks（把 AC-10 / iOS / 4K 的实测结论写实）
- [x] 7.2 提交：`feat: add video play entry that routes ?view to movi-player`
- [x] 7.3 提交信息里注明验证过的 dufs 版本（0.47.0）与 movi-player 版本（0.4.1）

---

## 检查点（Check 阶段重点复看）

1. **零 Rust 改动** —— `../dufs` 目录必须干净（`git -C ../dufs status --short` 为空）
2. **前缀没有硬编码** —— 全仓 `grep -rn "dufs_v" index.*` 应为空
3. **`src` 不带 query** —— `grep -n "movi-player" index.js` 附近确认用 `baseUrl()`
4. **没有改 `movi.js`/`movi.wasm` 一个字节** —— `git diff --stat` 不包含它们
5. **没有新增依赖** —— 无 `package.json` / `node_modules`
6. **降级路径可跑** —— AC-8 必须手动复现过一次，不能只看代码

## 回滚点

| 位置 | 回滚动作 |
|---|---|
| 步骤 2 之后不满意 | `git checkout -- index.js index.html`（入口消失，行为回到基线） |
| 步骤 3–5 之后播不了 | 把 `MEDIA_VIDEO_FORMATS` 置为 `[]` → 全链路失效，等价基线 |
| 全部推翻 | `git checkout c9701e8 -- index.html index.js index.css` |
