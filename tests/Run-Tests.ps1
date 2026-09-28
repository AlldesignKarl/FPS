# Pruebas del analisis con datos sinteticos. Ejecutar:  powershell -File tests\Run-Tests.ps1
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
. (Join-Path $src 'lib/Analysis.ps1')
. (Join-Path $src 'lib/Collectors.ps1')
. (Join-Path $src 'lib/Plan.ps1')
. (Join-Path $src 'lib/Report.ps1')

$script:fail = 0; $script:pass = 0
function Assert([bool]$cond, [string]$msg) {
    if ($cond) { $script:pass++; Write-Host "  OK   $msg" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL $msg" -ForegroundColor Red }
}

function New-Samples {
    param([int]$n = 20, [hashtable]$Set = @{})
    $base = @{
        RobloxRunning = $true; GpuUtil = 70; GpuClockMHz = 993; GpuMemClockMHz = 900; GpuTempC = 70; VramUsedMB = 900; VramTotalMB = 2048
        GpuThrottleMask = 0; CpuTotal = 45; CpuCoreMax = 60; CpuPerfPct = 110; CpuMHz = 2800; CpuLimitFlags = 0
        ThermalZoneC = 60; PassiveLimitPct = 100; RamUsedPct = 60; RamAvailMB = 4500; CommitPct = 55; PageReadsPerSec = 2
        OnBattery = $false; RobloxCpuPct = 30; RobloxTopThreadPct = 60; RobloxGpuNvidia = 60; RobloxGpuOther = 0.5
    }
    foreach ($k in $Set.Keys) { $base[$k] = $Set[$k] }
    1..$n | ForEach-Object { [pscustomobject]$base }
}
$ctx = [pscustomobject]@{ GpuMaxClockMHz = 993; ProcThrottleMaxAC = 100; PowerOverlayName = 'Equilibrado (recomendado)'; RefreshHz = 60 }

Write-Host 'Utilidades'
Assert ((Convert-WinDriverToNvidia '31.0.15.5222') -eq '552.22') 'Version driver Windows -> NVIDIA'
Assert ((Convert-WinDriverToNvidia '27.21.14.6079') -eq '460.79') 'Version driver antigua'
Assert ((ConvertTo-NvBitmask '0x0000000000000024') -eq 0x24) 'Mascara hex de throttle'
Assert ((Get-NvThrottleText 0x24) -match 'energia' -and (Get-NvThrottleText 0x24) -match 'termica') 'Texto de mascara'
$st = Get-Stats @(1, 2, 3, 4, $null, 5)
Assert ($st.Count -eq 5 -and $st.Avg -eq 3 -and $st.P50 -eq 3 -and $st.Max -eq 5) 'Estadisticas ignoran nulos'
Assert ((ConvertTo-Num '[N/A]') -eq $null -and (ConvertTo-Num '65.5') -eq 65.5) 'Conversion de valores nvidia-smi'
Assert ((Get-GpuMemoryTypeGuess 900) -match 'DDR3' -and (Get-GpuMemoryTypeGuess 2505) -match 'GDDR5') 'Tipo de VRAM por reloj'
Assert (Test-IsMaxwellOrOlder 'NVIDIA GeForce 920MX') 'La 920MX se reconoce como Maxwell'
Assert (-not (Test-IsMaxwellOrOlder 'NVIDIA GeForce GTX 1650')) 'GTX 1650 no es Maxwell'

Write-Host 'Frame stats'
$ft = @(1..200 | ForEach-Object { 20.0 }) + @(1..2 | ForEach-Object { 50.0 })
$fs = Get-FrameStats -FrameTimesMs $ft -GpuBusyMs @($ft | ForEach-Object { $_ * 0.5 })
Assert ([math]::Abs($fs.FpsMax - 50) -lt 0.01 -and [math]::Abs($fs.FpsMin - 20) -lt 0.01) 'FPS min/max desde frame times'
Assert ([math]::Abs($fs.FpsAvg - (1000 * 202 / (200 * 20 + 100))) -lt 0.01) 'FPS medio = fotogramas / tiempo'
Assert ([math]::Abs($fs.GpuBusyRatioP50 - 0.5) -lt 0.001) 'Ratio GPUBusy/FrameTime'
Assert ($null -eq (Get-FrameStats -FrameTimesMs @(16, 16))) 'Pocos fotogramas => sin datos'

Write-Host 'Cuello de botella'
$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ GpuUtil = 62; CpuCoreMax = 98; RobloxTopThreadPct = 97; CpuTotal = 55 }) -Frames $null -Context $ctx
Assert ($a.Verdict -eq 'CPU BOTTLENECK') "CPU al 100% en un hilo + GPU 62% => $($a.Verdict)"

