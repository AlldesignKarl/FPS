# GPU BOOSTER 920MX

Herramienta personal para sacar el máximo rendimiento **real** de un portátil con
NVIDIA GeForce 920MX en Roblox (prueba principal: *Emergency Response: Liberty County*).

Sin placebo: cada optimización se basa en una medición y tiene una explicación técnica.
Si algo no es posible en este hardware, se marca **NO DISPONIBLE**; si no mejora el
rendimiento, no se aplica.

## Estado: FASE 1 — Diagnóstico (solo lectura)

La fase 1 **no modifica nada** en el ordenador. Solo mide y propone.

### Cómo usarlo (una sola línea)

1. Pulsa **tecla Windows + R**, escribe `powershell` y pulsa Enter.
2. Pega esta línea y pulsa Enter:

   ```powershell
   irm https://raw.githubusercontent.com/AlldesignKarl/FPS/refs/heads/claude/magical-hopper-b7gkdd/instalar.ps1 | iex
   ```
3. Cuando Windows pregunte si permites cambios, pulsa **Sí** (solo se usa para medir FPS).
4. Conecta el cargador, abre Roblox → ERLC y juega normal. La medición empieza sola
   y al acabar suenan dos pitidos.
5. El informe queda **copiado automáticamente**: pégalo en el chat con Ctrl+V.

El programa se instala en `%LOCALAPPDATA%\GpuBooster920MX`. Alternativa sin PowerShell:
descargar el ZIP de la rama y ejecutar `EJECUTAR_DIAGNOSTICO.bat`.

Los resultados se guardan en `reports\diagnostico_FECHA\`:

| Archivo | Contenido |
|---|---|
| `informe.txt` | Respuestas a las 10 preguntas, cuello de botella, optimizaciones propuestas |
| `muestras.csv` | Todas las muestras (CPU por núcleo, GPU, temperaturas, frecuencias, RAM, VRAM) |
| `presentmon.csv` | Fotogramas reales capturados (si PresentMon está disponible) |
| `nvidia-smi-q.txt` | Volcado completo del driver NVIDIA (relojes, energía, temperaturas) |
| `diagnostico.json` | Todo lo anterior en formato estructurado |

### Qué mide y cómo

| Dato | Fuente |
|---|---|
| GPU NVIDIA: modelo, driver, uso, relojes, VRAM, temperatura, P-state, motivos de throttling | `nvidia-smi` (incluido con el driver) |
| Qué GPU usa Roblox | Contadores *GPU Engine* de Windows por proceso (la NVIDIA se identifica por sus motores Cuda/VR) + tabla de procesos de `nvidia-smi` |
| CPU: modelo, núcleos, uso total y por hilo, frecuencia real, límites de rendimiento | WMI `Processor Information` (incluye `% Processor Performance` y `Performance Limit Flags`) |
| Hilo principal de Roblox | Tiempo de CPU por hilo del proceso (lo mismo que muestra Process Explorer) |
| Temperatura CPU | Zona térmica ACPI (aproximada: Windows no expone el sensor de cada núcleo sin driver) |
| RAM, memoria comprometida, paginación | WMI `PerfOS_Memory`, `Win32_PhysicalMemory` (módulos, canal) |
| FPS, frame time, % del fotograma que la GPU está ocupada | PresentMon (ETW, no toca Roblox) |
| Energía | `powercfg` (consulta), modo de energía, batería |
| Ajustes gráficos de Windows / Roblox | Registro (lectura) y archivo de ajustes de Roblox (lectura) |

Se usan clases WMI en lugar de `Get-Counter` porque sus nombres no cambian con el idioma de Windows.

### Cómo se decide el cuello de botella

Se analizan juntos FPS, frame time, uso de GPU, CPU total, CPU por hilo, hilo principal de
Roblox, frecuencias, temperaturas, RAM y VRAM:

- **GPU**: GPU ocupada ≥90 % de cada fotograma (PresentMon) o uso mediano ≥92 %.
- **CPU**: la GPU está ociosa gran parte del fotograma, o el hilo principal de Roblox / un hilo lógico está saturado mientras la GPU tiene margen.
- **THERMAL**: motivos de ralentización térmica de NVIDIA, límite térmico pasivo de Windows, o CPU por debajo de su frecuencia base con carga y temperatura alta.
- **POWER**: batería, límite de energía de la GPU, estado máximo del procesador < 100 %.
- **RAM**: poca RAM disponible, memoria comprometida alta o paginación sostenida.
- **OTRO**: Roblox en la GPU integrada, o FPS clavados en un límite (60 FPS / VSync).

Si los FPS están clavados en un límite, la proporción GPU/fotograma no se usa (ambos
esperan al límite y la conclusión sería falsa).

## Garantías de seguridad (todas las fases)

- Antes de cualquier cambio se guarda el valor original; habrá **RESTAURAR TODO**.
- Nada irreversible. Sin BIOS, firmware, voltajes ni drivers modificados.
- No se desactiva Windows Defender ni ninguna protección.
- No se cierran procesos de Windows, seguridad, audio o drivers.
- No se modifica Roblox, sus archivos ni su memoria. Sin exploits ni trampas.

## Hoja de ruta

| Fase | Contenido | Estado |
|---|---|---|
| 1 | Diagnóstico | ✅ lista para ejecutar |
| 2 | Monitorización en tiempo real | pendiente |
| 3 | Benchmark antes/después | pendiente |
| 4 | Optimizaciones seguras Windows/NVIDIA | pendiente (tras revisar el diagnóstico) |
| 5 | CPU Boost | pendiente |
| 6 | GPU Boost | pendiente |
| 7 | Roblox Boost + Auto Boost | pendiente |
| 8 | Sistema térmico | pendiente |
| 9 | Overclock experimental (solo si es compatible) | pendiente |
| 10 | Interfaz final | pendiente |

## Pruebas

```powershell
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

Prueban el análisis con escenarios sintéticos (CPU, GPU, térmico, batería, GPU integrada,
RAM, límite de 60 FPS) y la generación del informe.
