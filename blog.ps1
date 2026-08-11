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
    Write-Host "  [2] 导入本地 md 文件" -ForegroundColor Yellow
    Write-Host "  [3] 本地预览" -ForegroundColor Yellow
    Write-Host "  [4] 发布文章 (提交并推送)" -ForegroundColor Yellow
    Write-Host "  [5] 构建测试" -ForegroundColor Yellow
    Write-Host "  [6] 查看站点状态" -ForegroundColor Yellow
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

# 分离 front matter 和正文
function Split-PostContent {
    param([string]$content)
    $result = @{ Type = "none"; FrontMatter = ""; Body = $content }
    $trimmed = $content.TrimStart()
    if ($trimmed.StartsWith("---")) {
        $lines = $content -split "`r?`n"
        $fmLines = [System.Collections.Generic.List[string]]::new()
        $bodyLines = [System.Collections.Generic.List[string]]::new()
        $inFm = $false; $closed = $false; $startCount = 0
        foreach ($line in $lines) {
            if (-not $closed) {
                if ($line.Trim() -eq "---") {
                    $startCount++
                    if ($startCount -eq 1) { $inFm = $true; continue }
                    if ($startCount -eq 2) { $closed = $true; $inFm = $false; continue }
                }
                if ($inFm) { $fmLines.Add($line) } else { $bodyLines.Add($line) }
            } else { $bodyLines.Add($line) }
        }
        $result.Type = "yaml"
        $result.FrontMatter = ($fmLines -join "`n")
        $result.Body = ($bodyLines -join "`n")
    } elseif ($trimmed.StartsWith("+++")) {
        $lines = $content -split "`r?`n"
        $fmLines = [System.Collections.Generic.List[string]]::new()
        $bodyLines = [System.Collections.Generic.List[string]]::new()
        $inFm = $false; $closed = $false
        foreach ($line in $lines) {
            if (-not $closed) {
                if ($line.Trim() -eq "+++") {
                    if (-not $inFm) { $inFm = $true; continue } else { $closed = $true; $inFm = $false; continue }
                }
                if ($inFm) { $fmLines.Add($line) } else { $bodyLines.Add($line) }
            } else { $bodyLines.Add($line) }
        }
        $result.Type = "toml"
        $result.FrontMatter = ($fmLines -join "`n")
        $result.Body = ($bodyLines -join "`n")
    }
    return $result
}

# 解析 YAML front matter
function Parse-YamlFrontMatter {
    param([string]$yaml)
    $data = [ordered]@{}
    $lines = $yaml -split "`r?`n"
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line.Trim() -eq "") { $i++; continue }
        if ($line -notmatch '^\s*([A-Za-z_][\w\-]*)\s*:\s*(.*)$') { $i++; continue }
        $key = $Matches[1]; $val = $Matches[2].Trim()
        if ($val -eq "") {
            $arr = [System.Collections.Generic.List[string]]::new()
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -match '^\s*-\s+(.*)$') {
                $arr.Add($Matches[1].Trim().Trim("'").Trim('"'))
                $j++
            }
            if ($arr.Count -gt 0) { $data[$key] = $arr.ToArray(); $i = $j; continue }
            $data[$key] = ""; $i++; continue
        }
        if ($val -match '^\[(.*)\]$') {
            $items = $Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ -ne "" }
            $data[$key] = @($items); $i++; continue
        }
        $val = $val.Trim("'").Trim('"')
        $data[$key] = $val
        $i++
    }
    return $data
}

# 解析 TOML front matter
function Parse-TomlFrontMatter {
    param([string]$toml)
    $data = [ordered]@{}
    $lines = $toml -split "`r?`n"
    foreach ($line in $lines) {
        if ($line.Trim() -eq "") { continue }
        if ($line -notmatch '^\s*([A-Za-z_][\w\-]*)\s*=\s*(.*)$') { continue }
        $key = $Matches[1]; $val = $Matches[2].Trim()
        if ($val -match '^\[(.*)\]$') {
            $items = $Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ -ne "" }
            $data[$key] = @($items); continue
        }
        $val = $val.Trim("'").Trim('"')
        $data[$key] = $val
    }
    return $data
}

