<#
.SYNOPSIS
  GPU BOOSTER 920MX - AUTO BOOST para Roblox.

.DESCRIPTION
  1. Comprueba el turbo de la CPU y corrige los ajustes de energia de Windows
     que lo limiten (solo si la prueba demuestra que mejora; si no, se deshace).
  2. Espera a que abras Roblox y entonces, mientras juegas:
     - cierra instancias duplicadas de Roblox que ocupan RAM y VRAM,
     - cierra (con tu permiso) apps de segundo plano pesadas,
     - pausa Process Lasso para que no baje la prioridad del juego,
     - pone Roblox en prioridad "Por encima de lo normal",
     - mide FPS reales (benchmark) y los compara con el diagnostico anterior.
  3. Al cerrar Roblox lo deshace todo y vuelve a abrir tus apps.
  No toca Roblox, BIOS, drivers, Defender ni ninguna proteccion.

.PARAMETER Restaurar
  Deshace todo lo que haya hecho el Booster (RESTAURAR TODO) y sale.
#>
[CmdletBinding()]
param([switch]$Restaurar)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/Analysis.ps1')
. (Join-Path $PSScriptRoot 'lib/Collectors.ps1')
. (Join-Path $PSScriptRoot 'lib/Actions.ps1')

function Write-Step([string]$t) { Write-Host "  > $t" -ForegroundColor Cyan }
function Write-Ok([string]$t)   { Write-Host "    $t" -ForegroundColor Gray }
function Write-Good([string]$t) { Write-Host "    $t" -ForegroundColor Green }
function Write-Warn2([string]$t){ Write-Host "    ! $t" -ForegroundColor Yellow }
function Ask([string]$q, [string]$default = 'S') {
    $a = Read-Host "  $q"
    if ([string]::IsNullOrWhiteSpace($a)) { $a = $default }
    return $a.Trim().ToUpper()
}

