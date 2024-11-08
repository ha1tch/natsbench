#!/bin/bash

# =================================================================
# Script de Pruebas de Rendimiento NATS
# =================================================================
# Uso: ./run_test.sh [duración] [tasa_mensajes]
# Ejemplo: ./run_test.sh 300 1000
#   - duración: tiempo en segundos (default: 300)
#   - tasa_mensajes: mensajes por segundo (default: 1000)
# =================================================================

# Colores para mejor legibilidad
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AZUL='\033[0;34m'
AMARILLO='\033[1;33m'
NC='\033[0m' # Sin Color

# Valores por defecto
DURACION=${1:-300}     # Duración de la prueba en segundos
TASA=${2:-1000}        # Mensajes por segundo
DIRECTORIO_SALIDA="resultados_prueba_$(date +%Y%m%d_%H%M%S)"

# Función para verificar si un puerto está disponible
verificar_puerto() {
    local puerto=$1
    local servicio=$2
    if lsof -Pi :$puerto -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${ROJO}Error: El puerto $puerto ($servicio) ya está en uso.${NC}"
        return 1
    fi
    return 0
}

# Función para verificar si un servicio está respondiendo
verificar_servicio() {
    local url=$1
    local servicio=$2
    local max_intentos=5
    local intento=1

    while [ $intento -le $max_intentos ]; do
        if curl -s -f "$url" >/dev/null 2>&1; then
            echo -e "${VERDE}✓ $servicio está funcionando${NC}"
            return 0
        fi
        echo -e "${AMARILLO}Intento $intento: Esperando que $servicio esté disponible...${NC}"
        sleep 2
        ((intento++))
    done
    
    echo -e "${ROJO}Error: $servicio no está respondiendo${NC}"
    return 1
}

