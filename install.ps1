#Requires -Version 5.1
<#
.SYNOPSIS
    Installs codex-switch: copies the scripts into %USERPROFILE%\.codex and
    wires them into your PowerShell profile.

.DESCRIPTION
    Safe to re-run. Existing copies are replaced, and the profile block is
    rewritten in place rather than appended twice.

.PARAMETER Link
    Hardlink the scripts from this repo into ~\.codex instead of copying them.
    Edits in the repo then take effect immediately, with no re-install.
    Falls back to copying if the link cannot be created (different volume).

.PARAMETER NoProfile
    Skip profile wiring. Use this if you dot-source cx.ps1 yourself.

.EXAMPLE
    pwsh -File .\install.ps1
.EXAMPLE
    pwsh -File .\install.ps1 -Link
#>

param(
    [switch]$Link,
    [switch]$NoProfile
)

$ErrorActionPreference = 'Stop'

$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $HOME '.codex'
$files = @('cx.ps1', 'setup-codex-profiles.ps1')

New-Item -ItemType Directory -Force -Path $dest | Out-Null

Write-Host "Installing codex-switch" -ForegroundColor Cyan
Write-Host "  from: $src" -ForegroundColor DarkGray
Write-Host "  to:   $dest" -ForegroundColor DarkGray
Write-Host ""

foreach ($f in $files) {
    $s = Join-Path $src $f
    $d = Join-Path $dest $f
    if (-not (Test-Path -LiteralPath $s)) { throw "Missing $s - run install.ps1 from the repo root." }
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Force }

    $mode = 'copy'
    if ($Link) {
        # Hardlink works on Windows and on same-volume Unix paths; symlink is the
        # Unix fallback when the repo lives on another filesystem.
        try {
            New-Item -ItemType HardLink -Path $d -Target $s -Force | Out-Null
            $mode = 'hardlink'
        }
        catch {
            try {
                New-Item -ItemType SymbolicLink -Path $d -Target $s -Force | Out-Null
                $mode = 'symlink'
            }
            catch {
                Copy-Item $s $d -Force
                $mode = 'copy (link unavailable)'
            }
        }
    }
    else {
        Copy-Item $s $d -Force
    }
    Write-Host ("  {0,-28} {1}" -f $f, $mode) -ForegroundColor Green
}

if (-not $NoProfile) {
    $block = @(
        '# >>> codex-switch >>>'
        'if (Test-Path -LiteralPath "$HOME/.codex/cx.ps1") { . "$HOME/.codex/cx.ps1" }'
        '# <<< codex-switch <<<'
    ) -join "`r`n"

    # Profile locations differ per platform: Windows has separate 5.1 and 7+ trees,
    # while macOS/Linux have a single AllHosts profile for pwsh.
    $isWindowsHost = ($env:OS -eq 'Windows_NT')
    $targets = if ($isWindowsHost) {
        @(
            (Join-Path $HOME 'Documents\WindowsPowerShell\profile.ps1'),  # Windows PowerShell 5.1
            (Join-Path $HOME 'Documents\PowerShell\profile.ps1')          # PowerShell 7+
        )
    }
    else {
        @($PROFILE.CurrentUserAllHosts)
    }

    foreach ($target in $targets) {
        $dir = Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        $text = ''
        if (Test-Path -LiteralPath $target) {
            $text = Get-Content -LiteralPath $target -Raw
            if ($null -eq $text) { $text = '' }
        }

        $pattern = '(?s)# >>> codex-switch >>>.*?# <<< codex-switch <<<'
        if ($text -match $pattern) {
            $new = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block })
        }
        else {
            $new = if ($text.TrimEnd()) { $text.TrimEnd() + "`r`n`r`n" + $block + "`r`n" } else { $block + "`r`n" }
        }

        Set-Content -LiteralPath $target -Value $new -Encoding UTF8 -NoNewline
        Write-Host ("  profile wired            {0}" -f $target) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Done. Open a NEW PowerShell window, then run:" -ForegroundColor Cyan
Write-Host "  cx" -ForegroundColor White
Write-Host ""
Write-Host "Add your first extra account with: cx new" -ForegroundColor DarkGray
