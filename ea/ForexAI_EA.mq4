//+------------------------------------------------------------------+
//|                                              ForexAI_EA.mq4      |
//|               AI-Powered Autonomous Forex Advisor (MT4)          |
//+------------------------------------------------------------------+
#property copyright "ForexAI"
#property version   "1.10"
#property strict

extern string   InpApiUrl        = "https://YOUR-REPLIT-URL.replit.app/signal";
extern int      InpTimeoutMs     = 8000;
extern double   InpRiskPct       = 1.0;
extern double   InpMaxLot        = 1.0;
extern double   InpMinLot        = 0.01;
extern int      InpMagicNumber   = 771234;
extern int      InpIntervalMin   = 60;
extern bool     InpEnableTrading = true;
extern string   InpSymbols       = "EURUSD,GBPUSD,USDJPY";

datetime g_lastSignalTime = 0;

int OnInit() { EventSetTimer(60); Print("ForexAI EA v1.10 (MT4)"); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
{
   if (!InpEnableTrading) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if (dt.day_of_week == 0 || dt.day_of_week == 6) return;
   if ((TimeCurrent() - g_lastSignalTime) < InpIntervalMin * 60) return;
   RequestAndExecuteSignal();
   g_lastSignalTime = TimeCurrent();
}

string BuildPayload()
{
   string syms[]; int n = StringSplit(InpSymbols, ',', syms);
   string pricesJSON = "";
   for (int i = 0; i < n; i++)
   {
      string sym = syms[i]; StringTrimRight(sym); StringTrimLeft(sym);
      string prevCloses = "[";
      for (int j = 5; j >= 1; j--)
         prevCloses += DoubleToString(iClose(sym, PERIOD_H1, j), 5) + (j > 1 ? "," : "");
      prevCloses += "]";
      if (pricesJSON != "") pricesJSON += ",";
      pricesJSON += StringFormat(
         "\"%s\":{\"open\":%.5f,\"high\":%.5f,\"low\":%.5f,\"close\":%.5f,\"prev_closes\":%s}",
         sym, iOpen(sym,PERIOD_H1,0), iHigh(sym,PERIOD_H1,0),
         iLow(sym,PERIOD_H1,0), iClose(sym,PERIOD_H1,0), prevCloses);
   }
   return StringFormat(
      "{\"pairs\":\"%s\",\"prices\":{%s},\"account_balance\":%.2f,\"timestamp\":\"%s\"}",
      InpSymbols, pricesJSON, AccountBalance(),
      TimeToString(TimeGMT(), TIME_DATE|TIME_MINUTES));
}

void RequestAndExecuteSignal()
{
   string payload = BuildPayload();
   char bodyArr[]; StringToCharArray(payload, bodyArr, 0, StringLen(payload));
   char resultArr[]; string responseHeaders;
   int httpCode = WebRequest("POST", InpApiUrl,
      "Content-Type: application/json\r\n", InpTimeoutMs, bodyArr, resultArr, responseHeaders);
   if (httpCode == -1) { Print("[API] Error: ", GetLastError()); return; }
   string resp = CharArrayToString(resultArr);
   if (httpCode == 200) ProcessSignal(resp);
}

void ProcessSignal(string json)
{
   bool   tradeSig  = ParseBool(json,   "trade");
   string symbol    = ParseString(json, "symbol");
   string direction = ParseString(json, "direction");
   double slPips    = ParseDouble(json, "sl_pips");
   double tpPips    = ParseDouble(json, "tp_pips");
   if (!tradeSig || direction == "FLAT" || symbol == "NONE" || symbol == "") return;
   if (HasOpenPosition(symbol)) return;
   ExecuteTrade(symbol, direction, slPips, tpPips);
}

void ExecuteTrade(string symbol, string direction, double slPips, double tpPips)
{
   double point   = MarketInfo(symbol, MODE_POINT);
   int    digits  = (int)MarketInfo(symbol, MODE_DIGITS);
   double pipSize = (digits == 5 || digits == 3) ? point * 10 : point;
   double price, sl, tp; int cmd;
   if (direction == "BUY")
      { price = MarketInfo(symbol,MODE_ASK); sl = price-slPips*pipSize; tp = price+tpPips*pipSize; cmd = OP_BUY; }
   else
      { price = MarketInfo(symbol,MODE_BID); sl = price+slPips*pipSize; tp = price-tpPips*pipSize; cmd = OP_SELL; }
   double lots = CalculateLotSize(symbol, slPips * pipSize);
   int ticket = OrderSend(symbol, cmd, lots, price, 10, sl, tp, "ForexAI", InpMagicNumber, 0, clrNONE);
   if (ticket > 0) PrintFormat("[Trade] OK %s %s lots:%.2f ticket:%d", direction, symbol, lots, ticket);
   else            PrintFormat("[Trade] FAILED: %d", GetLastError());
}

double CalculateLotSize(string symbol, double slDist)
{
   double riskAmt  = AccountBalance() * InpRiskPct / 100.0;
   double tickVal  = MarketInfo(symbol, MODE_TICKVALUE);
   double tickSize = MarketInfo(symbol, MODE_TICKSIZE);
   double lotStep  = MarketInfo(symbol, MODE_LOTSTEP);
   double lots = (tickVal > 0 && tickSize > 0 && slDist > 0)
      ? riskAmt / (slDist / tickSize * tickVal) : InpMinLot;
   lots = MathMax(InpMinLot, MathMin(InpMaxLot, lots));
   return NormalizeDouble(MathRound(lots / lotStep) * lotStep, 2);
}

bool HasOpenPosition(string symbol)
{
   for (int i = 0; i < OrdersTotal(); i++)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         if (OrderSymbol() == symbol && OrderMagicNumber() == InpMagicNumber) return true;
   return false;
}

string ParseString(string json, string key)
{
   string s = "\"" + key + "\":\"";
   int i = StringFind(json, s); if (i < 0) return "";
   i += StringLen(s); int e = StringFind(json, "\"", i); if (e < 0) return "";
   return StringSubstr(json, i, e - i);
}
double ParseDouble(string json, string key)
{
   string s = "\"" + key + "\":";
   int i = StringFind(json, s); if (i < 0) return 0;
   i += StringLen(s); if (StringGetCharacter(json, i) == '"') i++;
   int e = i;
   while (e < StringLen(json) && StringFind("0123456789.-", StringSubstr(json, e, 1)) >= 0) e++;
   return StringToDouble(StringSubstr(json, i, e - i));
}
bool ParseBool(string json, string key)
{
   string s = "\"" + key + "\":";
   int i = StringFind(json, s); if (i < 0) return false;
   return StringSubstr(json, i + StringLen(s), 4) == "true";
}

void OnTick() {}
