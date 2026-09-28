# =============================================================================
#  GPU BOOSTER 920MX - Recoleccion de datos (SOLO LECTURA)
#  Ninguna funcion de este archivo modifica el sistema: solo consulta WMI/CIM,
#  el registro (lectura), powercfg (consulta) y nvidia-smi (consulta).
#  Se usan clases WMI de rendimiento porque, a diferencia de Get-Counter,
#  sus nombres no cambian con el idioma de Windows.
# =============================================================================

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Test-IsWindows { return ($env:OS -eq 'Windows_NT') }

function Test-IsAdmin {
    if (-not (Test-IsWindows)) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Cim {
    param([string]$Class, [string]$Namespace = 'root/cimv2', [string]$Filter)
    if (-not (Test-IsWindows)) { return @() }
    try {
        $p = @{ ClassName = $Class; Namespace = $Namespace; ErrorAction = 'Stop' }
        if ($Filter) { $p.Filter = $Filter }
        return @(Get-CimInstance @p)
    } catch { return @() }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function ConvertTo-Num {
    param($v)
    if ($null -eq $v) { return $null }
    $s = "$v".Trim()
    if ($s -eq '' -or $s -match '^\[.*\]$' -or $s -eq 'N/A') { return $null }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
    return $s
}

# ---------------------------------------------------------------- nvidia-smi
function Find-NvidiaSmi {
    if (-not (Test-IsWindows)) { return $null }
    $c = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")
    foreach ($p in $cands) { if (Test-Path $p) { return $p } }
    $d = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($d) { return $d.FullName }
    return $null
}

function Invoke-NvQuery {
    param([string]$Exe, [string[]]$Fields)
    if (-not $Exe -or $Fields.Count -eq 0) { return $null }
    try {
        $out = & $Exe "--query-gpu=$($Fields -join ',')" '--format=csv,noheader,nounits' 2>$null
    } catch { return $null }
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $line = "$(@($out)[0])"
    if ($line -match 'not a valid field|Invalid combination|error' ) { return $null }
    $parts = $line -split ',\s*'
    if ($parts.Count -ne $Fields.Count) { return $null }
    $r = [ordered]@{}
    for ($i = 0; $i -lt $Fields.Count; $i++) { $r[$Fields[$i]] = ConvertTo-Num $parts[$i] }
    return $r
}

# Consulta tolerante: si un campo no existe en este driver, se prueba uno a uno.
function Get-NvFields {
    param([string]$Exe, [string[]]$Fields)
    $all = Invoke-NvQuery -Exe $Exe -Fields $Fields
    if ($all) { return @{ Values = $all; Supported = $Fields } }
    $vals = [ordered]@{}; $ok = @()
    foreach ($f in $Fields) {
        $one = Invoke-NvQuery -Exe $Exe -Fields @($f)
        if ($one) { $vals[$f] = $one[$f]; $ok += $f }
    }
    return @{ Values = $vals; Supported = $ok }
}

$script:NvStaticFields = @(
    'name', 'driver_version', 'vbios_version', 'pci.device_id', 'pci.sub_device_id',
    'memory.total', 'clocks.max.graphics', 'clocks.max.memory', 'clocks.max.sm',
    'clocks.applications.graphics', 'clocks.default_applications.graphics',
    'power.management', 'power.limit', 'power.max_limit', 'enforced.power.limit',
    'pcie.link.gen.max', 'pcie.link.width.max', 'pcie.link.gen.current', 'pcie.link.width.current',
    'temperature.gpu', 'pstate', 'display_mode', 'display_active', 'driver_model.current'
)
$script:NvSampleFields = @(
    'utilization.gpu', 'utilization.memory', 'temperature.gpu', 'clocks.graphics', 'clocks.memory',
    'memory.used', 'memory.total', 'pstate', 'power.draw', 'clocks_throttle_reasons.active', 'clocks_event_reasons.active'
)

function Get-NvidiaSmiProcessLines {
    param([string]$Exe)
    if (-not $Exe) { return @() }
    try { return @(& $Exe 2>$null | Where-Object { $_ -match '\.exe' }) } catch { return @() }
}

# 31.0.15.5222 -> 552.22
function Convert-WinDriverToNvidia {
    param([string]$v)
    if (-not $v) { return $null }
    $g = $v -split '\.'
    if ($g.Count -lt 4) { return $null }
    $s = $g[2] + $g[3]
    if ($s.Length -lt 5) { return $null }
    $s = $s.Substring($s.Length - 5)
    return ('{0}.{1}' -f $s.Substring(0, 3), $s.Substring(3))
}

# ------------------------------------------------------------------ powercfg
$script:PowerGuids = @{
    SubProcessor     = '54533251-82be-4824-96c1-47b60b740d00'
    ProcThrottleMin  = '893dee8e-2bef-41e0-89c6-b55d0929964c'
    ProcThrottleMax  = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    PerfBoostMode    = 'be337238-0d82-4146-a960-4f3749d470c7'
    SysCoolingPolicy = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
    SubPciExpress    = '501a4d13-42af-4429-9fd1-a8218c268e20'
    PcieAspm         = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
}
$script:OverlayNames = @{
    'ded574b5-45a0-4f42-8737-46345c09c238' = 'Maximo rendimiento'
    '00000000-0000-0000-0000-000000000000' = 'Equilibrado (recomendado)'
    '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Mejor bateria'
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Ahorro de bateria'
}
$script:PerfBoostNames = @{ 0 = 'Deshabilitado (sin turbo)'; 1 = 'Habilitado'; 2 = 'Agresivo'; 3 = 'Habilitado eficiente'; 4 = 'Agresivo eficiente'; 5 = 'Agresivo garantizado'; 6 = 'Eficiente agresivo garantizado' }

function Get-PowerSettingValue {
    param([string]$Sub, [string]$Setting)
    try { $out = & powercfg.exe /qh SCHEME_CURRENT $Sub $Setting 2>$null } catch { return $null }
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $hex = @([regex]::Matches(($out -join "`n"), '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }
    # Las dos ultimas son el valor actual con cargador (AC) y con bateria (DC).
    return [pscustomobject]@{
        AC = [Convert]::ToInt32($hex[$hex.Count - 2].Substring(2), 16)
        DC = [Convert]::ToInt32($hex[$hex.Count - 1].Substring(2), 16)
    }
}

function Get-PowerInfo {
    $r = [ordered]@{}
    try { $act = (& powercfg.exe /getactivescheme 2>$null) -join ' ' } catch { $act = '' }
    if ($act -match '([0-9a-fA-F-]{36})\s*\((.+)\)') { $r.SchemeGuid = $Matches[1]; $r.SchemeName = $Matches[2].Trim() }
    $pp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    $ovAC = Get-RegValue $pp 'ActiveOverlayAcPowerScheme'
    $ovDC = Get-RegValue $pp 'ActiveOverlayDcPowerScheme'
    $r.OverlayAC = if ($ovAC) { $n = $script:OverlayNames["$ovAC".ToLower()]; if ($n) { $n } else { "$ovAC" } } else { 'Equilibrado (recomendado)' }
    $r.OverlayDC = if ($ovDC) { $n = $script:OverlayNames["$ovDC".ToLower()]; if ($n) { $n } else { "$ovDC" } } else { 'Equilibrado (recomendado)' }
    $g = $script:PowerGuids
    $r.ProcThrottleMin = Get-PowerSettingValue $g.SubProcessor $g.ProcThrottleMin
    $r.ProcThrottleMax = Get-PowerSettingValue $g.SubProcessor $g.ProcThrottleMax
    $r.PerfBoostMode   = Get-PowerSettingValue $g.SubProcessor $g.PerfBoostMode
    $r.CoolingPolicy   = Get-PowerSettingValue $g.SubProcessor $g.SysCoolingPolicy
    $r.PcieAspm        = Get-PowerSettingValue $g.SubPciExpress $g.PcieAspm
    $bat = @(Get-Cim Win32_Battery)
    $r.HasBattery = $bat.Count -gt 0
    if ($bat.Count -gt 0) {
        $r.BatteryPct = $bat[0].EstimatedChargeRemaining
        $r.OnBattery  = ($bat[0].BatteryStatus -eq 1)    # 1 = descargando
    } else { $r.OnBattery = $false }
    return [pscustomobject]$r
}

# -------------------------------------------------------------------- Roblox
$script:RobloxProcNames = @('RobloxPlayerBeta')

function Get-RobloxProcesses {
    $p = @(Get-Process -Name $script:RobloxProcNames -ErrorAction SilentlyContinue)
    # Version de Microsoft Store
    $store = @(Get-Process -Name 'Windows10Universal' -ErrorAction SilentlyContinue | Where-Object { $_.Path -match 'ROBLOX' })
    return @($p + $store)
}

function Get-RobloxInfo {
    $r = [ordered]@{ Installs = @(); Running = @(); SettingsFile = $null; Settings = [ordered]@{}; GpuPreferences = @(); StoreApp = $null }
    $roots = @(
        "$env:LOCALAPPDATA\Roblox\Versions",
        "$env:LOCALAPPDATA\Bloxstrap\Versions",
        "$env:LOCALAPPDATA\Fishstrap\Versions",
        "${env:ProgramFiles(x86)}\Roblox\Versions",
        "$env:ProgramFiles\Roblox\Versions"
    )
    foreach ($root in $roots) {
        if ($root -and (Test-Path $root)) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $exe = Join-Path $_.FullName 'RobloxPlayerBeta.exe'
                if (Test-Path $exe) {
                    $fi = Get-Item $exe
                    $r.Installs += [pscustomobject]@{ Path = $exe; Version = $fi.VersionInfo.FileVersion; Modified = $fi.LastWriteTime }
                }
            }
        }
    }
    $r.Installs = @($r.Installs | Sort-Object Modified -Descending)
    try { $app = Get-AppxPackage -Name '*ROBLOX*' -ErrorAction Stop | Select-Object -First 1; if ($app) { $r.StoreApp = "$($app.Name) $($app.Version)" } } catch {}
    foreach ($p in Get-RobloxProcesses) {
        $path = $null; try { $path = $p.Path } catch {}
        $r.Running += [pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; Path = $path; PriorityClass = $(try { "$($p.PriorityClass)" } catch { 'n/d' }); WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB) }
    }
    # Ajustes graficos guardados por Roblox (solo lectura, no se modifican nunca)
    $sf = Get-ChildItem "$env:LOCALAPPDATA\Roblox\GlobalBasicSettings_*.xml" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Studio' } | Sort-Object Name -Descending | Select-Object -First 1
    if ($sf) {
        $r.SettingsFile = $sf.FullName
        try {
            $txt = Get-Content $sf.FullName -Raw -ErrorAction Stop
            foreach ($mt in [regex]::Matches($txt, '<(\w+) name="([^"]*(Quality|Graphics|Frame|Fps|FPS|VSync|Fullscreen)[^"]*)">([^<]*)</\1>')) {
                $r.Settings[$mt.Groups[2].Value] = $mt.Groups[4].Value
            }
        } catch {}
    }
    # Preferencias de GPU de Windows (Configuracion > Pantalla > Graficos)
    $gp = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    try {
        $props = (Get-ItemProperty $gp -ErrorAction Stop).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
        foreach ($pr in $props) {
            if ($pr.Name -match 'roblox') { $r.GpuPreferences += [pscustomobject]@{ Path = $pr.Name; Value = "$($pr.Value)" } }
        }
    } catch {}
    return [pscustomobject]$r
}

# ----------------------------------------------------- Ajustes de Windows GFX
function Get-GraphicsSettings {
    $r = [ordered]@{}
    $r.HagsHwSchMode   = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'   # 2 = activado
    $r.GameModeAuto    = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'               # null/1 = activado
    $r.GameDvrEnabled  = Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    $r.AppCapture      = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'
    $r.HistoricalCapture = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled'
    $r.DxGlobal        = Get-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings'
    $r.Transparency    = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency'
    $r.VisualFx        = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting'
    return [pscustomobject]$r
}

# ------------------------------------------------------------ Info estatica
function Get-GpuAdaptersFromRegistry {
    $out = @()
    $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DriverDesc) {
            $mem = $p.'HardwareInformation.qwMemorySize'
            if (-not $mem) { $m2 = $p.'HardwareInformation.MemorySize'; if ($m2 -is [byte[]]) { $mem = [BitConverter]::ToUInt32($m2, 0) } else { $mem = $m2 } }
            $out += [pscustomobject]@{ Name = $p.DriverDesc; DriverVersion = $p.DriverVersion; DriverDate = $p.DriverDate; VramMB = $(if ($mem) { [math]::Round([double]$mem / 1MB) } else { $null }) }
        }
    }
    return $out
}

