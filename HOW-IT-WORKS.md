# How codex-switch works

This is the technical companion to the README. It covers the storage model, what is in
`auth.json`, every function, and the handful of non-obvious design decisions.

---

## 1. The model: `CODEX_HOME` isolation

The Codex CLI reads *all* of its state from one directory, given by the `CODEX_HOME`
environment variable (default `~/.codex`): `auth.json`, `config.toml`, logs, sqlite databases,
sessions, plugins.

That single variable is the entire trick. If you point it at a different folder containing a
different `auth.json`, the CLI is a different user — completely, with no shared cache and no
leaked session.

```
                 ┌───────────────────────────────┐
                 │  $env:CODEX_HOME              │
                 └──────────────┬────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
 profiles\acc1\          profiles\acc2\          profiles\acc3\
  auth.json               auth.json               auth.json
  config.toml             config.toml             config.toml
  (account A)             (account B)             (account C)
```

Everything else in this project is convenience around setting that one variable safely and
remembering which folders exist.

### Why not just swap `auth.json`?

Copying token files in and out of a single directory works, right up until it doesn't:

- an interrupted run leaves you with no valid login at all;
- two accounts cannot be used simultaneously in two shells;
- any stale cache or session state belongs to whichever account was last there;
- a crash mid-copy corrupts the file you were relying on.

One folder per account removes the class of bug entirely. Nothing is ever moved.

---

## 2. Directory layout

```
~\.codex\
├── auth.json                     ← the CLI's default login. Never modified by this tool.
├── config.toml                   ← template. Copied into each new profile.
├── cx.ps1                        ← switcher. Defines the `cx` command.
├── setup-codex-profiles.ps1      ← guided login.
└── profiles\
    ├── acc1\
    │   ├── auth.json             ← credentials for one ChatGPT account
    │   ├── config.toml           ← copy of the template
    │   ├── log\  tmp\  sessions\ ← per-account runtime state (safe to delete)
    │   └── *.sqlite              ← per-account history/queue
    ├── acc2\ ...
    └── accN\ ...
```

| Path | Owned by | Notes |
| :--- | :--- | :--- |
| `~\.codex\auth.json` | the CLI | The account you'd have without this tool. `acc1` is seeded from it. |
| `~\.codex\profiles\accN\auth.json` | this tool | The only file that actually identifies an account. |
| `~\.codex\profiles\accN\config.toml` | the CLI | Copied once, only if missing — your settings are never overwritten. |
| `~\.codex\profiles\accN\*.sqlite`, `log\`, `tmp\` | the CLI | Per-account state. Deleting them logs you out of nothing but history. |

---

## 3. What's inside `auth.json`

```jsonc
{
  "auth_mode": "chatgpt",          // or "apikey" for OPENAI_API_KEY logins
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token":      "eyJhbGciOi...",  // JWT: identity + email + plan
    "access_token":  "eyJhbGciOi...",  // JWT: the bearer token used for API calls
    "refresh_token": "rt.1.AAA...",    // opaque, long-lived, what keeps you logged in
    "account_id":    "2790813a-..."    // ChatGPT account UUID
  },
  "last_refresh": "2026-11-20T06:32:38Z"
}
```

All three JWT segments are unsigned-but-verifiable base64url. The middle segment is readable
without any secrets, which is how the tool shows you an email without calling an API:

```
header.payload.signature
       │
       └── base64url-decode → { "email": "...", "email_verified": true,
                                "https://api.openai.com/auth": {
                                     "chatgpt_plan_type": "free",
                                     "chatgpt_account_id": "..." } }
```

`Get-CodexProfileEmail` decodes exactly that. It tries `id_token` first, falls back to
`access_token`, and returns `$null` if neither parses — which the UI renders as
`(not logged in)`.

### The three states a profile can be in

| State | Detection | Meaning |
| :--- | :--- | :--- |
| `missing` | no `auth.json` | Never logged in, or the folder was cleaned |
| `incomplete` | file exists, no usable `tokens` | Login was abandoned before the callback |
| `ok` | `refresh_token` **and** (`id_token` or `access_token`) | Usable |

`incomplete` is the state that costs people the most time, which is why `setup-codex-profiles.ps1`
checks for it explicitly instead of trusting that a folder exists.

Worth knowing: `ok` means "has credentials", not "has quota". A rate-limited account is still
`ok`. That is a deliberate limit — see §8.

---

## 4. Function reference — `cx.ps1`

| Function | Purpose |
| :--- | :--- |
| `Get-CodexProfileEmail` | Decode the email claim out of a profile's JWT. No network. |
| `Get-CodexProfileAccountId` | Read `tokens.account_id` — the real identity of an account. |
| `Find-CodexDuplicateProfile` | Same `account_id` in two folders? Returns the other folder's name. |
| `Get-CodexProfiles` | Enumerate `profiles\` into `{Name, Path, Email}`, sorted numerically. |
| `Show-CodexProfiles` | Pretty-print the numbered list plus the tip block. Returns the array. |
| `Get-NextCodexProfileName` | Lowest unused `accN`, so `cx new` never collides. |
| `Start-CodexNewLogin` | Launch the login script in a child shell with the right slots. |
| `Show-CodexHelp` | Usage text for `cx help`. |
| `Invoke-CodexAccount` | The `cx` command itself: resolve → set env → run `codex`. |
| `Set-Alias cx Invoke-CodexAccount` | Binds the short name. |

### `Get-CodexProfiles` — why the sort is custom

`Sort-Object Name` is alphabetical, which puts `acc10` between `acc1` and `acc2`. The list
number and the folder name then disagree with any human ordering scheme. So each item carries a
temporary `Order` key:

```powershell
Order = if ($_.Name -match '^acc(\d+)$') { [int]$matches[1] } else { [int]::MaxValue }
```

Non-`accN` folders sort last instead of interleaving. The key is dropped by
`Select-Object Name, Path, Email` before the objects are returned.

### `Invoke-CodexAccount` — resolution order

Given `cx <arg>`, the first match wins:

1. `help` / `-h` / `--help` / `?` → usage
2. `new` / `login` → guided login (extra args become account names)
3. exact folder name → `acc3`
4. integer within range → list position
5. email substring → `god` matches `god.of.thunder…`
6. nothing → interactive prompt

Ambiguous email fragments are rejected rather than guessed:

```
'aru' matches more than one profile: acc2, acc5
```

### `Start-CodexNewLogin` — why a child process

The login script ends with `exit 1` on several failure paths. If `cx` dot-sourced it, that
`exit` would close your interactive shell. So it is invoked as a real subprocess:

```powershell
& $hostExe -NoProfile -File $loginScript -Accounts ($Names -join ',')
```

`-NoProfile` keeps startup fast and prevents a profile that itself dot-sources `cx.ps1` from
recursing.

The leftover `$args` is what makes `cx 3 exec "hi"` work: everything after the account
selector is handed straight to `codex`.

---

## 5. The login flow

`cx new` → `Start-CodexNewLogin` → `setup-codex-profiles.ps1`:

```
 1. normalize -Accounts        split on commas, trim, dedupe
 2. validate names             ^[A-Za-z0-9._-]+$   (folders, so no separators)
 3. seed acc1                  if ~\.codex\auth.json exists and acc1\auth.json does not
 4. per account:
      a. create profiles\accN\
      b. copy config.toml       only if absent — never clobbers your settings
      c. already 'ok'?          skip
      d. CODEX_HOME = accN folder
      e. codex login            browser → OAuth callback → auth.json written
      f. wait for ENTER         some terminals return before the write lands
      g. verify auth.json       report ok / incomplete / duplicate
      h. restore CODEX_HOME     to its previous value
 5. status table               every profile, email, token state
