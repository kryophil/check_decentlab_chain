# Compare-DecentlabInboundArchive.ps1

## Zweck

Das Script prüft die Vollständigkeit der Decentlab-Datenkette für die hydrologischen BAFU-Sensordaten (CONVERT_MODUL 151). Es vergleicht die Datenbestände über vier Stufen und zeigt pro Soll-Station × Parameter, wo Records verloren gehen.

```
InfluxDB (Decentlab API)
    │
    ▼  Airflow-Polling (10-min-Intervall)
Inbound (ch-meteoswiss-application-fabio-inbound-partner)
    │
    ▼  Java-Konvertierung (ch.meteoswiss.convertclasses.Decentlab)
Archiv (ch-meteoswiss-etl-archive, VRYA61-Bulletins)
    │
    ▼  Bulletin-Loader
DB (WORK1.T_WRK_SURFACE_NP → DWH)
```

Der Soll-Bestand ergibt sich aus den konfigurierten Stationen und Parametern in `station.csv` und `parameter.csv`, welche die Tabellen `DWH1.T_CONV_MODUL_CONV_STATION` und `DWH1.T_CONVERT_MODUL_CONV_PAR` abbilden.


## Voraussetzungen

### Verzeichnisstruktur

```
BasePath\
├── station.csv
├── parameter.csv
├── bulletin.csv
├── .key                                          (optional, für API-Zugriff)
├── Compare-DecentlabInboundArchive.ps1
├── ch-meteoswiss-application-fabio-inbound-partner\
│   ├── dt=2026-07-08T00_00_00+00_00\
│   │   └── *_measurements_*.json
│   ├── dt=2026-07-08T00_10_00+00_00\
│   │   └── ...
│   └── ...
└── ch-meteoswiss-etl-archive\
    ├── VRYA61.CCCX.070800..*.1783469429499
    ├── VRYA61.CCCX.070801..*.1783469429500
    └── ...
```

### CSV-Dateien

**station.csv** — Semikolon-getrennt, Zuordnung Decentlab-Node → MeteoSwiss-NET_NR:
```
STATION_IN_TX;STATION_OUT_TX
22404;100928
2286;100885
2287;100886
...
```

**parameter.csv** — Semikolon-getrennt, Zuordnung Sensor → DWH-Parameter mit Wertebereich:
```
IN_PARAMETER_TX;OUT_SHORT_NAME_TX;DECIMALS_NU;VALUE_RANGE_MIN;VALUE_RANGE_MAX
maxbotix-mb7386-distance;hyi435o0;0;0;10000
maxbotix-mb7389-distance;hyi436o0;0;0;10000
keller-pr36xiw-pressure;hyi437o0;6;-1;10
keller-pr26d-pressure;hyi438o0;6;-1;10
```

Die Spalten `DECIMALS_NU`, `VALUE_RANGE_MIN`, `VALUE_RANGE_MAX` sind optional. Ohne sie wird kein Wertebereichsfilter angewandt.

**bulletin.csv** — Semikolon-getrennt, Bulletin-Kennung:
```
BULLETIN_NAME_IN_TX;CONVERT_PROG_NAME_TX
VRYA61;ch.meteoswiss.convertclasses.Decentlab
```

**.key** — API-Key für die Decentlab InfluxDB (nur für `-CheckApi`):
```
API Key: eyJrIjoixxxxxxxxxxxxxxx
```

### Systemanforderungen

- PowerShell 5.1 (Windows), kompatibel mit Constrained Language Mode (CLM)
- `sqlplus` im PATH (nur für `-OracleConn`)
- Netzwerkzugriff auf `bafu-hydrometrie.decentlab.com` (nur für `-CheckApi`, ggf. via Proxy)


## Parameter

| Parameter | Typ | Default | Beschreibung |
|---|---|---|---|
| `-BasePath` | string | `M:\zue-prod\...\Test_Decentlab_API` | Pfad zum Verzeichnis mit CSVs und Daten-Unterordnern |
| `-OracleConn` | string | _(leer)_ | sqlplus-Connection-String, z.B. `"user/pass@TNSALIAS"` |
| `-DbCsv` | string | _(leer)_ | Pfad zu manuell exportierter DB-CSV (Alternative zu sqlplus) |
| `-CheckApi` | switch | _(aus)_ | InfluxDB-API direkt abfragen |
| `-Proxy` | string | _(leer)_ | HTTP-Proxy für API-Zugriff |


## Aufrufbeispiele

### Minimaler Aufruf (nur Inbound ↔ Archiv)
```powershell
.\Compare-DecentlabInboundArchive.ps1
```
Prüft die Konvertierung: kommen alle Inbound-Records im Archiv an? Generiert die SQL-Dateien `db_query.sql` und `db_query_spool.sql` für manuellen DB-Export.

### Mit DB-Vergleich via sqlplus
```powershell
.\Compare-DecentlabInboundArchive.ps1 -OracleConn "user/pass@TNSALIAS"
```
Wie oben, plus automatische DB-Abfrage. sqlplus muss im PATH sein.

### Mit DB-Vergleich via manueller CSV
```powershell
.\Compare-DecentlabInboundArchive.ps1 -DbCsv "M:\...\mein_export.csv"
```
Erwartet die Spalten `NET_NR;SHORT_NAME_TX;REFERENCE_TS;VALUE_NU` (Semikolon- oder Komma-getrennt). Geeignet für Toad- oder SQL-Developer-Export der Query aus `db_query.sql`.

### Volle Kette inkl. InfluxDB-API
```powershell
.\Compare-DecentlabInboundArchive.ps1 -OracleConn "user/pass@TNS" -CheckApi
```
Prüft alle vier Stufen: InfluxDB → Inbound → Archiv → DB.