# Función para obtener métricas de Prometheus
obtener_metricas_prometheus() {
    local query=$1
    local tiempo_fin=$(date +%s)
    local resultado

    resultado=$(curl -s -G --data-urlencode "query=$query" --data-urlencode "time=$tiempo_fin" http://localhost:9090/api/v1/query)
    
    if [ $? -eq 0 ]; then
        echo "$resultado" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# Verificaciones iniciales
echo -e "${AZUL}Verificando requisitos previos...${NC}"

# Verificar puertos necesarios
verificar_puerto 4222 "NATS" || exit 1
verificar_puerto 8222 "NATS HTTP" || exit 1
verificar_puerto 9090 "Prometheus" || exit 1
verificar_puerto 3000 "Grafana" || exit 1

# Crear directorio para resultados
mkdir -p "$DIRECTORIO_SALIDA"

# Función para imprimir encabezados
imprimir_encabezado() {
    echo -e "${AZUL}================================================${NC}"
    echo -e "${AZUL}$1${NC}"
    echo -e "${AZUL}================================================${NC}"
}

# Función para imprimir información
imprimir_info() {
    echo -e "${VERDE}➜ $1${NC}"
}

# Mostrar información inicial
imprimir_encabezado "PRUEBA DE RENDIMIENTO NATS"
imprimir_info "Duración de la prueba: ${DURACION} segundos"
imprimir_info "Tasa de mensajes: ${TASA} mensajes/segundo"
imprimir_info "Directorio de resultados: $DIRECTORIO_SALIDA"
echo ""

# Verificar que los servicios de monitoreo estén funcionando
echo -e "${AZUL}Verificando servicios de monitoreo...${NC}"
verificar_servicio "http://localhost:9090/-/healthy" "Prometheus" || exit 1
verificar_servicio "http://localhost:3000/api/health" "Grafana" || exit 1
verificar_servicio "http://localhost:8222/healthz" "NATS" || exit 1

# Exportar variables para docker-compose
export TEST_DURATION=$DURACION
export PUBLISH_RATE=$TASA

# Ejecutar la prueba
imprimir_encabezado "INICIANDO PRUEBA"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Iniciando contenedores..."
docker-compose up --build | tee "$DIRECTORIO_SALIDA/salida_completa.log"

# Procesar resultados
imprimir_encabezado "GENERANDO INFORME DE RESULTADOS"

# Extraer métricas del publicador y suscriptor
imprimir_info "Procesando métricas..."
grep "publisher_1" "$DIRECTORIO_SALIDA/salida_completa.log" | grep "Messages sent" > "$DIRECTORIO_SALIDA/metricas_publicador.log"
grep "subscriber_1" "$DIRECTORIO_SALIDA/salida_completa.log" | grep "Messages received" > "$DIRECTORIO_SALIDA/metricas_suscriptor.log"

# Obtener métricas de Prometheus
imprimir_info "Obteniendo métricas de Prometheus..."
TASA_MENSAJES_PROMETHEUS=$(obtener_metricas_prometheus "rate(nats_messages_sent_total[1m])")
LATENCIA_PROMEDIO=$(obtener_metricas_prometheus "rate(nats_end_to_end_latency_microseconds_sum[1m]) / rate(nats_end_to_end_latency_microseconds_count[1m])")
TASA_ERRORES=$(obtener_metricas_prometheus "rate(nats_publish_errors_total[1m])")
BYTES_ENVIADOS=$(obtener_metricas_prometheus "nats_bytes_sent_total")

# Generar informe final
{
    echo "INFORME DE PRUEBA DE RENDIMIENTO NATS"
    echo "====================================="
    echo ""
    echo "Parámetros de la Prueba"
    echo "----------------------"
    echo "Duración: ${DURACION} segundos"
    echo "Tasa objetivo: ${TASA} mensajes/segundo"
    echo ""
    echo "Resultados Finales del Publicador"
    echo "--------------------------------"
    tail -n 1 "$DIRECTORIO_SALIDA/metricas_publicador.log"
    echo ""
    echo "Resultados Finales del Suscriptor"
    echo "--------------------------------"
    tail -n 1 "$DIRECTORIO_SALIDA/metricas_suscriptor.log"
    echo ""
    echo "Métricas de Prometheus"
    echo "---------------------"
    echo "Tasa de mensajes (últimos 60s): $TASA_MENSAJES_PROMETHEUS msg/sec"
    echo "Latencia promedio: $LATENCIA_PROMEDIO µs"
    echo "Tasa de errores: $TASA_ERRORES errores/sec"
    echo "Total bytes enviados: $BYTES_ENVIADOS bytes"
    echo ""
    echo "Estadísticas Adicionales"
    echo "----------------------"
    echo "Fecha de la prueba: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Directorio de resultados: $DIRECTORIO_SALIDA"
} > "$DIRECTORIO_SALIDA/informe_final.txt"

# Generar gráficos de rendimiento (requiere gnuplot)
if command -v gnuplot >/dev/null 2>&1; then
    imprimir_info "Generando gráficos de rendimiento..."
    # Extraer datos para gráficos
    grep "Rate:" "$DIRECTORIO_SALIDA/metricas_publicador.log" | awk '{print $5}' > "$DIRECTORIO_SALIDA/datos_tasa_pub.txt"
    grep "Rate:" "$DIRECTORIO_SALIDA/metricas_suscriptor.log" | awk '{print $5}' > "$DIRECTORIO_SALIDA/datos_tasa_sub.txt"
    
    # Crear script de gnuplot
    cat << EOF > "$DIRECTORIO_SALIDA/plot.gnu"
set terminal png size 800,600
set output '$DIRECTORIO_SALIDA/grafico_rendimiento.png'
set title 'Rendimiento de Mensajería NATS'
set xlabel 'Tiempo (segundos)'
set ylabel 'Mensajes/segundo'
set grid
plot '$DIRECTORIO_SALIDA/datos_tasa_pub.txt' with lines title 'Publicador', \
     '$DIRECTORIO_SALIDA/datos_tasa_sub.txt' with lines title 'Suscriptor'
EOF
    gnuplot "$DIRECTORIO_SALIDA/plot.gnu"
fi

# Mostrar resumen final
imprimir_encabezado "PRUEBA COMPLETADA"
imprimir_info "Resultados guardados en: $DIRECTORIO_SALIDA/"
imprimir_info "Informe final: $DIRECTORIO_SALIDA/informe_final.txt"
if [ -f "$DIRECTORIO_SALIDA/grafico_rendimiento.png" ]; then
    imprimir_info "Gráfico de rendimiento: $DIRECTORIO_SALIDA/grafico_rendimiento.png"
fi

# Leyenda de archivos generados
echo ""
echo -e "${AMARILLO}Archivos Generados:${NC}"
echo "├── salida_completa.log       - Registro completo de la ejecución"
echo "├── metricas_publicador.log   - Métricas detalladas del publicador"
echo "├── metricas_suscriptor.log   - Métricas detalladas del suscriptor"
echo "├── informe_final.txt         - Resumen de la prueba con métricas de Prometheus"
if [ -f "$DIRECTORIO_SALIDA/grafico_rendimiento.png" ]; then
    echo "└── grafico_rendimiento.png   - Visualización del rendimiento"
fi
