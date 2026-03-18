//+------------------------------------------------------------------+
//|                                         Backtest_ForexAI.mq5    |
//|          Utility script to prepare data for offline backtesting  |
//+------------------------------------------------------------------+
#property copyright "ForexAI EA"
#property link      "https://github.com/shmitka590-star/forex-ai-ea"
#property version   "1.00"
#property script_show_inputs

input string   InpSymbol    = "EURUSD";  // Symbol
input ENUM_TIMEFRAMES InpTF = PERIOD_H1; // Timeframe
input int      InpBars      = 5000;      // Bars to export
input string   InpFilename  = "ForexAI_Data.csv"; // Output filename

void OnStart()
{
   double open[], high[], low[], close[];
   long   volume[];
   datetime time[];

   ArraySetAsSeries(open,   true);
   ArraySetAsSeries(high,   true);
   ArraySetAsSeries(low,    true);
   ArraySetAsSeries(close,  true);
   ArraySetAsSeries(volume, true);
   ArraySetAsSeries(time,   true);

   int bars = InpBars;
   if(CopyOpen (InpSymbol, InpTF, 0, bars, open)   < bars ||
      CopyHigh (InpSymbol, InpTF, 0, bars, high)   < bars ||
      CopyLow  (InpSymbol, InpTF, 0, bars, low)    < bars ||
      CopyClose(InpSymbol, InpTF, 0, bars, close)  < bars ||
      CopyTickVolume(InpSymbol, InpTF, 0, bars, volume) < bars ||
      CopyTime (InpSymbol, InpTF, 0, bars, time)   < bars)
   {
      Print("ERROR: Could not copy price data for ", InpSymbol);
      return;
   }

   int h = FileOpen(InpFilename, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
   {
      Print("ERROR: Cannot open file ", InpFilename);
      return;
   }

   FileWrite(h, "time", "open", "high", "low", "close", "volume");
   for(int i = bars - 1; i >= 0; i--)
      FileWrite(h,
                TimeToString(time[i], TIME_DATE | TIME_MINUTES),
                DoubleToString(open[i],  5),
                DoubleToString(high[i],  5),
                DoubleToString(low[i],   5),
                DoubleToString(close[i], 5),
                IntegerToString(volume[i]));

   FileClose(h);
   Print("Exported ", bars, " bars of ", InpSymbol,
         " to ", InpFilename);
}
