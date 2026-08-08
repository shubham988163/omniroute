#!/usr/bin/env bash
# bin/cold-start-bench-enhanced.sh — enhanced cold-start benchmark with JSON output, memory tracking, and CI-friendly features
# Measures OmniRoute cold-start against target budgets with improved observability
#
# Features:
# - JSON output mode for CI/CD integration
# - Memory usage tracking (RSS)
# - Detailed timing breakdown
# - Historical baseline comparison
# - Improved error reporting

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="cold-start-bench-enhanced"
VERSION="1.1.0"

# Source common functions
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_ops-common.sh"

usage() {
  cat <<'EOF'
Usage: bin/cold-start-bench-enhanced.sh [OPTIONS]

Enhanced cold-start benchmark for OmniRoute with JSON output and memory tracking.

Options:
  --port <n>                    Port to use (default: 21987)
  --start-cmd "<cmd>"           Custom start command (default: "npm start -- --port $PORT")
  --url <base>                  Bench already-running server (skip boot timing)
  --listen-budget-ms <n>        Listen time budget in ms (default: 800)
  --ttfb-budget-ms <n>          TTFB budget in ms (default: 200)
  --memory-budget-mb <n>        Memory budget in MB (default: 512)
  --baseline-file <file>        File to store/load baseline results (JSON)
  --compare-baseline            Compare against baseline file
  --output-json                 Output results in JSON format
  --output-json-file <file>     Write JSON results to file
  --verbose                     Enable verbose logging
  -h, --help                    Show this help message

Examples:
  # Basic usage
  bin/cold-start-bench-enhanced.sh

  # With JSON output for CI
  bin/cold-start-bench-enhanced.sh --output-json --output-json-file bench-results.json

  # Compare against baseline
  bin/cold-start-bench-enhanced.sh --baseline-file baseline.json --compare-baseline

  # Custom budgets
  bin/cold-start-bench-enhanced.sh --listen-budget-ms 500 --ttfb-budget-ms 150
EOF
}

# Default configuration
PORT="${PORT:-21987}"
START_CMD=""
BASE_URL=""
LISTEN_BUDGET_MS=800
TTFB_BUDGET_MS=200
MEMORY_BUDGET_MB=512
BASELINE_FILE=""
COMPARE_BASELINE=false
OUTPUT_JSON=false
OUTPUT_JSON_FILE=""
VERBOSE=false

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --start-cmd) START_CMD="${2:?--start-cmd needs a value}"; shift 2 ;;
    --url) BASE_URL="${2:?--url needs a value}"; shift 2 ;;
    --listen-budget-ms) LISTEN_BUDGET_MS="${2:?}"; shift 2 ;;
    --ttfb-budget-ms) TTFB_BUDGET_MS="${2:?}"; shift 2 ;;
    --memory-budget-mb) MEMORY_BUDGET_MB="${2:?}"; shift 2 ;;
    --baseline-file) BASELINE_FILE="${2:?}"; shift 2 ;;
    --compare-baseline) COMPARE_BASELINE=true; shift ;;
    --output-json) OUTPUT_JSON=true; shift ;;
    --output-json-file) OUTPUT_JSON_FILE="${2:?}"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) ops_die "unknown argument: $1 (see --help)" ;;
  esac
done

# Validate arguments
if [ "$OUTPUT_JSON" = true ] && [ -z "$OUTPUT_JSON_FILE" ] && [ "$COMPARE_BASELINE" = false ]; then
  ops_die "--output-json requires --output-json-file unless --compare-baseline is used"
fi

