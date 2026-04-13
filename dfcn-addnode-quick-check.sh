#!/usr/bin/env bash
set -euo pipefail

CLI="/usr/local/bin/defcon-cli"
DATADIR="/home/defcon/.defcon"
CONF="/home/defcon/.defcon/defcon.conf"

# Max seconds for low-level TCP connect check (per attempt)
MAX_SECONDS=5
# Sleep after addnode onetry before inspecting getpeerinfo
PEER_SLEEP=3
# How many test rounds per node
TEST_ROUNDS=3
# Minimum rounds that must pass for a node to be considered trusted
MIN_SUCCESS_ROUNDS=2
# Allowed height difference between local and peer
MAX_HEIGHT_DIFF=2
# Default DeFCoN masternode port
DEFAULT_PORT="8192"

# Reward age factor:
# max_reward_age = ENABLED_MN_COUNT * REWARD_AGE_FACTOR
REWARD_AGE_FACTOR="3"

# If set to 1, ANY revived node is rejected.
# If set to 0, revived nodes are allowed, but see MIN_REVIVED_AGE_BLOCKS below.
STRICT_REVIVED="0"

# If set to 1, nodes with lastPaidHeight = 0 are rejected.
STRICT_LASTPAID_ZERO="1"

# Maximum allowed age (seconds) of lastOutboundSuccessElapsed
# (older values indicate potentially stale / unhealthy peers)
MAX_OUTBOUND_SUCCESS_ELAPSED="21600"

# Minimum block age for revived masternodes:
# nodes revived more recently than this many blocks are rejected.
# This allows old, stable revivals but filters very recent revivals.
MIN_REVIVED_AGE_BLOCKS="5000"

