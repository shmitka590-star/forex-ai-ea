from flask import Flask, request, jsonify, render_template
import anthropic
import json
import os
import requests
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

app = Flask(__name__)
client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
DB_PATH = Path("signals.db")

# -- Database -----------------------------------------------------------------

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS signals (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            req_data  TEXT,
            res_data  TEXT
        )
    """)
    conn.commit()
    return conn

# -- News Calendar ------------------------------------------------------------

def check_high_impact_news():
    try:
        resp = requests.get(
            "https://nfs.faireconomy.media/ff_calendar_thisweek.json",
            timeout=5
        )
        resp.raise_for_status()
        now = datetime.now(timezone.utc)
        upcoming = []
        for event in resp.json():
            if event.get("impact") != "High":
                continue
            try:
                et = datetime.fromisoformat(event["date"].replace("Z", "+00:00"))
                diff = (et - now).total_seconds() / 60
                if -30 <= diff <= 120:
                    upcoming.append({
                        "title":        event.get("title", ""),
                        "currency":     event.get("currency", ""),
                        "minutes_away": int(diff),
                    })
            except Exception:
                continue
        return upcoming
    except Exception as e:
        print(f"[news] {e}")
        return []

# -- Claude Signal ------------------------------------------------------------

def format_candles(candles, tf_name):
    if not candles:
        return f"{tf_name}: no data\n"
    lines = []
    for c in candles:
        lines.append(
            f"  {c.get('t','?')}  "
            f"O={c.get('o',0):.5f}  "
            f"H={c.get('h',0):.5f}  "
            f"L={c.get('l',0):.5f}  "
            f"C={c.get('c',0):.5f}"
        )
    return f"{tf_name} -- {len(candles)} candles (newest first):\n" + "\n".join(lines) + "\n"

def format_market_data(prices):
    result = ""
    for pair in ["EURUSD", "GBPUSD", "USDJPY"]:
        if pair not in prices:
            continue
        result += f"\n{'='*44}\n{pair}\n{'='*44}\n"
        tfs = prices[pair]
        for tf in ["D1", "H4", "H1", "M15"]:
            if tf in tfs:
                result += format_candles(tfs[tf], tf) + "\n"
    return result

def get_claude_signal(market_data: dict, news_events: list) -> dict:
    affected = {ev["currency"] for ev in news_events}
    avoid_pairs = set()
    for pair in ["EURUSD", "GBPUSD", "USDJPY"]:
        if pair[:3] in affected or pair[3:] in affected:
            avoid_pairs.add(pair)

    prices     = market_data.get("prices", {})
    open_pos   = market_data.get("open_positions", [])
    open_count = market_data.get("open_trades", 0)
    balance    = market_data.get("account_balance", 0)
    equity     = market_data.get("account_equity", balance)

    market_text = format_market_data(prices)

    open_pos_text = "\n".join(
        f"  {p['symbol']} {p['direction']} profit:{p.get('profit_pips', 0):.1f}pips"
        for p in open_pos
    ) or "  None"

    news_text = "None within 2 hours." if not news_events else "\n".join(
        f"  {e['title']} ({e['currency']}) in {e['minutes_away']}min"
        for e in news_events
    )

    avoid_text = ", ".join(avoid_pairs) if avoid_pairs else "None"

    prompt = f"""You are a professional Forex trader with 20 years of experience in multi-timeframe technical analysis.

ACCOUNT STATE:
Balance: ${balance:.2f} | Equity: ${equity:.2f}
Open trades: {open_count}/3

OPEN POSITIONS:
{open_pos_text}

HIGH-IMPACT NEWS -- avoid these pairs: {avoid_text}
{news_text}

MARKET DATA -- candles listed newest first. M15[0] = candle that JUST OPENED this minute.
{market_text}

YOUR TASK -- Top-down analysis framework:

STEP 1 -- D1 TREND BIAS (per pair)
Determine: BULLISH / BEARISH / RANGING
Evidence: consecutive candle direction, higher highs/lows, close position relative to range

STEP 2 -- H4 KEY LEVELS (per pair)
Identify: exact price of nearest support AND resistance
Look for: swing highs/lows, consolidation zones, repeated price rejection areas

STEP 3 -- H1 SETUP PATTERN
Is a pattern forming? Options: bullish_engulfing, bearish_engulfing, pin_bar_bull,
pin_bar_bear, break_of_structure_bull, break_of_structure_bear, inside_bar, NONE

STEP 4 -- M15 ENTRY TRIGGER
M15[0] just opened. Does it confirm entry direction?
Look for: directional candle, breakout of previous candle high/low, momentum alignment

STEP 5 -- TRADE DECISION
Select ONE trade or NONE. Strict rules:
- Direction MUST align with D1 bias
- Entry must be within 20 pips of an H4 key level
- H1 must show a clear pattern (not NONE)
- M15[0] must confirm direction
- Confidence must be >= 70
- Do not trade a pair already in open_positions
- Do not trade if open_trades >= 3
- Do not trade pairs in avoid list

