# NATS Performance Testing Suite

This testing suite provides a containerized way to run performance tests on a NATS server using Go-based publishers and subscribers.

## 🚀 Features

- Containerized testing using Docker and Docker Compose
- Comprehensive performance metrics including:
  - Message rate (messages/second)
  - Throughput (MB/s)
  - Message latency
  - Error counting
  - Message sizes
- Configurable test duration
- Configurable publishing rate
- Automatic result collection
- Detailed test reports

## 📋 Prerequisites

- Docker
- Docker Compose
- Bash (for test script)

## 🗂️ Project Structure

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

## 🛠️ Setup

1. Clone the repository:
```bash
git clone [repository_URL]
cd nats-perf-test
```

2. Make sure the test script is executable:
```bash
chmod +x run_test.sh
```

## 📊 Running Tests

### Basic Usage

```bash
./run_test.sh [duration_in_seconds] [messages_per_second]
```

### Examples

1. Run a 5-minute test at 1000 messages/second:
```bash
./run_test.sh 300 1000
```

2. Run a 10-minute test at 5000 messages/second:
```bash
./run_test.sh 600 5000
```

## 📈 Test Results

Results are saved in a timestamped directory: `test_results_[timestamp]/`

Each results directory contains:
- `raw_output.log`: Complete test output
- `publisher_metrics.log`: Publisher metrics
- `subscriber_metrics.log`: Subscriber metrics
- `test_summary.txt`: Test summary

## 🔍 Monitoring During Tests

The NATS server exposes a monitoring endpoint on port 8222. You can access these metrics during the test:

```bash
# Get general NATS server information
curl http://localhost:8222/varz

# Get subscription information
curl http://localhost:8222/subsz

# Get connection information
curl http://localhost:8222/connz
```

## ⚙️ Environment Variables

You can configure the following environment variables:

- `NATS_URL`: NATS server URL (default: nats://nats:4222)
- `TEST_DURATION`: Test duration in seconds
- `PUBLISH_RATE`: Message publishing rate per second

## 🔧 Advanced Configuration

To modify the configuration, you can adjust the following files:
- `docker-compose.yml`: Services configuration
- `publisher/main.go`: Publisher logic
- `subscriber/main.go`: Subscriber logic

## 📝 Important Notes

- Tests will automatically stop after the specified duration
- Containers will gracefully shut down upon completion
- Results are automatically saved
- The script handles resource creation and cleanup

## 🤝 Contributing

Contributions are welcome. Please make sure to:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## ❗ Troubleshooting

If you encounter issues:

1. Verify Docker and Docker Compose are installed and running
2. Ensure ports 4222 and 8222 are available
3. Check logs using `docker-compose logs`

## 🔬 Advanced Testing Scenarios

### Scaling Subscribers
To test with multiple subscribers:
```bash
docker-compose up -d
docker-compose scale subscriber=3
```

### Testing Different Message Sizes
Modify the `PAYLOAD_SIZE` environment variable in docker-compose.yml:
```yaml
environment:
  - PAYLOAD_SIZE=1024  # Size in bytes
```

### Testing with Different NATS Configurations
The NATS server configuration can be customized in docker-compose.yml:
```yaml
services:
  nats:
    command: ["--max_payload", "2MB", "--max_connections", "1000"]
```

## 📊 Performance Metrics Explained

### Publisher Metrics
- Message Rate: Number of messages published per second
- Throughput: Amount of data published per second (MB/s)
- Error Rate: Number of failed publish attempts
- Average Latency: Time taken to publish messages

### Subscriber Metrics
- Message Rate: Number of messages received per second
- Processing Time: Time taken to process each message
- End-to-End Latency: Time from publish to receive
- Message Order Analysis: Detection of out-of-order messages

## 📄 License

This project is licensed under the MIT License. See the `LICENSE` file for details.
