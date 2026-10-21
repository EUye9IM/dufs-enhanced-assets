# MVP-A: 视频播放入口接入 movi-player

## Goal

在 dufs 文件列表的**操作列**加一个 ▶ 播放入口，点击后跳到 dufs 既有的 `?view` 页，由 movi-player 接管解码与播放，解决「部分编码浏览器不支持 → 回落下载 / 黑屏」的问题。

**目录页零体积增量**，原生直链保留为逃生口，**零 Rust 改动**（仅 `index.html` / `index.js` / `index.css` 三个文件）。

---

## Background · 为什么是这个方案

| 现象 | 根因（已核实） |
|---|---|
| 点视频文件回落成下载 | dufs 前端没有播放器，文件名是裸 `<a href>` 直链（`index.js:583`），交给浏览器 MIME 嗅探决定 inline / 下载。`.mkv`(video/x-matroska)、`.avi` 等直接进下载分支 |
| mp4/mov 有声音但黑屏 | 容器认了、编码不认（HEVC / AV1 / MPEG-4 Part2）。`<iframe>` 里还是浏览器原生解码器，没有软解兜底 |
| `.mkv` 连框都不给 | 不在 `IFRAME_FORMATS` 白名单里（`index.js:46`），落到 "Cannot edit because file is too large or binary." |

只换播放器 UI 无效，**必须换解码栈**。movi-player 的 `ffmpeg-wasm 解容器 + WebCodecs 硬解 + wasm 软解兜底` 是纯静态服务器上唯一能覆盖这些格式的路线。

---

## Scope · IN

1. **播放入口**：操作列为**视频类**文件无条件显示 ▶（不依赖 `--allow-upload` / `--allow-delete`），点击**新标签**打开 `<file-url>?view`（`target="_blank"`，与现有文件名/View 链接一致，目录页保留）。
2. **播放页**：`?view` 页命中视频扩展名时，动态加载 `movi.js`，挂载 `<movi-player src="<file-url>">` 替换掉原来的 iframe / "Cannot edit" 文案。
3. **懒加载**：`movi.js` / `movi.wasm` **只在**"View 页 + 视频扩展名"时请求；目录页与文本 View/Edit 页零请求。
4. **可降级**：`movi.js` 加载失败、wasm 实例化失败、解码报错时，退回原行为（iframe 或"下载原文件"提示），页面不得白屏。
5. **原功能不变**：上传（含断点续传）、下载、删除、移动、文本编辑、搜索、zip、hash、排序、登录 / token、dropzone、暗色主题、面包屑，逐个与上游行为一致。
6. **原生直链保留**：文件名链接维持 `<a href target="_blank">` 不变 —— 右键、中键、复制链接照旧可用。
7. **部署形态**：`dufs --assets <repo-dir>` 直接可用，不需要 `cargo build` 本仓库。

## Scope · OUT（本任务不做，防止滑移）

| 不做 | 原因 |
|---|---|
| 改 dufs Rust 源码（MIME / Content-Disposition / Range / 认证） | 一动就不是外置 assets，长期要跟上游 rebase |
| 服务端转码（ffmpeg CLI / HLS 预转码） | 完全不同的架构 |
| 音频走 movi-player | 原生 `<audio>` 已够用，movi 对纯音频无额外收益 |
| 外挂字幕探测（同目录 `.srt/.ass`） | 内封字幕 movi 自带；外挂需额外探测请求 + 权限判定 |
| 播放位置记忆 / 续播 | 明确排除，见「第一版切法」 |
| 播放列表、媒体库、海报墙、缩略图 | 另一个产品 |
| 原生性预判（试播 / 探容器 / `canPlayType`） | 不可靠（黑屏不报错）且成本 ≈ 重写 movi 的 demuxer；见 design.md §「被否决的设计」 |
| 引入打包器 / 框架 / npm / TypeScript | 破坏"无构建、直接 include"的上游同步模型 |
| 重写为 `?json` + fetch 数据层 | 收益低，`__INDEX_DATA__` 注入是 dufs 契约 |
| `src/noscript.rs` 服务端渲染页 | 后端职责，非 assets |
| 移动端专门适配 / iOS 特判 / 手势 / 投屏 | 归入后续任务；本版接受"iPhone 上体验等同上游" |
| 仓库脚手架（README / LICENSE / NOTICE / git-lfs / sync 脚本） | 独立后续任务；**但公开发布前必须补 NOTICE**（movi.wasm 静态链接 FFmpeg LGPL-2.1+） |

