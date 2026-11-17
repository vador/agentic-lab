# __REPO__

Project `__ORG__/__REPO__` — created by agentlab.

## Local development

```bash
direnv allow          # loads .envrc (AWS emulator endpoint, per-worktree compose project)
mise install          # toolchain pinned in mise.toml
make up               # start local emulators (Floci = AWS) for this worktree
make test
make down
```

CI runs on every push/PR via `.gitea/workflows/ci.yml` with Floci as a service container.
