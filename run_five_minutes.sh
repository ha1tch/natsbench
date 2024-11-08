# run_five_minutes.sh
#!/bin/bash

# Default rate is 1000 msg/sec if not specified
RATE=${1:-1000}

echo "Ejecutando prueba de 5 minutos a $RATE mensajes por segundo..."
./run_test.sh 300 $RATE
