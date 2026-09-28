<#
.SYNOPSIS
  GPU BOOSTER 920MX - Fase 1: diagnostico completo de SOLO LECTURA.

.DESCRIPTION
  Detecta hardware, drivers, energia, ajustes graficos y Roblox; despues
  mide el sistema mientras juegas (CPU por nucleo, GPU, temperaturas,
  frecuencias, RAM, VRAM y, si PresentMon esta disponible, FPS y frame time
  reales). Con todo ello estima el cuello de botella y propone
  optimizaciones. NO MODIFICA NADA.

.PARAMETER SampleSeconds
  Duracion de la captura en segundos (por defecto 90).

.PARAMETER IntervalSeconds
  Intervalo entre muestras (por defecto 2).

.PARAMETER NoPrompt
  No hace preguntas: no descarga PresentMon y captura inmediatamente.
#>
[CmdletBinding()]
param(
    [int]$SampleSeconds = 90,
    [double]$IntervalSeconds = 2,
    [switch]$NoPrompt,
    [string]$OutDir
)

$ErrorActionPreference = 'Continue'
$ToolVersion = '0.1.0-fase1'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/Analysis.ps1')
. (Join-Path $PSScriptRoot 'lib/Collectors.ps1')
. (Join-Path $PSScriptRoot 'lib/Plan.ps1')
. (Join-Path $PSScriptRoot 'lib/Report.ps1')

function Write-Step([string]$t) { Write-Host "  > $t" -ForegroundColor Cyan }
function Write-Ok([string]$t)   { Write-Host "    $t" -ForegroundColor Gray }
function Write-Warn2([string]$t){ Write-Host "    ! $t" -ForegroundColor Yellow }

# Si algo falla, se muestra el error y la ventana NO se cierra sola.
trap {
    Write-Host ''
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  En: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    Write-Host '  Haz una foto o copia este mensaje y pegalo en el chat.' -ForegroundColor Yellow
    if (-not $NoPrompt) { [void](Read-Host '  Pulsa ENTER para cerrar') }
    break
}

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Clear-Host
Write-Host ''
Write-Host '  ==============================================================' -ForegroundColor Green
Write-Host '     GPU BOOSTER 920MX  -  FASE 1: DIAGNOSTICO (solo lectura)' -ForegroundColor Green
Write-Host '  ==============================================================' -ForegroundColor Green
Write-Host '   Este programa NO cambia nada en tu ordenador. Solo mide.' -ForegroundColor Gray
Write-Host ''