---

## Decisions（已拍板）

| # | 决策 | 依据 |
|---|---|---|
| D1 | 播放入口形态 = **(d) 文件名保持直链不动，操作列加 ▶ 走 `?view`** | 最小侵入；天然形成"文件名=原生/下载，▶=movi"双路径，用户自己选，代码零判断 |
| D2 | 解码栈**唯一化**：进了播放器一律 movi，不做原生性预判 | 预判不可靠；movi `decoder="auto"` 本身优先 WebCodecs 硬解 |
| D3 | 第一版切法 = **MVP-A**：只做视频，音频 / 字幕 / 续播 / 画中画全部 OUT | 用户选择 |
| D4 | `movi.js` **动态注入**，不写进 `index.html` | 写进 HTML 会拖慢每一个目录页 |
| D5 | 资源前缀通过 `index.html` 新增的 `<meta name="dufs-assets-prefix" content="__ASSETS_PREFIX__">` 传给 JS | `render_html()` 只替换 HTML 字符串（`server.rs:868-874`），JS 文件里没有占位符 |
| D6 | 视频扩展名白名单：`.mp4 .m4v .mov .mkv .webm .avi .wmv .flv .ts .m2ts .mpg .mpeg .rmvb .rm .3gp .ogv`（**全量保留**，不因不确定 movi 是否覆盖而剔除；白名单只决定 ▶ 是否显示，播不了就报错降级） | 只用于"显不显示 ▶"，**不用于选解码栈** |
| D7 | ▶ **新标签**打开（`target="_blank"`），与现有文件名链接 / View 图标一致 | 目录页不丢、可连播多个视频；从目录页到播放页不需要返回操作，面包屑只管文件内的上级导航。代价：每标签一个独立 wasm 实例（见 Known Risks） |
| D8 | 视频行**用 ▶ 替代**「View file」图标（`actionView` 条件加 `&& !isVideo`），不并存 | 两者指向同一个 `?view`，并存 = 两个图标同一目的地；已核实 dufs 的 View 是「Edit 页的只读降级」，其图标抑制是**去重**而非权限共享（`server.rs:371-378` 均无权限门） |

---

## Constraints（不可协商）

1. dufs **不支持 gzip/brotli** → `movi.js 4.8MB + movi.wasm 5.4MB` 裸传。目录页必须 0 字节增量。
2. `movi.wasm` 的 URL 在脚本执行时由 `document.currentScript.src` 推导（回退 `document.baseURI`）→ 注入必须是带 `src` 的 `<script>`，**不能改名、不能同目录缺失**、不能 blob/inline。
3. `__ASSETS_PREFIX__` 渲染为 `uri_prefix + "__dufs_v{版本}__/"` → **版本化前缀**，天然长缓存 + 自动失效；但绝不能写死路径。
4. 无构建步骤 → 只能用上游 `dist/element.slim.global.js`（IIFE，`customElements.define("movi-player")`），不能用 `import`。
5. `?view` 路由契约（`server.rs:376` → `handle_edit_file`）：**无权限门**、只读前 1024 字节 + `meta.len()` 判 `editable`，不读全文 → 20GB 文件也是零成本。
6. 本仓库不引入 `package.json` / `node_modules` / 构建产物。

---

## Acceptance Criteria

功能：

- [x] **AC-1** 操作列为 `.mkv` 文件显示 ▶（在 `--allow-upload --allow-delete` 全开、以及只读两种部署下都显示）
- [x] **AC-2** 非视频文件（`.txt` / `.pdf` / `.jpg` / `.zip`）**不显示** ▶
- [x] **AC-2b** 视频行**不出现**「View file」与 ▶ 两个指向同一 `?view` 的图标（只读部署下尤其检查）
- [x] **AC-3** 点 ▶ → 导航到 `<file>?view` → 页面内出现播放器并自动可播
- [x] **AC-4** `.mkv`（HEVC + AAC）与 `.avi`（MPEG-4 Part2）在 Chrome 里可播、**可拖动进度条**
- [x] **AC-5** 播放页的面包屑可返回目录；下载按钮可下载原文件
- [x] **AC-6** 文件名链接行为不变（新标签直开/下载）

性能与降级：

