"""Self-contained O3 LiteX integration; no Breeze runtime dependency."""

def __getattr__(name):
    if name == "O3":
        from .core import O3
        return O3
    raise AttributeError(name)
