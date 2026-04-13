#!/usr/bin/env bash
set -u

CLI="/usr/local/bin/defcon-cli"
DATADIR="/home/defcon/.defcon"
CONF="/home/defcon/.defcon/defcon.conf"
MAX_SECONDS=5

run_cli() {
  "$CLI" -datadir="$DATADIR" -conf="$CONF" "$@"
}

check_local_reference_height() {
  local reference_height
  local local_height

  echo "Reference block height check"
  echo "----------------------------"
  echo "Before testing addnodes, this script checks whether your local DeFCoN node"
  echo "has already reached the reference block height you provide."
  echo
  echo "Please enter a trusted reference block height"
  echo "(for example from the official explorer or another trusted synced node)."
  echo

  read -r -p "Reference block height: " reference_height

  if ! echo "$reference_height" | grep -Eq '^[0-9]+$'; then
    echo "Invalid block height. Please enter a numeric value."
    exit 1
  fi

  local_height="$(run_cli getblockcount 2>/dev/null || echo "")"

  if ! echo "$local_height" | grep -Eq '^[0-9]+$'; then
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

check_node() {
  local node="$1"
  local host="${node%:*}"
  local port="${node##*:}"

  echo "Testing $node"

  if ! timeout "$MAX_SECONDS" bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
    echo "  - Port check: FAILED (port is not reachable)"
    return 1
  fi
  echo "  - Port check: OK"

  run_cli addnode "$node" onetry >/dev/null 2>&1 || true
  sleep 3

  if run_cli getpeerinfo 2>/dev/null | grep -q "$host"; then
    echo "  - Peer check: OK (node accepted as peer)"
    echo "GOOD: $node"
    return 0
  else
    echo "  - Peer check: FAILED (node did not appear in getpeerinfo)"
    return 1
  fi
}

main() {
  echo "DeFCoN Addnode Quick Checker"
  echo "----------------------------"
  echo "This helper checks candidate addnodes using your local DeFCoN node."
  echo
  echo "What this script does:"
  echo "  1) Ask for a trusted reference block height"
  echo "  2) Check whether your local node has already reached that height"
  echo "  3) Let you paste candidate addnodes into the terminal"
  echo "  4) Test whether each addnode is reachable and can be seen as a peer"
  echo
  echo "Expected addnode format:"
  echo "  IP:PORT"
  echo "  HOSTNAME:PORT"
  echo
  echo "Examples:"
  echo "  91.98.81.203:8192"
  echo "  node1.example.com:8192"
  echo "  203.0.113.10:8192"
  echo
  echo "Notes:"
  echo "  - One addnode per line"
  echo "  - Empty lines and comment lines will be ignored"
  echo "  - This script does not write any files"
  echo "  - Nodes that pass the checks will be printed as: GOOD: IP:PORT"
  echo

  check_local_reference_height

  echo "Paste your addnodes now."
  echo "When you are done, press ENTER on an empty line to start/finish the checks."
  echo

  local line

  while true; do
    if ! read -r line; then
      break
    fi

    if [[ -z "$line" ]]; then
      break
    fi

    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue

    if ! echo "$line" | grep -Eq '^[a-zA-Z0-9._-]+:[0-9]+$'; then
      echo "Skipping invalid format: $line (expected IP:PORT or HOSTNAME:PORT)"
      echo
      continue
    fi

    check_node "$line"
    echo
  done

  echo "Done."
  echo "Copy all lines starting with 'GOOD:' from the output as your good addnodes."
}

main "$@"
