#!/bin/bash

# =================================================================
# Script de Pruebas de Rendimiento NATS
# =================================================================
# Uso: ./run_test.sh [duración] [tasa_mensajes]
# Ejemplo: ./run_test.sh 300 1000
#   - duración: tiempo en segundos (default: 300)
#   - tasa_mensajes: mensajes por segundo (default: 1000)
# =================================================================

# Detección de entorno y configuración de colores
detect_terminal_background() {
    if [ -t 1 ]; then
        if echo -e "\033]11;?\007" > /dev/tty; then
            read -t 0.1 -s -d $'\007' response < /dev/tty
            if [[ $response == *"rgb:"* ]]; then
                local rgb=${response#*rgb:}
                local r=$((16#${rgb:0:2}))
                local g=$((16#${rgb:4:2}))
                local b=$((16#${rgb:8:2}))
                local brightness=$(( (r + g + b) / 3 ))
                
                if [ $brightness -gt 127 ]; then
                    return 0  # Fondo claro
                else
                    return 1  # Fondo oscuro
                fi
            fi
        fi
    fi
    return 1  # Default a fondo oscuro si falla la detección
}

# Configurar colores basados en el fondo del terminal
if detect_terminal_background; then
    # Colores para fondo claro
    VERDE='\033[0;32m'      # Verde oscuro
    ROJO='\033[0;31m'       # Rojo oscuro
    AZUL='\033[0;34m'       # Azul oscuro
    AMARILLO='\033[0;33m'   # Amarillo oscuro
else
    # Colores para fondo oscuro
    VERDE='\033[1;92m'      # Verde brillante
    ROJO='\033[1;91m'       # Rojo brillante
    AZUL='\033[1;94m'       # Azul brillante
    AMARILLO='\033[1;93m'   # Amarillo brillante
fi
NC='\033[0m'  # Sin Color

# Umbrales de rendimiento NATS
readonly UMBRAL_LATENCIA_ADVERTENCIA=1000    # 1ms
readonly UMBRAL_LATENCIA_CRITICO=5000        # 5ms
readonly UMBRAL_TASA_MENSAJES_MIN=100        # mensajes/segundo mínimo
readonly UMBRAL_ERROR_PORCENTAJE=1           # 1% de errores máximo
readonly UMBRAL_MEMORIA_MB=500               # 500MB de uso de memoria máximo
readonly UMBRAL_CPU_PORCENTAJE=80            # 80% de uso de CPU máximo

# Valores por defecto
DURACION=${1:-300}     # Duración de la prueba en segundos
TASA=${2:-1000}        # Mensajes por segundo
DIRECTORIO_SALIDA="resultados_prueba_$(date +%Y%m%d_%H%M%S)"

# Verificar si estamos en Docker Desktop o Docker nativo
check_docker_environment() {
    if [ -f "/proc/version" ] && grep -qi microsoft "/proc/version"; then
        echo "wsl"
    elif [ "$(uname)" == "Darwin" ]; then
        echo "mac"
    else
        echo "linux"
    fi
}

DOCKER_ENV=$(check_docker_environment)

# Ajustar comandos según el entorno
case $DOCKER_ENV in
    "wsl"|"mac")
        OPEN_CMD="xdg-open"
        [ "$(uname)" == "Darwin" ] && OPEN_CMD="open"
        DOCKER_STATUS_CMD="docker info >/dev/null 2>&1"
        ;;
    "linux")
        OPEN_CMD="xdg-open"
        DOCKER_STATUS_CMD="systemctl is-active --quiet docker"
        ;;
esac
# Funciones de utilidad y verificación

# Función para imprimir mensajes con formato
imprimir() {
    local tipo=$1
    local mensaje=$2
    case $tipo in
        "info")    echo -e "${AZUL}ℹ${NC} $mensaje" ;;
        "exito")   echo -e "${VERDE}✓${NC} $mensaje" ;;
        "error")   echo -e "${ROJO}✗${NC} $mensaje" ;;
        "aviso")   echo -e "${AMARILLO}⚠${NC} $mensaje" ;;
        "titulo")  
            echo -e "\n${AZUL}======================================${NC}"
            echo -e "${AZUL}$mensaje${NC}"
            echo -e "${AZUL}======================================${NC}"
            ;;
    esac
}

