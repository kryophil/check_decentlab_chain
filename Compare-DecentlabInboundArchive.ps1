<#
.SYNOPSIS
    Prueft die Vollstaendigkeit der Decentlab-Datenkette:
    InfluxDB-API -> Inbound (fabio-inbound-partner) -> Archiv (etl-archive) -> DB (DWH)

    Referenz ist die InfluxDB. Der Soll-Bestand ergibt sich aus den konfigurierten
    Stationen (station.csv) und Parametern (parameter.csv). Die Ausgabe zeigt pro
    Soll-Station x Parameter, wo in der Kette Daten verloren gehen.

.PARAMETER BasePath
    Verzeichnis mit CSVs und Unterordnern. Default: M:\...\Test_Decentlab_API

.PARAMETER OracleConn
    sqlplus Connection-String fuer DB-Vergleich, z.B. "user/pass@TNSALIAS"

.PARAMETER DbCsv
    Alternativ: Pfad zu manuell exportierter CSV

.PARAMETER CheckApi
    InfluxDB-API direkt abfragen (benoetigt .key-Datei)

.PARAMETER Proxy
    HTTP-Proxy fuer API-Zugriff, z.B. "http://proxy.meteoswiss.ch:8080"

.EXAMPLE
    .\Compare-DecentlabInboundArchive.ps1 -OracleConn "user/pass@TNS" -CheckApi
#>

