# codex-switch — multi-account switcher for the Codex CLI.
# Each account lives in its own CODEX_HOME folder under ~\.codex\profiles.
#
#   cx                    interactive account list
#   cx 3                  switch by list number
#   cx acc3               switch by folder name
#   cx god                switch by email fragment
#   cx acc2 exec "hi"     extra args pass through to codex
#   cx new                log in a new account (next free slot)
#   cx new acc11,acc12    log in specific slots
#   cx help               usage
#
# Note: $env:CODEX_HOME stays set after the call, so a bare `codex` in the
# same shell keeps using the account you picked.
#
# Porting to another shell or language? Read SPEC.md - it is the contract,
# this file is one implementation of it.

$global:CodexProfilesRoot = Join-Path (Join-Path $HOME '.codex') 'profiles'

function Get-CodexProfileEmail {
    param([Parameter(Mandatory)][string]$AuthPath)
    if (-not (Test-Path -LiteralPath $AuthPath)) { return $null }
    try { $auth = Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json } catch { return $null }
    foreach ($name in 'id_token', 'access_token') {
        $jwt = $auth.tokens.$name
        if (-not $jwt -or $jwt.Split('.').Count -lt 2) { continue }
        $payload = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
        try {
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            if ($claims.email) { return $claims.email }
        } catch { }
    }
    return $null
}

function Get-CodexProfileAccountId {
    param([Parameter(Mandatory)][string]$AuthPath)
    if (-not (Test-Path -LiteralPath $AuthPath)) { return $null }
    try { return (Get-Content -LiteralPath $AuthPath -Raw | ConvertFrom-Json).tokens.account_id } catch { return $null }
}

# Two profiles holding the same ChatGPT account = one wasted slot.
# Returns the name of the other profile, or $null.
function Find-CodexDuplicateProfile {
    param([Parameter(Mandatory)][string]$AccountId, [string]$Exclude)
    if (-not $AccountId) { return $null }
    Get-ChildItem $global:CodexProfilesRoot -Directory |
        Where-Object { $_.Name -ne $Exclude } |
        Where-Object { (Get-CodexProfileAccountId (Join-Path $_.FullName 'auth.json')) -eq $AccountId } |
        Select-Object -First 1 -ExpandProperty Name
}

# Numeric-aware sort: acc2 comes before acc10, not after.
function Get-CodexProfiles {
    if (-not (Test-Path $global:CodexProfilesRoot)) { return @() }
    Get-ChildItem $global:CodexProfilesRoot -Directory | ForEach-Object {
        [pscustomobject]@{
            Name  = $_.Name
            Path  = $_.FullName
            Email = Get-CodexProfileEmail (Join-Path $_.FullName 'auth.json')
            Order = if ($_.Name -match '^acc(\d+)$') { [int]$matches[1] } else { [int]::MaxValue }
        }
    } | Sort-Object Order, Name | Select-Object Name, Path, Email
}

function Show-CodexProfiles {
    $profiles = @(Get-CodexProfiles)
    Write-Host ""
    Write-Host "Codex accounts" -ForegroundColor Cyan
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        $label = if ($p.Email) { $p.Email } else { '(not logged in)' }
        $color = if ($p.Email) { 'White' } else { 'DarkGray' }
        Write-Host ("  [{0}] {1,-6} {2}" -f ($i + 1), $p.Name, $label) -ForegroundColor $color
    }
    $next = Get-NextCodexProfileName
    Write-Host ""
    Write-Host "  Tip:" -ForegroundColor DarkGray
    Write-Host "    cx new                log in a new account (next free slot: $next)" -ForegroundColor DarkGray
    Write-Host "    cx new acc11,acc12    log in specific slots" -ForegroundColor DarkGray
    Write-Host "    cx 3  |  cx work      switch account    |    cx 4 exec ""hi""  run once" -ForegroundColor DarkGray
    Write-Host ""
    return $profiles
}

# Lowest unused acc<N> folder, so `cx new` never overwrites a live profile.
function Get-NextCodexProfileName {
    for ($i = 1; $i -lt 100; $i++) {
        if (-not (Test-Path (Join-Path $global:CodexProfilesRoot "acc$i"))) { return "acc$i" }
    }
    return 'acc100'
}

