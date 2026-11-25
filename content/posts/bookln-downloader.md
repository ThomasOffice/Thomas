+++
title = '把在线样书变成 PDF：书链 / 云展网翻书下载器逆向笔记'
date = '2026-11-25T10:00:00+08:00'
draft = false
author = 'Thomas'
categories = ['技术']
tags = ['Python', 'Playwright', '逆向', 'PDF', '书链', '云展网', '爬虫']
description = '记录把书链样书和云展网翻书下载为高清图片并合成 PDF 的完整过程：签名 URL、WASM 加密页、blob 捕获、304 缓存、目录页 AES 解密等坑与解法。'
keywords = ['书链', '云展网', 'Playwright', '样书下载', 'PDF', 'WASM', 'blob', '逆向']
toc = true
autoCollapseToc = true
comment = true
+++

> 在线样书只能一页页翻，想离线备课、批注、打印都很麻烦。本文记录一个"让浏览器替我们解密"的下载器：不硬碰签名算法，也不逆 WASM，而是驱动真实 Edge 完成加载，再把页面已经解密好的图片取下来，最后合成 300 DPI PDF。

## 背景：样书为什么难下载

教辅样书、电子教材大多以"在线翻书"的形式提供：页面是一个翻页器，图片按需加载，右键保存只能得到低清缩略图，直接抓 HTML 又找不到完整的图片列表。

这次要处理的是两类站点：

- **书链**：`mp.zhizhuma.com/book/sample-*.htm?code=...`，图片由 `*.bookln.cn` 提供，页面数据接口在 `biz.bookln.cn`。
- **云展网**：`book.yunzhan365.com/suls/<id>/index.html`，基于 FlipHTML5 的翻书器。

目标很简单：**拿到站点提供的最高分辨率图片，按页序合成一个 PDF**。不做 OCR，不改内容，也不试图突破付费墙。

真正麻烦的地方在于：书链的图片 URL 带签名，每 5 页还有一页是 WASM 加密的；云展网的图片虽然是公开的，但页面清单藏在前端变量里。前者不能硬抓，后者不能硬猜。

## 第一反应：requests + 正则，然后 403

最开始的思路很朴素：请求页面 HTML，正则找图片地址，批量下载。

结果很快碰壁：

1. 图片 URL 带 `auth_key`、`time`、`key1`、`key2` 等参数，签名与完整 URL 和当前会话 cookie 绑定。
2. 试图改 `_width` / `_height` 拿更高分辨率，返回 **HTTP 403**。签名是 URL 绑定的，改一个字符就失效。
3. 页面数据接口 `biz.bookln.cn/ebookpageservices/queryAllPageByCode.do` 对非浏览器客户端直接返回：

```json
{"success": false, "msg": "服务器繁忙中,请稍后再试!"}
```

这不是接口真的忙，而是网关在检查客户端特征（TLS 指纹、请求头、cookie 等）。继续复刻 `requestSign`、`crossDomainPost` 那套混淆逻辑，投入产出比很低。

于是换一个方向：**不破解签名，直接让浏览器把页面正常打开**。签名、cookie、WASM 解密、blob 生命周期，全都交给页面自己完成，我们只负责在正确的时机把结果取走。

## 方案：用 Playwright 驱动本机 Edge

脚本用 Playwright 启动本机已安装的 Microsoft Edge，而不是下载 Playwright 自带的 Chromium。这样更接近用户真实环境，也能复用系统里的浏览器组件。

核心参数：

```python
browser = p.chromium.launch(
    headless=True,
    executable_path=r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
)
context = browser.new_context(
    viewport={"width": 1400, "height": 950},
    locale="zh-CN",
    user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) ... Edg/153.0.0.0",
)
page = context.new_page()
page.on("response", on_response)
```

页面加载后，不能用一个固定 `sleep` 等它渲染完，而是轮询等待全局变量 `allPages` 出现：

```python
for _ in range(60):
    page_data = page.evaluate("""() => {
        if (typeof allPages === 'undefined' || !allPages) return null;
        return allPages.map(p => ({imgurl: p.imgurl, encrypt: p.encrypt}));
    }""")
    if page_data:
        break
    time.sleep(0.5)
```

