# =============================================================================
#  GPU BOOSTER 920MX - Propuesta de optimizaciones (NO aplica nada)
#  Decide, segun lo medido, que optimizaciones tienen sentido en ESTE portatil.
#  Estados posibles:
#    RECOMENDADA      - lo medido indica que puede dar rendimiento real
#    OPCIONAL         - impacto pequeno o dependiente de la situacion
#    YA CORRECTO      - ya esta en el estado optimo, no hay nada que hacer
#    NO RECOMENDADA   - en tu caso empeoraria algo o no aporta
#    NO DISPONIBLE    - tu hardware/driver no lo permite
#    PENDIENTE        - hay que verificarlo en una fase posterior
# =============================================================================

function New-Opt {
    param([string]$Id, [string]$Name, [string]$State, [string]$Why, [string]$How, [string]$Impact, [string]$Phase, [string]$Undo)
    [pscustomobject]@{ Id = $Id; Name = $Name; State = $State; Why = $Why; How = $How; Impact = $Impact; Phase = $Phase; Undo = $Undo }
}

function Test-IsMaxwellOrOlder {
    param([string]$GpuName)
    # 920MX/930MX/940MX y GTX 9xxM son Maxwell (o Kepler). HAGS exige Pascal (GTX 10xx) o superior.
    return ($GpuName -match '\b9[0-9]0MX\b|\b8[0-9]0M\b|\b9[0-9]0M\b|GTX 9[0-9]{2}M?\b|MX1[0-9]0\b')
}

