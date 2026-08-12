+++
title = '从零搭建 Hugo 博客：一次完整的踩坑实录'
date = 2026-08-11T17:30:00+08:00
draft = false
author = 'Thomas'
categories = ['技术']
tags = ['Hugo', 'GitHub Pages', 'Giscus', 'PowerShell', '排错']
description = '记录从零搭建 Hugo + DoIt 主题博客的完整过程，包括网络代理、SSH 认证、Giscus 评论、TOML 配置等 7 个典型坑及解决方案。'
keywords = ['Hugo 搭建', 'DoIt 主题', 'GitHub Pages', 'Giscus', '踩坑']
toc = true
autoCollapseToc = true
comment = true
+++



## 前言

本文记录了我在 GitHub 空仓库上从零搭建 Hugo 个人博客的完整过程。

不同于"顺利教程"，这是一份**真实的踩坑实录**——从网络连接到 SSH 认证，从主题配置到评论系统，几乎每一步都踩了坑。但正是这些坑，让我对 Hugo 生态、Git 认证机制、DoIt 主题内部逻辑有了远比"跟着文档抄一遍"深刻得多的理解。

如果你也在搭建博客，或者对静态站点的工程实践感兴趣，希望这份记录能帮你少走弯路。



## 技术选型

| 组件 | 选择 | 理由 |
|------|------|------|
| 静态生成器 | Hugo Extended | 构建快、无运行时依赖、生态成熟 |
| 主题 | DoIt | 功能齐全、中文支持好、内置 Giscus |
| 部署 | GitHub Pages + Actions | 免费、自动、与 Git 工作流无缝集成 |
| 评论 | Giscus | 基于 GitHub Discussions，无需数据库 |
| 搜索 | Fuse.js | 纯本地索引，无需 Algolia 等外部服务 |



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



## 总结：七条经验法则

| 坑 | 经验 |
|----|------|
| 网络代理 | 国内访问 Git 平台，代理是必需品；配置 `http.proxy` 只影响 Git |
| SSH Key 位置 | Deploy Keys ≠ 个人 SSH Keys；看 URL 路径区分 `settings/keys` vs `仓库/settings/keys` |
| 历史冲突 | 在已有内容的仓库初始化时，用 `--allow-unrelated-histories` 合并 |
| 输出格式 | Hugo 的 JSON/RSS 等输出格式需要显式声明，不是默认开启的 |
| TOML 语法 | 带点号的 key 必须用引号包裹并写全父表前缀：`[mediaTypes."text/plain"]` |
| 主题隐藏逻辑 | 读模板源码是终极排查手段；配置层次 `Site.Params` vs `Site.Params.page` 可能不同 |
| PowerShell 编码 | 中文场景下控制台输入、输出、文件读写三处编码都要显式设为 UTF-8 |



## 工具化沉淀

踩完这些坑后，我把日常操作封装成了一个交互式管理工具 `blog.ps1`，支持：

- 新建文章（自动填充 front matter）
- 导入本地 Markdown（自动转换格式、补全字段、处理图片）
- 本地预览、构建测试、一键发布
- 查看站点状态

工具本身也踩了编码坑——但那又是另一个故事了。



## 后记

搭建博客这件事本身不难，难的是遇到问题时**不绕过去、搞清楚为什么**。每一个坑背后都藏着对系统理解的深化：

- SSH 认证失败让我搞清了 Deploy Key 和个人 Key 的区别
- 评论不显示让我学会了读 Hugo 模板源码
- 编码乱码让我理解了 PowerShell 的编码链路

这些知识比博客本身更有价值。博客是产物，排错是修行。

---



*本文涉及的完整项目配置见 [GitHub 仓库](https://github.com/ThomasOffice/Thomas)，项目说明见 [README](https://github.com/ThomasOffice/Thomas#readme)。*