SL: place below/above nearest M15 swing low/high (price, not pips)
TP1: 1.5x SL distance from entry (partial close 50% here, move SL to breakeven)
TP2: 3.0x SL distance from entry (close remaining 50%)

Respond ONLY with valid JSON -- no markdown, no text outside the JSON object:
{{
  "symbol":        "EURUSD|GBPUSD|USDJPY|NONE",
  "direction":     "BUY|SELL|FLAT",
  "confidence":    <integer 0-100>,
  "d1_bias":       "BULLISH|BEARISH|RANGING",
  "h4_support":    <price as float>,
  "h4_resistance": <price as float>,
  "h1_pattern":    "<pattern or NONE>",
  "m15_trigger":   "<one sentence description or NONE>",
  "entry":         <price as float>,
  "sl":            <price as float>,
  "tp1":           <price as float>,
  "tp2":           <price as float>,
  "sl_pips":       <number>,
  "reasoning":     "<max 150 words -- explain each step of your analysis>"
}}"""

    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=900,
        messages=[{"role": "user", "content": prompt}],
    )
    raw = response.content[0].text.strip().replace("```json", "").replace("```", "").strip()
    return json.loads(raw)

# -- Routes -------------------------------------------------------------------

@app.route("/signal", methods=["POST"])
def signal():
    try:
        data = request.get_json(force=True)
        if not data:
            return jsonify({"error": "Empty body"}), 400

        news_events = check_high_impact_news()
        sig = get_claude_signal(data, news_events)

        should_trade = (
            sig.get("direction") not in ("FLAT", None)
            and sig.get("symbol") not in ("NONE", None, "")
            and sig.get("confidence", 0) >= 70
        )

        response = {
            "trade":         should_trade,
            "symbol":        sig.get("symbol",        "NONE"),
            "direction":     sig.get("direction",     "FLAT"),
            "confidence":    sig.get("confidence",    0),
            "d1_bias":       sig.get("d1_bias",       ""),
            "h4_support":    sig.get("h4_support",    0),
            "h4_resistance": sig.get("h4_resistance", 0),
            "h1_pattern":    sig.get("h1_pattern",    ""),
            "m15_trigger":   sig.get("m15_trigger",   ""),
            "entry":         sig.get("entry",         0),
            "sl":            sig.get("sl",            0),
            "tp1":           sig.get("tp1",           0),
            "tp2":           sig.get("tp2",           0),
            "sl_pips":       sig.get("sl_pips",       0),
            "reasoning":     sig.get("reasoning",     ""),
            "news_events":   news_events,
            "timestamp":     datetime.utcnow().isoformat() + "Z",
        }

        conn = get_db()
        conn.execute(
            "INSERT INTO signals (timestamp, req_data, res_data) VALUES (?, ?, ?)",
            (response["timestamp"], json.dumps(data), json.dumps(response))
        )
        conn.commit()
        conn.close()

        return jsonify(response)

    except json.JSONDecodeError as e:
        print(f"[signal] Claude JSON error: {e}")
        return jsonify({"trade": False, "direction": "FLAT", "error": "parse error"}), 500
    except Exception as e:
        print(f"[signal] Error: {e}")
        return jsonify({"trade": False, "direction": "FLAT", "error": str(e)}), 500

@app.route("/history")
def history():
    conn = get_db()
    rows = conn.execute(
        "SELECT res_data FROM signals ORDER BY id DESC LIMIT 100"
    ).fetchall()
    conn.close()
    return jsonify([json.loads(r[0]) for r in rows])

@app.route("/stats")
def stats():
    conn = get_db()
    rows = conn.execute(
        "SELECT res_data FROM signals ORDER BY id DESC LIMIT 500"
    ).fetchall()
    conn.close()

    records   = [json.loads(r[0]) for r in rows]
    total     = len(records)
    trades    = [r for r in records if r.get("trade")]
    confs     = [r.get("confidence", 0) for r in records]
    d1_bulls  = sum(1 for r in records if r.get("d1_bias") == "BULLISH")
    d1_bears  = sum(1 for r in records if r.get("d1_bias") == "BEARISH")
    sym_counts = {}
    for r in records:
        s = r.get("symbol", "")
        if s and s != "NONE":
            sym_counts[s] = sym_counts.get(s, 0) + 1

    return jsonify({
        "total_signals":    total,
        "trades_triggered": len(trades),
        "flat_signals":     total - len(trades),
        "avg_confidence":   round(sum(confs) / len(confs), 1) if confs else 0,
        "d1_bullish":       d1_bulls,
        "d1_bearish":       d1_bears,
        "symbol_counts":    sym_counts,
    })

@app.route("/dashboard")
def dashboard():
    return render_template("dashboard.html")

@app.route("/health")
def health():
    return jsonify({"status": "ok", "version": "2.0", "utc": datetime.utcnow().isoformat() + "Z"})

if __name__ == "__main__":
    print("ForexAI v2 -- http://localhost:5000")
    print("Dashboard -- http://localhost:5000/dashboard")
    app.run(host="0.0.0.0", port=5000, debug=False)
