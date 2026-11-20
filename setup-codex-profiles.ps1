# codex-switch — guided multi-account login for the Codex CLI.
#
# Each account gets its own isolated CODEX_HOME folder under ~\.codex\profiles,
# so one ChatGPT login never overwrites another.
#
#   pwsh -File setup-codex-profiles.ps1                     # claim current login + status
#   pwsh -File setup-codex-profiles.ps1 -VerifyOnly         # status table only
#   pwsh -File setup-codex-profiles.ps1 -Accounts acc2,acc3 # log in these slots
#
# Re-runnable: accounts that are already logged in are skipped.
#
# NOTE: with `pwsh -File`, `-Accounts acc2,acc3` arrives as the SINGLE string
# "acc2,acc3" (the comma is not an array separator in -File argument mode).
# The normalization below splits on commas, so one flag = N profiles.

param(
    [string[]]$Accounts = @(),
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$codexHome = Join-Path $HOME '.codex'
$root      = Join-Path $codexHome 'profiles'

# Normalize -Accounts: accept `-Accounts acc2,acc3` (one string via pwsh -File),
# space-separated lists, or a real array. Trim, drop empties, dedupe.
$Accounts = @(
    $Accounts |
        ForEach-Object { "$_" -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique
)

# Guard: profile names become folder names. Reject anything path-ish, so a typo
# can never create a nested folder or escape the profiles directory.
$bad = @($Accounts | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' })
if ($bad.Count -gt 0) {
    Write-Host "ERROR: invalid profile name(s): $($bad -join ', ')" -ForegroundColor Red
    Write-Host "       Use letters, digits, dot, underscore or dash (e.g. acc2)." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force -Path $root | Out-Null

# Load the switcher so we share its email/account-id helpers.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cxPath = Join-Path $scriptDir 'cx.ps1'
if (-not (Test-Path -LiteralPath $cxPath)) { $cxPath = Join-Path $codexHome 'cx.ps1' }
if (-not (Test-Path -LiteralPath $cxPath)) {
    Write-Host "ERROR: cx.ps1 not found next to this script or in $codexHome." -ForegroundColor Red
    exit 1
}
. $cxPath

function Get-AuthState {
    param([string]$AuthPath)
    if (-not (Test-Path -LiteralPath $AuthPath)) { return 'missing' }
    try { $auth = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json } catch { return 'unreadable' }
    if ($auth.tokens.refresh_token -and ($auth.tokens.id_token -or $auth.tokens.access_token)) { return 'ok' }
    return 'incomplete'
}

function Copy-BaseConfig {
    param([string]$Dir)
    $src = Join-Path $codexHome 'config.toml'
    if ((Test-Path $src) -and -not (Test-Path (Join-Path $Dir 'config.toml'))) {
        Copy-Item $src $Dir -Force
    }
}

# --- acc1: claim the existing default login, so it is not left orphaned -----
if (-not $VerifyOnly) {
    $acc1 = Join-Path $root 'acc1'
    if (-not (Test-Path (Join-Path $acc1 'auth.json')) -and (Test-Path (Join-Path $codexHome 'auth.json'))) {
        New-Item -ItemType Directory -Force -Path $acc1 | Out-Null
        Copy-Item (Join-Path $codexHome 'auth.json') $acc1 -Force
        Copy-BaseConfig $acc1
        Write-Host "acc1 seeded from the existing default login." -ForegroundColor Green
    }
}

# --- one browser login per isolated home -----------------------------------
$prevCodexHome = $env:CODEX_HOME

foreach ($acc in $Accounts) {
    if ($VerifyOnly) { break }

    $dir      = Join-Path $root $acc
    $authPath = Join-Path $dir 'auth.json'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-BaseConfig $dir

    if ((Get-AuthState $authPath) -eq 'ok') {
        Write-Host "[$acc] already logged in as $(Get-CodexProfileEmail $authPath) - skipping." -ForegroundColor DarkGray
        continue
    }

    Write-Host ""
    Write-Host "=== Preparing login for Profile: $acc ===" -ForegroundColor Cyan
    Write-Host "Saving tokens to: $dir" -ForegroundColor DarkGray
    Write-Host "A browser window will open for ChatGPT sign-in." -ForegroundColor Yellow
    Write-Host "If it silently reuses the previous account, sign out of chatgpt.com first (or use a private window)." -ForegroundColor Yellow

    $env:CODEX_HOME = $dir
    $loginExit = 0
    try {
        codex login
    }
    finally {
        # login can be abandoned with Ctrl+C; the env var still must not leak.
        $loginExit = $LASTEXITCODE
    }

    Read-Host "Press ENTER once you have completed logging into account $acc in the browser"

    $state = Get-AuthState $authPath
    if ($state -eq 'ok') {
        Write-Host "[$acc] OK - $(Get-CodexProfileEmail $authPath)" -ForegroundColor Green
        $dup = Find-CodexDuplicateProfile -AccountId (Get-CodexProfileAccountId $authPath) -Exclude $acc
        if ($dup) {
            Write-Host "[$acc] DUPLICATE: this account is already saved as '$dup'." -ForegroundColor Yellow
            Write-Host "      Remove one folder, or re-login $acc with a different account." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[$acc] auth.json is $state - this account is not usable yet." -ForegroundColor Red
        if ($loginExit) { Write-Host "  codex login exited with $loginExit" -ForegroundColor DarkGray }
    }
    $env:CODEX_HOME = $prevCodexHome
}

# --- final status table ----------------------------------------------------
$profiles = @(Get-CodexProfiles)
Write-Host ""
Write-Host "Codex profiles in $root" -ForegroundColor Cyan
if ($profiles.Count -eq 0) {
    Write-Host "  (none yet)" -ForegroundColor DarkGray
}
$profiles | ForEach-Object {
    [pscustomobject]@{
        Profile = $_.Name
        Email   = if ($_.Email) { $_.Email } else { '-' }
        Tokens  = Get-AuthState (Join-Path $_.Path 'auth.json')
    }
} | Format-Table -AutoSize

$ready = @($profiles | Where-Object { (Get-AuthState (Join-Path $_.Path 'auth.json')) -eq 'ok' }).Count
Write-Host "$ready of $($profiles.Count) profiles ready. Switch with: cx 2" -ForegroundColor Green
if ($Accounts.Count -eq 0 -and -not $VerifyOnly) {
    Write-Host ""
    Write-Host "Add more accounts with:  cx new" -ForegroundColor Cyan
    Write-Host "Or directly:             pwsh -File $($MyInvocation.MyCommand.Path) -Accounts acc2,acc3" -ForegroundColor DarkGray
}
