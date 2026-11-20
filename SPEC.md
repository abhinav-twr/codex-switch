# SPEC — behaviour contract for codex-switch

This file exists so the tool can be **reimplemented in any language** (bash, Python, Node, Go,
whatever) without re-deriving the design. It contains no PowerShell.

If you are an agent asked to "make this work on Linux" or "port this to Python": read this file,
implement the contract, then satisfy every case in [§9 Acceptance tests](#9-acceptance-tests).
The PowerShell files are one implementation, not the definition.

---

## 1. What the tool is

A command that lets one user keep multiple ChatGPT/Codex CLI logins on one machine and switch
between them per shell, without moving or editing token files.

It does not talk to any API. It manipulates the Codex CLI's own `CODEX_HOME` convention and then
delegates to `codex`.

---

## 2. Invariants

Any implementation must preserve all of these. They are the reason the design works.

| # | Invariant |
| :-- | :--- |
| I1 | Each account occupies its own directory. No two accounts share `auth.json`. |
| I2 | Switching never copies, moves, or rewrites `auth.json`. It only sets an environment variable. |
| I3 | The CLI's default `~/.codex/auth.json` is never modified. |
| I4 | Profile directories are never created outside the profiles root. |
| I5 | Switching affects only the current shell process, and persists for later commands in that shell. |
| I6 | An existing authenticated profile is never overwritten by bulk operations. |
| I7 | Login runs sequentially, one account at a time. |

---

## 3. Storage contract

```
$CODEX_HOME_DEFAULT/                 # ~/.codex
├── auth.json                        # CLI default login — read-only here
├── config.toml                      # template, copied into new profiles
└── profiles/
    ├── acc1/
    │   ├── auth.json                # credentials for exactly one account
    │   └── config.toml              # copy of template, only if absent
    └── accN/...
```

Rules:

- **Profiles root** — `<default codex home>/profiles`. The implementation must derive it from the
  user's home directory, never hardcode a path.
- **Profile name** — must match `^[A-Za-z0-9._-]+$`. Names become directory names, so anything
  else (separators, commas, `..`) is rejected before any filesystem call.
- **Default naming** — `acc1`, `acc2`, … `accN`, monotonic.
- **Next free name** — the lowest `accN` (1 ≤ N < 100) with no existing directory.
- **Seeding** — if `profiles/acc1/auth.json` is missing and the CLI default `auth.json` exists,
  copy the default into `acc1` on setup. This prevents orphaning an existing login.
- **Config** — copy `config.toml` into a new profile **only if the profile has none**. Never
  overwrite a user's settings.

---

## 4. Credential contract

`auth.json` is JSON with this shape (extra fields may exist and must be ignored):

```jsonc
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "…jwt…",
    "access_token": "…jwt…",
    "refresh_token": "…opaque…",
    "account_id": "uuid"
  }
}
```

### 4.1 State machine

| State | Condition |
| :--- | :--- |
| `missing` | file does not exist |
| `unreadable` | file exists, JSON parse fails |
| `incomplete` | parses, but no usable `tokens` |
| `ok` | `tokens.refresh_token` present **and** (`tokens.id_token` or `tokens.access_token`) present |

`ok` means "has credentials". It does **not** mean "has quota". Implementations must not claim
otherwise.

### 4.2 Identity extraction (no network)

Email is read out of the JWT payload:

1. Try `tokens.id_token`, then `tokens.access_token`. First success wins.
2. Split on `.`. Need at least 2 segments. Take segment [1] (the payload).
3. Convert base64url → base64: `-`→`+`, `_`→`/`.
4. Pad to a multiple of 4: remainder 2 → `==`, remainder 3 → `=`, remainder 1 → invalid.
5. Base64-decode, parse as JSON, read the `email` claim.
6. On any failure, return null — the UI shows "(not logged in)".

Account identity is simpler: `tokens.account_id`, verbatim.

### 4.3 Duplicate detection

Two profiles are the same account when their `tokens.account_id` values are equal. A duplicate is
a wasted slot and must be reported, naming the other profile.

---

## 5. Command contract

| Invocation | Behaviour |
| :--- | :--- |
| *(no argument)* | Print the numbered list, then prompt for a selection. |
| `<integer in range>` | Switch to that list position. |
| `<exact profile name>` | Switch to that profile. |
| `<text>` | Switch to the unique profile whose email contains `<text>`. |
| `<selector> <any args…>` | Switch, then run `codex` with `<any args…>` passed through verbatim. |
| `new` / `login` | Start a guided login. Extra arguments are profile names. |
| `help` / `-h` / `--help` / `?` | Print usage; do nothing else. |

### 5.1 Resolution order

First match wins. Later steps are only tried if the earlier ones produced zero matches.

1. `help`-family → usage
2. `new` / `login` → login flow (§6)
3. exact profile directory name
4. integer within `1..profileCount` → index into the sorted list
5. email substring match (case-insensitive)
6. no argument → interactive prompt

Ambiguity is an error, never a guess:

```
'<text>' matches more than one profile: acc2, acc5
```

Out-of-range integer at the interactive prompt must explain the add path, not just fail:

```
No account [10] yet - you have 9. Run 'cx new' to add one.
```

### 5.2 Ordering

The list is sorted by the numeric suffix of `accN`, so `acc2` precedes `acc10`. Non-conforming
names sort last, alphabetically. The list index is 1-based and must match resolution step 4.

### 5.3 Switch semantics

On a successful switch:

1. Set `CODEX_HOME` to the chosen profile directory **in the current shell**.
2. Print `Codex -> <name> (<email>)`.
3. Run `codex` with any passthrough arguments.

If there are no passthrough arguments, `codex` is invoked bare (interactive mode). The
environment variable is **not** unset afterwards — that is what makes `cx` then `codex` work.

---

## 6. Login flow

Triggered by `new` / `login`, or by a separate setup entry point taking a list of names.

1. **Normalize** the requested names: split each on commas, trim, drop empties, dedupe. Accepting
   comma-joined input is required — CLI argument parsing differs per platform and per shell
   (PowerShell's `-File` mode delivers `acc2,acc3` as one string, not two arguments).
2. **Validate** every name against `^[A-Za-z0-9._-]+$`. Reject the whole run on any failure,
   listing the offenders.
3. **Seed** `acc1` per §3.
4. For each requested name, sequentially:
   1. Create the profile directory.
   2. Copy `config.toml` if absent.
   3. Skip if state is already `ok` (report it, keep going).
   4. Set `CODEX_HOME` to the profile directory.
   5. Run `codex login` — this opens a browser and blocks until the OAuth callback lands.
   6. Wait for the user to confirm (a keypress/ENTER). Some terminals return before the
      credential file is flushed; without this pause the next step races.
   7. Evaluate state: report `ok` + email, or `incomplete`/`unreadable` + reason.
   8. If `ok`, check duplicates (§4.3) and warn.
   9. **Restore** `CODEX_HOME` to its previous value. This is mandatory: leaking the variable
      would silently redirect the user's next command to the profile that was just created.
5. Print a final status table: every profile, its email, its state, plus a ready count.

`-VerifyOnly` (or an equivalent flag) must perform steps 3 and 5 only — no mutation, no login.

---

## 7. Install contract

| Requirement | Detail |
| :--- | :--- |
| Locate destination | `<default codex home>`, created if missing. |
| Place files | `cx` entry script + setup script into that directory. |
| Wire shell | Add one sourced line to the shell's profile, wrapped in `# >>> codex-switch >>>` / `# <<< codex-switch <<<` markers. |
| Idempotence | Re-running must replace the marked block, never append a second copy. |
| Platform profiles | Windows PowerShell 5.1: `Documents/WindowsPowerShell/profile.ps1`. PowerShell 7+: `Documents/PowerShell/profile.ps1`. macOS/Linux: the single AllHosts profile. |
| Optional hardlink | Offer a mode where the installed file is a link to the repo, so repo edits go live without reinstalling. Fall back chain: hardlink → symlink → copy. |
| No profile edit | A flag must exist to skip shell wiring entirely. |

Uninstall is the inverse: remove the marked block (keep surrounding content intact), delete the
installed scripts, and **keep** accounts unless an explicit purge flag is passed.

---

## 8. Output contract

Required, because other users will read it:

1. Numbered list, 1-based, aligned name + email.
2. A `(not logged in)` placeholder for profiles without credentials.
3. A hint block explaining how to add an account and the next free slot.
4. Switch confirmation on one line: `Codex -> <name> (<email>)`.
5. Errors name the failure and the fix, e.g. "incomplete — re-run the login for acc3".
6. Plain ASCII only. Box-drawing characters and emoji break on some Windows consoles.

---

## 9. Acceptance tests

An implementation is correct when all of these pass. `N` = profile count.

| # | Setup | Action | Expected |
| :-- | :--- | :--- | :--- |
| 1 | no profiles dir | list | empty list, no crash, hint shown |
| 2 | acc1 only | `new` | creates `acc2` (lowest free), not `acc1` |
| 3 | acc1..acc9 | `new` | targets `acc10` |
| 4 | acc1, acc3 exist (gap) | `new` | targets `acc2` |
| 5 | acc1..acc10 | list | `acc10` is last, `acc2` before `acc3` |
| 6 | 9 profiles | select `10` at prompt | explains count and suggests `new` |
| 7 | acc2 email `a@x.com`, acc3 `b@y.com` | `<text>` matching both | ambiguity error, no switch |
| 8 | acc2 exists | `new acc2` | skips it, `CODEX_HOME` unchanged |
| 9 | acc9 valid | `acc9 exec "hi"` | `CODEX_HOME` = acc9, `codex exec "hi"` runs |
| 10 | folder `acc9,acc10` from a bad parse | list | must never occur — comma input is split |
| 11 | name `../evil` | `new ../evil` | rejected before any filesystem write |
| 12 | `auth.json` truncated | list | shows `(not logged in)`, no crash |
| 13 | two profiles, same `account_id` | login the second | duplicate warning names the first |
| 14 | no `auth.json` in profile | state check | `missing`, not `ok` |
| 15 | interrupted login | state check | `incomplete`, not `ok` |
| 16 | login in progress, then `codex` in same shell | — | `CODEX_HOME` restored to pre-login value |

---

## 10. Porting map

PowerShell is one option. Minimum viable features per language:

| Need | PowerShell (reference) | bash / zsh | Python 3 |
| :--- | :--- | :--- | :--- |
| home dir | `$HOME` | `$HOME` | `Path.home()` |
| join path | `Join-Path a b` (nested) | `"$a/$b"` | `a / b` |
| JSON read | `ConvertFrom-Json` | `jq -r '.tokens.refresh_token'` | `json.load` |
| base64url decode | `FromBase64String` + padding | `base64 -d` (GNU) / `base64 -D` (BSD) | `base64.urlsafe_b64decode(s + '==')` |
| dir exists | `Test-Path` | `[ -d ... ]` | `Path.is_dir()` |
| list dirs | `Get-ChildItem -Directory` | `for d in "$root"/*/` | `Path.iterdir()` |
| set env | `$env:CODEX_HOME = $p` | `export CODEX_HOME="$p"` | `os.environ['CODEX_HOME'] = p` |
| prompt | `Read-Host` | `read -r` | `input()` |
| run child | `codex @args` | `"$@"` after `shift` | `subprocess.run(['codex', *args])` |
| hardlink | `New-Item -ItemType HardLink` | `ln` | `os.link` |

Portability notes:

- **bash must be sourced** to affect the parent shell (`source cx.sh`), exactly like the
  PowerShell profile dot-sources `cx.ps1`. A plain executed script cannot export to the caller —
  a wrapper function/alias is the standard workaround.
- **zsh** users need `export` too; a `cx()` function is the idiomatic carrier.
- macOS `base64` uses `-D`; GNU uses `-d`. Feature-detect rather than assume.
- `jq` is not guaranteed — prefer the language's JSON parser, or make `jq` an explicit dependency.
- Shell name validation must happen **before** `mkdir`, since a name is a directory component.

---

## 11. Non-goals

Deliberately out of scope, so implementations don't sprawl:

- Quota/usage probing (costs API calls; "has credentials" is the honest claim).
- Token expiry warnings (would require decoding `exp` and defining behaviour per platform).
- Token refresh orchestration — the CLI owns that.
- Parallel logins (OAuth callbacks would collide).
- Editing `config.toml` per profile beyond the one-time copy.
- Any network call of its own.
