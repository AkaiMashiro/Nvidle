#Requires -Version 5.1
<#
.SYNOPSIS
    Nvidle — NVIDIA GeForce 드라이버를 앱 없이, PC가 유휴일 때 자동 업데이트.

.DESCRIPTION
    NVIDIA 공식 조회 API로 최신 Game Ready 드라이버를 확인하고, 현재 설치 버전과
    비교하여 새 버전이 있으면 다운로드 후 무인(silent) 설치합니다.
    설치되는 것은 그래픽 드라이버 구성요소뿐입니다(NVIDIA 앱/GFE 미설치).

    - 설치된 NVIDIA GPU를 자동 감지하여 어떤 카드든 동작합니다.
    - 자동 업데이트: -EnableAuto 로 PC 켤 때(로그온) 점검을 예약하고, PC가 유휴(IDLE)일
      때만 설치합니다(게임/작업 중에는 대기, 이번 세션에 유휴가 없으면 다음에 켤 때 재시도).

.PARAMETER Mode
    Update  : (기본) 새 버전이면 무인 설치
    Check   : 업데이트 여부만 확인(설치 안 함)
    Guided  : 다운로드 후 설치창을 띄워 직접 클릭

.PARAMETER Auto
    예약 작업용. 유휴 상태일 때만 설치(IdleMinutes 기준).

.EXAMPLE
    .\Nvidle.ps1
.EXAMPLE
    .\Nvidle.ps1 -Mode Check
.EXAMPLE
    .\Nvidle.ps1 -EnableAuto -IdleMinutes 15
.LINK
    https://github.com/AkaiMashiro/Nvidle
#>
[CmdletBinding()]
param(
    [ValidateSet('Update', 'Check', 'Guided')] [string]$Mode = 'Update',
    [switch]$KeepSettings,        # -clean 생략(NVIDIA 제어판 설정 보존)
    [switch]$Force,               # 동일 버전이어도 재설치
    [switch]$EnableAuto,          # 자동 업데이트 예약 등록(유휴 시 설치)
    [switch]$DisableAuto,         # 자동 업데이트 예약 해제
    [switch]$Status,              # 현재 상태 출력
    [switch]$Auto,                # (예약 작업용) PC가 유휴일 때만 설치
    [int]$IdleMinutes = 10,       # 유휴 기준(분): 이 시간 이상 무입력일 때만 설치
    [int]$Pfid = 0,               # 수동 제품 ID(자동 감지 대신, 0=자동)
    [int]$Psid = 0,               # 수동 시리즈 ID
    [switch]$NoPause,             # 끝에 멈추지 않음(예약 작업/스크립트용)
    [switch]$Elevated             # (내부용) 권한 상승 재실행 표시
)

# ============================== 상수/경로 ==============================
$Version    = '1.0.0'
$AppName    = 'Nvidle'
$TaskName   = 'Nvidle'
$DataDir    = Join-Path $env:LOCALAPPDATA $AppName
$ConfigPath = Join-Path $DataDir 'config.json'
$LogPath    = Join-Path $DataDir 'update.log'
$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Definition }
$UA         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'
$LookupUrl  = 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx'
$DriverUrl  = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php'

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# 콘솔 한글 깨짐 방지
try { $null = cmd /c 'chcp 65001' } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================== 출력/로그 ==============================
function Write-LogFile([string]$lvl, [string]$msg) {
    try {
        if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $LogPath -Value ("{0} [{1}] {2}" -f $stamp, $lvl, $msg) -Encoding UTF8
    } catch {}
}
function Emit([string]$marker, [string]$msg, [ConsoleColor]$color, [string]$lvl) {
    Write-Host "$marker $msg" -ForegroundColor $color
    Write-LogFile $lvl $msg
}
function Step($m) { Emit '>>'   $m Cyan   'INFO'  }
function Ok($m)   { Emit '[OK]' $m Green  'OK'    }
function Note($m) { Emit '[!]'  $m Yellow 'WARN'  }
function Bad($m)  { Emit '[X]'  $m Red    'ERROR' }
function Line($m) { Write-Host $m; Write-LogFile 'INFO' $m }