`allPages` 是翻书器自己维护的页面清单，每一项包含图片地址和是否加密。拿到它，后面的翻页、匹配、校验都有了依据。

### 页码陷阱：不要信 HTML 里的变量

页面 HTML 里还有一个 `_totalPageSize`，看起来像总页数，但它并不可靠。实际遇到过 HTML 写 **30 页**、`allPages.length` 却是 **128 页** 的情况。

所以页码只认一个来源：

```python
n = len(page_data)
```

如果按 `_totalPageSize` 去翻页，后半本书会直接丢掉，而且不会报错。

## 普通页：抓 response，而不是再发一次请求

书链的图片由 `sampleimgauth.bookln.cn` 提供。最直接的想法是拿到 URL 后用 `page.request.get(url)` 下载，但这样会返回 403——因为 `page.request` 是独立的请求上下文，缺少浏览器会话里的请求头和 cookie。

正确做法是监听页面自己的网络响应：

```python
net_bodies = {}

def on_response(resp):
    if "sampleimgauth.bookln.cn" in resp.url:
        body = resp.body()
        if body:
            net_bodies[resp.url] = body
            net_bodies[resp.request.url] = body
```

这里同时用 `resp.url` 和 `resp.request.url` 做键，是因为 CDN 可能发生重定向，最终 URL 和 `<img>` 里的原始 URL 不一定完全一致。

另一个坑是：**不要在页面里用 `fetch()` 去抓图**。`sampleimgauth.bookln.cn` 有防盗链，页面级 `fetch()` 会带上 `Origin` 头，照样 403。只有真实的 `<img>` 加载才会被放行。所以必须让翻书器自己加载图片，我们只旁路监听响应。

翻页靠翻书器自己的 API：

```python
page.evaluate(f"$('#flipbook').turn('page', {i})")
```

然后等目标图片真正加载完成：

```python
expr = f"""() => {{
    const el = document.querySelector('img.img{i}');
    if (!el) return null;
    return {{src: el.src, nw: el.naturalWidth, nh: el.naturalHeight}};
}}"""
```

`naturalWidth > 0` 才说明图片解码成功。此时从 `<img>.src` 取最终地址，再去 `net_bodies` 里取响应体。

## 加密页：blob 与 revokeObjectURL

书链从第 10 页开始，每隔 5 页（第 10、15、20……页）会返回加密字节。页面里的 WASM 模块负责解密，解密后的结果被包装成 `blob:` URL 塞给 `<img>`。

如果直接 `fetch(blobUrl)`，经常会报：

```text
TypeError: Failed to fetch
```

原因是页面在图片加载完成后会调用 `URL.revokeObjectURL(blobUrl)` 释放内存。blob 一旦被撤销，就再也取不到了。

解决办法是在开始翻页之前，先把撤销函数替换成空操作：

```python
page.evaluate("URL.revokeObjectURL = function(){};")
```

这样 blob 会一直保留。然后在页面上下文里读取字节并转成 base64：

```javascript
async (src) => {
  const r = await fetch(src);
  const b = await r.blob();
  const buf = await b.arrayBuffer();
  const bytes = new Uint8Array(buf);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
```

Python 侧解码：

```python
saved[i] = base64.b64decode(b64)
```

要注意，翻页和 blob 生成是异步的。刚翻到某一页时，`img.src` 可能还是空的，或者 blob 还没准备好。所以这里需要重试几次，并在每次重试时重新读取 `img.src`。

最终 `manifest.json` 会记录哪些页走了 blob：

```json
{
  "encrypted": [10, 15, 20, 25],
  "captured": [1, 2, 3]
}
```

这次四本书链样书共 270 页，其中 48 页是 WASM 加密页。没有 blob 捕获这一步，每 5 页就会缺一张。

## 304 缓存：最隐蔽的坑

第一轮下载很顺利，但第二次运行脚本时开始出现大量缺页：

```text
page 37: no network body captured
```

页面看起来明明有图，`<img>` 也加载成功了，但 `net_bodies` 里没有对应的响应体。

原因是 HTTP 缓存。图片第二次请求时命中缓存，服务器返回 **304 Not Modified**，没有响应体。Playwright 的 `response.body()` 自然拿不到东西。

解决分两步：

