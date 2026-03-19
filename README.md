# ForexAI EA v2.1 — MT5 only

Autonomous Forex EA powered by Claude AI.

## Architecture

- H1 boundary: EA calls Flask, Claude analyses D1/H4/H1/M15 top-down
- M15 local: EA checks news, spread, watch level — no API call
- Momentum trades (market orders) + Level trades (limit orders)
- Progressive risk, partial close, H1 trailing, 5 position cap

## Setup

See ea/SETUP.md
