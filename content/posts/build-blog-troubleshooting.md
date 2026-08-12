+++
title = '从零搭建 Hugo 博客：一次完整的踩坑实录'
date = 2026-08-11T17:30:00+08:00
draft = false
author = 'Thomas'
categories = ['技术']
tags = ['Hugo', 'GitHub Pages', 'Giscus', 'PowerShell', 'CSS', 'Web Audio', '排错']
description = '记录从零搭建 Hugo + DoIt 主题博客的完整过程，包括网络代理、SSH 认证、Giscus 评论、TOML 配置、子路径部署、BGM 跨页持久化、彩蛋动效等 12 个典型坑及解决方案。'
keywords = ['Hugo 搭建', 'DoIt 主题', 'GitHub Pages', 'Giscus', 'BGM', '彩蛋', '液态玻璃', '踩坑']
toc = true
autoCollapseToc = true
comment = true
+++



## 前言

本文记录了我在 GitHub 空仓库上从零搭建 Hugo 个人博客的完整过程。

不同于"顺利教程"，这是一份**真实的踩坑实录**——从网络连接到 SSH 认证，从主题配置到评论系统，从子路径部署到 BGM 持久化，从彩蛋动效到液态玻璃文字，几乎每一步都踩了坑。但正是这些坑，让我对 Hugo 生态、Git 认证机制、DoIt 主题内部逻辑、CSS 视觉效果、Web Audio API 有了远比"跟着文档抄一遍"深刻得多的理解。

全文共记录 **12 个坑**，涵盖基建、部署、样式、交互四个阶段。如果你也在搭建博客，或者对静态站点的工程实践感兴趣，希望这份记录能帮你少走弯路。



## 技术选型

| 组件 | 选择 | 理由 |
|------|------|------|
| 静态生成器 | Hugo Extended | 构建快、无运行时依赖、生态成熟 |
| 主题 | DoIt | 功能齐全、中文支持好、内置 Giscus |
| 部署 | GitHub Pages + Actions | 免费、自动、与 Git 工作流无缝集成 |
| 评论 | Giscus | 基于 GitHub Discussions，无需数据库 |
| 搜索 | Fuse.js | 纯本地索引，无需 Algolia 等外部服务 |
| BGM | HTML5 Audio + Web Audio API | 跨页面持久化 + 频谱可视化 |
| 彩蛋动效 | Canvas 2D + CSS 3D | 粒子系统 + 极光 + 液态玻璃文字 |
| 管理工具 | PowerShell 7 | 交互式 CLI，新建/导入/发布一条龙 |



## 坑一：网络代理与 Git 推送

### 现象

`git push` 到 GitHub 时报错：

```
fatal: unable to access 'https://github.com/ThomasOffice/Thomas.git/':
Recv failure: Connection was reset
```

`Test-NetConnection` 显示 443 端口时通时断，行为极不稳定。



### 排查过程

```powershell
# 测试端口连通性
Test-NetConnection github.com -Port 443
# TcpTestSucceeded: False（时真时假）

Test-NetConnection github.com -Port 22
# TcpTestSucceeded: True（SSH 端口反而稳定）
```



### 解决方案

最终为 Git 配置本地 Clash 代理：

```powershell
git config --global http.proxy http://127.0.0.1:7890
git config --global https.proxy http://127.0.0.1:7890
```



### 经验

- GitHub 在国内网络环境下连接极不稳定，**代理几乎是必需品**
- `git config --global http.proxy` 只影响 Git，不影响系统其他网络流量
- 22 端口（SSH）和 443 端口（HTTPS）的可达性可能完全不同，排查时都要测



## 坑二：SSH Key 添加位置错误

### 现象

生成 SSH key 后，`ssh -T git@github.com` 始终返回 `Permission denied (publickey)`，但 GitHub 网页上明明显示 key 已添加。



### 排查过程

用 `ssh -v` 查看详细日志：

