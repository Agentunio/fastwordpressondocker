# Fast WordPress on Docker

A disposable local WordPress environment with a restorable base-state snapshot (**state-0**). Clone it, run `./start.sh` or `docker compose up -d`, and about a minute later you have a fully installed WordPress with an admin account, plugins and phpMyAdmin — no install wizard, no manual configuration.

Built for plugin/theme testing and site-migration workflows: break things freely, then restore the base state with a single command.

## What's inside

| Service | Image | Default URL |
|---|---|---|
| WordPress | **latest stable** core ensured on every container start (base image `wordpress:php8.3-apache` + wp-cli 2.12.0, custom build) | http://localhost |
| MariaDB | `mariadb:11.8` | — |
| phpMyAdmin | `phpmyadmin:5.2.2` | http://localhost:8080 |

## Requirements

- Docker Desktop (macOS / Windows) or Docker Engine with Compose v2 (Linux)
- macOS / Linux → use the `.sh` wrappers, Windows → use the `.ps1` wrappers (PowerShell)

## Quick start

Use this repository as a GitHub template, create your own project repository.

If you only want the files in the current folder without creating a Git repository:

```bash
curl -L https://github.com/Agentunio/fastwordpressondocker/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
./start.sh
```

Without interactive setup
```bash
curl -L https://github.com/Agentunio/fastwordpressondocker/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
docker compose up -d
```

`./start.sh` (macOS / Linux) and `./start.ps1` (Windows) let you choose:

1. `Default settings` (on later runs: `Current settings (…)` — keeps the values already in `.env`)
2. `Custom settings`

In `Custom settings`, choose:

- PHP image version: first `Standard (PHP 8.3)`, then PHP `8.1`, `8.2`, `8.4` and `8.5`.
- Optional plugins: `All-in-One WP Migration`, `UpdraftPlus` and `Advanced Custom Fields` can be selected together, or leave `None`.
- WordPress port: `Standard (80)` or a custom port.
- phpMyAdmin port: `Standard (8080)` or a custom port.

The WordPress URL is generated automatically from the selected WordPress port.

If you do not need the interactive setup, `docker compose up -d` still uses standard PHP `8.3`, WordPress port `80` and phpMyAdmin port `8080`.

The first start takes about a minute and is fully automated:

1. Builds the image (official WordPress image + wp-cli) and pulls MariaDB / phpMyAdmin.
2. Downloads and installs the **latest** WordPress core — no install wizard. Core auto-updates are disabled, so the version stays frozen in state-0.
3. Installs the default theme and the configured plugins (see [Plugins](#plugins)).
4. Removes WordPress's default Akismet and Hello Dolly plugins.
5. Saves the initial **state-0** snapshot into `snapshots/`.

Once it's done:

| | URL | Credentials |
|---|---|---|
| Site | http://localhost | — |
| Admin | http://localhost/wp-admin | `admin_qmpgfd` / `R40U8zp17YlwvQNkDEKgnhx2!@#` |
| phpMyAdmin | http://localhost:8080 | logs in automatically (DB user `wp` / `wp`) |

> These are the default **local development credentials**. Choose `Custom settings` in `./start.sh` or `./start.ps1` to configure a different administrator.

Every subsequent `docker compose up -d` starts instantly and re-applies the `.env` settings (site URL, optional plugins and administrator).

## Commands

> macOS / Linux → `./reset.sh`, `./snapshot.sh`
> Windows → `./reset.ps1`, `./snapshot.ps1`
>
> Both variants do exactly the same thing — they are thin wrappers around the same `scripts/*.sh` executed inside the container.

### `./reset.sh` — restore state-0

Rolls everything back (database + `wp-content` + `wp-config.php` + WordPress core version) to the state saved as **state-0**. The next container start updates the core to the latest stable version; the snapshot itself stays unchanged.

### `./snapshot.sh` — overwrite state-0

Saves the **current** WordPress state as the new state-0. Use it when you deliberately change the base state — e.g. you added a plugin or theme that should be part of the starting point from now on.

Under the hood: `docker compose exec -T wordpress bash /scripts/snapshot.sh`

### Starting over

```bash
# Re-provision from your existing state-0 (snapshots survive volume wipes):
docker compose down -v && docker compose up -d

# Full factory reset — wipe the snapshot and wp-content too, then fresh install:
docker compose down -v
rm -rf snapshots/state-0* wp-content/*
docker compose up -d
```

## Running multiple copies in parallel

Every clone of this repo is an independent environment. Docker Compose uses the checkout directory as the project name, so containers and volumes get that folder as their prefix (for example `client-site-wordpress-1`, `client-site-db_data`). To run a second copy next to the first one, clone it into a different folder and give it its own ports:

```bash
./start.sh
```

Choose `Custom settings`, then pick custom WordPress and phpMyAdmin ports. The wrapper writes `.env` for you, including a matching `WORDPRESS_URL`, which is re-applied to `home`/`siteurl` on every container start — an existing installation adapts to new ports automatically.

## Plugins

On a fresh install `scripts/init.sh` installs and activates:

- the optional plugins selected in `./start.sh` / `./start.ps1`: **All-in-One WP Migration**, **UpdraftPlus**, **Advanced Custom Fields** or none
- every `*.zip` found in `plugins/` (premium / custom plugins), also synced on later starts and resets

The optional plugins can be changed later: run `./start.sh` again and adjust the selection — selected plugins get installed and unselected managed optional plugins are removed automatically. state-0 still contains the old choice — run `./snapshot.sh` if the new selection should become part of the base state.

To add a plugin → drop its ZIP into `plugins/`. It gets installed on fresh installs, later starts and resets.

> `plugins/*` is gitignored on purpose — licensed/premium ZIPs stay on your machine and never end up in the repository.

WordPress's default plugins (Akismet, Hello Dolly) are removed automatically on fresh install and before every snapshot.

## How it works

| Script | Runs when | What it does |
|---|---|---|
| `start.sh` / `start.ps1` | manual start / reconfigure | asks for current/custom PHP, plugins, administrator and ports, writes them into `.env`, starts Compose and rebuilds only when PHP changes |
| `scripts/entrypoint.sh` | container start | starts `init.sh` in the background, hands control to the official WP entrypoint |
| `scripts/init.sh` | container start (background) | WP already installed → sync site URL + optional plugins from `.env` + local plugin ZIPs. Snapshot exists → restore it. Otherwise → fresh install + plugins + save state-0 |
| `scripts/reset.sh` | `./reset.sh` / `./reset.ps1` | resets the DB, restores `wp-content` + `wp-config.php` + the core version from the snapshot, then syncs local plugin ZIPs |
| `scripts/snapshot.sh` | `./snapshot.sh` / `./snapshot.ps1` | exports the DB, archives `wp-content`, copies `wp-config.php` into `snapshots/` |
| `scripts/apply-optional-plugin.sh` | called by init/reset | installs selected optional plugins and removes unselected managed optional plugins |
| `scripts/install-local-plugins.sh` | called by init/reset | installs and activates every ZIP from `plugins/` |
| `scripts/remove-default-plugins.sh` | called by init/snapshot | deletes Akismet & Hello Dolly if present |
| `scripts/default-admin-guardian.php` | after every local WordPress request | restores the default administrator after a database import; it lives outside WordPress and is not included in site exports |

A state-0 snapshot is four files in `snapshots/` (generated locally, gitignored):

```
state-0.sql                  # full database dump
state-0-wp-content.tar.gz    # wp-content (plugins, themes, uploads)
state-0-wp-config.php        # wp-config.php
state-0-core-version         # WordPress core version at snapshot time
```

WordPress core and the database live in named Docker volumes (`wp_data`, `db_data`). `wp-content/` is bind-mounted from the repo directory, so you can edit themes and plugins directly from your IDE on the host.

## Project structure

```
docker-compose.yml          # services: db (MariaDB 11), wordpress (custom build), phpmyadmin
Dockerfile                  # wordpress:php${PHP_VERSION}-apache + pinned wp-cli + mariadb-client
scripts/
  entrypoint.sh             # custom container entrypoint
  init.sh                   # first install / restore from state-0
  reset.sh                  # restore state-0
  snapshot.sh               # save the current state as state-0
  remove-default-plugins.sh # delete Akismet & Hello Dolly
plugins/                    # premium plugin ZIPs (gitignored, local only)
snapshots/                  # state-0.* files (gitignored, generated locally)
wp-content/                 # live wp-content of the running site (gitignored)
start.sh / start.ps1        # interactive host wrappers (macOS+Linux / Windows)
reset.sh / reset.ps1        # host wrappers (macOS+Linux / Windows)
snapshot.sh / snapshot.ps1  # host wrappers (macOS+Linux / Windows)
```

## Typical workflow

1. `./start.sh` or `docker compose up -d` — the first run installs everything and saves state-0.
2. Click around, test plugins, import a site with your selected migration/backup plugin, break things.
3. `./reset.sh` — back to state-0 in seconds.
4. Want a different starting point? Set the site up the way you like and run `./snapshot.sh`.
5. Repeat.

**Port 80 (or 8080) is already in use**

Run `./start.sh`, choose `Custom settings`, and pick free ports.

**The site redirects to `http://localhost` without your custom port**

Run `./start.sh` again and choose the WordPress port. The wrapper updates `WORDPRESS_URL` and restarts the container, which re-applies it automatically — no `./reset.sh` needed.
