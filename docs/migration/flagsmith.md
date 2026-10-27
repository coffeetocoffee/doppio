# Flagsmith → Doppio

## Concepts
| Flagsmith | Doppio |
|---|---|
| Feature | Flag |
| Segment | (manual) |
| Identity | unit_id |

## Bucketing
Flagsmith uses percentage-based rollout with its own hashing. Doppio uses xxh32. Deviation expected.

## Checklist
1. Export flags JSON.
2. Run flagsmith_to_doppio.py.
3. Review report.md.
4. Import + dual-run.