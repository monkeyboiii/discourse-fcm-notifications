# AGENTS.md — fcm-notifications

The repo contract. Everything else an agent needs is under `agents.d/` — shape and rules in the
harness's `playbook/agents-d.md`.

- Read `agents.d/memory/MEMORY.md` first.
- The docs are under `agents.d/modules/`; the harness's `workspace/fcm-notifications.md` indexes them.
- name is historical — APNs-direct, no FCM left; dev checkout is on branch push-metrics
- Surgical, simple, never invent a path — the harness `AGENTS.md` discipline applies here.
