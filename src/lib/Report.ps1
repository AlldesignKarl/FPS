# =============================================================================
#  GPU BOOSTER 920MX - Informe de diagnostico en texto
# =============================================================================

function Get-GpuMemoryTypeGuess {
    param($MaxMemClock)
    if (-not $MaxMemClock) { return 'no determinado' }
    # nvidia-smi informa el reloj "real": DDR3 ~ 900-1100 MHz; GDDR5 ~ 2500 MHz (5 Gbps efectivos).
    if ($MaxMemClock -le 1300) { return "DDR3 (reloj de memoria maximo $MaxMemClock MHz; es la variante mas lenta de la 920MX)" }
    if ($MaxMemClock -ge 2000) { return "GDDR5 (reloj de memoria maximo $MaxMemClock MHz)" }
    return "no determinado ($MaxMemClock MHz)"
}

function Get-YesNoFromFinding {
    param($Analysis, [string]$Type, [string]$Yes, [string]$Maybe, [string]$No)
    if (-not $Analysis.UsedGameData) { return 'SIN DATOS DE JUEGO: repite el diagnostico con Roblox (ERLC) abierto.' }
    $f = $Analysis.Findings | Where-Object { $_.Type -eq $Type } | Sort-Object Score -Descending | Select-Object -First 1
    if (-not $f -or $f.Score -lt 40) { return $No }
    if ($f.Score -ge 70) { return "$Yes (evidencia $($f.Level))" }
    return "$Maybe (evidencia $($f.Level))"
}

