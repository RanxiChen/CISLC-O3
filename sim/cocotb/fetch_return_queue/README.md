# Fetch return queue L1 contract

Run on Alan: `make -C sim/cocotb/fetch_return_queue SIM=verilator TEST_SEED=1`.
The directed and seeded tests check one reserved request, full FTQ identity,
data/brief gating, ordered dequeue, reset, and backpressure of a second
request. L4 will add multi-outstanding returns and killed-slot retention.
