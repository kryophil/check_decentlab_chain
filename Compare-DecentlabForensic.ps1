<#
.SYNOPSIS
    Forensischer Record-Level-Vergleich: Archiv vs. Inbound vs. DB.
    Keine Annahmen, keine Interpretation — nur harte Fakten pro Key.

.DESCRIPTION
    Parst alle Inbound-JSONs und alle Archiv-Bulletins, baut je eine
    vollstaendige Key-Liste (Station|Parameter|YYYYMMDDHHmm00) auf,
    und listet exakt auf, welche Keys wo fehlen.
    Optional DB-Vergleich gegen das Archiv-Zeitfenster.

.PARAMETER BasePath
    Verzeichnis mit CSVs und Daten-Unterordnern.

.PARAMETER OracleConn
    sqlplus Connection-String fuer DB-Vergleich.

.PARAMETER DbCsv
    Alternativ: Pfad zu manuell exportierter CSV.
#>

param(
    [string]$BasePath   = 'M:\zue-prod\data_integration\DWH_Hydro_Services\Test_Decentlab_API',
    [string]$OracleConn = '',
    [string]$DbCsv      = ''
)

$ErrorActionPreference = 'Stop'
$Epoch = [datetime]'1970-01-01'

# ============================================================
# 1. Konfiguration
# ============================================================
$InboundDir   = Join-Path $BasePath 'ch-meteoswiss-application-fabio-inbound-partner'
$ArchiveDir   = Join-Path $BasePath 'ch-meteoswiss-etl-archive'
$StationCsv   = Join-Path $BasePath 'station.csv'
$ParameterCsv = Join-Path $BasePath 'parameter.csv'
$BulletinCsv  = Join-Path $BasePath 'bulletin.csv'

foreach ($p in @($InboundDir, $ArchiveDir, $StationCsv, $ParameterCsv, $BulletinCsv)) {
    if (-not (Test-Path $p)) { Write-Error "Nicht gefunden: $p"; return }
}

$StationMap = @{}; $StationMapR = @{}
Import-Csv $StationCsv -Delimiter ';' | ForEach-Object {
    $StationMap[$_.STATION_IN_TX]   = $_.STATION_OUT_TX
    $StationMapR[$_.STATION_OUT_TX] = $_.STATION_IN_TX
}

$ParamMap = @{}; $ParamRangeMin = @{}; $ParamRangeMax = @{}
Import-Csv $ParameterCsv -Delimiter ';' | ForEach-Object {
    $ParamMap[$_.IN_PARAMETER_TX] = $_.OUT_SHORT_NAME_TX
    if ($_.PSObject.Properties.Name -contains 'VALUE_RANGE_MIN') {
        $ParamRangeMin[$_.OUT_SHORT_NAME_TX] = [double]$_.VALUE_RANGE_MIN
        $ParamRangeMax[$_.OUT_SHORT_NAME_TX] = [double]$_.VALUE_RANGE_MAX
    }
}
$SollStationsOut = @{}
foreach ($v in $StationMap.Values) { $SollStationsOut[$v] = $true }

$Bulletin = Import-Csv $BulletinCsv -Delimiter ';' | Select-Object -First 1

Write-Host "`n=== Konfiguration ===" -ForegroundColor Cyan
Write-Host "  Stationen: $($StationMap.Count)  Parameter: $($ParamMap.Count)"

# ============================================================
# 2. Inbound parsen — ALLE Records, ALLE Slots
# ============================================================
Write-Host "`n=== Parse Inbound ===" -ForegroundColor Cyan

# Key -> Wert (erster Wert pro Key bleibt, kein Ueberschreiben)
$InbKeys = @{}
# Key -> Quell-Info "folder|tsExact|node|sensor"
$InbSrc  = @{}
$InbTotal = 0; $InbOor = 0

$dtFolders = Get-ChildItem -Path $InboundDir -Directory -Filter 'dt=*' | Sort-Object Name
Write-Host "  Slots: $($dtFolders.Count)"

