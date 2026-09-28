# =============================================================================
#  GPU BOOSTER 920MX - Analisis (funciones puras, sin acceso al sistema)
#  Todo lo de este archivo trabaja solo con datos ya medidos, para poder
#  probarlo con datos sinteticos (tests/Run-Tests.ps1).
# =============================================================================

# Umbrales usados por el analisis. Estan juntos para poder revisarlos.
$script:Thresholds = [ordered]@{
    GpuBoundUtil         = 92    # % uso GPU (mediana) => GPU al limite
    GpuBusyUtil          = 85    # % uso GPU (mediana) => GPU muy cargada
    GpuBusyRatioBound    = 0.90  # GPUBusy/FrameTime (PresentMon) => GPU limita
    GpuBusyRatioCpu      = 0.75  # por debajo => la GPU espera a la CPU
    CoreHotBound         = 90    # % del nucleo/hilo mas cargado => hilo saturado
    CoreHotBusy          = 80
    RobloxThreadBound    = 85    # % de un nucleo usado por el hilo principal de Roblox
    CpuTotalBound        = 90    # % CPU total
    CpuPerfBelowBase     = 85    # % rendimiento CPU (100 = frecuencia base)
    GpuTempHot           = 87    # C, 920MX empieza a reducir relojes en torno a 90-95 C
    GpuTempCritical      = 93
    CpuZoneHot           = 90    # C (zona termica ACPI, aproximada)
    RamUsedHigh          = 85    # % RAM usada
    RamAvailLowMB        = 1000
    CommitHigh           = 90    # % memoria comprometida sobre limite
    PageReadsHigh        = 50    # lecturas de pagina/s sostenidas => paginacion real
    VramFull             = 0.95  # fraccion de VRAM usada
    FpsCapTolerancePct   = 4     # +-% alrededor de un limite de FPS tipico
}

# Bits de clocks_throttle_reasons / clocks_event_reasons (NVML)
$script:NvThrottleBits = [ordered]@{
    0x1   = 'GPU inactiva'
    0x2   = 'Relojes de aplicacion'
    0x4   = 'Limite de energia (SW power cap)'
    0x8   = 'Ralentizacion por hardware (HW slowdown)'
    0x10  = 'Sync boost'
    0x20  = 'Ralentizacion termica por software'
    0x40  = 'Ralentizacion termica por hardware'
    0x80  = 'Freno de energia por hardware'
    0x100 = 'Ajuste de reloj de pantalla'
}

function ConvertTo-NvBitmask {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = "$Value".Trim()
    if ($s -match '^0x([0-9a-fA-F]+)$') {
        return [Convert]::ToInt64($Matches[1], 16)
    }
    $n = 0L
    if ([long]::TryParse($s, [ref]$n)) { return $n }
    return $null
}

function Get-NvThrottleText {
    param($Mask)
    if ($null -eq $Mask) { return 'no disponible' }
    if ($Mask -eq 0) { return 'ninguna' }
    # Ojo: indexar un [ordered] con un entero es POSICIONAL; se recorre con el enumerador.
    $names = foreach ($e in $script:NvThrottleBits.GetEnumerator()) { if ($Mask -band $e.Key) { $e.Value } }
    return ($names -join ', ')
}