1. 用 CDP 禁用缓存：

```python
cdp = context.new_cdp_session(page)
cdp.send("Network.enable")
cdp.send("Network.setCacheDisabled", {"cacheDisabled": True})
```

2. 翻页时，如果目标页就是当前页，先翻到下一页再翻回来，强制发一次新的网络请求：

```python
def flip_to(i):
    target = i
    if current[0] == i:
        target = (i % n) + 1
    page.evaluate(f"$('#flipbook').turn('page', {target})")
    time.sleep(0.3)
    if target != i:
        page.evaluate(f"$('#flipbook').turn('page', {i})")
        time.sleep(0.35)
    current[0] = i
```

最后再加三轮补漏：只对缺失页重试，每轮之间稍微等一会儿。这样即使有少量图片因为网络抖动失败，也能在后续轮次补齐。

这一课很典型：**浏览器自动化里，"页面看起来有图"不等于"网络层有响应体"**。缓存、重定向、Service Worker 都可能让两者对不上。

## 目录页：一个链接背后的多本书

书链的 `webappv2/electronicBook/cookBook-*.htm` 不是一本样书，而是一个"电子书案例页"，里面列出若干分册，比如学案、练案、考案、答案。每个分册才是一本独立的样书。

这个页面的数据链路是：

1. `ebookcaseservices/h5/queryByCodeDetail.do` 返回一个 `kvKey`。
2. 真正的 JSON 在：

```text
https://idatabootcdn.bookln.cn/kvstore/kv_biz/api_result_cache/<KEY>
```

3. `eBookCaseResourceDTOList[]` 里每一项包含分册的 `name`、`id`（targetId）和加密的 `code`。

拿到这些信息后，还不能直接拼样书 URL。需要先在已经加载了站点脚本的页面里，调用它自己的 `requestSign`：

```javascript
const data = requestSign({id: targetId, code: encryptedCode});
const res = await fetch('/ebookPageService/gvc.do', {
  method: 'POST',
  headers: {'Content-Type': 'application/x-www-form-urlencoded'},
  body: new URLSearchParams(data).toString()
});
const j = await res.json();  // {encrypted:true, encryptedData:"..."}
```

返回的 `encryptedData` 用页面脚本里的 AES-ECB key 解密（这个 key 是页面脚本里的固定值，不是账号凭证）：

```javascript
const plain = CryptoJS.AES.decrypt(
  j.encryptedData,
  CryptoJS.enc.Utf8.parse('Suj4XDDt3jPsH9Jj'),
  {mode: CryptoJS.mode.ECB}
).toString(CryptoJS.enc.Utf8);
```

解出来的是一段 JSON，里面有真正的 sample code。最后拼成：

```text
https://mp.zhizhuma.com/book/sample-<alias>.htm?code=<sampleCode>&_src=webapp
```

其中 alias 从 cookBook 文件名推导，例如 `cookBook-tm98ii.htm` 对应 `sample-tm98ii.htm`。

这一步的关键不是"破解"，而是**复用页面自己的签名函数**。签名算法、时间戳、随机数都在页面脚本里，直接调用比逆推更稳。

## 云展网：另一套完全不同的逻辑

云展网没有签名，也没有 WASM 加密，但页面结构不一样。

一个书架页 `bookcase/<code>/index.html` 只列出封面，每本书的阅读器在：

```text
https://book.yunzhan365.com/suls/<id>/index.html
```

阅读器的页面清单在全局变量 `fliphtml5_pages` 里。每一项的 `n[0]` 是哈希后的全尺寸图片：

```text
files/large/713b496dba8c92f090aca85471e35063.webp
```

关键细节：

- 图片地址后面的 `?x-oss-process=...` 是缩略图处理参数，去掉它才能拿到原图（约 1959×2800）。
- `files/large/<hash>.jpg` 和 `files/original/*` 都是 404，哈希 `.webp` 是唯一来源。
- `files/large/1.jpg` 是占位符，不能拿 `l` 字段，必须用 `n[0]`。
- 图片是公开的，没有签名和 cookie。浏览器只负责读出清单，下载可以用普通 HTTP 请求加 `Referer`。

所以云展网的脚本反而简单：

```python
body = fetch(root + "files/large/" + name, referer)
```