param(
    [string]$BasePath    = 'M:\zue-prod\data_integration\DWH_Hydro_Services\Test_Decentlab_API',
    [string]$OracleConn  = '',
    [string]$DbCsv       = '',
    [switch]$CheckApi,
    [string]$Proxy       = ''
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Hilfsfunktion: Epoch-ms -> YYYYMMDDHHmm00
# ============================================================
$Epoch = [datetime]'1970-01-01'
function Convert-EpochToMinuteKey([long]$tsMs) {
    $dt = $script:Epoch.AddMilliseconds($tsMs)
    return $dt.ToString('yyyyMMddHHmm') + '00'
}
function Convert-EpochToExact([long]$tsMs) {
    return $script:Epoch.AddMilliseconds($tsMs).ToString('yyyyMMddHHmmss')
}

# ============================================================
# 1. Konfiguration laden
# ============================================================
$InboundDir   = Join-Path $BasePath 'ch-meteoswiss-application-fabio-inbound-partner'
$ArchiveDir   = Join-Path $BasePath 'ch-meteoswiss-etl-archive'
$StationCsv   = Join-Path $BasePath 'station.csv'
$ParameterCsv = Join-Path $BasePath 'parameter.csv'
$BulletinCsv  = Join-Path $BasePath 'bulletin.csv'

foreach ($p in @($InboundDir, $ArchiveDir, $StationCsv, $ParameterCsv, $BulletinCsv)) {
    if (-not (Test-Path $p)) { Write-Error "Pfad nicht gefunden: $p"; return }
}

Write-Host "`n=== Konfiguration ===" -ForegroundColor Cyan

$StationMap  = @{}; $StationMapR = @{}
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

$Bulletin = Import-Csv $BulletinCsv -Delimiter ';' | Select-Object -First 1
$SollStationsOut = @{}
foreach ($v in $StationMap.Values) { $SollStationsOut[$v] = $true }

# Soll-Kombinationen (Station x Parameter) aufbauen
$SollCombos = @{}
foreach ($stOut in $StationMap.Values) {
    foreach ($parOut in $ParamMap.Values) {
        $SollCombos["$stOut|$parOut"] = $true
    }
}

Write-Host "  Bulletin:      $($Bulletin.BULLETIN_NAME_IN_TX)"
Write-Host "  Stationen:     $($StationMap.Count)"
Write-Host "  Parameter:     $($ParamMap.Count)"
Write-Host "  Soll-Kombis:   $($SollCombos.Count) (Station x Parameter)"

# ============================================================
# Zaehler-Struktur: pro Soll-Kombi die Anzahl Keys je Quelle
# Cnt = @{ "stOut|parOut" -> count }
# Keys = @{ "stOut|parOut|ts" -> value }  (fuer Key-Matching)
# ============================================================

# ============================================================
# 2. Inbound parsen
# ============================================================
Write-Host "`n=== Parse Inbound ===" -ForegroundColor Cyan

$InbKeys  = @{}; $InbCnt = @{}; $InbMeta = @{}
$InbSlots = @{}; $InbTotal = 0

$dtFolders = Get-ChildItem -Path $InboundDir -Directory -Filter 'dt=*' | Sort-Object Name
Write-Host "  Slots: $($dtFolders.Count)"

foreach ($folder in $dtFolders) {
    $slotNorm = ($folder.Name -replace '^dt=', '') -replace 'T(\d{2})_(\d{2})_(\d{2})', 'T$1:$2:$3' -replace '([+-])(\d{2})_(\d{2})', '$1$2:$3'
    $InbSlots[$slotNorm] = $true

    foreach ($jf in (Get-ChildItem -Path $folder.FullName -Filter '*.json')) {
        $json = Get-Content -Path $jf.FullName -Raw | ConvertFrom-Json
        foreach ($result in $json.results) {
            foreach ($series in $result.series) {
                $node = $series.tags.node; $sensor = $series.tags.sensor
                $InbTotal += $series.values.Count
                if (-not $StationMap.ContainsKey($node))  { continue }
                if (-not $ParamMap.ContainsKey($sensor))  { continue }
                $stOut = $StationMap[$node]; $parOut = $ParamMap[$sensor]
                $combo = "$stOut|$parOut"

                foreach ($val in $series.values) {
                    $tsMs = [long]$val[0]; $value = $val[1]
                    $tsTrunc = Convert-EpochToMinuteKey $tsMs
                    $key = "$combo|$tsTrunc"

                    # Out-of-Range filtern
                    if ($ParamRangeMax.ContainsKey($parOut)) {
                        if ([double]$value -lt $ParamRangeMin[$parOut] -or [double]$value -ge $ParamRangeMax[$parOut]) { continue }
                    }

                    if (-not $InbKeys.ContainsKey($key)) {
                        # Nur erster Wert pro Minute-Key zaehlen (analog DB-Verhalten)
                        if (-not $InbCnt.ContainsKey($combo)) { $InbCnt[$combo] = 0 }
                        $InbCnt[$combo]++
                    }
                    $InbKeys[$key] = $value
                    $InbMeta[$key] = "$($folder.Name)|$(Convert-EpochToExact $tsMs)|$node|$sensor|$stOut|$parOut"
                }
            }
        }
    }
}

Write-Host "  Records total:    $InbTotal"
Write-Host "  Soll-Keys (dedup): $($InbKeys.Count)"

# Luecken-Check
$sortedSlots = $InbSlots.Keys | Sort-Object
if ($sortedSlots.Count -ge 2) {
    $firstDt = ([datetime]$sortedSlots[0]).ToUniversalTime()
    $lastDt  = ([datetime]$sortedSlots[-1]).ToUniversalTime()
    $cursor = $firstDt; $missingSlots = @()
    while ($cursor -le $lastDt) {
        $exp = $cursor.ToString("yyyy-MM-dd'T'HH:mm:ss+00:00")
        if (-not $InbSlots.ContainsKey($exp)) { $missingSlots += $exp }
        $cursor = $cursor.AddMinutes(10)
    }
    if ($missingSlots.Count -gt 0) {
        Write-Host "  ACHTUNG: $($missingSlots.Count) fehlende Slots:" -ForegroundColor Yellow
        foreach ($ms in $missingSlots) { Write-Host "    $ms" -ForegroundColor Yellow }
    } else { Write-Host "  Alle 10-min-Slots lueckenlos." }
}

# Zeitbereich
$inbTs = $InbKeys.Keys | ForEach-Object { ($_ -split '\|')[2] } | Sort-Object
$inbTsMin = $inbTs[0]; $inbTsMax = $inbTs[-1]
Write-Host "  Zeitbereich: $inbTsMin - $inbTsMax"

# ============================================================
# 3. Archiv parsen
# ============================================================
Write-Host "`n=== Parse Archiv ===" -ForegroundColor Cyan

$ArchKeys = @{}; $ArchCnt = @{}
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

        # Out-of-Range filtern
        if ($ParamRangeMax.ContainsKey($param)) {
            if ([double]$value -lt $ParamRangeMin[$param] -or [double]$value -ge $ParamRangeMax[$param]) { continue }
        }

        $combo = "$station|$param"
        $key = "$combo|$ts"
        if (-not $ArchKeys.ContainsKey($key)) {
            if (-not $ArchCnt.ContainsKey($combo)) { $ArchCnt[$combo] = 0 }
            $ArchCnt[$combo]++
        }
        $ArchKeys[$key] = $value
    }
}

