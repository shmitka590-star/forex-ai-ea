# ForexAI EA v2

Autonomous Forex Expert Advisor powered by Claude AI.

## Architecture

- MT4/MT5 EA sends multi-timeframe OHLC data every new M15 candle
- Flask (localhost:5000) formats data and calls Claude
- Claude performs top-down D1/H4/H1/M15 analysis
- EA executes trade, manages partial close + trailing stop

## Signal Logic

- D1 -> trend bias
- H4 -> key support/resistance levels
- H1 -> setup pattern (engulfing, pin bar, BoS)
- M15 -> entry trigger on freshly opened candle

## Risk Management

- Progressive lots: scales up on win streaks, down on losses
- Partial close 50% at TP1 (1.5R), move SL to breakeven
- Trail remaining position using H1 structure
- Hard stop: 3 consecutive losses or 10% drawdown

## Setup

See ea/SETUP.md for full instructions.
