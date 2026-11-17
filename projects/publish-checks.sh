#!/usr/bin/env bash
# Publish checks/ to the human-owned Gitea repo platform/checks and move its major tag.
# Projects use it as: uses: <gitea>/platform/checks@v1   (see checks/README.md)
# The "platform" org has no bot members, so agents can neither read nor change the checks.
# The CI runner fetches the action with a read-only account (checks-reader) whose token sits only
# in the runner's own git config on the CI VM: jobs never see it.
source "$(dirname "$0")/../lib/common.sh"
need curl jq git

tag=v1 ci_vm=ci
while (($#)); do
  case $1 in
    --tag) tag=$2; shift 2 ;;
    --ci-vm) ci_vm=$2; shift 2 ;;
    -h | --help) echo "Usage: lab checks publish [--tag v1] [--ci-vm ci]"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done
[[ $tag =~ ^v[0-9]+$ ]] || die "tag must look like v1, v2…"
org=$CHECKS_ORG repo=checks

if ! gitea_exists "/orgs/$org"; then
  log "Creating organization $org (humans only)"
  gitea_api POST /orgs "$(jq -n --arg o "$org" '{username:$o, visibility:"private"}')" >/dev/null
fi
if ! gitea_exists "/repos/$org/$repo"; then
  log "Creating repository $org/$repo"
  gitea_api POST "/orgs/$org/repos" "$(jq -n --arg r "$repo" \
    '{name:$r, private:true, default_branch:"main", auto_init:false, description:"Human-owned CI checks (published from agentlab)"}')" >/dev/null
fi

# --- read-only account the CI runner uses to download the action ------------------------------
ensure_secrets_dir
reader=checks-reader
rpw="$SECRETS_DIR/$reader.password" rtok="$SECRETS_DIR/$reader.token"
if ! gitea_exists "/users/$reader"; then
  log "Creating read-only user $reader"
  randpw >"$rpw"; chmod 600 "$rpw"
  gitea_api POST /admin/users "$(jq -n --arg u "$reader" --arg e "$reader@$LAB_NAME.$LAB_DOMAIN" --arg p "$(<"$rpw")" \
    '{username:$u, email:$e, password:$p, must_change_password:false, restricted:true, visibility:"private"}')" >/dev/null
fi
team_id=$(gitea_api GET "/orgs/$org/teams" | jq -r '.[] | select(.name == "readers") | .id')
if [[ -z $team_id ]]; then
  team_id=$(gitea_api POST "/orgs/$org/teams" "$(jq -n '{name:"readers", description:"CI runner: read checks",
      permission:"read", includes_all_repositories:true, can_create_org_repo:false, units_map:{"repo.code":"read"}}')" | jq -r .id)
fi
gitea_api PUT "/teams/$team_id/members/$reader" >/dev/null
if [[ ! -s $rtok ]]; then
  [[ -s $rpw ]] || die "missing $rpw; reset $reader's password in Gitea and save it there"
  curl -sS --fail-with-body -u "$reader:$(<"$rpw")" -H 'Content-Type: application/json' \
    --data "$(jq -n --arg n "runner-$(date +%Y%m%d%H%M%S)" '{name:$n, scopes:["read:repository"]}')" \
    "$GITEA_API_URL/api/v1/users/$reader/tokens" | jq -r .sha1 >"$rtok"
  chmod 600 "$rtok"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
auth=(-c "http.extraHeader=Authorization: token $(gitea_token)")
url="$GITEA_API_URL/$org/$repo.git"
if [[ $(gitea_api GET "/repos/$org/$repo" | jq -r .empty) == true ]]; then
  git -C "$work" init -q -b main
else
  git "${auth[@]}" clone -q "$url" "$work"
fi
find "$work" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -a "$LAB_ROOT/checks/." "$work/"
git -C "$work" add -A
src=$(git -C "$LAB_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
dirty=$(git -C "$LAB_ROOT" status --porcelain -- checks 2>/dev/null | head -1)
if git -C "$work" diff --cached --quiet && git -C "$work" rev-parse -q --verify HEAD >/dev/null; then
  log "platform/checks already up to date"
else
  git -C "$work" -c user.name="$GITEA_ADMIN_USER" -c user.email="$GITEA_ADMIN_EMAIL" \
    commit -qm "Publish checks from agentlab $src${dirty:+ (+ uncommitted changes)}"
  git "${auth[@]}" -C "$work" push -q "$url" main
fi
git -C "$work" tag -f "$tag" >/dev/null
git "${auth[@]}" -C "$work" push -q -f "$url" "refs/tags/$tag"
log "Published $org/$repo@$tag ($(git -C "$work" rev-parse --short HEAD))"

# --- give the CI runner read access to the checks ---------------------------------------------
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$ci_vm" true 2>/dev/null; then
  ssh "$ci_vm" "sudo git config --file /var/lib/gitea-runner/.gitconfig \
      'http.$GITEA_INTERNAL_URL/$org/.extraHeader' \"Authorization: token \$(cat)\" &&
    sudo chown gitea-runner: /var/lib/gitea-runner/.gitconfig && sudo chmod 600 /var/lib/gitea-runner/.gitconfig" <"$rtok"
  log "Runner in VM '$ci_vm' can read $org/*"
else
  warn "CI VM '$ci_vm' not reachable: re-run 'lab checks publish --ci-vm <vm>' once it is up"
fi