```
debug1: Offering public key: id_ed25519 ED25519 SHA256:yLCjYL92...
git@github.com: Permission denied (publickey).
```

指纹完全匹配，但 GitHub 拒绝。注意到网页上 key 旁边显示 **"Read/write"** 标记——这是**仓库 Deploy Keys** 页面的特征，个人 SSH keys 页面不显示这个。



### 根因

我把公钥添加到了 `仓库 Settings → Deploy keys`，而不是 `账号 Settings → SSH and GPG keys`。

- **Deploy Keys**：仓库级别，只能用于特定仓库，无法通过 `ssh -T git@github.com` 全局认证
- **个人 SSH Keys**：账号级别，可认证所有你有权限的仓库

当我试图把同一个 key 再添加到个人 SSH keys 时，GitHub 报错 **"Key is already in use"**——因为一个公钥不能同时存在于两处。



### 解决方案

生成一个全新的 key 专用于个人账号：

```powershell
ssh-keygen -t ed25519 -C "ThomasOffice@users.noreply.github.com" -f "$env:USERPROFILE\.ssh\id_ed25519_github" -N '""'
```

配置 SSH config 指定使用新 key：

```
# ~/.ssh/config
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
```

不过 SSH 方案最终因网络问题放弃，改用 HTTPS + Git Credential Manager（浏览器 OAuth 登录），一次配置后无需再管 key。



### 经验

- **Deploy Keys ≠ 个人 SSH Keys**：URL 是 `settings/keys`（账号）vs `仓库/settings/keys`（仓库）
- 一个公钥不能在两处复用，遇到 "Key is already in use" 就生成新 key
- Windows 上 HTTPS + Credential Manager 往往比 SSH 更省心



## 坑三：远程仓库历史冲突

### 现象

SSH 改 HTTPS 后推送成功，但被拒绝：

```
! [rejected] main -> main (fetch first)
hint: Updates were rejected because the remote contains work that you do
not have locally.
```



### 根因

GitHub 空仓库创建时自动生成了初始提交（README.md、test.txt），而本地是全新仓库，两边历史完全独立（unrelated）。



### 解决方案

```powershell
git pull origin main --allow-unrelated-histories --no-edit
git push -u origin main
```

`--allow-unrelated-histories` 允许合并不相关的历史分支。



### 经验

- 在已有内容的仓库上初始化本地项目时，先 `git pull --allow-unrelated-histories` 再 push
- 或者创建空仓库时**不勾选** "Initialize this repository with README"



## 坑四：Hugo Fuse.js 搜索报错

### 现象

配置 Fuse.js 本地搜索后构建报错：

```
ERROR The output format 'json' is not defined for the home page,
Fuse.js requires an json index of the site.
```



### 根因

Fuse.js 需要一个 JSON 格式的搜索索引文件，但 Hugo 默认不输出 JSON。需要在 `[outputs]` 中显式配置。



### 解决方案

在 `hugo.toml` 中添加：

```toml
[outputs]
  home = ["HTML", "RSS", "JSON", "JsonFeed"]

[outputFormats]
  [outputFormats.JsonFeed]
    mediaType = "application/feed+json"
    isPlainText = true
    notAlternative = true
```



### 经验

- Hugo 的输出格式是模块化的，搜索、RSS、sitemap 都需要对应的输出格式声明
- DoIt 主题示例配置分散在 `config/_default/` 多个文件中，单文件配置时要手动合并



## 坑五：TOML 嵌套表语法

### 现象

配置 `mediaTypes` 时报错：

```
ERROR failed to decode "outputformats":
media type "application/feed+json" not found
```



### 错误写法

```toml
[mediaTypes]
  ["text/plain"]
    suffixes = ["md"]
```



### 正确写法

```toml
[mediaTypes]
  [mediaTypes."text/plain"]
    suffixes = ["md"]
```



### 经验

