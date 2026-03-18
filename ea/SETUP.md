# ForexAI EA Setup Guide

## Step 1 - Replit Setup

1. Create a new Replit from this repo (Python template)
2. Add Secret: ANTHROPIC_API_KEY = your key from console.anthropic.com
3. Click Run, note your URL (e.g. https://forexai.yourname.replit.app)
4. Enable Always On in Replit settings

## Step 2 - MetaTrader Setup

### Allow WebRequest (CRITICAL)

MT5: Tools > Options > Expert Advisors > Allow WebRequest for listed URL
Add: https://YOUR-REPLIT-URL.replit.app

MT4: Same path, also tick Allow DLL imports

### Install EA

1. File > Open Data Folder > MQL5 (or MQL4) > Experts
2. Copy ForexAI_EA.mq5 (or .mq4) into that folder
3. Navigator > Expert Advisors > right-click > Refresh
4. Drag EA onto any chart

### Configure Parameters

- InpApiUrl: https://YOUR-REPLIT-URL.replit.app/signal
- InpRiskPct: 1.0 (1% per trade)
- InpMaxLot: 1.0
- InpIntervalMin: 60
- InpEnableTrading: true

## Guardrails Built In

- Skips weekends
- Skips high-impact news within 2 hours
- Max 1 position per symbol
- Min 65% confidence threshold
- TP always >= 1.8x SL

## Troubleshooting

Error 4060: URL not whitelisted in MT Options
Error 5: Replit sleeping, enable Always On
No trades: Check /dashboard for Claude reasoning