$archTs = $ArchKeys.Keys | ForEach-Object { ($_ -split '\|')[2] } | Sort-Object
Write-Host "  Soll-Keys (dedup): $($ArchKeys.Count)"
Write-Host "  Zeitbereich: $($archTs[0]) - $($archTs[-1])"

# ============================================================
# 4. DB laden (optional)
# ============================================================
$DbKeys = @{}; $DbCnt = @{}; $dbLoaded = $false

$stationList = ($StationMap.Values | Sort-Object) -join ','
$paramList   = ($ParamMap.Values | ForEach-Object { "'$_'" }) -join ','
$tsFrom = $inbTsMin.Substring(0,4) + '-' + $inbTsMin.Substring(4,2) + '-' + $inbTsMin.Substring(6,2) + ' ' + $inbTsMin.Substring(8,2) + ':' + $inbTsMin.Substring(10,2) + ':00'
$tsTo   = $inbTsMax.Substring(0,4) + '-' + $inbTsMax.Substring(4,2) + '-' + $inbTsMax.Substring(6,2) + ' ' + $inbTsMax.Substring(8,2) + ':' + $inbTsMax.Substring(10,2) + ':59'

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

# SQL-Files immer schreiben
$sqlFile = Join-Path $BasePath 'db_query.sql'
$dbCsvFile = Join-Path $BasePath 'db_export.csv'
$sqlQuery | Out-File -FilePath $sqlFile -Encoding ascii

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
$sqlPlusFile = Join-Path $BasePath 'db_query_spool.sql'
$sqlPlusScript | Out-File -FilePath $sqlPlusFile -Encoding ascii

if ($OracleConn -ne '' -or $DbCsv -ne '') {
    Write-Host "`n=== Lade DB-Daten ===" -ForegroundColor Cyan

    $dbRecordsRaw = $null
    if ($OracleConn -ne '') {
        $sqlplusTest = Get-Command sqlplus -ErrorAction SilentlyContinue
        if (-not $sqlplusTest) { Write-Host "  FEHLER: sqlplus nicht im PATH." -ForegroundColor Red; return }
        $env:NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'
        $null = Get-Content $sqlPlusFile -Raw | & sqlplus -s $OracleConn 2>&1
        if (Test-Path $dbCsvFile) {
            $dbRecordsRaw = Get-Content $dbCsvFile | Where-Object { $_.Trim() -ne '' }
            Write-Host "  sqlplus: $($dbRecordsRaw.Count) Zeilen"
        } else { Write-Host "  FEHLER: SPOOL-Datei nicht erzeugt." -ForegroundColor Red; return }
    } elseif ($DbCsv -ne '') {
        if (-not (Test-Path $DbCsv)) { Write-Host "  FEHLER: $DbCsv nicht gefunden." -ForegroundColor Red; return }
        $dbRecordsRaw = Get-Content $DbCsv | Where-Object { $_.Trim() -ne '' }
        Write-Host "  CSV: $($dbRecordsRaw.Count) Zeilen"
    }

    $dbSkippedHeader = $false
    foreach ($line in $dbRecordsRaw) {
        $line = $line.Trim()
        if ($line -eq '' -or $line -match '^-+') { continue }
        if (-not $dbSkippedHeader -and $line -match 'NET_NR|SHORT_NAME') { $dbSkippedHeader = $true; continue }
        $parts = $line -split ';'
        if ($parts.Count -lt 4) { $parts = $line -split ',' }
        if ($parts.Count -lt 4) { continue }
        $netNr = $parts[0].Trim(); $shortNm = $parts[1].Trim()
        $refTs = ($parts[2].Trim() -replace '[^0-9]', '')
        if ($refTs.Length -lt 12) { continue }
        $refTs = $refTs.Substring(0, 12) + '00'

        $combo = "$netNr|$shortNm"
        $key = "$combo|$refTs"
        if (-not $DbKeys.ContainsKey($key)) {
            if (-not $DbCnt.ContainsKey($combo)) { $DbCnt[$combo] = 0 }
            $DbCnt[$combo]++
        }
        $DbKeys[$key] = $parts[3].Trim()
    }
    Write-Host "  DB-Keys (dedup): $($DbKeys.Count)"
    $dbLoaded = $true
} else {
    Write-Host "`n=== DB uebersprungen (kein -OracleConn / -DbCsv) ===" -ForegroundColor DarkGray
}

# ============================================================
# 5. InfluxDB-API laden (optional)
# ============================================================
$ApiKeys = @{}; $ApiCnt = @{}; $apiLoaded = $false

