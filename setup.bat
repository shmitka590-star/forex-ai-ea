@echo off
set /p ANTHROPIC_API_KEY= YOUR_API_KEY_HERE
if exist forex-ai-ea (
    cd forex-ai-ea
    git pull
) else (
    git clone https://github.com/shmitka590-star/forex-ai-ea.git
    cd forex-ai-ea
)
pip install -r requirements.txt
echo.
echo ForexAI starting on http://localhost:5000
python main.py
pause
