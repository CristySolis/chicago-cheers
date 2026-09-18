# Vercel's entry point. It must sit at the project root: that is where Vercel
# looks for a FastAPI `app`, and finding it there routes every path to the app.
# The older api/index.py layout served only /api itself and 404'd on the real
# routes, and the other option — tool.vercel.entrypoint in pyproject.toml — is
# unavailable because .vercelignore hides that file from Vercel.
#
# Everything else is a standard ASGI app that runs the same way under uvicorn
# locally or in a Cloud Run container.
from cheers.main import app  # noqa: F401
