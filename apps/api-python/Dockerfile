FROM python:3.12.5-slim

WORKDIR /app

COPY apps/api-python/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY apps/api-python/main.py .

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
