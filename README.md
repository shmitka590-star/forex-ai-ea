# ForexAI EA

Autonomous Forex Expert Advisor powered by Claude AI.

- **Backend**: Python / Flask on Replit
- **Brain**: Claude analyses EURUSD, GBPUSD, USDJPY and picks the clearest setup
- **News filter**: Skips trades during high-impact economic events (ForexFactory calendar)
- **Execution**: MQL4/MQL5 EA places trades directly in MetaTrader

## Quick Start

1. Deploy `main.py` on Replit, add `ANTHROPIC_API_KEY` secret
1. Install `ForexAI_EA.mq5` (or `.mq4`) in MetaTrader
1. Whitelist your Replit URL in MT Tools > Options > Expert Advisors
1. Set `InpApiUrl` in EA parameters to your Replit URL
1. Enable Auto Trading and attach EA to any chart

See `ea/SETUP.md` for full instructions.

## Stack

| Layer  | Tech                         |
|--------|------------------------------|
| EA     | MQL5 / MQL4                  |
| API    | Flask + Anthropic            |
| DB     | Replit DB                    |
| News   | ForexFactory calendar (free) |
| Hosting| Replit Always On             |
