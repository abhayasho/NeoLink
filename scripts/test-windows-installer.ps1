<#
Exercises the Windows installers end to end on a real Windows machine (CI's Windows runner, or yours):
installs, updates and uninstalls with scripts/install.ps1 through `irm | iex` (from a local archive), then,
if -Setup is given, the same with NeoLink-Setup-x64.exe. It changes the current user's Start menu,
desktop, Explorer menu, PATH and Settings > Apps entries while it runs, and removes them again.

    pwsh scripts/test-windows-installer.ps1 -Archive target\NeoLink-windows-x64.zip [-Setup target\NeoLink-Setup-x64.exe]
#>
param(
    [Parameter(Mandatory)] [string]$Archive,
    [string]$Setup
)
$ErrorActionPreference = 'Stop'
$failures = 0
function Check([bool]$Condition, [string]$What) {
    if ($Condition) { Write-Host "  ok   $What" } else { Write-Host "  FAIL $What" -ForegroundColor Red; $script:failures++ }
}
function UserPath { [string][Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames') }

$Archive = (Resolve-Path $Archive).Path
$installer = Join-Path $PSScriptRoot 'install.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('neolink-installer-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$dir = Join-Path $root 'NeoLink'
$programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'NeoLink.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'NeoLink.lnk'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoLink'
$menu = 'HKCU:\Software\Classes\Directory\shell\NeoLink'
$pathBefore = UserPath

Write-Host 'install.ps1 through irm | iex'
$env:NEOLINK_ARCHIVE = $Archive
$env:NEOLINK_INSTALL_DIR = $dir
$env:NEOLINK_NO_TOOLS = '1'
try {
    # Exactly what the README's one-liner does, with the script read from disk instead of GitHub.
    Get-Content -Raw -LiteralPath $installer | Invoke-Expression
    Check (Test-Path "$dir\NeoLink.exe") 'NeoLink.exe installed'
    Check (Test-Path "$dir\Resources\Editor\neolink.lua") 'editor runtime beside it'
    Check (Test-Path $programs) 'Start menu entry'
    Check (Test-Path $desktop) 'desktop icon'
    Check ((New-Object -ComObject WScript.Shell).CreateShortcut($desktop).TargetPath -ieq "$dir\NeoLink.exe") 'desktop icon opens the installed app'
    Check ((Get-Item "$menu\command").GetValue('') -like "*$dir\NeoLink.exe*") '"Open in NeoLink" on folders'
    Check ((UserPath) -split ';' -contains "$dir\bin") 'bin folder on the user PATH'
    Check ((Get-Content "$dir\bin\neolink.cmd" -Raw) -match 'NeoLink\.exe') 'neolink command'
    Check ((Get-ItemProperty $key).DisplayName -eq 'NeoLink') 'listed in Settings > Apps'
    Check (Test-Path "$dir\uninstall.ps1") 'uninstaller'

    # A real launch of the installed app: it opens a window and quits after writing a capture.
    $capture = Join-Path $root 'capture.png'
    $env:NEOLINK_CAPTURE = $capture; $env:NEOLINK_CAPTURE_AFTER = '3'
    $process = Start-Process -FilePath "$dir\NeoLink.exe" -PassThru
    if (-not $process.WaitForExit(60000)) { $process.Kill() }
    Remove-Item Env:NEOLINK_CAPTURE, Env:NEOLINK_CAPTURE_AFTER
    Check (Test-Path $capture) 'the installed app opens a window and draws'

    Write-Host 'running it again updates in place'
    Set-Content -LiteralPath "$dir\stale.txt" -Value 'left over'
    Get-Content -Raw -LiteralPath $installer | Invoke-Expression
    Check (Test-Path "$dir\NeoLink.exe") 'still installed'
    Check (-not (Test-Path "$dir\stale.txt")) 'old files replaced'
    Check (@((UserPath) -split ';' | Where-Object { $_ -ieq "$dir\bin" }).Count -eq 1) 'PATH entry not duplicated'
    Check (@(Get-ChildItem $root -Filter 'NeoLink.previous-*').Count -eq 0) 'no backup left behind'

    Write-Host 'uninstall from Settings > Apps (quietly)'
    $quiet = (Get-ItemProperty $key).QuietUninstallString
    Start-Process -FilePath cmd.exe -ArgumentList '/c', $quiet -Wait -WindowStyle Hidden
    Start-Sleep -Seconds 4  # the folder goes once the uninstaller has exited
    Check (-not (Test-Path $dir)) 'install folder removed'
    Check (-not (Test-Path $programs)) 'Start menu entry removed'
    Check (-not (Test-Path $desktop)) 'desktop icon removed'
    Check (-not (Test-Path $menu)) 'folder menu entry removed'
    Check (-not (Test-Path $key)) 'Settings > Apps entry removed'
    Check (-not ((UserPath) -split ';' -contains "$dir\bin")) 'PATH entry removed'
} finally {
    Remove-Item Env:NEOLINK_ARCHIVE, Env:NEOLINK_INSTALL_DIR, Env:NEOLINK_NO_TOOLS -ErrorAction SilentlyContinue
}

if ($Setup) {
    Write-Host 'NeoLink-Setup-x64.exe (silent)'
    $setupDir = Join-Path $root 'Setup'
    $log = Join-Path $root 'setup.log'
    Start-Process -FilePath (Resolve-Path $Setup).Path -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/DIR=`"$setupDir`"", '/TASKS=desktopicon,contextmenu,path', "/LOG=`"$log`"" -Wait
    Check (Test-Path "$setupDir\NeoLink.exe") 'NeoLink.exe installed'
    Check (Test-Path "$setupDir\Resources\Editor\neolink.lua") 'editor runtime beside it'
    Check (Test-Path "$setupDir\bin\neolink.cmd") 'neolink command'
    Check (Test-Path $programs) 'Start menu entry'
    Check (Test-Path $desktop) 'desktop icon'
    Check ((Get-Item "$menu\command").GetValue('') -like "*$setupDir\NeoLink.exe*") '"Open in NeoLink" on folders'
    Check ((UserPath) -split ';' -contains "$setupDir\bin") 'bin folder on the user PATH'
    Start-Process -FilePath "$setupDir\unins000.exe" -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
    Start-Sleep -Seconds 3
    Check (-not (Test-Path "$setupDir\NeoLink.exe")) 'uninstalled'
    Check (-not (Test-Path $programs)) 'Start menu entry removed'
    Check (-not (Test-Path $menu)) 'folder menu entry removed'
    Check (-not ((UserPath) -split ';' -contains "$setupDir\bin")) 'PATH entry removed'
}

Check ((UserPath) -eq $pathBefore) 'the user PATH is as it was'
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All installer checks passed.' -ForegroundColor Green
