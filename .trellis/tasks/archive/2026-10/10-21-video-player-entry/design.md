# Design · MVP-A 视频播放入口

> 目标：在**不改 Rust、不引构建**的前提下，让 `?view` 页对视频文件挂上 `<movi-player>`，且目录页零体积增量。

---

## 1. 系统边界与数据流

```
[目录页 DATA.kind="Index"]
   文件名 <a href=fileUrl>            → 浏览器原生/下载   （逃生口，不改）
   操作列 ▶ <a href=fileUrl?view>     → 新增，仅视频扩展名
        │
        ▼ 新标签导航（target="_blank"，目录页保留，整页请求）
[服务端 handle_edit_file(DataKind::View)]  server.rs:1141
   · 无权限门；只 read 前 1024B + metadata.len() → 判 editable
   · 返回同一份 index.html，内嵌 base64 EditData{kind:"View", href, editable:false, uri_prefix, ...}
        │
        ▼
[前端 ready() → DATA.kind==="View" → setupEditorPage()]  index.js:165,699
   · baseUrl() = location.href 去掉 ?/!  →  正好是文件原始 URL   index.js:952
   · 命中视频扩展名 →
        inject <script src=prefix+"movi.js">  （一次性 Promise）
        mount   <movi-player src=baseUrl()>
        │
        ▼
[movi-player 内部]
   fetch(src, Range) ──► ffmpeg-wasm(EBML/MP4 demux) ──► WebCodecs 硬解 ──► canvas
                                                    └──► wasm 软解兜底（HEVC/AV1/MPEG4/VC1/ProRes）
   fetch(prefix+"movi.wasm", credentials:"same-origin") → instantiateStreaming（失败回退 ArrayBuffer）
```

关键：**播放页和目录页是两个不同的 HTTP 响应**。10.2MB 只发生在播放页，且只在视频文件时。

---

## 2. dufs 侧契约（已逐条核实，实现时不要重新猜）

| 契约 | 位置 | 对本设计的含义 |
|---|---|---|
| 路由 `?view` → `handle_edit_file(DataKind::View)` | `src/server.rs:376-378` | 入口存在，`?view` **不需要** `--allow-upload` |
| `?edit` 与 `?view` **都没有**权限门，只受读权限（`access_paths`）约束 | `src/server.rs:371-378` | `allow_upload` 只是塞进 `EditData` 供前端决定显不显示「保存」按钮，**不是路由门禁** |
| `EditData.allow_upload` 原样透传 `self.args.allow_upload` | `src/server.rs:1163` | 前端 `DATA.allow_upload` 是「能力提示」，不是「是否可访问」 |
| `handle_edit_file` 只读 1024B、`meta.len()<=4MB && is_text` 才 editable | `src/server.rs:1149-1158` | 任意大小视频都零成本；`DATA.editable === false` 必然成立 |
| 返回 index.html + base64 `EditData` | `src/server.rs:1160-1180` | 前端拿到的仍是同一份壳 |
| `render_html()` 只替换 `__ASSETS_PREFIX__` / `__PATH_PREFIX__`，且**只作用于 HTML 字符串** | `src/server.rs:868-874` | JS 里拿不到前缀 → 必须靠 `<meta>`（D5） |
| `--assets <dir>` 下该目录内**任意文件**都被 `handle_send_file` 服务（支持 Range、`mime_guess`） | `src/server.rs:883-899` | `movi.js` / `movi.wasm` 可直接放在仓库根被取到，无需特殊路由 |
| 未传 `--assets` 时只认 `index.js/index.css/favicon.ico`，其余 404 | `src/server.rs:901-935` | **本仓库必须配合 `--assets` 使用**，写进 README |
| `assets_prefix = "__dufs_v{CARGO_PKG_VERSION}__/"`，渲染时拼 `uri_prefix` | `src/server.rs:76, 871` | 版本化前缀 = 天然缓存失效；不要写死 `/__dufs_v0.47.0__/` |
| 前端 `ready()` 已 union 处理 `View` | `index.js:165-169` | 不需要新增页面状态 |
| `addBreadcrumb(DATA.href, DATA.uri_prefix)` 无条件调用 | `index.js:152` | 播放页自带返回路径，无需自建返回按钮 |
| `.download` 在 `setupEditorPage()` 中无条件显示 | `index.js:700-703` | 播放页自带"下载原文件" |
| `baseUrl()` = `location.href.split(/[?#]/)[0]` | `index.js:952` | 在 `?view` 页上等于文件 URL，可直接作 `src`；**天然剥离 query** |
| 现有 action 列逻辑：`actionView` 仅在 `!actionEdit && !isDir` 时生成 | `index.js:566-568` | 抑制原因是**图标去重**（不可编辑文件在 `?edit` 页里本来就渲染 iframe，是 View 的超集），**不是权限共享** → ▶ 必须独立于该条件，同时避免与 `actionView` 重复 |