if ($CheckApi) {
    Write-Host "`n=== InfluxDB-API Direktabfrage ===" -ForegroundColor Cyan
    $keyFile = Join-Path $BasePath '.key'
    if (-not (Test-Path $keyFile)) { Write-Host "  FEHLER: $keyFile nicht gefunden." -ForegroundColor Red; return }
    $apiKey = ((Get-Content $keyFile | Select-Object -First 1).Trim() -replace '^API Key:\s*', '').Trim()

    $apiTsFrom = $inbTsMin.Substring(0,4) + '-' + $inbTsMin.Substring(4,2) + '-' + $inbTsMin.Substring(6,2) + 'T' + $inbTsMin.Substring(8,2) + ':' + $inbTsMin.Substring(10,2) + ':00Z'
    $apiTsTo   = $inbTsMax.Substring(0,4) + '-' + $inbTsMax.Substring(4,2) + '-' + $inbTsMax.Substring(6,2) + 'T' + $inbTsMax.Substring(8,2) + ':' + $inbTsMax.Substring(10,2) + ':59Z'

    $influxQuery = "SELECT value FROM ""measurements"" WHERE time >= '$apiTsFrom' AND time < '$apiTsTo' AND ""channel"" !~ /^link-/ GROUP BY node, sensor, unit"
    $apiBaseUrl = 'https://bafu-hydrometrie.decentlab.com/api/datasources/proxy/uid/main/query'
    $apiBody = @{ q = $influxQuery; db = 'main'; epoch = 'ms' }
    $headers = @{ 'Authorization' = "Bearer $apiKey" }

    Write-Host "  Zeitbereich: $apiTsFrom - $apiTsTo"
    $restParams = @{ Uri = $apiBaseUrl; Headers = $headers; Body = $apiBody; Method = 'Get'; TimeoutSec = 120 }
    if ($Proxy -ne '') { $restParams['Proxy'] = $Proxy; $restParams['ProxyUseDefaultCredentials'] = $true }

    try {
        $apiResponse = Invoke-RestMethod @restParams
    } catch {
        Write-Host "  FEHLER: $_" -ForegroundColor Red
        if ($Proxy -eq '') { Write-Host "  Tipp: -Proxy 'http://proxy.meteoswiss.ch:8080'" -ForegroundColor Yellow }
        Write-Host "  Fahre ohne API-Daten fort." -ForegroundColor Yellow
        $CheckApi = $false
    }

    if ($CheckApi) {
        foreach ($result in $apiResponse.results) {
            foreach ($series in $result.series) {
                $node = $series.tags.node; $sensor = $series.tags.sensor
                if (-not $StationMap.ContainsKey($node))  { continue }
                if (-not $ParamMap.ContainsKey($sensor))  { continue }
                $stOut = $StationMap[$node]; $parOut = $ParamMap[$sensor]
                $combo = "$stOut|$parOut"

                foreach ($val in $series.values) {
                    $tsMs = [long]$val[0]; $value = $val[1]

                    if ($ParamRangeMax.ContainsKey($parOut)) {
                        if ([double]$value -lt $ParamRangeMin[$parOut] -or [double]$value -ge $ParamRangeMax[$parOut]) { continue }
                    }

                    $tsTrunc = Convert-EpochToMinuteKey $tsMs
                    $key = "$combo|$tsTrunc"
                    if (-not $ApiKeys.ContainsKey($key)) {
                        if (-not $ApiCnt.ContainsKey($combo)) { $ApiCnt[$combo] = 0 }
                        $ApiCnt[$combo]++
                    }
                    $ApiKeys[$key] = $value
                }
            }
        }
        Write-Host "  API-Keys (dedup): $($ApiKeys.Count)"
        $apiLoaded = $true
    }
}

# ============================================================
# 6. PIPELINE-MATRIX (Kernstueck)
# ============================================================
Write-Host "`n=== Pipeline-Matrix: Records pro Soll-Station x Parameter ===" -ForegroundColor Cyan
Write-Host "    (Zeitfenster Inbound: $inbTsMin - $inbTsMax)"
Write-Host ""

# Archiv-Keys auf Inbound-Zeitfenster einschraenken fuer fairen Vergleich
$ArchCntInWindow = @{}
foreach ($key in $ArchKeys.Keys) {
    $ts = ($key -split '\|')[2]
    if ($ts -ge $inbTsMin -and $ts -le $inbTsMax) {
        $combo = ($key -split '\|')[0] + '|' + ($key -split '\|')[1]
        if (-not $ArchCntInWindow.ContainsKey($combo)) { $ArchCntInWindow[$combo] = 0 }
        $ArchCntInWindow[$combo]++
    }
}

