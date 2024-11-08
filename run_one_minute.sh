# run_one_minute.sh
#!/bin/bash

# Default rate is 1000 msg/sec if not specified
RATE=${1:-1000}

echo "Ejecutando prueba de 1 minuto a $RATE mensajes por segundo..."
./run_test.sh 60 $RATE