# 生成 TOML front matter 文本
function Build-TomlFrontMatter {
    param([System.Collections.Specialized.OrderedDictionary]$data)
    $boolKeys = @("draft", "toc", "comment", "autoCollapseToc")
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("+++")
    foreach ($key in $data.Keys) {
        $val = $data[$key]
        if ($val -is [bool]) {
            [void]$sb.AppendLine("$key = $(if ($val) {'true'} else {'false'})")
        } elseif ($val -is [array]) {
            $items = ($val | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ", "
            [void]$sb.AppendLine("$key = [$items]")
        } elseif ($key -in $boolKeys) {
            [void]$sb.AppendLine("$key = $val")
        } else {
            [void]$sb.AppendLine("$key = '$($val -replace "'", "''")'")
        }
    }
    [void]$sb.AppendLine("+++")
    return $sb.ToString()
}

# 补全缺失字段，返回 @{ Data=...; Changes=@() }
function Complete-FrontMatter {
    param(
        [System.Collections.Specialized.OrderedDictionary]$data,
        [string]$fallbackTitle
    )
    $defaults = [ordered]@{
        title = $fallbackTitle
        date = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
        draft = "true"
        author = "Thomas"
        categories = @("技术")
        tags = @()
        description = ""
        keywords = ""
        featuredImage = ""
        featuredImagePreview = ""
        toc = "true"
        autoCollapseToc = "true"
        comment = "true"
    }
    $result = [ordered]@{}
    $changes = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $defaults.Keys) {
        if ($data.Contains($key) -and $data[$key] -ne "" -and $data[$key] -ne $null) {
            $result[$key] = $data[$key]
        } else {
            if ($data.Contains($key)) {
                $changes.Add("补全空值字段: $key")
            } else {
                $changes.Add("新增缺失字段: $key")
            }
            $result[$key] = $defaults[$key]
        }
    }
    foreach ($key in $data.Keys) {
        if (-not $result.Contains($key)) { $result[$key] = $data[$key] }
    }
    foreach ($arrKey in @("categories", "tags")) {
        if ($result.Contains($arrKey) -and $result[$arrKey] -is [string] -and $result[$arrKey] -ne "") {
            $result[$arrKey] = @($result[$arrKey])
            $changes.Add("$arrKey 由字符串转为数组格式")
        }
    }
    return @{ Data = $result; Changes = $changes.ToArray() }
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

function Import-Post {
    if (-not (Test-HugoSite)) { return }

    Write-Host ""
    Write-Host "导入本地 Markdown 文件作为新文章" -ForegroundColor Cyan
    Write-Host "支持自动转换 front matter (YAML→TOML)、补全字段、处理本地图片" -ForegroundColor DarkGray
    Write-Host ""

    $srcInput = Read-Host "请输入 md 文件路径 (可直接拖入文件)"
    $srcPath = $srcInput.Trim().Trim('"').Trim("'").Trim()
    if ([string]::IsNullOrWhiteSpace($srcPath)) {
        Write-Host "路径不能为空" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }
    if (-not (Test-Path -LiteralPath $srcPath -PathType Leaf)) {
        Write-Host "文件不存在: $srcPath" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $content = Get-Content -LiteralPath $srcPath -Raw -Encoding UTF8
    $parts = Split-PostContent $content
    $changes = [System.Collections.Generic.List[string]]::new()

    # 解析已有 front matter
    $fmData = [ordered]@{}
    if ($parts.Type -eq "yaml") {
        $fmData = Parse-YamlFrontMatter $parts.FrontMatter
        $changes.Add("front matter: YAML 转换为 TOML 格式")
    } elseif ($parts.Type -eq "toml") {
        $fmData = Parse-TomlFrontMatter $parts.FrontMatter
    } else {
        $changes.Add("无 front matter，已自动生成")
    }

    # 推断标题
    $inferTitle = [System.IO.Path]::GetFileNameWithoutExtension($srcPath) -replace '-', ' ' -replace '_', ' '
    if ($parts.Body -match '(?m)^#\s+(.+)$') { $inferTitle = $Matches[1].Trim() }
    if ($fmData.Contains("title") -and $fmData["title"] -ne "") { $inferTitle = $fmData["title"] }

    # 补全字段
    $completed = Complete-FrontMatter $fmData $inferTitle
    $finalData = $completed.Data
    foreach ($c in $completed.Changes) { $changes.Add($c) }

    # 扫描本地图片引用
    $srcDir = [System.IO.Path]::GetDirectoryName($srcPath)
    $body = $parts.Body
    $imageMatches = [regex]::Matches($body, '!\[([^\]]*)\]\(([^)]+)\)')
    $localImages = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($m in $imageMatches) {
        $alt = $m.Groups[1].Value
        $imgPath = $m.Groups[2].Value
        if ($imgPath -match '^(https?|ftp)://') { continue }
        if ($imgPath -match '^[A-Za-z]:[\\/]') {
            $absImg = $imgPath
        } else {
            $absImg = [System.IO.Path]::GetFullPath((Join-Path $srcDir $imgPath))
        }
        if (Test-Path -LiteralPath $absImg -PathType Leaf) {
            $localImages.Add(@{ Alt = $alt; Original = $imgPath; Absolute = $absImg; FileName = [System.IO.Path]::GetFileName($absImg) })
        }
    }
    if ($localImages.Count -gt 0) {
        $changes.Add("发现 $($localImages.Count) 张本地图片，将转为 Page Bundle 结构并复制")
        foreach ($img in $localImages) {
            $body = $body -replace [regex]::Escape($img.Original), $img.FileName
        }
    }

    # 生成 slug
    $defaultSlug = (Get-Date -Format "yyyy-MM-dd")
    $slug = Read-Host "请输入文件名 slug (回车用默认: $defaultSlug)"
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = $defaultSlug }
    $slug = $slug.Trim() -replace '\s+', '-' -replace '[^\w\-]', ''

    $hasImages = $localImages.Count -gt 0
    if ($hasImages) {
        $destDir = Join-Path "content/posts" $slug
        $destPath = Join-Path $destDir "index.md"
    } else {
        $destPath = Join-Path "content/posts" "$slug.md"
    }
    if (Test-Path -LiteralPath $destPath) {
        Write-Host "目标文件已存在: $destPath" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    # 询问 draft 状态
    Write-Host ""
    Write-Host "是否作为草稿导入？" -ForegroundColor Cyan
    Write-Host "  [1] 草稿 (draft = true，暂不发布)" -ForegroundColor Yellow
    Write-Host "  [2] 直接发布 (draft = false)" -ForegroundColor Yellow
    $draftChoice = Read-Host "请选择 [1/2，回车默认 1]"
    if ($draftChoice.Trim() -eq "2") { $finalData["draft"] = "false" } else { $finalData["draft"] = "true" }

    # 显示调整报告
    Write-Host ""
    Write-Host "========== 导入预览 ==========" -ForegroundColor Cyan
    Write-Host "标题: $($finalData["title"])" -ForegroundColor Green
    Write-Host "目标: $destPath" -ForegroundColor Green
    if ($hasImages) { Write-Host "图片: $($localImages.Count) 张 → $destDir\" -ForegroundColor Green }
    Write-Host ""
    Write-Host "自动调整项 ($($changes.Count) 项):" -ForegroundColor Yellow
    foreach ($c in $changes) { Write-Host "  - $c" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "--- 最终 front matter ---" -ForegroundColor DarkGray
    $tomlFm = Build-TomlFrontMatter $finalData
    Write-Host $tomlFm -ForegroundColor DarkGray
    Write-Host "==============================" -ForegroundColor Cyan

    Write-Host ""
    $confirm = Read-Host "确认导入？(y/n，回车 y)"
    if ($confirm.Trim() -ne "y" -and $confirm.Trim() -ne "") {
        Write-Host "已取消" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    # 执行写入
    if ($hasImages) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        foreach ($img in $localImages) {
            Copy-Item -LiteralPath $img.Absolute -Destination $destDir -Force
        }
    }
    $finalContent = $tomlFm + "`n" + $body.TrimStart() + "`n"
    [System.IO.File]::WriteAllText((Join-Path $Root $destPath), $finalContent, [System.Text.UTF8Encoding]::new($false))

    Write-Host ""
    Write-Host "导入成功！" -ForegroundColor Green
    Write-Host "文件: $destPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "下一步:" -ForegroundColor Cyan
    Write-Host "  1. 检查文章内容和格式"
    Write-Host "  2. 选择 [2] 本地预览确认效果"
    Write-Host "  3. 选择 [3] 发布"
    Write-Host ""

    $open = Read-Host "是否现在打开编辑？(y/n，回车否)"
    if ($open.Trim() -eq 'y') {
        Start-Process -FilePath (Join-Path $Root $destPath)
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
    $choice = Read-Host "请选择 [0-6]"
    switch ($choice) {
        "1" { New-Post }
        "2" { Import-Post }
        "3" { Preview-Site }
        "4" { Publish-Site }
        "5" { Build-Site }
        "6" { Show-Status }
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