# Header
$hdrApi  = if ($apiLoaded)  { '{0,7}' -f 'API' }    else { '' }
$hdrDb   = if ($dbLoaded)   { '{0,7}  {1,10}' -f 'DB', 'Arch->DB' } else { '' }
$hdrApiL = if ($apiLoaded)  { '{0,10}' -f 'API->Inb' } else { '' }
Write-Host ("  {0,-8} {1,5} {2,-10} $hdrApi {3,7} {4,7} $hdrApiL {5,10} $hdrDb" -f `
    'Station', 'Node', 'Parameter', 'Inbound', 'Archiv', 'Inb->Arch')
Write-Host ("  " + ('-' * (75 + $(if ($apiLoaded) { 18 } else { 0 }) + $(if ($dbLoaded) { 19 } else { 0 }))))

$totalApi = 0; $totalInb = 0; $totalArch = 0; $totalDb = 0
$totalLossApiInb = 0; $totalLossInbArch = 0; $totalLossArchDb = 0
$stationsWithDbLoss = @{}

foreach ($comboKey in ($SollCombos.Keys | Sort-Object)) {
    $p = $comboKey -split '\|'
    $stOut = $p[0]; $parOut = $p[1]
    $nodeId = if ($StationMapR.ContainsKey($stOut)) { $StationMapR[$stOut] } else { '?' }

    $cApi  = if ($ApiCnt.ContainsKey($comboKey))          { $ApiCnt[$comboKey] }          else { 0 }
    $cInb  = if ($InbCnt.ContainsKey($comboKey))          { $InbCnt[$comboKey] }          else { 0 }
    $cArch = if ($ArchCntInWindow.ContainsKey($comboKey)) { $ArchCntInWindow[$comboKey] } else { 0 }
    $cDb   = if ($DbCnt.ContainsKey($comboKey))           { $DbCnt[$comboKey] }           else { 0 }

    # Deltas
    $dApiInb  = if ($apiLoaded) { $cInb - $cApi }   else { 0 }
    $dInbArch = $cArch - $cInb
    $dArchDb  = if ($dbLoaded)  { $cDb - $cArch }   else { 0 }

    $totalApi += $cApi; $totalInb += $cInb; $totalArch += $cArch; $totalDb += $cDb
    if ($dApiInb -lt 0)  { $totalLossApiInb  += (-$dApiInb) }
    if ($dInbArch -lt 0) { $totalLossInbArch += (-$dInbArch) }
    if ($dArchDb -lt 0)  { $totalLossArchDb  += (-$dArchDb); $stationsWithDbLoss[$comboKey] = $dArchDb }

    # Farbe: rot wenn negative Deltas, gelb wenn 0 Records
    $color = 'Green'
    if ($dArchDb -lt 0 -or $dInbArch -lt 0 -or $dApiInb -lt 0) { $color = 'Red' }
    elseif ($cInb -eq 0) { $color = 'Yellow' }

    # Zeile formatieren
    $colApi  = if ($apiLoaded)  { '{0,7}' -f $cApi }  else { '' }
    $colDb   = if ($dbLoaded)   { '{0,7}  {1,10}' -f $cDb, $dArchDb }  else { '' }
    $colApiL = if ($apiLoaded)  { '{0,10}' -f $dApiInb } else { '' }

    Write-Host ("  {0,-8} {1,5} {2,-10} $colApi {3,7} {4,7} $colApiL {5,10} $colDb" -f `
        $stOut, $nodeId, $parOut, $cInb, $cArch, $dInbArch) -ForegroundColor $color
}

