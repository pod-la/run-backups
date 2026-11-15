# run-backups

`run-backups.sh` is a small shell wrapper that scans a parent directory, finds child directories containing a `backup.sh` script, and runs each one in turn.

It is designed for environments where each service or application lives in its own directory and each one has its own backup process. Instead of manually running a backup in every folder, you run one command and the wrapper handles the rest.

## What it does

When you launch the script, it:

- looks under a configured base directory (default: `/docker`)
- finds every subdirectory that contains a matching backup script
- runs each script from inside that subdirectory
- writes the output to a log directory such as `backup_logs/`
- tracks which jobs succeeded or failed
- reports a summary at the end
- optionally sends notifications through Gotify and/or ntfy

The wrapper is intentionally resilient:

- it keeps going even if one backup fails
- a failed backup does not stop other backups from running
- it logs each backup separately so you can inspect what happened later

## Typical layout

Example directory structure:

```text
/docker/
  app-one/
    backup.sh
    backup_logs/
  app-two/
    backup.sh
    backup_logs/
  app-three/
    backup.sh
    backup_logs/
```

If `run-backups.sh` is pointed at `/docker`, it will discover `app-one`, `app-two`, and `app-three`, run each `backup.sh`, and store logs under each directory's `backup_logs` folder.

## Configuration

The script uses a YAML config file for notifications. A sample config is included at `run-backups.example.yaml`.

By default it looks for:

```text
~/.config/run-backups/config.yaml
```

You can override this with `-c`.

Example structure:

```yaml
notify:
  on: always

gotify:
  enabled: true
  url: https://gotify.example.com
  token: YOUR_TOKEN

ntfy:
  enabled: true
  url: https://ntfy.example.com
  topic: docker-backups
```

The config file is expected to hold secret tokens, so it should be locked down with restrictive permissions, for example:

```bash
chmod 600 ~/.config/run-backups/config.yaml
```

## Usage

```bash
./run-backups.sh
```

Common options:

```bash
./run-backups.sh -d /docker
./run-backups.sh -s backup.sh
./run-backups.sh -l backup_logs
./run-backups.sh -c /path/to/config.yaml
./run-backups.sh -n
```

### Flags

- `-d DIR`: base directory to scan
- `-s NAME`: backup script filename to look for in each directory
- `-l NAME`: log subdirectory name
- `-c FILE`: config file path
- `-n`: dry run; show what would happen without running anything
- `-h`: show help

## Dry run

Use dry run to check what the script would find and execute without actually running backups:

```bash
./run-backups.sh -n
```

This prints the matching directories and the log paths, but does not execute the backup scripts or send notifications.

## Notification support

The wrapper can send a summary after the run using:

- Gotify
- ntfy

This is controlled by the YAML config and by `notify.on`:

- `always`: send a notification for every run
- `error`: send only when one or more backups fail

## Exit behavior

The wrapper always exits successfully (`exit 0`) after processing so that one failed backup does not break the overall run. If you prefer monitoring tools to notice failures, you can change the final line to return a non-zero exit when any backup failed.

## Why use it

This script is useful when you have a collection of independent backup tasks and want a single scheduler-friendly entry point to run them consistently, log them neatly, and get a summary without manually scripting each directory.