# Guided login. Runs setup-codex-profiles.ps1 in a CHILD shell, never dot-sourced:
# that script calls `exit` on failure, which would close the interactive session.
function Start-CodexNewLogin {
    param([string[]]$Names)

    $loginScript = Join-Path (Join-Path $HOME '.codex') 'setup-codex-profiles.ps1'
    if (-not (Test-Path -LiteralPath $loginScript)) {
        Write-Host "Login script not found: $loginScript" -ForegroundColor Red
        Write-Host "Run install.ps1 from the codex-switch repo first." -ForegroundColor Yellow
        return
    }

    $Names = @(
        $Names |
            ForEach-Object { "$_" -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    if ($Names.Count -eq 0) { $Names = @(Get-NextCodexProfileName) }

    $hostExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

    Write-Host "Adding Codex account(s): $($Names -join ', ')" -ForegroundColor Cyan
    & $hostExe -NoProfile -File $loginScript -Accounts ($Names -join ',')
}

function Show-CodexHelp {
    Write-Host ""
    Write-Host "codex-switch" -ForegroundColor Cyan
    Write-Host "  Multiple Codex CLI accounts. One command to switch." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Switching" -ForegroundColor Yellow
    Write-Host "    cx                    interactive list"
    Write-Host "    cx 3                  by list number"
    Write-Host "    cx acc3               by folder name"
    Write-Host "    cx god                by email fragment"
    Write-Host "    cx 3 exec ""hi""        run codex once, args pass through"
    Write-Host ""
    Write-Host "  Adding accounts" -ForegroundColor Yellow
    Write-Host "    cx new                next free slot"
    Write-Host "    cx new acc11,acc12    specific slots"
    Write-Host ""
    Write-Host "  Where things live" -ForegroundColor Yellow
    Write-Host "    profiles: $global:CodexProfilesRoot"
    Write-Host "    active:   `$env:CODEX_HOME (stays set for this shell)"
    Write-Host ""
}

function Invoke-CodexAccount {
    param([string]$Account)

    if ($Account -in @('help', '-h', '--help', '?')) {
        Show-CodexHelp
        return
    }

    # `cx new` / `cx login` -> guided login, no profile switching.
    if ($Account -in @('new', 'login')) {
        Start-CodexNewLogin -Names $args
        return
    }

    $profiles = @(Get-CodexProfiles)
    if ($profiles.Count -eq 0) {
        Write-Host "No profiles in $global:CodexProfilesRoot." -ForegroundColor Red
        Write-Host "Run install.ps1 from the codex-switch repo, then: cx new" -ForegroundColor Yellow
        return
    }

    $match = @()
    if ($Account) {
        $match = @($profiles | Where-Object { $_.Name -eq $Account })
        if ($match.Count -eq 0 -and $Account -match '^\d+$' -and [int]$Account -ge 1 -and [int]$Account -le $profiles.Count) {
            $match = @($profiles[[int]$Account - 1])
        }
        if ($match.Count -eq 0) { $match = @($profiles | Where-Object { $_.Email -like "*$Account*" }) }
        if ($match.Count -gt 1) {
            Write-Host "'$Account' matches more than one profile: $($match.Name -join ', ')" -ForegroundColor Yellow
            return
        }
        if ($match.Count -eq 0) {
            Write-Host "No profile matches '$Account'." -ForegroundColor Red
            Show-CodexProfiles | Out-Null
            return
        }
    }
    else {
        Show-CodexProfiles | Out-Null
        $choice = Read-Host "Select account (number, name, email, or 'new')"
        if (-not $choice) { return }

        # "new" at the prompt = add an account instead of switching.
        if ($choice -in @('new', 'login')) {
            Start-CodexNewLogin -Names @()
            return
        }

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $profiles.Count) {
            $match = @($profiles[[int]$choice - 1])
        }
        else {
            $match = @($profiles | Where-Object { $_.Name -eq $choice -or $_.Email -like "*$choice*" })
        }
        if ($match.Count -ne 1) {
            if ($choice -match '^\d+$') {
                Write-Host "No account [$choice] yet - you have $($profiles.Count). Run 'cx new' to add one." -ForegroundColor Yellow
            }
            else {
                Write-Host "Invalid selection. Run 'cx new' to add an account." -ForegroundColor Red
            }
            return
        }
    }

    $env:CODEX_HOME = $match[0].Path
    Write-Host "Codex -> $($match[0].Name) ($($match[0].Email))" -ForegroundColor Green
    codex @args
}

Set-Alias cx Invoke-CodexAccount
