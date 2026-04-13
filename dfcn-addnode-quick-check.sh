#!/usr/bin/env bash
set -u
set -o pipefail

CLI="/usr/local/bin/defcon-cli"
DATADIR="/home/defcon/.defcon"
CONF="/home/defcon/.defcon/defcon.conf"
MAX_SECONDS=5
PEER_SLEEP=3
TEST_ROUNDS=2
MIN_SUCCESS_ROUNDS=2
MAX_HEIGHT_DIFF=2
DEFAULT_PORT="8192"

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
  h="$(run_cli getblockcount 2>/dev/null || echo "")"
  if ! is_number "$h"; then
    return 1
  fi
  echo "$h"
}

check_local_reference_height() {
  local reference_height
  local local_height

  echo "Reference block height check"
  echo "----------------------------"
  echo "This script keeps your manual reference height check."
  echo "Additionally, it will use masternodelist/protx data for PoSe filtering."
  echo
  echo "Please enter a trusted reference block height"
  echo "(for example from the official explorer or another trusted synced node)."
  echo

  read -r -p "Reference block height: " reference_height

  if ! is_number "$reference_height"; then
    echo "Invalid block height. Please enter a numeric value."
    exit 1
  fi

  local_height="$(get_local_height 2>/dev/null || echo "")"

  if ! is_number "$local_height"; then
    echo "Could not read local block height from defcon-cli."
    exit 1
  fi

  echo
  echo "Local block height     : $local_height"
  echo "Reference block height : $reference_height"
  echo

  if [ "$local_height" -lt "$reference_height" ]; then
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

check_peer_connection() {
  local node="$1"
  local host="${node%:*}"
  local local_height peer_json peer_height

  local_height="$(get_local_height 2>/dev/null || echo "")"
  if ! is_number "$local_height"; then
    echo "  - Local height read: FAILED"
    return 1
  fi

  run_cli addnode "$node" onetry >/dev/null 2>&1 || true
  sleep "$PEER_SLEEP"

  peer_json="$(get_peer_json_by_host "$host" 2>/dev/null || echo "")"
  if [[ -z "$peer_json" ]]; then
    echo "  - Peer check: FAILED (node did not appear in getpeerinfo)"
    return 1
  fi

  peer_height="$(jq -r '.synced_headers // .startingheight // empty' <<< "$peer_json" 2>/dev/null)"
  if is_number "$peer_height"; then
    echo "  - Peer height: $peer_height"
    if (( peer_height + MAX_HEIGHT_DIFF < local_height )); then
      echo "  - Height plausibility: FAILED (peer lags too far behind local height $local_height)"
      return 1
    fi
  else
    echo "  - Peer height: UNKNOWN"
  fi

  echo "  - Peer check: OK"
  return 0
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

check_masternodelist_status() {
  local node="$1"
  local status_line
  local status_word

  status_line="$(run_cli masternodelist status "$node" 2>/dev/null || echo "")"

  if [[ -z "$status_line" || "$status_line" == "{}" ]]; then
    echo "  - Masternodelist status: UNKNOWN"
    return 2
  fi

  status_word="$(echo "$status_line" | grep -Eo 'ENABLED|POSE_BANNED' | head -n 1)"

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

check_protx_pose() {
  local node="$1"
  local protx_json match penalty ban_height revived_height

  protx_json="$(run_cli protx list registered true 2>/dev/null || echo "")"
  if [[ -z "$protx_json" ]]; then
    echo "  - ProTx lookup: UNKNOWN"
    return 2
  fi

  match="$(jq -c --arg node "$node" '.[] | select((.state.service // "") == $node)' <<< "$protx_json" 2>/dev/null | head -n 1)"

  if [[ -z "$match" ]]; then
    echo "  - ProTx lookup: UNKNOWN (service not found)"
    return 2
  fi

  penalty="$(jq -r '.state.PoSePenalty // 0' <<< "$match" 2>/dev/null)"
  ban_height="$(jq -r '.state.PoSeBanHeight // -1' <<< "$match" 2>/dev/null)"
  revived_height="$(jq -r '.state.PoSeRevivedHeight // -1' <<< "$match" 2>/dev/null)"

  echo "  - ProTx PoSePenalty     : $penalty"
  echo "  - ProTx PoSeBanHeight   : $ban_height"
  echo "  - ProTx PoSeRevivedHeight: $revived_height"

  if is_number "$penalty" && (( penalty > 0 )); then
    echo "  - ProTx PoSe check: FAILED (PoSePenalty > 0)"
    return 1
  fi

  if is_number "$ban_height" && (( ban_height > 0 )); then
    echo "  - ProTx PoSe check: FAILED (PoSeBanHeight > 0)"
    return 1
  fi

  if [[ "$revived_height" != "-1" && "$revived_height" != "0" ]]; then
    echo "  - ProTx PoSe note: node was revived before"
  fi

  echo "  - ProTx PoSe check: OK"
  return 0
}

test_node_once() {
  local node="$1"
  local host="${node%:*}"
  local port="${node##*:}"

  echo "Testing $node"

  check_tcp_port "$host" "$port" || return 1
  check_peer_connection "$node" || return 1

  check_masternodelist_status "$node"
  case $? in
    1) return 1 ;;
    0|2) ;;
  esac

  check_protx_pose "$node"
  case $? in
    1) return 1 ;;
    0|2) ;;
  esac

  return 0
}

main() {
  need_cmd bash
  need_cmd grep
  need_cmd jq
  need_cmd timeout

  echo "DeFCoN Trusted Addnode Checker"
  echo "------------------------------"
  echo "This script:"
  echo "  1) Keeps your manual reference block height check"
  echo "  2) Tests candidate addnodes for reachability"
  echo "  3) Checks whether they appear as peers"
  echo "  4) Uses masternodelist/protx to reject PoSe-problem nodes"
  echo
  echo "Expected addnode format:"
  echo "  IP:PORT"
  echo "  HOSTNAME:PORT"
  echo
  echo "Default DeFCoN port: 8192"
  echo

  check_local_reference_height

  echo "Paste your addnodes now."
  echo "When you are done, press ENTER on an empty line to start the checks."
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

    if ! echo "$node" | grep -Eq '^[a-zA-Z0-9._-]+:[0-9]+$'; then
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