TOML 中带点号的 key（如 MIME 类型 `"text/plain"`）必须用引号包裹并显式声明父表前缀。这是 TOML 规范的语法要求，不是 Hugo 的问题。在多文件配置中可以省略前缀，但合并到单文件后必须写全。



## 坑六：Giscus 评论不显示（最深的坑）

### 现象

博客上线后，文章页面没有评论区。本地构建的 HTML 中找不到 giscus 代码。



### 排查过程

**第一步**：查看 DoIt 主题评论模板 `layouts/_partials/comment.html`

```go-html-template
{{- $comment := .Scratch.Get "comment" | default dict -}}
{{- if $comment.enable -}}
    <div id="comments">...</div>
```

评论配置从 `.Scratch.Get "comment"` 读取。



**第二步**：追溯 Scratch 设置位置 `layouts/_partials/init.html`

```go-html-template
{{- $params := .Params | merge .Site.Params.page -}}
{{- .Scratch.Set "comment" $params.comment -}}
{{- if eq .Params.comment true -}}
    {{- .Scratch.Set "comment" .Site.Params.comment -}}   <!-- 关键！ -->
{{- else if eq .Params.comment false -}}
    {{- .Scratch.Set "comment" dict -}}
{{- end -}}
```



**关键发现**：当文章 front matter 显式设置 `comment = true` 时，主题会**切换读取路径**——从合并后的 `page.comment` 切换到**顶层** `.Site.Params.comment`！



### 根因

我只在 `[params.page.comment]` 配置了 Giscus，没有在顶层 `[params.comment]` 配置。文章的 `comment = true` 触发了路径切换，导致评论配置被重置为空 dict。

另外，`init.html` 第 17 行还有环境判断：

```go-html-template
{{- if eq hugo.Environment "production" -}}
    {{- .Scratch.Set "comment" $params.comment -}}
{{- else -}}
    {{- warnf "评论系统不会启用..." -}}
{{- end -}}
```

**评论只在 production 环境启用**，本地 `hugo server` 默认是 development，看不到评论。



### 解决方案

添加顶层 `[params.comment]` 配置（与 `[params.page.comment]` 内容相同）：

```toml
# 顶层评论配置（当文章 comment = true 时使用）
[params.comment]
  enable = true
  [params.comment.giscus]
    enable = true
    dataRepo = "ThomasOffice/Thomas"
    dataRepoId = "R_kgDOJfy2pQ"
    dataCategory = "Announcements"
    dataCategoryId = "DIC_kwDOJfy2pc4DDHzG"
    # ...其他字段

# 页面级评论配置（默认）
[params.page.comment]
  enable = true
  [params.page.comment.giscus]
    # ...同上
```

本地验证时用 production 环境：

```powershell
hugo --environment production --gc
```



### 经验

- **读主题源码是终极排查手段**：文档不会告诉你所有隐藏逻辑，但模板代码不会骗人
- Hugo 主题的配置层次可能很复杂：`Site.Params.xxx` vs `Site.Params.page.xxx` vs `.Params.xxx`
- `hugo.Environment` 会影响功能开关，本地调试 production 功能时记得加 `--environment production`



## 坑七：PowerShell 中文编码

### 现象

为管理工具编写 `New-Post` 函数时，管道测试传入中文标题，生成的文件中标题变成乱码：`娴嬭瘯鏂囩珷鏍囬`。



### 根因

PowerShell 默认使用系统代码页（GBK），而非 UTF-8。涉及中文的三个环节都可能出问题：
1. 控制台输入编码
2. 控制台输出编码
3. 文件读写编码



### 解决方案

脚本开头强制设置 UTF-8：

```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
```

文件读写显式指定编码：

```powershell
# 读取
$content = Get-Content -LiteralPath $path -Raw -Encoding UTF8

# 写入（UTF-8 无 BOM）
[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
```

`UTF8Encoding($false)` 的 `false` 参数表示不写入 BOM。Hugo 对带 BOM 的 TOML 配置文件可能解析异常。