run_cli() {
  "$CLI" -datadir="$DATADIR" -conf="$CONF" "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_number() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

normalize_node() {
  local node="$1"
  if [[ "$node" != *:* ]]; then
    echo "${node}:${DEFAULT_PORT}"
  else
    echo "$node"
  fi
}

get_local_height() {
  local h
  h="$(run_cli getblockcount 2>/dev/null || true)"
  is_number "$h" || return 1
  echo "$h"
}

check_local_reference_height() {
  local reference_height
  local local_height

  echo "Reference block height check"
  echo "----------------------------"
  echo "This script keeps your manual reference block height check."
  echo "It also adds stricter trusted-node filters using masternodelist and protx."
  echo
  echo "Please enter a trusted reference block height"
  echo "(for example from the official explorer or another trusted synced node)."
  echo

  read -r -p "Reference block height: " reference_height

  if ! is_number "$reference_height"; then
    echo "Invalid block height. Please enter a numeric value."
    exit 1
  fi

  local_height="$(get_local_height || echo "")"

  if ! is_number "$local_height"; then
    echo "Could not read local block height from defcon-cli."
    exit 1
  fi

  echo
  echo "Local block height     : $local_height"
  echo "Reference block height : $reference_height"
  echo

  if (( local_height < reference_height )); then
    echo "Your local node has not yet reached the reference block height."
    echo "Please wait until your VPS node is fully synced before testing addnodes."
    exit 1
  fi

  echo "OK: Your local node has reached the reference block height."
  echo
}

get_peer_json_by_host() {
  local host="$1"
  run_cli getpeerinfo 2>/dev/null | jq -c --arg host "$host" '
    .[] | select(
      (.addr? | tostring | startswith($host + ":")) or
      (.addrbind? | tostring | contains($host)) or
      (.addrlocal? | tostring | contains($host))
    )' | head -n 1
}

check_tcp_port() {
  local host="$1"
  local port="$2"

  if timeout "$MAX_SECONDS" bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
    echo "  - Port check: OK"
    return 0
  else
    echo "  - Port check: FAILED"
    return 1
  fi
}

check_peer_connection() {
  local node="$1"
  local host="${node%:*}"
  local local_height peer_json peer_height pingtime

  local_height="$(get_local_height || echo "")"
  if ! is_number "$local_height"; then
    echo "  - Local height read: FAILED"
    return 1
  fi

  run_cli addnode "$node" onetry >/dev/null 2>&1 || true
  sleep "$PEER_SLEEP"

  peer_json="$(get_peer_json_by_host "$host" 2>/dev/null || true)"
  if [[ -z "$peer_json" ]]; then
    echo "  - Peer check: FAILED (node did not appear in getpeerinfo)"
    return 1
  fi

  peer_height="$(jq -r '.synced_headers // .startingheight // .synced_blocks // empty' <<< "$peer_json" 2>/dev/null)"
  pingtime="$(jq -r '.pingtime // empty' <<< "$peer_json" 2>/dev/null)"

  if is_number "$peer_height"; then
    echo "  - Peer height: $peer_height"
    if (( peer_height + MAX_HEIGHT_DIFF < local_height )); then
      echo "  - Height plausibility: FAILED (peer lags too far behind local height $local_height)"
      return 1
    fi
  else
    echo "  - Peer height: UNKNOWN"
  fi

  [[ -n "$pingtime" && "$pingtime" != "null" ]] && echo "  - Ping time: $pingtime"
  echo "  - Peer check: OK"
  return 0
}

get_enabled_count() {
  local count
  count="$(run_cli masternodelist status 2>/dev/null | grep -o 'ENABLED' | wc -l | tr -d ' ')"
  is_number "$count" || return 1
  echo "$count"
}

get_masternodelist_full_line() {
  local node="$1"
  run_cli masternodelist full "$node" 2>/dev/null \
    | jq -r 'to_entries[]? | .value' 2>/dev/null \
    | grep -F " $node" \
    | head -n 1
}

check_masternodelist_status() {
  local node="$1"
  local status_json status_word

  status_json="$(run_cli masternodelist status "$node" 2>/dev/null || true)"

  if [[ -z "$status_json" || "$status_json" == "{}" ]]; then
    echo "  - Masternodelist status: UNKNOWN"
    return 2
  fi

  status_word="$(echo "$status_json" | grep -Eo 'ENABLED|POSE_BANNED' | head -n 1 || true)"

  if [[ "$status_word" == "POSE_BANNED" ]]; then
    echo "  - Masternodelist status: FAILED (POSE_BANNED)"
    return 1
  elif [[ "$status_word" == "ENABLED" ]]; then
    echo "  - Masternodelist status: OK (ENABLED)"
    return 0
  else
    echo "  - Masternodelist status: UNKNOWN"
    return 2
  fi
}

check_masternodelist_full_heuristics() {
  local node="$1"
  local full_line last_paid_block

  full_line="$(get_masternodelist_full_line "$node")"

  if [[ -z "$full_line" ]]; then
    echo "  - Masternodelist full: UNKNOWN"
    return 2
  fi

  echo "  - Masternodelist full: $full_line"

  if grep -q 'POSE_BANNED' <<< "$full_line"; then
    echo "  - Masternodelist full check: FAILED (POSE_BANNED)"
    return 1
  fi

  last_paid_block="$(awk '{print $(NF-1)}' <<< "$full_line" 2>/dev/null || true)"

  if is_number "$last_paid_block"; then
    echo "  - lastpaidblock (masternodelist full): $last_paid_block"
    if (( STRICT_LASTPAID_ZERO == 1 )) && (( last_paid_block == 0 )); then
      echo "  - Masternodelist reward heuristic: FAILED (lastpaidblock = 0)"
      return 1
    fi
  fi

  return 0
}

get_protx_match() {
  local node="$1"
  run_cli protx list registered true 2>/dev/null \
    | jq -c --arg node "$node" '.[] | select((.state.service // "") == $node)' \
    | head -n 1
}

check_protx_pose_and_health() {
  local node="$1"
  local enabled_count="$2"
  local local_height="$3"
  local match penalty ban_height revived_height last_paid_height outbound_success_elapsed revocation_reason
  local max_reward_age delta_blocks revived_age

  match="$(get_protx_match "$node")"

  if [[ -z "$match" ]]; then
    echo "  - ProTx lookup: UNKNOWN (service not found)"
    return 2
  fi

  penalty="$(jq -r '.state.PoSePenalty // 0' <<< "$match")"
  ban_height="$(jq -r '.state.PoSeBanHeight // -1' <<< "$match")"
  revived_height="$(jq -r '.state.PoSeRevivedHeight // -1' <<< "$match")"
  last_paid_height="$(jq -r '.state.lastPaidHeight // 0' <<< "$match")"
  outbound_success_elapsed="$(jq -r '.metaInfo.lastOutboundSuccessElapsed // 0' <<< "$match")"
  revocation_reason="$(jq -r '.state.revocationReason // 0' <<< "$match")"

  echo "  - ProTx PoSePenalty            : $penalty"
  echo "  - ProTx PoSeBanHeight          : $ban_height"
  echo "  - ProTx PoSeRevivedHeight      : $revived_height"
  echo "  - ProTx lastPaidHeight         : $last_paid_height"
  echo "  - ProTx lastOutboundSuccessElapsed: $outbound_success_elapsed"
  echo "  - ProTx revocationReason       : $revocation_reason"

  if is_number "$penalty" && (( penalty > 0 )); then
    echo "  - ProTx PoSe check: FAILED (PoSePenalty > 0)"
    return 1
  fi

  if is_number "$ban_height" && (( ban_height > 0 )); then
    echo "  - ProTx PoSe check: FAILED (PoSeBanHeight > 0)"
    return 1
  fi

  if is_number "$revocation_reason" && (( revocation_reason > 0 )); then
    echo "  - ProTx revocation check: FAILED (revocationReason > 0)"
    return 1
  fi

  # Revived masternodes:
  # - STRICT_REVIVED=1 → reject any revival
  # - STRICT_REVIVED=0 → only reject if revival is too recent (younger than MIN_REVIVED_AGE_BLOCKS)
  if [[ "$revived_height" != "-1" && "$revived_height" != "0" ]]; then
    if (( STRICT_REVIVED == 1 )); then
      echo "  - ProTx revived check: FAILED (node was revived before - strict mode)"
      return 1
    else
      if is_number "$revived_height"; then
        revived_age=$(( local_height - revived_height ))
        echo "  - ProTx revived age blocks     : $revived_age"
        echo "  - ProTx revived min age blocks : $MIN_REVIVED_AGE_BLOCKS"
        if (( revived_age < MIN_REVIVED_AGE_BLOCKS )); then
          echo "  - ProTx revived check: FAILED (revived too recently)"
          return 1
        else
          echo "  - ProTx revived note: old revival accepted"
        fi
      else
        echo "  - ProTx revived note: non-numeric revived height, ignoring"
      fi
    fi
  fi

  if is_number "$last_paid_height"; then
    if (( STRICT_LASTPAID_ZERO == 1 )) && (( last_paid_height == 0 )); then
      echo "  - Reward age check: FAILED (lastPaidHeight = 0)"
      return 1
    fi

    if (( last_paid_height > 0 )) && (( enabled_count > 0 )); then
      delta_blocks=$(( local_height - last_paid_height ))
      max_reward_age=$(( enabled_count * REWARD_AGE_FACTOR ))
      echo "  - Reward age delta blocks      : $delta_blocks"
      echo "  - Reward age max allowed       : $max_reward_age"

      if (( delta_blocks > max_reward_age )); then
        echo "  - Reward age check: FAILED (too many blocks since last payment)"
        return 1
      fi
    fi
  fi

  if is_number "$outbound_success_elapsed" && (( outbound_success_elapsed > MAX_OUTBOUND_SUCCESS_ELAPSED )); then
    echo "  - Outbound success age check: FAILED (too old)"
    return 1
  fi

  echo "  - ProTx health check: OK"
  return 0
}

test_node_once() {
  local node="$1"
  local host="${node%:*}"
  local port="${node##*:}"
  local enabled_count local_height

  echo "Testing $node"

  local_height="$(get_local_height || echo "")"
  enabled_count="$(get_enabled_count || echo "0")"

  if ! is_number "$local_height"; then
    echo "  - Local height read: FAILED"
    return 1
  fi

  if ! is_number "$enabled_count"; then
    enabled_count=0
  fi

  echo "  - Local height: $local_height"
  echo "  - ENABLED masternodes: $enabled_count"

  check_tcp_port "$host" "$port" || return 1
  check_peer_connection "$node" || return 1

  check_masternodelist_status "$node"
  case $? in
    1) return 1 ;;
    0|2) ;;
  esac

  check_masternodelist_full_heuristics "$node"
  case $? in
    1) return 1 ;;
    0|2) ;;
  esac

  check_protx_pose_and_health "$node" "$enabled_count" "$local_height"
  case $? in
    1) return 1 ;;
    0|2) ;;
  esac

  return 0
}