# Función para verificar requisitos del sistema
verificar_requisitos() {
    local errores=0

    # Verificar Docker
    if ! eval $DOCKER_STATUS_CMD; then
        imprimir "error" "Docker no está en ejecución"
        errores=$((errores + 1))
    else
        imprimir "exito" "Docker está en ejecución"
    fi

    # Verificar Docker Compose
    if ! command -v docker-compose >/dev/null 2>&1; then
        imprimir "error" "Docker Compose no está instalado"
        errores=$((errores + 1))
    else
        imprimir "exito" "Docker Compose está instalado"
    fi

    # Verificar curl (necesario para las métricas)
    if ! command -v curl >/dev/null 2>&1; then
        imprimir "error" "curl no está instalado"
        errores=$((errores + 1))
    else
        imprimir "exito" "curl está instalado"
    fi

    # Verificar jq (necesario para procesar JSON)
    if ! command -v jq >/dev/null 2>&1; then
        imprimir "aviso" "jq no está instalado - algunas funciones de métricas estarán limitadas"
    else
        imprimir "exito" "jq está instalado"
    fi

    # Verificar bc (necesario para cálculos)
    if ! command -v bc >/dev/null 2>&1; then
        imprimir "error" "bc no está instalado"
        errores=$((errores + 1))
    else
        imprimir "exito" "bc está instalado"
    fi


    return $errores
}

# Función para verificar puertos disponibles
verificar_puertos() {
    local puertos=("4222:NATS" "8222:NATS HTTP" "9090:Prometheus" "3000:Grafana")
    local errores=0

    for puerto_info in "${puertos[@]}"; do
        puerto="${puerto_info%%:*}"
        servicio="${puerto_info#*:}"
        
        if lsof -Pi ":$puerto" -sTCP:LISTEN -t >/dev/null 2>&1; then
            imprimir "error" "Puerto $puerto ($servicio) está en uso"
            errores=$((errores + 1))
        else
            imprimir "exito" "Puerto $puerto ($servicio) está disponible"
        fi
    done

    return $errores
}

# Función para verificar servicios en ejecución
verificar_servicio() {
    local url=$1
    local servicio=$2
    local max_intentos=5
    local intento=1

    while [ $intento -le $max_intentos ]; do
        if curl -s -f "$url" >/dev/null 2>&1; then
            imprimir "exito" "$servicio está respondiendo"
            return 0
        fi
        if [ $intento -lt $max_intentos ]; then
            imprimir "aviso" "Esperando que $servicio responda (intento $intento de $max_intentos)..."
            sleep 2
        fi
        ((intento++))
    done
    
    imprimir "error" "$servicio no está respondiendo después de $max_intentos intentos"
    return 1
}

# Función para validar valores de entrada
validar_parametros() {
    if ! [[ $DURACION =~ ^[0-9]+$ ]]; then
        imprimir "error" "La duración debe ser un número entero positivo"
        return 1
    fi

    if ! [[ $TASA =~ ^[0-9]+$ ]]; then
        imprimir "error" "La tasa de mensajes debe ser un número entero positivo"
        return 1
    fi

    if [ $DURACION -lt 10 ]; then
        imprimir "error" "La duración mínima es de 10 segundos"
        return 1
    fi

    if [ $TASA -lt $UMBRAL_TASA_MENSAJES_MIN ]; then
        imprimir "error" "La tasa mínima es de $UMBRAL_TASA_MENSAJES_MIN mensajes por segundo"
        return 1
    fi

    return 0
}
# Funciones para recolección y procesamiento de métricas

