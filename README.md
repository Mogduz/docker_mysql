# docker_mysql

MySQL 8 auf Ubuntu 24.04 mit Docker Compose.

## Wichtige Variablen

In `docker-compose.yml` wird der Admin-Account über folgende Variablen gesetzt:

- `root_user`
- `root_password`

Der EntryPoint initialisiert damit die Datenbank beim ersten Start und konfiguriert den Root/Admin-User.

Die App-Datenbank wird über folgende Variablen erstellt:

- `db_name`
- `db_user`
- `db_user_password`

Wenn diese gesetzt sind, erstellt der EntryPoint eine leere Datenbank, den User und führt
`GRANT ALL PRIVILEGES` auf `db_name` für `db_user` aus (über den Root-Account).

Optional kannst du `dump_file_name` setzen. Dann wird genau dieser Dump beim Container-Start automatisch
in `db_name` importiert (als `db_user`). Ist `dump_file_name` leer, findet kein Auto-Import statt.
Es ist nur ein Dateiname erlaubt, der aus `/mnt/dump` gelesen wird.

## Dump-Import

Der Container erwartet Dump-Dateien in `/mnt/dump` (Host-Mount, read-only).

Import aufrufen:

```bash
./scripts/import-dump.sh <dump-file-name.sql|dump-file-name.sql.gz>
```

Beispiele:

```bash
./scripts/import-dump.sh test.sql
./scripts/import-dump.sh backup.sql.gz
```

Der Importer verwendet immer `db_user`/`db_user_password` und schreibt immer in `db_name`.
Vor und nach dem Import wird ein SHA256-Hash geprüft. Bei `.gz` wird zusätzlich `gzip -t` ausgeführt.
Wenn sich die Datei während des Imports ändert, wird der Import mit Fehler beendet.

WSL-Alias (in `~/.bashrc`):

```bash
alias dbimport='cd /mnt/c/Users/Gerald/Documents/GitHub/docker_mysql && ./scripts/import-dump.sh'
```

Danach:

```bash
source ~/.bashrc
dbimport mein_dump.sql
```