---

## 3. 改动面（3 文件）

### 3.1 `index.html`

```diff
   <head>
     <link rel="icon" ... href="__ASSETS_PREFIX__favicon.ico">
     <link rel="stylesheet" href="__ASSETS_PREFIX__index.css">
+    <meta name="dufs-assets-prefix" content="__ASSETS_PREFIX__">
```

只加这一行。**不加** `<script src="...movi.js">`（D4）。

### 3.2 `index.js`

**(a) 常量**（放在 `IFRAME_FORMATS` 附近）

```js
const MEDIA_VIDEO_FORMATS = [
  ".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".wmv", ".flv",
  ".ts", ".m2ts", ".mpg", ".mpeg", ".rmvb", ".rm", ".3gp", ".ogv",
];
const MOVI_SCRIPT = "movi.js";
```

**(b) `ICONS.play`** —— 与现有 `ICONS.view` 同风格的 16×16 SVG。

**(c) `addPath()` 内新增播放按钮**（注意：与 `actionEdit` 互不影响）

```js
const isVideo = !isDir && MEDIA_VIDEO_FORMATS.includes(extName(file.name).toLowerCase());
const actionPlay = isVideo
  ? `<a class="action-btn" title="Play video" target="_blank" href="${url}?view">${ICONS.play}</a>`
  : "";
```
插入位置：`actionCell` 中 **`actionDownload` 之前**（▶ 是视频文件的主操作）。

**必须同时去重**：把现有 `actionView` 的条件改为 `if (!actionEdit && !isDir && !isVideo)`（`index.js:566`）。否则只读部署下视频行会同时出现「View file」和 ▶，两个图标指向同一个 `?view`。

关于视频行的 "Edit"（`?edit`）图标：**保留不动**。理由——`?edit` 与 `?view` 服务端都无权限门，且 `setupEditorPage()` 的 `!DATA.editable` 分支是两者共用的，所以 `?edit` 打开视频时同样会挂播放器，并额外带上 move/delete 工具栏，功能上是 `?view` 的超集，无副作用。

**新标签的副作用（D7）**：每个标签是独立文档，`<script>`/wasm 实例不共享。连开 N 个视频 = N 份 wasm 堆与解码缓冲。本版不优化（不做共享 worker、不限并发），写入 README 已知限制。

`file.path_type` 已用于判目录（`endsWith("Dir")`，`index.js:535`），沿用；`extName()` 已存在（`index.js:960`），复用。

**(d) 播放器加载器**（新增，约 25 行）

```js
let moviLoadPromise = null;
function loadMovi() {
  if (customElements.get("movi-player")) return Promise.resolve();
  if (moviLoadPromise) return moviLoadPromise;
  const prefix = document.querySelector('meta[name="dufs-assets-prefix"]')?.content ?? "";
  moviLoadPromise = new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = prefix + MOVI_SCRIPT;   // 必须是带 src 的 script：wasm URL 由 currentScript.src 推导
    s.async = true;
    s.onload = () => customElements.whenDefined("movi-player").then(resolve, reject);
    s.onerror = () => reject(new Error("failed to load " + s.src));
    document.head.appendChild(s);
  });
  return moviLoadPromise;
}
```

