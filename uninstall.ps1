#Requires -Version 5.1
<#
  NVIDIA Driver Updater — 완전 제거 스크립트
  ------------------------------------------------------------------
  - 자동 업데이트 예약 작업 삭제
  - %LOCALAPPDATA%\Nvidle\ (엔진/설정/로그) 전체 삭제
  ※ 이미 설치된 그래픽 드라이버 자체는 건드리지 않습니다.

  로컬:  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
  웹  :  irm https://raw.githubusercontent.com/AkaiMashiro/Nvidle/main/uninstall.ps1 | iex
#>
[CmdletBinding()]
param([switch]$Elevated, [switch]$Relaunched)
try { $null = cmd /c 'chcp 65001' } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$AppName  = 'Nvidle'
$TaskName = 'Nvidle'
$DataDir  = Join-Path $env:LOCALAPPDATA $AppName
$selfPath = $PSCommandPath

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 권한 상승 — 자기 자신이 삭제 대상 폴더 안에 있으면 TEMP로 복사해 실행(파일 잠금 회피)
if (-not (Test-Admin) -and -not $Elevated) {
    if ($selfPath) {
        $launch = $selfPath
        if ($selfPath -like "$DataDir*") {
            $launch = Join-Path $env:TEMP 'nvidle-uninstall.ps1'; Copy-Item $selfPath $launch -Force
        }
        Write-Host '>> 관리자 권한으로 다시 실행합니다... (UAC 창에서 예)' -ForegroundColor Cyan
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$launch`" -Elevated -Relaunched"
    } else {
        # 웹(irm|iex) 모드: 같은 한 줄 명령을 관리자 권한으로 다시 실행
        Write-Host '>> 관리자 권한으로 다시 실행합니다... (UAC 창에서 예)' -ForegroundColor Cyan
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/AkaiMashiro/Nvidle/main/uninstall.ps1 | iex`""
    }
    return
}

# 관리자이지만 삭제 대상 폴더 내부에서 실행 중이면 TEMP로 옮겨 재실행
if ($selfPath -and ($selfPath -like "$DataDir*") -and -not $Relaunched) {
    $tmp = Join-Path $env:TEMP 'nvidle-uninstall.ps1'; Copy-Item $selfPath $tmp -Force
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`" -Elevated -Relaunched"
    return
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor DarkCyan
Write-Host '  Nvidle 제거' -ForegroundColor White
Write-Host '==================================================' -ForegroundColor DarkCyan

Write-Host '>> 자동 업데이트 예약 작업 삭제...' -ForegroundColor Cyan
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host '[OK] 예약 작업 삭제됨' -ForegroundColor Green
} else {
    Write-Host '[!] 예약 작업 없음(건너뜀)' -ForegroundColor Yellow
}

Write-Host '>> 데이터 폴더 삭제...' -ForegroundColor Cyan
if (Test-Path $DataDir) {
    Remove-Item $DataDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $DataDir) { Write-Host "[!] 일부 파일이 사용 중이라 남았습니다: $DataDir" -ForegroundColor Yellow }
    else { Write-Host '[OK] 데이터 폴더 삭제됨' -ForegroundColor Green }
} else {
    Write-Host '[!] 데이터 폴더 없음(건너뜀)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '[OK] 제거 완료. (그래픽 드라이버 자체는 그대로 유지됩니다)' -ForegroundColor Green
Write-Host ''
Read-Host '엔터를 누르면 닫힙니다'
