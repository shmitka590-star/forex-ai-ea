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
PAIRS   = ["EURUSD", "GBPUSD", "USDJPY"]

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS signals (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            req_json  TEXT,
            res_json  TEXT
        )
    """)
    conn.commit()
    return conn

def fetch_news():
    try:
        r = requests.get(
            "https://nfs.faireconomy.media/ff_calendar_thisweek.json",
            timeout=6
        )
        r.raise_for_status()
        now = datetime.now(timezone.utc)
        out = []
        for ev in r.json():
            if ev.get("impact") != "High":
                continue
            try:
                et   = datetime.fromisoformat(ev["date"].replace("Z", "+00:00"))
                diff = (et - now).total_seconds() / 60
                out.append({
                    "title":        ev.get("title", ""),
                    "currency":     ev.get("currency", ""),
                    "minutes_away": round(diff, 1),
                    "time_utc":     ev.get("date", ""),
                })
            except Exception:
                continue
        return out
    except Exception as e:
        print(f"[news] {e}")
        return []

def blocked_pairs(news_events):
    blocked = set()
    for ev in news_events:
        m = ev["minutes_away"]
        if -60 <= m <= 30:
            cur = ev["currency"]
            for p in PAIRS:
                if p[:3] == cur or p[3:] == cur:
                    blocked.add(p)
    return blocked

def candles_text(candles, label):
    if not candles:
        return f"{label}: no data\n"
    lines = [f"{label} ({len(candles)} candles, newest first):"]
    for c in candles:
        lines.append(
            f"  {c.get('t','?')}  "
            f"O={c.get('o',0):.5f}  H={c.get('h',0):.5f}  "
            f"L={c.get('l',0):.5f}  C={c.get('c',0):.5f}"
        )
    return "\n".join(lines) + "\n"

def market_block(prices):
    out = ""
    for pair in PAIRS:
        if pair not in prices:
            continue
        out += f"\n{'='*46}\n{pair}\n{'='*46}\n"
        for tf in ["D1", "H4", "H1", "M15"]:
            if tf in prices[pair]:
                out += candles_text(prices[pair][tf], tf) + "\n"
    return out

def call_claude(market_data: dict, news_events: list) -> dict:
    blocked    = blocked_pairs(news_events)
    prices     = market_data.get("prices", {})
    open_pos   = market_data.get("open_positions", [])
    total_open = market_data.get("open_trades", 0)
    balance    = market_data.get("account_balance", 0)
    equity     = market_data.get("account_equity", balance)

    open_txt = "\n".join(
        f"  {p['symbol']} {p['direction']} profit:{p.get('profit_pips',0):.1f}pips"
        for p in open_pos
    ) or "  None"

    news_txt = "None requiring halt." if not news_events else "\n".join(
        f"  {e['title']} ({e['currency']}) {e['minutes_away']:.0f}min away"
        for e in news_events
    )

    blocked_txt = ", ".join(blocked) if blocked else "None"

    prompt = f"""You are a professional Forex trader with 20 years of multi-timeframe experience.

Broker: IC Markets Raw Spread MT5. Commission: $3.50 per lot per side.

ACCOUNT:
Balance: ${balance:.2f} | Equity: ${equity:.2f} | Open: {total_open}/5

OPEN POSITIONS:
{open_txt}

NEWS (halt 30min before to 60min after):
{news_txt}
BLOCKED PAIRS: {blocked_txt}

MARKET DATA (newest first, M15[0] = just opened):
{market_block(prices)}

STEPS:

1. D1 BIAS per pair: BULLISH/BEARISH/RANGING
2. H4 KEY LEVELS: exact support and resistance prices
3. H1 PATTERN: bullish_engulfing, bearish_engulfing, pin_bar_bull,
   pin_bar_bear, break_of_structure_bull, break_of_structure_bear,
   inside_bar, NONE
4. M15 TRIGGER: exact condition + watch_level price
5. ACTIVE SIGNAL (market order on M15 confirm):
   - Must align D1, have H1 pattern, confidence>=70
   - Not blocked, not already open
   - SL: exact price at M15 swing structure
   - TP1: 1.5x SL dist + 1pip commission buffer
   - TP2: 3.0x SL dist + 1pip commission buffer
6. LIMIT ORDERS up to 2 (placed immediately, expire 4h):
   - At H4 key levels, align D1, SL 10-15 pips beyond level
   - Same TP structure + commission buffer
   - Return [] if none

