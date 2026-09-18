# Vercel's entry point. Everything else is a standard ASGI app that runs the
# same way under uvicorn locally or in a Cloud Run container.
from cheers.main import app  # noqa: F401