foreach ($folder in $dtFolders) {
    foreach ($jf in (Get-ChildItem -Path $folder.FullName -Filter '*.json')) {
        $json = Get-Content -Path $jf.FullName -Raw | ConvertFrom-Json
        foreach ($result in $json.results) {
            foreach ($series in $result.series) {
                $node = $series.tags.node; $sensor = $series.tags.sensor
                if (-not $StationMap.ContainsKey($node))  { continue }
                if (-not $ParamMap.ContainsKey($sensor))  { continue }
                $stOut = $StationMap[$node]; $parOut = $ParamMap[$sensor]

                foreach ($val in $series.values) {
                    $InbTotal++
                    $tsMs = [long]$val[0]; $value = $val[1]

                    if ($ParamRangeMax.ContainsKey($parOut)) {
                        if ([double]$value -lt $ParamRangeMin[$parOut] -or [double]$value -ge $ParamRangeMax[$parOut]) {
                            $InbOor++; continue
                        }
                    }

                    $dt = $Epoch.AddMilliseconds($tsMs)
                    $tsTrunc = $dt.ToString('yyyyMMddHHmm') + '00'
                    $tsExact = $dt.ToString('yyyyMMddHHmmss')
                    $key = "$stOut|$parOut|$tsTrunc"

                    if (-not $InbKeys.ContainsKey($key)) {
                        $InbKeys[$key] = $value
                        $InbSrc[$key]  = "$($folder.Name)|$tsExact|$node|$sensor"
                    }
                }
            }
        }
    }
}

Write-Host "  Soll-Records: $InbTotal  Out-of-Range: $InbOor  Keys: $($InbKeys.Count)"
$inbTs = $InbKeys.Keys | ForEach-Object { ($_ -split '\|')[2] } | Sort-Object
Write-Host "  Zeitbereich: $($inbTs[0]) - $($inbTs[-1])"

# ============================================================
# 3. Archiv parsen — ALLE Bulletins
# ============================================================
Write-Host "`n=== Parse Archiv ===" -ForegroundColor Cyan

$ArchKeys = @{}
# Key -> Quell-Info "bulletin-filename"
$ArchSrc  = @{}
$ArchTotal = 0; $ArchOor = 0

$bulletinName = $Bulletin.BULLETIN_NAME_IN_TX
$archiveFiles = Get-ChildItem -Path $ArchiveDir -File -Filter "$bulletinName*" | Sort-Object Name
Write-Host "  Bulletins: $($archiveFiles.Count)"

foreach ($af in $archiveFiles) {
    $lines = Get-Content -Path $af.FullName
    for ($i = 3; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }
        $parts = $line -split '\s+'
        if ($parts.Count -lt 6) { continue }
        $station = $parts[2]; $ts = $parts[3]; $param = $parts[4]; $value = $parts[5]

        if (-not $SollStationsOut.ContainsKey($station)) { continue }
        $ArchTotal++

        if ($ParamRangeMax.ContainsKey($param)) {
            if ([double]$value -lt $ParamRangeMin[$param] -or [double]$value -ge $ParamRangeMax[$param]) {
                $ArchOor++; continue
            }
        }

        $key = "$station|$param|$ts"
        if (-not $ArchKeys.ContainsKey($key)) {
            $ArchKeys[$key] = $value
            $ArchSrc[$key]  = $af.Name
        }
    }
}

$archTs = $ArchKeys.Keys | ForEach-Object { ($_ -split '\|')[2] } | Sort-Object
$archTsMin = $archTs[0]; $archTsMax = $archTs[-1]
Write-Host "  Soll-Records: $ArchTotal  Out-of-Range: $ArchOor  Keys: $($ArchKeys.Count)"
Write-Host "  Zeitbereich: $archTsMin - $archTsMax"

# ============================================================
# 4. DB laden (optional) — Zeitfenster = ARCHIV (nicht Inbound)
# ============================================================
$DbKeys = @{}; $dbLoaded = $false

