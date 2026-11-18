<#
.SYNOPSIS
Installs or updates NeoLink for Windows for the current user. No administrator rights needed.

.DESCRIPTION
    irm https://raw.githubusercontent.com/abhayasho/NeoLink/main/scripts/install.ps1 | iex

Downloads the latest release (checking its SHA-256 when the release publishes one), installs it in
%LOCALAPPDATA%\Programs\NeoLink, and adds a Start menu entry, a desktop icon, "Open in NeoLink" on
folders in File Explorer, a `neolink` command for terminals, and an entry in Settings > Apps to
uninstall it. Neovim, Git and ripgrep are installed with winget if they are missing.

Run it again to update; settings (%APPDATA%\NeoLink) are kept. Options, as parameters when the script
is run from a file, or as environment variables before `irm | iex`:
    -Version v2.2.0       NEOLINK_VERSION        a release tag instead of the latest release
    -InstallDir <folder>  NEOLINK_INSTALL_DIR    where to install
    -Archive <zip>        NEOLINK_ARCHIVE        install this NeoLink-windows-x64.zip instead of downloading
    -NoTools              NEOLINK_NO_TOOLS=1     do not install Neovim, Git or ripgrep
    -NoDesktopIcon        NEOLINK_NO_DESKTOP=1   no desktop icon
    -Launch               NEOLINK_LAUNCH=1       open NeoLink when done
    -Uninstall                                   remove NeoLink (settings are kept)
#>
[CmdletBinding()]
param(
    [string]$Version = $env:NEOLINK_VERSION,
    [string]$InstallDir = $env:NEOLINK_INSTALL_DIR,
    [string]$Archive = $env:NEOLINK_ARCHIVE,
    [switch]$NoTools = ($env:NEOLINK_NO_TOOLS -eq '1'),
    [switch]$NoDesktopIcon = ($env:NEOLINK_NO_DESKTOP -eq '1'),
    [switch]$Launch = ($env:NEOLINK_LAUNCH -eq '1'),
    [switch]$Uninstall
)

# Everything is inside functions so that `irm | iex` parses the whole script before doing anything, and
# so that a failure stops the installer without closing the terminal it was pasted into.
function Install-NeoLink {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'  # Windows PowerShell's progress bar slows downloads tenfold.
    $repository = 'abhayasho/NeoLink'
    $asset = 'NeoLink-windows-x64.zip'
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoLink'
    $setupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F1D2A8B-3C47-4E5A-9B1E-7A0C2D5E8F31}_is1'

    if (-not [Environment]::Is64BitOperatingSystem) { throw 'NeoLink needs 64-bit Windows.' }
    if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'NeoLink needs Windows 10 or later.' }
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\NeoLink' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)

    if ($Uninstall) {
        Remove-NeoLink -InstallDir $InstallDir -UninstallKey $uninstallKey
        return
    }
    Assert-NotRunning $InstallDir

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('neolink-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        if ($Archive) {
            $zip = (Resolve-Path $Archive).Path
            Write-Host "Installing NeoLink from $zip"
        } else {
            # Windows PowerShell 5.1 may still default to TLS 1.0, which GitHub refuses.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $base = if ($Version) { "https://github.com/$repository/releases/download/$Version" } else { "https://github.com/$repository/releases/latest/download" }
            $zip = Join-Path $temporary $asset
            Write-Host "Downloading NeoLink$(if ($Version) { " $Version" })..."
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $zip
            $expected = $null
            try {
                $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset.sha256").Content
                if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
                $line = ($sums -split "`n") | Where-Object { $_ -match '^\s*([0-9a-fA-F]{64})\s+\*?(\S+)\s*$' -and $Matches[2] -eq $asset } | Select-Object -First 1
                if (-not $line) { throw 'The release checksum file does not list the download.' }
                $null = $line -match '^\s*([0-9a-fA-F]{64})'
                $expected = $Matches[1].ToLowerInvariant()
            } catch {
                # Only a release without a checksum file (404) goes on unverified. (Windows PowerShell and
                # PowerShell 7 throw different exception types; both carry the response.)
                $status = 0
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                if ($status -ne 404) { throw }
            }
            if ($expected) {
                $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
                if ($actual -ne $expected) { throw 'The download does not match the release checksum; nothing was changed.' }
                Write-Host 'Checksum verified.'
            } else {
                Write-Warning 'This release publishes no checksum; the download could not be verified.'
            }
        }

        $unpacked = Join-Path $temporary 'unpacked'
        Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
        $package = Join-Path $unpacked 'NeoLink'
        foreach ($required in 'NeoLink.exe', 'Resources\Editor\neolink.lua') {
            if (-not (Test-Path -LiteralPath (Join-Path $package $required) -PathType Leaf)) { throw "The download is missing $required." }
        }
        $bytes = [IO.File]::ReadAllBytes((Join-Path $package 'NeoLink.exe'))
        if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'The download does not contain a Windows program.' }

        # A copy installed by NeoLink-Setup goes first, so that Settings > Apps lists NeoLink once.
        if (Test-Path $setupKey) {
            $setupUninstaller = Join-Path $InstallDir 'unins000.exe'
            if (Test-Path -LiteralPath $setupUninstaller) {
                Write-Host 'Replacing the copy installed by NeoLink-Setup...'
                Start-Process -FilePath $setupUninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
            }
        }

        # The downloaded files replace the installed ones in one move; the old copy comes back if that fails.
        Assert-NotRunning $InstallDir
        $parent = Split-Path -Parent $InstallDir
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $backup = $null
        if (Test-Path -LiteralPath $InstallDir) {
            if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'NeoLink.exe')) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
                throw "$InstallDir exists and is not a NeoLink installation; choose another folder with -InstallDir."
            }
            $backup = "$InstallDir.previous-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            Move-Item -LiteralPath $InstallDir -Destination $backup
        }
        try {
            Move-Item -LiteralPath $package -Destination $InstallDir
        } catch {
            if ($backup) { Move-Item -LiteralPath $backup -Destination $InstallDir }
            throw
        }
        if ($backup) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }

        $exe = Join-Path $InstallDir 'NeoLink.exe'
        Register-NeoLink -InstallDir $InstallDir -Exe $exe -UninstallKey $uninstallKey -DesktopIcon:(-not $NoDesktopIcon)
        $installed = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        Write-Host ''
        Write-Host "NeoLink $installed is installed in $InstallDir" -ForegroundColor Green
        Write-Host 'Open it from the Start menu or the desktop, right-click a folder and choose "Open in NeoLink",'
        Write-Host 'or type `neolink .` in a new terminal. Run this command again to update.'

        if (-not $NoTools) { Install-NeoLinkTools }
        if ($Launch) { Start-Process -FilePath $exe }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-NotRunning([string]$InstallDir) {
    $running = Get-Process -Name NeoLink -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) }
    if ($running) { throw 'Quit NeoLink first, then run this again. Your settings and open folders are kept.' }
}

