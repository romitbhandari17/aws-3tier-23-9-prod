-- Demo schema for the "courses" table backing GET /courses.
--
-- NOTE: this file is a reference / for manual `psql` use only — it is not
-- executed automatically by Terraform or ECS. The Flask app
-- (src/ecs/app/app.py) runs the equivalent CREATE TABLE IF NOT EXISTS /
-- seed INSERT itself on startup, so the schema stays in sync even if this
-- file is run separately (both are idempotent).

CREATE TABLE IF NOT EXISTS courses (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);

INSERT INTO courses (name)
SELECT v.name
FROM (VALUES ('AWS Cloud AI Course'), ('AWS Cloud AI Architect Course')) AS v(name)
WHERE NOT EXISTS (SELECT 1 FROM courses WHERE courses.name = v.name);