# Summenzeile
Write-Host ("  " + ('-' * (75 + $(if ($apiLoaded) { 18 } else { 0 }) + $(if ($dbLoaded) { 19 } else { 0 }))))
$colApi  = if ($apiLoaded)  { '{0,7}' -f $totalApi }  else { '' }
$colDb   = if ($dbLoaded)   { '{0,7}  {1,10}' -f $totalDb, '' }  else { '' }
$colApiL = if ($apiLoaded)  { '{0,10}' -f '' } else { '' }
Write-Host ("  {0,-8} {1,5} {2,-10} $colApi {3,7} {4,7} $colApiL {5,10} $colDb" -f `
    'TOTAL', '', '', $totalInb, $totalArch, '') -ForegroundColor Cyan

# ============================================================
# 7. Zusammenfassung Verluste
# ============================================================
Write-Host "`n=== Verlustanalyse ===" -ForegroundColor Cyan

Write-Host ""
Write-Host "  Inbound -> Archiv (Key-Match, zuverlaessig):" -ForegroundColor Cyan
# Exakter Key-Vergleich: Inbound-Key existiert in Archiv?
$inbNotArch = 0; $archNotInb = 0
foreach ($k in $InbKeys.Keys) {
    if (-not $ArchKeys.ContainsKey($k)) { $inbNotArch++ }
}
foreach ($k in $ArchKeys.Keys) {
    $ts = ($k -split '\|')[2]
    if ($ts -ge $inbTsMin -and $ts -le $inbTsMax) {
        if (-not $InbKeys.ContainsKey($k)) { $archNotInb++ }
    }
}
Write-Host "  Keys im Inbound, nicht im Archiv:  $inbNotArch" -ForegroundColor $(if ($inbNotArch -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Keys im Archiv, nicht im Inbound:  $archNotInb" -ForegroundColor $(if ($archNotInb -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  -> Konvertierung: $(if ($inbNotArch -eq 0 -and $archNotInb -eq 0) { 'VERLUSTFREI' } else { 'VERLUST ERKANNT' })" -ForegroundColor $(if ($inbNotArch -eq 0) { 'Green' } else { 'Red' })

if ($dbLoaded) {
    Write-Host ""
    Write-Host "  Archiv -> DB (Anzahlvergleich pro Station x Parameter):" -ForegroundColor Cyan
    Write-Host "  (Key-Match unzuverlaessig wegen Polling-Ueberlappung/Minutenversatz)" -ForegroundColor DarkGray
    if ($stationsWithDbLoss.Count -eq 0) {
        Write-Host "  -> DB-Ladung: VERLUSTFREI" -ForegroundColor Green
    } else {
        Write-Host "  -> DB-Ladung: VERLUST bei $($stationsWithDbLoss.Count) Kombination(en):" -ForegroundColor Red
        foreach ($comboKey in ($stationsWithDbLoss.Keys | Sort-Object)) {
            $p = $comboKey -split '\|'
            $nodeId = if ($StationMapR.ContainsKey($p[0])) { $StationMapR[$p[0]] } else { '?' }
            Write-Host "    Station $($p[0]) (Node $nodeId) / $($p[1]): $($stationsWithDbLoss[$comboKey]) Records" -ForegroundColor Red
        }
    }
}

if ($apiLoaded) {
    Write-Host ""
    Write-Host "  InfluxDB-API -> Inbound (Key-Match):" -ForegroundColor Cyan
    $apiNotInb = 0; $apiNotInbByCombo = @{}
    foreach ($k in $ApiKeys.Keys) {
        if (-not $InbKeys.ContainsKey($k)) {
            $apiNotInb++
            $combo = ($k -split '\|')[0] + '|' + ($k -split '\|')[1]
            if (-not $apiNotInbByCombo.ContainsKey($combo)) { $apiNotInbByCombo[$combo] = 0 }
            $apiNotInbByCombo[$combo]++
        }
    }
    Write-Host "  Keys in API, nicht im Inbound: $apiNotInb" -ForegroundColor $(if ($apiNotInb -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  -> Polling: $(if ($apiNotInb -eq 0) { 'VERLUSTFREI' } else { 'VERLUST ERKANNT' })" -ForegroundColor $(if ($apiNotInb -eq 0) { 'Green' } else { 'Red' })
    if ($apiNotInb -gt 0) {
        foreach ($comboKey in ($apiNotInbByCombo.Keys | Sort-Object)) {
            $p = $comboKey -split '\|'
            $nodeId = if ($StationMapR.ContainsKey($p[0])) { $StationMapR[$p[0]] } else { '?' }
            Write-Host "    Station $($p[0]) (Node $nodeId) / $($p[1]): $($apiNotInbByCombo[$comboKey]) Keys" -ForegroundColor Red
        }
    }
}

# ============================================================
# 8. Fehlende Inbound-Slots (Polling-Luecken)
# ============================================================
if ($missingSlots.Count -gt 0) {
    Write-Host "`n=== Fehlende Airflow-Polling-Slots ===" -ForegroundColor Yellow
    foreach ($ms in $missingSlots) { Write-Host "  $ms" -ForegroundColor Yellow }
    Write-Host "  Diese Slots verursachen Datenverlust bei allen Stationen." -ForegroundColor Yellow
}

Write-Host "`n=== Analyse abgeschlossen ===" -ForegroundColor Cyan