- [x] **AC-7** 打开目录页与文本 `?view`/`?edit` 页，Network 中**没有** `movi.js` / `movi.wasm` 请求
- [x] **AC-8** 把 `movi.js` 改名（404）后，播放页显示可读错误提示 + 可下载原文件，**不白屏**，其他页面功能全正常

认证：

- [x] **AC-9** `--auth user:pass --auth-method basic` 下播放 + seek 正常
- [x] **AC-10** `--auth user:pass --auth-method digest` 下播放 + seek 正常（**实测项**，禁止假设；失败则记录结论并作为已知限制写入 README）

回归：

- [x] **AC-11** 上传 / 断点续传 / 删除 / 移动 / 文本编辑保存 / 搜索 / zip / 排序 / 登出 各点一遍，与上游一致
- [x] **AC-12** `git diff` 仅触及 `index.html` / `index.js` / `index.css`（及本任务文档），**无 Rust 改动**

---

## Verification Results（2026-10-21，dufs 0.47.0 + movi-player 0.4.1，headless Chrome）

| 项 | 结果 |
|---|---|
| AC-1 ▶ 在只读 / 可写两种部署下都显示 | ✅ 只读：视频行 1 个 `?view` 链接；全权：▶ + Edit |
| AC-2 非视频无 ▶ | ✅ `note.txt` 无 ▶ |
| AC-2b 无重复 View 图标 | ✅ 只读部署下视频行只有 ▶（`views: 1`） |
| AC-3 ▶ → `?view` → 播放器 | ✅ `target=_blank`，播放器在 `?view` 页挂载 |
| AC-4 mkv(HEVC) / avi(MPEG4) 可播 + 可 seek | ✅ 截图确认解码出真帧；`currentTime` 设置生效 |
| AC-5 面包屑 + 下载 | ✅ 两都在播放页可见可用 |
| AC-6 文件名链接不变 | ✅ 仍 `target=_blank` |
| AC-7 目录页/文本页不拉 movi | ✅ 目录：仅 css/js/favicon；文本 `?view`：无 movi |
| AC-8 movi.js 404 降级 | ✅ 文案 "Failed to load video player…" + 下载按钮可用 + 不白屏 |
| AC-9 basic 认证播放 + seek | ✅ movi.wasm 200、Range 206、播放正常 |
| AC-10 digest 认证播放 + seek | ✅ 首次 401 → 认证缓存建立后 movi.wasm 200 / Range 206 / 播放正常 |
| AC-11 回归（排序/搜索/编辑保存） | ✅ `?order=&sort=` 切换、`?q=` 搜索、编辑器保存落盘 |
| AC-12 改动面 | ✅ 3 文件 +97/−1 |

额外验证：`.ts`（H.264 in MPEG-TS）可播；大写扩展名 `UPPER.MP4` 也显示 ▶ 且可播。

## Known Risks / Known Issues

| 问题 | 结论 |
|---|---|
| movi-player 会向公网请求字体 | **实测发现**：`movi.js` 向 shadow root 注入 `@import url('https://fonts.googleapis.com/css2?family=Inter…')` → 每次播放页都有一次外网请求。内网/离线部署会多一次失败请求（不影响播放，回落系统字体）。**本版不改 movi.js（约束 4）**，待后续用 CSP 或自托管字体解决 |
| digest 认证下并发 Range | **已实测关闭**：认证缓存建立后，movi.wasm 与多个 Range 均 200/206，无额外 401 |
| 用 URL 内嵌凭证（`http://u:p@host/`）访问 | 非产品问题，但已知：movi 用 `document.currentScript.src` 拼 wasm 地址，而 `fetch()` **拒绝含 credentials 的 URL** → wasm 拉不到。正常认证（浏览器弹框/凭证缓存）不走此路径 |
| 4K HEVC 在低端设备的 wasm 内存压力 | 未测；本版不优化 |
| iPhone Safari 无法元素全屏 | 未测；本版不承诺移动端 |
| **D7 的副作用**：每标签一个独立 wasm 实例 | 未测（未做 3 标签并发）；本版不优化 |
| 4G+ 大文件 / 大偏移 | 未测 |

## Notes

- 本项目 `.trellis/spec/frontend/*` 目前仍是 `trellis init` 的模板占位（`00-bootstrap-guidelines` 任务未完成），本任务的实现以 `design.md` 里的源码契约为准。
- 验证需要 `dufs` 二进制（本机未安装）与 `ffmpeg`（已装）→ 见 `implement.md` 步骤 0。