Respond ONLY valid JSON no markdown:
{{
  "active_signal": {{
    "symbol": "EURUSD|GBPUSD|USDJPY|NONE",
    "direction": "BUY|SELL|FLAT",
    "confidence": <0-100>,
    "d1_bias": "BULLISH|BEARISH|RANGING",
    "h4_support": <float>,
    "h4_resistance": <float>,
    "h1_pattern": "<pattern or NONE>",
    "watch_level": <float>,
    "trigger_condition": "<precise condition>",
    "sl": <float>,
    "tp1": <float>,
    "tp2": <float>,
    "sl_pips": <number>,
    "reasoning": "<max 120 words>"
  }},
  "pending_orders": [
    {{
      "symbol": "EURUSD|GBPUSD|USDJPY",
      "type": "BUY_LIMIT|SELL_LIMIT",
      "entry": <float>,
      "sl": <float>,
      "tp1": <float>,
      "tp2": <float>,
      "sl_pips": <number>,
      "expiry_hours": 4,
      "reasoning": "<max 60 words>"
    }}
  ]
}}"""

    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=1200,
        messages=[{"role": "user", "content": prompt}],
    )
    raw = response.content[0].text.strip().replace("```json","").replace("```","").strip()
    return json.loads(raw)

@app.route("/signal", methods=["POST"])
def signal():
    try:
        data = request.get_json(force=True)
        if not data:
            return jsonify({"error": "Empty body"}), 400
        news_events = fetch_news()
        result      = call_claude(data, news_events)
        active      = result.get("active_signal", {})
        pending     = result.get("pending_orders", [])
        should_trade = (
            active.get("direction") not in ("FLAT", None)
            and active.get("symbol") not in ("NONE", None, "")
            and active.get("confidence", 0) >= 70
        )
        response = {
            "active_signal": {
                "trade":             should_trade,
                "symbol":            active.get("symbol",            "NONE"),
                "direction":         active.get("direction",         "FLAT"),
                "confidence":        active.get("confidence",        0),
                "d1_bias":           active.get("d1_bias",           ""),
                "h4_support":        active.get("h4_support",        0),
                "h4_resistance":     active.get("h4_resistance",     0),
                "h1_pattern":        active.get("h1_pattern",        ""),
                "watch_level":       active.get("watch_level",       0),
                "trigger_condition": active.get("trigger_condition", ""),
                "sl":                active.get("sl",                0),
                "tp1":               active.get("tp1",               0),
                "tp2":               active.get("tp2",               0),
                "sl_pips":           active.get("sl_pips",           0),
                "reasoning":         active.get("reasoning",         ""),
            },
            "pending_orders": pending,
            "news_events":    news_events,
            "timestamp":      datetime.utcnow().isoformat() + "Z",
        }
        conn = get_db()
        conn.execute(
            "INSERT INTO signals (timestamp, req_json, res_json) VALUES (?,?,?)",
            (response["timestamp"], json.dumps(data), json.dumps(response))
        )
        conn.commit()
        conn.close()
        return jsonify(response)
    except json.JSONDecodeError as e:
        print(f"[signal] JSON error: {e}")
        return jsonify({"error": "parse error", "active_signal": {"trade": False}}), 500
    except Exception as e:
        print(f"[signal] Error: {e}")
        return jsonify({"error": str(e), "active_signal": {"trade": False}}), 500

@app.route("/history")
def history():
    conn = get_db()
    rows = conn.execute(
        "SELECT res_json FROM signals ORDER BY id DESC LIMIT 100"
    ).fetchall()
    conn.close()
    return jsonify([json.loads(r[0]) for r in rows])

@app.route("/stats")
def stats():
    conn = get_db()
    rows = conn.execute(
        "SELECT res_json FROM signals ORDER BY id DESC LIMIT 500"
    ).fetchall()
    conn.close()
    records = [json.loads(r[0]) for r in rows]
    total   = len(records)
    trades  = [r for r in records if r.get("active_signal", {}).get("trade")]
    pending = sum(len(r.get("pending_orders", [])) for r in records)
    confs   = [r.get("active_signal", {}).get("confidence", 0) for r in records]
    return jsonify({
        "total_signals":       total,
        "momentum_trades":     len(trades),
        "limit_orders_issued": pending,
        "flat_signals":        total - len(trades),
        "avg_confidence":      round(sum(confs)/len(confs), 1) if confs else 0,
    })

@app.route("/dashboard")
def dashboard():
    return render_template("dashboard.html")

@app.route("/health")
def health():
    return jsonify({"status": "ok", "version": "2.1",
                    "utc": datetime.utcnow().isoformat() + "Z"})

if __name__ == "__main__":
    print("ForexAI v2.1 - http://localhost:5000")
    app.run(host="0.0.0.0", port=5000, debug=False)