### 经验

- PowerShell 处理中文时，**三个编码环节都要显式设置**，不能依赖默认值
- Hugo 要求 UTF-8 无 BOM，用 `[System.IO.File]::WriteAllText` 比 `Set-Content`/`Out-File` 更可控
- 管道测试（`echo "中文" | script.ps1`）的编码行为与真实终端交互不同，测试通过不代表终端没问题，反之亦然



## 坑八：草稿文章线上不显示

### 现象

用管理工具发布文章后，本地预览正常，但线上看不到新文章。GitHub Actions 构建成功，仓库里文件也在。

### 排查过程

对比本地构建和线上构建的差异：

```powershell
# 本地预览（能看到文章）
hugo server -D    # -D = buildDrafts，包含草稿

# 线上构建（看不到文章）
hugo --minify     # 默认不含草稿
```

检查文章 front matter：

```toml
+++
draft = true    # 草稿状态！
+++
```

### 根因

`draft = true` 的文章在 production 构建时会被跳过。本地 `hugo server -D` 的 `-D` 参数显式包含草稿，造成"本地能看线上看不到"的假象。

### 解决方案

发布前将 `draft = true` 改为 `draft = false`。并在管理工具中增加**草稿自动检测**：

```powershell
# 发布前扫描草稿文章
Get-ChildItem -Path "content/posts" -Recurse -File -Filter "*.md" | ForEach-Object {
    $raw = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    if ($raw -match '(?m)^\s*draft\s*=\s*true\s*$') {
        # 提示用户：是否自动改为 false
    }
}
```

### 经验

- Hugo 的 `draft`、`expiryDate`、`publishDate` 都会影响线上可见性，排查"文章不显示"时第一时间查 front matter
- 本地预览加 `-D` 是方便，但会掩盖草稿问题，发布前务必用 `hugo --gc`（不加 `-D`）验证



## 坑九：子路径部署导致头像 404

### 现象

头像本地预览正常，线上无法显示。浏览器控制台报 404。

### 排查过程

```powershell
# 头像在子路径下可访问
https://thomasoffice.github.io/Thomas/images/avatar.jpg  # 200

# 但 HTML 中引用的是根路径
<img src="/images/avatar.jpg">  # 404
```

### 根因

`hugo.toml` 中 `baseURL = "https://thomasoffice.github.io/Thomas/"`（子路径 `/Thomas/`），但 `avatarURL = "/images/avatar.jpg"` 以 `/` 开头——Hugo 把以 `/` 开头的路径视为**站点根绝对路径**，不会自动拼接 baseURL 子路径前缀。

### 解决方案

所有静态资源引用都加上子路径前缀：

```toml
# 错误
avatarURL = "/images/avatar.jpg"

# 正确
avatarURL = "/Thomas/images/avatar.jpg"
```

需要修改的位置包括：`params.images`、`params.home.profile.avatarURL`、`params.author.avatar`、`params.page.seo.publisher.logoUrl`、`params.seo.image`、`params.seo.thumbnailUrl`。

### 经验

- Hugo 的 URL 处理有三套规则：`/` 开头（站点根）、`//` 开头（协议相对）、`http` 开头（绝对 URL）。子路径部署时 `/` 开头的路径**不会**自动加前缀
- 子路径部署（非 `<user>.github.io` 根仓库）所有静态资源路径都要手动加前缀，或用 `relURL`/`relLangURL` 函数



## 坑十：归档页和关于页标题右对齐

### 现象

"所有文章"、"分类"、"标签"、"关于"页面的标题被右对齐，但文章页标题正常左对齐。

### 排查过程

查看 DoIt 主题样式源码：

```scss
// _page/_archive.scss
.archive .single-title {
  text-align: right;    // 归档页右对齐！
}

// _page/_special.scss
.special .single-title,
.special .single-subtitle {
  text-align: right;    // 关于页（special 类型）也右对齐！
}
```

