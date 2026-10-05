function Get-CurrentTag {
    # 必须 @() 包裹：单个 tag 时原样返回字符串，[0] 会取到首字符而非整行
    $tags = @(git tag --sort=-v:refname 2>$null)
    # 忽略 beta 预发布 tag，基线版本从最新正式版算起
    $tags = @($tags | Where-Object { $_ -notmatch 'beta' })
    if ($tags.Count -gt 0) { return $tags[0] }
    return 'v0.0.0'
}

function Update-PubspecVersion {
    param([string]$Version)
    $file = 'pubspec.yaml'
    $content = Get-Content $file -Raw
    $content = $content -replace '(?m)^version: .*', "version: $Version"
    Set-Content $file $content -NoNewline
}

function Update-Changelog {
    # CHANGELOG.md 的约定：整个文件就是「最新一个版本的 release notes」，
    # 每次发布整体覆盖。这里按上个正式 tag..HEAD 的提交标题生成 GitHub
    # alert 块草稿（Merge 与历次 release commit 除外），润色交给发布者。
    # 显式 UTF8：默认编码随系统区域走，中文条目会写坏。
    $baseline = Get-CurrentTag
    $range = if ($baseline -eq 'v0.0.0') { 'HEAD' } else { "$baseline..HEAD" }
    $subjects = @(
        git log --pretty=format:%s $range 2>$null | Where-Object {
            $_ -and $_ -notmatch '^Merge\b' -and $_ -notmatch 'chore: release \S+$'
        }
    )
    $lines = @('> [!TIP]', '>')
    foreach ($s in $subjects) { $lines += "> - $s" }
    Set-Content -Path 'docs/CHANGELOG.md' -Value ($lines -join "`n") -NoNewline -Encoding UTF8
}

function Invoke-RunCommand {
    param([string]$Command, [string[]]$Arguments)
    $result = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "命令执行失败: $Command $($Arguments -join ' ')`n$result"
    }
}

function Get-RepoUrl {
    return (git config --get remote.origin.url).Trim()
}

function Get-RepoPath {
    param([string]$Url)
    if ($Url -match 'github\.com[:/](.+/.+?)(\.git)?$') {
        return $Matches[1] -replace '\.git$', ''
    }
    return $null
}