$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ GpuUtil = 99; CpuCoreMax = 60; RobloxTopThreadPct = 55 }) -Frames $null -Context $ctx
Assert ($a.Verdict -eq 'GPU BOTTLENECK') "GPU 99% => $($a.Verdict)"

$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ GpuUtil = 99; GpuTempC = 95; GpuThrottleMask = 0x20; GpuClockMHz = 700 }) -Frames $null -Context $ctx
Assert ($a.Verdict -eq 'THERMAL BOTTLENECK') "GPU con throttling termico => $($a.Verdict)"

$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ CpuCoreMax = 95; CpuPerfPct = 60; CpuLimitFlags = 1; ThermalZoneC = 96 }) -Frames $null -Context $ctx
Assert ($a.Verdict -eq 'THERMAL BOTTLENECK') "CPU por debajo de base y caliente => $($a.Verdict)"

$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ OnBattery = $true }) -Frames $null -Context $ctx
Assert ($a.Verdict -eq 'POWER BOTTLENECK') "Con bateria => $($a.Verdict)"

$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ RobloxGpuNvidia = 0; RobloxGpuOther = 80; GpuUtil = 3 }) -Frames $null -Context $ctx
Assert ($a.Verdict -match 'INTEGRADA') "Roblox en iGPU => $($a.Verdict)"

$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ RamUsedPct = 96; RamAvailMB = 400; PageReadsPerSec = 150 }) -Frames $null -Context $ctx
Assert ($a.Verdict -eq 'RAM BOTTLENECK') "RAM llena y paginando => $($a.Verdict)"

$capFt = @(1..600 | ForEach-Object { 16.67 + (($_ % 5) - 2) * 0.1 })
$fsCap = Get-FrameStats -FrameTimesMs $capFt -GpuBusyMs @($capFt | ForEach-Object { 9.0 })
$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ GpuUtil = 55 }) -Frames $fsCap -Context $ctx
Assert ($a.FpsCap -eq 60 -and $a.Verdict -match 'FPS limitados a 60') "FPS clavados a 60 => $($a.Verdict)"

$gpuFt = @(1..600 | ForEach-Object { 22 + ($_ % 7) })
$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ GpuUtil = 97 }) -Frames (Get-FrameStats -FrameTimesMs $gpuFt -GpuBusyMs @($gpuFt | ForEach-Object { $_ * 0.97 })) -Context $ctx
Assert ($a.Verdict -eq 'GPU BOTTLENECK' -and -not $a.FpsCap) "PresentMon GPU ocupada 97% del fotograma => $($a.Verdict)"

$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ RobloxRunning = $false }) -Frames $null -Context $ctx
Assert ($a.Verdict -eq 'SIN DATOS DE JUEGO') 'Sin Roblox => sin veredicto'

Write-Host 'Plan e informe'
$static = [pscustomobject]@{
    CPU = [pscustomobject]@{ Name = 'Intel(R) Core(TM) i5-7200U CPU @ 2.50GHz'; Cores = 2; Threads = 4; BaseMHz = 2712 }
    GPUs = @([pscustomobject]@{ Name = 'NVIDIA GeForce 920MX'; DriverVersion = '31.0.15.5222'; NvidiaDriver = '552.22'; DriverDate = (Get-Date).AddMonths(-30); VramMB = 2048; RefreshHz = 60 },
             [pscustomobject]@{ Name = 'Intel(R) HD Graphics 620'; DriverVersion = '31.0.101.2111'; RefreshHz = 60 })
    NvStatic = [pscustomobject]@{ name = 'NVIDIA GeForce 920MX'; driver_version = '552.22'; 'memory.total' = 2048; 'clocks.max.graphics' = 993; 'clocks.max.memory' = 900 }
    RAM = [pscustomobject]@{ TotalGB = 11.9; TotalMB = 12200; Modules = @([pscustomobject]@{ SizeGB = 4; Type = 'DDR4'; ConfiguredMHz = 2133 }, [pscustomobject]@{ SizeGB = 8; Type = 'DDR4'; ConfiguredMHz = 2133 }) }
    Power = [pscustomobject]@{ SchemeName = 'Equilibrado'; OverlayAC = 'Equilibrado (recomendado)'; OverlayDC = 'Mejor bateria'; ProcThrottleMin = [pscustomobject]@{ AC = 5; DC = 5 }; ProcThrottleMax = [pscustomobject]@{ AC = 100; DC = 100 }; HasBattery = $true; OnBattery = $false; BatteryPct = 100 }
    Graphics = [pscustomobject]@{ HistoricalCapture = 1; GameModeAuto = $null; HagsHwSchMode = $null }
    Roblox = [pscustomobject]@{ Installs = @([pscustomobject]@{ Path = 'C:\x\RobloxPlayerBeta.exe' }); GpuPreferences = @(); Running = @(); Settings = [ordered]@{ GraphicsQualityLevel = '7' }; SettingsFile = 'C:\x\GlobalBasicSettings_13.xml' }
    Machine = [pscustomobject]@{}; OS = [pscustomobject]@{}; PageFile = @(); Disks = @(); StartupItems = @(); RefreshHz = 60
}
$a = Invoke-BottleneckAnalysis -Samples (New-Samples -Set @{ GpuUtil = 62; CpuCoreMax = 98; RobloxTopThreadPct = 97 }) -Frames $fsCap -Context $ctx
$procs = @([pscustomobject]@{ Name = 'chrome'; Count = 12; CpuPct = 6.5; PrivateMB = 900; WorkingSetMB = 1000; Critical = $false; KnownBackground = $true },
           [pscustomobject]@{ Name = 'svchost'; Count = 70; CpuPct = 3; PrivateMB = 800; WorkingSetMB = 900; Critical = $true; KnownBackground = $false })
