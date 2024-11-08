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

    # Verificar gnuplot (necesario para gráficos)
    if ! command -v gnuplot >/dev/null 2>&1; then
        imprimir "aviso" "gnuplot no está instalado - no se generarán gráficos"
    else
        imprimir "exito" "gnuplot está instalado"
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

# Función para procesar y formatear valores numéricos
formatear_valor() {
    local valor=$1
    local tipo=$2  # bytes, latencia, tasa

    if [ "$valor" = "N/A" ]; then
        echo "N/A"
        return
    fi

    case $tipo in
        "bytes")
            if [ $(echo "$valor > 1073741824" | bc -l) -eq 1 ]; then
                printf "%.2f GB" $(echo "scale=2; $valor / 1073741824" | bc -l)
            elif [ $(echo "$valor > 1048576" | bc -l) -eq 1 ]; then
                printf "%.2f MB" $(echo "scale=2; $valor / 1048576" | bc -l)
            elif [ $(echo "$valor > 1024" | bc -l) -eq 1 ]; then
                printf "%.2f KB" $(echo "scale=2; $valor / 1024" | bc -l)
            else
                printf "%.0f B" $valor
            fi
            ;;
        "latencia")
            if [ $(echo "$valor > 1000000" | bc -l) -eq 1 ]; then
                printf "%.2f s" $(echo "scale=2; $valor / 1000000" | bc -l)
            elif [ $(echo "$valor > 1000" | bc -l) -eq 1 ]; then
                printf "%.2f ms" $(echo "scale=2; $valor / 1000" | bc -l)
            else
                printf "%.2f µs" $valor
            fi
            ;;
        "tasa")
            printf "%.2f/s" $valor
            ;;
        *)
            printf "%.2f" $valor
            ;;
    esac
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
            echo "Total mensajes enviados: $(formatear_valor $total_mensajes_env)"
            echo "Total mensajes recibidos: $(formatear_valor $total_mensajes_rec)"
            echo "Total bytes transferidos: $(formatear_valor $total_bytes_env 'bytes')"
            echo "Total errores: $(formatear_valor $total_errores)"
            echo ""
            echo "Métricas de Rendimiento"
            echo "----------------------"
            echo "Tasa de mensajes promedio: $(formatear_valor $tasa_pub 'tasa') mensajes"
            echo "Latencia promedio: $(formatear_valor $latencia 'latencia')"
            echo "Latencia P95: $(formatear_valor $latencia_p95 'latencia')"
            echo "Latencia P99: $(formatear_valor $latencia_p99 'latencia')"
            echo "Throughput promedio: $(formatear_valor $throughput_env 'bytes')/s"
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
                imprimir "error" "Latencia crítica detectada: $(formatear_valor $latencia 'latencia')"
            elif [ "$(echo "$latencia > $UMBRAL_LATENCIA_ADVERTENCIA" | bc -l)" -eq 1 ]; then
                imprimir "aviso" "Latencia elevada detectada: $(formatear_valor $latencia 'latencia')"
            fi
        fi

        # Verificar tasa de errores
        if [ "$total_errores" != "N/A" ] && [ "$(echo "$total_errores > $UMBRAL_ERROR_PORCENTAJE" | bc -l)" -eq 1 ]; then
            imprimir "error" "Tasa de errores elevada: $(formatear_valor $total_errores)%"
        fi

        imprimir "exito" "Informe final generado en: $dir_salida/informe_final.txt"
    fi
}