主题设计者刻意把归档页和 special 页面标题右对齐作为"风格"，但不符合中文阅读习惯。

### 解决方案

创建 `assets/css/_custom.scss` 覆盖：

```scss
// 修复归档页标题右对齐
.archive .single-title {
  text-align: left;
}

// 修复 special 页面标题右对齐（关于页等）
.special .single-title,
.special .single-subtitle {
  text-align: left;
}
```

DoIt 主题的 `_custom.scss` 会在主样式之后加载，天然具有覆盖优先级。

### 经验

- DoIt 主题支持 `assets/css/_custom.scss` 和 `_override.scss` 两个自定义入口，前者加在最后（覆盖样式），前者加在最前（覆盖变量）
- 查样式问题先读主题 SCSS 源码，比浏览器 F12 逆向更高效



## 坑十一：BGM 跨页面持久化

### 现象

BGM 在首页播放正常，但点击导航跳转到文章页后 BGM 中断（静态站点每个页面都是独立的 HTML）。

### 排查过程

静态站点的本质：每个页面都是独立的 HTML 文档，页面跳转 = 整个 DOM 重建，`<audio>` 元素随之销毁。没有 SPA 的路由保活机制。

### 解决方案

用 `sessionStorage` 在页面间传递播放状态：

```javascript
// 保存状态
function saveState(source, playing) {
    var audio = source === 'easter' ? bgmEaster : bgmDefault;
    sessionStorage.setItem('thomas_bgm_state', JSON.stringify({
        source: source,        // 'default' 或 'easter'
        playing: playing,      // 是否正在播放
        time: audio.currentTime || 0   // 播放进度
    }));
}

// 恢复播放
function startPlayback() {
    var state = loadState();
    if (state && state.playing) {
        // 从断点恢复
        bgmDefault.currentTime = state.time;
        bgmDefault.play();
    }
}
```

关键点：
- `timeupdate` 事件定期保存进度
- `beforeunload` + `visibilitychange` 确保跳转前保存
- 新页面 `DOMContentLoaded` 立即恢复
- 浏览器自动播放策略：首次用户交互后才能 `play()`，用 `click`/`keydown`/`touchstart` 监听作为回退

### 经验

- 静态站点没有 SPA 的组件保活，跨页面状态只能靠 `sessionStorage`（同步、页面级）或 `localStorage`（持久）
- `sessionStorage` 比 `localStorage` 更合适：BGM 状态不需要跨会话保留，关标签页即清除
- 浏览器自动播放策略（Autoplay Policy）是 2018 年后的硬性限制，`audio.play()` 必须在用户交互回调中调用



## 坑十二：液态玻璃文字 + 逐字动画冲突

### 现象

彩蛋文字改为英文后全部堆在一起，且没有逐字浮现效果。

### 排查过程

两个问题叠加：

**问题 A：文字堆叠**

原 CSS 把 `background-clip: text` 放在 `.egg-line` 父容器上：

```css
.egg-line {
    background: linear-gradient(...);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
}
.egg-char {
    display: inline-block;  /* 每个字符是独立块 */
}
```

父容器裁切渐变，但子元素 `inline-block` 各自独立，渐变背景无法正确传递到每个字符，导致文字重叠。

**问题 B：逐字动画不触发**

```javascript
span.style.animationDelay = (charIndex * 0.05) + 's';
// 后面添加 .in class
chars[i].classList.add('in');
```

CSS `.egg-char.in { animation: egg-char-in 0.8s ... forwards; }` 的 `animation` 简写**覆盖**了 inline `animationDelay`，所有字符同时动画。

### 解决方案

**修复 A**：渐变裁切移到每个字符上：

```css
.egg-char {
    background: linear-gradient(135deg, ...);
    -webkit-background-clip: text;
    background-clip: text;
    -webkit-text-fill-color: transparent;
}
```

