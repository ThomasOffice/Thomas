# Thomas's Blog

基于 Hugo + DoIt 主题的个人博客，托管于 GitHub Pages，通过 GitHub Actions 自动构建部署。

[**在线访问**](https://thomasoffice.github.io/Thomas/) · [**构建进度**](https://github.com/ThomasOffice/Thomas/actions)

## 技术栈

| 组件 | 选择 |
|------|------|
| 静态生成器 | Hugo Extended 0.164.0 |
| 主题 | [DoIt](https://github.com/HEIGE-PCloud/DoIt)（git submodule 集成） |
| 部署 | GitHub Pages + GitHub Actions |
| 评论 | Giscus（基于 GitHub Discussions） |
| 搜索 | Fuse.js（本地搜索，无需外部服务） |
| 语言 | 简体中文（zh-cn） |

## 目录结构

```
Thomas/
├── .github/workflows/
│   └── hugo.yml              # GitHub Actions 自动部署工作流
├── archetypes/
│   └── default.md            # 文章模板（hugo new 使用）
├── content/
│   ├── about/index.md        # 关于页
│   └── posts/                # 博客文章目录
├── themes/
│   └── DoIt/                 # 主题（git submodule）
├── blog.ps1                  # 一键管理工具（PowerShell）
├── blog.bat                  # Windows 启动器
├── hugo.toml                 # Hugo 站点配置
└── README.md
```

## 快速开始

### 环境要求

- [Hugo Extended](https://gohugo.io/installation/) 0.142.0+
- Git
- PowerShell 7+（使用管理工具）

### 一键管理工具

双击 `blog.bat` 启动交互式管理工具：

```
  ======================================
      Thomas's Blog  管理工具
  ======================================

  [1] 新建文章
  [2] 导入本地 md 文件
  [3] 本地预览
  [4] 发布文章 (提交并推送)
  [5] 构建测试
  [6] 查看站点状态
  [0] 退出
```

### 手动操作

```bash
# 新建文章
hugo new content/posts/my-post.md

# 本地预览（含草稿）
hugo server -D

# 构建测试
hugo --gc

# 发布
git add . && git commit -m "post: 新文章" && git push
```

## 导入本地 Markdown

管理工具的 `[2] 导入本地 md 文件` 功能支持自动格式转换：

| 问题 | 自动处理 |
|------|---------|
| 无 front matter | 从首个 `# 标题` 或文件名推断，生成完整 TOML front matter |
| YAML 格式 (`---`) | 转换为 TOML (`+++`)，与站点风格一致 |
| 缺失字段 | 自动补全 author、date、toc、comment、draft 等 |
| 分类/标签为字符串 | 转为数组格式 `['xxx']` |
| 本地图片引用 | 转为 Page Bundle 结构，复制图片并修正路径 |
| 网络图片引用 | 保持不变 |

## 文章 Front Matter

```toml
+++
title = '文章标题'
date = 2026-08-11T12:00:00+08:00
draft = false              # true 为草稿，不会发布
author = 'Thomas'
categories = ['技术']       # 分类
tags = ['Hugo', '教程']     # 标签
description = '文章摘要'
toc = true                 # 目录
comment = true             # 评论
+++
```

## 部署流程

1. 推送代码到 `main` 分支
2. GitHub Actions 自动触发构建（[查看工作流](.github/workflows/hugo.yml)）
3. Hugo 构建静态文件并上传 artifact
4. 部署到 GitHub Pages
5. 约 1-2 分钟后站点更新

## 配置要点

### Giscus 评论

评论系统需同时配置**两处**（DoIt 主题的特殊逻辑）：

- `[params.page.comment.giscus]`：页面级默认评论配置
- `[params.comment.giscus]`：当文章 front matter 显式 `comment = true` 时使用此配置

Giscus 配置值（`data-repo-id`、`data-category-id`）从 [giscus.app](https://giscus.app) 获取。

### 搜索（Fuse.js）

使用 Fuse.js 本地搜索需要在 `hugo.toml` 配置 JSON 输出格式：

```toml
[outputs]
  home = ["HTML", "RSS", "JSON", "JsonFeed"]
```

### baseURL

站点部署在子路径 `/Thomas/`，baseURL 设置为：
```
https://thomasoffice.github.io/Thomas/
```

## 主题更新

```bash
# 更新 DoIt 主题到最新版本
git submodule update --remote --merge
git add themes/DoIt
git commit -m "chore: update DoIt theme"
```

## License

内容采用 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) 授权。