并且带断点续传：目标文件存在且大于 1 KB 就跳过，适合网络不稳时反复补。

## PDF：最后一步

图片下载完后，用 Pillow 合成 PDF：

```python
files = sorted(out_dir.glob("page_*"), key=lambda f: int(re.search(r"(\d+)", f.name).group(1)))
images = []
for f in files:
    img = Image.open(f)
    img.load()
    if img.mode in ("RGBA", "P", "LA"):
        img = img.convert("RGB")
    images.append(img)

images[0].save(
    pdf_path, "PDF",
    resolution=300.0,
    save_all=True,
    append_images=images[1:],
    quality=95,
)
```

两个细节：

- 按文件名里的数字排序，不能按字符串排序，否则 `page_10` 会排在 `page_2` 前面。
- PDF 不支持透明通道，RGBA/P/LA 必须先转 RGB，否则保存时会报错或出现黑底。

`resolution=300.0` 让 PDF 里的图片按 300 DPI 解释。配合站点提供的约 1460×2050（书链）或 1959×2800（云展网）原图，打印出来已经足够清晰。

## 实测结果

这次一共处理了 7 本，602 页，约 438 MB：

| 分册 | 来源 | 页数 | PDF 大小 |
|------|------|------|----------|
| 化学R人教选择性必修3 · 01 | 云展网 | 132 | 101.9 MB |
| 化学R人教选择性必修3 · 02 参考答案 | 云展网 | 92 | 89.4 MB |
| 化学R人教选择性必修3 · 03 分层作业 | 云展网 | 108 | 87.3 MB |
| 导学案 · 01 学案 | 书链 | 144 | 77.5 MB |
| 导学案 · 02 练案 | 书链 | 58 | 30.0 MB |
| 导学案 · 03 考案 | 书链 | 12 | 9.5 MB |
| 导学案 · 04 答案 | 书链 | 56 | 42.1 MB |
| **合计** | | **602** | **437.7 MB** |

书链的 270 页里有 48 页是 WASM 加密页，全部通过 blob 捕获拿到；云展网的 332 页全部是公开直链。

## 经验总结

### 1. 浏览器是最终真相

签名、cookie、WASM、blob 生命周期，全都在页面里完成。与其复刻混淆算法，不如让浏览器正常打开页面，再在正确的时机取结果。**能复用会话就不要重写会话。**

### 2. 页面状态比 HTML 变量可靠

`allPages.length` 才是真实页数，`_totalPageSize` 可能是错的。自动化脚本要尽量读应用自己维护的状态，而不是解析静态 HTML。

### 3. 抓网络响应，不要二次请求

`page.on("response")` 拿到的是浏览器真实请求的响应体，带着完整会话。`page.request.get()` 和页面内 `fetch()` 都可能因为缺少 cookie 或多了 `Origin` 而被 403。

### 4. blob 要抢在 revoke 之前

页面加载完就撤销 blob 是常见做法。必须在翻页前 patch `URL.revokeObjectURL`，否则加密页永远取不到。

### 5. 缓存会产生"没有 body 的响应"

304 不是错误，但对抓取来说等于失败。禁用缓存 + 翻走再翻回 + 多轮补漏，是浏览器抓取的标准组合拳。

### 6. 目录页要单独拆

案例页、目录页、样书页是三种不同的东西。先解析目录拿到每个分册的 sample code，再逐本下载，不能把目录页当成一本书。

### 7. 不同站点用不同策略

书链要签名 + WASM + blob，云展网只要读 manifest + 公开直链。不要把一个站点的方案硬套到另一个站点。

### 8. 幂等和重试比"一次成功"重要

网络抖动、缓存、异步渲染都会造成缺页。脚本要能记录已完成的页、只补缺失页、重复运行不重复下载。**能重跑，比一次跑通更有价值。**

## 免责声明

本文记录的技术仅用于**已合法获得访问权限的样书/电子书**的个人离线阅读、备课与批注，不得用于绕过付费、批量抓取、商业分发或传播受版权保护的内容。请遵守目标站点的服务条款与当地著作权法。

---

*写于 2026 年 11 月。技术会过时，但"让浏览器做它擅长的事"这个思路不会。*
