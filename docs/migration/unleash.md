# Unleash → Doppio

## Concepts
| Unleash | Doppio |
|---|---|
| Feature toggle | Flag |
| Strategy | Rule |
| Segment | (manual) |

## Bucketing
Unleash uses murmur3 for stickiness; Doppio uses xxh32. Membership changes. Marked as deviation.

## Inexpressible
- Custom stickiness strategies beyond userId/sessionId.
- Gradual rollout with group stickiness.

## Checklist
1. Export features JSON.
2. Run unleash_to_doppio.py.
3. Review report.md.
4. Import + dual-run.