# Nvidle

NVIDIA driver updater that installs new drivers only while your PC is idle.

[English](#english) · [한국어](#한국어)

## English

Update the NVIDIA GeForce driver from PowerShell, without GeForce Experience or the NVIDIA App.
It detects your GPU, installs the driver only, and can update automatically while the PC is idle.

Windows 10/11, PowerShell 5.1+. No dependencies.

### Install

```powershell
$f = "$env:TEMP\nvidle-install.ps1"; irm https://raw.githubusercontent.com/AkaiMashiro/Nvidle/main/install.ps1 -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

It downloads the script to `%LOCALAPPDATA%\Nvidle`, registers an idle-aware auto-update task,
and installs the latest driver once. A UAC prompt appears for admin rights, then re-runs itself elevated.

Working from a local clone instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

### Usage

One-off update without installing anything: double-click `Update-Now.bat`, or run the script:

```powershell
.\Nvidle.ps1              # check, install if a newer driver exists
.\Nvidle.ps1 -Mode Check  # check only, don't install
.\Nvidle.ps1 -Status      # GPU, current version, schedule
```

### Auto-update (idle only)

The scheduled task runs about 3 minutes after logon and installs only when the PC is idle, so it
won't interrupt a game. After finding a new driver it re-checks every 5 minutes (up to 6 hours)
and installs the moment all of these are true:

- no keyboard/mouse input for `IdleMinutes` (default 10)
- no fullscreen game or presentation (via `SHQueryUserNotificationState`)
- the foreground window isn't fullscreen (covers borderless games and fullscreen video)

If you don't go idle during the session, it tries again next time you turn the PC on.

Set the idle window at install time, or change it later:

```powershell
.\install.ps1 -IdleMinutes 15
.\Nvidle.ps1 -EnableAuto -IdleMinutes 15   # reconfigure
.\Nvidle.ps1 -DisableAuto                  # turn off, keep the tool
```

### Uninstall

Removes the scheduled task and everything under `%LOCALAPPDATA%\Nvidle`.
The installed GPU driver is left as is.

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Nvidle\bin\uninstall.ps1"
```

### How it works

1. Reads the installed driver version from WMI and converts it to NVIDIA's format
   (`32.0.15.9649` becomes `596.49`).
2. Maps the GPU name to NVIDIA's product IDs through the lookup endpoint, then queries the
   latest Game Ready driver.
3. If it's newer, downloads the package, extracts **only the driver components** with the built-in
   `tar` (excluding the NVIDIA App, GeForce Experience, and telemetry), and runs the trimmed
   `setup.exe -s -clean -noreboot`.

It relies on NVIDIA's public but undocumented endpoints (`gfwsl.geforce.com`,
`nvidia.com/Download/API`). They can change without notice, which would break lookups.

### Notes

- Game Ready only. NVIDIA's API no longer returns Studio drivers, so they aren't supported.
- Installs the graphics driver, PhysX, and HD Audio. GeForce Experience / the NVIDIA App are not installed.
- The only network connections are to NVIDIA, to check and download drivers.
- A different GPU is detected automatically; override with `-Pfid`/`-Psid` if detection fails.
- Installing GPU drivers carries some risk. This project is not affiliated with NVIDIA.

### License

MIT

---

## 한국어

GeForce Experience나 NVIDIA 앱 없이 PowerShell로 NVIDIA GeForce 드라이버를 업데이트합니다.
GPU를 자동 감지하고, 드라이버만 설치하며, PC가 유휴 상태일 때 자동으로 업데이트할 수 있습니다.

Windows 10/11, PowerShell 5.1+. 의존성 없음.

### 설치

```powershell
$f = "$env:TEMP\nvidle-install.ps1"; irm https://raw.githubusercontent.com/AkaiMashiro/Nvidle/main/install.ps1 -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

스크립트를 `%LOCALAPPDATA%\Nvidle`에 내려받고, 유휴 기반 자동 업데이트 작업을 등록한 뒤
최신 드라이버를 한 번 설치합니다. 관리자 권한(UAC) 창이 한 번 뜨고, 자동으로 권한을 올려 재실행합니다.

저장소를 클론해서 쓰는 경우:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

### 사용

설치 없이 한 번만 업데이트하려면 `Update-Now.bat`을 더블클릭하거나, 스크립트를 실행합니다:

```powershell
.\Nvidle.ps1              # 확인 후 새 버전이면 설치
.\Nvidle.ps1 -Mode Check  # 확인만, 설치 안 함
.\Nvidle.ps1 -Status      # GPU, 현재 버전, 예약 상태
```

### 자동 업데이트 (유휴 상태에서만)

예약 작업은 로그온 약 3분 뒤에 실행되고, 설치는 PC가 유휴일 때만 하므로 게임을 방해하지
않습니다. 새 드라이버를 찾으면 5분 간격으로(최대 6시간) 다시 확인해, 다음 조건이 모두 참이
되는 순간 설치합니다:

- `IdleMinutes`(기본 10분) 동안 키보드/마우스 입력 없음
- 전체화면 게임이나 발표 중이 아님 (`SHQueryUserNotificationState`로 판별)
- 전경 창이 전체화면이 아님 (테두리 없는 게임과 전체화면 영상까지 포함)

이번 세션에 유휴 시점이 없으면, 다음에 PC를 켤 때 다시 시도합니다.

유휴 기준은 설치할 때 정하거나 나중에 바꿀 수 있습니다:

```powershell
.\install.ps1 -IdleMinutes 15
.\Nvidle.ps1 -EnableAuto -IdleMinutes 15   # 재설정
.\Nvidle.ps1 -DisableAuto                  # 끄기(도구는 유지)
```

### 제거

예약 작업과 `%LOCALAPPDATA%\Nvidle` 아래 모든 파일을 삭제합니다.
이미 설치된 그래픽 드라이버는 그대로 둡니다.

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Nvidle\bin\uninstall.ps1"
```

### 동작 방식

1. WMI에서 설치된 드라이버 버전을 읽어 NVIDIA 표기로 변환합니다
   (`32.0.15.9649` → `596.49`).
2. GPU 이름을 조회 엔드포인트로 NVIDIA 제품 ID에 매핑한 뒤, 최신 Game Ready 드라이버를 조회합니다.
3. 더 새 버전이면 패키지를 받아 윈도우 내장 `tar`로 **드라이버 구성요소만 추출**
   (NVIDIA App·GeForce Experience·텔레메트리 제외)한 뒤, 정리된 `setup.exe -s -clean -noreboot`로 설치합니다.

NVIDIA의 공개되어 있지만 비공식인 엔드포인트(`gfwsl.geforce.com`, `nvidia.com/Download/API`)에
의존합니다. 예고 없이 바뀔 수 있고, 그럴 경우 조회가 깨집니다.

### 참고

- Game Ready만 지원합니다. NVIDIA API가 더 이상 Studio 드라이버를 반환하지 않습니다.
- 그래픽 드라이버, PhysX, HD 오디오를 설치합니다. GeForce Experience / NVIDIA 앱은 설치하지 않습니다.
- 네트워크 연결은 드라이버 확인과 다운로드를 위해 NVIDIA로만 이뤄집니다.
- 다른 GPU도 자동 감지됩니다. 감지가 실패하면 `-Pfid`/`-Psid`로 직접 지정하세요.
- 드라이버 설치에는 어느 정도 위험이 따릅니다. 이 프로젝트는 NVIDIA와 무관합니다.

### 라이선스

MIT