```

### Step 2 matters more than it looks

Profile names become **folder names**. Without a whitelist, a name like `..\..\Windows` or
`acc9/sub` would create a path outside the profiles root. The regex allows only letters,
digits, dot, underscore and dash.

It cannot catch semantic mistakes — `-Accounts bad,path` passes validation and creates two
profiles called `bad` and `path`. If you want to see what a run *would* do before committing to
it, check the printed `Adding Codex account(s): …` line; it lists the resolved slots first.

### The `pwsh -File` comma trap

```powershell
pwsh -File setup-codex-profiles.ps1 -Accounts acc9,acc10
```

In `-File` argument mode the comma is a **literal character**, not an array separator. The
parameter is declared `[string[]]` but receives one element: `"acc9,acc10"` — and you get a
single folder named `acc9,acc10`.

This is why both scripts split on commas themselves:

```powershell
$Accounts | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | ...
```

It makes all of these equivalent:

```powershell
-Accounts acc9,acc10          # via pwsh -File (one string)
-Accounts acc9, acc10         # spaces, still one string
-Accounts @('acc9','acc10')   # real array, from inside PowerShell
```

### Step 6 exists because of a race

`codex login` can return before `auth.json` is fully flushed. Pressing ENTER without the pause
would intermittently report `incomplete` for a login that actually succeeded. The prompt costs
one keystroke and removes the race.

### Step 8 exists because of leakage

`$env:CODEX_HOME` is process-wide. If it leaked out of the script, the *next* `codex` run in
that shell would silently use the profile you just created rather than the one you had chosen.
`Invoke-CodexAccount` sets it deliberately; the login script restores it.

---

## 6. Why the switch persists

`Invoke-CodexAccount` sets `$env:CODEX_HOME` and leaves it set. That is intentional:

```powershell
cx 3            # switch
codex exec "…"  # uses acc3
```

The alternative — scoping the variable per call — would force `cx` on every invocation and
break scripts that call `codex` repeatedly. The cost is that a shell silently remembers an
account, which is why the list shows it and `cx` prints `Codex -> acc3 (email)` on switch.

Open a new window to get back to the default `~\.codex` login.

---

## 7. Extending it

To add a subcommand, catch it early in `Invoke-CodexAccount` before profile resolution:

```powershell
function Invoke-CodexAccount {
    param([string]$Account)

    if ($Account -in @('help', '-h', '--help', '?')) { Show-CodexHelp; return }
    if ($Account -in @('new', 'login')) { Start-CodexNewLogin -Names $args; return }

    if ($Account -eq 'test') {          # ← new subcommand
        # $args holds anything after "test"
        return
    }
    ...
```

Useful primitives already available: `Get-CodexProfiles` (enumerate), `Get-CodexProfileEmail`
(identify), `Get-AuthState` in the setup script (validate), `Find-CodexDuplicateProfile`
(detect wasted slots).

Keep new commands ASCII-only in output — Windows PowerShell 5.1 consoles mangle box-drawing
characters and emoji depending on code page.

---

## 8. Known limitations

| Limitation | Detail |
| :--- | :--- |
| No quota check | `ok` means "has tokens", not "has headroom". Probing costs API calls, so it is opt-in by design. |
| Plaintext tokens | Same as the CLI's own storage. `profiles\` deserves password-file treatment. |
| Windows-first | No Windows-only API is used, but only Windows is tested. |
| No expiry warning | `access_token` carries an `exp` claim that could be decoded locally to warn about dead tokens; not implemented. |
| Sequential logins | One browser flow at a time, by design — parallel OAuth callbacks would fight over the local port. |
