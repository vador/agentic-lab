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
| `agt new\|ls\|rm\|attach` (inside VM) | One worktree + one tmux window per agent task |

## Multiple projects

- **One Gitea org per project or client.** `lab project new` creates the org, a **restricted bot user**
  `bot-<org>` (it only sees this org), an `agents` team with write access, and the repo, seeded from
  `projects/template/`. It also protects `main`: only the admin (you) can push to or merge into
  `main`, so agents must open PRs (`tea pr create --login <org> --repo <org>/<repo>`).
- **Mandatory CI**: the template's workflow runs `lint`, `unit`, `integration` and `e2e` as separate
  jobs (`make lint`, `make test-unit`, `make test-integration`, `make test-e2e`; Floci runs as a service
  for the last two). Every check in `REQUIRED_CHECKS` must be green before a PR can be merged, and
  even the admin cannot override that. To add perf or other stages, add the job to the workflow,
  add it to `REQUIRED_CHECKS`, and run `lab project protect <org>`.
- **Human-owned checks**: the `guard` and `security` jobs run an action from `platform/checks`, a
  Gitea repo that agents can neither read nor change. The CI runner reads it with a read-only
  account whose token is only in the runner's git config. `guard` fails agent PRs that touch
  `.gitea/` or scanner ignore files, delete tests, reduce the number of tests, or add skip/only
  markers or coverage/security exclusions. `security` runs gitleaks (secrets in the PR's commits)
  and trivy (HIGH/CRITICAL vulnerable dependencies, misconfigurations, secrets), with pinned and
  checksum-verified versions. The source is `checks/` in this repo; edit it, then
  `lab checks publish`. Details: `checks/README.md`.
- Limits: this stops agents cutting corners, not an agent set on cheating. Such an agent could
  rewrite `ci.yml` to fake a `guard` job; that change would show in the diff, and the real `guard`
  would flag it. Agents can also still weaken the assertions inside tests, so review test diffs.
- **Per-project identity in the VM**: there's an SSH alias `gitea-<org>` with the bot's key, a git
  `includeIf` for `~/work/<org>/`, and a `tea` login named `<org>`. A leaked credential only gives
  access to one project.
- **Per-worktree isolation**: the template's `.envrc` sets a unique `COMPOSE_PROJECT_NAME` and
  Floci port for each worktree, so parallel agents never collide.
- **Separate VM for sensitive or client work**: `lab vm new client-x`, then
  `lab project new client-x --vm client-x`.
- Toolchains are pinned per repo in `mise.toml`.

Workspace layout in the VM: `~/work/<org>/<repo>/main` (clone) and `~/work/<org>/<repo>/wt-<branch>` (tasks).

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
checks/                   human-owned CI checks (guard, security) used by every project
projects/template/        skeleton for new repos (AGENTS.md, CLAUDE.md, mise, direnv, Floci, CI)
```

## Status / to verify on first run

These scripts have been syntax-checked and their pure parts tested, but they have **not yet been run
end-to-end**. Points to watch on the first run:

- `gitea-runner` 6.0.0 (formerly act_runner) is assumed to keep the `generate-config` / `register` /
  `daemon` subcommands.
- The Gitea image tag `docker.gitea.com/gitea:28.4.0` (see `GITEA_IMAGE`).
- Docker's `ip-forward-no-drop` daemon option needs Docker Engine ≥ 28.
- `floci/floci:latest` is not pinned yet. Pin a version once things work.

## Ideas / next steps

- Pull-through caches for npm (Verdaccio) and PyPI (devpi)
- Optional k3s in the CI VM as a "deploy" target
- Caddy/Traefik in the agent VM for `https://<app>.<project>.test`
