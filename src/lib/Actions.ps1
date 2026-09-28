# =============================================================================
#  GPU BOOSTER 920MX - Acciones de optimizacion con copia de seguridad
#  Cada cambio se apunta en backup\sesion_activa.json ANTES de hacerse, para
#  poder deshacerlo aunque el programa se cierre de golpe.
# =============================================================================

$script:StateDir = $null
$script:Session = $null

function Initialize-BoosterState {
    param([string]$Root)
    $script:StateDir = Join-Path $Root 'backup'
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
}
function Get-SessionPath { return (Join-Path $script:StateDir 'sesion_activa.json') }
function Get-BaselinePath { return (Join-Path $script:StateDir 'estado_original.json') }

function Start-BoostSession {
    $script:Session = [pscustomobject]@{ Started = (Get-Date).ToString('s'); Changes = New-Object System.Collections.ArrayList }
    Save-BoostSession
}
function Save-BoostSession {
    if ($script:Session) { ConvertTo-Json -InputObject $script:Session -Depth 6 | Out-File (Get-SessionPath) -Encoding UTF8 }
}
function Add-BoostChange {
    param([hashtable]$Change)
    [void]$script:Session.Changes.Add([pscustomobject]$Change)
    Save-BoostSession
}
function Read-PendingSession {
    $p = Get-SessionPath
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

# ------------------------------------------------------------------ Energia
$script:BoostPower = @(
    # Politica de turbo: 0 = sin turbo, 100 = turbo siempre que se pueda.
    @{ Name = 'Politica de turbo (PERFBOOSTPOL)'; Setting = '45bcc044-d885-43e2-8605-ee0ec6e96b59'; Target = 100; Better = 'max' },
    # Frecuencia maxima del procesador en MHz: 0 = sin limite.
    @{ Name = 'Frecuencia maxima CPU (PROCFREQMAX)'; Setting = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'; Target = 0; Better = 'zero' },
    @{ Name = 'Modo turbo (PERFBOOSTMODE)'; Setting = 'be337238-0d82-4146-a960-4f3749d470c7'; Target = 2; Better = 'boostmode' },
    @{ Name = 'Estado maximo CPU (PROCTHROTTLEMAX)'; Setting = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Target = 100; Better = 'max' }
)

function Test-PowerValueLimits {
    param($Def, [int]$Current)
    switch ($Def.Better) {
        'max'       { return ($Current -lt $Def.Target) }
        'zero'      { return ($Current -ne 0) }
        'boostmode' { return ($Current -eq 0) }   # 0 = deshabilitado; 1-6 permiten turbo
    }
    return $false
}

function Set-PowerAC {
    param([string]$Setting, [int]$Value)
    & powercfg.exe /setacvalueindex SCHEME_CURRENT $script:PowerGuids.SubProcessor $Setting $Value 2>$null | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
}

# Devuelve los ajustes de energia que estan limitando el turbo (con su valor actual).
function Get-PowerLimits {
    $out = @()
    foreach ($d in $script:BoostPower) {
        $v = Get-PowerSettingValue $script:PowerGuids.SubProcessor $d.Setting
        if ($v -and (Test-PowerValueLimits $d $v.AC)) {
            $out += [pscustomobject]@{ Name = $d.Name; Setting = $d.Setting; Current = $v.AC; Target = $d.Target }
        }
    }
    return $out
}

# ------------------------------------------------------------- Aplicaciones
# Aplicaciones de segundo plano que se pueden cerrar mientras juegas.
$script:BoostApps = @(
    @{ Key = 'Steam';    Procs = @('steam', 'steamwebhelper'); Reopen = $true },
    @{ Key = 'Discord';  Procs = @('Discord'); Reopen = $true },
    @{ Key = 'Chrome';   Procs = @('chrome'); Reopen = $false },
    @{ Key = 'Teams';    Procs = @('ms-teams', 'Teams'); Reopen = $true },
    @{ Key = 'OneDrive'; Procs = @('OneDrive'); Reopen = $true }
)

function Get-RunningBoostApps {
    $r = @()
    foreach ($a in $script:BoostApps) {
        $ps = @(Get-Process -Name $a.Procs -ErrorAction SilentlyContinue)
        if ($ps.Count) {
            $mb = [math]::Round((($ps | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1MB)
            $main = $ps | Where-Object { $_.ProcessName -eq $a.Procs[0] } | Select-Object -First 1
            $path = $null; try { $path = $main.Path } catch {}
            $r += [pscustomobject]@{ Key = $a.Key; Procs = $a.Procs; MB = $mb; Path = $path; Reopen = $a.Reopen }
        }
    }
    return $r
}

function Stop-BoostApp {
    param($App)
    if ($App.Key -eq 'Steam' -and $App.Path) {
        # Cierre ordenado de Steam.
        try { Start-Process -FilePath $App.Path -ArgumentList '-shutdown' -ErrorAction Stop } catch {}
        for ($i = 0; $i -lt 10 -and @(Get-Process -Name $App.Procs -ErrorAction SilentlyContinue).Count; $i++) { Start-Sleep -Seconds 1 }
    } else {
        foreach ($p in @(Get-Process -Name $App.Procs -ErrorAction SilentlyContinue)) { try { [void]$p.CloseMainWindow() } catch {} }
        for ($i = 0; $i -lt 5 -and @(Get-Process -Name $App.Procs -ErrorAction SilentlyContinue).Count; $i++) { Start-Sleep -Seconds 1 }
    }
    Get-Process -Name $App.Procs -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-BoostApp {
    param($Change)
    if (-not $Change.Path -or -not (Test-Path $Change.Path)) { return }
    if ($Change.Key -eq 'Discord') {
        $upd = Join-Path (Split-Path (Split-Path $Change.Path -Parent) -Parent) 'Update.exe'
        if (Test-Path $upd) { Start-Process -FilePath $upd -ArgumentList '--processStart', 'Discord.exe'; return }
    }
    if ($Change.Key -eq 'Steam') { Start-Process -FilePath $Change.Path -ArgumentList '-silent'; return }
    Start-Process -FilePath $Change.Path
}

# ------------------------------------------------------------ Process Lasso
function Suspend-ProcessLasso {
    $done = @()
    foreach ($svc in @(Get-Service -Name 'ProcessGovernor', 'Process Governor' -ErrorAction SilentlyContinue)) {
        if ($svc.Status -eq 'Running') {
            Add-BoostChange @{ Kind = 'service'; Name = $svc.Name }
            try { Stop-Service -Name $svc.Name -Force -ErrorAction Stop; $done += "servicio $($svc.Name)" } catch {}
        }
    }
    foreach ($p in @(Get-Process -Name 'ProcessLasso', 'ProcessGovernor' -ErrorAction SilentlyContinue)) {
        $path = $null; try { $path = $p.Path } catch {}
        Add-BoostChange @{ Kind = 'process'; Name = $p.ProcessName; Path = $path }
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $done += $p.ProcessName } catch {}
    }
    return $done
}

# ------------------------------------------------------------------- Roblox
function Get-RobloxGameProcess {
    $ps = @(Get-RobloxProcesses)
    if ($ps.Count -eq 0) { return $null }
    $withWindow = @($ps | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    $pool = if ($withWindow.Count) { $withWindow } else { $ps }
    return ($pool | Sort-Object { try { $_.StartTime } catch { [datetime]::MinValue } } -Descending | Select-Object -First 1)
}

function Get-RobloxDuplicates {
    param($Game)
    if (-not $Game) { return @() }
    return @(Get-RobloxProcesses | Where-Object { $_.Id -ne $Game.Id })
}

# -------------------------------------------------------------- Restaurar
function Restore-BoostSession {
    param($Session, [bool]$ReopenApps = $true)
    if (-not $Session) { return @() }
    $log = @()
    $changes = @($Session.Changes)
    [array]::Reverse($changes)
    $powerTouched = $false
    foreach ($c in $changes) {
        try {
            switch ($c.Kind) {
                'power' {
                    & powercfg.exe /setacvalueindex SCHEME_CURRENT $script:PowerGuids.SubProcessor $c.Setting ([int]$c.Original) 2>$null | Out-Null
                    $powerTouched = $true; $log += "Energia: $($c.Name) vuelve a $($c.Original)"
                }
                'service' { Start-Service -Name $c.Name -ErrorAction Stop; $log += "Servicio $($c.Name) arrancado de nuevo" }
                'process' {
                    if ($c.Path -and (Test-Path $c.Path) -and -not (Get-Process -Name $c.Name -ErrorAction SilentlyContinue)) {
                        Start-Process -FilePath $c.Path -WindowStyle Minimized; $log += "$($c.Name) abierto de nuevo"
                    }
                }
                'closedApp' { if ($ReopenApps -and $c.Reopen) { Start-BoostApp $c; $log += "$($c.Key) abierto de nuevo" } }
                'priority' {
                    $p = Get-Process -Id ([int]$c.Pid) -ErrorAction SilentlyContinue
                    if ($p) { $p.PriorityClass = $c.Original; $log += "Prioridad de Roblox vuelve a $($c.Original)" }
                }
            }
        } catch { $log += "No se pudo restaurar $($c.Kind): $($_.Exception.Message)" }
    }
    if ($powerTouched) { & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null }
    Remove-Item (Get-SessionPath) -Force -ErrorAction SilentlyContinue
    $script:Session = $null
    return $log
}

# ------------------------------------------------------- Estado original
# Se guarda UNA vez (la primera vez que se usa el Booster) para "Restaurar todo".
function Save-Baseline {
    if (Test-Path (Get-BaselinePath)) { return }
    $pw = @{}
    foreach ($d in $script:BoostPower) {
        $v = Get-PowerSettingValue $script:PowerGuids.SubProcessor $d.Setting
        if ($v) { $pw[$d.Setting] = $v.AC }
    }
    $cs = Get-Cim Win32_ComputerSystem | Select-Object -First 1
    $pf = @(Get-Cim Win32_PageFileSetting | ForEach-Object { @{ Name = $_.Name; InitialSize = $_.InitialSize; MaximumSize = $_.MaximumSize } })
    ConvertTo-Json -InputObject @{ Saved = (Get-Date).ToString('s'); PowerAC = $pw; AutomaticPagefile = $cs.AutomaticManagedPagefile; PageFiles = $pf } -Depth 5 |
        Out-File (Get-BaselinePath) -Encoding UTF8
}

function Restore-Baseline {
    $p = Get-BaselinePath
    if (-not (Test-Path $p)) { return @('No hay estado original guardado: el Booster nunca cambio nada permanente.') }
    $b = Get-Content $p -Raw | ConvertFrom-Json
    $log = @()
    foreach ($prop in $b.PowerAC.PSObject.Properties) {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT $script:PowerGuids.SubProcessor $prop.Name ([int]$prop.Value) 2>$null | Out-Null
    }
    & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
    $log += 'Ajustes de energia del procesador restaurados.'
    $cs = Get-CimInstance Win32_ComputerSystem
    if ([bool]$cs.AutomaticManagedPagefile -ne [bool]$b.AutomaticPagefile) {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = [bool]$b.AutomaticPagefile }
        if (-not $b.AutomaticPagefile) {
            foreach ($pf in @($b.PageFiles)) {
                $cur = Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -eq $pf.Name }
                if ($cur) { Set-CimInstance -InputObject $cur -Property @{ InitialSize = [uint32]$pf.InitialSize; MaximumSize = [uint32]$pf.MaximumSize } }
                else { New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $pf.Name; InitialSize = [uint32]$pf.InitialSize; MaximumSize = [uint32]$pf.MaximumSize } | Out-Null }
            }
        }
        $log += 'Archivo de paginacion restaurado (se aplica al reiniciar).'
    }
    return $log
}

function Set-AutomaticPagefile {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { return $false }
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
    return $true
}

# --------------------------------------------------------------- Benchmark
function Get-BenchmarkComparison {
    param($Before, $After)
    if (-not $After) { return $null }
    $r = [ordered]@{ AfterAvg = $After.FpsAvg; After1Low = $After.Fps1Low; BeforeAvg = $null; DeltaFps = $null; DeltaPct = $null; Delta1Low = $null }
    if ($Before -and $Before.FpsAvg) {
        $r.BeforeAvg = [double]$Before.FpsAvg
        $r.DeltaFps  = $After.FpsAvg - $r.BeforeAvg
        $r.DeltaPct  = 100 * $r.DeltaFps / $r.BeforeAvg
        if ($Before.Fps1Low) { $r.Delta1Low = $After.Fps1Low - [double]$Before.Fps1Low; $r.Before1Low = [double]$Before.Fps1Low }
    }
    return [pscustomobject]$r
}

function Get-LastDiagnosticFrames {
    param([string]$ReportsDir)
    $j = Get-ChildItem $ReportsDir -Filter 'diagnostico.json' -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $j) { return $null }
    try {
        $d = Get-Content $j.FullName -Raw | ConvertFrom-Json
        if ($d.Analysis.Frames) { return [pscustomobject]@{ FpsAvg = $d.Analysis.Frames.FpsAvg; Fps1Low = $d.Analysis.Frames.Fps1Low; When = $d.Meta.Date } }
    } catch {}
    return $null
}
