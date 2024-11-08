package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
)

type Message struct {
	ID        uint64    `json:"id"`
	Timestamp time.Time `json:"timestamp"`
	Data      string    `json:"data"`
	Size      int      `json:"size"`
}

type Metrics struct {
	counter       uint64
	bytesSent     uint64
	errorCount    uint64
	startTime     time.Time
	lastReportTime time.Time
}

func main() {
	// Get configuration from environment
	natsURL := getEnv("NATS_URL", nats.DefaultURL)
	publishRate := getEnvInt("PUBLISH_RATE", 1000)
	testDuration := getEnvInt("TEST_DURATION", 300)
	
	// Initialize metrics
	metrics := &Metrics{
		startTime:     time.Now(),
		lastReportTime: time.Now(),
	}

	// Connect to NATS
	nc, err := nats.Connect(natsURL,
		nats.PingInterval(20*time.Second),
		nats.MaxPingsOutstanding(5),
		nats.ReconnectWait(2*time.Second),
		nats.RetryOnFailedConnect(true),
		nats.MaxReconnects(-1),
	)
	if err != nil {
		log.Fatalf("Error al conectar a NATS: %v", err)
	}
	defer nc.Close()

	log.Printf("Conectado al servidor NATS en %s", natsURL)
	log.Printf("Tasa de publicación: %d mensajes/seg", publishRate)
	log.Printf("Duración de la prueba: %d segundos", testDuration)

	// Setup graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// Create timer for test duration
	testTimer := time.NewTimer(time.Duration(testDuration) * time.Second)

	// Publishing loop
	ticker := time.NewTicker(time.Second / time.Duration(publishRate))
	defer ticker.Stop()

	go func() {
		for {
			select {
			case <-ticker.C:
				msg := Message{
					ID:        atomic.AddUint64(&metrics.counter, 1),
					Timestamp: time.Now(),
					Data:      fmt.Sprintf("Mensaje %d del publicador Go", metrics.counter),
				}

				data, err := json.Marshal(msg)
				if err != nil {
					atomic.AddUint64(&metrics.errorCount, 1)
					log.Printf("Error al serializar el mensaje: %v", err)
					continue
				}

				msg.Size = len(data)
				err = nc.Publish("messages.updates", data)
				if err != nil {
					atomic.AddUint64(&metrics.errorCount, 1)
					log.Printf("Error al publicar el mensaje: %v", err)
					continue
				}

				atomic.AddUint64(&metrics.bytesSent, uint64(len(data)))

				// Report metrics every second
				if time.Since(metrics.lastReportTime) >= time.Second {
					reportMetrics(metrics)
					metrics.lastReportTime = time.Now()
				}
			}
		}
	}()

	// Wait for shutdown signal or test duration
	select {
	case <-sigCh:
		log.Println("Señal de apagado recibida")
	case <-testTimer.C:
		log.Println("Prueba completada")
	}

	// Final metrics report
	reportMetrics(metrics)
	log.Printf("Prueba finalizada. Total de errores: %d", atomic.LoadUint64(&metrics.errorCount))
}

func reportMetrics(m *Metrics) {
	elapsed := time.Since(m.startTime)
	count := atomic.LoadUint64(&m.counter)
	bytes := atomic.LoadUint64(&m.bytesSent)
	
	rate := float64(count) / elapsed.Seconds()
	throughput := float64(bytes) / (1024 * 1024 * elapsed.Seconds()) // MB/s

	log.Printf("Mensajes enviados: %d, Tasa: %.2f msg/seg, Rendimiento: %.2f MB/s",
		count, rate, throughput)
}

func getEnv(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value, exists := os.LookupEnv(key); exists {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
	}
	return defaultValue
}
