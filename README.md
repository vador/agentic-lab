# agentlab

An isolated lab for agentic coding on a Debian 13 workstation.

AI agents (Claude Code, Codex CLI, Gemini CLI, VS Code extensions) run inside **disposable KVM VMs**.
Code reaches the host only through a **Gitea** server that runs in Docker on the host. CI runs in a
**separate runner VM**, and **Floci** emulates AWS, so no real cloud account is needed.

```
┌──────────────────────── Debian 13 host ─────────────────────────────────────────────┐
│ VS Code / terminal ──ssh──┐        Docker Compose (trusted)                         │
│                           │        ├─ gitea + postgres  :3000 / ssh :2222           │
│                           │        ├─ registry mirror   :5000  (Docker Hub cache)   │
│                           │        └─ ollama (opt, GPU) :11434                      │
│                           ▼               ▲ published on 127.0.0.1 + 192.168.150.1  │
│  libvirt NAT "agentlab" 192.168.150.0/24 ─┘  nftables: VMs → internet + those ports │
│      │                         │              only; never your LAN                  │
│  ┌───▼──── agent (VM) ───┐ ┌───▼──── ci (VM) ──────┐                                │
│  │ claude/codex/gemini   │ │ gitea-runner          │                                │
│  │ tmux + git worktrees  │ │ jobs in Docker        │                                │
│  │ Docker, mise, Floci   │ │ Floci as job service  │                                │
│  │                       │ │ + guard/security from │                                │
│  │                       │ │   platform/checks     │                                │
│  └───────────────────────┘ └───────────────────────┘                                │
│  Both are thin copy-on-write clones of a "golden" image                             │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## Quick start

```bash
cp config.env.example config.env        # optional: adjust sizes, versions, network
ln -s "$PWD/lab" ~/.local/bin/lab        # optional: put `lab` on your PATH

lab host install        # packages, Docker, libvirt network + pool, firewall, /etc/hosts
# log out and back in (libvirt/docker groups)
lab services up         # Gitea + Postgres + registry mirror; creates admin + tokens in .secrets/
lab vm golden           # ~10 min: Debian 13 + Docker + mise + Node + AI CLIs + tea
lab vm new ci --role ci # Actions runner, registered automatically
lab vm new agent        # your agents' workspace
lab project new demo    # org + bot user + repo from template + creds/clone in the agent VM
                        # (first time: also publishes the human-owned CI checks)
