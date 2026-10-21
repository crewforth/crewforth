import os
import json, sys
from fastapi import FastAPI, APIRouter
import psycopg
import yaml
import requests
import httpx
import faiss  # the vector index
from app import helpers
from . import local_mod

router = APIRouter(prefix="/v1")
admin = APIRouter(prefix="/admin")
app = FastAPI()

@router.get(
    "",
    response_model=list,
)
def items():
    return []

@admin.get("")
def admin_home():
    return {}

@router.post(
    "/items",
    status_code=201,
)
def create_item():
    return {}

@router.get("/items/{item_id}")
def item(item_id: int):
    return {}

@app.post("/jobs")
def jobs():
    a = os.getenv("PY_DEFINED")
    b = os.environ["PY_MISSING_KEY"]
    c = os.environ.get("PY_WITH_DEFAULT", "x")
    requests.get("https://api.weather.example/today")
    requests.get("/v1")
    requests.get("/admin")
    requests.post("/v1/items")
    httpx.get(f"{base}/v1/elsewhere")
    return requests.get("/v1/items/7")
