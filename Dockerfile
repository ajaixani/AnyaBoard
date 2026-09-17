# The state board — the service the mod's relay reads and reports to.
# Build from the repo root:  docker build -t anyaboard .
FROM python:3.12-slim

RUN useradd -m -u 10001 board
WORKDIR /app

COPY board/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY board/ /app/board/
COPY schema/ /app/schema/

# The board persists its state here; mount a volume to keep it across
# restarts, or don't — it is regenerated from schema/default_state.json.
RUN mkdir -p /app/board/data && chown -R board:board /app
USER board

ENV PYTHONUNBUFFERED=1
EXPOSE 8787
WORKDIR /app/board
CMD ["python", "main.py", "--host", "0.0.0.0", "--port", "8787"]
