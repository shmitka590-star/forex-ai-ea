from flask import Flask, request, jsonify, render_template
import anthropic
import json
import os
import requests
import sqlite3
from datetime import datetime, timezone

DB_PATH = "signals.db"

def get_db():
    con = sqlite3.connect(DB_PATH)
    con.execute(
        "CREATE TABLE IF NOT EXISTS signals "
        "(key TEXT PRIMARY KEY, data TEXT NOT NULL)"
    )
    return con

app = Flask(__name__)
client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

CANDIDATE_PAIRS = ["EURUSD", "GBPUSD", "USDJPY"]

def check_high_impact_news():
    try:
        url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
        resp = requests.get(url, timeout=5)
        resp.raise_for_status()
        events = resp.json()
        now = datetime.now(timezone.utc)
        upcoming = []
        for event in events:
            if event.get("impact") != "High":
                continue
            try:
                event_time = datetime.fromisoformat(event["date"].replace("Z", "+00:00"))
                diff_minutes = (event_time - now).total_seconds() / 60
                if -30 <= diff_minutes <= 120:
                    upcoming.append({
                        "title": event.get("title", ""),
                        "currency": event.get("currency", ""),
                        "minutes_away": int(diff_minutes),
                        "time_utc": event.get("date", ""),
                    })
            except Exception:
                continue
        return upcoming
    except Exception as e:
        print(f"[news] Error fetching calendar: {e}")
        return []

def currencies_affected(news_events):
    return {ev["currency"] for ev in news_events}

def pair_has_news(pair, affected_currencies):
    return pair[:3] in affected_currencies or pair[3:] in affected_currencies

def get_claude_signal(market_data: dict, news_events: list) -> dict:
    affected = currencies_affected(news_events)
    pairs_block = ""
    for pair, data in market_data.get("prices", {}).items():
        news_flag = " WARNING HIGH-IMPACT NEWS" if pair_has_news(pair, affected) else ""
        prev = ", ".join(str(p) for p in data.get("prev_closes", []))
        pairs_block += (
            f"\n{pair}{news_flag}\n"
            f"  Current candle  O={data['open']} H={data['high']} L={data['low']} C={data['close']}\n"
            f"  Previous closes: {prev}\n"
        )

    news_block = (
        "No high-impact news events within 2 hours."
        if not news_events
        else "HIGH-IMPACT EVENTS NEAR:\n"
        + "\n".join(f"  - {e['title']} ({e['currency']}) in {e['minutes_away']} min" for e in news_events)
    )

    prompt = f"""You are a professional Forex trader and quantitative analyst with 20 years of experience.

MARKET SNAPSHOT (H1 candle data):
{pairs_block}
Account Balance: ${market_data.get('account_balance', 'unknown')}
Server Time UTC: {market_data.get('timestamp', datetime.utcnow().isoformat())}

NEWS STATUS:
{news_block}

TRADING RULES:
1. Select ONE instrument from EURUSD, GBPUSD, USDJPY or NONE if no clear opportunity.
2. NEVER trade a pair whose base or quote currency has a high-impact event within 2 hours.
3. Only issue BUY or SELL if confidence >= 65. Otherwise use FLAT.
4. Choose optimal timeframe: M15, H1, H4, or D1.
5. SL must be between 15-80 pips. TP must be >= 1.8x SL.
6. Prefer the pair with the cleanest, most predictable trend structure.

Respond ONLY with valid JSON, no markdown:
{{
  "symbol": "EURUSD|GBPUSD|USDJPY|NONE",
  "direction": "BUY|SELL|FLAT",
  "timeframe": "M15|H1|H4|D1",
  "confidence": <integer 0-100>,
  "sl_pips": <number>,
  "tp_pips": <number>,
  "reasoning": "<max 120 words>"
}}"""

    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=600,
        messages=[{"role": "user", "content": prompt}],
    )
    raw = response.content[0].text.strip().replace("```json", "").replace("```", "").strip()
    return json.loads(raw)

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
            and sig.get("confidence", 0) >= 65
        )
        response = {
            "trade":      should_trade,
            "symbol":     sig.get("symbol",    "NONE"),
            "direction":  sig.get("direction", "FLAT"),
            "timeframe":  sig.get("timeframe", "H1"),
            "confidence": sig.get("confidence", 0),
            "sl_pips":    sig.get("sl_pips",   30),
            "tp_pips":    sig.get("tp_pips",   60),
            "reasoning":  sig.get("reasoning", ""),
            "news_events": news_events,
            "timestamp":  datetime.utcnow().isoformat() + "Z",
        }
        key = f"signal_{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}"
        with get_db() as con:
            con.execute(
                "INSERT OR REPLACE INTO signals (key, data) VALUES (?, ?)",
                (key, json.dumps({"request": data, "response": response}))
            )
        return jsonify(response)
    except json.JSONDecodeError as e:
        print(f"[signal] Claude returned invalid JSON: {e}")
        return jsonify({"trade": False, "direction": "FLAT", "error": "Claude parse error"}), 500
    except Exception as e:
        print(f"[signal] Unhandled error: {e}")
        return jsonify({"trade": False, "direction": "FLAT", "error": str(e)}), 500

@app.route("/history", methods=["GET"])
def history():
    with get_db() as con:
        rows = con.execute(
            "SELECT data FROM signals WHERE key LIKE 'signal_%' "
            "ORDER BY key DESC LIMIT 100"
        ).fetchall()
    records = []
    for (data,) in rows:
        try:
            records.append(json.loads(data))
        except Exception:
            continue
    return jsonify(records)

@app.route("/dashboard")
def dashboard():
    return render_template("dashboard.html")

@app.route("/health")
def health():
    return jsonify({"status": "ok", "utc": datetime.utcnow().isoformat() + "Z"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
