# kira 一键启动脚本（psmux 托管，复用 run-kira driver）
# 用法: .\scripts\run.ps1 [win|mumu|emu] [-Stop] [-Log]
#   win   flutter run -d win
#   mumu  启动 MuMu 模拟器 → adb connect 127.0.0.1:5557 → flutter run -d 127
#   emu   flutter emulators --launch Medium_Phone_API_36 → flutter run -d emu
# 无参数: 打印用法

param(
    [Parameter(Position = 0)]
    [ValidateSet('win', 'mumu', 'emu')]
    [string]$Target,
    [switch]$Stop,
    [switch]$Log,
    [switch]$NoWait
)

$SessionName = 'kira'
$MuMuManager = 'C:\Program Files\Netease\MuMu\nx_main\MuMuManager.exe'
$MuMuIndex = 1
$MuMuAdbAddr = '127.0.0.1:5557'
$EmulatorName = 'Medium_Phone_API_36'
$Driver = '.claude/skills/run-kira/driver.mjs'

function Test-Session {
    psmux has-session -t $SessionName 2>$null
    return ($LASTEXITCODE -eq 0)
}

if ($Stop) {
    node $Driver stop --yes
    exit $LASTEXITCODE
}

if ($Log) {
    if (Test-Session) {
        node $Driver log 40
    } else {
        Write-Host "session $SessionName 不存在"
    }
    exit 0
}

if (-not $Target) {
    Write-Host @"
用法: .\scripts\run.ps1 <win|mumu|emu> [-Stop] [-Log] [-NoWait]

  win   Windows 桌面运行
  mumu  MuMu 模拟器 (127.0.0.1:5557)
  emu   Android emulator ($EmulatorName)

  -Stop    停止并清理 psmux session
  -Log     查看最近 40 行运行输出
  -NoWait  启动后立刻返回，不等应用编译就绪（编译在后台继续，
           用 -Log 看进度；不传则等到就绪，之后才能安全热重载）

示例:
  .\scripts\run.ps1 win
  .\scripts\run.ps1 win -NoWait
  .\scripts\run.ps1 mumu
"@
    exit 0
}

# 已运行则先停掉（冷启动全新设备）
if (Test-Session) {
    Write-Host "session $SessionName 已在运行，先停止旧进程..."
    node $Driver stop --yes
    Start-Sleep -Seconds 2
}

# ---- 设备准备，解析出 flutter -d 参数 ----
$DeviceArg = switch ($Target) {
    'win'  { 'windows' }
    'mumu' {
        Write-Host "启动 MuMu 模拟器..."
        if (-not (Test-Path $MuMuManager)) { throw "找不到 MuMuManager: $MuMuManager" }
        & $MuMuManager control -v 1 launch | Out-Null
        Write-Host "等待模拟器就绪并连接 adb $MuMuAdbAddr ..."
        $ok = $false
        for ($i = 0; $i -lt 24; $i++) {
            adb connect $MuMuAdbAddr 2>&1 | Out-Null
            $devices = adb devices
            if ($devices -match ([regex]::Escape($MuMuAdbAddr) + '\s+device')) { $ok = $true; break }
            Start-Sleep -Seconds 5
        }
        if (-not $ok) { throw "adb 连接 $MuMuAdbAddr 超时，请手动检查模拟器状态" }
        Write-Host "MuMu 已连接"
        '127'
    }
    'emu'  {
        Write-Host "启动 Android 模拟器 $EmulatorName ..."
        flutter emulators --launch $EmulatorName | Out-Null
        Write-Host "等待模拟器上线..."
        $ok = $false
        for ($i = 0; $i -lt 24; $i++) {
            $devices = adb devices
            if ($devices -match 'emulator-\d+\s+device') { $ok = $true; break }
            Start-Sleep -Seconds 5
        }
        if (-not $ok) { throw "等待模拟器上线超时，请手动检查" }
        Write-Host "模拟器已上线"
        'emu'
    }
}

# ---- 通过 driver 启动（session 名、就绪轮询统一） ----
$env:KIRA_DEVICE = $DeviceArg
Write-Host "启动: flutter run -d $DeviceArg"

# 拷贝接口登录的签名密钥。桌面调试时 driver 里 `flutter run` 继承本进程环境
# 变量，应用侧直接读 Platform.environment 即可；Android 设备没有环境变量，
# 需要时用 --dart-define 自行启动（见 docs/architecture.md）。
. "$PSScriptRoot\common.ps1"
if (-not (Get-CopyAuthKeyDefine)) {
    Write-Host "未设置 COPY_AUTH_KEY，接口登录入口将不出现在应用中" -ForegroundColor DarkYellow
}
if ($NoWait) {
    node $Driver start --no-wait
} else {
    node $Driver start
}
exit $LASTEXITCODE