### Mit Proxy (MeteoSwiss-Firewall)
```powershell
.\Compare-DecentlabInboundArchive.ps1 -CheckApi -Proxy "http://proxy.meteoswiss.ch:8080"
```
Falls die API von der Firewall blockiert wird. Verwendet Windows-Default-Credentials für den Proxy.

### Anderer Basispfad
```powershell
.\Compare-DecentlabInboundArchive.ps1 -BasePath "D:\Test\Decentlab" -OracleConn "user/pass@TNS" -CheckApi
```

### Execution Policy (falls blockiert)
```powershell
Unblock-File .\Compare-DecentlabInboundArchive.ps1
.\Compare-DecentlabInboundArchive.ps1
```


## Ausgabe

### Pipeline-Matrix

Das Kernstück der Ausgabe. Zeigt pro Soll-Station × Parameter die Anzahl Records in jeder Stufe und die Differenz zur Vorstufe:

```
=== Pipeline-Matrix: Records pro Soll-Station x Parameter ===
    (Zeitfenster Inbound: 20260707235000 - 20260709083800)

  Station   Node  Parameter      API  Inbound  Archiv  API→Inb  Inb→Arch      DB  Arch→DB
  -----------------------------------------------------------------------------------------
  100885    2286  hyi435o0       196      196     196        0         0      195       -1
  100888    2820  hyi435o0       386      386     386        0         0      378       -8
  100928   22404  hyi436o0       190      190     190        0         0        0     -190
  ...
```

Negative Deltas (rot) = Datenverlust in dieser Stufe. Null Records (gelb) = Station/Parameter liefert keine Daten.

### Verlustanalyse

Nach der Matrix folgt eine Zusammenfassung pro Kettenstufe:

- **Inbound → Archiv:** Exakter Key-Match (zuverlässig, da gleiche Minute-Truncation). Zeigt ob die Java-Konvertierung Records verliert.
- **Archiv → DB:** Anzahlvergleich pro Station × Parameter (kein Key-Match, da die DB durch Polling-Überlappung andere Minute-Keys zuordnen kann als der Inbound).
- **API → Inbound:** Key-Match. Zeigt ob das Airflow-Polling Records aus der InfluxDB verliert.

### Fehlende Polling-Slots

Falls 10-Minuten-Slots im Inbound fehlen (Airflow-Ausfälle), werden diese explizit aufgelistet.


## Datenfluss-Details

### Zeitstempel-Behandlung

Alle Quellen werden auf Minuten-Keys (`YYYYMMDDHHmm00`) normalisiert:

- **Inbound/API:** Epoch-Millisekunden → DateTime → `ToString('yyyyMMddHHmm') + '00'`
- **Archiv:** Timestamp im Bulletin ist bereits auf volle Minuten trunciert
- **DB:** `TO_CHAR(REFERENCE_TS, 'YYYYMMDDHH24MI') || '00'`

### Out-of-Range-Filterung

Werte ausserhalb des in `parameter.csv` definierten Bereichs (z.B. Maxbotix-Sentinel 9999 bei Range 0..10000) werden in allen vier Quellen konsistent vor dem Zählen herausgefiltert.

### Deduplizierung

Pro Quelle wird jeder Minuten-Key nur einmal gezählt. Bei 5-Minuten-Nodes, die zwei Messungen pro 10-Minuten-Slot liefern, fallen diese auf verschiedene Minuten und werden als separate Keys gezählt. Falls derselbe Key durch überlappende Polling-Fenster mehrfach erscheint, zählt nur die erste Occurrence.

### Warum kein Wertvergleich?

- **Inbound ↔ Archiv:** Die Konvertierungsklasse schreibt Float-Werte als Text ins Bulletin. Bei 6-stelligen Druckwerten (Keller-Sensoren) entstehen systematisch Rundungsdifferenzen von ±1 an der letzten Dezimale (IEEE 754 Float→Text→Float).
- **Inbound ↔ DB:** Die Polling-Überlappung bewirkt, dass Inbound und DB für denselben Minuten-Key unterschiedliche Messungen desselben Sensors enthalten können. Ein Wertvergleich ist daher nicht aussagekräftig.


## Generierte Dateien

Das Script erzeugt folgende Dateien im `BasePath`:

| Datei | Beschreibung |
|---|---|
| `db_query.sql` | SELECT-Query für manuellen Export (Toad/SQL Developer) |
| `db_query_spool.sql` | sqlplus-Wrapper mit SET/SPOOL-Kommandos |
| `db_export.csv` | Ergebnis der sqlplus-Abfrage (nur bei `-OracleConn`) |


## Bekannte Einschränkungen

- **Constrained Language Mode (CLM):** Das Script vermeidet .NET-Generics, statische Methodenaufrufe und `[PSCustomObject]`. Alle Datenstrukturen verwenden Hashtables und Arrays.
- **Polling-Überlappung:** Durch überlappende 10-min-Abfragefenster kann derselbe Sensor-Messwert in zwei aufeinanderfolgenden Inbound-Slots erscheinen. Die Minute-Key-Deduplizierung im Script behält den letzten geschriebenen Wert, die DB den ersten. Für den Archiv→DB-Vergleich wird daher nur die Anzahl pro Station × Parameter verglichen.
- **SOCKS5-Proxy:** PowerShell's `Invoke-RestMethod` unterstützt kein SOCKS5. Falls nur `proxy.meteoswiss.ch:1080` (SOCKS5) verfügbar ist, muss die API-Abfrage alternativ via `curl.exe --socks5` erfolgen.