function Get-StaticInfo {
    param([string]$NvSmi)
    $r = [ordered]@{}
    $os = Get-Cim Win32_OperatingSystem | Select-Object -First 1
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $r.OS = [pscustomobject]@{
        Caption = $os.Caption; Version = $os.Version; Build = $os.BuildNumber
        UBR = Get-RegValue $cv 'UBR'; DisplayVersion = Get-RegValue $cv 'DisplayVersion'; Arch = $os.OSArchitecture
        LastBoot = $os.LastBootUpTime
    }
    $cs = Get-Cim Win32_ComputerSystem | Select-Object -First 1
    $bios = Get-Cim Win32_BIOS | Select-Object -First 1
    $r.Machine = [pscustomobject]@{ Manufacturer = $cs.Manufacturer; Model = $cs.Model; Bios = $bios.SMBIOSBIOSVersion; BiosDate = $bios.ReleaseDate }

    $cpu = Get-Cim Win32_Processor | Select-Object -First 1
    $r.CPU = [pscustomobject]@{
        Name = "$($cpu.Name)".Trim(); Cores = $cpu.NumberOfCores; Threads = $cpu.NumberOfLogicalProcessors
        BaseMHz = $cpu.MaxClockSpeed; L2KB = $cpu.L2CacheSize; L3KB = $cpu.L3CacheSize; Socket = $cpu.SocketDesignation
    }

    # Memoria fisica
    $mods = @(Get-Cim Win32_PhysicalMemory)
    $memTypes = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
    $r.RAM = [pscustomobject]@{
        TotalGB  = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { $null }
        TotalMB  = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1MB) } else { $null }
        Modules  = @($mods | ForEach-Object { [pscustomobject]@{
            Slot = $_.DeviceLocator; Bank = $_.BankLabel; SizeGB = [math]::Round($_.Capacity / 1GB, 1)
            SpeedMHz = $_.Speed; ConfiguredMHz = $_.ConfiguredClockSpeed; Type = $memTypes[[int]$_.SMBIOSMemoryType]
            Manufacturer = "$($_.Manufacturer)".Trim(); Part = "$($_.PartNumber)".Trim() } })
    }
    $pf = @(Get-Cim Win32_PageFileUsage)
    $r.PageFile = @($pf | ForEach-Object { [pscustomobject]@{ Path = $_.Name; AllocatedMB = $_.AllocatedBaseSize; CurrentMB = $_.CurrentUsage; PeakMB = $_.PeakUsage } })

    # GPUs
    $vc = @(Get-Cim Win32_VideoController)
    $reg = @(Get-GpuAdaptersFromRegistry)
    $r.GPUs = @($vc | ForEach-Object {
        $n = $_.Name
        $rg = $reg | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        [pscustomobject]@{
            Name = $n; Vendor = $_.AdapterCompatibility; DriverVersion = $_.DriverVersion; DriverDate = $_.DriverDate
            NvidiaDriver = $(if ($n -match 'NVIDIA') { Convert-WinDriverToNvidia $_.DriverVersion } else { $null })
            VramMB = $(if ($rg -and $rg.VramMB) { $rg.VramMB } elseif ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1MB) } else { $null })
            PnpId = $_.PNPDeviceID; Status = $_.Status
            Resolution = $(if ($_.CurrentHorizontalResolution) { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" } else { $null })
            RefreshHz = $_.CurrentRefreshRate
        }
    })
    $r.RefreshHz = ($r.GPUs | Where-Object { $_.RefreshHz } | Select-Object -First 1).RefreshHz

    # nvidia-smi
    $r.NvSmiPath = $NvSmi
    if ($NvSmi) {
        $q = Get-NvFields -Exe $NvSmi -Fields $script:NvStaticFields
        $r.NvStatic = [pscustomobject]$q.Values
        $r.NvStaticSupported = $q.Supported
    }

    # Disco
    try {
        $r.Disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.FriendlyName; Media = "$($_.MediaType)"; Bus = "$($_.BusType)"; SizeGB = [math]::Round($_.Size / 1GB) } })
    } catch { $r.Disks = @() }
    $sysDrive = Get-Cim Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" | Select-Object -First 1
    if ($sysDrive) { $r.SystemDriveFreeGB = [math]::Round($sysDrive.FreeSpace / 1GB, 1) }

    $r.Power    = Get-PowerInfo
    $r.Graphics = Get-GraphicsSettings
    $r.Roblox   = Get-RobloxInfo
    try { $r.StartupItems = @(Get-Cim Win32_StartupCommand | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Command = $_.Command; Location = $_.Location } }) } catch { $r.StartupItems = @() }
    return [pscustomobject]$r
}

