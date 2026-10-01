# Backups and restore

SRS DB-11 to DB-13: daily backups kept for 90 days, weekly backups kept for a
year, and a restore that has actually been tested.

## What is kept, and where

| Copy | What | When | Kept | Where |
|---|---|---|---|---|
| Disk snapshot | The whole 300 GB disk, crash-consistent | Daily 18:00 UTC | 90 days | GCP snapshots, schedule `ceynex-daily-90d` |
| Daily logical backup | Every datastore, the model registry, raw data, encrypted config | Daily 02:00 UTC | 90 days | `gs://<project-id>-backups/daily/<stamp>/` |
| Weekly logical backup | The Sunday run, copied | Sundays | 365 days | `gs://<project-id>-backups/weekly/<stamp>/` |
| Local copy | The same runs | Daily | 7 days | `~/backups/<stamp>/` on the VM |
| Policy corpus PDFs | The 39 source documents behind `ceynex_policy` | Once | No expiry | `gs://<project-id>-backups/archive/` |

The logical backup is `ops/backup.sh`. Each run holds:

| File | Restores |
|---|---|
| `ceynex-postgres.dump` | Postgres, with `pg_restore` |
| `ceynex-neo4j.cypher` | Neo4j, piped into `cypher-shell` |
| `ceynex_policy.snapshot`, `ceynex_news.snapshot` | Qdrant, by snapshot upload |
| `models_data.tgz`, `dataset_data.tgz` | The backend volumes |
| `config.tar.gz.gpg` | The three `.env` files, Let's Encrypt state, crontabs, `renew-cert.sh` |
| `manifest.json` | The counts a restore must reproduce |
| `SHA256SUMS` | Every file above |

**The passphrase for `config.tar.gz.gpg` is in the team password manager.** A
copy on the VM alone would be lost with the disk.

Two things are deliberately not backed up:
- `backend_fastembed_cache`: ONNX models, downloaded again on the first policy query.
- `db_redis_data`: rate-limit windows and turn mirrors, all of them minutes old.

The bucket is writable by the VM's service account (`ceynex-vm`), but that
account can neither delete nor overwrite an object. Only the lifecycle rules
delete, so a compromised VM cannot remove its own backups. Setup:
`gcp/02_backup_setup.sh`.

## Restoring

Three cases, fastest first. Each ends with the same checks.

### The VM is gone, or its disk is unusable: from a snapshot

At most a day old, and nothing to reassemble.

```bash
gcloud compute snapshots list --sort-by=~creationTimestamp --limit=3
gcloud compute disks create ceynex-restored --zone asia-south1-b --source-snapshot <snapshot>
# A VM like the old one (c4-standard-4, tags http-server https-server ssh) with
# that disk as its boot disk and the reserved address ceynex-ip, so ceynex.cc
# needs no DNS change.
```

### A logical restore from the bucket

Use this for a fresh VM, or when the newest snapshot is older than what was
lost.
1. Download a run: `gcloud storage cp -r gs://<bucket>/daily/<stamp> .`, then run `sha256sum -c SHA256SUMS` inside the folder.
2. Decrypt the config: `gpg -d config.tar.gz.gpg | tar xzf -`. Put the three `.env` files in place.
3. Start the data tier from `ceynex-infra/database`. **Keep the project names `db` and `backend`:** compose derives volume names from them, and a different name restores into volumes nothing reads.
4. Restore each store with the same commands `ops/restore-drill.sh` uses, but against the production containers:
   - Postgres: `pg_restore --clean --if-exists`.
   - Neo4j: `cypher-shell < ceynex-neo4j.cypher`.
   - Qdrant: snapshot upload.
   - Volumes: `tar xzf` into `backend_models_data` and `backend_dataset_data`.

### One store is damaged

Restore only that store, from the newest local run, with its line from step 4.

### After any restore

- `https://ceynex.cc/health` reports `status: ok`, with `fact_trade_rows` equal to the manifest's `postgres_rows.fact_trade`.
- Ask for a forecast and check it does **not** say "drift baseline". An empty model registry looks exactly like a working one.
- Sign in, ask one question, and check the evidence panel lists sources.

## The drill (DB-13)

Run it quarterly, and after any change to `ops/backup.sh`. It uses a disposable
VM, never the production one:

```bash
gcloud compute instances create ceynex-restore-drill --zone asia-south1-b \
  --machine-type e2-standard-2 --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size 30GB --scopes storage-ro
gcloud compute ssh ceynex-restore-drill --zone asia-south1-b --tunnel-through-iap
#   on it: install docker (gcp/00_install_docker.sh), clone ceynex-infra, then
#   BACKUP_BUCKET=<bucket> ceynex-infra/ops/restore-drill.sh
gcloud compute instances delete ceynex-restore-drill --zone asia-south1-b
```

The drill:
1. Downloads the newest run and checks the checksums.
2. Restores Postgres, Neo4j and Qdrant into a throwaway stack (`ops/restore-drill.compose.yml`).
3. Checks the volume archives list end to end.
4. Decrypts the config, if given `BACKUP_PASSPHRASE_FILE`.
5. Recomputes every count in `manifest.json`: rows per table, the upsert key, nodes per label, relationships per type, constraints, and Qdrant points.

It exits 0 only if they all match.

`DRILL_FROM=<run directory>` restores a local copy instead, with no bucket
involved.

| Date | Backup restored | Where | Result |
|---|---|---|---|
| 2026-10-01 | A run of `ops/backup.sh` against the local dev stack | Workstation, `DRILL_FROM` | All counts matched (19 tables, 6 labels, 6 relationship types, 7 constraints, both collections); config decrypted |
