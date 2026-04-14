# DeFCoN Addnode Quick Checker

DeFCoN Addnode Quick Checker is a lightweight helper script that lets you paste candidate addnodes into the terminal, verify that your local VPS node has reached a trusted reference block height, and quickly see which nodes are reachable and acceptable as peers. Nodes that pass are printed as `TRUSTED: IP:PORT` so they can be copied into a trusted addnode list.

## Quick start

Run this on your VPS:

```bash
sudo -u defcon bash -lc 'cd /home/defcon && rm -f dfcn-addnode-quick-check.sh && wget --no-cache -qO dfcn-addnode-quick-check.sh https://raw.githubusercontent.com/MrMarsellus/dfcn-addnode-quick-check/refs/heads/main/dfcn-addnode-quick-check.sh && chmod +x dfcn-addnode-quick-check.sh && ./dfcn-addnode-quick-check.sh'
```

Requirements:

- Working DeFCoN node with `defcon-cli`
- Linux VPS with shell access
- `wget` installed (otherwise: `sudo apt update && sudo apt install -y wget`)

## Usage

1. Run the command above.
2. Enter a trusted reference block height when asked.
3. Paste one candidate addnode per line.
4. Press Enter on an empty line to start the checks.
5. Copy all `TRUSTED: IP:PORT` lines into your trusted addnode list.

Accepted input examples:

```text
123.45.67.89
123.45.67.89:8192
node.example.com
node.example.com:8192
```

If no port is provided, the script assumes the DeFCoN default port `8192`.

## Health check criteria

The DeFCoN Addnode Quick Checker uses a strict set of health check thresholds to decide whether a candidate addnode is marked as TRUSTED or REJECTED. These parameters control how many times a node is tested, how much block-height lag is tolerated, and how conservative the ProTx-based heuristics are.

```text
TEST_ROUNDS=5                       # Number of test rounds per node
MIN_SUCCESS_ROUNDS=3                # Minimum successful rounds required for TRUSTED
MAX_HEIGHT_DIFF=10                  # Maximum allowed block-height lag vs. local node
REWARD_AGE_FACTOR=3                 # Reward age threshold factor (ENABLED * factor)
STRICT_REVIVED=0                    # 1 = reject any revived node, 0 = allow older revivals
STRICT_LASTPAID_ZERO=1              # 1 = reject nodes with lastPaidHeight = 0
MAX_OUTBOUND_SUCCESS_ELAPSED=43200  # Max age (seconds) of last outbound success
MIN_REVIVED_AGE_BLOCKS=5000         # Minimum block age since revival required
```

## Notes

- Use only a reliable reference block height (explorer or trusted node).
- A `TRUSTED` result means “reachable and acceptable under the current checks”, not a guarantee of long-term stability.
- Re-run the script periodically if you maintain a long-lived trusted addnode list.