# --------------------------------------------------------------- Procesos
# Procesos que el Booster NUNCA tocara (sistema, seguridad, graficos, audio).
$script:CriticalProcs = @(
    'Idle', 'System', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso', 'svchost',
    'dwm', 'explorer', 'fontdrvhost', 'Memory Compression', 'sihost', 'ctfmon', 'spoolsv', 'audiodg', 'conhost',
    'MsMpEng', 'NisSrv', 'SecurityHealthService', 'SecurityHealthSystray', 'MpDefenderCoreService', 'smartscreen',
    'WmiPrvSE', 'RuntimeBroker', 'StartMenuExperienceHost', 'ShellExperienceHost', 'SearchHost', 'SearchIndexer',
    'TextInputHost', 'taskhostw', 'dllhost', 'WUDFHost', 'dasHost', 'LsaIso', 'SgrmBroker', 'MsSense',
    'NVDisplay.Container', 'nvcontainer', 'NVIDIA Web Helper', 'igfxEM', 'igfxCUIService', 'IntelCpHDCPSvc', 'IntelCpHeciSvc',
    'powershell', 'pwsh', 'WindowsTerminal', 'OpenConsole', 'Taskmgr', 'RobloxPlayerBeta', 'RobloxCrashHandler'
)
# Aplicaciones de usuario conocidas que suelen consumir recursos en segundo plano.
$script:KnownBackgroundApps = @(
    'OneDrive', 'Teams', 'ms-teams', 'Discord', 'chrome', 'msedge', 'firefox', 'opera', 'brave', 'Spotify', 'steam', 'steamwebhelper',
    'EpicGamesLauncher', 'EpicWebHelper', 'Dropbox', 'GoogleDriveFS', 'Skype', 'Zoom', 'WhatsApp', 'Telegram', 'AdobeARM',
    'Creative Cloud', 'CCXProcess', 'AdobeIPCBroker', 'iCUE', 'RazerCentralService', 'PhoneExperienceHost', 'Widgets',
    'msedgewebview2', 'EADesktop', 'Origin', 'Battle.net', 'GalaxyClient', 'Overwolf', 'MicrosoftEdgeUpdate', 'GoogleUpdate',
    'NVIDIA Share', 'NVIDIA Overlay', 'uTorrent', 'qbittorrent', 'Lghub', 'Cortana', 'YourPhone'
)

