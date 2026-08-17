# Slim base rather than full python: ~50 MB vs ~350 MB, which matters on a
# t3.micro with limited disk.
FROM python:3.12-slim

# Never write .pyc files, never buffer stdout - buffered logs are the usual
# reason `docker logs` looks empty while the app is clearly running.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Dependencies first, in their own layer. Docker reuses this layer on every
# rebuild where requirements.txt has not changed, so code edits do not trigger
# a full pip install.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a non-root user. If the process is ever compromised, the attacker
# lands as an unprivileged account with no write access to the app directory.
RUN useradd --create-home --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health').status==200 else 1)"

# gunicorn, not the Flask dev server: the dev server is single-threaded and
# explicitly not for production use.
# 2 workers matches the 2 vCPUs; threads absorb slow clients without more RAM.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", \
     "--workers", "2", "--threads", "4", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]
