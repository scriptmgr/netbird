# PART 0 — Meta

This file is the canonical project specification. All build, layout, and convention rules are defined here. `IDEA.md` holds the project-specific variables and business logic. `CLAUDE.md` is the short loader that points at both.

---

# PART 1 — Project Identity

| Field | Value |
|-------|-------|
| `{project_name}` | `netbird` |
| `{project_org}` | `scriptmgr` |
| `{internal_name}` | `netbird` |
| `{repo_url}` | `https://github.com/scriptmgr/netbird` |
| `{language}` | POSIX sh |
| `{project_type}` | shell-script |
| `{license}` | MIT |

---

# PART 2 — Project Layout

```
netbird/
├── install.sh          # main installer/updater script
├── Makefile            # lint, install, uninstall targets
├── release.txt         # current version string (e.g. 0.1.0)
├── LICENSE.md          # MIT license
├── README.md           # public documentation
├── AI.md               # project specification (this file)
├── IDEA.md             # project variables and business logic
├── CLAUDE.md           # short loader
├── .gitignore
└── .claude/
    └── settings.json
```

Scripts live at the repo root — this is a single-script installer, not a multi-script library.

---

# PART 3 — No Build Toolchain

This is a pure shell-script project. There is no Makefile, no compiler, no toolchain image. Linting (`shellcheck`) is run directly on the host or in CI.

---

# PART 4 — Script Conventions

- **POSIX sh** — `#!/bin/sh`, no bashisms, no arrays, no `[[ ]]`, no `$'...'`
- **Function prefix** — all functions must be prefixed with `__` (e.g. `__die`, `__say`)
- **Variable prefix** — all global script variables must be prefixed with `INSTALL_` or `NB_`
- **`grep` default** — always `grep -- {pattern}` to prevent flag injection
- **No UUOC** — `grep pattern file`, never `cat file | grep pattern`
- **No inline comments** — comments go on the line above the code they describe
- **Line length** — max 180 characters
- **Version header** — every `.sh` file must have:
  ```sh
  ##@Version           :  YYYYMMDDHHMM-git
  ```
  and a matching `VERSION='YYYYMMDDHHMM-git'` assignment in the script body
- **Exit codes** — POSIX sysexits: 0=success, 1=general error, 64=usage, 65=data, 66=noinput, 69=unavailable, 78=config

---

# PART 5 — .gitignore

Must include at minimum:

```
.env
app.env
default.env
*.local
.no_push
.no_git
.installed
.claude/settings.local.json
.claude/backups/
.claude/cache/
.claude/file-history/
.claude/history.jsonl
.claude/projects/
.claude/statsFile
.claude/*.lock
```

---

# PART 6 — Bootstrap Checklist

On first bootstrap, create or verify:

1. `release.txt` — contains `0.1.0`
2. `LICENSE.md` — MIT license, copyright `scriptmgr`
3. `.gitignore` — entries from PART 5 merged with existing
4. `CLAUDE.md` — short loader pointing at `AI.md` and `IDEA.md`
5. `IDEA.md` — project description, variables, business logic
6. `.claude/settings.json` — Claude Code project settings
7. `.env.example` — template of overridable variables (no secrets)