function Get-ProcSnapshot {
    $h = @{}
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        $ms = $null
        try { $ms = $p.TotalProcessorTime.TotalMilliseconds } catch {}
        $h[$p.Id] = [pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; CpuMs = $ms; WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB); PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB) }
    }
    return $h
}

# Uso de CPU por proceso entre dos instantaneas, en % de la CPU completa.
function Get-ProcessUsage {
    param($Before, $After, [double]$Seconds, [int]$LogicalCpus)
    $rows = foreach ($id in $After.Keys) {
        $a = $After[$id]; $b = $Before[$id]
        $cpu = $null
        if ($b -and $null -ne $a.CpuMs -and $null -ne $b.CpuMs -and $Seconds -gt 0) {
            $cpu = [math]::Max(0, ($a.CpuMs - $b.CpuMs) / ($Seconds * 1000 * [math]::Max(1, $LogicalCpus)) * 100)
        }
        [pscustomobject]@{
            Id = $id; Name = $a.Name; CpuPct = $cpu; WorkingSetMB = $a.WorkingSetMB; PrivateMB = $a.PrivateMB
            Critical = ($script:CriticalProcs -contains $a.Name)
            KnownBackground = ($script:KnownBackgroundApps -contains $a.Name)
        }
    }
    return @($rows)
}

