

Here are a few example commands:

**Wildcard mode (default) — upload all `.dat` files, move `.gz` to processed, delete originals:**
```bash
./pushtomft-cron-dev.sh -s /delphix/DeIdentified -u myuser -p 'mypassword'
```

**Explicit extension and SSH key auth:**
```bash
./pushtomft-cron-dev.sh -s /delphix/DeIdentified -u svc_account -x dat -k ~/.ssh/id_ed25519
```

**Single file mode:**
```bash
./pushtomft-cron-dev.sh -s /delphix/DeIdentified -u myuser -p 'mypassword' -m single -f CLAIM_HEADER_20260304.dat
```

**Dev environment with custom destination, keep files after upload:**
```bash
./pushtomft-cron-dev.sh -e dev -d /genius/test/inbound/ -s /delphix/DeIdentified -u myuser -p 'mypassword' -c keep
```

**Dry-run tip** — to verify argument parsing and file matching without actually uploading, you could temporarily add `exit 0` before the SFTP Upload section, or test on a dev environment first:
```bash
./pushtomft-cron-dev.sh -e dev -d /tmp/test/ -s /delphix/DeIdentified -u myuser -p 'mypassword' -x dat -c keep
```

### Flag quick reference

| Flag | Purpose | Default |
|------|---------|---------|
| `-s` | Source directory (required) | — |
| `-u` | SFTP username (required) | — |
| `-p` | SFTP password (or omit for SSH key) | — |
| `-k` | SSH private key path | `~/.ssh/id_ed25519` |
| `-e` | Environment: `prod` / `dev` | `prod` |
| `-d` | Destination dir (required for dev) | — |
| `-m` | Mode: `wildcard` / `single` | `wildcard` |
| `-x` | File extension to match | `dat` |
| `-f` | Filename (single mode only) | — |
| `-c` | Cleanup: `move` / `delete` / `keep` | `move` |
| `-P` | Base processed directory | `/delphix/DeIdentified/processed` |