# ============================== 유틸 ==============================
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 제품명 정규화(매칭용): "NVIDIA GeForce RTX 4070 Ti SUPER" -> "rtx4070tisuper"
function Get-NormName([string]$s) {
    ($s -replace '(?i)nvidia|geforce|\(.*?\)', '' -replace '[^A-Za-z0-9]', '').ToLower()
}

# Windows 11 = osID 135, Windows 10 64-bit = 57
function Get-OsId {
    $b = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    if ($b -ge 22000) { 135 } else { 57 }
}

function Get-NvidiaGpu {
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'NVIDIA' -and $_.Name -notmatch 'Virtual|Mirror|Basic Display' } |
        Select-Object -First 1
}

# 현재 드라이버 버전을 NVIDIA 표기로 변환 ("32.0.15.9649" -> 596.49)
function Get-CurrentVersion {
    $gpu = Get-NvidiaGpu
    if (-not $gpu -or -not $gpu.DriverVersion) { return $null }
    $d = ($gpu.DriverVersion -replace '\D', '')
    if ($d.Length -lt 5) { return $null }
    $l5 = $d.Substring($d.Length - 5, 5)
    return [version]('{0}.{1}' -f $l5.Substring(0, 3), $l5.Substring(3, 2))
}

# 설치된 GPU 이름 -> (pfid, psid) 매핑. 캐시/수동 지정 우선.
function Resolve-Gpu($cfg) {
    $gpu = Get-NvidiaGpu
    if (-not $gpu) { throw 'NVIDIA 그래픽카드를 찾을 수 없습니다.' }
    $name = $gpu.Name.Trim()

    if ($Pfid -gt 0 -and $Psid -gt 0) { return @{ Name = $name; Pfid = $Pfid; Psid = $Psid } }
    if ($cfg.gpuName -eq $name -and [int]$cfg.pfid -gt 0 -and [int]$cfg.psid -gt 0) {
        return @{ Name = $name; Pfid = [int]$cfg.pfid; Psid = [int]$cfg.psid }
    }

    Step "GPU 자동 감지 중: $name"
    $raw = (Invoke-WebRequest -Uri "$LookupUrl`?TypeID=3" -UserAgent $UA -TimeoutSec 30 -UseBasicParsing).Content
    $rx  = [regex]'(?is)<LookupValue\s+ParentID="(\d+)">\s*<Name>(.*?)</Name>\s*<Value>(\d+)</Value>'
    $target = Get-NormName $name
    foreach ($m in $rx.Matches($raw)) {
        if ((Get-NormName $m.Groups[2].Value) -eq $target) {
            return @{ Name = $name; Pfid = [int]$m.Groups[3].Value; Psid = [int]$m.Groups[1].Value }
        }
    }
    throw "GPU '$name' 을(를) NVIDIA 목록에서 찾지 못했습니다. config.json 에 pfid/psid 를 수동 지정하거나 -Pfid/-Psid 인자를 사용하세요."
}

# 최신 Game Ready 드라이버 조회
function Get-LatestDriver([int]$pfid, [int]$psid, [int]$osId) {
    $q = "func=DriverManualLookup&psid=$psid&pfid=$pfid&osID=$osId" +
         "&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1"
    $resp = Invoke-RestMethod -Uri "$DriverUrl`?$q" -UserAgent $UA -TimeoutSec 30
    $info = $resp.IDS | ForEach-Object { $_.downloadInfo } |
            Where-Object { $_.Version -and $_.Version.Trim() } | Select-Object -First 1
    if (-not $info) { return $null }
    [pscustomobject]@{
        Version = [version]$info.Version
        Text    = $info.Version
        Url     = $info.DownloadURL
        Date    = $info.ReleaseDateTime
        Name    = [uri]::UnescapeDataString($info.Name)
    }
}

function Invoke-Download([string]$url, [string]$dest) {
    if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
    try {
        Start-BitsTransfer -Source $url -Destination $dest -Description 'NVIDIA 드라이버 다운로드' -ErrorAction Stop
    } catch {
        Note 'BITS 다운로드 실패 -> 일반 다운로드로 재시도'
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $url -OutFile $dest -UserAgent $UA -TimeoutSec 0 }
        finally { $ProgressPreference = $old }
    }
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 50MB) {
        throw '다운로드한 파일이 비정상입니다(크기 부족).'
    }
}