if ($OracleConn -ne '' -or $DbCsv -ne '') {
    Write-Host "`n=== Lade DB ===" -ForegroundColor Cyan

    $stationList = ($StationMap.Values | Sort-Object) -join ','
    $paramList   = ($ParamMap.Values | ForEach-Object { "'$_'" }) -join ','
    $tsFrom = $archTsMin.Substring(0,4) + '-' + $archTsMin.Substring(4,2) + '-' + $archTsMin.Substring(6,2) + ' ' + $archTsMin.Substring(8,2) + ':' + $archTsMin.Substring(10,2) + ':00'
    $tsTo   = $archTsMax.Substring(0,4) + '-' + $archTsMax.Substring(4,2) + '-' + $archTsMax.Substring(6,2) + ' ' + $archTsMax.Substring(8,2) + ':' + $archTsMax.Substring(10,2) + ':59'

    $sqlQuery = @"
SELECT MS.NET_NR, PAR.SHORT_NAME_TX,
       TO_CHAR(WSP.REFERENCE_TS, 'YYYYMMDDHH24MI') || '00' AS REFERENCE_TS,
       WSP.VALUE_NU
FROM WORK1.T_WRK_SURFACE_NP WSP
JOIN DWH1.T_PARAMETER_INSTALLATION PI ON WSP.PARAMETER_ID = PI.PARAMETER_ID AND WSP.INSTALLATION_ID = PI.INSTALLATION_ID
JOIN DWH1.T_TRANSL_SRC_DWH TSD ON PI.PARAMETER_ID = TSD.TARGET_PARAMETER_ID AND PI.INSTALLATION_ID = TSD.TARGET_INSTALLATION_ID
JOIN DWH1.T_MEAS_SITE MS ON TSD.SRC_MEAS_SITE_ID = MS.MEAS_SITE_ID
JOIN DWH1.T_PARAMETER PAR ON TSD.SRC_PARAMETER_ID = PAR.PARAMETER_ID
WHERE PAR.SHORT_NAME_TX IN ($paramList)
AND MS.NET_NR IN ($stationList)
AND WSP.REFERENCE_TS BETWEEN TO_DATE('$tsFrom', 'YYYY-MM-DD HH24:MI:SS') AND TO_DATE('$tsTo', 'YYYY-MM-DD HH24:MI:SS')
ORDER BY MS.NET_NR, PAR.SHORT_NAME_TX, WSP.REFERENCE_TS
"@

    $dbCsvFile = Join-Path $BasePath 'db_forensic_export.csv'
    $sqlPlusScript = @"
SET PAGESIZE 0
SET LINESIZE 500
SET TRIMSPOOL ON
SET TRIMOUT ON
SET HEADING OFF
SET FEEDBACK OFF
SET ECHO OFF
SET COLSEP ';'
SPOOL $dbCsvFile
$sqlQuery
;
SPOOL OFF
EXIT
"@
    $sqlPlusFile = Join-Path $BasePath 'db_forensic_spool.sql'
    $sqlPlusScript | Out-File -FilePath $sqlPlusFile -Encoding ascii

    $dbRecordsRaw = $null
    if ($OracleConn -ne '') {
        Write-Host "  Zeitfenster DB-Query: $tsFrom - $tsTo"
        $env:NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'
        $sqlplusOutput = Get-Content $sqlPlusFile -Raw | & sqlplus -s $OracleConn 2>&1
        if (Test-Path $dbCsvFile) {
            $dbRecordsRaw = Get-Content $dbCsvFile | Where-Object { $_.Trim() -ne '' }
            Write-Host "  SPOOL-Datei: $dbCsvFile ($($dbRecordsRaw.Count) Zeilen)"
        } else {
            Write-Host "  FEHLER: SPOOL-Datei nicht erzeugt: $dbCsvFile" -ForegroundColor Red
            Write-Host "  sqlplus-Output:" -ForegroundColor Red
            Write-Host "  $sqlplusOutput" -ForegroundColor Red
        }
    } elseif ($DbCsv -ne '' -and (Test-Path $DbCsv)) {
        $dbRecordsRaw = Get-Content $DbCsv | Where-Object { $_.Trim() -ne '' }
        Write-Host "  CSV: $($dbRecordsRaw.Count) Zeilen aus $DbCsv"
    }

    if ($dbRecordsRaw -and $dbRecordsRaw.Count -gt 0) {
        $dbSkippedHeader = $false
        foreach ($line in $dbRecordsRaw) {
            $line = $line.Trim()
            if ($line -eq '' -or $line -match '^-+') { continue }
            if (-not $dbSkippedHeader -and $line -match 'NET_NR|SHORT_NAME') { $dbSkippedHeader = $true; continue }
            $parts = $line -split ';'
            if ($parts.Count -lt 4) { $parts = $line -split ',' }
            if ($parts.Count -lt 4) { continue }
            $refTs = ($parts[2].Trim() -replace '[^0-9]', '')
            if ($refTs.Length -lt 12) { continue }
            $refTs = $refTs.Substring(0, 12) + '00'
            $key = "$($parts[0].Trim())|$($parts[1].Trim())|$refTs"
            if (-not $DbKeys.ContainsKey($key)) { $DbKeys[$key] = $parts[3].Trim() }
        }
        Write-Host "  DB-Keys (dedup): $($DbKeys.Count)"
        $dbLoaded = $true
    } else {
        Write-Host "  WARNUNG: Keine DB-Daten geladen. Vergleich 2 wird uebersprungen." -ForegroundColor Yellow
        if ($dbRecordsRaw) { Write-Host "  (dbRecordsRaw.Count = $($dbRecordsRaw.Count))" -ForegroundColor Yellow }
    }
}