# Pedir administrador si hace falta (cambiar prioridades y energia lo necesita).
if ((Test-IsWindows) -and -not (Test-IsAdmin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Restaurar) { $argList += '-Restaurar' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

trap {
    Write-Host ''
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  En: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    if ($script:Session) {
        Write-Host '  Deshaciendo los cambios de esta sesion...' -ForegroundColor Yellow
        Restore-BoostSession -Session $script:Session | ForEach-Object { Write-Ok $_ }
    }
    Write-Host '  Copia este mensaje y pegalo en el chat.' -ForegroundColor Yellow
    [void](Read-Host '  Pulsa ENTER para cerrar')
    break
}

try { $Host.UI.RawUI.WindowTitle = 'GPU BOOSTER 920MX' } catch {}
Clear-Host
Write-Host ''
Write-Host '  ==============================================================' -ForegroundColor Green
Write-Host '                 GPU BOOSTER 920MX  -  AUTO BOOST' -ForegroundColor Green
Write-Host '  ==============================================================' -ForegroundColor Green
Initialize-BoosterState -Root $Root
$ToolsDir = Join-Path $Root 'tools'
$ReportsDir = Join-Path $Root 'reports'

# ------------------------------------------------ Recuperacion tras un cierre
$pending = Read-PendingSession
if ($pending) {
    Write-Step 'La ultima sesion no termino bien: restaurando lo que quedo cambiado...'
    Restore-BoostSession -Session $pending | ForEach-Object { Write-Ok $_ }
}

# ------------------------------------------------------------ RESTAURAR TODO
if ($Restaurar) {
    Write-Step 'RESTAURAR TODO: devolviendo Windows a como estaba antes del Booster...'
    Restore-Baseline | ForEach-Object { Write-Ok $_ }
    Write-Good 'Listo. Todo esta como antes del Booster.'
    [void](Read-Host '  Pulsa ENTER para cerrar')
    exit
}

Save-Baseline
Start-BoostSession

# --------------------------------------------------------- 1. Turbo de CPU
Write-Host ''
if (@(Get-RobloxProcesses).Count -eq 0) {
    Write-Step 'Paso 1: comprobando el turbo del procesador (8 s)...'
    $t1 = Test-CpuTurbo -Seconds 8
    Write-Ok "Maximo alcanzado: $($t1.MaxMHz) MHz ($($t1.MaxPerfPct)% de la base de Windows)"
    if ($t1.MaxPerfPct -ge 105) {
        Write-Good 'El turbo funciona. No hay nada que cambiar.'
    } else {
        $limits = @(Get-PowerLimits)
        if ($limits.Count -eq 0) {
            Write-Warn2 'El turbo no se activa y Windows NO lo esta limitando (sus ajustes ya permiten turbo).'
            Write-Warn2 'El bloqueo viene del portatil (BIOS, modo de Lenovo o driver termico): no lo toco.'
        } else {
            foreach ($l in $limits) {
                Write-Ok "Ajuste que limita: $($l.Name) = $($l.Current) -> $($l.Target)"
                Add-BoostChange @{ Kind = 'power'; Name = $l.Name; Setting = $l.Setting; Original = $l.Current }
                Set-PowerAC -Setting $l.Setting -Value $l.Target
            }
            Write-Step 'Repitiendo la prueba para ver si mejora...'
            $t2 = Test-CpuTurbo -Seconds 8
            Write-Ok "Ahora: $($t2.MaxMHz) MHz ($($t2.MaxPerfPct)%)"
            if ($t2.MaxPerfPct -ge $t1.MaxPerfPct + 5) {
                Write-Good "TURBO RECUPERADO: $($t1.MaxMHz) -> $($t2.MaxMHz) MHz. Se mantiene mientras juegas."
            } else {
                Write-Warn2 'No ha mejorado: deshago el cambio (solo aplico lo que funciona).'
                $undo = [pscustomobject]@{ Changes = @($script:Session.Changes | Where-Object { $_.Kind -eq 'power' }) }
                Restore-BoostSession -Session $undo | Out-Null
                Start-BoostSession
                Write-Warn2 'El bloqueo viene del portatil (BIOS, modo de Lenovo o driver termico): no lo toco.'
            }
        }
    }
} else {
    Write-Warn2 'Roblox ya esta abierto: salto la prueba del turbo. Para hacerla, abre el Booster ANTES que Roblox.'
}

# ------------------------------------------------- 2. Archivo de paginacion
$cs = Get-Cim Win32_ComputerSystem | Select-Object -First 1
if ($cs -and -not $cs.AutomaticManagedPagefile) {
    Write-Host ''
    Write-Step 'Paso 2: archivo de paginacion'
    Write-Ok 'Esta fijo en un tamano pequeno. Con la RAM llena, Roblox puede cerrarse de golpe.'
    Write-Ok 'Ponerlo en automatico deja que Windows lo agrande cuando haga falta (se aplica al reiniciar).'
    if ((Ask 'Ponerlo en automatico? (S/N) [S]') -eq 'S') {
        if (Set-AutomaticPagefile) { Write-Good 'Hecho. Se aplicara la proxima vez que reinicies.' }
    }
}

# ------------------------------------------------ 3. Esperar a Roblox
Write-Host ''
Write-Step 'Paso 3: abre Roblox y entra en tu juego. Te espero...'
while (-not (Get-RobloxGameProcess)) { Start-Sleep -Seconds 2 }
Start-Sleep -Seconds 5
$game = Get-RobloxGameProcess
Write-Good "Roblox detectado (PID $($game.Id))."

# Instancias duplicadas
$dups = @(Get-RobloxDuplicates -Game $game)
if ($dups.Count) {
    Write-Warn2 "Hay $($dups.Count) Roblox mas abierto(s) sin ventana, gastando memoria:"
    foreach ($d in $dups) { Write-Ok ("PID {0}  RAM {1} MB" -f $d.Id, [math]::Round($d.PrivateMemorySize64 / 1MB)) }
    if ((Ask 'Cerrarlos? (el tuyo sigue abierto) (S/N) [S]') -eq 'S') {
        foreach ($d in $dups) { try { Stop-Process -Id $d.Id -Force -ErrorAction Stop; Write-Good "Cerrado PID $($d.Id)" } catch { Write-Warn2 "No se pudo cerrar PID $($d.Id)" } }
    }
}

# Apps de segundo plano
$apps = @(Get-RunningBoostApps)
if ($apps.Count) {
    Write-Host ''
    Write-Ok ('Apps abiertas que gastan memoria: ' + (($apps | ForEach-Object { "$($_.Key) ($($_.MB) MB)" }) -join ', '))
    Write-Ok 'S = cerrarlas todas mientras juegas | N = no cerrar ninguna | D = todas menos Discord'
    $ans = Ask 'Que hago? (S/N/D) [S]'
    if ($ans -ne 'N') {
        foreach ($a in $apps) {
            if ($ans -eq 'D' -and $a.Key -eq 'Discord') { continue }
            Add-BoostChange @{ Kind = 'closedApp'; Key = $a.Key; Path = $a.Path; Reopen = $a.Reopen }
            Stop-BoostApp $a
            Write-Good "$($a.Key) cerrado ($($a.MB) MB liberados)"
        }
    }
}

# Process Lasso
if (@(Get-Process -Name 'ProcessLasso', 'ProcessGovernor' -ErrorAction SilentlyContinue).Count -or @(Get-Service -Name 'ProcessGovernor' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }).Count) {
    $done = Suspend-ProcessLasso
    Write-Good "Process Lasso pausado mientras juegas ($($done -join ', ')). Se vuelve a abrir al terminar."
}

# Prioridad
$game = Get-RobloxGameProcess
$orig = "$($game.PriorityClass)"
Add-BoostChange @{ Kind = 'priority'; Pid = $game.Id; Original = $(if ($orig) { $orig } else { 'Normal' }) }
try { $game.PriorityClass = 'AboveNormal'; Write-Good "Prioridad de Roblox: $orig -> Por encima de lo normal" } catch { Write-Warn2 'No se pudo cambiar la prioridad de Roblox.' }

# ------------------------------------------------ 4. Monitor + benchmark
$nvSmi = Find-NvidiaSmi
$nvFields = @(); if ($nvSmi) { $nvFields = (Get-NvFields -Exe $nvSmi -Fields $script:NvSampleFields).Supported }
$script:SampleState.DxgiNvLuids = @(Get-DxgiAdapters | Where-Object { $_.IsNvidia } | ForEach-Object { $_.Luid })
$cpuInfo = Get-Cim Win32_Processor | Select-Object -First 1
$logical = [int]$cpuInfo.NumberOfLogicalProcessors; if ($logical -lt 1) { $logical = [Environment]::ProcessorCount }
$ramMB = [double](Get-Cim Win32_ComputerSystem | Select-Object -First 1).TotalPhysicalMemory / 1MB

$pmExe = Find-PresentMon -ToolsDir $ToolsDir
if (-not $pmExe) { try { $pmExe = Install-PresentMon -ToolsDir $ToolsDir } catch { Write-Warn2 'Sin PresentMon: no se podran medir FPS.' } }
$benchDir = Join-Path $ReportsDir ("boost_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $benchDir -Force | Out-Null
$pmCsv = Join-Path $benchDir 'presentmon.csv'
$benchStart = (Get-Date).AddSeconds(45)
$pmProc = $null; $benchDone = $false; $benchText = $null

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor Green
Write-Host '   BOOST ACTIVO. Juega normal. En 45 s empieza un benchmark de 90 s.' -ForegroundColor Green
Write-Host '   Cuando cierres Roblox, todo vuelve a como estaba.' -ForegroundColor Green
Write-Host '  ------------------------------------------------------------' -ForegroundColor Green

[void](Get-LiveSample -NvSmi $nvSmi -NvFields $nvFields -LogicalCpus $logical -TotalRamMB $ramMB)
try {
    while ($true) {
        $game = Get-RobloxGameProcess
        if (-not $game) { break }
        # Si otro programa baja la prioridad, se vuelve a subir.
        try { if ("$($game.PriorityClass)" -notin @('AboveNormal', 'High')) { $game.PriorityClass = 'AboveNormal' } } catch {}

        if (-not $pmProc -and -not $benchDone -and $pmExe -and (Get-Date) -ge $benchStart) {
            try { $pmProc = Start-PresentMonCapture -Exe $pmExe -CsvPath $pmCsv -Seconds 90 } catch { $benchDone = $true }
            try { [Console]::Beep(660, 150) } catch {}
        }
        if ($pmProc -and $pmProc.HasExited -and -not $benchDone) {
            $benchDone = $true
            $pm = Read-PresentMonCsv -CsvPath $pmCsv
            $after = if ($pm) { Get-FrameStats -FrameTimesMs $pm.FrameTimes -GpuBusyMs $pm.GpuBusy } else { $null }
            $before = Get-LastDiagnosticFrames -ReportsDir $ReportsDir
            $cmp = Get-BenchmarkComparison -Before $before -After $after
            try { [Console]::Beep(880, 250); [Console]::Beep(1100, 250) } catch {}
            if ($cmp) {
                $lines = @('GPU BOOSTER 920MX - BENCHMARK', "Fecha: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))", '')
                if ($null -ne $cmp.BeforeAvg) {
                    $lines += ("ANTES   (diagnostico {0}): {1} FPS medios | 1% low {2}" -f $before.When, (Format-N $cmp.BeforeAvg 1), (Format-N $cmp.Before1Low 1))
                }
                $lines += ("DESPUES (con Boost):          {0} FPS medios | 1% low {1} | min {2} | max {3}" -f (Format-N $after.FpsAvg 1), (Format-N $after.Fps1Low 1), (Format-N $after.FpsMin 1), (Format-N $after.FpsMax 1))
                $lines += ("Frame time medio: {0} ms | p99 {1} ms" -f (Format-N $after.FrameTimeAvgMs 1), (Format-N $after.FrameTimeP99Ms 1))
                if ($null -ne $cmp.DeltaFps) {
                    $lines += ("MEJORA: {0}{1} FPS ({0}{2} %) | 1% low {3}{4}" -f $(if ($cmp.DeltaFps -ge 0) { '+' } else { '' }), (Format-N $cmp.DeltaFps 1), (Format-N $cmp.DeltaPct 0), $(if ($cmp.Delta1Low -ge 0) { '+' } else { '' }), (Format-N $cmp.Delta1Low 1))
                }
                $lines += '' ; $lines += 'Cambios activos en esta sesion:'
                foreach ($c in $script:Session.Changes) { $lines += "  - $($c.Kind) $($c.Name)$($c.Key)" }
                $benchText = $lines -join "`r`n"
                $benchText | Out-File (Join-Path $benchDir 'benchmark.txt') -Encoding UTF8
                try { Set-Clipboard -Value $benchText } catch {}
                Write-Host ''
                foreach ($l in $lines) { Write-Host "  $l" -ForegroundColor Green }
                Write-Host '  (Resultado copiado: pegalo en el chat con Ctrl+V)' -ForegroundColor Green
            } else { Write-Warn2 'El benchmark no obtuvo fotogramas.' }
        }

        $smp = Get-LiveSample -NvSmi $nvSmi -NvFields $nvFields -LogicalCpus $logical -TotalRamMB $ramMB
        $st = if ($pmProc -and -not $benchDone) { 'midiendo FPS...' } elseif ($benchDone) { 'benchmark hecho' } else { 'boost activo' }
        Write-Host ("`r  [BOOST] GPU {0,3}% {1,4}MHz VRAM {2,4}MB | CPU {3,3}% {4,4}MHz | RAM {5,3}% | Roblox {6} | {7}      " -f `
            (Format-N $smp.GpuUtil), (Format-N $smp.GpuClockMHz), (Format-N $smp.VramUsedMB), (Format-N $smp.CpuTotal), (Format-N $smp.CpuMHz), (Format-N $smp.RamUsedPct), $smp.RobloxPriority, $st) -NoNewline
        Start-Sleep -Seconds 3
    }
} finally {
    if ($pmProc -and -not $pmProc.HasExited) { try { Stop-Process -Id $pmProc.Id -Force } catch {} }
    Write-Host ''
    Write-Host ''
    Write-Step 'Roblox cerrado: deshaciendo los cambios temporales...'
    Restore-BoostSession -Session $script:Session | ForEach-Object { Write-Ok $_ }
    Write-Good 'Todo esta como antes. Gracias por usar GPU BOOSTER 920MX.'
}
[void](Read-Host '  Pulsa ENTER para cerrar')
