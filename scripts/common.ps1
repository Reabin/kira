function Get-CopyAuthKeyDefine {
    # 拷贝接口登录的签名密钥 = 官方 APK 签名证书 DER 的 MD5 hex。
    # 它不入库：从环境变量 COPY_AUTH_KEY 读取，取不到就返回空（接口登录
    # 入口在应用里自动隐藏）。
    $key = $env:COPY_AUTH_KEY
    if ([string]::IsNullOrWhiteSpace($key)) { return '' }
    return "--dart-define=COPY_AUTH_KEY=$($key.Trim())"
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