# 설치 후 토스트 알림(베스트 에포트)
function Show-Toast([string]$title, [string]$msg) {
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $tmpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $tmpl.GetElementsByTagName('text')
        $t.Item(0).AppendChild($tmpl.CreateTextNode($title)) | Out-Null
        $t.Item(1).AppendChild($tmpl.CreateTextNode($msg))   | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tmpl)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Nvidle').Show($toast)
    } catch {}
}

# 유휴 감지용 Win32 API 로드(1회)
function Initialize-IdleApi {
    if ('NvIdle' -as [type]) { return }
    Add-Type @"
using System; using System.Runtime.InteropServices;
public static class NvIdle {
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int s);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, int flag);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFO mi);
  public static uint IdleMs(){ var i=new LASTINPUTINFO(); i.cbSize=(uint)Marshal.SizeOf(i); GetLastInputInfo(ref i); return (uint)Environment.TickCount - i.dwTime; }
  public static int NotifState(){ int s; SHQueryUserNotificationState(out s); return s; }
  // 전경 창이 '그 창이 위치한 모니터'를 가득 채우면 true (멀티모니터/테두리없는 게임 대응)
  public static bool ForegroundIsFullscreen(){
    IntPtr h=GetForegroundWindow(); if(h==IntPtr.Zero) return false;
    RECT r; if(!GetWindowRect(h, out r)) return false;
    IntPtr mon=MonitorFromWindow(h, 2);
    MONITORINFO mi=new MONITORINFO(); mi.cbSize=Marshal.SizeOf(typeof(MONITORINFO));
    if(!GetMonitorInfo(mon, ref mi)) return false;
    RECT m=mi.rcMonitor;
    return r.Left<=m.Left+2 && r.Top<=m.Top+2 && r.Right>=m.Right-2 && r.Bottom>=m.Bottom-2;
  }
}
"@
}

# 지금 설치해도 되는 유휴 상태인지 판정 (게임/사용 중이면 보류)
#   조건: (1)무입력 idleMin분 이상  (2)전체화면 게임/발표 아님  (3)테두리없는 전체화면 아님
function Test-SafeToInstall([int]$idleMin) {
    Initialize-IdleApi
    $idleSec = [NvIdle]::IdleMs() / 1000
    $state   = [NvIdle]::NotifState()                 # 2=바쁨,3=D3D전체화면,4=발표,7=앱전체화면
    if ($idleSec -lt ($idleMin * 60)) { return @{ Safe = $false; Reason = ("사용 중(무입력 {0:N0}초 < 기준 {1}분)" -f $idleSec, $idleMin) } }
    if (@(2, 3, 4, 7) -contains $state) { return @{ Safe = $false; Reason = "전체화면/게임/발표 상태(QUNS=$state)" } }
    if ([NvIdle]::ForegroundIsFullscreen()) { return @{ Safe = $false; Reason = "전경창 전체화면(테두리없는 게임/영상 추정)" } }
    return @{ Safe = $true; Reason = ("유휴 확인(무입력 {0:N0}초)" -f $idleSec) }
}