# Start menu, desktop, Explorer's folder menu, the `neolink` command and Settings > Apps.
function Register-NeoLink([string]$InstallDir, [string]$Exe, [string]$UninstallKey, [switch]$DesktopIcon) {
    $shell = New-Object -ComObject WScript.Shell
    $places = @([Environment]::GetFolderPath('Programs'))
    if ($DesktopIcon) { $places += [Environment]::GetFolderPath('DesktopDirectory') }
    foreach ($place in $places) {
        $link = $shell.CreateShortcut((Join-Path $place 'NeoLink.lnk'))
        $link.TargetPath = $Exe
        $link.WorkingDirectory = $InstallDir
        $link.IconLocation = "$Exe,0"
        $link.Description = 'NeoLink: terminals, editor, explorer and agents'
        $link.Save()
    }

    # "Open in NeoLink" on a folder and on a folder's background.
    foreach ($target in @(@('Directory', '%1'), @('Directory\Background', '%V'), @('Drive', '%1'))) {
        $key = "HKCU:\Software\Classes\$($target[0])\shell\NeoLink"
        New-Item -Path "$key\command" -Force | Out-Null
        Set-Item -Path $key -Value 'Open in NeoLink'
        New-ItemProperty -Path $key -Name Icon -Value "`"$Exe`",0" -Force | Out-Null
        Set-Item -Path "$key\command" -Value "`"$Exe`" `"$($target[1])`""
    }

    # `neolink [folder] [files]` from any terminal: a small launcher in its own folder on the user PATH.
    $bin = Join-Path $InstallDir 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'neolink.cmd') -Encoding Ascii -Value "@echo off`r`nstart `"`" `"%~dp0..\NeoLink.exe`" %*"
    Add-UserPath $bin

    $uninstaller = Join-Path $InstallDir 'uninstall.ps1'
    Set-Content -LiteralPath $uninstaller -Encoding UTF8 -Value $script:UninstallScript
    $version = (Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion
    $size = [int]((Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB)
    New-Item -Path $UninstallKey -Force | Out-Null
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstaller`""
    $values = @{
        DisplayName = 'NeoLink'; DisplayVersion = "$version"; Publisher = 'NeoLink'; DisplayIcon = "`"$Exe`",0"
        InstallLocation = $InstallDir; UninstallString = $command; QuietUninstallString = "$command -Quiet"
        URLInfoAbout = 'https://github.com/abhayasho/NeoLink'; HelpLink = 'https://github.com/abhayasho/NeoLink/issues'
    }
    foreach ($name in $values.Keys) { New-ItemProperty -Path $UninstallKey -Name $name -Value $values[$name] -Force | Out-Null }
    foreach ($name in 'NoModify', 'NoRepair') { New-ItemProperty -Path $UninstallKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $UninstallKey -Name EstimatedSize -Value $size -PropertyType DWord -Force | Out-Null
}

# Adds a folder to the user's PATH without flattening entries like %USERPROFILE%\bin (the value stays
# REG_EXPAND_SZ), then tells running programs, so new terminals see it.
function Add-UserPath([string]$Folder) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (@($current -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Folder.TrimEnd('\') }).Count) { return }
        # Appended as the last entry, before a trailing separator if there is one, so that removing it
        # gives back exactly the value that was there.
        $value = if (-not $current) { $Folder } elseif ($current.EndsWith(';')) { "$current$Folder;" } else { "$current;$Folder" }
        $key.SetValue('Path', $value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
    Send-EnvironmentChange
    if (-not (($env:Path -split ';') -contains $Folder)) { $env:Path = "$env:Path;$Folder" }
}

function Send-EnvironmentChange {
    # Setting a user variable through .NET broadcasts WM_SETTINGCHANGE; this one is set and removed.
    [Environment]::SetEnvironmentVariable('NEOLINK_INSTALLER', '1', 'User')
    [Environment]::SetEnvironmentVariable('NEOLINK_INSTALLER', $null, 'User')
}

# Neovim (the code editor; without it files open in the built-in editor), Git (Source Control) and
# ripgrep (Find in Files), from winget. Each is skipped if it is already on the PATH.
function Install-NeoLinkTools {
    $tools = @(
        @{ Command = 'nvim'; Id = 'Neovim.Neovim'; Name = 'Neovim' },
        @{ Command = 'git'; Id = 'Git.Git'; Name = 'Git' },
        @{ Command = 'rg'; Id = 'BurntSushi.ripgrep.MSVC'; Name = 'ripgrep' }
    )
    $missing = @($tools | Where-Object { -not (Get-Command $_.Command -ErrorAction SilentlyContinue) })
    if ($missing.Count -eq 0) { return }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warning ("Install these for the full experience: " + (($missing | ForEach-Object { $_.Name }) -join ', ') + ' (winget is not available here).')
        return
    }
    foreach ($tool in $missing) {
        Write-Host "Installing $($tool.Name)... (Windows may ask for permission)"
        & $winget.Source install --id $tool.Id --exact --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning "$($tool.Name) was not installed (winget exit code $LASTEXITCODE). NeoLink works without it; install it later with: winget install $($tool.Id)" }
    }
}

function Remove-NeoLink([string]$InstallDir, [string]$UninstallKey) {
    Assert-NotRunning $InstallDir
    foreach ($place in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('DesktopDirectory')) {
        $link = Join-Path $place 'NeoLink.lnk'
        if (Test-Path -LiteralPath $link) {
            $target = (New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath
            if ($target -and $target.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $link -Force }
        }
    }
    foreach ($target in 'Directory', 'Directory\Background', 'Drive') {
        Remove-Item -Path "HKCU:\Software\Classes\$target\shell\NeoLink" -Recurse -Force -ErrorAction SilentlyContinue
    }
    $bin = Join-Path $InstallDir 'bin'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($current -split ';')
        $kept = @($entries | Where-Object { -not $_ -or $_.TrimEnd('\') -ine $bin.TrimEnd('\') })
        if ($kept.Count -ne $entries.Count) {
            $key.SetValue('Path', ($kept -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        }
    } finally { $key.Close() }
    Send-EnvironmentChange
    Remove-Item -Path $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'NeoLink.exe')) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    Write-Host "NeoLink was removed. Your settings are still in $env:APPDATA\NeoLink." -ForegroundColor Green
}

# Settings > Apps runs this; it removes what the installer added (not the settings, nor Neovim, Git or
# ripgrep, which other programs may use).
$script:UninstallScript = @'
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (Get-Process -Name NeoLink -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) }) {
    if (-not $Quiet) { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show('Quit NeoLink first, then uninstall it again.', 'NeoLink') }
    exit 1
}
$shell = New-Object -ComObject WScript.Shell
foreach ($place in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('DesktopDirectory')) {
    $link = Join-Path $place 'NeoLink.lnk'
    if ((Test-Path -LiteralPath $link) -and $shell.CreateShortcut($link).TargetPath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $link -Force }
}
foreach ($target in 'Directory', 'Directory\Background', 'Drive') {
    Remove-Item -Path "HKCU:\Software\Classes\$target\shell\NeoLink" -Recurse -Force -ErrorAction SilentlyContinue
}
$bin = Join-Path $dir 'bin'
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$entries = @($current -split ';')
$kept = @($entries | Where-Object { -not $_ -or $_.TrimEnd('\') -ine $bin.TrimEnd('\') })
if ($kept.Count -ne $entries.Count) { $key.SetValue('Path', ($kept -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
$key.Close()
[Environment]::SetEnvironmentVariable('NEOLINK_INSTALLER', '1', 'User')
[Environment]::SetEnvironmentVariable('NEOLINK_INSTALLER', $null, 'User')
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoLink' -Recurse -Force -ErrorAction SilentlyContinue
# The folder holding this script is removed once PowerShell has let go of it.
Start-Process -WindowStyle Hidden -FilePath cmd.exe -ArgumentList '/c', "timeout /t 2 /nobreak >nul & rmdir /s /q `"$dir`""
if (-not $Quiet) { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show("NeoLink was removed. Your settings are still in $env:APPDATA\NeoLink.", 'NeoLink') }
'@

Install-NeoLink