$plan = Get-OptimizationPlan -Static $static -Analysis $a -ProcUsage $procs
$byId = @{}; foreach ($o in $plan) { $byId[$o.Id] = $o }
Assert ($byId['HAGS'].State -eq 'NO DISPONIBLE') 'HAGS no disponible en 920MX'
Assert ($byId['GAMEDVR'].State -eq 'RECOMENDADA') 'Grabacion en segundo plano activa => recomendada'
Assert ($byId['BACKGROUND'].Why -match 'chrome' -and $byId['BACKGROUND'].Why -notmatch 'svchost') 'Solo se proponen apps no criticas'
Assert ($byId['PRIORITY'].State -eq 'RECOMENDADA') 'Prioridad recomendada con CPU bottleneck'
Assert ($byId['FPS_CAP'].State -eq 'RECOMENDADA') 'Limite de FPS detectado'
Assert ($byId['GPU_SELECT'].State -eq 'OPCIONAL') 'Roblox ya en NVIDIA sin preferencia => opcional'
Assert ($byId['DRIVER'].State -eq 'RECOMENDADA') 'Driver de hace 30 meses => actualizar'

$meta = [pscustomobject]@{ Date = 'hoy'; ToolVersion = 'test'; IsAdmin = $true; CaptureSeconds = 90; FpsSource = 'test'; NvSmiRobloxLines = @('|    0   N/A  N/A      8123    C+G   ...\RobloxPlayerBeta.exe      N/A      |') }
$txt = Build-TextReport -Static $static -Analysis $a -Plan $plan -ProcUsage $procs -Meta $meta
Assert ($txt -match 'RESPUESTAS A TUS 10 PREGUNTAS' -and $txt -match '920MX' -and $txt -match 'DDR3') 'El informe se genera'
Assert ($txt -match '8\. La CPU como cuello de botella: SI') 'Pregunta 8 responde SI en caso CPU'
Assert ($txt -match 'nvidia-smi: .*RobloxPlayerBeta') 'El informe incluye las lineas de nvidia-smi con Roblox'

Write-Host 'Codigo'
# Windows PowerShell no distingue mayusculas en variables: $L y $l son la misma.
$collisions = foreach ($file in Get-ChildItem $src -Recurse -Filter *.ps1) {
    $tk = $null; $pe = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tk, [ref]$pe)
    foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $map = @{}
        foreach ($v in $fn.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $n = $v.VariablePath.UserPath
            if ($n -match ':') { continue }
            $k = $n.ToLowerInvariant()
            if (-not $map.ContainsKey($k)) { $map[$k] = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal) }
            [void]$map[$k].Add($n)
        }
        foreach ($k in $map.Keys) { if ($map[$k].Count -gt 1) { "$($file.Name) $($fn.Name): $(@($map[$k]) -join '/')" } }
    }
}
Assert (@($collisions).Count -eq 0) "Sin variables que solo difieren en mayusculas $(@($collisions) -join '; ')"

Write-Host ''
Write-Host "Resultado: $script:pass OK, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