# 설치 파일을 '드라이버만' 추출 — NVIDIA App/GeForce Experience/텔레메트리 컴포넌트 제외.
# 윈도우 내장 tar.exe 사용(외부 의존성/미서명 실행 없음). setup.cfg의 NvApp 파일참조 3줄을 제거해
# 무인설치가 깨지지 않게 함. 추출된 폴더 경로를 반환.
function Expand-DriverOnly([string]$installerExe) {
    if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
        throw 'tar.exe 가 없습니다(Windows 10 1803+ / 11 내장). 드라이버-only 추출 불가.'
    }
    $ex = Join-Path $env:TEMP 'nvidle-pkg'
    if (Test-Path $ex) { Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $ex -Force | Out-Null
    # App/GFE/텔레메트리 제외하고 추출. SFX의 PE 헤더 때문에 tar가 종료코드 255를 내지만
    # 7z 페이로드는 정상 추출되므로, 종료코드 대신 파일 존재로 성공을 판정한다.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    tar.exe -xf $installerExe -C $ex --exclude=NvApp* --exclude=NvBackend* --exclude=NvTelemetry* --exclude=ShadowPlay* --exclude=FrameViewSDK* 2>$null
    $ErrorActionPreference = $old
    if (-not (Test-Path (Join-Path $ex 'setup.exe')) -or -not (Test-Path (Join-Path $ex 'Display.Driver'))) {
        Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
        throw '드라이버 패키지 추출 실패(setup.exe/Display.Driver 없음).'
    }
    # setup.cfg manifest 에서 NvApp 폴더 파일참조 3줄 제거(없으면 무인설치 실패).
    # 다국어 문자열/인코딩 보존을 위해 UTF-8(BOM 없이) 그대로 읽고 쓴다. string 정의는 건드리지 않음.
    $cfg = Join-Path $ex 'setup.cfg'
    $t = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8)
    $t = $t -replace '(?m)^[ \t]*<file name="\$\{\{(EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile)\}\}"\s*/>\r?\n', ''
    [IO.File]::WriteAllText($cfg, $t, (New-Object Text.UTF8Encoding $false))
    return $ex
}

function Install-Driver($driver, $cfg, [switch]$Guided, [switch]$IdleGated, [int]$idleMin = 10) {
    $dest = Join-Path $env:TEMP ("nvidia-$($driver.Text).exe")
    Step "다운로드 중: $($driver.Text)  (수백 MB, 잠시 걸립니다)"
    Invoke-Download $driver.Url $dest
    Ok '다운로드 완료'

    # 다운로드 파일 코드서명 검증 — NVIDIA 서명이 아니면 실행 거부(변조/중간자 차단)
    $sig = Get-AuthenticodeSignature $dest
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=NVIDIA Corporation') {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        throw "설치 파일 서명 검증 실패 (Status=$($sig.Status)). 변조 가능성 — 설치를 중단합니다."
    }
    Ok '서명 검증 통과 (NVIDIA Corporation)'

    if ($Guided) {
        Step "설치 프로그램 실행 — 'NVIDIA 그래픽 드라이버'만 선택해 진행하세요."
        $p = Start-Process -FilePath $dest -Wait -PassThru
    } else {
        # 드라이버-only 추출 (NVIDIA App/GFE/텔레메트리 제외)
        Step '드라이버-only 추출 중 (NVIDIA App 제외)...'
        $pkg = Expand-DriverOnly $dest
        Ok '추출 완료 — NVIDIA App 제외됨'
        # 설치(화면 리셋) 직전 유휴 재확인(자동 모드): 사용 재개 시 취소하고 다음 기회에
        if ($IdleGated) {
            $safe = Test-SafeToInstall $idleMin
            if (-not $safe.Safe) {
                Remove-Item $dest, $pkg -Recurse -Force -ErrorAction SilentlyContinue
                Note "사용 재개 감지 — $($safe.Reason). 설치 취소(다음에 PC 켤 때 재시도)."
                return -1
            }
        }
        $flags = @('-s', '-noreboot')
        if (-not $KeepSettings -and $cfg.cleanInstall) { $flags += '-clean' }
        Step "무인 설치 중 (드라이버만)... 화면이 잠시 깜빡일 수 있음  옵션: $($flags -join ' ')"
        $p = Start-Process -FilePath (Join-Path $pkg 'setup.exe') -ArgumentList $flags -Wait -PassThru
        Remove-Item $pkg -Recurse -Force -ErrorAction SilentlyContinue
    }
    $code = $p.ExitCode
    Remove-Item $dest -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
    $now = Get-CurrentVersion
    if ($now -and $now -ge $driver.Version) {
        Ok "설치 완료! 현재 버전: $now"
        Show-Toast 'Nvidle' "드라이버 $($driver.Text) 설치 완료"
        $cfg.lastInstalled = $driver.Text; $cfg.lastDeferred = ''
    } elseif ($code -in 0, 1) {
        Ok "설치가 끝났습니다(종료코드 $code). 버전 반영은 재부팅 후일 수 있습니다."
        $cfg.lastInstalled = $driver.Text; $cfg.lastDeferred = ''
    } else {
        Bad "설치 실패 가능(종료코드 $code). 잠시 후 다시 시도하거나 수동 설치를 권장합니다."
    }
    return $code
}

