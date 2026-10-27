# GrowthBook → Doppio

## Concepts
| GrowthBook | Doppio |
|---|---|
| Feature | Flag |
| Experiment | Experiment |
| Condition (JSONLogic) | Rule (manual) |

## Bucketing
GrowthBook uses hash-based bucketing; Doppio uses xxh32. Deviation.

## Inexpressible
- JSONLogic conditions: not supported, marked manual.
- Multi-armed bandits: out of scope (no ML).

## Checklist
1. Export features JSON.
2. Run growthbook_to_doppio.py.
3. Review report.md (expect manual items).
4. Import + dual-run.