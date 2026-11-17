#!/usr/bin/env bash
# Dump Gitea (repos + DB + config) to $BACKUP_DIR, keeping the last $BACKUP_KEEP dumps.
# Cron example (daily 03:00):  0 3 * * *  /path/to/agentlab/lab services backup >/dev/null
source "$(dirname "$0")/../lib/common.sh"
cd "$LAB_ROOT/services"

ts=$(date +%Y%m%d-%H%M%S)
name="gitea-dump-$ts.tar.gz"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

log "Dumping Gitea to $BACKUP_DIR/$name"
dk compose exec -T -u git -w /tmp gitea gitea dump --type tar.gz --file "/tmp/$name" >/dev/null
dk compose cp "gitea:/tmp/$name" "$BACKUP_DIR/$name"
dk compose exec -T -u git gitea rm -f "/tmp/$name"
cp -a "$SECRETS_DIR" "$BACKUP_DIR/secrets-$ts"

# rotate
ls -1t "$BACKUP_DIR"/gitea-dump-*.tar.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
ls -1dt "$BACKUP_DIR"/secrets-* 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -rf
log "Backup done"