设计要点：
- **幂等**：模块级 Promise，重复进入播放页不会重复注入。
- `s.src` 必须是绝对/相对可解析路径；`prefix` 形如 `/__dufs_v0.47.0__/`。
- 不改 `movi.js` 内部逻辑，因此将来换上游 dist 文件零成本。
- 超时兜底交给上层 UI（见 §4），不在此处加 timer，避免和浏览器慢网络打架。

**(e) `setupEditorPage()` 分支调整**（`index.js:699-747`）

当前逻辑（简化）：
```
if (DATA.kind == "Edit") { ...move/delete/save... }
else if (DATA.kind == "View") { $editor.readonly = true; }
if (!DATA.editable) {
   if (IFRAME_FORMATS.includes(ext)) → iframe
   else → "Cannot edit because file is too large or binary."
   return;
}
```

改为在 `if (!DATA.editable)` 分支内**先判视频**：

```js
if (!DATA.editable) {
  const url = baseUrl();
  const ext = extName(baseName(url)).toLowerCase();
  if (MEDIA_VIDEO_FORMATS.includes(ext)) {
    await mountVideoPlayer(url, $notEditable);   // 新函数
    return;
  }
  if (IFRAME_FORMATS.find(v => v === ext)) { /* 原 iframe 分支不动 */ }
  else { /* 原提示不动 */ }
  return;
}
```

**(f) `mountVideoPlayer(url, $slot)`**（新增，约 30 行）

```js
async function mountVideoPlayer(url, $slot) {
  $slot.textContent = "Loading player…";
  try {
    await loadMovi();
  } catch (err) {
    $slot.textContent = "Failed to load video player. You can still download the file.";
    console.error(err);
    return;
  }
  const el = document.createElement("movi-player");
  el.setAttribute("src", url);
  el.setAttribute("controls", "");
  el.className = "movi-player";
  el.addEventListener("error", () => {
    $slot.textContent = "This video could not be decoded. You can still download the file.";
  }, { once: true });
  $slot.insertAdjacentElement("afterend", el);
  $slot.classList.add("hidden");   // 成功后隐藏占位文案
  document.body.classList.add("has-movi-player");
}
```

注意点：
- `src` 用 `baseUrl()`（已剥离 `?view`），**不要**带 `?view`，否则服务端返回 HTML 壳而不是字节流。
- 失败时**不复用** `$slot` 隐藏逻辑，保证文案可见。
- 元素属性只用已确认存在的：`src` / `controls`（dist 里出现 10 次）/ 可选 `sw`、`decoder`。**不使用**任何未验证的属性（如 `preferNative` —— 那是 dashjs/shaka 的配置项，不是元素属性）。
- 不设 `autoplay`：浏览器自动播放策略会拦截有声自动播放，交给用户点播放。

### 3.3 `index.css`

```css
/* 播放页布局：editor-page 原为 flex 列，播放器需撑满剩余高度 */
body.has-movi-player .editor-page { height: calc(100vh - 56px); }  /* 数值按 .head 实际高度校准 */
.movi-player { display: block; width: 100%; height: 100%; background: #000; }
.movi-player:not(:defined) { display: none; }
```

`body.has-movi-player` 作用域化，避免影响文本 View/Edit 页。

---

## 4. 失败与降级矩阵

