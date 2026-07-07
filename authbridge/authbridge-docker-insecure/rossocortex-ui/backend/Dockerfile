FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim
WORKDIR /app
COPY main.py token_broker.py ./
RUN uv pip install --system --no-cache \
    "fastapi>=0.115.0" \
    "uvicorn[standard]>=0.30.0" \
    "httpx>=0.27.0" \
    "python-multipart>=0.0.9"
USER 1001
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
