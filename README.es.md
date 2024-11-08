# Suite de Pruebas de Rendimiento NATS

Esta suite de pruebas proporciona una manera containerizada de ejecutar pruebas de rendimiento en un servidor NATS utilizando publicadores y suscriptores en Go.

## 🚀 Características

- Pruebas containerizadas usando Docker y Docker Compose
- Métricas completas de rendimiento incluyendo:
  - Tasa de mensajes (mensajes/segundo)
  - Rendimiento (MB/s)
  - Latencia de mensajes
  - Conteo de errores
  - Tamaño de mensajes
- Duración de prueba configurable
- Tasa de publicación configurable
- Recolección automática de resultados
- Informes detallados de las pruebas

## 📋 Prerequisitos

- Docker
- Docker Compose
- Bash (para el script de pruebas)

## 🗂️ Estructura del Proyecto

```
nats-perf-test/
├── docker-compose.yml
├── Dockerfile.publisher
├── Dockerfile.subscriber
├── go.mod
├── go.sum
├── publisher/
│   └── main.go
├── subscriber/
│   └── main.go
└── run_test.sh
```

## 🛠️ Configuración

1. Clona el repositorio:
```bash
git clone [URL_del_repositorio]
cd nats-perf-test
```

2. Asegúrate de que el script de pruebas sea ejecutable:
```bash
chmod +x run_test.sh
```

## 📊 Ejecutando las Pruebas

### Uso Básico

```bash
./run_test.sh [duración_en_segundos] [mensajes_por_segundo]
```

### Ejemplos

1. Ejecutar una prueba de 5 minutos a 1000 mensajes/segundo:
```bash
./run_test.sh 300 1000
```

2. Ejecutar una prueba de 10 minutos a 5000 mensajes/segundo:
```bash
./run_test.sh 600 5000
```

## 📈 Resultados de las Pruebas

Los resultados se guardan en un directorio con marca de tiempo: `test_results_[timestamp]/`

Cada directorio de resultados contiene:
- `raw_output.log`: Salida completa de la prueba
- `publisher_metrics.log`: Métricas del publicador
- `subscriber_metrics.log`: Métricas del suscriptor
- `test_summary.txt`: Resumen de la prueba

## 🔍 Monitoreo Durante las Pruebas

El servidor NATS expone un endpoint de monitoreo en el puerto 8222. Puedes acceder a estas métricas durante la prueba:

```bash
# Información general del servidor NATS
curl http://localhost:8222/varz

# Información de suscripciones
curl http://localhost:8222/subsz

# Información de conexiones
curl http://localhost:8222/connz
```

## ⚙️ Variables de Entorno

Puedes configurar las siguientes variables de entorno:

- `NATS_URL`: URL del servidor NATS (por defecto: nats://nats:4222)
- `TEST_DURATION`: Duración de la prueba en segundos
- `PUBLISH_RATE`: Tasa de publicación de mensajes por segundo

## 🔧 Configuración Avanzada

Para modificar la configuración, puedes ajustar los siguientes archivos:
- `docker-compose.yml`: Configuración de servicios
- `publisher/main.go`: Lógica del publicador
- `subscriber/main.go`: Lógica del suscriptor

## 📝 Notas Importantes

- Las pruebas se detendrán automáticamente después de la duración especificada
- Los contenedores se cerrarán graciosamente al finalizar
- Los resultados se guardan automáticamente
- El script maneja la creación y limpieza de recursos

## 🤝 Contribuciones

Las contribuciones son bienvenidas. Por favor, asegúrate de:
1. Hacer fork del repositorio
2. Crear una rama para tu característica
3. Enviar un pull request

## ❗ Solución de Problemas

Si encuentras problemas:

1. Verifica que Docker y Docker Compose estén instalados y funcionando
2. Asegúrate de que los puertos 4222 y 8222 estén disponibles
3. Revisa los logs usando `docker-compose logs`

## 🔬 Escenarios de Prueba Avanzados

### Escalando Suscriptores
Para probar con múltiples suscriptores:
```bash
docker-compose up -d
docker-compose scale subscriber=3
```

### Pruebas con Diferentes Tamaños de Mensaje
Modifica la variable de entorno `PAYLOAD_SIZE` en docker-compose.yml:
```yaml
environment:
  - PAYLOAD_SIZE=1024  # Tamaño en bytes
```

### Pruebas con Diferentes Configuraciones de NATS
La configuración del servidor NATS puede ser personalizada en docker-compose.yml:
```yaml
services:
  nats:
    command: ["--max_payload", "2MB", "--max_connections", "1000"]
```

## 📊 Explicación de Métricas de Rendimiento

### Métricas del Publicador
- Tasa de Mensajes: Número de mensajes publicados por segundo
- Rendimiento: Cantidad de datos publicados por segundo (MB/s)
- Tasa de Error: Número de intentos fallidos de publicación
- Latencia Promedio: Tiempo necesario para publicar mensajes

### Métricas del Suscriptor
- Tasa de Mensajes: Número de mensajes recibidos por segundo
- Tiempo de Procesamiento: Tiempo necesario para procesar cada mensaje
- Latencia de Extremo a Extremo: Tiempo desde la publicación hasta la recepción
- Análisis de Orden de Mensajes: Detección de mensajes fuera de orden

## 📄 Licencia

Este proyecto está bajo la Licencia MIT. Ver el archivo `LICENSE` para más detalles.