function Build-TextReport {
    param($Static, $Analysis, $Plan, $ProcUsage, $Meta)
    $lines = New-Object System.Collections.Generic.List[string]
    function Add([string]$text = '') { $lines.Add($text) }
    function Sec([string]$t) { Add ''; Add ('=' * 78); Add "  $t"; Add ('=' * 78) }
    $m = $Analysis.Metrics
    $nv = $Static.GPUs | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    $ig = @($Static.GPUs | Where-Object { $_.Name -notmatch 'NVIDIA' })
    $ns = $Static.NvStatic

    Add 'GPU BOOSTER 920MX - DIAGNOSTICO (FASE 1, SOLO LECTURA)'
    Add "Fecha: $($Meta.Date)   Version herramienta: $($Meta.ToolVersion)"
    Add "Administrador: $(if ($Meta.IsAdmin) { 'si' } else { 'no (algunos datos pueden faltar)' })   Captura: $($Meta.CaptureSeconds) s   Muestras: $($m.SampleCount) (con Roblox: $($m.GameSamples))"
    Add "Medicion de FPS: $($Meta.FpsSource)"
    Add 'Este diagnostico NO ha modificado nada en tu ordenador.'

    Sec 'RESPUESTAS A TUS 10 PREGUNTAS'
    $cpu = $Static.CPU
    Add "1. CPU: $($cpu.Name) - $($cpu.Cores) nucleos / $($cpu.Threads) hilos, frecuencia base $($cpu.BaseMHz) MHz."
    if ($m.CpuMHz) { Add "   En la captura: $(Format-N $m.CpuMHz.Avg) MHz de media (min $(Format-N $m.CpuMHz.Min), max $(Format-N $m.CpuMHz.Max))." }
    if ($Static.Turbo) { Add "   Prueba de turbo (1 hilo al 100%, juego cerrado): maximo $($Static.Turbo.MaxMHz) MHz ($($Static.Turbo.MaxPerfPct)% de la base de Windows, $($Static.Turbo.WindowsBaseMHz) MHz); flags de limite max: $($Static.Turbo.LimitFlagsMax)." }
    if ($nv) {
        Add "2. GPU: $($nv.Name)$(if ($ns -and $ns.'pci.device_id') { "  [PCI $($ns.'pci.device_id') / subsistema $($ns.'pci.sub_device_id')]" })"
        Add "   VRAM: $(if ($ns -and $ns.'memory.total') { "$($ns.'memory.total') MB" } else { "$($nv.VramMB) MB" }), tipo: $(Get-GpuMemoryTypeGuess $(if ($ns) { $ns.'clocks.max.memory' }))"
        if ($ns -and $ns.vbios_version) { Add "   VBIOS: $($ns.vbios_version)" }
    } else { Add '2. GPU: NO SE HA DETECTADO NINGUNA GPU NVIDIA (revisa el driver en el Administrador de dispositivos).' }
    foreach ($g in $ig) { Add "   GPU integrada: $($g.Name) (driver $($g.DriverVersion))" }
    if ($nv) {
        Add "3. Driver NVIDIA: $(if ($ns -and $ns.driver_version) { $ns.driver_version } else { $nv.NvidiaDriver }) (version Windows $($nv.DriverVersion), fecha $(if ($nv.DriverDate) { ([datetime]$nv.DriverDate).ToString('yyyy-MM-dd') } else { 'n/d' }))"
    } else { Add '3. Driver NVIDIA: no detectado.' }
    Add "4. Temperaturas: GPU $(if ($m.GpuTemp) { "media $(Format-N $m.GpuTemp.Avg) C, max $(Format-N $m.GpuTemp.Max) C" } else { 'NO DISPONIBLE (el driver no da lectura de temperatura en este portatil)' }); CPU (zona termica ACPI, aproximada) $(if ($m.CpuZoneTemp) { "media $(Format-N $m.CpuZoneTemp.Avg) C, max $(Format-N $m.CpuZoneTemp.Max) C" } else { 'no expuesta por el portatil' })."
    Add "   Nota: Windows no da la temperatura real de los nucleos de la CPU sin un driver de sensores; la zona ACPI es una aproximacion."
    Add "5. Frecuencias 920MX: maximo nucleo $(if ($ns) { Format-N $ns.'clocks.max.graphics' } else { 'n/d' }) MHz, maximo memoria $(if ($ns) { Format-N $ns.'clocks.max.memory' } else { 'n/d' }) MHz."
    if ($m.GpuClock) { Add "   Medido: nucleo $(Format-N $m.GpuClock.P50) MHz (mediana; min $(Format-N $m.GpuClock.Min), max $(Format-N $m.GpuClock.Max)), memoria $(Format-N $(if ($m.GpuMemClock) { $m.GpuMemClock.P50 })) MHz." }
    $gsel = Get-RobloxGpuVerdict -Metrics $m -UsedGameData $Analysis.UsedGameData
    $rbGpu = switch ($gsel.Code) {
        'SIN_DATOS' { 'SIN DATOS: Roblox no estaba abierto durante la captura.' }
        'IGPU'      { "LA GPU INTEGRADA (problema grave). $($gsel.Evidence -join '; ')" }
        'NVIDIA'    { "la NVIDIA $(if ($nv) { $nv.Name }). $($gsel.Evidence -join '; ')" }
        'DUDA'      { "NO CONCLUYENTE, los datos se contradicen. $($gsel.Evidence -join '; ')" }
        default     { "no determinado. $($gsel.Evidence -join '; ')" }
    }
    Add "6. GPU que usa Roblox: $rbGpu"
    foreach ($nvLine in @($Meta.NvSmiRobloxLines)) { Add "   nvidia-smi: $("$nvLine".Trim())" }
    Add "7. Thermal throttling: $(Get-YesNoFromFinding $Analysis 'THERMAL' 'SI, hay limitacion termica' 'POSIBLE, temperaturas altas' 'NO detectado en esta captura')"
    Add "8. La CPU como cuello de botella: $(Get-YesNoFromFinding $Analysis 'CPU' 'SI, la CPU limita los FPS' 'POSIBLE, la CPU esta muy cargada' 'NO parece ser el limite')"
    Add "9. La GPU como cuello de botella: $(Get-YesNoFromFinding $Analysis 'GPU' 'SI, la GPU limita los FPS' 'POSIBLE, la GPU esta muy cargada' 'NO parece ser el limite')"
    Add '10. Optimizaciones realmente posibles en TU portatil: ver seccion "OPTIMIZACIONES PROPUESTAS".'
    $rec = @($Plan | Where-Object { $_.State -eq 'RECOMENDADA' })
    Add "    Recomendadas segun lo medido: $(if ($rec.Count) { ($rec | ForEach-Object { $_.Name }) -join ' | ' } else { 'ninguna' })"

    Sec "CUELLO DE BOTELLA (preliminar): $($Analysis.Verdict)"
    if ($Analysis.Frames) {
        $f = $Analysis.Frames
        Add "FPS medidos (PresentMon, $($f.Frames) fotogramas): media $(Format-N $f.FpsAvg 1) | 1% low $(Format-N $f.Fps1Low 1) | min $(Format-N $f.FpsMin 1) | max $(Format-N $f.FpsMax 1)"
        Add "Frame time: media $(Format-N $f.FrameTimeAvgMs 2) ms | p99 $(Format-N $f.FrameTimeP99Ms 2) ms | desviacion $(Format-N $f.FrameTimeStdMs 2) ms"
        if ($null -ne $f.GpuBusyRatioP50) { Add "GPU ocupada en cada fotograma (mediana): $(Format-N ($f.GpuBusyRatioP50*100))%" }
    } else { Add 'Sin datos de FPS (PresentMon no disponible): el analisis usa solo contadores de uso, frecuencia y temperatura.' }
    if ($Analysis.Findings.Count -eq 0) { Add 'No se han encontrado indicios claros de limitacion.' }
    foreach ($fd in $Analysis.Findings) {
        Add ''
        Add "[$($fd.Type)] $($fd.Title)  - evidencia $($fd.Level) ($($fd.Score)/100)"
        foreach ($e in $fd.Evidence) { Add "   * $e" }
        Add "   > $($fd.Explanation)"
    }

    Sec 'OPTIMIZACIONES PROPUESTAS (NO SE HA APLICADO NINGUNA)'
    $i = 0
    foreach ($o in $Plan) {
        $i++
        Add ''
        Add ("{0,2}. [{1}] {2}" -f $i, $o.State, $o.Name)
        Add "    Por que:    $($o.Why)"
        Add "    Como:       $($o.How)"
        Add "    Impacto:    $($o.Impact)"
        Add "    Fase:       $($o.Phase)"
        Add "    Reversion:  $($o.Undo)"
    }
    Add ''
    Add 'DESCARTADAS A PROPOSITO (placebo o peligrosas):'
    foreach ($r in $script:Rejected) { Add "  - $r" }

    Sec 'IDENTIFICACION DE GPU (que grafica usa Roblox)'
    if (@($Static.Dxgi).Count) {
        Add 'Adaptadores segun DirectX:'
        foreach ($a in $Static.Dxgi) { Add "   $($a.Luid)  $($a.Name)  [fabricante $($a.VendorId)$(if ($a.IsNvidia) { ' = NVIDIA' })]  dedicada $($a.DedicatedMB) MB, compartida $($a.SharedMB) MB$(if ($a.Software) { ' (software)' })" }
    } else { Add 'DirectX no devolvio la lista de adaptadores (se usa la deteccion alternativa por tipo de motor).' }
    $gi = $Meta.GpuIdent
    if ($gi -and $gi.Count) {
        Add 'Uso de GPU de Roblox por adaptador y motor (media durante la captura):'
        foreach ($k in ($gi.Keys | Sort-Object)) {
            $parts = $k -split '\|'
            $st = Get-Stats @($gi[$k])
            $unit = if ($parts[1] -eq 'MemoriaDedicadaMB') { ' MB' } else { ' %' }
            $name = ($Static.Dxgi | Where-Object { $_.Luid -eq $parts[0] } | Select-Object -First 1).Name
            Add ("   {0} {1,-22} {2,-18} media {3,7}{4}  max {5,7}{4}" -f $parts[0], $(if ($name) { $name.Substring(0, [math]::Min(22, $name.Length)) } else { '' }), $parts[1], (Format-N $st.Avg 1), $unit, (Format-N $st.Max 1))
        }
    }
    foreach ($nvLine in @($Meta.NvSmiRobloxLines)) { Add "nvidia-smi ve a Roblox: $("$nvLine".Trim())" }

    Sec 'MEDIDAS DURANTE LA CAPTURA'
    $rows = @(
        @('Uso GPU %', $m.GpuUtil), @('Reloj GPU MHz', $m.GpuClock), @('Reloj memoria GPU MHz', $m.GpuMemClock),
        @('Temperatura GPU C', $m.GpuTemp), @('Consumo GPU W', $m.GpuPower), @('VRAM usada MB', $m.VramUsed),
        @('CPU total %', $m.CpuTotal), @('Hilo logico mas cargado %', $m.CpuCoreMax), @('Rendimiento CPU % (100=base)', $m.CpuPerfPct),
        @('Frecuencia CPU MHz', $m.CpuMHz), @('Flags de limite CPU', $m.CpuLimitFlags), @('Zona termica ACPI C', $m.CpuZoneTemp),
        @('VRAM de Roblox en NVIDIA MB', $m.RobloxNvDedMB), @('VRAM de Roblox en otra GPU MB', $m.RobloxOtherDedMB),
        @('Roblox CPU % (del total)', $m.RobloxCpu), @('Hilo principal Roblox % de 1 nucleo', $m.RobloxMainThread), @('Otros procesos CPU %', $m.BackgroundCpu),
        @('RAM usada %', $m.RamUsedPct), @('RAM disponible MB', $m.RamAvailMB), @('Memoria comprometida %', $m.CommitPct), @('Lecturas paginacion /s', $m.PageReads)
    )
    Add ('{0,-38} {1,8} {2,8} {3,8} {4,8}' -f 'Metrica', 'Min', 'Media', 'Mediana', 'Max')
    foreach ($r in $rows) {
        $s = $r[1]
        if ($s) { Add ('{0,-38} {1,8} {2,8} {3,8} {4,8}' -f $r[0], (Format-N $s.Min 1), (Format-N $s.Avg 1), (Format-N $s.P50 1), (Format-N $s.Max 1)) }
        else { Add ('{0,-38} {1,8}' -f $r[0], 'n/d') }
    }

    Sec 'SISTEMA'
    Add "Equipo: $($Static.Machine.Manufacturer) $($Static.Machine.Model)  (BIOS $($Static.Machine.Bios))"
    Add "Windows: $($Static.OS.Caption) $($Static.OS.DisplayVersion) - build $($Static.OS.Build).$($Static.OS.UBR) ($($Static.OS.Arch))"
    Add "RAM: $($Static.RAM.TotalGB) GB visibles"
    foreach ($mo in $Static.RAM.Modules) { Add "   - $($mo.Slot): $($mo.SizeGB) GB $($mo.Type) $($mo.ConfiguredMHz)/$($mo.SpeedMHz) MHz $($mo.Manufacturer) $($mo.Part)" }
    if (@($Static.RAM.Modules).Count -eq 1) { Add '   ! Un solo modulo: la RAM funciona en canal simple.' }
    if (@($Static.RAM.Modules).Count -eq 2 -and (@($Static.RAM.Modules)[0].SizeGB -ne @($Static.RAM.Modules)[1].SizeGB)) { Add '   i Dos modulos de distinto tamano: doble canal parcial (modo flex).' }
    foreach ($p in $Static.PageFile) { Add "Archivo de paginacion: $($p.Path) asignado $($p.AllocatedMB) MB, uso $($p.CurrentMB) MB, pico $($p.PeakMB) MB" }
    foreach ($d in $Static.Disks) { Add "Disco: $($d.Name) - $($d.Media) $($d.Bus) $($d.SizeGB) GB" }
    Add "Espacio libre en $($env:SystemDrive): $($Static.SystemDriveFreeGB) GB"
    foreach ($g in $Static.GPUs) { Add "Adaptador: $($g.Name) | driver $($g.DriverVersion) | $($g.Resolution) @ $($g.RefreshHz) Hz | estado $($g.Status)" }

    $pw = $Static.Power
    Add ''
    Add "Energia: plan '$($pw.SchemeName)' ($($pw.SchemeGuid)) | modo con cargador: $($pw.OverlayAC) | con bateria: $($pw.OverlayDC)"
    Add "   Estado minimo CPU AC/DC: $(if ($pw.ProcThrottleMin) { "$($pw.ProcThrottleMin.AC)% / $($pw.ProcThrottleMin.DC)%" } else { 'n/d' }) | maximo AC/DC: $(if ($pw.ProcThrottleMax) { "$($pw.ProcThrottleMax.AC)% / $($pw.ProcThrottleMax.DC)%" } else { 'n/d' })"
    Add "   Turbo (boost) AC/DC: $(if ($pw.PerfBoostMode) { "$($script:PerfBoostNames[$pw.PerfBoostMode.AC]) / $($script:PerfBoostNames[$pw.PerfBoostMode.DC])" } else { 'n/d' }) | Refrigeracion AC: $(if ($pw.CoolingPolicy) { if ($pw.CoolingPolicy.AC -eq 1) { 'activa' } else { 'pasiva' } } else { 'n/d' }) | ASPM PCIe AC: $(if ($pw.PcieAspm) { $pw.PcieAspm.AC } else { 'n/d' })"
    Add "   Bateria: $(if ($pw.HasBattery) { "$($pw.BatteryPct)% - $(if ($pw.OnBattery) { 'DESCARGANDO (sin cargador)' } else { 'con cargador' })" } else { 'no detectada' })"
    $gr = $Static.Graphics
    Add "Graficos Windows: HAGS=$($gr.HagsHwSchMode) | Modo Juego=$(if ($null -eq $gr.GameModeAuto) { 'por defecto' } else { $gr.GameModeAuto }) | GameDVR=$($gr.GameDvrEnabled) | Captura=$($gr.AppCapture) | Grabacion 2o plano=$($gr.HistoricalCapture) | Transparencia=$($gr.Transparency)"
    Add "   DirectX global: $($gr.DxGlobal)"

    Add ''
    Add 'Roblox:'
    foreach ($ins in ($Static.Roblox.Installs | Select-Object -First 3)) { Add "   Instalado: $($ins.Path) (v$($ins.Version), $($ins.Modified))" }
    if ($Static.Roblox.StoreApp) { Add "   Microsoft Store: $($Static.Roblox.StoreApp)" }
    foreach ($r in $Static.Roblox.Running) { Add "   En ejecucion: PID $($r.Id) $($r.Path) prioridad $($r.PriorityClass) RAM $($r.WorkingSetMB) MB" }
    if (-not @($Static.Roblox.GpuPreferences).Count) { Add '   Preferencia de GPU de Windows para Roblox: ninguna' }
    foreach ($gp in $Static.Roblox.GpuPreferences) { Add "   Preferencia GPU: $($gp.Path) = $($gp.Value)" }
    if ($Static.Roblox.SettingsFile) {
        Add "   Ajustes guardados ($(Split-Path $Static.Roblox.SettingsFile -Leaf)):"
        foreach ($k in $Static.Roblox.Settings.Keys) { Add "      $k = $($Static.Roblox.Settings[$k])" }
    }

    if ($ns) {
        Add ''
        Add 'nvidia-smi (estatico):'
        foreach ($p in $ns.PSObject.Properties) { Add ("   {0,-38} {1}" -f $p.Name, $(if ($null -eq $p.Value) { 'no soportado' } else { $p.Value })) }
    }

    Sec 'PROCESOS CON MAS CONSUMO DURANTE LA CAPTURA'
    Add ('{0,-32} {1,6} {2,8} {3,10}  {4}' -f 'Proceso', 'N', 'CPU %', 'RAM priv MB', 'Tipo')
    foreach ($p in ($ProcUsage | Sort-Object CpuPct -Descending | Select-Object -First 15)) {
        Add ('{0,-32} {1,6} {2,8} {3,10}  {4}' -f $p.Name, $p.Count, (Format-N $p.CpuPct 1), $p.PrivateMB, $(if ($p.Name -match 'Roblox') { 'el juego' } elseif ($p.Critical) { 'sistema/critico (no se toca)' } elseif ($p.KnownBackground) { 'app de segundo plano' } else { '' }))
    }
    Add ''
    Add 'Mas memoria:'
    foreach ($p in ($ProcUsage | Sort-Object PrivateMB -Descending | Select-Object -First 10)) {
        Add ('{0,-32} {1,6} {2,8} {3,10}  {4}' -f $p.Name, $p.Count, (Format-N $p.CpuPct 1), $p.PrivateMB, $(if ($p.Name -match 'Roblox') { 'el juego' } elseif ($p.Critical) { 'sistema/critico (no se toca)' } elseif ($p.KnownBackground) { 'app de segundo plano' } else { '' }))
    }
    Add ''
    if (@($Static.OtherTools).Count) { Add "Otros optimizadores abiertos: $(@($Static.OtherTools) -join ', ')" }
    Add "Programas de inicio: $(@($Static.StartupItems).Count)"
    foreach ($s in ($Static.StartupItems | Select-Object -First 20)) { Add "   - $($s.Name)" }

    if (@($Meta.NvLive).Count) {
        Sec 'DRIVER NVIDIA CON EL JUEGO ABIERTO (nvidia-smi -q)'
        foreach ($ln in ($Meta.NvLive | Where-Object { "$_".Trim() -ne '' -and $_ -notmatch '^=+|Timestamp|Attached GPUs' })) { Add "$ln" }
    }

    Sec 'LIMITACIONES DE ESTA MEDICION'
    Add '- La temperatura de CPU es la zona termica ACPI del portatil, no el sensor de cada nucleo.'
    Add '- El diagnostico consume un poco de CPU mientras mide (una consulta cada pocos segundos).'
    if (-not $Analysis.Frames) { Add '- Sin PresentMon no hay FPS ni frame time reales; el cuello de botella se deduce de uso/frecuencias.' }
    if (-not $Meta.IsAdmin) { Add '- Sin permisos de administrador PresentMon no puede medir FPS.' }
    return ($lines -join "`r`n")
}
