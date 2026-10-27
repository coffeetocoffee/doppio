# LaunchDarkly → Doppio Semantic Translation

## Concepts

| LaunchDarkly | Doppio | Notes |
|---|---|---|
| Flag (boolean) | FlagDefinition | Direct mapping |
| Variation | Variation | Values are strings in Doppio; coerce on eval |
| Targeting rule | Rule | Expression simplified to "true" in importer |
| Segment | (not yet supported) | Marked manual |
| Prerequisite | (not yet supported) | Marked manual |
| Rollout (percentage) | rolloutPercentage | Bucketing differs |
| Environment | (single default env) | Doppio has one env currently |

## Bucketing

LaunchDarkly uses murmur3 hash over `flagKey + unitId` with a 100000-bucket space. Doppio uses xxh32 (seed 0) over `flagKey + "\x00" + unitId` mod 100000. **Membership will differ for the same percentage.** This is a known, accepted deviation; rollout percentages are preserved but bucket assignments change.

## Rule translation

LD targeting rules use a rich clause model (attribute, op, values). Doppio rules use a single expression string. The importer simplifies each rule to `expression: "true"` with `variation: 0`. **This is lossy** — review targeting manually. Full expression translation is a future enhancement.

## Inexpressible / lossy features

- **Segments**: not supported; marked manual.
- **Prerequisites**: not supported; marked manual.
- **Multivariate flags (non-boolean)**: skipped; marked manual.
- **Custom operators (regex, semantic version)**: not supported.
- **Experimentation / holdouts**: not supported.

## Migration checklist

1. Export LD flags (JSON).
2. Run `doppio-import --file export.json --out ./imported`.
3. Review `report.md` — resolve all "manual" items.
4. Review "deviation" items (bucketing changes).
5. Import `flags.json` into Doppio.
6. Run dual-run bridge for a week; review diff report.
7. Cutover when mismatch rate acceptable.