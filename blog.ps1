#!/usr/bin/env pwsh
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
Set-Location -LiteralPath $Root

$SiteURL = "https://thomasoffice.github.io/Thomas/"
$ActionsURL = "https://github.com/ThomasOffice/Thomas/actions"

function Show-Banner {
    try { Clear-Host } catch { Write-Host ("`n" * 3) }
    Write-Host ""
    Write-Host "  ======================================" -ForegroundColor Cyan
    Write-Host "      Thomas's Blog  管理工具" -ForegroundColor Cyan
    Write-Host "  ======================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    Write-Host "  [1] 新建文章" -ForegroundColor Yellow
    Write-Host "  [2] 本地预览" -ForegroundColor Yellow
    Write-Host "  [3] 发布文章 (提交并推送)" -ForegroundColor Yellow
    Write-Host "  [4] 构建测试" -ForegroundColor Yellow
    Write-Host "  [5] 查看站点状态" -ForegroundColor Yellow
    Write-Host "  [0] 退出" -ForegroundColor Yellow
    Write-Host ""
}

function Test-HugoSite {
    if (-not (Test-Path -LiteralPath "hugo.toml")) {
        Write-Host "当前目录不是 Hugo 站点根目录 (缺少 hugo.toml)" -ForegroundColor Red
        return $false
    }
    return $true
}

function New-Post {
    if (-not (Test-HugoSite)) { return }

    Write-Host ""
    $title = Read-Host "请输入文章标题"
    if ([string]::IsNullOrWhiteSpace($title)) {
        Write-Host "标题不能为空" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }

    $defaultSlug = Get-Date -Format "yyyy-MM-dd"
    $slug = Read-Host "请输入文件名 slug (英文/拼音，回车用默认: $defaultSlug)"
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = $defaultSlug }
    $slug = $slug.Trim() -replace '\s+', '-' -replace '[^\w\-]', ''

    $path = Join-Path "content/posts" "$slug.md"
    if (Test-Path -LiteralPath $path) {
        Write-Host "文件已存在: $path" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }

    & hugo new content/posts/$slug.md 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "创建失败" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }

    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $content = $content -replace "title = '[^']*'", "title = '$title'"
    [System.IO.File]::WriteAllText((Resolve-Path $path).Path, $content, [System.Text.UTF8Encoding]::new($false))

    Write-Host ""
    Write-Host "已创建文章: $path" -ForegroundColor Green
    Write-Host "标题: $title" -ForegroundColor Green
    Write-Host ""
    Write-Host "下一步:" -ForegroundColor Cyan
    Write-Host "  1. 编辑文章正文"
    Write-Host "  2. 将 front matter 中的 draft = true 改为 draft = false"
    Write-Host "  3. 回到本菜单选择 [3] 发布"
    Write-Host ""

    $open = Read-Host "是否现在打开编辑？(y/n，回车否)"
    if ($open.Trim() -eq 'y') {
        Start-Process -FilePath $path
    }
    Write-Host ""
    Read-Host "按回车返回菜单"
}

function Preview-Site {
    if (-not (Test-HugoSite)) { return }
    Write-Host ""
    Write-Host "启动本地预览服务器..." -ForegroundColor Cyan
    Write-Host "浏览器访问: http://localhost:1313/Thomas/" -ForegroundColor Green
    Write-Host "按 Ctrl+C 停止" -ForegroundColor Yellow
    Write-Host ""
    Start-Sleep -Seconds 2
    & hugo server -D --buildDrafts
    Write-Host ""
    Read-Host "按回车返回菜单"
}

function Publish-Site {
    if (-not (Test-HugoSite)) { return }

    $status = git status --porcelain 2>&1
    if ([string]::IsNullOrWhiteSpace($status)) {
        Write-Host "没有改动需要提交" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    Write-Host ""
    Write-Host "待提交的改动:" -ForegroundColor Cyan
    git status --short
    Write-Host ""

    $defaultMsg = "publish: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $msg = Read-Host "请输入提交信息 (回车用默认: $defaultMsg)"
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $defaultMsg }

    Write-Host ""
    git add -A
    git commit -m $msg 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "提交失败" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host "正在推送到 GitHub..." -ForegroundColor Cyan
    git push 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "推送成功！" -ForegroundColor Green
        Write-Host "GitHub Actions 将自动构建部署 (约 1-2 分钟)" -ForegroundColor Green
        Write-Host "构建进度: $ActionsURL" -ForegroundColor Cyan
        Write-Host "站点地址: $SiteURL" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "推送失败，请检查网络或代理" -ForegroundColor Red
    }
    Write-Host ""
    Read-Host "按回车返回菜单"
}

function Build-Site {
    if (-not (Test-HugoSite)) { return }
    Write-Host ""
    Write-Host "构建站点..." -ForegroundColor Cyan
    & hugo --gc
    Write-Host ""
    if ($LASTEXITCODE -eq 0) {
        Write-Host "构建成功" -ForegroundColor Green
    } else {
        Write-Host "构建失败，请检查错误信息" -ForegroundColor Red
    }
    Write-Host ""
    Read-Host "按回车返回菜单"
}

function Show-Status {
    Write-Host ""
    Write-Host "站点地址: $SiteURL" -ForegroundColor Cyan
    Write-Host "Actions:  $ActionsURL" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "本地仓库状态:" -ForegroundColor Cyan
    $branch = git rev-parse --abbrev-ref HEAD 2>&1
    Write-Host "  当前分支: $branch"
    $ahead = git rev-list --count origin/main..HEAD 2>&1
    if ($ahead -and $ahead -gt 0) {
        Write-Host "  未推送提交: $ahead 个" -ForegroundColor Yellow
    } else {
        Write-Host "  未推送提交: 0" -ForegroundColor Green
    }
    $dirty = git status --porcelain 2>&1
    if ([string]::IsNullOrWhiteSpace($dirty)) {
        Write-Host "  工作区: 干净" -ForegroundColor Green
    } else {
        $count = ($dirty | Measure-Object).Count
        Write-Host "  工作区: 有 $count 个改动" -ForegroundColor Yellow
    }
    Write-Host ""
    Read-Host "按回车返回菜单"
}

while ($true) {
    Show-Banner
    Show-Menu
    $choice = Read-Host "请选择 [0-5]"
    switch ($choice) {
        "1" { New-Post }
        "2" { Preview-Site }
        "3" { Publish-Site }
        "4" { Build-Site }
        "5" { Show-Status }
        "0" {
            Write-Host "再见！" -ForegroundColor Cyan
            Start-Sleep -Seconds 1
            break
        }
        default {
            Write-Host "无效选择" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
    if ($choice -eq "0") { break }
}
