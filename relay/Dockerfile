FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
# Cloud Run sets $PORT (default 8080); the server reads it.
CMD ["python", "server.py"]