# ============================================================
# 5. Vergleich 1: INBOUND vs. ARCHIV (Key-Match)
#    Nur innerhalb Inbound-Zeitfenster
# ============================================================
Write-Host "`n========================================================" -ForegroundColor White
Write-Host "  VERGLEICH 1: INBOUND vs. ARCHIV (Key-Match)" -ForegroundColor White
Write-Host "  Zeitfenster: $($inbTs[0]) - $($inbTs[-1])" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor White

$inbNotArch = @()
foreach ($k in $InbKeys.Keys) {
    if (-not $ArchKeys.ContainsKey($k)) { $inbNotArch += $k }
}

$archNotInb = @()
foreach ($k in $ArchKeys.Keys) {
    $ts = ($k -split '\|')[2]
    if ($ts -ge $inbTs[0] -and $ts -le $inbTs[-1]) {
        if (-not $InbKeys.ContainsKey($k)) { $archNotInb += $k }
    }
}

Write-Host "`n  Im INBOUND, nicht im ARCHIV: $($inbNotArch.Count)" -ForegroundColor $(if ($inbNotArch.Count -gt 0) { 'Red' } else { 'Green' })
if ($inbNotArch.Count -gt 0) {
    Write-Host ("    {0,-46} {1,-16} {2,-7} {3,-10} {4,-10} {5}" -f 'Inbound-Ordner', 'TS exakt', 'Node', 'Station', 'Parameter', 'Wert')
    Write-Host ("    " + ('-' * 100))
    foreach ($k in ($inbNotArch | Sort-Object)) {
        $m = $InbSrc[$k] -split '\|'
        $p = $k -split '\|'
        Write-Host ("    {0,-46} {1,-16} {2,-7} {3,-10} {4,-10} {5}" -f $m[0], $m[1], $m[2], $p[0], $p[1], $InbKeys[$k])
    }
}

Write-Host "`n  Im ARCHIV, nicht im INBOUND: $($archNotInb.Count)" -ForegroundColor $(if ($archNotInb.Count -gt 0) { 'Yellow' } else { 'Green' })
if ($archNotInb.Count -gt 0) {
    Write-Host ("    {0,-50} {1,-10} {2,-10} {3,-16} {4}" -f 'Bulletin', 'Station', 'Parameter', 'TS', 'Wert')
    Write-Host ("    " + ('-' * 100))
    foreach ($k in ($archNotInb | Sort-Object)) {
        $p = $k -split '\|'
        Write-Host ("    {0,-50} {1,-10} {2,-10} {3,-16} {4}" -f $ArchSrc[$k], $p[0], $p[1], $p[2], $ArchKeys[$k])
    }
}

