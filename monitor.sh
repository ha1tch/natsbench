#!/bin/bash

# Colors for pretty output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
YELLOW='\033[1;33m'

# Function to check if a port is available
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${RED}El puerto $port está en uso${NC}"
        return 1
    fi
    return 0
}

# Function to wait for service availability
wait_for_service() {
    local service=$1
    local port=$2
    local max_attempts=30
    local attempt=1

    echo -e "${YELLOW}Esperando que $service esté listo...${NC}"
    
    while ! curl -s "http://localhost:$port" > /dev/null; do
        if [ $attempt -eq $max_attempts ]; then
            echo -e "${RED}$service no pudo iniciar después de $max_attempts intentos${NC}"
            return 1
        fi
        echo -n "."
        sleep 1
        ((attempt++))
    done
    echo -e "\n${GREEN}¡$service está listo!${NC}"
    return 0
}

# Check required ports
required_ports=(3000 4222 8222 9090)
for port in "${required_ports[@]}"; do
    if ! check_port $port; then
        echo -e "${RED}Por favor, libere el puerto $port antes de continuar${NC}"
        exit 1
    fi
done

# Start all services
echo -e "${YELLOW}Iniciando servicios de monitoreo...${NC}"
docker-compose up -d

# Wait for services to be ready
if wait_for_service "Prometheus" 9090; then
    echo -e "${GREEN}Prometheus está disponible en: ${NC}http://localhost:9090"
else
    echo -e "${RED}No se pudo iniciar Prometheus${NC}"
fi

if wait_for_service "Grafana" 3000; then
    echo -e "${GREEN}Grafana está disponible en: ${NC}http://localhost:3000"
    echo -e "${YELLOW}Credenciales de Grafana:${NC}"
    echo "  Usuario: admin"
    echo "  Contraseña: admin"
else
    echo -e "${RED}No se pudo iniciar Grafana${NC}"
fi

if wait_for_service "NATS" 8222; then
    echo -e "${GREEN}Monitoreo de NATS disponible en: ${NC}http://localhost:8222"
else
    echo -e "${RED}No se pudo iniciar NATS${NC}"
fi

# Print monitoring URLs
echo -e "\n${GREEN}URLs de Monitoreo:${NC}"
echo "- Grafana:    http://localhost:3000"
echo "- Prometheus: http://localhost:9090"
echo "- NATS:       http://localhost:8222"

# Function to display container status
show_status() {
    echo -e "\n${YELLOW}Estado de Contenedores:${NC}"
    docker-compose ps
}

# Function to follow logs
follow_logs() {
    echo -e "\n${YELLOW}Siguiendo logs (Ctrl+C para detener):${NC}"
    docker-compose logs -f
}

# Show initial status
show_status

# Interactive options
echo -e "\n${GREEN}Comandos de Monitoreo:${NC}"
echo "1. Ver estado de contenedores (docker-compose ps)"
echo "2. Seguir logs (docker-compose logs -f)"
echo "3. Detener servicios de monitoreo"
echo "4. Reiniciar servicios de monitoreo"
echo "q. Salir"

while true; do
    read -p "Ingrese comando (1-4 o q): " cmd
    case $cmd in
        1) show_status ;;
        2) follow_logs ;;
        3) 
            echo -e "${YELLOW}Deteniendo servicios de monitoreo...${NC}"
            docker-compose down
            echo -e "${GREEN}Servicios de monitoreo detenidos${NC}"
            exit 0
            ;;
        4)
            echo -e "${YELLOW}Reiniciando servicios de monitoreo...${NC}"
            docker-compose down
            docker-compose up -d
            show_status
            ;;
        q) 
            echo -e "${GREEN}Saliendo del script de monitoreo${NC}"
            exit 0
            ;;
        *) echo -e "${RED}Opción inválida${NC}" ;;
    esac
done
