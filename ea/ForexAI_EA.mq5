//+------------------------------------------------------------------+
//|                                              ForexAI_EA.mq5      |
//|               AI-Powered Autonomous Forex Advisor (MT5)          |
//+------------------------------------------------------------------+
#property copyright "ForexAI"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input group "=== API Settings ==="
input string   InpApiUrl        = "https://YOUR-REPLIT-URL.replit.app/signal";
input int      InpTimeoutMs     = 8000;

input group "=== Risk Management ==="
input double   InpRiskPct       = 1.0;
input double   InpMaxLot        = 1.0;
input double   InpMinLot        = 0.01;
input int      InpMagicNumber   = 771234;

input group "=== Signal Settings ==="
input int      InpIntervalMin   = 60;
input bool     InpEnableTrading = true;
input string   InpSymbols       = "EURUSD,GBPUSD,USDJPY";

CTrade         g_trade;
CPositionInfo  g_pos;
datetime       g_lastSignalTime = 0;

int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   EventSetTimer(60);
   PrintFormat("ForexAI EA v1.10 started | Magic: %d", InpMagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
{
   if (!InpEnableTrading) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if (dt.day_of_week == 0 || dt.day_of_week == 6) return;
   if ((TimeCurrent() - g_lastSignalTime) < InpIntervalMin * 60) return;
   RequestAndExecuteSignal();
   g_lastSignalTime = TimeCurrent();
}

string BuildPayload()
{
   string syms[];
   int n = StringSplit(InpSymbols, ',', syms);
   string pricesJSON = "";
   for (int i = 0; i < n; i++)
   {
      string sym = syms[i];
      StringTrimRight(sym); StringTrimLeft(sym);
      MqlRates rates[];
      if (CopyRates(sym, PERIOD_H1, 0, 7, rates) < 7) continue;
      string prevCloses = "[";
      for (int j = 6; j >= 2; j--)
         prevCloses += DoubleToString(rates[j].close, 5) + (j > 2 ? "," : "");
      prevCloses += "]";
      if (pricesJSON != "") pricesJSON += ",";
      pricesJSON += StringFormat(
         "\"%s\":{\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f,\"prev_closes\":%s}",
         sym, rates[0].open, rates[0].high, rates[0].low, rates[0].close, prevCloses);
   }
   string ts = TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   StringReplace(ts, ".", "-");
   return StringFormat(
      "{\"pairs\":\"%s\",\"prices\":{%s},\"account_balance\":%.2f,\"timestamp\":\"%s\"}",
      InpSymbols, pricesJSON, AccountInfoDouble(ACCOUNT_BALANCE), ts);
}

void RequestAndExecuteSignal()
{
   string payload = BuildPayload();
   char bodyArr[]; StringToCharArray(payload, bodyArr, 0, StringLen(payload));
   char resultArr[]; string responseHeaders;
   int httpCode = WebRequest("POST", InpApiUrl,
      "Content-Type: application/json\r\n", InpTimeoutMs,
      bodyArr, resultArr, responseHeaders);
   if (httpCode == -1)
   {
      PrintFormat("[API] Error %d - Add URL to Tools>Options>Expert Advisors>Allow WebRequest", GetLastError());
      return;
   }
   string resp = CharArrayToString(resultArr);
   PrintFormat("[API] HTTP %d | %s", httpCode, resp);
   if (httpCode == 200) ProcessSignal(resp);
}

void ProcessSignal(const string &json)
{
   bool   tradeSig  = ParseBool(json,   "trade");
   string symbol    = ParseString(json, "symbol");
   string direction = ParseString(json, "direction");
   double slPips    = ParseDouble(json, "sl_pips");
   double tpPips    = ParseDouble(json, "tp_pips");
   string reasoning = ParseString(json, "reasoning");
   PrintFormat("[Signal] %s %s | SL:%.1f TP:%.1f | %s", direction, symbol, slPips, tpPips, reasoning);
   if (!tradeSig || direction == "FLAT" || symbol == "NONE" || symbol == "") { Print("[Signal] No trade."); return; }
   if (HasOpenPosition(symbol)) { PrintFormat("[Signal] Position exists on %s", symbol); return; }
   ExecuteTrade(symbol, direction, slPips, tpPips);
}

void ExecuteTrade(const string &symbol, const string &direction, double slPips, double tpPips)
{
   double point   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = (digits == 5 || digits == 4) ? point * (digits == 5 ? 10 : 1) : point * 10;
   double slDist  = slPips * pipSize;
   double tpDist  = tpPips * pipSize;
   double price, sl, tp;
   if (direction == "BUY")
      { price = SymbolInfoDouble(symbol, SYMBOL_ASK); sl = price - slDist; tp = price + tpDist; }
   else
      { price = SymbolInfoDouble(symbol, SYMBOL_BID); sl = price + slDist; tp = price - tpDist; }
   double lots = CalculateLotSize(symbol, slDist);
   bool ok = (direction == "BUY") ? g_trade.Buy(lots, symbol, 0, sl, tp, "ForexAI")
                                  : g_trade.Sell(lots, symbol, 0, sl, tp, "ForexAI");
   if (ok) PrintFormat("[Trade] OK %s %s lots:%.2f sl:%.5f tp:%.5f", direction, symbol, lots, sl, tp);
   else    PrintFormat("[Trade] FAILED %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

double CalculateLotSize(const string &symbol, double slDist)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * InpRiskPct / 100.0;
   double tickVal  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lots = (tickVal > 0 && tickSize > 0 && slDist > 0)
      ? riskAmt / (slDist / tickSize * tickVal) : InpMinLot;
   lots = MathMax(InpMinLot, MathMin(InpMaxLot, lots));
   return NormalizeDouble(MathRound(lots / lotStep) * lotStep, 2);
}

bool HasOpenPosition(const string &symbol)
{
   for (int i = 0; i < PositionsTotal(); i++)
      if (g_pos.SelectByIndex(i))
         if (g_pos.Symbol() == symbol && g_pos.Magic() == InpMagicNumber) return true;
   return false;
}

string ParseString(const string &json, const string &key)
{
   string s = "\"" + key + "\":\"";
   int i = StringFind(json, s); if (i < 0) return "";
   i += StringLen(s);
   int e = StringFind(json, "\"", i); if (e < 0) return "";
   return StringSubstr(json, i, e - i);
}

double ParseDouble(const string &json, const string &key)
{
   string s = "\"" + key + "\":";
   int i = StringFind(json, s); if (i < 0) return 0;
   i += StringLen(s);
   if (StringGetCharacter(json, i) == '"') i++;
   int e = i;
   while (e < StringLen(json) && StringFind("0123456789.-", StringSubstr(json, e, 1)) >= 0) e++;
   return StringToDouble(StringSubstr(json, i, e - i));
}

bool ParseBool(const string &json, const string &key)
{
   string s = "\"" + key + "\":";
   int i = StringFind(json, s); if (i < 0) return false;
   return StringSubstr(json, i + StringLen(s), 4) == "true";
}

void OnTick() {}
