
import json
import os
import time
from urllib.parse import quote

import psycopg
import redis
from flask import Flask, jsonify, request

app = Flask(__name__)


def get_database_url():
    """
    Production can provide DB_PASSWORD_FILE as a Docker secret.
    Development can continue using DATABASE_URL from .env.
    """
    password_file = os.environ.get("DB_PASSWORD_FILE")

    if password_file:
        with open(password_file, "r", encoding="utf-8") as file:
            password = file.read().strip()

        user = os.environ["POSTGRES_USER"]
        database = os.environ["POSTGRES_DB"]
        host = os.environ.get("POSTGRES_HOST", "postgres")
        port = os.environ.get("POSTGRES_PORT", "5432")

        encoded_user = quote(user, safe="")
        encoded_password = quote(password, safe="")
        encoded_database = quote(database, safe="")

        return (
            f"postgresql://{encoded_user}:{encoded_password}"
            f"@{host}:{port}/{encoded_database}"
        )

    return os.environ.get(
        "DATABASE_URL",
        "postgresql://coreuser:corepassword@localhost:5432/coredb",
    )


DATABASE_URL = get_database_url()

REDIS_URL = os.environ.get(
    "REDIS_URL",
    "redis://localhost:6379/0",
)

cache = redis.Redis.from_url(
    REDIS_URL,
    decode_responses=True,
)

CACHE_KEY = "items"
CACHE_TTL = 30


def get_connection():
    return psycopg.connect(DATABASE_URL)


def initialize_database():
    """Create the required schema safely when the app starts."""
    max_attempts = 12

    for attempt in range(1, max_attempts + 1):
        try:
            with get_connection() as connection:
                with connection.cursor() as cursor:
                    # Serialize initialization across replicas/workers.
                    cursor.execute(
                        "SELECT pg_advisory_xact_lock(20261016)"
                    )
                    cursor.execute(
                        """
                        CREATE TABLE IF NOT EXISTS items (
                            id SERIAL PRIMARY KEY,
                            name TEXT NOT NULL
                        )
                        """
                    )

            app.logger.info("Database schema initialized")
            return

        except psycopg.Error:
            app.logger.exception(
                "Database initialization attempt %s/%s failed",
                attempt,
                max_attempts,
            )

            if attempt == max_attempts:
                raise

            time.sleep(5)


initialize_database()


@app.route("/", methods=["GET"])
def home():
    return jsonify({
        "service": "core-app",
        "status": "running",
    })


@app.route("/health", methods=["GET"])
def health():
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()

        return jsonify({
            "status": "healthy",
            "database": "connected",
        }), 200

    except (psycopg.Error, OSError):
        app.logger.exception("Database health check failed")
        return jsonify({
            "status": "unhealthy",
            "database": "unavailable",
        }), 503


@app.route("/items", methods=["GET"])
def get_items():
    try:
        cached_items = cache.get(CACHE_KEY)

        if cached_items is not None:
            return app.response_class(
                cached_items,
                status=200,
                mimetype="application/json",
            )

    except redis.RedisError:
        app.logger.warning("Redis unavailable; reading from database")

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT id, name FROM items ORDER BY id"
                )
                rows = cursor.fetchall()

        items = [
            {"id": item_id, "name": name}
            for item_id, name in rows
        ]

        response_json = json.dumps(items)

        try:
            cache.setex(CACHE_KEY, CACHE_TTL, response_json)
        except redis.RedisError:
            app.logger.warning("Could not populate Redis cache")

        return jsonify(items), 200

    except psycopg.Error:
        app.logger.exception("Failed to retrieve items")
        return jsonify({"error": "Database unavailable"}), 503


@app.route("/items", methods=["POST"])
def create_item():
    data = request.get_json(silent=True)

    if not isinstance(data, dict):
        return jsonify({"error": "A JSON object is required"}), 400

    name = data.get("name")

    if not isinstance(name, str) or not name.strip():
        return jsonify({"error": "A non-empty name is required"}), 400

    name = name.strip()

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "INSERT INTO items (name) VALUES (%s) RETURNING id",
                    (name,),
                )
                item_id = cursor.fetchone()[0]

        try:
            cache.delete(CACHE_KEY)
        except redis.RedisError:
            app.logger.warning("Could not invalidate Redis cache")

        return jsonify({
            "id": item_id,
            "name": name,
        }), 201

    except psycopg.Error:
        app.logger.exception("Failed to create item")
        return jsonify({"error": "Database unavailable"}), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
