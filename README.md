# codex-switch

> One Codex CLI. Many ChatGPT accounts. Switch in one keystroke.

The Codex CLI stores exactly **one** login at `~/.codex/auth.json`. When that account hits its
rate limit, you are stuck — either waiting, or hand-editing token files and hoping you can get the
old one back.

`codex-switch` gives every ChatGPT account its own isolated `CODEX_HOME` folder, and turns
switching into a single command. No token juggling, no overwriting, no copy-paste.

```text
Codex accounts
  [1] acc1   you@gmail.com
  [2] acc2   work@gmail.com
  [3] acc3   alt@gmail.com

  Tip:
    cx new                log in a new account (next free slot: acc4)
```

## Why this exists

| The usual way | With codex-switch |
| :--- | :--- |
| Log out, log in as someone else, lose the previous session | Each account stays logged in, permanently |
| Move `auth.json` files around by hand | `cx 2` |
| Forgot which account is active | The list tells you, and `$env:CODEX_HOME` holds it |
| Rate limited mid-task | Switch and keep working |

## Requirements

| | |
| :--- | :--- |
| OS | Windows, macOS or Linux. **PowerShell 7+** everywhere; Windows PowerShell 5.1 also works on Windows. |
| `codex` | Installed and on your `PATH` (`npm i -g @openai/codex`) |
| Account | Any ChatGPT account — the free tier is fine |

All paths are built with `Join-Path`, and the installer picks the right profile location for your
platform (`Documents\PowerShell\profile.ps1` on Windows, `~/.config/powershell/profile.ps1` on
macOS/Linux).

## Install

```powershell
git clone https://github.com/abhinav-twr/codex-switch.git
cd codex-switch
pwsh -File .\install.ps1
```

Open a **new** PowerShell window, then:

```powershell
cx
```

That is it. `install.ps1` copies the scripts to `~\.codex\` and adds a small block to your
PowerShell profile, so `cx` exists in every new shell.

### Options

| Command | What it does |
| :--- | :--- |
| `pwsh -File .\install.ps1` | Copy the scripts into `~\.codex\` |
| `pwsh -File .\install.ps1 -Link` | Hardlink instead of copy — repo edits take effect instantly, no re-install |
| `pwsh -File .\install.ps1 -NoProfile` | Don't touch your profile; you'll dot-source `cx.ps1` yourself |

### Manual install

If you'd rather not run a script, do it by hand:

```powershell
# 1. put both scripts in place
Copy-Item .\cx.ps1, .\setup-codex-profiles.ps1 "$HOME\.codex\"

# 2. add one line to your profile
Add-Content $PROFILE.CurrentUserAllHosts '. "$HOME\.codex\cx.ps1"'
```

## Quick start

```powershell
cx          # see what you have
cx new      # log in the next account (opens a browser)
cx 2        # switch to it
```

The first run automatically **seeds `acc1`** from whatever login already exists in
`~\.codex\auth.json`, so your current account is never lost.

## Usage

| Command | Result |
| :--- | :--- |
| `cx` | Interactive account list |
| `cx 3` | Switch by list number |
| `cx acc3` | Switch by folder name |
| `cx work` | Switch by email fragment |
| `cx 3 exec "hi"` | Run `codex` once with that account; args pass straight through |
| `cx new` | Log in a new account in the next free slot |
| `cx new acc11,acc12` | Log in specific slots |
| `cx help` | Full usage |

After `cx 3`, `$env:CODEX_HOME` stays pointed at that account **for that shell**, so a bare
`codex` keeps using it. Open another shell and you start from the default login again — the
switch is per-window on purpose.

## Where everything lives

```
~\.codex\
├── auth.json                     default login (untouched by the switcher)
├── config.toml                   template copied into every new profile
├── cx.ps1                        the switcher  ── defines `cx`
├── setup-codex-profiles.ps1      guided login
└── profiles\
    ├── acc1\  auth.json  config.toml
    ├── acc2\  auth.json  config.toml
    └── acc3\  auth.json  config.toml
```

`~\.codex\profiles\` is the **only** thing worth backing up — those folders hold the live tokens.
Everything else can be reinstalled from this repo in seconds.

## How it works

Short version: `cx` sets `$env:CODEX_HOME` to the chosen profile folder and calls `codex`.
Because the CLI reads its auth and config from `CODEX_HOME`, each account is fully isolated.

The longer version — login sequence, `auth.json` anatomy, resolution order, every function —
is in **[HOW-IT-WORKS.md](HOW-IT-WORKS.md)**.

## Troubleshooting

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| `cx` is not recognized | Profile not reloaded, or block missing | Open a new shell, or `. "$HOME\.codex\cx.ps1"` |
| Browser logs into the **same** account again | ChatGPT session cookie is reused | Sign out of chatgpt.com first, or use a private window |
| `[acc3] auth.json is incomplete` | Login was abandoned before the callback finished | Re-run `cx new acc3` |
| Account looks fine but requests fail | Token expired server-side | Delete `~\.codex\profiles\acc3\auth.json`, then `cx new acc3` |
| `[acc3] DUPLICATE: already saved as 'acc2'` | Same ChatGPT account logged in twice | Delete one profile folder — a duplicate wastes a slot |
| Two identical accounts after login | Same reason, caught late | Same fix |
| Script does nothing when run as `.\script.ps1` | Execution policy | `pwsh -File .\install.ps1` instead |

## Uninstall

```powershell
pwsh -File .\uninstall.ps1                  # keeps your accounts
pwsh -File .\uninstall.ps1 -PurgeProfiles   # logs every account out (no undo)
```

## Repo layout

| File | Purpose |
| :--- | :--- |
| `cx.ps1` | The switcher — every `cx` subcommand |
| `setup-codex-profiles.ps1` | Guided login, one isolated `CODEX_HOME` per account |
| `install.ps1` | Copies/hardlinks both scripts to `~\.codex`, wires the profile |
| `uninstall.ps1` | Removes the profile block and scripts |
| `HOW-IT-WORKS.md` | Architecture and function reference |
| `SPEC.md` | Language-agnostic behaviour contract — use this to port the tool |

## Porting to another shell or language

The design is not PowerShell-specific. **[SPEC.md](SPEC.md)** states the invariants, the storage
and credential contracts, the resolution algorithm, the login flow, and 16 acceptance tests —
everything needed to rebuild this in bash, Python or Node without reverse-engineering the code.

If you are an **agent** asked to make codex-switch work on another platform: implement `SPEC.md`,
then run its acceptance tests. The `.ps1` files are one implementation, not the definition.

Currently implemented: PowerShell (Windows, macOS, Linux via `pwsh`).
Not yet implemented: bash/zsh, Python.

## Notes & limits

- Tokens sit in plaintext in `auth.json`, same as the CLI's own default. Treat `profiles\` like a password file and keep it out of git — the `.gitignore` here already does.
- No quota probing: the list shows that tokens exist, not that the account still has headroom. If a call fails, switch and move on.
- Windows-first. Nothing uses Windows-only APIs, but only Windows is tested.

## License

MIT — see [LICENSE](LICENSE).
