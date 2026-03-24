#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
KEEP=false
DESTROY_ONLY=false
PASSED=0
FAILED=0
START_TIME=$(date +%s)

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run integration tests against a real AWS account.
Creates an RDS instance, deploys the scheduler module, and verifies
the Lambda can stop and start the instance.

Options:
  --region REGION   AWS region (default: us-east-1, or \$AWS_REGION)
  --keep            Don't destroy resources after test (for debugging)
  --destroy         Destroy existing test resources and exit
  -h, --help        Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)  REGION="$2"; shift 2;;
    --keep)    KEEP=true; shift;;
    --destroy) DESTROY_ONLY=true; shift;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

# --- Helpers ---

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

elapsed() {
  local secs=$(( $(date +%s) - START_TIME ))
  printf '%dm %ds' $((secs / 60)) $((secs % 60))
}

pass() { ((PASSED++)) || true; green "  PASS: $1"; }
fail() { ((FAILED++)) || true; red "  FAIL: $1"; }

cleanup() {
  echo ""
  if [ "$KEEP" = true ]; then
    yellow "Resources kept (--keep). Destroy later with:"
    yellow "  $0 --destroy --region $REGION"
  else
    yellow "Destroying resources..."
    terraform -chdir="$SCRIPT_DIR" destroy -auto-approve \
      -var="region=$REGION" 2>&1 | tail -5 || true
  fi

  bold "$(elapsed) | $PASSED passed, $FAILED failed"
  [ "$FAILED" -gt 0 ] && exit 1
  exit 0
}

get_status() {
  aws rds describe-db-instances \
    --db-instance-identifier "$1" \
    --region "$REGION" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text
}

wait_for_status() {
  local rds_id="$1" target="$2" timeout="${3:-900}"
  local start
  start=$(date +%s)

  while true; do
    local status
    status=$(get_status "$rds_id")
    printf '    %s (want: %s)\n' "$status" "$target"

    [ "$status" = "$target" ] && return 0

    if (( $(date +%s) - start > timeout )); then
      fail "Timed out after ${timeout}s waiting for '$target' (at '$status')"
      return 1
    fi
    sleep 15
  done
}

invoke_lambda() {
  local lambda_arn="$1" rule_arn="$2" action="$3"
  local tmpfile
  tmpfile=$(mktemp)

  local payload
  payload=$(printf '{"version":"0","id":"test-%s","detail-type":"Scheduled Event","source":"aws.events","resources":["%s"],"detail":{}}' \
    "$action" "$rule_arn")

  local metadata
  metadata=$(aws lambda invoke \
    --function-name "$lambda_arn" \
    --payload "$payload" \
    --cli-binary-format raw-in-base64-out \
    --log-type Tail \
    --region "$REGION" \
    "$tmpfile" 2>&1)

  local func_error
  func_error=$(echo "$metadata" | jq -r '.FunctionError // empty')

  if [ -n "$func_error" ]; then
    fail "Lambda $action returned: $func_error"
    local logs
    logs=$(echo "$metadata" | jq -r '.LogResult // empty')
    [ -n "$logs" ] && echo "$logs" | base64 --decode
    cat "$tmpfile"
    rm -f "$tmpfile"
    return 1
  fi

  rm -f "$tmpfile"
  return 0
}

# --- Preflight ---

for cmd in terraform aws jq; do
  command -v "$cmd" >/dev/null || { red "Required: $cmd"; exit 1; }
done

aws sts get-caller-identity > /dev/null 2>&1 || { red "AWS credentials not configured"; exit 1; }

# --- Destroy-only mode ---

if [ "$DESTROY_ONLY" = true ]; then
  yellow "Destroying existing resources..."
  terraform -chdir="$SCRIPT_DIR" destroy -auto-approve -var="region=$REGION"
  exit $?
fi

# --- Main ---

trap cleanup EXIT

bold "RDS Scheduler — Integration Test"
echo "Region: $REGION"
echo ""

yellow "Step 1: Deploy (RDS instance + scheduler module)"
terraform -chdir="$SCRIPT_DIR" init -input=false -no-color 2>&1 | tail -3
terraform -chdir="$SCRIPT_DIR" apply -auto-approve -var="region=$REGION" -input=false -no-color

LAMBDA_ARN=$(terraform -chdir="$SCRIPT_DIR" output -raw lambda_arn)
STOP_ARN=$(terraform  -chdir="$SCRIPT_DIR" output -raw stop_rule_arn)
START_ARN=$(terraform -chdir="$SCRIPT_DIR" output -raw start_rule_arn)
RDS_ID=$(terraform    -chdir="$SCRIPT_DIR" output -raw rds_identifier)

echo ""
bold "Test 1: RDS instance is available after deploy"
STATUS=$(get_status "$RDS_ID")
if [ "$STATUS" = "available" ]; then
  pass "Instance is available"
else
  fail "Expected 'available', got '$STATUS'"
fi

echo ""
bold "Test 2: Stop instance via Lambda"
if invoke_lambda "$LAMBDA_ARN" "$STOP_ARN" "stop"; then
  pass "Lambda invoked successfully for stop"
else
  fail "Lambda invocation failed for stop"
fi
yellow "  Waiting for instance to stop..."
if wait_for_status "$RDS_ID" "stopped"; then
  pass "Instance stopped"
fi

echo ""
bold "Test 3: Stop is idempotent (already stopped)"
if invoke_lambda "$LAMBDA_ARN" "$STOP_ARN" "stop"; then
  pass "Lambda handled already-stopped gracefully"
fi

echo ""
bold "Test 4: Start instance via Lambda"
if invoke_lambda "$LAMBDA_ARN" "$START_ARN" "start"; then
  pass "Lambda invoked successfully for start"
else
  fail "Lambda invocation failed for start"
fi
yellow "  Waiting for instance to start..."
if wait_for_status "$RDS_ID" "available"; then
  pass "Instance started"
fi

echo ""
bold "Test 5: Start is idempotent (already running)"
if invoke_lambda "$LAMBDA_ARN" "$START_ARN" "start"; then
  pass "Lambda handled already-running gracefully"
fi
