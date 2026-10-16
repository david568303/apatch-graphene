$ErrorActionPreference = 'Stop'
$AvbRootVersion = '3.35.0' # renovate: datasource=github-releases packageName=chenxiaolong/avbroot versioning=semver
$MinFastboot = [version]'35.0.1'
$ChenxiaolongPk = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4'
$AvbPkmd = 'avb_pkmd.bin'

function Fail($msg) {
  Write-Host "==> $msg" -ForegroundColor Red
  Read-Host 'Press Enter to exit'
  exit 1
}
function Info($msg)  { Write-Host "==> $msg" }
function Ok($msg)    { Write-Host "==> $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "==> $msg" -ForegroundColor Yellow }

function Confirm($question) {
  $r = Read-Host "$question [y/N]"
  return $r -match '^[Yy]$'
}

function Invoke-ProcessWithStdinFile($Exe, [string[]]$ExeArgs, [string]$StdinPath) {
  # Start-Process -RedirectStandardInput goes through a text-encoding layer
  # that corrupts binary input (confirmed: it roughly doubled a binary
  # file's byte count in testing). Go straight to System.Diagnostics.Process
  # and copy the file's raw bytes into the child's stdin stream instead.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  foreach ($a in $ExeArgs) { [void]$psi.ArgumentList.Add($a) }
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $proc = [System.Diagnostics.Process]::Start($psi)
  $inStream = [System.IO.File]::OpenRead($StdinPath)
  $inStream.CopyTo($proc.StandardInput.BaseStream)
  $proc.StandardInput.Close()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $inStream.Close()
  return [PSCustomObject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Run($exe, $cmdArgs) {
  & $exe @cmdArgs
  if ($LASTEXITCODE -ne 0) { Fail "Command failed (exit $LASTEXITCODE): $exe $($cmdArgs -join ' ')" }
}

# 1. fastboot
$fastboot = Get-Command fastboot -ErrorAction SilentlyContinue
if (-not $fastboot) {
  Fail "fastboot was not found on PATH. Install Android platform-tools (>= 35.0.1) from https://developer.android.com/tools/releases/platform-tools, add it to PATH, then re-run this script."
}
$verLine = ((& fastboot --version) -join "`n")
$m = [regex]::Match($verLine, '(\d+)\.(\d+)\.(\d+)')
if (-not $m.Success) {
  Warn "Could not determine your fastboot version from: $verLine"
  if (-not (Confirm 'Continue anyway?')) { exit 1 }
} else {
  $fbVer = [version]"$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
  if ($fbVer -lt $MinFastboot) {
    Fail "fastboot $fbVer is too old (need >= $MinFastboot): earlier versions fail to flash dynamic partitions correctly. Install a recent one from https://developer.android.com/tools/releases/platform-tools, then re-run this script."
  }
  Ok "fastboot $fbVer"
}

# 2. OTA selection
$otas = @(Get-ChildItem -Filter *.zip -File | Select-Object -ExpandProperty Name)
if ($otas.Count -eq 0) {
  Fail "No OTA zip found in $(Get-Location). Download one from https://github.com/david568303/rooted-graphene/releases and place it next to this script."
} elseif ($otas.Count -eq 1) {
  $otaFile = $otas[0]
  Info "Found one OTA: $otaFile"
} else {
  if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    # No real console (piped/redirected input, or run from a non-interactive
    # host): fall back to a plain numbered prompt instead of the arrow menu.
    Info "Found multiple OTAs:"
    for ($i = 0; $i -lt $otas.Count; $i++) { Write-Host ("{0,2}) {1}" -f ($i + 1), $otas[$i]) }
    while ($true) {
      $choice = Read-Host "Select a number [1-$($otas.Count)]"
      if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $otas.Count) {
        $otaFile = $otas[[int]$choice - 1]
        break
      }
      Write-Host 'Invalid selection.'
    }
  } else {
    Info "Found multiple OTAs. Use Up/Down and Enter to pick one:"
    $idx = 0
    $top = [Console]::CursorTop
    function Draw {
      [Console]::SetCursorPosition(0, $top)
      for ($i = 0; $i -lt $otas.Count; $i++) {
        if ($i -eq $idx) { Write-Host ('> ' + $otas[$i]) -ForegroundColor Black -BackgroundColor White }
        else { Write-Host ('  ' + $otas[$i]) }
      }
    }
    Draw
    while ($true) {
      $k = [Console]::ReadKey($true)
      if ($k.Key -eq 'UpArrow') { $idx = ($idx - 1 + $otas.Count) % $otas.Count; Draw }
      elseif ($k.Key -eq 'DownArrow') { $idx = ($idx + 1) % $otas.Count; Draw }
      elseif ($k.Key -eq 'Enter') { break }
    }
    $otaFile = $otas[$idx]
  }
}

# 3. avbroot
$avbroot = $null
if (Test-Path .\avbroot.exe) { $avbroot = (Resolve-Path .\avbroot.exe).Path }
elseif (Get-Command avbroot -ErrorAction SilentlyContinue) { $avbroot = 'avbroot' }
else {
  Warn "avbroot was not found on PATH or in $(Get-Location)."
  if (-not (Confirm "Download avbroot v$AvbRootVersion now?")) { Fail 'avbroot missing' }

  $target = 'x86_64-pc-windows-msvc'
  $base = "avbroot-$AvbRootVersion-$target"
  $url = "https://github.com/chenxiaolong/avbroot/releases/download/v$AvbRootVersion/$base.zip"
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  Info "Downloading $url"
  try {
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp 'avbroot.zip') -UseBasicParsing
    Invoke-WebRequest -Uri "$url.sig" -OutFile (Join-Path $tmp 'avbroot.zip.sig') -UseBasicParsing
  } catch {
    Remove-Item -Recurse -Force $tmp
    Fail "Could not download avbroot for Windows/x86_64 (v$AvbRootVersion may not publish this platform). Download it manually from https://github.com/chenxiaolong/avbroot/releases and place avbroot.exe next to this script."
  }

  $sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
  if ($sshKeygen) {
    $allowed = Join-Path $tmp 'allowed_signers'
    "chenxiaolong $ChenxiaolongPk" | Set-Content -Path $allowed -Encoding ascii
    $verify = Invoke-ProcessWithStdinFile -Exe 'ssh-keygen' -ExeArgs @('-Y','verify','-I','chenxiaolong','-f',$allowed,'-n','file','-s',(Join-Path $tmp 'avbroot.zip.sig')) -StdinPath (Join-Path $tmp 'avbroot.zip')
    if ($verify.ExitCode -ne 0) {
      Remove-Item -Recurse -Force $tmp
      Fail "avbroot download failed signature verification. Not using it. Download it yourself from https://github.com/chenxiaolong/avbroot/releases."
    }
    Ok "avbroot download verified against chenxiaolong's signing key."
  } else {
    Warn "ssh-keygen was not found: could not verify the avbroot download's signature."
    if (-not (Confirm 'Continue anyway, using an UNVERIFIED avbroot binary?')) { Remove-Item -Recurse -Force $tmp; exit 1 }
  }

  Expand-Archive -Path (Join-Path $tmp 'avbroot.zip') -DestinationPath $tmp -Force
  Copy-Item (Join-Path $tmp 'avbroot.exe') .\avbroot.exe -Force
  Remove-Item -Recurse -Force $tmp
  $avbroot = (Resolve-Path .\avbroot.exe).Path
  Ok "Downloaded avbroot v$AvbRootVersion"
}
"$avbroot --version" | Out-Null
try { & $avbroot --version | Out-Null } catch { Fail "Found $avbroot but it did not run. Is it the right binary for this machine?" }
Ok "Using avbroot: $avbroot"

