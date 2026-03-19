# ForexAI EA v2.1 — Setup Guide

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Installation](#2-installation)
3. [Running the Python Server](#3-running-the-python-server)
4. [MetaTrader 5 Configuration](#4-metatrader-5-configuration)
5. [Installing the EA](#5-installing-the-ea)
6. [Input Parameters](#6-input-parameters)
7. [Testing Phases](#7-testing-phases)
8. [How the EA Works](#8-how-the-ea-works)
9. [Trade Management](#9-trade-management)
10. [Risk Table](#10-risk-table)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Prerequisites

| Requirement | Minimum version | Notes |
|-------------|-----------------|-------|
| Python | 3.10+ | [python.org/downloads](https://www.python.org/downloads/) |
| MetaTrader 5 | Build 4000+ | IC Markets Raw Spread account recommended |
| Anthropic API key | — | [console.anthropic.com](https://console.anthropic.com/) |
| Git | any | [git-scm.com](https://git-scm.com/) |

### Getting an Anthropic API key

1. Go to [console.anthropic.com](https://console.anthropic.com/) and sign in.
2. Navigate to **API Keys** → **Create Key**.
3. Copy the key (starts with `sk-ant-`). You will paste it when `run.bat` prompts you, or set it as an environment variable beforehand:

```bat
setx ANTHROPIC_API_KEY "sk-ant-your-key-here"
```

---

## 2. Installation

```bat
git clone https://github.com/your-org/forex-ai-ea.git
cd forex-ai-ea
```

The repository structure:

```
forex-ai-ea/
├── main.py            # Flask signal server
├── requirements.txt   # Python dependencies
├── run.bat            # One-click launcher (Windows)
├── ea/
│   ├── ForexAI_EA.mq5 # Expert Advisor source
│   └── SETUP.md       # This file
└── templates/
    └── dashboard.html # Web dashboard
```

Dependencies installed automatically by `run.bat`:

```
flask==3.0.3
anthropic==0.34.2
requests==2.32.3
gunicorn==22.0.0
```

---

## 3. Running the Python Server

Double-click **`run.bat`** or run from a terminal:

```bat
cd forex-ai-ea
run.bat
```

`run.bat` will:
1. Prompt for your Anthropic API key if `ANTHROPIC_API_KEY` is not already set.
2. Run `pip install -r requirements.txt`.
3. Start the Flask server on `http://localhost:5000`.

**The server must be running whenever MT5 is active.** Keep the terminal window open.

### Available endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/signal` | POST | Receives EA payload, returns signal JSON |
| `/health` | GET | Server status check |
| `/history` | GET | Last 100 signal records |
| `/stats` | GET | Aggregate trade statistics |
| `/dashboard` | GET | Web dashboard UI |

Verify the server is running:

```bat
curl http://localhost:5000/health
```

Expected response: `{"status": "ok", "version": "2.1", "utc": "..."}`

---

## 4. MetaTrader 5 Configuration

### Enable WebRequest for localhost

The EA calls `http://localhost:5000/signal` on every H1 boundary. MT5 blocks all web requests by default.

1. In MT5 go to **Tools → Options → Expert Advisors**.
2. Check **Allow WebRequest for listed URL**.
3. Click **Add** and enter exactly:
   ```
   http://localhost:5000
   ```
4. Click **OK**.

> Without this step the EA logs `[API] Error 4014` and no signals are received.

### Enable automated trading

- Click the **Algo Trading** button in the MT5 toolbar (must be green/enabled).
- Ensure the EA is not paused at the chart level (smiley face icon should be active in the top-right corner of the chart).

---

## 5. Installing the EA

1. Copy `ea/ForexAI_EA.mq5` to your MT5 data folder:

   ```
   %APPDATA%\MetaQuotes\Terminal\<instance-id>\MQL5\Experts\
   ```

   Or in MT5: **File → Open Data Folder → MQL5 → Experts**, then paste the file.

2. Open **MetaEditor** (F4 in MT5) and compile `ForexAI_EA.mq5`. Ensure zero errors.

3. In MT5, open a chart for any of the three pairs (EURUSD recommended). Timeframe does not matter — the EA manages its own H1/M15 schedule internally.

4. Drag **ForexAI_EA** from the Navigator panel onto the chart.

5. In the EA settings dialog, confirm inputs (see section 6) then click **OK**.

6. The EA prints its startup banner to the **Experts** tab:
   ```
   ForexAI v2.1 | Magic:771234 | Risk:1.0% | MaxPos:5 | Micro:OFF
   ```

---

## 6. Input Parameters

### API group

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpApiUrl` | `http://localhost:5000/signal` | Flask server endpoint. Do not change unless hosting remotely. |
| `InpTimeoutMs` | `12000` | HTTP request timeout in milliseconds. Increase on slow connections. |

### Risk group

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpBaseRisk` | `1.0` | Base risk per trade as a percentage of account balance. |
| `InpMaxLot` | `2.0` | Hard ceiling on lot size regardless of calculation. |
| `InpMinLot` | `0.01` | Minimum lot size; also used in MicroMode. |
| `InpMagic` | `771234` | Unique magic number. Change only if running multiple EA instances. |
| `InpMaxPositions` | `5` | Maximum combined open positions and pending orders. |

### Filters group

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpEnabled` | `true` | Master on/off switch. Set to `false` to pause without removing the EA. |
| `InpMicroMode` | `false` | Forces `InpMinLot` (0.01) on every trade, ignoring risk calculation. Use for live week 3+ initial phase. |
| `InpSymbols` | `EURUSD,GBPUSD,USDJPY` | Comma-separated list of pairs to analyse and trade. |
| `InpMinConf` | `70` | Minimum Claude confidence score (0–100) required to act on a signal. |
| `InpMaxSpreadEURUSD` | `1.2` | Maximum allowed spread in pips for EURUSD before skipping entry. |
| `InpMaxSpreadGBPUSD` | `1.5` | Maximum allowed spread in pips for GBPUSD before skipping entry. |
| `InpMaxSpreadUSDJPY` | `1.2` | Maximum allowed spread in pips for USDJPY before skipping entry. |
| `InpMaxWatchDist` | `10.0` | Maximum distance in pips between current price and watch level for M15 trigger to fire. |

---

## 7. Testing Phases

### Phase 1 — Demo account (weeks 1–2)

| Setting | Value |
|---------|-------|
| Account type | Demo |
| `InpMicroMode` | `false` |
| `InpBaseRisk` | `1.0` |
| `InpMaxLot` | `2.0` |

Run on a demo account with normal risk calculation for at least two full trading weeks (Monday open to Friday close). Goals:

- Confirm server connectivity — check the **Experts** tab for `[H1] API call` and `[API] HTTP 200` every hour.
- Verify limit orders appear in the MT5 **Trade** tab.
- Confirm partial closes fire at TP1 and comment updates to breakeven.
- Review `/stats` endpoint to track signal quality and confidence distribution.
- Check news filtering is active — you should see `[M15] News blocked` log lines around high-impact events.

Do not proceed to live trading until at least 20 completed trades have been observed with expected behavior.

### Phase 2 — Live account (week 3+)

| Setting | Value |
|---------|-------|
| Account type | Live |
| `InpMicroMode` | `true` |
| `InpMinLot` | `0.01` |
| `InpBaseRisk` | `1.0` (ignored in MicroMode) |

Start live with `InpMicroMode = true` so every trade uses a fixed 0.01 lot regardless of account balance. This caps real-money exposure while confirming live execution (fills, slippage, broker behavior) matches demo.

After a further two weeks of stable live results with MicroMode, switch to `InpMicroMode = false` to enable full risk-based sizing. Recommended transition balance: at minimum $1,000 per 0.01 lot of intended risk.

---

## 8. How the EA Works

### H1 boundary — API call

Every time a new H1 candle opens, the EA:

1. Builds a JSON payload containing account balance, equity, open positions, and OHLC data for D1 (10 candles), H4 (20), H1 (20), and M15 (20) for each symbol in `InpSymbols`.
2. POSTs the payload to `InpApiUrl` via `WebRequest`.
3. The Flask server fetches live high-impact news from ForexFactory, then calls Claude (`claude-opus-4-5`) with a structured prompt requesting multi-timeframe analysis.
4. Claude returns JSON with:
   - `active_signal` — a potential market order with watch level, SL, TP1, TP2, and confidence score.
   - `pending_orders` — up to two limit orders at H4 key levels, each with a 4-hour expiry.
5. The EA stores the active signal internally and immediately places any valid limit orders.

### M15 boundary — local entry check

Every time a new M15 candle opens (no API call), the EA checks the stored active signal:

- Is it still within its 1-hour validity window?
- Is the pair free of news (no high-impact event within 60 minutes past or 30 minutes ahead)?
- Is the spread within the configured maximum?
- Is there no existing position on that pair?
- Is the current price within `InpMaxWatchDist` pips of the watch level (or is the watch level zero for immediate entry)?

If all conditions pass, a market order is executed. The signal is consumed and cleared regardless of whether an order was placed.

### Guard rails (checked every 15-second timer tick)

- **Weekend**: no action on Saturday or Sunday.
- **Drawdown ≥ 10%**: all trading suspended until manually re-enabled.
- **Loss streak ≥ 3**: all trading suspended until streak resets.
- **Max positions**: no new orders if `TotalOpenAndPending() >= InpMaxPositions`.

---

## 9. Trade Management

### Entry comment format

Market orders are tagged with: `FAI_MOM_TP1_<price>` where `<price>` is the TP1 level as a 5-decimal float.
Limit orders are tagged with: `FAI_LIM`.

### Partial close at TP1

When price reaches the TP1 level stored in the order comment:

1. 50% of the position volume is closed.
2. Stop loss is moved to breakeven (entry price + 2 points spread buffer).
3. The remaining 50% runs toward TP2.

This logic survives EA restarts because it reads deal history via `HistorySelectByPosition` to determine whether a partial close has already occurred (position volume < 60% of original open volume).

### Trailing stop (post-partial)

After the partial close, the EA trails the stop loss on every 15-second tick using the last 3 completed H1 candles:

- **Long positions**: trail = lowest low of last 3 H1 candles − 3 pips. Stop only moves up.
- **Short positions**: trail = highest high of last 3 H1 candles + 3 pips. Stop only moves down.

### Limit order expiry

All pending limit orders placed by the EA use `ORDER_TIME_SPECIFIED` with a default 4-hour expiry (overridable per order via the API response `expiry_hours` field). Expired orders are also cleaned up by `CleanExpiredOrders()` on each timer tick as a safety net.

---

## 10. Risk Table

Risk percentage applied to `InpBaseRisk` based on current drawdown and win/loss streak:

| Condition | Risk multiplier | Effective risk (at 1% base) |
|-----------|-----------------|------------------------------|
| Drawdown ≥ 10% **or** loss streak ≥ 3 | 0× (no trades) | 0% |
| Drawdown ≥ 5% **or** loss streak = 2 | 0.5× | 0.5% |
| Loss streak = 1 | 0.75× | 0.75% |
| Normal (no streak) | 1× | 1.0% |
| Win streak ≥ 3 | 1.25× | 1.25% |
| Win streak ≥ 5 | 1.5× | 1.5% |

Conditions are evaluated in priority order (top row wins). The drawdown is calculated as `(balance − equity) / balance × 100`.

Lot size formula (when MicroMode is off):

```
risk_amount = balance × risk_pct / 100
lots = risk_amount / (sl_distance_in_price / tick_size × tick_value)
lots = clamp(lots, InpMinLot, InpMaxLot), rounded to volume step
```

---

## 11. Troubleshooting

### `[API] Error 4014` in Experts tab

MT5 is blocking the WebRequest. Go to **Tools → Options → Expert Advisors**, enable **Allow WebRequest for listed URL**, and add `http://localhost:5000`. Restart the EA after saving.

### `[API] Error 4060` or timeout

The Flask server is not running. Ensure `run.bat` is open and shows `Starting ForexAI v2.1 on http://localhost:5000`. Check that no firewall is blocking port 5000.

### EA prints startup banner but no `[H1] API call` appears

The EA fires on the H1 candle boundary, not immediately on attach. Wait up to 60 minutes for the first call, or detach and re-attach the EA — `OnTimer` fires within 15 seconds of attach and will trigger the H1 check if a new hour has started.

### `[API] HTTP 500` or `parse error` in server console

Claude returned malformed JSON. Check the server console for the raw response. This is rare; it resolves automatically on the next H1 call. If persistent, check your Anthropic API key and account credit balance at [console.anthropic.com](https://console.anthropic.com/).

### No trades firing despite valid signals

Check in order:
1. **Algo Trading** button is green in MT5 toolbar.
2. `InpEnabled` is `true`.
3. Pair is not news-blocked — look for `[M15] News blocked` in the Experts tab.
4. Spread is within limits — look for `[Spread] ... skip`.
5. Price is within `InpMaxWatchDist` pips of the watch level — look for `[Watch] ... too far from level`.
6. `TotalOpenAndPending()` has not hit `InpMaxPositions`.

### Partial close not firing

Check that the order comment contains `FAI_MOM_TP1_` followed by the TP1 price. If the comment was manually edited or truncated by the broker, the EA falls back to a 1.5× SL distance estimate for TP1 — this is expected behavior and the partial will still fire at that estimated level.

### Server crashes on startup

Ensure Python 3.10+ is installed and `pip install -r requirements.txt` completed without errors. If `anthropic` fails to import, run:

```bat
pip install --upgrade anthropic
```

Verify your API key is valid:

```bat
python -c "import anthropic; print(anthropic.Anthropic().models.list())"
```