function Get-OptimizationPlan {
    param($Static, $Analysis, $ProcUsage)
    $plan = New-Object System.Collections.ArrayList
    $m = $Analysis.Metrics
    $types = @($Analysis.Findings | Where-Object { $_.Score -ge 40 } | ForEach-Object { $_.Type })
    $cpuBound = $types -contains 'CPU'
    $gpuBound = $types -contains 'GPU'
    $thermal  = $types -contains 'THERMAL'
    $nvGpu = $Static.GPUs | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    $nvName = if ($nvGpu) { $nvGpu.Name } else { '' }
    $game = $Analysis.UsedGameData

    # 1. GPU usada por Roblox --------------------------------------------------
    $gsel = Get-RobloxGpuVerdict -Metrics $m -UsedGameData $game
    $prefs = @($Static.Roblox.GpuPreferences)
    $running = $Static.Roblox.Running | Select-Object -First 1
    $isStore = $running -and $running.Path -match 'WindowsApps'
    $latest = $Static.Roblox.Installs | Select-Object -First 1
    $prefOk = @($prefs | Where-Object { $_.Value -match 'GpuPreference=2' -and (($isStore -and $_.Path -match 'ROBLOXCorporation') -or ($latest -and $_.Path -eq $latest.Path)) }).Count -gt 0
    $onIgpu = $gsel.Code -eq 'IGPU'
    $usesNv = $gsel.Code -eq 'NVIDIA'
    $state = if ($onIgpu) { 'RECOMENDADA' } elseif ($gsel.Code -eq 'DUDA') { 'PENDIENTE' } elseif ($usesNv -and $prefOk) { 'YA CORRECTO' } elseif ($usesNv) { 'OPCIONAL' } else { 'RECOMENDADA' }
    $why = switch ($gsel.Code) {
        'IGPU'   { "Medido: Roblox esta usando la GPU integrada. $($gsel.Evidence -join '; ')." }
        'NVIDIA' { "Medido: Roblox usa la NVIDIA. $($gsel.Evidence -join '; ').$(if ($prefOk) { ' Ya existe la preferencia de Windows de alto rendimiento.' })" }
        'DUDA'   { "Los datos se contradicen: $($gsel.Evidence -join '; '). Hay que confirmarlo antes de tocar nada." }
        default  { 'No se pudo confirmar que GPU usa Roblox (juego cerrado o sin actividad de GPU).' }
    }
    if ($isStore) { $why += ' Estas usando la version de Microsoft Store de Roblox.' }
    [void]$plan.Add((New-Opt 'GPU_SELECT' 'Forzar la NVIDIA 920MX para Roblox' $state $why `
        'Crear la preferencia oficial de Windows "Alto rendimiento" (HKCU\...\DirectX\UserGpuPreferences, GpuPreference=2) para la ruta EXACTA del RobloxPlayerBeta.exe actual, y volver a crearla cuando Roblox se actualice (el Booster lo detecta al abrir el juego).' `
        $(if ($onIgpu) { 'MUY ALTO: la 920MX rinde bastante mas que la grafica integrada.' } else { 'Ninguno si ya usa la NVIDIA; evita que una actualizacion lo rompa.' }) `
        'Fase 6 (GPU Boost) / Fase 7 (Roblox Boost)' 'Se borra el valor creado; se guarda el valor anterior si existia.'))

    # 2. Cargador ---------------------------------------------------------------
    [void]$plan.Add((New-Opt 'AC_POWER' 'Jugar con el cargador conectado' $(if ($Static.Power.OnBattery) { 'RECOMENDADA' } else { 'YA CORRECTO' }) `
        $(if ($Static.Power.OnBattery) { 'Durante el diagnostico el portatil estaba con bateria.' } else { 'El portatil estaba conectado al cargador.' }) `
        'Con bateria, Windows y el driver NVIDIA reducen el limite de potencia de CPU y GPU. No se puede solucionar por software.' 'Alto si estabas jugando con bateria.' 'Aviso en pantalla' 'No aplica'))

    # 3. Plan de energia --------------------------------------------------------
    $ov = $Static.Power.OverlayAC
    $max = $Static.Power.ProcThrottleMax
    $min = $Static.Power.ProcThrottleMin
    $isBest = ($ov -eq 'Maximo rendimiento') -or ($min -and $min.AC -ge 100)
    $st = if ($max -and $max.AC -lt 100 -and -not $thermal) { 'RECOMENDADA' }
          elseif ($isBest) { 'YA CORRECTO' }
          elseif ($thermal) { 'NO RECOMENDADA' }
          elseif ($cpuBound) { 'RECOMENDADA' }
          else { 'OPCIONAL' }
    [void]$plan.Add((New-Opt 'POWER_PLAN' 'Modo de energia "Maximo rendimiento" solo mientras juegas' $st `
        "Actual: plan '$($Static.Power.SchemeName)', modo '$ov', estado min/max CPU con cargador: $(if ($min) { $min.AC } else { 'n/d' })% / $(if ($max) { $max.AC } else { 'n/d' })%. $(if ($thermal) { 'Hay limitacion termica: subir la frecuencia minima solo generaria mas calor.' })" `
        'Activar temporalmente el modo "Maximo rendimiento" de Windows mientras Roblox esta abierto: la CPU sube de frecuencia antes y no baja en los micro-descansos del hilo principal. Al cerrar Roblox se restaura el plan original.' `
        $(if ($cpuBound) { 'Bajo-medio en limitacion por CPU (mas FPS minimos / menos tirones).' } else { 'Bajo.' }) 'Fase 4 / Fase 5' 'powercfg restaura el plan y modo guardados.'))

    # 4. Prioridad de Roblox ----------------------------------------------------
    $bg = if ($m.BackgroundCpu) { $m.BackgroundCpu.Avg } else { $null }
    $st = if (-not $game) { 'PENDIENTE' } elseif (($bg -ge 8) -or $cpuBound) { 'RECOMENDADA' } else { 'OPCIONAL' }
    $lasso = @($Static.OtherTools) -match 'ProcessLasso|ProcessGovernor'
    [void]$plan.Add((New-Opt 'PRIORITY' 'Prioridad "Por encima de lo normal" para Roblox' $st `
        "CPU usada por otros procesos durante el juego: $(Format-N $bg)%. Prioridad actual de Roblox: $(if ($Static.Roblox.Running) { ($Static.Roblox.Running | Select-Object -First 1).PriorityClass } else { 'n/d' }).$(if ($lasso) { ' Process Lasso esta abierto: puede estar bajando la prioridad de Roblox por su cuenta; hay que revisarlo para que no se peleen.' })" `
        'Cambiar la clase de prioridad del proceso (lo mismo que hace el Administrador de tareas). No se usa "Alta" ni "Tiempo real" porque pueden dejar sin CPU al audio, raton o al propio Windows. No toca archivos ni memoria de Roblox.' `
        'Bajo-medio: solo ayuda cuando hay competencia real por la CPU.' 'Fase 5 (CPU Boost)' 'La prioridad vuelve a Normal y desaparece al cerrar Roblox.'))

    # 5. Apps en segundo plano ----------------------------------------------------
    $heavy = @($ProcUsage | Where-Object { -not $_.Critical -and $_.Name -notmatch 'Roblox' -and (($_.CpuPct -ge 2) -or ($_.PrivateMB -ge 400)) } | Sort-Object CpuPct -Descending | Select-Object -First 8)
    $names = ($heavy | ForEach-Object { "$($_.Name) ($(Format-N $_.CpuPct 1)% CPU, $($_.PrivateMB) MB)" }) -join '; '
    [void]$plan.Add((New-Opt 'BACKGROUND' 'Cerrar/pausar aplicaciones de segundo plano (con tu permiso)' $(if ($heavy.Count) { 'RECOMENDADA' } else { 'YA CORRECTO' }) `
        $(if ($heavy.Count) { "Consumen recursos durante el juego: $names" } else { 'No se han visto aplicaciones no criticas con consumo relevante.' }) `
        'Mostrar la lista y cerrar SOLO las que tu marques (nunca procesos de Windows, seguridad, audio o drivers). Libera CPU para el hilo de Roblox y RAM.' `
        'Variable: depende de cuanto consuman. Se medira con el benchmark antes/despues.' 'Fase 5 (CPU Boost) / Fase 5 RAM' 'Las apps cerradas se pueden volver a abrir; no se desinstala ni se desactiva nada de forma permanente.'))

    # 6. Grabacion en segundo plano de Xbox Game Bar ----------------------------
    $g = $Static.Graphics
    $recOn = ($g.HistoricalCapture -eq 1)
    [void]$plan.Add((New-Opt 'GAMEDVR' 'Desactivar la grabacion en segundo plano (Xbox Game Bar)' $(if ($recOn) { 'RECOMENDADA' } else { 'YA CORRECTO' }) `
        "HistoricalCaptureEnabled=$($g.HistoricalCapture), AppCaptureEnabled=$($g.AppCapture), GameDVR_Enabled=$($g.GameDvrEnabled)." `
        'La grabacion continua ("grabar lo que acaba de pasar") codifica video todo el rato mientras juegas y consume GPU/CPU. Se desactiva solo esa grabacion, no Game Bar ni ninguna proteccion.' `
        $(if ($recOn) { 'Medio.' } else { 'Ninguno (ya esta desactivada).' }) 'Fase 4' 'Se restaura el valor original.'))

    # 7. Modo Juego --------------------------------------------------------------
    $gm = $g.GameModeAuto
    [void]$plan.Add((New-Opt 'GAMEMODE' 'Modo Juego de Windows activado' $(if ($gm -eq 0) { 'RECOMENDADA' } else { 'YA CORRECTO' }) `
        "AutoGameModeEnabled=$(if ($null -eq $gm) { 'por defecto (activado)' } else { $gm })." `
        'Windows da preferencia al juego en primer plano y evita que Windows Update instale/notifique durante la partida.' 'Bajo, pero sin coste.' 'Fase 4' 'Se restaura el valor original.'))

    # 8. Gestion de energia NVIDIA ------------------------------------------------
    $clkRatio = if ($m.GpuClock -and $Static.NvStatic -and $Static.NvStatic.'clocks.max.graphics') { $m.GpuClock.P50 / $Static.NvStatic.'clocks.max.graphics' } else { $null }
    $st = if (-not $nvGpu) { 'NO DISPONIBLE' } elseif ($gpuBound -and $clkRatio -and $clkRatio -lt 0.9 -and -not $thermal) { 'RECOMENDADA' } else { 'PENDIENTE' }
    [void]$plan.Add((New-Opt 'NV_POWER' 'NVIDIA: "Preferir rendimiento maximo" en el perfil de Roblox' $st `
        "Reloj GPU en juego: mediana $(Format-N $(if ($m.GpuClock) { $m.GpuClock.P50 })) MHz de $(Format-N $(if ($Static.NvStatic) { $Static.NvStatic.'clocks.max.graphics' })) MHz maximos." `
        'Ajuste oficial del driver (el mismo del Panel de control de NVIDIA) aplicado solo al perfil de Roblox mediante NVAPI: evita que la GPU baje de reloj en momentos de menos carga y tarde en volver a subir.' `
        'Bajo-medio en FPS minimos si la GPU esta bajando de reloj. Nulo si ya va al maximo.' 'Fase 6 (GPU Boost) - se verificara si NVAPI lo permite en tu driver' 'Se guarda y restaura el valor original del perfil.'))

    # 9. Cache de shaders --------------------------------------------------------
    [void]$plan.Add((New-Opt 'SHADER_CACHE' 'Cache de shaders NVIDIA activada y con tamano suficiente' $(if ($nvGpu) { 'PENDIENTE' } else { 'NO DISPONIBLE' }) `
        'Se comprobara su estado leyendo el perfil del driver (NVAPI).' `
        'Guardar en disco los shaders compilados evita recompilarlos (tirones al entrar en zonas nuevas). No aumenta los FPS medios; reduce tirones.' 'Tirones: bajo-medio. FPS medios: ninguno.' 'Fase 6' 'Se restaura el valor original.'))

    # 10. HAGS --------------------------------------------------------------------
    $maxwell = Test-IsMaxwellOrOlder $nvName
    [void]$plan.Add((New-Opt 'HAGS' 'Programacion de GPU acelerada por hardware (HAGS)' $(if ($maxwell) { 'NO DISPONIBLE' } else { 'PENDIENTE' }) `
        $(if ($maxwell) { "La $nvName es arquitectura Maxwell; NVIDIA solo soporta HAGS desde la serie GTX 10 (Pascal)." } else { "Valor actual HwSchMode=$($g.HagsHwSchMode)." }) `
        'Requiere soporte del hardware y driver.' 'Ninguno en tu GPU.' '-' '-'))

    # 11. Overclock ---------------------------------------------------------------
    $st = if (-not $nvGpu) { 'NO DISPONIBLE' } elseif ($thermal) { 'NO RECOMENDADA' } else { 'PENDIENTE' }
    [void]$plan.Add((New-Opt 'OVERCLOCK' 'Overclock experimental de la 920MX (core/memoria)' $st `
        $(if ($thermal) { 'Hay limitacion termica: un overclock produciria mas calor y la GPU bajaria aun mas sus relojes.' } else { 'No se asume que sea compatible. En la fase 9 se comprobara via NVAPI si tu driver permite desplazamientos de reloj en esta GPU movil (muchos portatiles lo bloquean).' }) `
        'Solo desplazamiento de reloj (sin voltaje, sin BIOS ni firmware), en pasos pequenos, con prueba de estabilidad, medicion y reversion automatica.' `
        'Si esta disponible y la GPU es el limite: tipicamente +5-12% en GPU, nunca garantizado.' 'Fase 9 (solo si es compatible)' 'Reversion automatica a 0 MHz de desplazamiento; nada persiste tras reiniciar.'))

    # 11b. Turbo de CPU ----------------------------------------------------------
    $tb = $Static.Turbo
    $noTurbo = (@($Analysis.Findings | Where-Object { $_.Title -match 'turbo' }).Count -gt 0) -or ($tb -and $tb.MaxPerfPct -lt 105)
    [void]$plan.Add((New-Opt 'TURBO' 'Recuperar el turbo de la CPU' $(if ($noTurbo) { 'PENDIENTE' } elseif ($tb) { 'YA CORRECTO' } else { 'PENDIENTE' }) `
        $(if ($noTurbo) { "Medido: la CPU no sube de su frecuencia base$(if ($tb) { " (maximo $($tb.MaxMHz) MHz en la prueba)" }). Con un juego limitado por CPU, es lo que mas FPS puede devolver." } elseif ($tb) { "La CPU llego a $($tb.MaxMHz) MHz en la prueba: el turbo funciona." } else { 'No se hizo la prueba de turbo.' }) `
        'Primero averiguar POR QUE esta bloqueado (modo de energia de Lenovo Vantage, driver termico Intel DPTF, opcion de BIOS o temperatura). Solo se cambiaria un ajuste de Windows/Lenovo reversible; nunca la BIOS.' `
        'Potencialmente alto en limitacion por CPU (el i7-7500U puede pasar de 2,7 a 3,5 GHz en un nucleo).' 'Fase 5 (CPU Boost), tras investigar la causa' 'Se restaura el ajuste original.'))

    # 12. Termico -----------------------------------------------------------------
    [void]$plan.Add((New-Opt 'THERMAL' 'Gestion termica: reducir turbo de CPU si el calor limita a la GPU' $(if ($thermal -and $gpuBound) { 'RECOMENDADA' } elseif ($thermal) { 'OPCIONAL' } else { 'NO RECOMENDADA' }) `
        $(if ($thermal) { 'Se ha medido limitacion termica.' } else { 'No se ha medido limitacion termica: quitar el turbo solo te haria perder rendimiento de CPU.' }) `
        'En portatiles con disipador compartido, limitar la CPU al 99% (desactiva el turbo) baja mucho su calor y deja margen termico a la GPU. Solo se aplicaria si el benchmark demuestra mas FPS. Ademas: limpiar ventiladores y elevar la parte trasera del portatil.' `
        'Variable; solo se mantiene si el benchmark lo confirma.' 'Fase 8 (sistema termico)' 'Se restaura el estado maximo del procesador original.'))

    # 13. RAM -----------------------------------------------------------------------
    $mods = @($Static.RAM.Modules)
    $single = $mods.Count -eq 1
    $ramPress = $types -contains 'RAM'
    [void]$plan.Add((New-Opt 'RAM' 'Memoria RAM' $(if ($ramPress) { 'RECOMENDADA' } else { 'YA CORRECTO' }) `
        "$(if ($ramPress) { 'Se ha medido presion de memoria.' } else { 'No se ha medido falta de RAM durante el juego.' }) Modulos: $($mods.Count) ($(($mods | ForEach-Object { "$($_.SizeGB) GB $($_.Type) $($_.ConfiguredMHz) MHz" }) -join ' + '))$(if ($single) { ' -> un solo modulo = canal simple (limitacion de hardware, no se arregla por software).' })" `
        'Liberar RAM cerrando aplicaciones pesadas (con tu permiso). NO se usan "limpiadores de RAM": vaciar la cache/standby obliga a Windows a volver a leer del disco y empeora los tirones.' `
        $(if ($ramPress) { 'Medio (menos tirones).' } else { 'Ninguno: con RAM suficiente no hay nada que ganar.' }) 'Fase 5' 'No aplica.'))

    # 14. Limite de FPS del juego -------------------------------------------------------
    if ($Analysis.FpsCap) {
        [void]$plan.Add((New-Opt 'FPS_CAP' "Subir el limite de FPS de Roblox (ahora ~$($Analysis.FpsCap))" 'RECOMENDADA' `
            'Los FPS medidos estan clavados en un limite.' `
            "Cambiarlo TU en el menu oficial de Roblox (Configuracion > 'Frecuencia de fotogramas maxima'). El Booster no modifica Roblox. Si tu pantalla es de $($Static.RefreshHz) Hz, por encima no veras mas imagenes, pero baja la latencia." `
            'Solo sube la media si el hardware da para mas.' 'Informativo' 'Lo cambias tu en el juego.'))
    }

    # 15. Driver ---------------------------------------------------------------------------
    if ($nvGpu) {
        $age = $null
        if ($nvGpu.DriverDate) { $age = [math]::Round(((Get-Date) - [datetime]$nvGpu.DriverDate).TotalDays / 30) }
        [void]$plan.Add((New-Opt 'DRIVER' 'Driver NVIDIA' $(if ($age -and $age -gt 18) { 'RECOMENDADA' } else { 'OPCIONAL' }) `
            "Instalado: $($nvGpu.NvidiaDriver) (Windows $($nvGpu.DriverVersion)), fecha $(if ($nvGpu.DriverDate) { ([datetime]$nvGpu.DriverDate).ToString('yyyy-MM-dd') } else { 'n/d' })$(if ($age) { ", hace ~$age meses" })." `
            'Actualizar solo con el driver oficial de nvidia.com o del fabricante del portatil (Maxwell recibe soporte hasta la rama 580). El Booster nunca instala drivers.' `
            'Variable; a veces corrige rendimiento en juegos DX11.' 'Recomendacion manual' 'Se puede volver al anterior desde el Administrador de dispositivos.'))
    }
    return @($plan)
}

# Optimizaciones descartadas a proposito (placebo o peligrosas).
$script:Rejected = @(
    'Limpiadores de RAM / vaciar memoria standby: empeoran los tirones (Windows vuelve a leer del disco).',
    'Botones tipo "GPU 200%": no existen; la GPU no puede superar sus relojes sin overclock real.',
    'Tweaks de registro "gaming" sin efecto medible en Roblox (NetworkThrottlingIndex, SystemResponsiveness, Win32PrioritySeparation, desactivar core parking...).',
    'Prioridad "Tiempo real"/"Alta" para Roblox: puede bloquear audio, raton y el propio Windows.',
    'Desactivar Windows Defender, actualizaciones o protecciones: prohibido por seguridad.',
    'Modificar archivos/cliente de Roblox, FFlags o desbloqueadores de FPS: prohibido (sin trampas ni modificaciones del cliente).',
    'Modificar BIOS, firmware, voltajes o instalar drivers modificados: prohibido.'
)