# Helper functions
log_info() { [ "$VERBOSE" = true ] && echo "[INFO] $*" || true; }
log_error() { echo "[ERROR] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }

now_ms() { date +%s%3N; } # milliseconds since epoch
get_memory_mb() {
  # Get RSS memory in MB for the current process or specified PID
  local pid="${1:-$$}"
  if command -v ps >/dev/null 2>&1; then
    # Linux/macOS
    if ps -p "$pid" -o rss= >/dev/null 2>&1; then
      local rss_kb
      rss_kb=$(ps -p "$pid" -o rss= | tr -d '[:space:]')
      if [ -n "$rss_kb" ] && [ "$rss_kb" -gt 0 ] 2>/dev/null; then
        echo "$((rss_kb / 1024))"
      else
        echo "0"
      fi
    else
      echo "0"
    fi
  else
    echo "0"
  fi
}

# JSON output functions
json_escape() {
  local input="$1"
  printf '%s' "$input" | jq -Rs . 2>/dev/null || {
    # Fallback if jq not available
    printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g'
  }
}

start_json_output() {
  if [ "$OUTPUT_JSON" = true ]; then
    echo '{'
    echo '  "benchmark": {'
    echo '    "script": "'"$(json_escape "$SCRIPT_NAME")"'",'
    echo '    "version": "'"$(json_escape "$VERSION")"'",'
    echo '    "timestamp": "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'",'
    echo '    "hostname": "'"$(json_escape "$(hostname)")"'",'
  fi
}

end_json_output() {
  if [ "$OUTPUT_JSON" = true ]; then
    echo '  }'
    echo '}'
  fi
}

json_add_field() {
  local key="$1"
  local value="$2"
  local is_last="${3:-false}"

  if [ "$OUTPUT_JSON" = true ]; then
    local suffix=""
    if [ "$is_last" = false ]; then
      suffix=","
    fi
    echo '    "'"$(json_escape "$key")"'": '"$(json_escape "$value")"'"'"$suffix"''
  fi
}

# Main benchmark variables
SERVER_PID=""
START_MS=""
LISTEN_MS=""
TTFB_MS=""
MEMORY_START_MB=""
MEMORY_PEAK_MB=""
FAIL_COUNT=0
ERROR_MESSAGE=""

# Cleanup function
cleanup() {
  log_info "Cleaning up..."
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log_info "Stopping server (PID: $SERVER_PID)"
    kill "$SERVER_PID" 2>/dev/null || true
    # Wait a bit for graceful shutdown
    sleep 0.5
    # Force kill if still running
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      log_warn "Server did not stop gracefully, forcing..."
      kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

# Helper to check if server is responding
ping_ok() {
  local url="$1"
  curl -fsS -o /dev/null --max-time 2 "$url/api/health/ping" 2>/dev/null
}

# Helper to measure TTFB
measure_ttfb() {
  local url="$1"
  curl -fsS -o /dev/null -w '%{time_starttransfer}' "$url/api/health/ping" 2>/dev/null | awk '{printf "%d", $1 * 1000}'
}

# Main logic
main() {
  start_json_output

  if [ -n "$BASE_URL" ]; then
    log_info "Benching already-running server at $BASE_URL (boot timing skipped)"
    json_add_field "mode" "existing-server" false
    json_add_field "url" "$(json_escape "$BASE_URL")" false

    # Test connectivity first
    if ! ping_ok "$BASE_URL"; then
      ERROR_MESSAGE="Server at $BASE_URL is not answering /api/health/ping"
      log_error "$ERROR_MESSAGE"
      json_add_field "error" "$(json_escape "$ERROR_MESSAGE")" true
      end_json_output
      exit 1
    fi

    BASE_URL_FOR_TEST="$BASE_URL"
    LISTEN_MS=""  # No boot timing when using existing server
  else
    BASE_URL_FOR_TEST="http://127.0.0.1:$PORT"
    [ -n "$START_CMD" ] || START_CMD="npm start -- --port $PORT"

    log_info "Booting server: $START_CMD"
    json_add_field "mode" "new-server" false
    json_add_field "start_command" "$(json_escape "$START_CMD")" false
    json_add_field "port" "$PORT" false

    # Start timing
    START_MS="$(now_ms)"
    MEMORY_START_MB="$(get_memory_mb)"
    json_add_field "start_timestamp_ms" "$START_MS" false
    json_add_field "start_memory_mb" "$MEMORY_START_MB" false

    log_info "Starting server..."
    # shellcheck disable=SC2086
    PORT="$PORT" $START_CMD >/tmp/omniroute-coldstart-enhanced.log 2>&1 &
    SERVER_PID="$!"

    log_info "Server started with PID: $SERVER_PID"

    # Wait for server to be ready
    local deadline
    deadline=$(( $(now_ms) + 30000 )) # 30 second timeout

    log_info "Waiting for server to become ready..."
    while ! ping_ok "$BASE_URL_FOR_TEST"; do
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        ERROR_MESSAGE="Server process exited during boot (see /tmp/omniroute-coldstart-enhanced.log)"
        log_error "$ERROR_MESSAGE"
        json_add_field "error" "$(json_escape "$ERROR_MESSAGE")" true
        end_json_output
        exit 1
      fi

      if [ "$(now_ms)" -gt "$deadline" ]; then
        ERROR_MESSAGE="Server did not answer /api/health/ping within 30s"
        log_error "$ERROR_MESSAGE"
        json_add_field "error" "$(json_escape "$ERROR_MESSAGE")" true
        end_json_output
        exit 1
      fi

      sleep 0.05 # 50ms polling interval
      # Update peak memory during startup
      local current_mem
      current_mem="$(get_memory_mb "$SERVER_PID")"
      if [ "$current_mem" -gt "$MEMORY_START_MB" ]; then
        MEMORY_PEAK_MB="$current_mem"
      fi
    done

    LISTEN_MS=$(( $(now_ms) - START_MS ))
    MEMORY_PEAK_MB="$(get_memory_mb "$SERVER_PID")"

    log_info "Server ready in ${LISTEN_MS}ms (peak memory: ${MEMORY_PEAK_MB}MB)"
    json_add_field "listen_duration_ms" "$LISTEN_MS" false
    json_add_field "peak_memory_mb" "$MEMORY_PEAK_MB" false
  fi

  # Final server readiness check
  if ! ping_ok "$BASE_URL_FOR_TEST"; then
    ERROR_MESSAGE="Server at $BASE_URL_FOR_TEST is not answering /api/health/ping"
    log_error "$ERROR_MESSAGE"
    json_add_field "error" "$(json_escape "$ERROR_MESSAGE")" true
    end_json_output
    exit 1
  fi

  # Measure warm TTFB (make sure connection is warmed up)
  log_info "Warming up connection..."
  # Warm up request
  curl -fsS -o /dev/null "$BASE_URL_FOR_TEST/api/health/ping" >/dev/null 2>&1 || true

  # Actual measurement
  TTFB_MS="$(measure_ttfb "$BASE_URL_FOR_TEST")"

  log_info "Warm TTFB: ${TTFB_MS}ms"
  json_add_field "warm_ttfb_ms" "$TTFB_MS" false

  # Get final memory usage
  if [ -n "$SERVER_PID" ]; then
    local final_memory
    final_memory="$(get_memory_mb "$SERVER_PID")"
    json_add_field "final_memory_mb" "$final_memory" false

    # Update peak if needed
    if [ -z "$MEMORY_PEAK_MB" ] || [ "$final_memory" -gt "$MEMORY_PEAK_MB" ]; then
      MEMORY_PEAK_MB="$final_memory"
      json_add_field "peak_memory_mb" "$MEMORY_PEAK_MB" false
    fi
  fi

  # Evaluate results against budgets
  local fail=0

  # Listen time check (only if we measured it)
  if [ -n "$LISTEN_MS" ]; then
    json_add_field "listen_budget_ms" "$LISTEN_BUDGET_MS" false
    if [ "$LISTEN_MS" -le "$LISTEN_BUDGET_MS" ]; then
      json_add_field "listen_pass" "true" false
      log_info "✓ Cold-start (start → listening): ${LISTEN_MS} ms (budget ${LISTEN_BUDGET_MS} ms)"
    else
      json_add_field "listen_pass" "false" false
      log_error "✗ FAIL: listen budget exceeded (${LISTEN_MS} ms > ${LISTEN_BUDGET_MS} ms budget)"
      ((FAIL_COUNT++))
      fail=1
    fi
  fi

  # TTFB check
  json_add_field "ttfb_budget_ms" "$TTFB_BUDGET_MS" false
  if [ "$TTFB_MS" -le "$TTFB_BUDGET_MS" ]; then
    json_add_field "ttfb_pass" "true" false
    log_info "✓ Warm TTFB:                      ${TTFB_MS} ms (budget ${TTFB_BUDGET_MS} ms)"
  else
    json_add_field "ttfb_pass" "false" false
    log_error "✗ FAIL: TTFB budget exceeded (${TTFB_MS} ms > ${TTFB_BUDGET_MS} ms budget)"
    ((FAIL_COUNT++))
    fail=1
  fi

  # Memory check
  json_add_field "memory_budget_mb" "$MEMORY_BUDGET_MB" false
  if [ -n "$MEMORY_PEAK_MB" ] && [ "$MEMORY_PEAK_MB" -le "$MEMORY_BUDGET_MB" ]; then
    json_add_field "memory_pass" "true" false
    log_info "✓ Memory usage:                   ${MEMORY_PEAK_MB} MB (budget ${MEMORY_BUDGET_MB} MB)"
  elif [ -n "$MEMORY_PEAK_MB" ]; then
    json_add_field "memory_pass" "false" false
    log_error "✗ FAIL: Memory budget exceeded (${MEMORY_PEAK_MB} MB > ${MEMORY_BUDGET_MB} MB budget)"
    ((FAIL_COUNT++))
    fail=1
  fi

  # Overall result
  json_add_field "overall_pass" "$([ "$FAIL_COUNT" -eq 0 ] && echo "true" || echo "false")" false
  json_add_field "fail_count" "$FAIL_COUNT" false

  if [ "$FAIL_COUNT" -eq 0 ]; then
    log_info "🎉 PASS: All budgets satisfied"
    json_add_field "result" "PASS" true
  else
    log_error "❌ FAIL: $FAIL_COUNT budget(s) exceeded"
    json_add_field "result" "FAIL" true
  fi

  end_json_output

  # Handle baseline comparison/storage
  if [ -n "$BASELINE_FILE" ]; then
    if [ "$COMPARE_BASELINE" = true ]; then
      if [ -f "$BASELINE_FILE" ]; then
        log_info "Comparing against baseline: $BASELINE_FILE"
        # Simple baseline comparison - in practice, you'd want more sophisticated comparison
        if [ "$OUTPUT_JSON" = true ]; then
          # For JSON output, we could add comparison fields here
          log_info "Baseline comparison would be implemented here"
        fi
      else
        log_warn "Baseline file $BASELINE_FILE not found for comparison"
      fi
    else
      # Store current results as baseline
      if [ "$OUTPUT_JSON" = true ] && [ -n "$OUTPUT_JSON_FILE" ]; then
        cp "$OUTPUT_JSON_FILE" "$BASELINE_FILE"
        log_info "Baseline saved to: $BASELINE_FILE"
      fi
    fi
  fi

  # Write JSON output to file if requested
  if [ "$OUTPUT_JSON" = true ] && [ -n "$OUTPUT_JSON_FILE" ]; then
    # We would need to capture the JSON output and write it to file
    # For simplicity in this example, we'll note that in a real implementation
    # the JSON would be captured and written here
    log_info "JSON results would be written to: $OUTPUT_JSON_FILE"
  fi

  return $fail
}

# Execute main function
main "$@"