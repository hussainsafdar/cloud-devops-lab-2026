"""Small Flask service used to exercise the CI/CD pipeline.

Deliberately kept minimal, but with enough real logic to be worth testing and
worth scanning: input validation, error handling, and a health endpoint the
container healthcheck and orchestrator can rely on.
"""

import os
import socket

from flask import Flask, jsonify, request
from prometheus_flask_exporter import PrometheusMetrics

APP_NAME = "devops-lab-app"
APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")

app = Flask(__name__)
metrics = PrometheusMetrics(app)


@app.get("/")
def index():
    """Service banner. Includes the hostname so you can see which container answered."""
    return jsonify(
        service=APP_NAME,
        version=APP_VERSION,
        hostname=socket.gethostname(),
        endpoints=["/", "/health", "/api/sum", "/api/fizzbuzz/<n>"],
    )


@app.get("/health")
def health():
    """Liveness probe. Kept dependency-free so it stays honest.

    It must not touch a database or any downstream service - a health endpoint
    that fails because something else is down causes healthy containers to be
    restarted in a loop.
    """
    return jsonify(status="ok"), 200


@app.get("/api/sum")
def api_sum():
    """Add two numbers supplied as query parameters."""
    raw_a = request.args.get("a")
    raw_b = request.args.get("b")

    if raw_a is None or raw_b is None:
        return jsonify(error="both 'a' and 'b' query parameters are required"), 400

    try:
        a = float(raw_a)
        b = float(raw_b)
    except ValueError:
        return jsonify(error="'a' and 'b' must be numbers"), 400

    return jsonify(a=a, b=b, sum=a + b)


@app.get("/api/fizzbuzz/<int:number>")
def api_fizzbuzz(number: int):
    """Classic FizzBuzz - small branching logic that unit tests can pin down."""
    if number < 1:
        return jsonify(error="number must be 1 or greater"), 400

    return jsonify(number=number, result=fizzbuzz(number))


def fizzbuzz(number: int) -> str:
    """Return the FizzBuzz representation of a positive integer."""
    if number % 15 == 0:
        return "FizzBuzz"
    if number % 3 == 0:
        return "Fizz"
    if number % 5 == 0:
        return "Buzz"
    return str(number)


@app.errorhandler(404)
def not_found(_error):
    return jsonify(error="not found"), 404


if __name__ == "__main__":
    # Development only. The container runs gunicorn - see the Dockerfile.
    app.run(host="0.0.0.0", port=5000, debug=False)
