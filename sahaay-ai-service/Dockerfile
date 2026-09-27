# SAHAAY - AI & Smart Features Service
# Build:  docker build -t sahaay-ai-service .
# Run:    docker run -p 8000:8000 sahaay-ai-service
# Then open: http://127.0.0.1:8000/docs

FROM python:3.11-slim

# Prevents Python from writing .pyc files & buffers stdout (cleaner logs)
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies first (better Docker layer caching — only
# re-installs if requirements.txt changes, not on every code edit)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the project
COPY . .

# Train the surplus prediction model at build time so the container
# starts ready to serve predictions immediately (no first-request delay)
RUN python -m app.ml.train_model

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
