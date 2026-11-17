# Instructions for AI coding agents

## Workflow
- You are working in a git worktree on a feature branch. Never commit to `main`; you cannot push to it anyway.
- Make small, focused commits with clear messages. Push your branch, then open a PR:
  `tea pr create --login __ORG__ --title "..." --description "..."`
- Before pushing, run `make lint test` and make sure it passes.

## Environment
- Toolchain versions are pinned in `mise.toml` (`mise install` if a tool is missing).
- Cloud services are emulated locally — never use real cloud credentials:
  - AWS → Floci, started with `make up`. Endpoint is in `$AWS_ENDPOINT_URL` (set by `.envrc`), credentials are dummy.
- Each worktree has its own compose project and its own emulator port, so parallel tasks don't collide.

## Commands
- `make up` / `make down` — start/stop local emulators
- `make test` — run tests
- `make lint` — run linters

## Project notes
<!-- Describe architecture, conventions and gotchas here as the project grows. -->
