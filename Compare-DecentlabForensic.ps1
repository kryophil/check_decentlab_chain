<#
.SYNOPSIS
    Forensischer Record-Level-Vergleich: Inbound vs. Archiv vs. DB.
    Erzeugt ein CSV mit allen Inbound-Werten, die im Archiv oder der DB fehlen.

.DESCRIPTION
    Parst alle Inbound-JSONs und alle Archiv-Bulletins, baut je eine
    vollstaendige Key-Liste (Station|Parameter|YYYYMMDDHHmm00) auf,
    und exportiert ein CSV mit Detail-Informationen fuer alle Keys,
    die im Inbound vorhanden sind, aber im Archiv oder in der DB fehlen.

.PARAMETER BasePath
    Verzeichnis mit CSVs und Daten-Unterordnern.

.PARAMETER OracleConn
    sqlplus Connection-String fuer DB-Vergleich.

.PARAMETER DbCsv
    Alternativ: Pfad zu manuell exportierter CSV.

.PARAMETER OutputCsv
    Pfad fuer die Ausgabe-CSV. Default: missing_records.csv im BasePath.
#>

param(
    [string]$BasePath   = 'M:\zue-prod\data_integration\DWH_Hydro_Services\Test_Decentlab_API',
    [string]$OracleConn = '',
    [string]$DbCsv      = '',
    [string]$OutputCsv  = ''
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

if ($OutputCsv -eq '') { $OutputCsv = Join-Path $BasePath 'missing_records.csv' }

foreach ($p in @($InboundDir, $ArchiveDir, $StationCsv, $ParameterCsv, $BulletinCsv)) {
    if (-not (Test-Path $p)) { Write-Error "Nicht gefunden: $p"; return }
}

$StationMap = @{}; $StationMapR = @{}
Import-Csv $StationCsv -Delimiter ';' | ForEach-Object {
    $StationMap[$_.STATION_IN_TX]   = $_.STATION_OUT_TX
    $StationMapR[$_.STATION_OUT_TX] = $_.STATION_IN_TX
}

$ParamMap = @{}; $ParamMapR = @{}; $ParamRangeMin = @{}; $ParamRangeMax = @{}
Import-Csv $ParameterCsv -Delimiter ';' | ForEach-Object {
    $ParamMap[$_.IN_PARAMETER_TX] = $_.OUT_SHORT_NAME_TX
    $ParamMapR[$_.OUT_SHORT_NAME_TX] = $_.IN_PARAMETER_TX
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

$InbKeys = @{}
# Key -> Hashtable mit Quell-Details
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
                        $InbSrc[$key] = @{
                            Folder   = $folder.Name
                            File     = $jf.Name
                            FilePath = "$($folder.Name)/$($jf.Name)"
                            TsExact  = $tsExact
                            TsMs     = $tsMs
                            Node     = $node
                            Sensor   = $sensor
                            Value    = $value
                        }
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
            $ArchSrc[$key] = @{
                File    = $af.Name
                Line    = $line
                LineNr  = $i + 1
            }
        }
    }
}

$archTs = $ArchKeys.Keys | ForEach-Object { ($_ -split '\|')[2] } | Sort-Object
$archTsMin = $archTs[0]; $archTsMax = $archTs[-1]
Write-Host "  Soll-Records: $ArchTotal  Out-of-Range: $ArchOor  Keys: $($ArchKeys.Count)"
Write-Host "  Zeitbereich: $archTsMin - $archTsMax"

# ============================================================
# 4. DB laden (optional)
# ============================================================
$DbKeys = @{}; $DbSrc = @{}; $dbLoaded = $false

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
            if (-not $DbKeys.ContainsKey($key)) {
                $DbKeys[$key] = $parts[3].Trim()
                $DbSrc[$key] = "$($parts[0].Trim());$($parts[1].Trim());$refTs;$($parts[3].Trim())"
            }
        }
        Write-Host "  DB-Keys (dedup): $($DbKeys.Count)"
        $dbLoaded = $true
    } else {
        Write-Host "  WARNUNG: Keine DB-Daten geladen." -ForegroundColor Yellow
    }
}

# ============================================================
# 5. CSV erzeugen: Inbound-Keys die im Archiv ODER in DB fehlen
# ============================================================
Write-Host "`n=== Erzeuge CSV fuer fehlende Records ===" -ForegroundColor Cyan

$csvLines = @()
$csvLines += 'INBOUND_FILE;INBOUND_RECORD;IN_PARAMETER_TX;STATION_IN_TX;ARCHIVE_FILE;ARCHIVE_RECORD;OUT_SHORT_NAME_TX;STATION_OUT_TX;DB_RECORD'

$missingArchCount = 0
$missingDbCount = 0
$missingBothCount = 0