# 4. Flashing
Info "Extracting $otaFile for fastboot"
Remove-Item -Recurse -Force .\extracted, .\extra -ErrorAction SilentlyContinue
Run $avbroot @('ota', 'extract', '--input', $otaFile, '--directory', 'extracted', '--fastboot')
Run $avbroot @('ota', 'extract', '--input', $otaFile, '--directory', 'extra', '-p', 'product', '-p', 'vendor', '-p', 'system_ext', '-p', 'system_dlkm', '-p', 'vendor_dlkm')

$env:ANDROID_PRODUCT_OUT = (Resolve-Path .\extracted).Path

Info "Flashing core partitions (this enters fastbootd automatically)"
Run fastboot @('flashall', '--skip-reboot')

Info "Flashing the remaining dynamic partitions in fastbootd"
foreach ($p in 'product', 'vendor', 'system_ext', 'system_dlkm', 'vendor_dlkm') {
  $img = ".\extra\$p.img"
  if (Test-Path $img) { Run fastboot @('flash', $p, $img) }
}

if (Test-Path $AvbPkmd) {
  Info "Registering this repo's AVB key"
  Run fastboot @('reboot-bootloader')
  Run fastboot @('erase', 'avb_custom_key')
  Run fastboot @('flash', 'avb_custom_key', $AvbPkmd)
} else {
  Warn "$AvbPkmd not found next to this script; the custom AVB key was NOT (re)registered."
  Warn 'If this is a first install, the device will fail to boot once locked without it.'
}

Ok 'Flashing complete. The device is in the bootloader.'

# 5. Boot confirmation + lock flow
Write-Host ''
Info 'The device is sitting in the bootloader now.'
Info "Boot it into GrapheneOS: either run 'fastboot reboot' or use the volume/power buttons to select Start."
Read-Host 'Press Enter once you have booted the device and GrapheneOS has had a chance to start'

if (-not (Confirm 'Does GrapheneOS boot?')) {
  Warn 'Do NOT lock the bootloader on a device that does not boot.'
  Warn "Capture the kernel log of the failed boot with: adb shell su -c 'cat /sys/fs/pstore/console-ramoops-0' (after booting any working image), and open an issue."
  exit 0
}
Ok 'Good, GrapheneOS boots.'

if (-not (Confirm 'Do you want to lock the bootloader now? This wipes all data on the device and cannot be undone without unlocking (another wipe).')) {
  Info 'Leaving the bootloader unlocked.'
  exit 0
}

Warn 'Last check: locking is destructive and should only be done once you are sure the device is working well.'
$confirmation = Read-Host "Type 'lock' to confirm, or anything else to cancel"
if ($confirmation -ne 'lock') {
  Info 'Not locking the bootloader.'
  exit 0
}

Info 'Rebooting to the bootloader to lock it'
Run fastboot @('reboot', 'bootloader')
Run fastboot @('flashing', 'lock')
Ok 'Bootloader lock command sent. Confirm on the device screen if prompted (volume down, then power).'
