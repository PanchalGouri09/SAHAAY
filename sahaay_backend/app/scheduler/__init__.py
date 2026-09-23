"""In-process background escalation scheduler for SAHAAY.

Runs an asyncio loop (started from the FastAPI lifespan) that periodically
sweeps for donations which need an auto-escalation check and drives them
through the SAME shared service used by the provider-triggered endpoint.

No new dependencies: the loop uses asyncio + a thread for the blocking
(Supabase + AI) work, and the sweep is fully isolated per-donation so a
single failure never aborts the loop.
"""