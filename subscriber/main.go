package main

import (
	"encoding/json"
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
	counter        uint64
	bytesReceived  uint64
	errorCount     uint64
	latencySum     uint64
	latencyCount   uint64
	startTime      time.Time
	lastReportTime time.Time
}

func main() {
	// Get configuration from environment
	natsURL := getEnv("NATS_URL", nats.DefaultURL)
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
		log.Fatalf("Error connecting to NATS: %v", err)
	}
	defer nc.Close()

	log.Printf("Connected to NATS server at %s", natsURL)
	log.Printf("Test duration: %d seconds", testDuration)

	// Subscribe to messages
	sub, err := nc.Subscribe("messages.updates", func(msg *nats.Msg) {
		atomic.AddUint64(&metrics.counter, 1)
		atomic.AddUint64(&metrics.bytesReceived, uint64(len(msg.Data)))

		var message Message
		if err := json.Unmarshal(msg.Data, &message); err != nil {
			atomic.AddUint64(&metrics.errorCount, 1)
			log.Printf("Error unmarshaling message: %v", err)
			return
		}

		// Calculate message latency
		latency := time.Since(message.Timestamp).Microseconds()
		atomic.AddUint64(&metrics.latencySum, uint64(latency))
		atomic.AddUint64(&metrics.latencyCount, 1)

		// Report metrics every second
		if time.Since(metrics.lastReportTime) >= time.Second {
			reportMetrics(metrics)
			metrics.lastReportTime = time.Now()
		}
	})
	if err != nil {
		log.Fatalf("Error subscribing: %v", err)
	}
	defer sub.Unsubscribe()

	// Setup graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// Create timer for test duration
	testTimer := time.NewTimer(time.Duration(testDuration) * time.Second)

	// Wait for shutdown signal or test duration
	select {
	case <-sigCh:
		log.Println("Received shutdown signal")
	case <-testTimer.C:
		log.Println("Test duration completed")
	}

	// Final metrics report
	reportMetrics(metrics)
	log.Printf("Test completed. Total errors: %d", atomic.LoadUint64(&metrics.errorCount))
}

func reportMetrics(m *Metrics) {
	elapsed := time.Since(m.startTime)
	count := atomic.LoadUint64(&m.counter)
	bytes := atomic.LoadUint64(&m.bytesReceived)
	latencySum := atomic.LoadUint64(&m.latencySum)
	latencyCount := atomic.LoadUint64(&m.latencyCount)

	rate := float64(count) / elapsed.Seconds()
	throughput := float64(bytes) / (1024 * 1024 * elapsed.Seconds()) // MB/s
	
	var avgLatency float64
	if latencyCount > 0 {
		avgLatency = float64(latencySum) / float64(latencyCount)
	}

	log.Printf("Messages received: %d, Rate: %.2f msg/sec, Throughput: %.2f MB/s, Avg Latency: %.2f µs",
		count, rate, throughput, avgLatency)
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
