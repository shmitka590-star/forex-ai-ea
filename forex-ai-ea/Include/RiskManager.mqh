//+------------------------------------------------------------------+
//|                                               RiskManager.mqh   |
//|                      Position sizing and risk control for MT5   |
//+------------------------------------------------------------------+
#ifndef RISK_MANAGER_MQH
#define RISK_MANAGER_MQH

class CRiskManager
{
private:
   double m_RiskPercent;     // Risk per trade as % of balance
   double m_MaxDrawdown;     // Max allowed drawdown %
   int    m_MaxOpenTrades;   // Max simultaneous open trades

public:
   CRiskManager(double riskPct, double maxDD, int maxTrades)
      : m_RiskPercent(riskPct), m_MaxDrawdown(maxDD), m_MaxOpenTrades(maxTrades) {}

   //--- Check if drawdown limit is breached
   bool CheckDrawdown(double startBalance)
   {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct   = (startBalance - equity) / startBalance * 100.0;
      return (ddPct < m_MaxDrawdown);
   }

   //--- Check if we can open another trade
   bool CanOpenTrade(long magic)
   {
      int count = 0;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) &&
            PositionGetInteger(POSITION_MAGIC) == magic)
            count++;
      }
      return (count < m_MaxOpenTrades);
   }

   //--- Calculate lot size based on risk % and stop-loss distance (in price)
   double CalculateLotSize(string symbol, double slDistance)
   {
      if(slDistance <= 0) return 0.0;

      double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmount = balance * m_RiskPercent / 100.0;
      double tickValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double lotStep    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      double minLot     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double maxLot     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

      if(tickSize == 0 || tickValue == 0) return minLot;

      double lotSize = riskAmount / (slDistance / tickSize * tickValue);
      lotSize = MathFloor(lotSize / lotStep) * lotStep;
      lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

      return NormalizeDouble(lotSize, 2);
   }
};

#endif // RISK_MANAGER_MQH
