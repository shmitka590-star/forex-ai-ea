# ForexAI EA v2 -- Setup Guide

## Architecture

```
MetaTrader on your laptop
  └── EA fires on every new M15 candle
        └── POST to http://localhost:5000/signal
              └── Flask reads D1/H4/H1/M15 data
              └── Claude does top-down analysis
              └── Returns: entry, SL, TP1, TP2
        └── EA executes trade
        └── EA manages: partial close at TP1, breakeven, H1 trailing
```

## Step 1 -- Run Flask (do this first)

1. Open Command Prompt
2. cd into the forex-ai-ea folder
3. Double-click run.bat (or: python main.py)
4. Enter your Anthropic API key when prompted
5. Visit http://localhost:5000/health -- should return {"status":"ok"}
6. Visit http://localhost:5000/dashboard -- signal history

## Step 2 -- MetaTrader Setup

### Allow WebRequest (CRITICAL -- do this or EA cannot call Flask)

MT5: Tools > Options > Expert Advisors > Allow WebRequest for listed URL
Add: http://localhost:5000

MT4: Same path, also tick Allow DLL imports

### Install EA

1. File > Open Data Folder > MQL5 (or MQL4) > Experts
2. Copy ForexAI_EA.mq5 (or .mq4) into that folder
3. Navigator > Expert Advisors > right-click > Refresh
4. Drag EA onto any chart (EURUSD recommended)
5. Set InpApiUrl = http://localhost:5000/signal
6. Enable Auto Trading button (must be green)

## EA Parameters

| Parameter        | Default                      | Description             |
|------------------|------------------------------|-------------------------|
| InpApiUrl        | http://localhost:5000/signal | Flask endpoint          |
| InpBaseRiskPct   | 1.0                          | Base risk % per trade   |
| InpMaxLot        | 2.0                          | Maximum lot size        |
| InpMinLot        | 0.01                         | Minimum lot size        |
| InpMaxTrades     | 3                            | Max simultaneous trades |
| InpMinConfidence | 70                           | Min Claude confidence   |
| InpSymbols       | EURUSD,GBPUSD,USDJPY         | Pairs to analyse        |

## How Trades Are Managed

1. Entry: at M15 candle open price
2. SL: placed by Claude below/above M15 swing structure
3. TP1 (1.5R): 50% of position closed, SL moved to breakeven
4. TP2 (3.0R): remaining 50% closed (hard TP)
5. Trailing: after TP1, SL trails using H1 candle lows/highs

## Progressive Risk

| Condition      | Risk %      |
|----------------|-------------|
| Default        | 1.0% (base) |
| 3-4 win streak | 1.25%       |
| 5+ win streak  | 1.5%        |
| 1 loss         | 0.75%       |
| 2 losses       | 0.5%        |
| 3 losses       | HALTED      |
| 5% drawdown    | 0.5%        |
| 10% drawdown   | HALTED      |

## Start on DEMO Account

Always run on a demo account first for at least 2 weeks.
Confirm signal quality at http://localhost:5000/dashboard before going live.

## Troubleshooting

Error 4060 in Experts log: URL not whitelisted (Step 2 above)
No signals firing: Check if Flask is running (http://localhost:5000/health)
Trade not executing: Check Auto Trading button is green in MT toolbar