**修复 B**：用 `setTimeout` 逐个添加 `.in` class，不用 CSS animation-delay：

```javascript
allChars.forEach(function(ch, idx) {
    setTimeout(function() {
        ch.classList.add('in');
    }, idx * 60);   // 每 60ms 触发一个字符
});
```

### 经验

- `background-clip: text` 的渐变作用域是**当前元素**，不会穿透到子元素。父容器裁切 + 子元素 `inline-block` = 灾难
- CSS `animation` 简写会重置 `animation-delay`，要么用 `animation-delay` 单独属性，要么用 JS 控制时序
- 英文按**单词**分组（`white-space: nowrap`）防止换行时单词断裂，比按字符分组更美观



## 总结：十二条经验法则

| 坑 | 经验 |
|----|------|
| 网络代理 | 国内访问 Git 平台，代理是必需品；配置 `http.proxy` 只影响 Git |
| SSH Key 位置 | Deploy Keys ≠ 个人 SSH Keys；看 URL 路径区分 `settings/keys` vs `仓库/settings/keys` |
| 历史冲突 | 在已有内容的仓库初始化时，用 `--allow-unrelated-histories` 合并 |
| 输出格式 | Hugo 的 JSON/RSS 等输出格式需要显式声明，不是默认开启的 |
| TOML 语法 | 带点号的 key 必须用引号包裹并写全父表前缀：`[mediaTypes."text/plain"]` |
| 主题隐藏逻辑 | 读模板源码是终极排查手段；配置层次 `Site.Params` vs `Site.Params.page` 可能不同 |
| PowerShell 编码 | 中文场景下控制台输入、输出、文件读写三处编码都要显式设为 UTF-8 |
| 草稿不显示 | `draft = true` 在 production 构建会跳过；发布前用 `hugo --gc`（不加 `-D`）验证 |
| 子路径资源 404 | `/` 开头的路径不会自动加 baseURL 子路径前缀，需手动写 `/Thomas/...` |
| 标题右对齐 | DoIt 归档页/special 页标题刻意右对齐，用 `_custom.scss` 覆盖 |
| BGM 跨页面 | 静态站点无 SPA 保活，用 `sessionStorage` 传递播放状态 + 断点恢复 |
| 液态玻璃动画 | `background-clip:text` 作用域是当前元素不穿透子元素；`animation` 简写覆盖 `delay` |



## 工具化沉淀

踩完这些坑后，我把日常操作封装成了一个交互式管理工具 `blog.ps1`，支持：

- 新建文章（自动填充 front matter）
- 导入本地 Markdown（自动转换格式、补全字段、处理图片为 Page Bundle）
- 本地预览、构建测试、一键发布
- 草稿自动检测（发布前提示改为 `draft = false`）
- 查看站点状态

工具本身也踩了编码坑——但那又是另一个故事了。



## 后记

搭建博客这件事本身不难，难的是遇到问题时**不绕过去、搞清楚为什么**。每一个坑背后都藏着对系统理解的深化：

- SSH 认证失败让我搞清了 Deploy Key 和个人 Key 的区别
- 评论不显示让我学会了读 Hugo 模板源码
- 编码乱码让我理解了 PowerShell 的编码链路
- 子路径 404 让我搞懂了 Hugo 的 URL 拼接规则
- BGM 跨页面中断让我掌握了静态站点的状态持久化方案
- 液态玻璃文字堆叠让我深入理解了 `background-clip: text` 的作用域

从最初的空仓库到带 BGM、彩蛋动效、液态玻璃文字的完整博客，12 个坑串起了 Hugo 生态、Git 认证、CSS 视觉、Web Audio 四个领域的实践。这些知识比博客本身更有价值。博客是产物，排错是修行。

---

*本文涉及的完整项目配置见 [GitHub 仓库](https://github.com/ThomasOffice/Thomas)，项目说明见 [README](https://github.com/ThomasOffice/Thomas#readme)。*