# Función para obtener métricas de Prometheus
obtener_metrica_prometheus() {
    local query=$1
    local tiempo_fin=$(date +%s)
    local resultado

    resultado=$(curl -s -G --data-urlencode "query=$query" --data-urlencode "time=$tiempo_fin" http://localhost:9090/api/v1/query)
    
    if [ $? -eq 0 ] && command -v jq >/dev/null 2>&1; then
        echo "$resultado" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# Función para recolectar todas las métricas
recolectar_metricas() {
    local dir_salida=$1
    local es_final=${2:-false}  # true si es la recolección final
    local timestamp=$(date +%s)
    
    # Métricas instantáneas
    local tasa_pub=$(obtener_metrica_prometheus 'rate(nats_messages_sent_total[1m])')
    local tasa_sub=$(obtener_metrica_prometheus 'rate(nats_messages_received_total[1m])')
    local latencia=$(obtener_metrica_prometheus 'rate(nats_end_to_end_latency_microseconds_sum[1m])/rate(nats_end_to_end_latency_microseconds_count[1m])')
    local latencia_p95=$(obtener_metrica_prometheus 'histogram_quantile(0.95,rate(nats_end_to_end_latency_microseconds_bucket[1m]))')
    local latencia_p99=$(obtener_metrica_prometheus 'histogram_quantile(0.99,rate(nats_end_to_end_latency_microseconds_bucket[1m]))')
    local throughput_env=$(obtener_metrica_prometheus 'rate(nats_bytes_sent_total[1m])')
    local throughput_rec=$(obtener_metrica_prometheus 'rate(nats_bytes_received_total[1m])')
    
    # Guardar datos para gráficos
    echo "$timestamp $tasa_pub" >> "$dir_salida/datos_tasa_pub.txt"
    echo "$timestamp $tasa_sub" >> "$dir_salida/datos_tasa_sub.txt"
    echo "$timestamp $latencia" >> "$dir_salida/latencia_promedio.txt"
    echo "$timestamp $latencia_p95" >> "$dir_salida/latencia_p95.txt"
    echo "$timestamp $latencia_p99" >> "$dir_salida/latencia_p99.txt"
    echo "$timestamp $throughput_env" >> "$dir_salida/throughput_enviado.txt"
    echo "$timestamp $throughput_rec" >> "$dir_salida/throughput_recibido.txt"

    # Si es la recolección final, generar el informe
    if [ "$es_final" = true ]; then
        # Métricas totales
        local total_mensajes_env=$(obtener_metrica_prometheus 'nats_messages_sent_total')
        local total_mensajes_rec=$(obtener_metrica_prometheus 'nats_messages_received_total')
        local total_bytes_env=$(obtener_metrica_prometheus 'nats_bytes_sent_total')
        local total_errores=$(obtener_metrica_prometheus 'nats_publish_errors_total')
        
        # Generar informe final
        {
            echo "INFORME DE PRUEBA DE RENDIMIENTO NATS"
            echo "====================================="
            echo ""
            echo "Parámetros de la Prueba"
            echo "----------------------"
            echo "Duración: $DURACION segundos"
            echo "Tasa objetivo: $TASA mensajes/segundo"
            echo ""
            echo "Resultados Finales"
            echo "-----------------"
            echo "Total mensajes enviados: $total_mensajes_env"
            echo "Total mensajes recibidos: $total_mensajes_rec"
            echo "Total bytes transferidos: $total_bytes_env"
            echo "Total errores: $total_errores"
            echo ""
            echo "Métricas de Rendimiento"
            echo "----------------------"
            echo "Tasa de mensajes promedio: $tasa_pub msg/s"
            echo "Latencia promedio: $latencia µs"
            echo "Latencia P95: $latencia_p95 µs"
            echo "Latencia P99: $latencia_p99 µs"
            echo "Throughput promedio: $throughput_env B/s"
            echo ""
            echo "Estado del Sistema"
            echo "-----------------"
            echo "Fecha de inicio: $(date -d @$TIEMPO_INICIO '+%Y-%m-%d %H:%M:%S')"
            echo "Fecha de fin: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Directorio de resultados: $dir_salida"
        } > "$dir_salida/informe_final.txt"

        # Verificar umbrales y mostrar advertencias
        if [ "$latencia" != "N/A" ]; then
            if [ "$(echo "$latencia > $UMBRAL_LATENCIA_CRITICO" | bc -l)" -eq 1 ]; then
                imprimir "error" "Latencia crítica detectada: ${latencia}µs"
            elif [ "$(echo "$latencia > $UMBRAL_LATENCIA_ADVERTENCIA" | bc -l)" -eq 1 ]; then
                imprimir "aviso" "Latencia elevada detectada: ${latencia}µs"
            fi
        fi

        # Verificar tasa de errores
        if [ "$total_errores" != "N/A" ] && [ "$(echo "$total_errores > $UMBRAL_ERROR_PORCENTAJE" | bc -l)" -eq 1 ]; then
            imprimir "error" "Tasa de errores elevada: ${total_errores}%"
        fi
    fi
}




# Funciones para generación de visualizaciones y dashboard

# Función para generar gráficos con gnuplot
# Función para generar gráficos con gnuplot
generar_graficos() {
    local dir=$1
    local dir_datos="$dir/datos"
    local dir_graficos="$dir/graficos"
    
    if ! command -v gnuplot >/dev/null 2>&1; then
        imprimir "aviso" "gnuplot no está instalado - no se generarán gráficos"
        return 1
    }

    # Crear directorio de gráficos si no existe
    mkdir -p "$dir_graficos"

    imprimir "info" "Generando gráficos de rendimiento..."

    # Configuración común de gnuplot
    local config_comun=$(cat << 'EOF'
set grid
set style line 1 lc rgb '#2196F3' lw 2 pt 7 ps 0.5  # Azul Material Design
set style line 2 lc rgb '#4CAF50' lw 2 pt 7 ps 0.5  # Verde Material Design
set style line 3 lc rgb '#FFC107' lw 2 pt 7 ps 0.5  # Amarillo Material Design
set style line 4 lc rgb '#F44336' lw 2 pt 7 ps 0.5  # Rojo Material Design
set style line 5 lc rgb '#9C27B0' lw 2 pt 7 ps 0.5  # Púrpura Material Design

# Estilo del grid
set grid linecolor rgb '#E0E0E0'

# Formato de los ejes
set xtics font 'Arial,9'
set ytics font 'Arial,9'

# Estilo de la leyenda
set key font 'Arial,9'
set key box linecolor rgb '#BDBDBD'
set key spacing 1.5
EOF
)

    # 1. Gráfico de Tasa de Mensajes
    imprimir "info" "Generando gráfico de tasa de mensajes..."
    cat << EOF > "$dir_graficos/plot_mensajes.gnu"
$config_comun
set terminal png size 1000,600 enhanced font 'Arial,10'
set output '$dir_graficos/tasa_mensajes.png'
set title 'Tasa de Mensajes NATS' font 'Arial,12'
set xlabel 'Tiempo transcurrido (segundos)' font 'Arial,10'
set ylabel 'Mensajes por segundo' font 'Arial,10'
set key top right

# Calcular tiempo relativo desde el inicio
stats '$dir_datos/datos_tasa_pub.txt' using 1 nooutput
inicio = STATS_min

plot '$dir_datos/datos_tasa_pub.txt' using (\$1-inicio):2 with lines ls 1 title 'Publicador', \
     '$dir_datos/datos_tasa_sub.txt' using (\$1-inicio):2 with lines ls 2 title 'Suscriptor'
EOF

    # 2. Gráfico de Latencia
    imprimir "info" "Generando gráfico de latencia..."
    cat << EOF > "$dir_graficos/plot_latencia.gnu"
$config_comun
set terminal png size 1000,600 enhanced font 'Arial,10'
set output '$dir_graficos/latencia.png'
set title 'Latencia de Mensajes' font 'Arial,12'
set xlabel 'Tiempo transcurrido (segundos)' font 'Arial,10'
set ylabel 'Latencia (µs)' font 'Arial,10'
set key top right

# Calcular tiempo relativo desde el inicio
stats '$dir_datos/latencia_promedio.txt' using 1 nooutput
inicio = STATS_min

# Agregar líneas de umbral
set arrow from graph 0,first $UMBRAL_LATENCIA_ADVERTENCIA to graph 1,first $UMBRAL_LATENCIA_ADVERTENCIA \
    nohead lt 0 lc rgb '#FFA726' lw 1 dt 2
set arrow from graph 0,first $UMBRAL_LATENCIA_CRITICO to graph 1,first $UMBRAL_LATENCIA_CRITICO \
    nohead lt 0 lc rgb '#EF5350' lw 1 dt 2

plot '$dir_datos/latencia_promedio.txt' using (\$1-inicio):2 with lines ls 1 title 'Promedio', \
     '$dir_datos/latencia_p95.txt' using (\$1-inicio):2 with lines ls 4 title 'P95', \
     '$dir_datos/latencia_p99.txt' using (\$1-inicio):2 with lines ls 5 title 'P99'
EOF

    # 3. Gráfico de Throughput
    imprimir "info" "Generando gráfico de throughput..."
    cat << EOF > "$dir_graficos/plot_throughput.gnu"
$config_comun
set terminal png size 1000,600 enhanced font 'Arial,10'
set output '$dir_graficos/throughput.png'
set title 'Throughput de Datos' font 'Arial,12'
set xlabel 'Tiempo transcurrido (segundos)' font 'Arial,10'
set ylabel 'MB/s' font 'Arial,10'
set key top right

# Calcular tiempo relativo desde el inicio
stats '$dir_datos/throughput_enviado.txt' using 1 nooutput
inicio = STATS_min

# Convertir bytes/s a MB/s
plot '$dir_datos/throughput_enviado.txt' using (\$1-inicio):(\$2/1048576) with lines ls 1 title 'Enviado', \
     '$dir_datos/throughput_recibido.txt' using (\$1-inicio):(\$2/1048576) with lines ls 2 title 'Recibido'
EOF

    # 4. Gráfico Combinado (Vista General)
    imprimir "info" "Generando gráfico de vista general..."
    cat << EOF > "$dir_graficos/plot_resumen.gnu"
$config_comun
set terminal png size 1200,800 enhanced font 'Arial,10'
set output '$dir_graficos/resumen.png'
set title 'Resumen de Rendimiento NATS' font 'Arial,14'
set multiplot layout 2,2 margins 0.1,0.95,0.1,0.95 spacing 0.1

# Calcular tiempo relativo desde el inicio
stats '$dir_datos/datos_tasa_pub.txt' using 1 nooutput
inicio = STATS_min

# Panel 1: Tasa de Mensajes
set size 0.5,0.5
set origin 0.0,0.5
set title 'Tasa de Mensajes' font 'Arial,10'
set xlabel 'Tiempo (s)' font 'Arial,9'
set ylabel 'Mensajes/s' font 'Arial,9'
plot '$dir_datos/datos_tasa_pub.txt' using (\$1-inicio):2 with lines ls 1 title 'Pub', \
     '$dir_datos/datos_tasa_sub.txt' using (\$1-inicio):2 with lines ls 2 title 'Sub'

# Panel 2: Latencia
set origin 0.5,0.5
set title 'Latencia' font 'Arial,10'
set xlabel 'Tiempo (s)' font 'Arial,9'
set ylabel 'µs' font 'Arial,9'
plot '$dir_datos/latencia_promedio.txt' using (\$1-inicio):2 with lines ls 1 title 'Avg', \
     '$dir_datos/latencia_p95.txt' using (\$1-inicio):2 with lines ls 4 title 'P95'

# Panel 3: Throughput
set origin 0.0,0.0
set title 'Throughput' font 'Arial,10'
set xlabel 'Tiempo (s)' font 'Arial,9'
set ylabel 'MB/s' font 'Arial,9'
plot '$dir_datos/throughput_enviado.txt' using (\$1-inicio):(\$2/1048576) with lines ls 1 title 'TX', \
     '$dir_datos/throughput_recibido.txt' using (\$1-inicio):(\$2/1048576) with lines ls 2 title 'RX'

# Panel 4: Métricas Adicionales (ejemplo con P99)
set origin 0.5,0.0
set title 'Latencia P99' font 'Arial,10'
set xlabel 'Tiempo (s)' font 'Arial,9'
set ylabel 'µs' font 'Arial,9'
plot '$dir_datos/latencia_p99.txt' using (\$1-inicio):2 with lines ls 5 title 'P99'

unset multiplot
EOF

    # Ejecutar todos los scripts de gnuplot
    local errores=0
    for script in "$dir_graficos"/plot_*.gnu; do
        if ! gnuplot "$script" 2>/dev/null; then
            imprimir "error" "Error al generar gráfico: $(basename "$script")"
            errores=$((errores + 1))
        fi
    done

    if [ $errores -eq 0 ]; then
        imprimir "exito" "Gráficos generados exitosamente en $dir_graficos"
        # Copiar los gráficos al directorio raíz para el dashboard
        cp "$dir_graficos"/*.png "$dir/"
        return 0
    else
        imprimir "error" "Se encontraron errores al generar los gráficos"
        return 1
    fi
}


# Función para generar el dashboard HTML
generar_dashboard() {
    local dir=$1
    local titulo="Dashboard de Rendimiento NATS - $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Obtener valores para el resumen
    local tasa_mensajes=$(cat "$dir/tasa_mensajes_1min.txt")
    local latencia=$(cat "$dir/latencia_promedio.txt")
    local throughput=$(cat "$dir/tasa_bytes.txt")
    
    # Crear el dashboard HTML
    cat << EOF > "$dir/dashboard.html"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$titulo</title>
    <style>
        body {
            font-family: 'Segoe UI', Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
            color: #333;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background-color: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .header {
            text-align: center;
            margin-bottom: 30px;
            padding-bottom: 20px;
            border-bottom: 2px solid #eee;
        }
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .metric-card {
            background: #fff;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
            border: 1px solid #eee;
        }
        .metric-title {
            font-size: 0.9em;
            color: #666;
            margin-bottom: 10px;
        }
        .metric-value {
            font-size: 24px;
            font-weight: bold;
            color: #2196F3;
        }
        .graph-container {
            margin: 20px 0;
            padding: 20px;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
        }
        .graph-title {
            font-size: 1.2em;
            margin-bottom: 15px;
            color: #333;
        }
        .graph-img {
            width: 100%;
            height: auto;
            border-radius: 4px;
        }
        .timestamp {
            text-align: right;
            color: #666;
            font-size: 0.9em;
            margin-top: 20px;
        }
        .status {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.9em;
            margin-left: 10px;
        }
        .status-ok { background: #4CAF50; color: white; }
        .status-warning { background: #FF9800; color: white; }
        .status-error { background: #F44336; color: white; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>$titulo</h1>
        </div>
        
        <div class="metrics-grid">
            <div class="metric-card">
                <div class="metric-title">Tasa de Mensajes</div>
                <div class="metric-value">
                    ${tasa_mensajes:-0} msg/s
                    $(if [ "${tasa_mensajes:-0}" -gt "$UMBRAL_TASA_MENSAJES_MIN" ]; then
                        echo '<span class="status status-ok">OK</span>'
                    else
                        echo '<span class="status status-error">Bajo</span>'
                    fi)
                </div>
            </div>
            <div class="metric-card">
                <div class="metric-title">Latencia Promedio</div>
                <div class="metric-value">
                    ${latencia:-0} µs
                    $(if [ "${latencia:-0}" -lt "$UMBRAL_LATENCIA_ADVERTENCIA" ]; then
                        echo '<span class="status status-ok">OK</span>'
                    elif [ "${latencia:-0}" -lt "$UMBRAL_LATENCIA_CRITICO" ]; then
                        echo '<span class="status status-warning">Alto</span>'
                    else
                        echo '<span class="status status-error">Crítico</span>'
                    fi)
                </div>
            </div>
            <div class="metric-card">
                <div class="metric-title">Throughput</div>
                <div class="metric-value">${throughput:-0} MB/s</div>
            </div>
        </div>

        <div class="graph-container">
            <div class="graph-title">Tasa de Mensajes</div>
            <img class="graph-img" src="tasa_mensajes.png" alt="Tasa de Mensajes">
        </div>

        <div class="graph-container">
            <div class="graph-title">Latencia</div>
            <img class="graph-img" src="latencia.png" alt="Latencia">
        </div>

        <div class="graph-container">
            <div class="graph-title">Throughput</div>
            <img class="graph-img" src="throughput.png" alt="Throughput">
        </div>

        <div class="timestamp">
            Generado el: $(date '+%Y-%m-%d %H:%M:%S')
        </div>
    </div>
</body>
</html>
EOF

    imprimir "exito" "Dashboard HTML generado en $dir/dashboard.html"

    # Abrir el dashboard en el navegador predeterminado
    if [ -n "$OPEN_CMD" ]; then
        $OPEN_CMD "$dir/dashboard.html" >/dev/null 2>&1 || \
            imprimir "aviso" "No se pudo abrir el dashboard automáticamente"
    fi
}


# =================================================================
# Ejecución Principal
# =================================================================

main() {
    # Almacenar tiempo de inicio
    TIEMPO_INICIO=$(date +%s)

    # Verificar y validar parámetros
    imprimir "titulo" "VERIFICACIÓN INICIAL"
    if ! validar_parametros; then
        exit 1
    fi

    # Crear directorio para resultados
    mkdir -p "$DIRECTORIO_SALIDA"
    imprimir "info" "Directorio de resultados creado: $DIRECTORIO_SALIDA"

    # Crear subdirectorios para organización
    mkdir -p "$DIRECTORIO_SALIDA/datos"
    mkdir -p "$DIRECTORIO_SALIDA/graficos"

    # Verificar requisitos del sistema
    imprimir "titulo" "VERIFICANDO REQUISITOS"
    if ! verificar_requisitos; then
        imprimir "error" "No se cumplen los requisitos necesarios"
        exit 1
    fi

    # Verificar puertos necesarios
    imprimir "titulo" "VERIFICANDO PUERTOS"
    if ! verificar_puertos; then
        imprimir "error" "Hay puertos necesarios que no están disponibles"
        exit 1
    fi

    # Limpiar contenedores existentes
    imprimir "titulo" "LIMPIANDO AMBIENTE"
    imprimir "info" "Deteniendo contenedores previos..."
    docker-compose down -v >/dev/null 2>&1

    # Exportar variables de entorno para docker-compose
    export TEST_DURATION=$DURACION
    export PUBLISH_RATE=$TASA

    # Iniciar los servicios
    imprimir "titulo" "INICIANDO SERVICIOS"
    imprimir "info" "Iniciando contenedores con docker-compose..."
    if ! docker-compose up -d; then
        imprimir "error" "Error al iniciar los servicios"
        exit 1
    fi

    # Esperar a que los servicios estén listos
    imprimir "info" "Esperando a que los servicios estén listos..."
    sleep 5  # Dar tiempo inicial para que los servicios empiecen

    # Verificar servicios críticos
    imprimir "titulo" "VERIFICANDO SERVICIOS"
    local servicios_ok=true
    
    if ! verificar_servicio "http://localhost:9090/-/healthy" "Prometheus"; then
        servicios_ok=false
    fi
    if ! verificar_servicio "http://localhost:3000/api/health" "Grafana"; then
        servicios_ok=false
    fi
    if ! verificar_servicio "http://localhost:8222/healthz" "NATS"; then
        servicios_ok=false
    fi

    if [ "$servicios_ok" = false ]; then
        imprimir "error" "No todos los servicios están funcionando correctamente"
        docker-compose down -v
        exit 1
    fi

    # Iniciar la prueba
    imprimir "titulo" "EJECUTANDO PRUEBA DE RENDIMIENTO"
    imprimir "info" "Duración: $DURACION segundos"
    imprimir "info" "Tasa objetivo: $TASA mensajes/segundo"

    # Capturar logs en tiempo real
    docker-compose logs -f > "$DIRECTORIO_SALIDA/logs_completos.log" 2>&1 &
    LOGS_PID=$!

    # Inicializar archivos de datos
    > "$DIRECTORIO_SALIDA/datos/datos_tasa_pub.txt"
    > "$DIRECTORIO_SALIDA/datos/datos_tasa_sub.txt"
    > "$DIRECTORIO_SALIDA/datos/latencia_promedio.txt"
    > "$DIRECTORIO_SALIDA/datos/latencia_p95.txt"
    > "$DIRECTORIO_SALIDA/datos/latencia_p99.txt"
    > "$DIRECTORIO_SALIDA/datos/throughput_enviado.txt"
    > "$DIRECTORIO_SALIDA/datos/throughput_recibido.txt"

    # Ejecutar la prueba y recolectar métricas
    imprimir "info" "Prueba en progreso..."
    local tiempo_transcurrido=0
    local ultimo_porcentaje=0

    while [ $tiempo_transcurrido -lt $DURACION ]; do
        # Calcular y mostrar progreso
        local porcentaje=$((tiempo_transcurrido * 100 / DURACION))
        if [ $porcentaje -ne $ultimo_porcentaje ]; then
            echo -ne "\rProgreso: [${porcentaje}%] "
            printf "%-${porcentaje}s" "" | tr ' ' '█'
            printf "%-$((100-porcentaje))s" "" | tr ' ' '░'
            ultimo_porcentaje=$porcentaje
        fi

        # Recolectar métricas cada 5 segundos
        if [ $((tiempo_transcurrido % 5)) -eq 0 ]; then
            recolectar_metricas "$DIRECTORIO_SALIDA/datos" false
        fi

        sleep 1
        tiempo_transcurrido=$((tiempo_transcurrido + 1))
    done
    echo -e "\rProgreso: [100%] $(printf "%-100s" "" | tr ' ' '█')"

    # Detener la captura de logs
    kill $LOGS_PID 2>/dev/null
    wait $LOGS_PID 2>/dev/null

    # Recolectar métricas finales
    imprimir "titulo" "RECOLECTANDO MÉTRICAS FINALES"
    recolectar_metricas "$DIRECTORIO_SALIDA/datos" true

    # Generar visualizaciones
    imprimir "titulo" "GENERANDO VISUALIZACIONES"
    generar_graficos "$DIRECTORIO_SALIDA"
    generar_dashboard "$DIRECTORIO_SALIDA"

    # Detener los servicios
    imprimir "titulo" "FINALIZANDO PRUEBA"
    imprimir "info" "Deteniendo servicios..."
    docker-compose down -v

    # Calcular tiempo total
    local tiempo_fin=$(date +%s)
    local duracion_total=$((tiempo_fin - TIEMPO_INICIO))

    # Mostrar resumen final
    imprimir "titulo" "PRUEBA COMPLETADA"
    imprimir "exito" "Tiempo total de ejecución: $duracion_total segundos"
    imprimir "exito" "Resultados guardados en: $DIRECTORIO_SALIDA"
    imprimir "info" "- Dashboard: $DIRECTORIO_SALIDA/dashboard.html"
    imprimir "info" "- Informe detallado: $DIRECTORIO_SALIDA/informe_final.txt"
    imprimir "info" "- Logs completos: $DIRECTORIO_SALIDA/logs_completos.log"
    imprimir "info" "- Gráficos: $DIRECTORIO_SALIDA/graficos/"
    imprimir "info" "- Datos raw: $DIRECTORIO_SALIDA/datos/"

    # Intentar abrir el dashboard
    if [ -f "$DIRECTORIO_SALIDA/dashboard.html" ]; then
        imprimir "info" "Abriendo dashboard en el navegador..."
        if ! $OPEN_CMD "$DIRECTORIO_SALIDA/dashboard.html" 2>/dev/null; then
            imprimir "aviso" "No se pudo abrir el dashboard automáticamente"
            imprimir "info" "Abra manualmente: $DIRECTORIO_SALIDA/dashboard.html"
        fi
    fi

    # Verificar si hubo errores graves durante la prueba
    if [ -f "$DIRECTORIO_SALIDA/informe_final.txt" ] && grep -q "CRÍTICO\|ERROR" "$DIRECTORIO_SALIDA/informe_final.txt"; then
        imprimir "aviso" "Se detectaron errores durante la prueba. Revise el informe final para más detalles."
    fi
}

# Manejo de señales
trap 'echo -e "\n${ROJO}Prueba interrumpida por el usuario${NC}"; docker-compose down -v; exit 1' SIGINT SIGTERM

# Ejecutar la función principal
main "$@"



