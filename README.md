# Fast WordPress on Docker

A disposable local WordPress environment with a restorable base-state snapshot (**state-0**). Clone it, run `docker compose up -d`, and about a minute later you have a fully installed WordPress with an admin account, plugins and phpMyAdmin — no install wizard, no manual configuration.

Built for plugin/theme testing and site-migration workflows: break things freely, then restore the base state with a single command. The reset also pulls the **latest** WordPress core and plugin versions, so your sandbox never goes stale.

## What's inside

| Service | Image | Default URL |
|---|---|---|
| WordPress | `wordpress:php8.3-apache` + wp-cli (custom build) | http://localhost |
| MariaDB | `mariadb:11` | — |
| phpMyAdmin | `phpmyadmin:5` | http://localhost:8080 |

## Requirements

- Docker Desktop (macOS / Windows) or Docker Engine with Compose v2 (Linux)
- macOS / Linux → use the `.sh` wrappers, Windows → use the `.ps1` wrappers (PowerShell)

## Quick start

Use this repository as a GitHub template, create your own project repository, then clone it:

```bash
git clone https://github.com/your-user/your-project.git
cd your-project
docker compose up -d
```

If you only want the files in the current folder without creating a Git repository:

```bash
curl -L https://github.com/Agentunio/fastwordpressondocker/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1
docker compose up -d
```

The first start takes about a minute and is fully automated:

1. Builds the image (official WordPress image + wp-cli) and pulls MariaDB / phpMyAdmin.
2. Downloads and installs the **latest** WordPress core — no install wizard.
3. Installs the default theme and the configured plugins (see [Plugins](#plugins)).
4. Removes WordPress's default Akismet and Hello Dolly plugins.
5. Saves the initial **state-0** snapshot into `snapshots/`.

Once it's done:

| | URL | Credentials |
|---|---|---|
| Site | http://localhost | — |
| Admin | http://localhost/wp-admin | `admin_qmpgfd` / `R40U8zp17YlwvQNkDEKgnhx2!@#` |
| phpMyAdmin | http://localhost:8080 | logs in automatically (DB user `wp` / `wp`) |

> These are **local development credentials**, hardcoded in `scripts/init.sh` and used only inside your machine. Change them there before the first start if you want different ones.

Every subsequent `docker compose up -d` starts instantly — init detects the existing installation and exits.

## Commands

> macOS / Linux → `./reset.sh`, `./snapshot.sh`
> Windows → `./reset.ps1`, `./snapshot.ps1`
>
> Both variants do exactly the same thing — they are thin wrappers around the same `scripts/*.sh` executed inside the container.

### `./reset.sh` — restore state-0 (and refresh versions)

Rolls everything back (database + `wp-content` + `wp-config.php`) to the state saved as **state-0**, then:

- downloads the latest WordPress core,
- updates the free plugins (ACF, All-in-One WP Migration) to their latest wordpress.org versions,
- force-reinstalls premium plugins from the local ZIPs in `plugins/`,
- removes Akismet / Hello Dolly if they reappeared.

Under the hood: `docker compose exec -T wordpress bash /scripts/reset.sh`

### `./snapshot.sh` — overwrite state-0

Saves the **current** WordPress state as the new state-0. Use it when you deliberately change the base state — e.g. you added a plugin or theme that should be part of the starting point from now on. Removes Akismet / Hello Dolly before saving.

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

Every clone of this repo is an independent environment. Docker Compose uses the checkout directory as the project name, so containers and volumes get that folder as their prefix (for example `client-site-wordpress-1`, `client-site-db_data`). To run a second copy next to the first one, clone it into a different folder and give it its own ports — create a `.env` file in the second checkout:

```bash
cp .env.example .env
```

```dotenv
WORDPRESS_PORT=3001
WORDPRESS_URL=http://localhost:3001
PHPMYADMIN_PORT=7778
```

Then `docker compose up -d` as usual.

**`WORDPRESS_URL` must include the same port as `WORDPRESS_PORT`**, otherwise WordPress redirects to the portless URL. The reset script re-applies `WORDPRESS_URL` to `home`/`siteurl` on every run, so an existing snapshot adapts to new ports automatically.

## Plugins

On a fresh install `scripts/init.sh` installs and activates:

- **Advanced Custom Fields** (free, from wordpress.org)
- **All-in-One WP Migration** (free, from wordpress.org)
- every `*.zip` found in `plugins/` (premium / custom plugins)

To add another free plugin → add its wordpress.org slug to the `FREE_PLUGINS=(...)` array in `scripts/init.sh`.
To add a premium plugin → drop its ZIP into `plugins/`. It gets installed on fresh installs and force-reinstalled on every reset.

> `plugins/*` is gitignored on purpose — licensed/premium ZIPs stay on your machine and never end up in the repository.

WordPress's default plugins (Akismet, Hello Dolly) are removed automatically on fresh install, on every reset and before every snapshot.

## How it works

| Script | Runs when | What it does |
|---|---|---|
| `scripts/entrypoint.sh` | container start | starts `init.sh` in the background, hands control to the official WP entrypoint |
| `scripts/init.sh` | container start (background) | WP already installed → exit. Snapshot exists → restore it. Otherwise → fresh install + plugins + save state-0 |
| `scripts/reset.sh` | `./reset.sh` / `./reset.ps1` | resets the DB, restores `wp-content` + `wp-config.php` from the snapshot, updates core + plugins |
| `scripts/snapshot.sh` | `./snapshot.sh` / `./snapshot.ps1` | exports the DB, archives `wp-content`, copies `wp-config.php` into `snapshots/` |
| `scripts/remove-default-plugins.sh` | called by the three above | deletes Akismet & Hello Dolly if present |

A state-0 snapshot is three files in `snapshots/` (generated locally, gitignored):

```
state-0.sql                  # full database dump
state-0-wp-content.tar.gz    # wp-content (plugins, themes, uploads)
state-0-wp-config.php        # wp-config.php
```

WordPress core and the database live in named Docker volumes (`wp_data`, `db_data`). `wp-content/` is bind-mounted from the repo directory, so you can edit themes and plugins directly from your IDE on the host.

## Project structure

```
docker-compose.yml          # services: db (MariaDB 11), wordpress (custom build), phpmyadmin
Dockerfile                  # wordpress:php8.3-apache + wp-cli + mariadb-client
.env.example                # port/URL overrides (copy to .env)
scripts/
  entrypoint.sh             # custom container entrypoint
  init.sh                   # first install / restore from state-0
  reset.sh                  # restore state-0 + update WP/plugins
  snapshot.sh               # save the current state as state-0
  remove-default-plugins.sh # delete Akismet & Hello Dolly
plugins/                    # premium plugin ZIPs (gitignored, local only)
snapshots/                  # state-0.* files (gitignored, generated locally)
wp-content/                 # live wp-content of the running site (gitignored)
reset.sh / reset.ps1        # host wrappers (macOS+Linux / Windows)
snapshot.sh / snapshot.ps1  # host wrappers (macOS+Linux / Windows)
```

## Typical workflow

1. `docker compose up -d` — the first run installs everything and saves state-0.
2. Click around, test plugins, import a site with All-in-One WP Migration, break things.
3. `./reset.sh` — back to state-0 in seconds, with WP core + plugins refreshed to latest.
4. Want a different starting point? Set the site up the way you like and run `./snapshot.sh`.
5. Repeat.

## Troubleshooting

**`./reset.sh` fails mid-script with `command not found` (e.g. `ch: command not found`)**

Docker Desktop on macOS (VirtioFS) can serve a stale or truncated version of a bind-mounted file after it was edited on the host. Force a re-read:

```bash
docker compose restart wordpress
```

Sanity check that the container sees the same file size as the host:

```bash
docker compose exec -T wordpress wc -c /scripts/reset.sh && wc -c scripts/reset.sh
```

**Port 80 (or 8080) is already in use**

Create a `.env` file (see [Running multiple copies in parallel](#running-multiple-copies-in-parallel)) and pick free ports.

**The site redirects to `http://localhost` without your custom port**

`WORDPRESS_URL` in `.env` must include the port, e.g. `http://localhost:3001`. Run `./reset.sh` afterwards to re-apply it.
