"""Minimal demo Flask app for ECS service tier.

Kept intentionally tiny for demo purposes.

Reads Postgres connection info from env vars (DB_HOST, DB_PORT, DB_NAME,
DB_USER, DB_PASSWORD) — these are injected by the ECS task definition from
the Secrets Manager secret created by the rds Terraform module (see
modules/ecs/main.tf `secrets` block). On startup it creates the "courses"
table if needed and seeds it with two hardcoded rows (both idempotent, see
src/rds/init.sql for the equivalent standalone SQL).
"""
import os

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME")
DB_USER = os.environ.get("DB_USER")
DB_PASSWORD = os.environ.get("DB_PASSWORD")

SEED_COURSES = ["AWS Cloud AI Course", "AWS Cloud AI Architect Course"]


def get_db_connection():
    """Open a fresh connection using env-supplied credentials.

    Not pooled — fine for this demo's traffic level. Raises if DB_HOST (or
    any other required var) isn't set, e.g. when running outside ECS.
    """
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


def init_db():
    """Create the courses table and seed it, if not already present."""
    conn = get_db_connection()
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS courses (
                        id   SERIAL PRIMARY KEY,
                        name VARCHAR(255) NOT NULL
                    )
                    """
                )
                for name in SEED_COURSES:
                    cur.execute(
                        "INSERT INTO courses (name) "
                        "SELECT %s WHERE NOT EXISTS "
                        "(SELECT 1 FROM courses WHERE name = %s)",
                        (name, name),
                    )
    finally:
        conn.close()


@app.route("/health")
def health():
    return jsonify(status="ok")


@app.route("/")
def index():
    return jsonify(message="Hello from ECS demo app")


@app.route("/courses")
def courses():
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id, name FROM courses ORDER BY id")
            rows = cur.fetchall()
    finally:
        conn.close()

    return jsonify(courses=[{"id": row[0], "name": row[1]} for row in rows])


if __name__ == "__main__":
    # Best-effort: don't crash app startup if the DB isn't reachable yet
    # (e.g. local run without env vars set) — /courses will just fail on
    # request in that case instead.
    try:
        init_db()
    except Exception as exc:  # noqa: BLE001 - demo-level startup guard
        app.logger.warning("Skipping DB init (courses table): %s", exc)

    app.run(host="0.0.0.0", port=8080)