# ============================== 자동 업데이트(예약) ==============================
function Enable-Auto([int]$idleMin) {
    if (-not (Test-Admin)) { throw '자동 업데이트 등록은 관리자 권한이 필요합니다.' }
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Auto -IdleMinutes $idleMin -NoPause -Elevated"
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trigger.Delay = 'PT3M'   # 로그온 3분 후(부팅 안정화 대기)
    $set     = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                   -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    $prin    = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $set -Principal $prin -Force `
        -Description 'NVIDIA 드라이버: PC 켤 때(로그온) 확인 + 유휴 시 설치 (드라이버만)' | Out-Null
    Ok ("자동 업데이트 켜짐 — PC 켤 때(로그온) 확인하고, 유휴(무입력 {0}분+)일 때 설치합니다." -f $idleMin)
}

function Disable-Auto {
    if (-not (Test-Admin)) { throw '자동 업데이트 해제는 관리자 권한이 필요합니다.' }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Ok '자동 업데이트 꺼짐.'
    } else { Note '등록된 자동 업데이트가 없습니다.' }
}

function Get-AutoState {
    [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

# ============================== 권한 상승 ==============================
$needAdmin = ($Mode -ne 'Check') -or $EnableAuto -or $DisableAuto
if ($needAdmin -and -not $Status -and -not (Test-Admin) -and -not $Elevated) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"", '-Mode', $Mode, '-Elevated')
    if ($KeepSettings) { $a += '-KeepSettings' }
    if ($Force)        { $a += '-Force' }
    if ($NoPause)      { $a += '-NoPause' }
    if ($Auto)         { $a += @('-Auto', '-IdleMinutes', $IdleMinutes) }
    if ($EnableAuto)   { $a += @('-EnableAuto', '-IdleMinutes', $IdleMinutes) }
    if ($DisableAuto)  { $a += '-DisableAuto' }
    if ($Pfid -gt 0)   { $a += @('-Pfid', $Pfid) }
    if ($Psid -gt 0)   { $a += @('-Psid', $Psid) }
    Step "관리자 권한으로 다시 실행합니다... (UAC 창에서 '예')"
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a }
    catch { Bad '권한 상승이 취소되었습니다. 드라이버 설치에는 관리자 권한이 필요합니다.' }
    return
}

# ============================== 메인 ==============================
$pause = -not $NoPause
$cfg = $null
function Load-Config {
    $d = @{ gpuName = ''; pfid = 0; psid = 0; cleanInstall = $true; lastCheck = ''; lastInstalled = '';
            idleMinutes = 10; lastDeferred = '' }
    if (Test-Path $ConfigPath) {
        try {
            $j = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($d.Keys)) { if ($null -ne $j.$k) { $d[$k] = $j.$k } }
        } catch {}
    }
    return $d
}
function Save-Config($c) {
    try {
        if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        $c | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { Note "설정 저장 실패: $($_.Exception.Message)" }
}

try {
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor DarkCyan
    Write-Host "  Nvidle v$Version  (NVIDIA 드라이버만 / 앱 미설치)" -ForegroundColor White
    Write-Host '==================================================' -ForegroundColor DarkCyan

    $cfg = Load-Config

    if ($EnableAuto)  {
        Enable-Auto $IdleMinutes
        $cfg.idleMinutes = $IdleMinutes; Save-Config $cfg
        return
    }
    if ($DisableAuto) { Disable-Auto; return }

    if ($Status) {
        $gpu = Get-NvidiaGpu
        Line ("GPU            : " + $(if ($gpu) { $gpu.Name } else { '없음' }))
        Line ("현재 버전      : " + $(if ($cur = Get-CurrentVersion) { $cur } else { '확인 불가' }))
        Line ("자동 업데이트  : " + $(if (Get-AutoState) { "켜짐 (PC 켤 때 확인, 유휴 $($cfg.idleMinutes)분+ 시 설치)" } else { '꺼짐' }))
        Line ("마지막 보류    : " + $(if ($cfg.lastDeferred) { $cfg.lastDeferred } else { '없음' }))
        Line ("설정/로그      : $DataDir")
        return
    }

    $osId = Get-OsId
    $gpuInfo = Resolve-Gpu $cfg
    # 감지 결과 캐시 저장
    $cfg.gpuName = $gpuInfo.Name; $cfg.pfid = $gpuInfo.Pfid; $cfg.psid = $gpuInfo.Psid

    $cur = Get-CurrentVersion
    Step ("GPU            : $($gpuInfo.Name)")
    Step ("현재 설치 버전 : " + $(if ($cur) { $cur } else { '확인 불가' }))

    Step '최신 버전 확인 중... (Game Ready)'
    $tries = if ($Auto) { 5 } else { 1 }   # 자동 모드: 로그온 직후 네트워크 지연 대비 재시도
    $latest = $null
    for ($i = 1; $i -le $tries; $i++) {
        try { $latest = Get-LatestDriver $gpuInfo.Pfid $gpuInfo.Psid $osId; if ($latest) { break } } catch {}
        if ($i -lt $tries) { Start-Sleep -Seconds 30 }
    }
    if (-not $latest) { throw '최신 드라이버 정보를 가져오지 못했습니다. (인터넷/방화벽 확인)' }
    Step ("최신 버전      : {0}   ({1}, {2})" -f $latest.Text, $latest.Name, $latest.Date)

    $cfg.lastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    if (-not $cur) { $cur = [version]'0.0'; Note '현재 버전을 못 읽어 최신 버전으로 설치를 진행합니다.' }

    if (-not (($latest.Version -gt $cur) -or $Force)) {
        Write-Host ''
        Ok '이미 최신 버전입니다. 업데이트할 필요가 없습니다.'
        Save-Config $cfg
        return
    }

    if ($latest.Version -gt $cur) {
        Write-Host ''
        Write-Host "  >> 새 버전이 있습니다:  $cur  ->  $($latest.Text)" -ForegroundColor Yellow
    } else {
        Note '-Force 지정: 동일/이전 버전이지만 재설치합니다.'
    }

    # 자동(예약) 실행: 새 드라이버가 있어도 PC가 유휴 상태가 될 때까지 기다렸다가 설치.
    # 게임/사용 중이면 조용히 대기하고, 이번 세션에 유휴가 안 오면 다음에 PC 켤 때 다시 시도.
    if ($Auto) {
        $deadline = (Get-Date).AddHours(6)
        $logged = $false
        while ($true) {
            $safe = Test-SafeToInstall $IdleMinutes
            if ($safe.Safe) { Ok "유휴 확인 — $($safe.Reason)"; break }
            if (-not $logged) {
                Note "새 드라이버 대기 중 — $($safe.Reason). 자리를 비우면 설치합니다."
                $cfg.lastDeferred = (Get-Date -Format 'yyyy-MM-dd HH:mm') + "  $($safe.Reason)"
                Save-Config $cfg; $logged = $true
            }
            if ((Get-Date) -ge $deadline) {
                Note '이번엔 유휴 시점을 못 잡아 보류 — 다음에 PC 켤 때 다시 확인합니다.'
                return
            }
            Start-Sleep -Seconds 300
        }
    }

    switch ($Mode) {
        'Check'  { Line "`n[확인 모드] 설치는 하지 않습니다. 다운로드 주소:`n  $($latest.Url)" }
        'Guided' { Install-Driver $latest $cfg -Guided | Out-Null }
        'Update' {
            if ($Auto) { Install-Driver $latest $cfg -IdleGated -idleMin $IdleMinutes | Out-Null }
            else       { Install-Driver $latest $cfg | Out-Null }
        }
    }
    Save-Config $cfg
}
catch {
    Bad $_.Exception.Message
}
finally {
    if ($pause) {
        Write-Host ''
        Read-Host '엔터를 누르면 창이 닫힙니다'
    }
}