main() {
  need_cmd bash
  need_cmd grep
  need_cmd awk
  need_cmd jq
  need_cmd timeout
  need_cmd wc

  echo "DeFCoN Strict Trusted Addnode Checker"
  echo "-------------------------------------"
  echo "This script:"
  echo "  1) Keeps your manual reference block height check"
  echo "  2) Tests TCP reachability on port 8192"
  echo "  3) Verifies peer visibility in getpeerinfo"
  echo "  4) Rejects POSE_BANNED nodes"
  echo "  5) Rejects nodes with PoSePenalty > 0 or PoSeBanHeight > 0"
  echo "  6) Rejects suspiciously old reward history"
  echo "  7) Rejects stale outbound-success metadata"
  echo "  8) Filters out recently revived masternodes"
  echo
  echo "Config:"
  echo "  TEST_ROUNDS=$TEST_ROUNDS            # how many test rounds per node"
  echo "  MIN_SUCCESS_ROUNDS=$MIN_SUCCESS_ROUNDS # min rounds that must pass"
  echo "  REWARD_AGE_FACTOR=$REWARD_AGE_FACTOR    # reward-age sensitivity"
  echo "  STRICT_REVIVED=$STRICT_REVIVED          # 1=reject any revival, 0=allow old revivals"
  echo "  MIN_REVIVED_AGE_BLOCKS=$MIN_REVIVED_AGE_BLOCKS  # min block age for accepted revivals"
  echo "  STRICT_LASTPAID_ZERO=$STRICT_LASTPAID_ZERO      # 1=reject lastPaidHeight=0"
  echo "  MAX_OUTBOUND_SUCCESS_ELAPSED=$MAX_OUTBOUND_SUCCESS_ELAPSED # max age of outbound success"
  echo

  check_local_reference_height

  echo "Paste your addnodes now."
  echo "One addnode per line. Empty line starts the checks."
  echo

  local line node round success
  local -a nodes=()

  while true; do
    if ! read -r line; then
      break
    fi

    line="${line%%#*}"
    line="$(trim "$line")"

    [[ -z "$line" ]] && break

    node="$(normalize_node "$line")"

    if ! [[ "$node" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]]; then
      echo "Skipping invalid format: $node"
      continue
    fi

    nodes+=("$node")
  done

  echo
  echo "Starting checks..."
  echo

  for node in "${nodes[@]}"; do
    success=0

    for ((round=1; round<=TEST_ROUNDS; round++)); do
      echo "Round $round/$TEST_ROUNDS"
      if test_node_once "$node"; then
        success=$((success + 1))
      fi
      echo
    done

    if (( success >= MIN_SUCCESS_ROUNDS )); then
      echo "TRUSTED: $node"
    else
      echo "REJECT:  $node"
    fi

    echo "------------------------------------------------------------"
  done

  echo
  echo "Done."
  echo "Copy all lines starting with 'TRUSTED:' as your trusted addnodes."
}
main "$@"
