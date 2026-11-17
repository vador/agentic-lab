# platform/checks

Human-owned checks that every project's CI runs as required jobs. Bot users (agents) have no access
to the `platform` organization, so they cannot change what these checks enforce.

**Source of truth:** `checks/` in the agentlab repo. Publish with `lab checks publish` (moves tag `v1`).
Don't edit `platform/checks` directly; the next publish overwrites it.

## Use in a project workflow

```yaml
  guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: <gitea-url>/platform/checks@v1
        with: { mode: guard }        # or: security
```

## `guard`: test and pipeline integrity (PRs by `bot-*` users)

Fails when an agent's PR:
- changes a human-only path: `.gitea/**`, `.trivyignore`, `trivy.yaml`, `.gitleaksignore`, `.gitleaks.toml`
- deletes a test file
- reduces the number of tests (counted with simple per-language patterns)
- adds a skipped or focused test (`pytest.mark.skip`, `it.skip`, `it.only`, `xit`, `t.Skip()`, `@Disabled`…)
- adds a coverage or security exclusion (`pragma: no cover`, `istanbul ignore`, `nosec`, `gitleaks:allow`, `trivy:ignore`, `nosemgrep`)

Warns (doesn't fail) on lint/type suppressions (`noqa`, `eslint-disable`, `@ts-ignore`…) and on
test/coverage config changes. Look for these warnings in the job log when reviewing.

PRs by humans only get the summary. A human who needs to do something the guard forbids opens
the PR themselves.

## `security`: secrets, vulnerable dependencies, misconfigurations

- **gitleaks** scans the PR's commits for secrets (the whole tree on pushes to main).
- **trivy fs** scans for HIGH/CRITICAL vulnerabilities with a fix available, IaC/Dockerfile
  misconfigurations, and secrets in files.

Tool versions are pinned and their SHA-256 checksums are verified (`bin/security.sh`).
To accept a finding, a human adds it to `.trivyignore` / `.gitleaksignore`. Agents can't: those are
human-only paths.
