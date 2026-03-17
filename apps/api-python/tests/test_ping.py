from fastapi.testclient import TestClient
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from main import app

client = TestClient(app)

def test_ping_returns_service_name_and_status():
    response = client.get("/ping")
    assert response.status_code == 200
    body = response.json()
    assert body["service"] == "python"
    assert body["status"] == "ok"

def test_ping_has_no_downstream_key():
    response = client.get("/ping")
    assert "downstream" not in response.json()