function Get-Stats {
    param([object[]]$Values)
    $v = @($Values | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $sum = 0.0; foreach ($x in $v) { $sum += $x }
    $avg = $sum / $v.Count
    $var = 0.0; foreach ($x in $v) { $var += ($x - $avg) * ($x - $avg) }
    return [pscustomobject]@{
        Count = $v.Count
        Min   = $v[0]
        Max   = $v[$v.Count - 1]
        Avg   = $avg
        P50   = Get-Percentile -Sorted $v -P 50
        P95   = Get-Percentile -Sorted $v -P 95
        P99   = Get-Percentile -Sorted $v -P 99
        StdDev = [math]::Sqrt($var / $v.Count)
    }
}

function Get-Percentile {
    param([double[]]$Sorted, [double]$P)
    if ($Sorted.Count -eq 0) { return $null }
    if ($Sorted.Count -eq 1) { return $Sorted[0] }
    $rank = ($P / 100.0) * ($Sorted.Count - 1)
    $lo = [math]::Floor($rank); $hi = [math]::Ceiling($rank)
    if ($lo -eq $hi) { return $Sorted[[int]$lo] }
    return $Sorted[[int]$lo] + ($Sorted[[int]$hi] - $Sorted[[int]$lo]) * ($rank - $lo)
}

# Estadisticas de fotogramas a partir de frame times (ms) reales de PresentMon.
function Get-FrameStats {
    param([double[]]$FrameTimesMs, [double[]]$GpuBusyMs)
    $ft = @($FrameTimesMs | Where-Object { $_ -gt 0 -and $_ -lt 1000 })
    if ($ft.Count -lt 30) { return $null }
    $s = Get-Stats $ft
    $total = 0.0; foreach ($x in $ft) { $total += $x }
    $r = [ordered]@{
        Frames          = $ft.Count
        FpsAvg          = 1000.0 * $ft.Count / $total      # FPS medio real (frames / tiempo)
        FpsMin          = 1000.0 / $s.Max
        FpsMax          = 1000.0 / $s.Min
        Fps1Low         = 1000.0 / $s.P99                   # "1% low"
        FpsMedian       = 1000.0 / $s.P50
        FrameTimeAvgMs  = $s.Avg
        FrameTimeP50Ms  = $s.P50
        FrameTimeP99Ms  = $s.P99
        FrameTimeStdMs  = $s.StdDev
        GpuBusyRatioP50 = $null
    }
    if ($GpuBusyMs -and $GpuBusyMs.Count -eq $FrameTimesMs.Count) {
        $ratios = for ($i = 0; $i -lt $FrameTimesMs.Count; $i++) {
            if ($FrameTimesMs[$i] -gt 0 -and $FrameTimesMs[$i] -lt 1000 -and $GpuBusyMs[$i] -ge 0) {
                [math]::Min(1.0, $GpuBusyMs[$i] / $FrameTimesMs[$i])
            }
        }
        $rs = Get-Stats @($ratios)
        if ($rs) { $r.GpuBusyRatioP50 = $rs.P50 }
    }
    return [pscustomobject]$r
}

# Detecta si los FPS estan clavados en un limite (cap del juego o VSync).
function Find-FpsCap {
    param($FrameStats, [int[]]$KnownCaps = @(30, 60, 75, 120, 144, 240), [int]$RefreshHz = 0)
    if (-not $FrameStats) { return $null }
    $caps = @($KnownCaps)
    if ($RefreshHz -gt 0) { $caps += $RefreshHz }
    foreach ($c in ($caps | Sort-Object -Unique)) {
        $tol = $c * $script:Thresholds.FpsCapTolerancePct / 100.0
        if ([math]::Abs($FrameStats.FpsMedian - $c) -le $tol -and $FrameStats.FpsMax -le ($c * 1.15)) {
            return $c
        }
    }
    return $null
}

function New-Finding {
    param([string]$Type, [int]$Score, [string]$Title, [string[]]$Evidence, [string]$Explanation)
    [pscustomobject]@{
        Type        = $Type       # GPU | CPU | RAM | THERMAL | POWER | OTRO
        Score       = $Score      # 0-100 (fuerza de la evidencia)
        Level       = $(if ($Score -ge 70) { 'ALTA' } elseif ($Score -ge 40) { 'MEDIA' } else { 'BAJA' })
        Title       = $Title
        Evidence    = @($Evidence)
        Explanation = $Explanation
    }
}

function Get-Fraction {
    param([object[]]$Items, [scriptblock]$Predicate)
    $all = @($Items)
    if ($all.Count -eq 0) { return 0 }
    $n = @($all | Where-Object $Predicate).Count
    return $n / $all.Count
}

function Format-N { param($v, [int]$d = 0) if ($null -eq $v) { 'n/d' } else { [math]::Round([double]$v, $d).ToString([Globalization.CultureInfo]::InvariantCulture) } }

# -----------------------------------------------------------------------------
# Analisis conjunto del cuello de botella.
#   $Samples : muestras de Get-LiveSample (ver Collectors.ps1)
#   $Frames  : resultado de Get-FrameStats (o $null si no hay PresentMon)
#   $Context : datos estaticos relevantes (OnBattery, ProcThrottleMaxAC, ...)
# -----------------------------------------------------------------------------
function Invoke-BottleneckAnalysis {
    param([object[]]$Samples, $Frames, $Context)
    $T = $script:Thresholds
    $findings = New-Object System.Collections.ArrayList

    $all = @($Samples)
    $game = @($all | Where-Object { $_.RobloxRunning })
    $useGame = $game.Count -ge 3
    $S = if ($useGame) { $game } else { $all }

    $m = [ordered]@{
        SampleCount     = $S.Count
        GameSamples     = $game.Count
        GpuUtil         = Get-Stats ($S | ForEach-Object { $_.GpuUtil })
        GpuClock        = Get-Stats ($S | ForEach-Object { $_.GpuClockMHz })
        GpuMemClock     = Get-Stats ($S | ForEach-Object { $_.GpuMemClockMHz })
        GpuTemp         = Get-Stats ($S | ForEach-Object { $_.GpuTempC })
        GpuPower        = Get-Stats ($S | ForEach-Object { $_.GpuPowerW })
        VramUsed        = Get-Stats ($S | ForEach-Object { $_.VramUsedMB })
        CpuTotal        = Get-Stats ($S | ForEach-Object { $_.CpuTotal })
        CpuCoreMax      = Get-Stats ($S | ForEach-Object { $_.CpuCoreMax })
        CpuPerfPct      = Get-Stats ($S | ForEach-Object { $_.CpuPerfPct })
        CpuMHz          = Get-Stats ($S | ForEach-Object { $_.CpuMHz })
        CpuZoneTemp     = Get-Stats ($S | ForEach-Object { $_.ThermalZoneC })
        RamUsedPct      = Get-Stats ($S | ForEach-Object { $_.RamUsedPct })
        RamAvailMB      = Get-Stats ($S | ForEach-Object { $_.RamAvailMB })
        CommitPct       = Get-Stats ($S | ForEach-Object { $_.CommitPct })
        PageReads       = Get-Stats ($S | ForEach-Object { $_.PageReadsPerSec })
        RobloxCpu       = Get-Stats ($S | ForEach-Object { $_.RobloxCpuPct })
        RobloxMainThread= Get-Stats ($S | ForEach-Object { $_.RobloxTopThreadPct })
        BackgroundCpu   = Get-Stats ($S | ForEach-Object { if ($null -ne $_.CpuTotal -and $null -ne $_.RobloxCpuPct) { [math]::Max(0, $_.CpuTotal - $_.RobloxCpuPct) } })
        RobloxGpuNv     = Get-Stats ($S | ForEach-Object { $_.RobloxGpuNvidia })
        RobloxGpuOther  = Get-Stats ($S | ForEach-Object { $_.RobloxGpuOther })
        RobloxNvDedMB   = Get-Stats ($S | ForEach-Object { $_.RobloxNvDedicatedMB })
        RobloxOtherDedMB= Get-Stats ($S | ForEach-Object { $_.RobloxOtherDedicatedMB })
        CpuLimitFlags   = Get-Stats ($S | ForEach-Object { $_.CpuLimitFlags })
    }
    $vramTotal = ($S | Where-Object { $_.VramTotalMB } | Select-Object -First 1).VramTotalMB
    $gpuMaxClock = $Context.GpuMaxClockMHz

    # ---------------- Seleccion de GPU ----------------
    $gsel = Get-RobloxGpuVerdict -Metrics ([pscustomobject]$m) -UsedGameData $useGame
    if ($gsel.Code -eq 'IGPU') {
        [void]$findings.Add((New-Finding 'OTRO' 95 'Roblox esta renderizando con la GPU INTEGRADA, no con la 920MX' $gsel.Evidence `
            'Es la causa mas grave posible: la 920MX no se esta usando para el juego. Forzar la GPU de alto rendimiento para Roblox es la primera optimizacion.'))
    } elseif ($gsel.Code -eq 'DUDA') {
        [void]$findings.Add((New-Finding 'OTRO' 35 'No esta claro que grafica usa Roblox: los datos se contradicen' $gsel.Evidence `
            'Hace falta otra medicion antes de cambiar nada relacionado con la seleccion de GPU.'))
    }

    # Un limite de FPS (cap/VSync) hace que CPU y GPU esperen: en ese caso la
    # proporcion GPUBusy/FrameTime no indica quien limita y no se usa.
    $cap = Find-FpsCap -FrameStats $Frames -RefreshHz $Context.RefreshHz
    $useRatio = $Frames -and $null -ne $Frames.GpuBusyRatioP50 -and -not $cap

    # ---------------- GPU ----------------
    $gpuScore = 0; $gpuEv = @()
    if ($useRatio) {
        $r = $Frames.GpuBusyRatioP50
        $gpuEv += "GPUBusy/FrameTime (mediana) = $(Format-N ($r*100))% (PresentMon)"
        if ($r -ge $T.GpuBusyRatioBound) { $gpuScore = 90 } elseif ($r -ge 0.80) { $gpuScore = 60 }
    }
    if ($m.GpuUtil) {
        $gpuEv += "Uso GPU mediana $(Format-N $m.GpuUtil.P50)% (media $(Format-N $m.GpuUtil.Avg)%, p95 $(Format-N $m.GpuUtil.P95)%)"
        if ($m.GpuUtil.P50 -ge $T.GpuBoundUtil) { $gpuScore = [math]::Max($gpuScore, 80) }
        elseif ($m.GpuUtil.P50 -ge $T.GpuBusyUtil) { $gpuScore = [math]::Max($gpuScore, 55) }
    }
    if ($gpuScore -gt 0) {
        [void]$findings.Add((New-Finding 'GPU' $gpuScore 'La GPU (920MX) esta trabajando al limite' $gpuEv `
            'Si la GPU esta ocupada casi todo el tiempo de cada fotograma, los FPS dependen de su velocidad: ayudan que funcione en su reloj maximo sin bajar (gestion de energia NVIDIA), que no se caliente, y la memoria de video disponible.'))
    }
    if ($vramTotal -and $m.VramUsed -and ($m.VramUsed.P95 / $vramTotal) -ge $T.VramFull) {
        [void]$findings.Add((New-Finding 'GPU' 70 'VRAM llena (memoria de video de la 920MX)' @(
            "VRAM usada p95: $(Format-N $m.VramUsed.P95) MB de $(Format-N $vramTotal) MB") `
            'Con la VRAM llena, las texturas pasan a RAM del sistema por PCIe y aparecen tirones. Cerrar apps que usen la GPU NVIDIA libera VRAM; en Roblox la calidad de texturas depende del nivel grafico.'))
    }

    # ---------------- CPU ----------------
    $cpuScore = 0; $cpuEv = @()
    $gpuUtilP50 = if ($m.GpuUtil) { $m.GpuUtil.P50 } else { $null }
    if ($useRatio -and $Frames.GpuBusyRatioP50 -lt $T.GpuBusyRatioCpu) {
        $cpuEv += "La GPU solo esta ocupada el $(Format-N ($Frames.GpuBusyRatioP50*100))% de cada fotograma (PresentMon): espera al procesador"
        $cpuScore = 75
    }
    if ($m.RobloxMainThread) {
        $cpuEv += "Hilo mas cargado de Roblox: mediana $(Format-N $m.RobloxMainThread.P50)% de un nucleo (p95 $(Format-N $m.RobloxMainThread.P95)%)"
        if ($m.RobloxMainThread.P50 -ge $T.RobloxThreadBound -and ($null -eq $gpuUtilP50 -or $gpuUtilP50 -lt $T.GpuBusyUtil)) {
            $cpuScore = [math]::Max($cpuScore, 85)
        }
    }
    if ($m.CpuCoreMax) {
        $cpuEv += "Nucleo/hilo logico mas cargado: mediana $(Format-N $m.CpuCoreMax.P50)%"
        if ($m.CpuCoreMax.P50 -ge $T.CoreHotBound -and ($null -eq $gpuUtilP50 -or $gpuUtilP50 -lt 80)) {
            $cpuScore = [math]::Max($cpuScore, 70)
        } elseif ($m.CpuCoreMax.P50 -ge $T.CoreHotBusy -and ($null -eq $gpuUtilP50 -or $gpuUtilP50 -lt 70)) {
            $cpuScore = [math]::Max($cpuScore, 50)
        }
    }
    if ($m.CpuTotal) {
        $cpuEv += "CPU total: mediana $(Format-N $m.CpuTotal.P50)% (p95 $(Format-N $m.CpuTotal.P95)%)"
        if ($m.CpuTotal.P50 -ge $T.CpuTotalBound) { $cpuScore = [math]::Max($cpuScore, 80) }
    }
    if ($m.BackgroundCpu -and $m.BackgroundCpu.Avg -ge 10) {
        $cpuEv += "Procesos distintos de Roblox consumen de media $(Format-N $m.BackgroundCpu.Avg)% de CPU"
        if ($cpuScore -ge 40) { $cpuScore = [math]::Min(100, $cpuScore + 5) }
    }
    if ($cpuScore -gt 0) {
        [void]$findings.Add((New-Finding 'CPU' $cpuScore 'El procesador limita los FPS' $cpuEv `
            'Roblox prepara cada fotograma en un hilo principal. Si ese hilo esta saturado, la GPU espera y los FPS no suben aunque la GPU tenga margen. Ayudan: frecuencia de CPU alta y estable (plan de energia, temperatura), menos competencia de procesos en segundo plano y prioridad correcta del juego.'))
    }

    # ---------------- TERMICO ----------------
    $thScore = 0; $thEv = @()
    $thermBits = 0x20 -bor 0x40 -bor 0x8
    $fThr = Get-Fraction $S { $null -ne $_.GpuThrottleMask -and ($_.GpuThrottleMask -band $thermBits) }
    if ($fThr -gt 0.05) {
        $thEv += "GPU con ralentizacion termica/hardware activa en el $(Format-N ($fThr*100))% de las muestras"
        $thScore = [math]::Max($thScore, $(if ($fThr -gt 0.2) { 90 } else { 65 }))
    }
    if ($m.GpuTemp) {
        $thEv += "Temperatura GPU: media $(Format-N $m.GpuTemp.Avg) C, max $(Format-N $m.GpuTemp.Max) C"
        if ($m.GpuTemp.Max -ge $T.GpuTempCritical) { $thScore = [math]::Max($thScore, 70) }
        elseif ($m.GpuTemp.P95 -ge $T.GpuTempHot) { $thScore = [math]::Max($thScore, 45) }
    }
    if ($gpuMaxClock -and $m.GpuClock -and $m.GpuUtil -and $m.GpuUtil.P50 -ge 80) {
        $ratio = $m.GpuClock.P50 / $gpuMaxClock
        $thEv += "Reloj GPU bajo carga: mediana $(Format-N $m.GpuClock.P50) MHz de $(Format-N $gpuMaxClock) MHz maximos ($(Format-N ($ratio*100))%)"
        if ($ratio -lt 0.85 -and $m.GpuTemp -and $m.GpuTemp.P95 -ge $T.GpuTempHot) { $thScore = [math]::Max($thScore, 75) }
    }
    $fPassive = Get-Fraction $S { $null -ne $_.PassiveLimitPct -and $_.PassiveLimitPct -lt 100 }
    if ($fPassive -gt 0.05) {
        $thEv += "Windows aplica limite termico pasivo a la CPU en el $(Format-N ($fPassive*100))% de las muestras"
        $thScore = [math]::Max($thScore, 85)
    }
    $loaded = @($S | Where-Object { $_.CpuCoreMax -ge $T.CoreHotBusy -and $null -ne $_.CpuPerfPct })
    if ($loaded.Count -ge 3) {
        $fLow = Get-Fraction $loaded { $_.CpuPerfPct -lt $T.CpuPerfBelowBase }
        $fLim = Get-Fraction $loaded { $_.CpuLimitFlags -gt 0 }
        if ($fLow -gt 0.25) {
            $zoneHot = $m.CpuZoneTemp -and $m.CpuZoneTemp.Max -ge $T.CpuZoneHot
            $ev = "Con carga, la CPU funciona por debajo de su frecuencia base el $(Format-N ($fLow*100))% del tiempo (limite activo en el $(Format-N ($fLim*100))%)"
            if ($zoneHot -or $fPassive -gt 0) {
                $thEv += $ev; $thScore = [math]::Max($thScore, 75)
            } else {
                [void]$findings.Add((New-Finding 'POWER' 60 'La CPU no alcanza su frecuencia base con carga' @($ev) `
                    'Sin temperatura alta que lo explique, la causa suele ser el limite de potencia del portatil, el plan de energia o funcionar con bateria.'))
            }
        }
    }
    if ($m.CpuZoneTemp) { $thEv += "Zona termica ACPI (aprox. CPU): max $(Format-N $m.CpuZoneTemp.Max) C" }
    if ($thScore -gt 0) {
        [void]$findings.Add((New-Finding 'THERMAL' $thScore 'Limitacion por temperatura (thermal throttling)' $thEv `
            'Cuando el portatil se calienta, baja las frecuencias de CPU y/o GPU para protegerse. En muchos portatiles CPU y GPU comparten el mismo disipador: el calor de uno reduce la frecuencia del otro. Aqui la prioridad es refrigeracion, no forzar mas.'))
    }

    # ---------------- ENERGIA ----------------
    $pwScore = 0; $pwEv = @()
    $fBat = Get-Fraction $S { $_.OnBattery -eq $true }
    if ($fBat -gt 0.1) {
        $pwEv += "Funcionando con BATERIA en el $(Format-N ($fBat*100))% de las muestras"
        $pwScore = 90
    }
    $fPow = Get-Fraction $S { $null -ne $_.GpuThrottleMask -and ($_.GpuThrottleMask -band (0x4 -bor 0x80)) }
    if ($fPow -gt 0.2 -and $m.GpuUtil -and $m.GpuUtil.P50 -ge 80) {
        $pwEv += "GPU limitada por energia en el $(Format-N ($fPow*100))% de las muestras"
        $pwScore = [math]::Max($pwScore, 55)
    }
    if ($null -ne $Context.ProcThrottleMaxAC -and $Context.ProcThrottleMaxAC -lt 100) {
        $pwEv += "El plan de energia limita la CPU al $($Context.ProcThrottleMaxAC)% (estado maximo del procesador, con cargador)"
        $pwScore = [math]::Max($pwScore, 60)
    }
    if ($Context.PowerOverlayName -match 'bateria') {
        $pwEv += "Modo de energia de Windows: $($Context.PowerOverlayName)"
        $pwScore = [math]::Max($pwScore, 50)
    }
    if ($pwScore -gt 0) {
        [void]$findings.Add((New-Finding 'POWER' $pwScore 'Limitacion por energia' $pwEv `
            'Con bateria o con un plan de ahorro, Windows y el driver limitan frecuencias de CPU y GPU. Con el cargador y un plan de alto rendimiento la CPU/GPU pueden mantener su frecuencia maxima.'))
    }

    # ---------------- Turbo de la CPU ----------------
    $turboPct = $Context.TurboMaxPerfPct
    $gamePerfMax = if ($m.CpuPerfPct) { $m.CpuPerfPct.Max } else { $null }
    if (($null -ne $turboPct -and $turboPct -lt 105) -or ($null -eq $turboPct -and $useGame -and $null -ne $gamePerfMax -and $gamePerfMax -lt 100 -and $m.CpuCoreMax -and $m.CpuCoreMax.P50 -ge 80)) {
        $ev = @()
        if ($null -ne $turboPct) { $ev += "Prueba con un hilo al 100%: la CPU no paso del $(Format-N $turboPct)% de la frecuencia base de Windows" }
        if ($null -ne $gamePerfMax) { $ev += "Durante el juego: maximo $(Format-N $gamePerfMax)% ($(Format-N $m.CpuMHz.Max) MHz)" }
        if ($m.CpuLimitFlags -and $m.CpuLimitFlags.Max -gt 0) { $ev += "Windows marca limite de rendimiento activo (flags $(Format-N $m.CpuLimitFlags.Max))" }
        $cpuLimited = @($findings | Where-Object { $_.Type -eq 'CPU' -and $_.Score -ge 40 }).Count -gt 0
        [void]$findings.Add((New-Finding 'POWER' $(if ($cpuLimited) { 65 } else { 45 }) 'La CPU no usa su turbo (se queda en la frecuencia base)' $ev `
            'El turbo permite a la CPU subir por encima de su frecuencia base cuando hay margen. Si esta bloqueado (modo de energia del fabricante, driver termico de Intel, BIOS o calor), el hilo principal de Roblox va mas lento. Hay que averiguar la causa antes de tocar nada.'))
    }

    # ---------------- RAM ----------------
    $ramScore = 0; $ramEv = @()
    if ($m.RamUsedPct) {
        $ramEv += "RAM usada: media $(Format-N $m.RamUsedPct.Avg)%, max $(Format-N $m.RamUsedPct.Max)%"
        if ($m.RamUsedPct.Max -ge 95) { $ramScore = 80 } elseif ($m.RamUsedPct.P95 -ge $T.RamUsedHigh) { $ramScore = 45 }
    }
    if ($m.RamAvailMB -and $m.RamAvailMB.Min -lt $T.RamAvailLowMB) {
        $ramEv += "RAM disponible minima: $(Format-N $m.RamAvailMB.Min) MB"
        $ramScore = [math]::Max($ramScore, 65)
    }
    if ($m.CommitPct -and $m.CommitPct.Max -ge $T.CommitHigh) {
        $ramEv += "Memoria comprometida: max $(Format-N $m.CommitPct.Max)% del limite"
        $ramScore = [math]::Max($ramScore, 60)
    }
    if ($m.PageReads -and $m.PageReads.Avg -ge $T.PageReadsHigh) {
        $ramEv += "Lecturas de paginacion: media $(Format-N $m.PageReads.Avg)/s (se esta leyendo memoria desde disco)"
        $ramScore = [math]::Max($ramScore, 75)
    }
    if ($ramScore -gt 0) {
        [void]$findings.Add((New-Finding 'RAM' $ramScore 'Presion de memoria RAM' $ramEv `
            'Si falta RAM, Windows mueve memoria al disco (paginacion) y aparecen tirones. La solucion real es cerrar aplicaciones que consumen mucha memoria, no "limpiadores de RAM".'))
    }

    # ---------------- LIMITE DE FPS ----------------
    if ($cap) {
        [void]$findings.Add((New-Finding 'OTRO' 90 "FPS limitados a $cap (limite del juego o VSync)" @(
            "FPS mediana $(Format-N $Frames.FpsMedian 1), maximo $(Format-N $Frames.FpsMax 1)") `
            "Mientras el juego este limitado a $cap FPS, ninguna optimizacion puede subir la media por encima. Roblox tiene la opcion oficial 'Frecuencia de fotogramas maxima' en su menu de configuracion."))
    }

    # ---------------- Veredicto ----------------
    $ordered = @($findings | Sort-Object -Property Score -Descending)
    $verdict = if (-not $useGame) {
        'SIN DATOS DE JUEGO'
    } elseif ($ordered.Count -eq 0) {
        'SIN CUELLO DE BOTELLA CLARO'
    } else {
        # Termico y energia se priorizan si son fuertes: son la causa de lo demas.
        $root = @($ordered | Where-Object { $_.Type -in @('THERMAL', 'POWER') -and $_.Score -ge 70 }) | Select-Object -First 1
        $top = if ($root) { $root } else { $ordered[0] }
        switch ($top.Type) {
            'GPU'     { 'GPU BOTTLENECK' }
            'CPU'     { 'CPU BOTTLENECK' }
            'RAM'     { 'RAM BOTTLENECK' }
            'THERMAL' { 'THERMAL BOTTLENECK' }
            'POWER'   { 'POWER BOTTLENECK' }
            default   { "OTRO: $($top.Title)" }
        }
    }

    return [pscustomobject]@{
        Verdict      = $verdict
        UsedGameData = $useGame
        Findings     = $ordered
        Metrics      = [pscustomobject]$m
        Frames       = $Frames
        FpsCap       = $cap
    }
}

# Decide que grafica usa Roblox combinando varias pruebas independientes:
# uso de motores 3D por adaptador y memoria de GPU de Roblox en cada adaptador.
function Get-RobloxGpuVerdict {
    param($Metrics, [bool]$UsedGameData)
    $m = $Metrics
    if (-not $UsedGameData) { return [pscustomobject]@{ Code = 'SIN_DATOS'; Evidence = @('Roblox no estaba abierto') } }
    $nvUtil = if ($m.RobloxGpuNv) { $m.RobloxGpuNv.Avg } else { $null }
    $otUtil = if ($m.RobloxGpuOther) { $m.RobloxGpuOther.Avg } else { $null }
    $nvDed  = if ($m.RobloxNvDedMB) { $m.RobloxNvDedMB.P50 } else { $null }
    $ev = @("Uso 3D de Roblox: NVIDIA $(Format-N $nvUtil)% / integrada $(Format-N $otUtil)%")
    if ($null -ne $nvDed) { $ev += "Memoria de video de Roblox en la NVIDIA: $(Format-N $nvDed) MB" }
    $memOnNv  = ($null -ne $nvDed -and $nvDed -ge 150)
    $utilOnNv = ($null -ne $nvUtil -and $nvUtil -ge 1)
    $utilOnIg = ($null -ne $otUtil -and $otUtil -gt 5)
    if ($utilOnNv) { return [pscustomobject]@{ Code = 'NVIDIA'; Evidence = $ev } }
    if ($utilOnIg -and $memOnNv) { return [pscustomobject]@{ Code = 'DUDA'; Evidence = $ev } }
    if ($utilOnIg) { return [pscustomobject]@{ Code = 'IGPU'; Evidence = $ev } }
    if ($memOnNv) { return [pscustomobject]@{ Code = 'NVIDIA'; Evidence = $ev } }
    return [pscustomobject]@{ Code = 'DESCONOCIDO'; Evidence = $ev }
}
