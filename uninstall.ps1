#Requires -Version 5.1
<#
.SYNOPSIS
    Removes codex-switch from this machine.

.DESCRIPTION
    Unwires the profile block and deletes the installed scripts.
    Your saved accounts in ~\.codex\profiles are KEPT by default - they hold
    live ChatGPT tokens and cannot be regenerated without logging in again.

.PARAMETER PurgeProfiles
    Also delete ~\.codex\profiles. This logs every account out. There is no undo.

.EXAMPLE
    pwsh -File .\uninstall.ps1
.EXAMPLE
    pwsh -File .\uninstall.ps1 -PurgeProfiles
#>

param(
    [switch]$PurgeProfiles
)

$ErrorActionPreference = 'Stop'

$dest = Join-Path $HOME '.codex'

Write-Host "Removing codex-switch" -ForegroundColor Cyan

# --- unwire profile blocks -------------------------------------------------
$targets = @(
    (Join-Path $HOME 'Documents\WindowsPowerShell\profile.ps1'),
    (Join-Path $HOME 'Documents\PowerShell\profile.ps1')
)

foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target)) { continue }
    $text = Get-Content -LiteralPath $target -Raw
    if ($null -eq $text) { continue }

    $pattern = '(?s)\s*# >>> codex-switch >>>.*?# <<< codex-switch <<<\s*'
    if ($text -notmatch $pattern) { continue }

    $new = [regex]::Replace($text, $pattern, "`r`n")
    Set-Content -LiteralPath $target -Value $new.TrimEnd() + "`r`n" -Encoding UTF8 -NoNewline
    Write-Host "  profile unwired          $target" -ForegroundColor Green
}

# --- remove scripts --------------------------------------------------------
foreach ($f in @('cx.ps1', 'setup-codex-profiles.ps1')) {
    $p = Join-Path $dest $f
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force
        Write-Host "  removed                  $p" -ForegroundColor Green
    }
}

# --- profiles --------------------------------------------------------------
$profilesRoot = Join-Path $dest 'profiles'
if ($PurgeProfiles) {
    if (Test-Path -LiteralPath $profilesRoot) {
        Remove-Item -LiteralPath $profilesRoot -Recurse -Force
        Write-Host "  PURGED accounts          $profilesRoot" -ForegroundColor Yellow
    }
}
elseif (Test-Path -LiteralPath $profilesRoot) {
    Write-Host "  kept your accounts       $profilesRoot" -ForegroundColor DarkGray
    Write-Host "  (delete it manually, or re-run with -PurgeProfiles)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Done. Open a new shell - 'cx' is gone." -ForegroundColor Cyan
