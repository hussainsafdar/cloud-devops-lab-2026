"""Unit tests for the Flask service.

These run in the Jenkins pipeline and produce the coverage report SonarQube
consumes, so they cover the branches rather than just the happy path.
"""

import pytest

from app import app as flask_app
from app import fizzbuzz


@pytest.fixture()
def client():
    flask_app.config.update(TESTING=True)
    return flask_app.test_client()


class TestHealth:
    def test_health_returns_ok(self, client):
        response = client.get("/health")
        assert response.status_code == 200
        assert response.get_json()["status"] == "ok"


class TestIndex:
    def test_index_reports_service_metadata(self, client):
        payload = client.get("/").get_json()
        assert payload["service"] == "devops-lab-app"
        assert "version" in payload
        assert "/health" in payload["endpoints"]


class TestSum:
    def test_adds_two_integers(self, client):
        assert client.get("/api/sum?a=2&b=3").get_json()["sum"] == 5

    def test_adds_negative_and_float(self, client):
        assert client.get("/api/sum?a=-1.5&b=4").get_json()["sum"] == 2.5

    def test_missing_parameter_is_rejected(self, client):
        response = client.get("/api/sum?a=1")
        assert response.status_code == 400
        assert "required" in response.get_json()["error"]

    def test_non_numeric_input_is_rejected(self, client):
        response = client.get("/api/sum?a=abc&b=2")
        assert response.status_code == 400
        assert "numbers" in response.get_json()["error"]


class TestFizzBuzz:
    @pytest.mark.parametrize(
        "number,expected",
        [
            (1, "1"),
            (3, "Fizz"),
            (5, "Buzz"),
            (9, "Fizz"),
            (10, "Buzz"),
            (15, "FizzBuzz"),
            (30, "FizzBuzz"),
        ],
    )
    def test_fizzbuzz_values(self, number, expected):
        assert fizzbuzz(number) == expected

    def test_endpoint_returns_result(self, client):
        payload = client.get("/api/fizzbuzz/15").get_json()
        assert payload["result"] == "FizzBuzz"
        assert payload["number"] == 15

    def test_zero_is_rejected(self, client):
        assert client.get("/api/fizzbuzz/0").status_code == 400


class TestErrors:
    def test_unknown_route_returns_json_404(self, client):
        response = client.get("/does-not-exist")
        assert response.status_code == 404
        assert response.get_json()["error"] == "not found"