# Agrupa por nombre (chrome tiene decenas de procesos).
function Group-ProcessUsage {
    param([object[]]$Rows)
    $Rows | Where-Object { $_.Name -ne 'Idle' } | Group-Object Name | ForEach-Object {
        $cpu = ($_.Group | Where-Object { $null -ne $_.CpuPct } | Measure-Object CpuPct -Sum).Sum
        [pscustomobject]@{
            Name = $_.Name; Count = $_.Count; CpuPct = [math]::Round([double]$cpu, 1)
            WorkingSetMB = ($_.Group | Measure-Object WorkingSetMB -Sum).Sum
            PrivateMB = ($_.Group | Measure-Object PrivateMB -Sum).Sum
            Critical = $_.Group[0].Critical; KnownBackground = $_.Group[0].KnownBackground
        }
    }
}

# ------------------------------------------------------- Muestreo en vivo
function Get-ThreadTimes {
    param([int]$ProcId)
    $h = @{}
    try {
        $p = Get-Process -Id $ProcId -ErrorAction Stop
        foreach ($t in $p.Threads) { try { $h[$t.Id] = $t.TotalProcessorTime.TotalMilliseconds } catch {} }
    } catch {}
    return $h
}

# Estado persistente entre muestras (tiempos previos de CPU).
$script:SampleState = @{ PrevRoblox = @{}; PrevThreads = @{}; PrevTime = $null }

