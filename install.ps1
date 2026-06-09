#Requires -Version 5.1
<#
  NVIDIA Driver Updater — 원클릭 설치 스크립트
  ------------------------------------------------------------------
  엔진을 %LOCALAPPDATA%\Nvidle\bin\ 에 설치하고,
  PC 켤 때(로그온) 확인 + 유휴 시 설치하는 자동 업데이트를 등록한 뒤, 1회 점검합니다.

  로컬:  powershell -ExecutionPolicy Bypass -File .\install.ps1
  웹  :  $f = "$env:TEMP\nvidle-install.ps1"; irm https://raw.githubusercontent.com/AkaiMashiro/Nvidle/main/install.ps1 -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f
#>
[CmdletBinding()]
param(
    [int]$IdleMinutes = 10,       # 유휴 기준(분) — 이 시간 이상 무입력일 때만 설치
    [switch]$NoFirstUpdate,       # 설치 직후 첫 업데이트를 건너뜀
    [string]$RepoRaw = 'https://raw.githubusercontent.com/AkaiMashiro/Nvidle/main',
    [switch]$Elevated             # (내부용)
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { $null = cmd /c 'chcp 65001' } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$AppName  = 'Nvidle'
$DataDir  = Join-Path $env:LOCALAPPDATA $AppName
$BinDir   = Join-Path $DataDir 'bin'
$Engine   = Join-Path $BinDir 'Nvidle.ps1'
$selfPath = $PSCommandPath
$selfDir  = if ($selfPath) { Split-Path $selfPath -Parent } else { '' }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 관리자 권한 상승(설치/예약 등록에 필요)
if (-not (Test-Admin) -and -not $Elevated) {
    $opt = "-IdleMinutes $IdleMinutes -Elevated" + $(if ($NoFirstUpdate) { ' -NoFirstUpdate' } else { '' })
    Write-Host '>> 관리자 권한으로 다시 실행합니다... (UAC 창에서 예)' -ForegroundColor Cyan
    if ($selfPath) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`" $opt"
    } else {
        # 웹 모드(파일 없이 실행): BOM 보존 위해 임시파일로 받아 관리자 권한으로 실행
        $tmp = Join-Path $env:TEMP 'nvidle-install.ps1'
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $RepoRaw/install.ps1 -OutFile '$tmp'; & '$tmp'`""
    }
    return
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor DarkCyan
Write-Host '  Nvidle 설치 (NVIDIA 드라이버 업데이터)' -ForegroundColor White
Write-Host '==================================================' -ForegroundColor DarkCyan

# 1) 엔진 확보 — 로컬 클론(엔진+제거스크립트가 한 폴더에 같이 있음)이면 로컬 사본,
#    아니면(웹 설치: 임시폴더에 install.ps1 만 받아짐) 깃허브에서 다운로드.
#    이렇게 하면 대소문자 무시(nvidle.ps1==Nvidle.ps1)로 임시 install.ps1 을 엔진으로 오인하지 않음.
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
$localEngine = if ($selfDir) { Join-Path $selfDir 'Nvidle.ps1' }   else { '' }
$localUninst = if ($selfDir) { Join-Path $selfDir 'uninstall.ps1' } else { '' }
$useLocal = $localEngine -and (Test-Path $localEngine) -and $localUninst -and (Test-Path $localUninst)
if ($useLocal) {
    Copy-Item $localEngine $Engine -Force
    Copy-Item $localUninst (Join-Path $BinDir 'uninstall.ps1') -Force
    Write-Host ">> 엔진 설치(로컬 사본): $Engine" -ForegroundColor Cyan
} else {
    Write-Host ">> 엔진 다운로드: $RepoRaw" -ForegroundColor Cyan
    Invoke-WebRequest "$RepoRaw/Nvidle.ps1" -OutFile $Engine -UseBasicParsing
    Invoke-WebRequest "$RepoRaw/uninstall.ps1" -OutFile (Join-Path $BinDir 'uninstall.ps1') -UseBasicParsing
}

# 2) 자동 업데이트(유휴 게이트) 등록 — 이미 관리자이므로 추가 UAC 없음
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -EnableAuto -IdleMinutes $IdleMinutes -NoPause -Elevated

# 3) 첫 점검/설치(사용자가 직접 실행 중이므로 즉시 진행)
if (-not $NoFirstUpdate) {
    Write-Host ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Mode Update -NoPause -Elevated
}

$uninst = Join-Path $BinDir 'uninstall.ps1'
Write-Host ''
Write-Host '[OK] 설치 완료!' -ForegroundColor Green
Write-Host "  - 도구 위치   : $BinDir"
Write-Host "  - 자동 업데이트: PC 켤 때(로그온) 점검, 유휴(무입력 ${IdleMinutes}분+)일 때 설치"
Write-Host "  - 상태 보기   : powershell -ExecutionPolicy Bypass -File `"$Engine`" -Status"
Write-Host "  - 제거        : powershell -ExecutionPolicy Bypass -File `"$uninst`""
Write-Host ''
Read-Host '엔터를 누르면 닫힙니다'