```

Then:

```bash
ssh agent                        # or VS Code → Remote-SSH → "agent"
claude                           # first run: log in / set API keys inside the VM only
agt new demo feat/hello          # worktree + tmux window running the agent
```

Gitea UI: http://gitea.internal:3000. The admin password is in `.secrets/gitea-admin-password`.

## Commands

| Command | What it does |
|---|---|
| `lab host install` | Installs KVM/libvirt, Docker and the lab network/pool/firewall |
| `lab host nvidia` | Optional: proprietary NVIDIA driver + container toolkit (for Ollama) |
| `lab services up [--gpu]` / `down` / `ps` / `logs` | Host services |
| `lab services backup` | `gitea dump` + `.secrets` → `$BACKUP_DIR` (rotated) |
| `lab vm golden` | Builds a new `golden-<date>.qcow2`. Existing VMs are unaffected |
| `lab vm new <name> [--role agent\|ci\|base]` | Thin clone of the latest golden image, fixed IP, `ssh <name>` |
| `lab vm snapshot <name> [label]` / `rollback` / `snapshots` | Take a snapshot before long autonomous runs |
| `lab vm destroy <name>` | Deletes the VM, its disk, IP reservation and SSH entries |
| `lab vm golden-list` | Lists golden images and which VMs still use them |
| `lab project new <org> [--repo R] [--vm VM]` | Sets up everything for a project (idempotent) |
| `lab project protect <org> [--repo R]` | Re-applies `main` protection and `REQUIRED_CHECKS` (after adding a CI job) |
| `lab checks publish` | Publishes `checks/` to `platform/checks@v1` and gives the CI runner read access |
| `agt new\|ls\|rm\|attach` (inside VM) | One worktree + one tmux window per agent task |

## Multiple projects

- **One Gitea org per project or client.** `lab project new` creates the org, a **restricted bot user**
  `bot-<org>` (it only sees this org), an `agents` team with write access, and the repo, seeded from
  `projects/template/`. It also protects `main`: only the admin (you) can push to or merge into
  `main`, so agents must open PRs (`tea pr create --login <org> --repo <org>/<repo>`).
- **Per-project identity in the VM**: there's an SSH alias `gitea-<org>` with the bot's key, a git
  `includeIf` for `~/work/<org>/`, and a `tea` login named `<org>`. A leaked credential only gives
  access to one project.
- **Per-worktree isolation**: the template's `.envrc` sets a unique `COMPOSE_PROJECT_NAME` and
  Floci port for each worktree, so parallel agents never collide.
- **Separate VM for sensitive or client work**: `lab vm new client-x`, then
  `lab project new client-x --vm client-x`.
- Toolchains are pinned per repo in `mise.toml`.

Workspace layout in the VM: `~/work/<org>/<repo>/main` (clone) and `~/work/<org>/<repo>/wt-<branch>` (tasks).

## CI and merging

Every push to a PR runs `.gitea/workflows/ci.yml` on the runner in the `ci` VM. Each job is a
separate check, and **all checks in `REQUIRED_CHECKS` must be green before a PR can be merged**,
even by the admin.

| Check | Runs | Defined by |
|---|---|---|
| `lint` | `make lint` | the project (agents fill in the Makefile) |
| `unit` | `make test-unit` | the project |
| `integration` | `make test-integration`, with Floci as fake AWS | the project |
| `e2e` | `make test-e2e`, with Floci | the project |
| `guard` | test + pipeline integrity | **humans only**: `platform/checks` |
| `security` | gitleaks + trivy | **humans only**: `platform/checks` |

- **Day to day**: an agent pushes a branch and opens a PR; you review it in Gitea and merge once
  it's green. Only the admin can merge. The admin can also push to `main` directly, which skips
  the checks; that's your escape hatch.
- **`guard`** fails agent PRs (by `bot-*`) that change `.gitea/` or scanner ignore files, delete
  test files, reduce the number of tests, or add skip/only markers or coverage/security exclusions
  (`pytest.mark.skip`, `it.only`, `pragma: no cover`, `nosec`…). Lint suppressions only warn. Your
  own PRs are not enforced, so pipeline changes go through a normal PR.
- **`security`** fails on secrets in the PR's commits (gitleaks) and on HIGH/CRITICAL vulnerable
  dependencies, misconfigurations and secrets in files (trivy). Tool versions are pinned and their
  checksums verified. To accept a finding, add it to `.trivyignore` / `.gitleaksignore` yourself.
- **Where the human-owned checks live**: `checks/` in this repo is the source. `lab checks publish`
  copies it to the Gitea repo `platform/checks` and moves tag `v1`. Bots have no access to the
  `platform` org; the CI runner reads it with a read-only `checks-reader` token that is only in
  the runner's own git config. Details: `checks/README.md`.
- **Adding a stage** (perf, more security…): add the job to the workflow (or, if it must be
  human-owned, to `checks/` + `lab checks publish`), add it to `REQUIRED_CHECKS` in `config.env`,
  then run `lab project protect <org>`. Template changes only affect new projects; copy the job
  into existing repos' `ci.yml`.
- **Limits**: this stops agents cutting corners, not an agent set on cheating. Such an agent could
  rewrite `ci.yml` to fake a `guard` job; that change shows in the diff, and the real `guard`
  flags it. Agents can also weaken assertions inside tests, so review test diffs.

## Security model

- **Trusted**: the host, Gitea, and `.secrets/` (git-ignored; back it up).
- **Untrusted, disposable**: every VM. Agents can have `sudo` and loose permissions there.
  If a VM breaks, roll back a snapshot or `destroy` and recreate it in a few minutes.
- VMs reach the internet and the host's ports 53/67/3000/2222/5000/11434 only. Your LAN
  (`192.168.0.0/16` and other private ranges) is blocked by `host/firewall.sh`.
- No host folders are shared with VMs. Code moves only through git.
- Put AI-provider API keys only inside VMs. Never use your personal SSH keys or real cloud credentials there.

## Repository layout

```
lab                       CLI entry point
config.env.example        all settings (override in config.env)
lib/                      shared bash helpers
host/                     host setup: packages, libvirt network/pool, nftables, NVIDIA
services/                 compose.yml (Gitea, Postgres, registry mirror, Ollama), bootstrap, backup
vm/build-golden.sh        golden image build
vm/new-vm.sh, vm/vmctl.sh VM lifecycle
vm/provision/             scripts run inside VMs by cloud-init (golden, agent, ci)
vm/tools/agt              worktree + tmux task helper (installed in VMs)
projects/new-project.sh   Gitea org/bot/repo + VM credentials
projects/protect.sh       main branch protection + required CI checks
projects/publish-checks.sh  publish checks/ to platform/checks + runner read access
projects/template/        skeleton for new repos (AGENTS.md, CLAUDE.md, mise, direnv, Floci, CI)
checks/                   human-owned CI checks (guard, security) used by every project
```

## Status

Verified end to end on Debian 13 (kernel 7.2), Gitea 28.4, gitea-runner 6.0.0:
golden image build, `agent` + `ci` VMs (UEFI boot, internal snapshots), project creation, bot
push/PR flow with `main` protected, all six CI checks (including Floci, `guard` and `security`),
merges blocked by failing checks, and the firewall (LAN blocked, internet allowed).

Notes and not yet verified:
- VMs boot with UEFI: on this host, SeaBIOS guests reset-loop right after GRUB.
- A `ci` VM created *after* `lab checks publish` gets the checks token through cloud-init; that
  path hasn't run yet. If `guard` can't download `platform/checks`, run `lab checks publish`.
- `floci/floci:latest` is not pinned yet. Pin a version once you depend on its behaviour.

## Ideas / next steps

- More human-owned checks: semgrep (static analysis), coverage threshold, perf tests
- Pull-through caches for npm (Verdaccio) and PyPI (devpi)
- Optional k3s in the CI VM as a "deploy" target
- Caddy/Traefik in the agent VM for `https://<app>.<project>.test`