function Get-LiveSample {
    param([string]$NvSmi, [string[]]$NvFields, [int]$LogicalCpus, [double]$TotalRamMB)
    $now = Get-Date
    $s = [ordered]@{ Time = $now.ToString('HH:mm:ss') }

    # --- CPU (Processor Information: incluye rendimiento real y flags de limite)
    $pi = @(Get-Cim Win32_PerfFormattedData_Counters_ProcessorInformation)
    $tot = $pi | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    $cores = @($pi | Where-Object { $_.Name -match '^\d+,\d+$' })
    if ($tot) {
        $s.CpuTotal      = [double]$tot.PercentProcessorTime
        $s.CpuPerfPct    = [double]$tot.PercentProcessorPerformance    # 100 = frecuencia base; >100 = turbo
        $s.CpuMHz        = if ($tot.ProcessorFrequency) { [math]::Round($tot.ProcessorFrequency * $tot.PercentProcessorPerformance / 100) } else { $null }
        $s.CpuLimitFlags = [double]$tot.PerformanceLimitFlags
    }
    if ($cores.Count -gt 0) {
        $vals = @($cores | Sort-Object { [int](($_.Name -split ',')[1]) } | ForEach-Object { [double]$_.PercentProcessorTime })
        $s.CpuCoreMax = ($vals | Measure-Object -Maximum).Maximum
        $s.CpuCores = ($vals | ForEach-Object { [math]::Round($_) }) -join '|'
    }

    # --- Memoria
    $mem = Get-Cim Win32_PerfFormattedData_PerfOS_Memory | Select-Object -First 1
    if ($mem) {
        $s.RamAvailMB = [double]$mem.AvailableMBytes
        if ($TotalRamMB -gt 0) { $s.RamUsedPct = [math]::Round(100 * (1 - $mem.AvailableMBytes / $TotalRamMB), 1) }
        if ($mem.CommitLimit -gt 0) { $s.CommitPct = [math]::Round(100 * $mem.CommittedBytes / $mem.CommitLimit, 1) }
        $s.PageReadsPerSec = [double]$mem.PageReadsPersec
    }

    # --- Zonas termicas ACPI (aprox. CPU/placa; Kelvin -> Celsius)
    $tz = @(Get-Cim Win32_PerfFormattedData_Counters_ThermalZoneInformation)
    if ($tz.Count -gt 0) {
        $temps = @($tz | Where-Object { $_.Temperature -gt 200 } | ForEach-Object { $_.Temperature - 273.15 })
        if ($temps.Count) { $s.ThermalZoneC = [math]::Round(($temps | Measure-Object -Maximum).Maximum, 1) }
        $s.PassiveLimitPct = ($tz | Measure-Object PercentPassiveLimit -Minimum).Minimum
    }

    # --- Bateria / cargador
    $bat = Get-Cim Win32_Battery | Select-Object -First 1
    $s.OnBattery = if ($bat) { $bat.BatteryStatus -eq 1 } else { $false }

    # --- GPU via nvidia-smi
    if ($NvSmi -and $NvFields.Count) {
        $nv = Invoke-NvQuery -Exe $NvSmi -Fields $NvFields
        if ($nv) {
            $s.GpuUtil        = $nv['utilization.gpu']
            $s.GpuMemCtrlUtil = $nv['utilization.memory']
            $s.GpuTempC       = $nv['temperature.gpu']
            $s.GpuClockMHz    = $nv['clocks.graphics']
            $s.GpuMemClockMHz = $nv['clocks.memory']
            $s.VramUsedMB     = $nv['memory.used']
            $s.VramTotalMB    = $nv['memory.total']
            $s.GpuPState      = $nv['pstate']
            $s.GpuPowerW      = $nv['power.draw']
            $thr = $nv['clocks_event_reasons.active']
            if ($null -eq $thr) { $thr = $nv['clocks_throttle_reasons.active'] }
            $s.GpuThrottleMask = ConvertTo-NvBitmask $thr
        }
    }

    # --- Motores GPU de Windows (identifica que GPU usa cada proceso)
    $robloxIds = @(Get-RobloxProcesses | ForEach-Object { $_.Id })
    $s.RobloxRunning = $robloxIds.Count -gt 0
    $eng = @(Get-Cim Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine)
    if ($eng.Count -gt 0) {
        $parsed = foreach ($e in $eng) {
            if ($e.Name -match 'pid_(\d+)_luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)_phys_(\d+)_eng_(\d+)_engtype_(.*)$') {
                [pscustomobject]@{ Pid = [int]$Matches[1]; Luid = $Matches[2]; Eng = "$($Matches[3])_$($Matches[4])"; Type = $Matches[5]; Util = [double]$e.UtilizationPercentage }
            }
        }
        $parsed = @($parsed)
        # La NVIDIA expone motores propios (Cuda, VR, Graphics_1) que Intel/AMD no tienen.
        $nvLuids = @($parsed | Where-Object { $_.Type -match '^(Cuda|VR|Graphics_1)$' } | Select-Object -ExpandProperty Luid -Unique)
        $script:SampleState.NvLuids = @(@($script:SampleState.NvLuids) + $nvLuids | Where-Object { $_ } | Select-Object -Unique)
        $known = $script:SampleState.NvLuids
        # Uso 3D por adaptador (maximo entre motores, sumando procesos)
        $byEngine = $parsed | Group-Object Luid, Eng | ForEach-Object {
            [pscustomobject]@{ Luid = $_.Group[0].Luid; Util = ($_.Group | Measure-Object Util -Sum).Sum }
        }
        $nvEng = @($byEngine | Where-Object { $known -contains $_.Luid })
        if ($nvEng.Count) { $s.GpuUtilWin = [math]::Min(100, ($nvEng | Measure-Object Util -Maximum).Maximum) }
        $igEng = @($byEngine | Where-Object { $known -notcontains $_.Luid })
        if ($igEng.Count) { $s.IgpuUtilWin = [math]::Min(100, ($igEng | Measure-Object Util -Maximum).Maximum) }
        if ($robloxIds.Count) {
            $rb = @($parsed | Where-Object { $robloxIds -contains $_.Pid })
            $s.RobloxGpuNvidia = [math]::Round((@($rb | Where-Object { $known -contains $_.Luid }) | Measure-Object Util -Sum).Sum, 1)
            $s.RobloxGpuOther  = [math]::Round((@($rb | Where-Object { $known -notcontains $_.Luid }) | Measure-Object Util -Sum).Sum, 1)
            $s.RobloxHasNvContext = @($rb | Where-Object { $known -contains $_.Luid }).Count -gt 0
        }
    }
    if ($null -eq $s.GpuUtil -and $null -ne $s.GpuUtilWin) { $s.GpuUtil = $s.GpuUtilWin }

    # --- Roblox: CPU del proceso y del hilo mas cargado
    $elapsed = if ($script:SampleState.PrevTime) { ($now - $script:SampleState.PrevTime).TotalSeconds } else { 0 }
    $newRb = @{}; $newTh = @{}
    $rbCpu = 0.0; $topThread = $null
    foreach ($id in $robloxIds) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            $ms = $p.TotalProcessorTime.TotalMilliseconds
            $newRb[$id] = $ms
            if ($elapsed -gt 0 -and $script:SampleState.PrevRoblox.ContainsKey($id)) {
                $rbCpu += ($ms - $script:SampleState.PrevRoblox[$id]) / ($elapsed * 1000 * [math]::Max(1, $LogicalCpus)) * 100
            }
            $s.RobloxWorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB)
            $s.RobloxPriority = "$($p.PriorityClass)"
        } catch {}
        $th = Get-ThreadTimes -ProcId $id
        foreach ($k in $th.Keys) {
            $key = "$id-$k"; $newTh[$key] = $th[$k]
            if ($elapsed -gt 0 -and $script:SampleState.PrevThreads.ContainsKey($key)) {
                $pct = ($th[$k] - $script:SampleState.PrevThreads[$key]) / ($elapsed * 1000) * 100
                if ($null -eq $topThread -or $pct -gt $topThread) { $topThread = $pct }
            }
        }
    }
    if ($elapsed -gt 0 -and $robloxIds.Count) {
        $s.RobloxCpuPct = [math]::Round($rbCpu, 1)
        if ($null -ne $topThread) { $s.RobloxTopThreadPct = [math]::Round([math]::Min(100, $topThread), 1) }
    }
    $script:SampleState.PrevRoblox = $newRb
    $script:SampleState.PrevThreads = $newTh
    $script:SampleState.PrevTime = $now
    return [pscustomobject]$s
}

