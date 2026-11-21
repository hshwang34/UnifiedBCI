import os

# Read before importing numpy and the pipeline (seconds on a loaded machine), so the
# parent watchdog compares against the app's pid even if the app dies meanwhile.
_parent = os.getppid()

from .main import main  # noqa: E402

main(_parent)
