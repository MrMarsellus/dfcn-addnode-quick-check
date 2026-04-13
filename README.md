# DeFCoN Addnode Quick Checker

DeFCoN Addnode Quick Checker is a lightweight helper script that lets you paste candidate addnodes into the terminal, verify that your local VPS node has reached a trusted reference block height, and quickly see which nodes are reachable and acceptable as peers. Nodes that pass are printed as `GOOD: IP:PORT` so they can be copied into a trusted addnode list.

## Quick start

Run this on your VPS:

```bash
sudo -u defcon bash -lc 'cd /home/defcon && wget -qO dfcn-addnode-quick-check.sh https://raw.githubusercontent.com/MrMarsellus/dfcn-addnode-quick-check/refs/heads/main/dfcn-addnode-quick-check.sh && chmod +x dfcn-addnode-quick-check.sh && ./dfcn-addnode-quick-check.sh'
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
5. Copy all `GOOD: IP:PORT` lines into your trusted addnode list.

Accepted input examples:

```text
123.45.67.89
123.45.67.89:8192
node.example.com
node.example.com:8192
```

If no port is provided, the script assumes the DeFCoN default port `8192`.

## Notes

- Use only a reliable reference block height (explorer or trusted node).
- A `GOOD` result means “reachable and acceptable now”, not a guarantee of long-term stability.
- Re-run the script periodically if you maintain a long-lived trusted addnode list.
