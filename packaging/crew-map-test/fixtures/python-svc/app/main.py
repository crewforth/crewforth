import os
import json, sys
from fastapi import FastAPI, APIRouter
import psycopg
import yaml
import requests
import httpx
from app import helpers
from . import local_mod

router = APIRouter(prefix="/v1")
app = FastAPI()

@router.get("/items/{item_id}")
def item(item_id: int):
    return {}

@app.post("/jobs")
def jobs():
    a = os.getenv("PY_DEFINED")
    b = os.environ["PY_MISSING_KEY"]
    c = os.environ.get("PY_WITH_DEFAULT", "x")
    requests.get("https://api.weather.example/today")
    return requests.get("/v1/items/7")
