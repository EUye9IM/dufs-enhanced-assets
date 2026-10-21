# Research · dufs v0.47.0 契约实测记录

> 环境：`dufs 0.47.0`（GitHub release `x86_64-unknown-linux-musl`，本机 `/tmp/dufs-bin/dufs`，经代理 `http://localhost:10808` 下载）
> 夹具：`/tmp/dufs-fixtures`（ffmpeg 生成：`hevc.mkv`=hevc、`mpeg4.avi`=mpeg4、`h264.mp4`=h264）
> 结论全部来自实跑，不是读源码推断。实测时间 2026-10-21。

---

## 1. `--assets` 的访问路径必须带版本前缀 【推翻原假设】

| 请求 | 结果 |
|---|---|
| `GET /movi.js` | **404** |
| `GET /__dufs_v0.47.0__/movi.js` | 200 `text/javascript` 5081314 B |
| `GET /__dufs_v0.47.0__/movi.wasm` | 200 **`application/wasm`** 5647290 B |

原因：`handle_internal()` 要求 `req_path.strip_prefix(assets_prefix)` 成功才去 `--assets` 目录取文件（`server.rs:883-899`）。

**影响**：`loadMovi()` 里 `prefix + "movi.js"` 是唯一正确写法；任何"省略前缀"或"相对路径猜测"都会 404。D5 的 meta 方案因此是**必需**而非可选。

## 2. `movi.wasm` 的 MIME 是 `application/wasm`（`instantiateStreaming` 可直接用）

`mime_guess 2.0` 有 wasm 映射。**原 Known Risk「MIME 可能不对」可以关闭**；ArrayBuffer 回退仍在，但不会走到。

## 3. Range + 长缓存都成立

```
GET /__dufs_v0.47.0__/movi.wasm   Range: bytes=0-99
HTTP/1.1 206 Partial Content
Cache-Control: public, max-age=31536000, immutable
ETag: "1792595656929-5647290"
Accept-Ranges: bytes
Content-Range: bytes 0-99/5647290
```

→ 版本化前缀 + `immutable` = 10.2MB 只下一次，升级版本自动失效。**懒加载的价值在于首次，之后靠缓存**。

## 4. `?view` / `?edit` 均无权限门（只读实例实测）

只读实例（**不加** `--allow-upload --allow-delete`）：

| 请求 | 状态 |
|---|---|
| `GET /hevc.mkv?view` | 200 `text/html` |
| `GET /hevc.mkv?edit` | 200 `text/html` |
| `GET /hevc.mkv` | 200 **`video/x-matroska`** |

→ 证实了"回落下载"的根因（`video/x-matroska` 不被浏览器 inline 播），也证实在只读部署下 ▶ 完全可用。

## 5. `EditData` 实际字段（`?view` 页）

```json
{"href":"/hevc.mkv","kind":"View","uri_prefix":"/","allow_upload":true,
 "allow_delete":true,"auth":false,"user":null,"editable":false}
```

- `href` **不含** `uri_prefix`（`server.rs:1153` 只拼 `/`）→ 与设计一致：**必须用 `baseUrl()` 而不是 `DATA.href`**
- `editable:false` 对视频恒成立
- `?view` 响应仅 7262 B、`time_total=0.0017s`（大文件不读全文）

## 6. 未传 `--assets` 时内嵌模式只认 3 个文件

| 请求（内嵌实例） | 结果 |
|---|---|
| `index.js` / `index.css` / `favicon.ico` | 200 |
| `movi.js` / `movi.wasm` | **404** |

→ 本仓库**必须**用 `--assets` 部署。

## 7. 认证细节（AC-9 / AC-10 的前置事实）

- `--auth` 语法是 **`user:pass@/path:rw`**（`a:b` 会被拒：`Error: Invalid auth`）
- digest 挑战头：`Www-Authenticate: Digest realm="DUFS", nonce=..., qop="auth"`
- 带凭证后：`movi.wasm` 全量 200，`Range: bytes=0-99` → **206**（一次 401 后成功）
- **静态 assets 同样受认证保护**（未带凭证 `GET /` 即 401）→ 浏览器会为 realm 缓存 digest 凭证，但**并行 Range 请求是否各自触发 401 仍需浏览器内实测**（AC-10 保留）

## 8. 测试脚本注意：curl 会被当终端浏览器

`detect_noscript()` 识别 curl/wget 等 UA → 返回**服务端渲染的 noscript 页**，其中没有 `__ASSETS_PREFIX__` 相关标签。

→ 所有检查目录页 HTML 的 curl 命令**必须带浏览器 UA**：
```bash
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
curl -s -A "$UA" http://127.0.0.1:5000/ | grep -o 'link rel="stylesheet" href="[^"]*"'
# → /__dufs_v0.47.0__/index.css    ← 证实占位符替换结果
```
`?view` 页不受影响（不经过 noscript 分支）。

---

## 对设计的净影响

| 原设计点 | 实测后 |
|---|---|
| meta 传前缀（D5） | **必需**，已证实占位符渲染为 `/__dufs_v0.47.0__/` |
| 用 `baseUrl()` 作 `src` | 必需，`DATA.href` 缺 `uri_prefix` |
| wasm MIME 风险 | 关闭（`application/wasm`） |
| 缓存策略 | 已是最优（`immutable` 1 年） |
| digest 播放 | HTTP 层已通，浏览器并行挑战仍需 AC-10 实测 |
| 验收脚本 | 必须带浏览器 UA |
