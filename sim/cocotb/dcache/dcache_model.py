"""Reference contract for an L1D that has no valid cache lines."""


def empty_probe_response(kind, recall_id):
    return kind, recall_id, 0, 0
