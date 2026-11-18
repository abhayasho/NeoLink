# Installs the tools NeoLink works with, if they are missing: Neovim (the code editor; without it files
# open in the built-in editor), Git (Source Control) and ripgrep (Find in Files). NeoLink-Setup runs this;
# scripts/install.ps1 does the same. Each goes through winget, which may ask for permission.
$ErrorActionPreference = 'Continue'

# The PATH as stored now, so that tools installed since this session started are found.
$machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$user = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = "$env:Path;$machine;$user"

$tools = @(
    @{ Command = 'nvim'; Id = 'Neovim.Neovim'; Name = 'Neovim' },
    @{ Command = 'git'; Id = 'Git.Git'; Name = 'Git' },
    @{ Command = 'rg'; Id = 'BurntSushi.ripgrep.MSVC'; Name = 'ripgrep' }
)
$missing = @($tools | Where-Object { -not (Get-Command $_.Command -ErrorAction SilentlyContinue) })
if ($missing.Count -eq 0) { exit 0 }
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Warning ('winget is not available; install these yourself: ' + (($missing | ForEach-Object { $_.Name }) -join ', '))
    exit 0
}
foreach ($tool in $missing) {
    Write-Host "Installing $($tool.Name)..."
    & $winget.Source install --id $tool.Id --exact --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { Write-Warning "$($tool.Name) was not installed (winget exit code $LASTEXITCODE)." }
}
exit 0