| 触发点 | 检测方式 | 行为 |
|---|---|---|
| `movi.js` 404 / 网络失败 | `script.onerror` | 占位文案 "Failed to load video player. You can still download the file."；下载按钮仍可用（面包屑/下载已在壳里） |
| 脚本加载成功但 `customElements.define` 未执行 | `customElements.whenDefined` 永不 resolve | Promise pending；由 `:not(:defined){display:none}` 保证不出现空壳。**已知限制**，不做超时计时器（v1 接受） |
| `movi.wasm` 拉取失败 / 实例化失败 | movi 内部 reject → 元素 `error` 事件 | 占位文案 "This video could not be decoded…" |
| 编码不支持 | 同上 | 同上 |
| 视频行出现两个指向同一 `?view` 的图标 | 人工检查 | 已用 `actionView` 加 `&& !isVideo` 规避（§3.2c） |
| 元素已定义但 `src` 无效（如 `?view` 未剥离） | 播放失败 → `error` | 同上；测试用例显式覆盖 |

原则：**任何失败都必须让"下载原文件"这条路仍然可用**，绝不白屏。

---

## 5. 被否决的设计（记录理由，避免后续反复）

| 设计 | 否决理由 |
|---|---|
| 用 `canPlayType` / `mediaCapabilities` / 试播来预判原生可播 | 需要 codec 字符串 → 需要解容器（moov 可能在文件尾 → 还要尾查 Range）；且"黑屏"场景不触发 `error`，`loadedmetadata` 照常触发但 `videoWidth===0`，判据不完整 |
| 让 movi 内部"能原生就用原生" | 已核实 dist：`using native`（原生 video 元素）只出现在 DRM 分支；普通文件走 WebCodecs/wasm 解码后画到 canvas。实测 shadow DOM 里是 `CANVAS`（渲染）+ 一个 0×0 的 `VIDEO`（音频/媒体汇）、元素 class 带 `movi-native-video`，但**没有任何"跳过 wasm 用原生解码"的开关** |
| 直接把 `<script src="...movi.js">` 写进 index.html | 每个目录页都要下 4.8MB（且 dufs 不做 gzip） |
| 点文件名 → 原地弹层播放 | 需要接管 `<a>` 默认行为 + 自己实现历史栈 / 关闭逻辑；与 (d) 的最小侵入目标冲突 |
| 用 `?edit` 当播放入口 | 早前误判「`?edit` 需要 `--allow-upload`」，已核实 `server.rs:371-378` **无门禁**；但 `?edit` 语义是「编辑」，只读部署下做成播放按钮会误导，且与已有 Edit 图标重复 |
| 在 JS 里硬编码 `/__dufs_v0.47.0__/` | 版本升级即失效 |
| 引入 `?json` + fetch 重写列表数据层 | 收益低，破坏上游同步 |

---

## 6. 测试夹具与环境

```bash
# 1) 构建 dufs（本机未安装，仓库在 ../dufs，版本 0.47.0）
cd ../dufs && cargo build --release

# 2) 生成夹具（不进 git，放 /tmp/dufs-fixtures）
mkdir -p /tmp/dufs-fixtures
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=25 -t 8 -c:v libx265 -pix_fmt yuv420p \
       -tag:v hvc1 -c:a aac /tmp/dufs-fixtures/hevc.mkv     # 黑屏主犯（HEVC in matroska）
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=25 -t 8 -c:v mpeg4 -c:a libmp3lame \
       /tmp/dufs-fixtures/mpeg4.avi                          # 回落下载主犯
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=25 -t 8 -c:v libx264 -c:a aac \
       /tmp/dufs-fixtures/h264.mp4                           # 原生对照组

# 3) 起服务
../dufs/target/release/dufs /tmp/dufs-fixtures --assets "$PWD" --allow-upload --allow-delete
#    只读场景：去掉 --allow-upload --allow-delete（验证 AC-1 两种部署下 ▶ 都显示）
#    digest 场景：--auth a:b --auth-method digest
```

---

## 7. 回滚

改动集中在 3 个文件、约 60 行，且全部被"是否命中 `MEDIA_VIDEO_FORMATS`"包裹：

- 快速关停：把 `MEDIA_VIDEO_FORMATS` 置为 `[]` → ▶ 消失、`?view` 回到 iframe/提示，行为**等价于基线**（`c9701e8`）。
- 完整回滚：`git checkout c9701e8 -- index.html index.js index.css`。
