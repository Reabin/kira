$projectRoot = Split-Path $PSScriptRoot -Parent

$pubspec = Join-Path $projectRoot "pubspec.yaml"

$versionCode = [int](git -C $projectRoot rev-list --count HEAD).Trim() + 1

# 显式 UTF-8（无 BOM）：默认编码随系统区域走，pubspec 里的中文注释会被写坏。
$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [System.IO.File]::ReadAllText($pubspec, $utf8)

$text = [regex]::Replace(
    $text,
    '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(\+\d+)?',
    { param($m) "version: $($m.Groups[1].Value)+$versionCode" }
)

[System.IO.File]::WriteAllText($pubspec, $text, $utf8)

Write-Host "Updated versionCode -> $versionCode"
