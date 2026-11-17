#!/usr/bin/env bash
# Create (or complete) a project: Gitea org + restricted bot user + "agents" team + repo seeded
# from projects/template + main branch protection, then install the bot's credentials in a VM
# and clone the repo there. Idempotent: re-run it to add a repo or to set up another VM.
source "$(dirname "$0")/../lib/common.sh"
need curl jq git ssh-keygen

usage() {
  cat <<EOF
Usage: lab project new <org> [--repo NAME] [--vm VM] [--no-vm]

  <org>       project / client name (Gitea organization), lowercase
  --repo      repository name (default: same as org). Run again with another --repo to add repos.
  --vm        VM to install credentials + clone into (default: agent)
  --no-vm     only create things in Gitea

Agents act as user 'bot-<org>': restricted to this org, can push branches and open PRs,
cannot push to or merge into main ($GITEA_ADMIN_USER can).
EOF
}

org=${1:-}
[[ -n $org && $org != -* ]] || { usage; exit 1; }
shift
repo=$org vm=agent use_vm=1
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --vm) vm=$2; shift 2 ;;
    --no-vm) use_vm=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done
[[ $org =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] || die "invalid org '$org'"
[[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || die "invalid repo '$repo'"
ensure_secrets_dir

bot="bot-$org"
bot_email="$bot@$LAB_NAME.$LAB_DOMAIN"
pwf="$SECRETS_DIR/bots/$bot.password"
tokf="$SECRETS_DIR/bots/$bot.token"
keyf="$SECRETS_DIR/bots/$bot.ed25519"

# --- organization ---------------------------------------------------------------------------
if ! gitea_exists "/orgs/$org"; then
  log "Creating organization $org"
  gitea_api POST /orgs "$(jq -n --arg o "$org" '{username:$o, visibility:"private"}')" >/dev/null
fi

# --- bot user (restricted: only sees what its teams give it) ----------------------------------
if ! gitea_exists "/users/$bot"; then
  log "Creating bot user $bot"
  randpw >"$pwf"
  gitea_api POST /admin/users "$(jq -n --arg u "$bot" --arg e "$bot_email" --arg p "$(<"$pwf")" \
    '{username:$u, email:$e, password:$p, must_change_password:false, restricted:true, visibility:"private"}')" >/dev/null
  gitea_api PATCH "/admin/users/$bot" "$(jq -n --arg u "$bot" '{login_name:$u, source_id:0, restricted:true}')" >/dev/null ||
    warn "could not mark $bot as restricted — do it in Site Administration"
fi

# --- "agents" team with write access on all org repos ---------------------------------------
team_id=$(gitea_api GET "/orgs/$org/teams" | jq -r '.[] | select(.name == "agents") | .id')
if [[ -z $team_id ]]; then
  log "Creating team agents"
  team_id=$(gitea_api POST "/orgs/$org/teams" "$(jq -n '{
      name: "agents", description: "AI coding agents", permission: "write",
      includes_all_repositories: true, can_create_org_repo: false,
      units_map: {"repo.code":"write","repo.pulls":"write","repo.issues":"write","repo.actions":"read",
                  "repo.packages":"write","repo.wiki":"write","repo.releases":"read"}
    }')" | jq -r .id)
fi
gitea_api PUT "/teams/$team_id/members/$bot" >/dev/null

# --- human-owned checks used by the template's guard/security jobs ---------------------------------
if ! gitea_exists "/repos/$CHECKS_ORG/checks"; then
  "$LAB_ROOT/projects/publish-checks.sh"
fi

# --- repository, seeded from the template -----------------------------------------------------
if ! gitea_exists "/repos/$org/$repo"; then
  log "Creating repository $org/$repo"
  gitea_api POST "/orgs/$org/repos" "$(jq -n --arg r "$repo" '{name:$r, private:true, default_branch:"main", auto_init:false}')" >/dev/null
fi
if [[ $(gitea_api GET "/repos/$org/$repo" | jq -r .empty) == true ]]; then
  log "Seeding $org/$repo from projects/template"
  work=$(mktemp -d)
  cp -a "$LAB_ROOT/projects/template/." "$work/"
  find "$work" -type f -exec sed -i -e "s/__ORG__/$org/g" -e "s/__REPO__/$repo/g" -e "s/__DOMAIN__/$LAB_DOMAIN/g" -e "s|__GITEA_URL__|$GITEA_INTERNAL_URL|g" {} +
  git -C "$work" init -q -b main
  git -C "$work" add -A
  git -C "$work" -c user.name="$GITEA_ADMIN_USER" -c user.email="$GITEA_ADMIN_EMAIL" \
    commit -qm "Initial project skeleton (agentlab template)"
  git -C "$work" -c "http.extraHeader=Authorization: token $(gitea_token)" \
    push -q "$GITEA_API_URL/$org/$repo.git" main
  rm -rf "$work"
fi

# --- protect main: only the admin pushes/merges, required CI checks must pass ------------------
"$LAB_ROOT/projects/protect.sh" "$org" --repo "$repo"

# --- bot credentials: API token (for tea/PRs) + SSH key (for git) -----------------------------
if [[ ! -s $tokf ]]; then
  [[ -s $pwf ]] || die "missing $pwf; reset the bot password in Gitea and save it there"
  log "Creating API token for $bot"
  curl -sS --fail-with-body -u "$bot:$(<"$pwf")" -H 'Content-Type: application/json' \
    --data "$(jq -n --arg n "agentlab-$(date +%Y%m%d%H%M%S)" \
      '{name:$n, scopes:["write:repository","write:issue","write:package","read:user","read:organization"]}')" \
    "$GITEA_API_URL/api/v1/users/$bot/tokens" | jq -r .sha1 >"$tokf"
  chmod 600 "$tokf"
fi
if [[ ! -f $keyf ]]; then
  log "Creating SSH key for $bot"
  ssh-keygen -q -t ed25519 -N '' -C "$bot@$LAB_NAME" -f "$keyf"
  gitea_api POST "/admin/users/$bot/keys" "$(jq -n --arg k "$(<"$keyf.pub")" '{title:"agentlab", key:$k, read_only:false}')" >/dev/null
fi

# --- install into the VM --------------------------------------------------------------------------
if ((use_vm)); then
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$vm" true 2>/dev/null; then
    warn "VM '$vm' not reachable — Gitea side is done. Re-run later: lab project new $org --repo $repo --vm $vm"
    exit 0
  fi
  log "Installing $bot credentials in VM '$vm'"
  scp -q "$keyf" "$vm:.ssh/agentlab/$bot"
  ssh "$vm" "chmod 600 ~/.ssh/agentlab/$bot && cat > ~/.ssh/config.d/agentlab-$org" <<EOF
Host gitea-$org
  HostName gitea.$LAB_DOMAIN
  Port $GITEA_SSH_PORT
  User git
  IdentityFile ~/.ssh/agentlab/$bot
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  ssh "$vm" "cat > ~/.gitconfig-$org" <<EOF
[user]
	name = $bot
	email = $bot_email
EOF
  ssh "$vm" "git config --global --get-all 'includeIf.gitdir:~/work/$org/.path' >/dev/null ||
             git config --global --add 'includeIf.gitdir:~/work/$org/.path' '~/.gitconfig-$org'"
  ssh "$vm" "tea login delete '$org' >/dev/null 2>&1 || true
             tea login add --name '$org' --url '$GITEA_INTERNAL_URL' --token \"\$(cat)\" >/dev/null" <"$tokf"
  ssh "$vm" "test -d ~/work/$org/$repo/main/.git || git clone -q gitea-$org:$org/$repo.git ~/work/$org/$repo/main"
fi

cat <<EOF

Project ready: $org/$repo
  Web:        $GITEA_INTERNAL_URL/$org/$repo
  Host clone: git clone gitea.$LAB_DOMAIN:$org/$repo.git
EOF
if ((use_vm)); then
  cat <<EOF
  In '$vm':   ~/work/$org/$repo/main   — start a task: ssh $vm -t agt new $( [[ $repo == "$org" ]] && echo "$org" || echo "$org/$repo" ) feat/first-task
  PRs:        tea pr create --login $org --repo $org/$repo   (from inside a worktree)
EOF
fi