# ============================================================
# 6. Vergleich 2: ARCHIV vs. DB (Key-Match)
#    Ueber das GESAMTE Archiv-Zeitfenster
# ============================================================
if ($dbLoaded) {
    Write-Host "`n========================================================" -ForegroundColor White
    Write-Host "  VERGLEICH 2: ARCHIV vs. DB (Key-Match)" -ForegroundColor White
    Write-Host "  Zeitfenster: $archTsMin - $archTsMax" -ForegroundColor White
    Write-Host "========================================================" -ForegroundColor White

    $archNotDb = @()
    foreach ($k in $ArchKeys.Keys) {
        if (-not $DbKeys.ContainsKey($k)) { $archNotDb += $k }
    }

    $dbNotArch = @()
    foreach ($k in $DbKeys.Keys) {
        if (-not $ArchKeys.ContainsKey($k)) { $dbNotArch += $k }
    }

    Write-Host "`n  Im ARCHIV, nicht in DB: $($archNotDb.Count)" -ForegroundColor $(if ($archNotDb.Count -gt 0) { 'Red' } else { 'Green' })
    if ($archNotDb.Count -gt 0) {
        # Gruppiert nach Station
        $byCombo = @{}
        foreach ($k in $archNotDb) {
            $p = $k -split '\|'; $combo = "$($p[0])|$($p[1])"
            if (-not $byCombo.ContainsKey($combo)) { $byCombo[$combo] = @() }
            $byCombo[$combo] += $k
        }
        foreach ($combo in ($byCombo.Keys | Sort-Object)) {
            $p = $combo -split '\|'
            $nodeId = if ($StationMapR.ContainsKey($p[0])) { $StationMapR[$p[0]] } else { '?' }
            $keys = $byCombo[$combo] | Sort-Object
            Write-Host ""
            Write-Host "    Station $($p[0]) (Node $nodeId) / $($p[1]): $($keys.Count) Records" -ForegroundColor Red
            Write-Host ("      {0,-50} {1,-16} {2}" -f 'Bulletin', 'TS', 'Wert')
            Write-Host ("      " + ('-' * 80))
            foreach ($k in $keys) {
                $kp = $k -split '\|'
                Write-Host ("      {0,-50} {1,-16} {2}" -f $ArchSrc[$k], $kp[2], $ArchKeys[$k])
            }
        }
    }

    Write-Host "`n  In DB, nicht im ARCHIV: $($dbNotArch.Count)" -ForegroundColor $(if ($dbNotArch.Count -gt 0) { 'Yellow' } else { 'Green' })
    if ($dbNotArch.Count -gt 0) {
        $byCombo = @{}
        foreach ($k in $dbNotArch) {
            $p = $k -split '\|'; $combo = "$($p[0])|$($p[1])"
            if (-not $byCombo.ContainsKey($combo)) { $byCombo[$combo] = @() }
            $byCombo[$combo] += $k
        }
        foreach ($combo in ($byCombo.Keys | Sort-Object)) {
            $p = $combo -split '\|'
            $nodeId = if ($StationMapR.ContainsKey($p[0])) { $StationMapR[$p[0]] } else { '?' }
            $keys = $byCombo[$combo] | Sort-Object
            Write-Host ""
            Write-Host "    Station $($p[0]) (Node $nodeId) / $($p[1]): $($keys.Count) Records" -ForegroundColor Yellow
            Write-Host ("      {0,-16} {1}" -f 'TS', 'DB-Wert')
            Write-Host ("      " + ('-' * 30))
            foreach ($k in $keys) {
                $kp = $k -split '\|'
                Write-Host ("      {0,-16} {1}" -f $kp[2], $DbKeys[$k])
            }
        }
    }

    # Zusammenfassung Archiv vs DB
    Write-Host "`n  --- Zusammenfassung Archiv vs. DB ---" -ForegroundColor Cyan
    $archNotDbCombos = @{}
    foreach ($k in $archNotDb) {
        $p = $k -split '\|'; $combo = "$($p[0])|$($p[1])"
        if (-not $archNotDbCombos.ContainsKey($combo)) { $archNotDbCombos[$combo] = 0 }
        $archNotDbCombos[$combo]++
    }
    Write-Host ("    {0,-8} {1,5} {2,-10} {3,8} {4,8} {5,10}" -f 'Station', 'Node', 'Parameter', 'Archiv', 'DB', 'Arch-DB')
    Write-Host ("    " + ('-' * 55))
    foreach ($stOut in ($StationMap.Values | Sort-Object)) {
        foreach ($parOut in ($ParamMap.Values | Sort-Object)) {
            $combo = "$stOut|$parOut"
            $cArch = 0; $cDb = 0
            foreach ($k in $ArchKeys.Keys) {
                if ($k.StartsWith("$combo|")) { $cArch++ }
            }
            foreach ($k in $DbKeys.Keys) {
                if ($k.StartsWith("$combo|")) { $cDb++ }
            }
            if ($cArch -eq 0 -and $cDb -eq 0) { continue }
            $nodeId = if ($StationMapR.ContainsKey($stOut)) { $StationMapR[$stOut] } else { '?' }
            $delta = $cDb - $cArch
            $color = if ($delta -lt 0) { 'Red' } elseif ($delta -gt 0) { 'Yellow' } else { 'Green' }
            Write-Host ("    {0,-8} {1,5} {2,-10} {3,8} {4,8} {5,10}" -f $stOut, $nodeId, $parOut, $cArch, $cDb, $delta) -ForegroundColor $color
        }
    }
}

Write-Host "`n=== Forensische Analyse abgeschlossen ===" -ForegroundColor Cyan