foreach ($key in ($InbKeys.Keys | Sort-Object)) {
    $keyParts = $key -split '\|'
    $stOut = $keyParts[0]; $parOut = $keyParts[1]; $tsTrunc = $keyParts[2]

    $inArchiv = $ArchKeys.ContainsKey($key)
    $inDb     = if ($dbLoaded) { $DbKeys.ContainsKey($key) } else { $true }

    if ($inArchiv -and $inDb) { continue }

    $src = $InbSrc[$key]
    $inbFile   = $src.FilePath
    $inbRecord = "node=$($src.Node);sensor=$($src.Sensor);ts=$($src.TsExact);value=$($src.Value)"
    $inParam   = $src.Sensor
    $stIn      = $src.Node

    $archFile   = ''
    $archRecord = ''
    if ($inArchiv) {
        $archFile   = $ArchSrc[$key].File
        $archRecord = $ArchSrc[$key].Line
    }

    $dbRecord = ''
    if ($dbLoaded -and $DbKeys.ContainsKey($key)) {
        $dbRecord = $DbSrc[$key]
    }

    if (-not $inArchiv -and -not $inDb) { $missingBothCount++ }
    elseif (-not $inArchiv) { $missingArchCount++ }
    else { $missingDbCount++ }

    $csvLines += "$inbFile;$inbRecord;$inParam;$stIn;$archFile;$archRecord;$parOut;$stOut;$dbRecord"
}

$totalMissing = $missingArchCount + $missingDbCount + $missingBothCount
Write-Host "  Fehlend nur im Archiv: $missingArchCount"
Write-Host "  Fehlend nur in DB:     $missingDbCount"
Write-Host "  Fehlend in beidem:     $missingBothCount"
Write-Host "  Total fehlende Keys:   $totalMissing"

$csvLines -join "`r`n" | Out-File -FilePath $OutputCsv -Encoding UTF8
Write-Host "`n  CSV geschrieben: $OutputCsv ($totalMissing Datensaetze)" -ForegroundColor Green

# ============================================================
# 6. Zusammenfassung auf Konsole (wie bisher)
# ============================================================
Write-Host "`n========================================================" -ForegroundColor White
Write-Host "  VERGLEICH: INBOUND vs. ARCHIV (Key-Match)" -ForegroundColor White
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
    Write-Host ("    {0,-46} {1,-16} {2,-7} {3,-10} {4,-10} {5}" -f 'Inbound-File', 'TS exakt', 'Node', 'Station', 'Parameter', 'Wert')
    Write-Host ("    " + ('-' * 100))
    foreach ($k in ($inbNotArch | Sort-Object)) {
        $s = $InbSrc[$k]
        $p = $k -split '\|'
        Write-Host ("    {0,-46} {1,-16} {2,-7} {3,-10} {4,-10} {5}" -f $s.FilePath, $s.TsExact, $s.Node, $p[0], $p[1], $InbKeys[$k])
    }
}

Write-Host "`n  Im ARCHIV, nicht im INBOUND: $($archNotInb.Count)" -ForegroundColor $(if ($archNotInb.Count -gt 0) { 'Yellow' } else { 'Green' })
if ($archNotInb.Count -gt 0) {
    Write-Host ("    {0,-50} {1,-10} {2,-10} {3,-16} {4}" -f 'Bulletin', 'Station', 'Parameter', 'TS', 'Wert')
    Write-Host ("    " + ('-' * 100))
    foreach ($k in ($archNotInb | Sort-Object)) {
        $p = $k -split '\|'
        Write-Host ("    {0,-50} {1,-10} {2,-10} {3,-16} {4}" -f $ArchSrc[$k].File, $p[0], $p[1], $p[2], $ArchKeys[$k])
    }
}

if ($dbLoaded) {
    Write-Host "`n========================================================" -ForegroundColor White
    Write-Host "  VERGLEICH: INBOUND vs. DB (Key-Match)" -ForegroundColor White
    Write-Host "  Zeitfenster: $archTsMin - $archTsMax" -ForegroundColor White
    Write-Host "========================================================" -ForegroundColor White

    $inbNotDb = @()
    foreach ($k in $InbKeys.Keys) {
        if (-not $DbKeys.ContainsKey($k)) { $inbNotDb += $k }
    }

    Write-Host "`n  Im INBOUND, nicht in DB: $($inbNotDb.Count)" -ForegroundColor $(if ($inbNotDb.Count -gt 0) { 'Red' } else { 'Green' })
    if ($inbNotDb.Count -gt 0) {
        $byCombo = @{}
        foreach ($k in $inbNotDb) {
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
            Write-Host ("      {0,-50} {1,-16} {2}" -f 'Inbound-File', 'TS', 'Wert')
            Write-Host ("      " + ('-' * 80))
            foreach ($k in $keys) {
                $kp = $k -split '\|'
                $s = $InbSrc[$k]
                Write-Host ("      {0,-50} {1,-16} {2}" -f $s.FilePath, $kp[2], $InbKeys[$k])
            }
        }
    }
}

Write-Host "`n=== Forensische Analyse abgeschlossen ===" -ForegroundColor Cyan
