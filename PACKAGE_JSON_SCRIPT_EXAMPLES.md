# Package.json Script Examples for Enhanced Benchmarks

Here are examples of how to add the enhanced cold start benchmark to your package.json scripts:

## Examples to Add to omniroute/package.json

Add these to the "scripts" section:

```json
{
  "scripts": {
    // Existing scripts...

    // Enhanced cold start benchmarks
    "bench:cold-start": "bin/cold-start-bench-enhanced.sh",
    "bench:cold-start:ci": "bin/cold-start-bench-enhanced.sh --output-json --output-json-file bench-results.json",
    "bench:cold-start:verbose": "bin/cold-start-bench-enhanced.sh --verbose",
    "bench:cold-start:baseline": "bin/cold-start-bench-enhanced.sh --baseline-file benchmarks/baseline.json",
    "bench:cold-start:compare": "bin/cold-start-bench-enhanced.sh --baseline-file benchmarks/baseline.json --compare-baseline",

    // Performance targets
    "bench:cold-start:strict": "bin/cold-start-bench-enhanced.sh --listen-budget-ms 500 --ttfb-budget-ms 150 --memory-budget-mb 256",
    "bench:cold-start:release": "bin/cold-start-bench-enhanced.sh --output-json --output-json-file benchmarks/release-$(git rev-parse --short HEAD).json --listen-budget-ms 600 --ttfb-budget-ms 180 --memory-budget-mb 384",

    // CI/CD integration examples
    "bench:cold-start:github": "bin/cold-start-bench-enhanced.sh --output-json --output-json-file cold-start-benchmark.json --listen-budget-ms 700 --ttfb-budget-ms 190 --memory-budget-mb 300",
    "bench:cold-start:gitlab": "bin/cold-start-bench-enhanced.sh --output-json --output-json-file cscd-$CI_PIPELINE_ID.json",

    // Convenience aliases
    "bench": "npm run bench:cold-start",
    "bench:ci": "npm run bench:cold-start:ci",
    "bench:baseline": "npm run bench:cold-start:baseline",
    "bench:compare": "npm run bench:cold-start:compare"
  }
}
```

## Usage Examples

```bash
# Basic usage
npm run bench:cold-start

# CI-friendly JSON output
npm run bench:cold-start:ci

# Verbose output for debugging
npm run bench:cold-start:verbose

# Strict performance targets
npm run bench:cold-start:strict

# Create/update baseline
npm run bench:cold-start:baseline

# Compare against baseline (for regression detection)
npm run bench:cold-start:compare

# Release-specific benchmarking
npm run bench:cold-start:release
```

## Advanced CI Examples

### GitHub Actions

```yaml
name: Performance Benchmark

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: ">=20"
          cache: "npm"

      - name: Install Dependencies
        run: npm ci

      - name: Run Cold Start Benchmark
        run: |
          npm run bench:cold-start:github

      - name: Upload Benchmark Results
        uses: actions/upload-artifact@v3
        with:
          name: cold-start-benchmark
          path: cold-start-benchmark.json

      - name: Comment on PR (if applicable)
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v6
        with:
          script: |
            const fs = require('fs');
            const results = JSON.parse(fs.readFileSync('cold-start-benchmark.json', 'utf8'));
            const comment = `
            ## 🚀 Cold Start Benchmark Results

            - **Listen Time**: \`${results.benchmark.listen_duration_ms}ms\` (${results.benchmark.listen_pass ? '✅ PASS' : '❌ FAIL'} )
            - **TTFB**: \`${results.benchmark.warm_ttfb_ms}ms\` (${results.benchmark.ttfb_pass ? '✅ PASS' : '❌ FAIL'} )
            - **Memory**: \`${results.benchmark.peak_memory_mb}MB\` (${results.benchmark.memory_pass ? '✅ PASS' : '❌ FAIL'} )
            - **Overall**: ${results.benchmark.result === 'PASS' ? '✅ PASS' : '❌ FAIL'}

            <details>
            <summary>Full Results</summary>

            \`\`\`json
            ${JSON.stringify(results, null, 2)}
            \`\`\`
            </details>
            `;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: comment
            });
```

### GitLab CI

```yaml
cold_start_benchmark:
  stage: test
  image: node:20
  script:
    - npm ci
    - npm run bench:cold-start:gitlab
  artifacts:
    when: always
    reports:
      json: cscd-$CI_PIPELINE_ID.json
    paths:
      - cscd-*.json
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      when: always
```

## Monitoring and Alerting Examples

### Prometheus Integration

You could extend the script to expose metrics:

```bash
# After collecting metrics, expose them for Prometheus
echo "omniroute_coldstart_listen_duration_ms ${LISTEN_MS}" | nc -q0 localhost 9090
echo "omniroute_coldstart_ttfb_ms ${TTFB_MS}" | nc -q0 localhost 9090
echo "omniroute_coldstart_memory_mb ${MEMORY_PEAK_MB}" | nc -q0 localhost 9090
```

### Dashboard Integration

The JSON output can be consumed by:

- Grafana (via JSON datasource or scripting)
- Custom internal dashboards
- Status pages
- Engineering metrics systems