if (-not (Test-IsWindows)) { Write-Warn2 'No es Windows: se generara un informe vacio (modo de prueba).' }
$isAdmin = Test-IsAdmin
if (-not $isAdmin) { Write-Warn2 'Sin permisos de administrador: no se podran medir FPS con PresentMon.' }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
if (-not $OutDir) { $OutDir = Join-Path $Root "reports\diagnostico_$stamp" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$ToolsDir = Join-Path $Root 'tools'

# ------------------------------------------------------------------ 1. Estatico
Write-Step 'Detectando hardware, drivers y configuracion...'
$nvSmi = Find-NvidiaSmi
if ($nvSmi) { Write-Ok "nvidia-smi: $nvSmi" } else { Write-Warn2 'nvidia-smi no encontrado (sin datos directos del driver NVIDIA).' }
$static = Get-StaticInfo -NvSmi $nvSmi
Write-Ok "CPU: $($static.CPU.Name)"
foreach ($g in $static.GPUs) { Write-Ok "GPU: $($g.Name)  (driver $($g.DriverVersion))" }
Write-Ok "RAM: $($static.RAM.TotalGB) GB"
if ($nvSmi) {
    try { & $nvSmi -q 2>$null | Out-File (Join-Path $OutDir 'nvidia-smi-q.txt') -Encoding UTF8 } catch {}
    try { & $nvSmi -q -d SUPPORTED_CLOCKS 2>$null | Out-File (Join-Path $OutDir 'nvidia-smi-supported-clocks.txt') -Encoding UTF8 } catch {}
}
$nvFields = @()
if ($nvSmi) { $nvFields = (Get-NvFields -Exe $nvSmi -Fields $script:NvSampleFields).Supported }

# --------------------------------------------------------------- 2. PresentMon
$pmExe = Find-PresentMon -ToolsDir $ToolsDir
$fpsSource = 'no disponible'
if (-not $pmExe -and $isAdmin -and -not $NoPrompt -and (Test-IsWindows)) {
    # PresentMon: medidor de FPS oficial y de codigo abierto de Intel. Solo lee
    # los eventos de presentacion de fotogramas de Windows; no toca Roblox.
    Write-Step 'Descargando PresentMon (medidor de FPS oficial de Intel)...'
    try { $pmExe = Install-PresentMon -ToolsDir $ToolsDir; Write-Ok "Listo, firma digital verificada: $([IO.Path]::GetFileName($pmExe))" }
    catch { Write-Warn2 "No se pudo descargar ($($_.Exception.Message)). Se medira sin FPS." }
}
if ($pmExe -and -not $isAdmin) { Write-Warn2 'PresentMon encontrado pero necesita administrador; se omite.'; $pmExe = $null }

# ------------------------------------------------------------------ 3. Captura
$logical = [int]$static.CPU.Threads; if ($logical -lt 1) { $logical = [Environment]::ProcessorCount }
$ramMB = [double]$static.RAM.TotalMB

if (-not $NoPrompt) {
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor White
    Write-Host '   AHORA:' -ForegroundColor White
    Write-Host '    1) Conecta el cargador.' -ForegroundColor White
    Write-Host '    2) Abre Roblox y entra en Emergency Response: Liberty County' -ForegroundColor White
    Write-Host '       con tus graficos de siempre.' -ForegroundColor White
    Write-Host '    3) Juega normal (conduce por la ciudad).' -ForegroundColor White
    Write-Host "   La medicion empieza SOLA y dura $SampleSeconds s. Al acabar oiras dos pitidos." -ForegroundColor White
    Write-Host '  ------------------------------------------------------------' -ForegroundColor White
    $idle = $false
    if (@(Get-RobloxProcesses).Count -eq 0) {
        Write-Host '   Esperando a que abras Roblox... (o pulsa ENTER aqui para medir sin juego)' -ForegroundColor Yellow
        while (@(Get-RobloxProcesses).Count -eq 0) {
            $key = $false
            try { if ([Console]::KeyAvailable) { $key = ([Console]::ReadKey($true).Key -eq 'Enter') } } catch {}
            if ($key) { $idle = $true; break }
            Start-Sleep -Seconds 2
        }
        # Margen para que el juego cargue y entres en el servidor.
        if (-not $idle) { $wait = 60; Write-Ok 'Roblox detectado. Te doy 60 s para que cargue y entres en el servidor.' }
    } else {
        $wait = 10; Write-Ok 'Roblox ya esta abierto. Vuelve al juego.'
    }
    if (-not $idle) {
        for ($i = $wait; $i -ge 1; $i--) { Write-Host "`r    La medicion empieza en $i s...   " -NoNewline -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        Write-Host ''
        try { [Console]::Beep(660, 200) } catch {}
    }
}

$procBefore = Get-ProcSnapshot
$tStart = Get-Date
$pmProc = $null; $pmCsv = Join-Path $OutDir 'presentmon.csv'
if ($pmExe -and @(Get-RobloxProcesses).Count -gt 0) {
    try { $pmProc = Start-PresentMonCapture -Exe $pmExe -CsvPath $pmCsv -Seconds $SampleSeconds } catch { Write-Warn2 "PresentMon no arranco: $($_.Exception.Message)" }
}

[void](Get-LiveSample -NvSmi $nvSmi -NvFields $nvFields -LogicalCpus $logical -TotalRamMB $ramMB)  # cebado de contadores
$samples = New-Object System.Collections.ArrayList
$end = $tStart.AddSeconds($SampleSeconds)
while ((Get-Date) -lt $end) {
    $t0 = Get-Date
    Start-Sleep -Milliseconds 50
    $smp = Get-LiveSample -NvSmi $nvSmi -NvFields $nvFields -LogicalCpus $logical -TotalRamMB $ramMB
    [void]$samples.Add($smp)
    $left = [int]($end - (Get-Date)).TotalSeconds
    Write-Host ("`r    [{0,3}s] GPU {1,3}% {2,3}C {3,4}MHz | CPU {4,3}% (hilo max {5,3}%) {6,4}MHz | RAM {7,3}% | Roblox: {8}   " -f `
        $left, (Format-N $smp.GpuUtil), (Format-N $smp.GpuTempC), (Format-N $smp.GpuClockMHz), (Format-N $smp.CpuTotal), (Format-N $smp.CpuCoreMax), (Format-N $smp.CpuMHz), (Format-N $smp.RamUsedPct), $(if ($smp.RobloxRunning) { 'si' } else { 'no' })) -NoNewline
    $wait = $IntervalSeconds - ((Get-Date) - $t0).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
}
Write-Host ''
$elapsed = ((Get-Date) - $tStart).TotalSeconds
$procAfter = Get-ProcSnapshot
$nvRobloxLines = Get-NvidiaSmiProcessLines -Exe $nvSmi | Where-Object { $_ -match 'Roblox' }
$static.Roblox = Get-RobloxInfo   # refrescar (proceso en ejecucion)
try { [Console]::Beep(880, 300); [Console]::Beep(1100, 300) } catch {}

$frames = $null
if ($pmProc) {
    Write-Step 'Esperando a PresentMon...'
    try { $pmProc | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue } catch {}
    if (-not $pmProc.HasExited) { try { Stop-Process -Id $pmProc.Id -Force } catch {} }
    $pm = Read-PresentMonCsv -CsvPath $pmCsv
    if ($pm) {
        $frames = Get-FrameStats -FrameTimesMs $pm.FrameTimes -GpuBusyMs $pm.GpuBusy
        $fpsSource = "PresentMon ($([IO.Path]::GetFileName($pmExe))), columnas $($pm.Columns), API $($pm.Runtime), modo $($pm.PresentMode)"
    } else { $fpsSource = 'PresentMon no genero datos (Roblox cerrado o sin permisos)' }
} elseif ($pmExe) { $fpsSource = 'PresentMon disponible, pero Roblox no estaba abierto' }

# ----------------------------------------------------------------- 4. Analisis
Write-Step 'Analizando...'
$procUsage = @(Group-ProcessUsage (Get-ProcessUsage -Before $procBefore -After $procAfter -Seconds $elapsed -LogicalCpus $logical))
$ctx = [pscustomobject]@{
    GpuMaxClockMHz    = $(if ($static.NvStatic) { $static.NvStatic.'clocks.max.graphics' } else { $null })
    ProcThrottleMaxAC = $(if ($static.Power.ProcThrottleMax) { $static.Power.ProcThrottleMax.AC } else { $null })
    PowerOverlayName  = $static.Power.OverlayAC
    RefreshHz         = [int]$static.RefreshHz
}
$analysis = Invoke-BottleneckAnalysis -Samples $samples -Frames $frames -Context $ctx
$plan = Get-OptimizationPlan -Static $static -Analysis $analysis -ProcUsage $procUsage

$meta = [pscustomobject]@{
    Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); ToolVersion = $ToolVersion; IsAdmin = $isAdmin
    CaptureSeconds = [math]::Round($elapsed); FpsSource = $fpsSource; NvSmiRobloxLines = @($nvRobloxLines)
}
$report = Build-TextReport -Static $static -Analysis $analysis -Plan $plan -ProcUsage $procUsage -Meta $meta

# ---------------------------------------------------------------- 5. Guardado
$txt = Join-Path $OutDir 'informe.txt'
$report | Out-File $txt -Encoding UTF8
# Export-Csv usa las columnas del primer objeto: se fija la union de todas.
$cols = @($samples | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique)
if ($cols.Count) { $samples | Select-Object -Property $cols | Export-Csv (Join-Path $OutDir 'muestras.csv') -NoTypeInformation -Encoding UTF8 }
[pscustomobject]@{ Meta = $meta; Static = $static; Analysis = $analysis; Plan = $plan; Processes = $procUsage } |
    ConvertTo-Json -Depth 8 | Out-File (Join-Path $OutDir 'diagnostico.json') -Encoding UTF8

Write-Host ''
Write-Host "  RESULTADO PRELIMINAR: $($analysis.Verdict)" -ForegroundColor Green
if ($frames) { Write-Host ("  FPS medios {0}  |  1% low {1}  |  min {2}  |  max {3}" -f (Format-N $frames.FpsAvg 1), (Format-N $frames.Fps1Low 1), (Format-N $frames.FpsMin 1), (Format-N $frames.FpsMax 1)) -ForegroundColor Green }
Write-Host "  Informe guardado en: $OutDir" -ForegroundColor White
$copied = $false
if ((Test-IsWindows) -and -not $NoPrompt) {
    try { Set-Clipboard -Value $report; $copied = $true } catch {}
    Start-Process notepad.exe -ArgumentList "`"$txt`""
}
Write-Host ''
if ($copied) {
    Write-Host '  EL INFORME YA ESTA COPIADO. Ve al chat y pulsa Ctrl+V para pegarlo.' -ForegroundColor Green
} else {
    Write-Host '  Copia el contenido de informe.txt (Ctrl+A, Ctrl+C) y pegalo en el chat.' -ForegroundColor Green
}
if (-not $NoPrompt) { [void](Read-Host '  Pulsa ENTER para cerrar esta ventana') }
