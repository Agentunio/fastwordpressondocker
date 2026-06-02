# Testowy WordPress

Lokalne środowisko WordPress w Dockerze ze snapshotem stanu bazowego (`state-0`), które można w każdej chwili przywrócić. Działa po `git clone` + `docker compose up` — bez ręcznej konfiguracji.

## Wymagania

- Docker Desktop
- macOS / Linux → wrappery `.sh` (działają w `bash`/`zsh`)
- Windows → wrappery `.ps1` (PowerShell)

## Quickstart

```bash
docker compose up -d
```

Pierwszy start (~1 min):
- pobranie obrazów + build (Dockerfile dorzuca `wp-cli` do oficjalnego obrazu WordPress)
- `init.sh` pobiera najnowszego WordPressa, instaluje pluginy (ACF + AIO Migration + AIO Migration Pro), zapisuje snapshot `state-0`

Po starcie:
- WordPress: http://localhost
- Admin: http://localhost/wp-admin
  - user: `admin_qmpgfd`
  - pass: `R40U8zp17YlwvQNkDEKgnhx2!@#`

Kolejne `docker compose up` — startuje natychmiast, init wykrywa zainstalowanego WP i kończy.

### Równoległy start kilku kopii

Domyślnie WordPress działa na porcie `80`, a phpMyAdmin na `8080`. Jeśli odpalasz drugi checkout tego projektu obok pierwszego, utwórz w nim lokalny plik `.env`:

```bash
WORDPRESS_PORT=3001
WORDPRESS_URL=http://localhost:3001
PHPMYADMIN_PORT=7778
```

Potem uruchom:

```bash
docker compose up -d
```

`WORDPRESS_URL` musi zawierać ten sam port co `WORDPRESS_PORT`, inaczej WordPress może przekierowywać na adres bez portu.

## Komendy

> macOS / Linux → `./reset.sh`, `./snapshot.sh`
> Windows → `./reset.ps1`, `./snapshot.ps1`
> Oba warianty robią to samo — to tylko wrappery na te same `scripts/*.sh` w kontenerze.

### `./reset.sh` (`./reset.ps1`) — przywróć state-0 i odśwież wersje

Cofa wszystko (baza + `wp-content` + `wp-config.php`) do stanu zapisanego jako `state-0`, a następnie pobiera najnowszego WordPressa oraz najnowsze darmowe wersje **ACF** i **All-in-One WP Migration** z wordpress.org. Premium ZIP-y z `plugins/` są przeinstalowywane z lokalnych plików.

Pod spodem: `docker compose exec -T wordpress bash /scripts/reset.sh`

### `./snapshot.sh` (`./snapshot.ps1`) — nadpisz state-0

Zapisuje **aktualny** stan WordPressa jako nowy state-0. Używaj gdy świadomie zmieniasz stan bazowy (dodajesz wtyczkę/motyw, który ma być w punkcie wyjścia).

Pod spodem: `docker compose exec -T wordpress bash /scripts/snapshot.sh`

## Co robi co

| Skrypt | Kiedy się uruchamia | Co robi |
|---|---|---|
| `scripts/entrypoint.sh` | Start kontenera | Wrapper — odpala `init.sh` w tle i przekazuje sterowanie do oryginalnego entrypointu WP |
| `scripts/init.sh` | Start kontenera (w tle) | Jeśli WP już zainstalowany → nic. Jeśli istnieje snapshot → `reset.sh`. Jeśli pusto → fresh install + pluginy + zapis state-0 |
| `scripts/reset.sh` | `./reset.sh` / `./reset.ps1` lub init z istniejącym snapshotem | Resetuje DB + przywraca `wp-content` + `wp-config.php` ze snapshotu |
| `scripts/snapshot.sh` | `./snapshot.sh` / `./snapshot.ps1` | Eksportuje DB + pakuje `wp-content` + kopiuje `wp-config.php` do `snapshots/` |

## Pluginy

`init.sh` przy fresh install instaluje:
- **ACF** (free, z wp.org slug: `advanced-custom-fields`)
- **All-in-One WP Migration** (free, z wp.org)
- **All-in-One WP Migration Pro** (premium, z `plugins/all-in-one-wp-migration-pro.zip`)

Żeby dodać kolejny darmowy plugin → edytuj `FREE_PLUGINS=(...)` w `scripts/init.sh`.
Żeby dodać kolejny premium → wrzuć `.zip` do `plugins/`.

## Struktura

```
docker-compose.yml        # services: db (mariadb 11) + wordpress (custom image)
Dockerfile                # wordpress:php8.2-apache + wp-cli
scripts/
  entrypoint.sh           # custom entrypoint kontenera
  init.sh                 # pierwsza instalacja / odtworzenie z state-0
  snapshot.sh             # zapis state-0
  reset.sh                # przywrócenie state-0
snapshots/                # state-0.* — generowane lokalnie, gitignored
plugins/                  # *.zip — premium pluginy, instalowane przy fresh install
reset.sh / reset.ps1      # wrapper dla scripts/reset.sh    (mac/linux / windows)
snapshot.sh / snapshot.ps1 # wrapper dla scripts/snapshot.sh (mac/linux / windows)
```

Cały WordPress (core + wp-content + DB) siedzi w named volumes (`wp_data`, `db_data`), nie w gicie. Czyściwa: `docker compose down -v` usuwa wszystko.

## Typowy workflow

1. `git clone` + `docker compose up -d` — start (fresh install + auto state-0)
2. Klikasz/testujesz/psujesz WordPressa
3. `./reset.sh` (Windows: `./reset.ps1`) — wracasz do state-0
4. Gdy chcesz **zmienić** punkt wyjścia → `./snapshot.sh` (Windows: `./snapshot.ps1`)
5. Pełny reset (z wyczyszczeniem volumes): `docker compose down -v && docker compose up -d`

## Troubleshooting

**`./reset.sh` rzuca `command not found` w połowie skryptu (np. `ch: command not found`)**
Docker Desktop na macOS (VirtioFS) potrafi serwować w kontenerze nieświeżą/uciętą wersję pliku z bind-mountu `scripts/` po jego edycji na hoście. Wymuś ponowne wczytanie:

```bash
docker compose restart wordpress
```

Sanity-check, że kontener widzi ten sam rozmiar pliku co host:

```bash
docker compose exec -T wordpress wc -c /scripts/reset.sh && wc -c scripts/reset.sh
```
