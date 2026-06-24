# Vo-Cal API — production image.
#
# Multi-stage, uv-based, mirroring Beacon's shipped shape:
#   builder  → resolve + install the frozen lockfile into a self-contained .venv
#   runtime  → copy that .venv + src onto a slim base, run as non-root
#
# Pinned to Python 3.12 to match `requires-python = ">=3.12"` in pyproject.toml
# (Beacon runs 3.14; Vo-Cal's lockfile is resolved against 3.12, so we hold there).
#
# Serves the module-level ASGI app `api.main:app` (the factory output uvicorn
# loads) on 0.0.0.0:8080. The package is `src/api` (hatchling wheel target), so
# the import path is `api.main:app` once the project is installed into the venv.

# ---- builder stage ----------------------------------------------------------
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

# Reproducible, fast installs: copy into the image (not a mount) and don't try
# to fetch a different interpreter than the base provides.
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Dependency layer first for caching: resolve the locked deps without the
# project itself so a source-only change doesn't bust the dependency cache.
# --no-dev drops pytest/ruff — they never run in production.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Now the source. README.md is referenced by pyproject `readme = "README.md"`,
# so the build needs it present to install the project wheel.
COPY README.md ./
COPY src ./src

# Install the project itself into the venv (gives us the `api` package on path).
RUN uv sync --frozen --no-dev

# ---- runtime stage ----------------------------------------------------------
FROM python:3.12-slim-bookworm

# Non-root: create an unprivileged user and own /app with it.
RUN groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid app --create-home app

WORKDIR /app

# Carry over only the resolved venv and the application source — no build tools,
# no lockfile, no tests in the runtime image.
COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --from=builder --chown=app:app /app/src   /app/src

# Put the venv on PATH so `uvicorn` resolves to the installed binary, and keep
# Python output unbuffered for clean container logs.
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

USER app

EXPOSE 8080

# Bind to all interfaces inside the container; Fly's proxy fronts TLS. PORT is
# overridable via fly.toml [env] but defaults to 8080 to match internal_port.
CMD ["sh", "-c", "uvicorn api.main:app --host 0.0.0.0 --port ${PORT}"]