# ------------------------------------------------------------- PresentMon
function Find-PresentMon {
    param([string]$ToolsDir)
    $f = Get-ChildItem $ToolsDir -Filter 'PresentMon*.exe' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

# Descarga PresentMon (herramienta oficial de Intel, codigo abierto) desde su
# pagina oficial de GitHub. Solo se llama si el usuario lo acepta.
function Install-PresentMon {
    param([string]$ToolsDir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/GameTechDev/PresentMon/releases/latest' -Headers @{ 'User-Agent' = 'GpuBooster920MX' } -ErrorAction Stop
    $asset = $rel.assets | Where-Object { $_.name -match '^PresentMon-[\d\.]+-x64\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw "No se encontro el ejecutable de consola en la version $($rel.tag_name)" }
    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }
    $dest = Join-Path $ToolsDir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    $sig = Get-AuthenticodeSignature $dest
    if ($sig.Status -ne 'Valid') {
        Remove-Item $dest -Force
        throw "La firma digital de PresentMon no es valida ($($sig.Status)); se ha borrado el archivo."
    }
    return $dest
}

function Start-PresentMonCapture {
    param([string]$Exe, [string]$CsvPath, [int]$Seconds)
    $pmArgs = @('--process_name', 'RobloxPlayerBeta.exe', '--output_file', "`"$CsvPath`"", '--timed', "$Seconds",
              '--terminate_after_timed', '--stop_existing_session', '--no_console_stats', '--session_name', 'GpuBooster920MX')
    return Start-Process -FilePath $Exe -ArgumentList $pmArgs -WindowStyle Hidden -PassThru
}

function Read-PresentMonCsv {
    param([string]$CsvPath)
    if (-not (Test-Path $CsvPath)) { return $null }
    $rows = @(Import-Csv $CsvPath)
    if ($rows.Count -eq 0) { return $null }
    $cols = $rows[0].PSObject.Properties.Name
    $ftCol = @('FrameTime', 'MsBetweenPresents', 'MsBetweenAppStart') | Where-Object { $cols -contains $_ } | Select-Object -First 1
    $gbCol = @('GPUBusy', 'MsGPUBusy', 'MsGPUActive') | Where-Object { $cols -contains $_ } | Select-Object -First 1
    $cbCol = @('CPUBusy', 'MsCPUBusy') | Where-Object { $cols -contains $_ } | Select-Object -First 1
    if (-not $ftCol) { return $null }
    # Si hay varias cadenas de presentacion, se usa la que mas fotogramas tiene (la del juego).
    $main = $rows | Group-Object SwapChainAddress | Sort-Object Count -Descending | Select-Object -First 1
    $use = if ($main -and $main.Name) { $main.Group } else { $rows }
    $ft = New-Object System.Collections.Generic.List[double]
    $gb = New-Object System.Collections.Generic.List[double]
    foreach ($r in $use) {
        $v = ConvertTo-Num $r.$ftCol
        if ($v -is [double]) {
            $ft.Add($v)
            if ($gbCol) { $g = ConvertTo-Num $r.$gbCol; $gb.Add($(if ($g -is [double]) { $g } else { -1 })) }
        }
    }
    return [pscustomobject]@{
        FrameTimes = $ft.ToArray(); GpuBusy = $(if ($gbCol) { $gb.ToArray() } else { $null })
        Columns = "$ftCol / $gbCol / $cbCol"; Runtime = ($use | Select-Object -First 1).PresentRuntime
        PresentMode = ($use | Group-Object PresentMode | Sort-Object Count -Descending | Select-Object -First 1).Name
    }
}
