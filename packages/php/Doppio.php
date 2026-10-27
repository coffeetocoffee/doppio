<?php
namespace Doppio;

class Doppio
{
    private static ?\FFI $ffi = null;
    private array $flags = [];
    private array $exposureQueue = [];
    private array $metricQueue = [];

    private static function ffi(): \FFI
    {
        if (self::$ffi === null) {
            self::$ffi = \FFI::cdef(<<<'C'
                uint32_t doppio_native_abi_version(void);
                uint32_t doppio_native_bucket(const char *flag_key, uint32_t flag_len, const char *unit_id, uint32_t unit_len);
                uint32_t doppio_native_enabled(const char *flag_key, uint32_t flag_len, const char *unit_id, uint32_t unit_len, uint32_t rollout_percentage);
                uint32_t doppio_native_eval_cel(const char *expr_ptr, uint32_t expr_len, const char *unit_ptr, uint32_t unit_len);
            C, self::libPath());
        }
        return self::$ffi;
    }

    private static function libPath(): string
    {
        return getenv('DOPPIO_LIB') ?: 'libdoppio.so';
    }

    public function __construct(array $options = [])
    {
        self::ffi()->doppio_native_abi_version();
        if (isset($options['flags']) && is_array($options['flags'])) {
            $this->loadFlags($options['flags']);
        }
    }

    public static function init(array $options = []): self { return new self($options); }

    public function bucket(string $flagKey, string $unitId): int
    {
        return self::ffi()->doppio_native_bucket($flagKey, strlen($flagKey), $unitId, strlen($unitId));
    }

    public function isEnabled(string $flagKey, string $unitId): bool
    {
        return self::ffi()->doppio_native_enabled($flagKey, strlen($flagKey), $unitId, strlen($unitId), 100) !== 0;
    }

    public function get(string $flagKey, array $context = []): ?array
    {
        $unitId = $context['unitId'] ?? $context['userId'] ?? 'anonymous';
        if (!isset($this->flags[$flagKey])) {
            return ['flagKey' => $flagKey, 'enabled' => false, 'value' => false, 'variation' => null, 'reason' => 'error', 'bucket' => 0];
        }
        $flag = $this->flags[$flagKey];
        $evaluation = $this->evaluate($flag, $context, $unitId, []);
        return $evaluation;
    }

    public function loadFlags(array $flags): void
    {
        $this->flags = [];
        foreach ($flags as $f) { $this->flags[$f['key']] = $f; }
    }

    // --- eval engine (ported from packages/js/src/client.ts) ---
    private function evaluate(array $flag, array $context, string $unitId, array $visited): array
    {
        if (!($flag['enabled'] ?? false)) {
            $def = $this->defaultVariation($flag);
            return $this->result($flag, false, $this->parse($def['value'] ?? 'false'), $def['key'] ?? null, 'disabled', $this->bucket($flag['key'], $unitId));
        }
        if (!empty($flag['prerequisites'])) {
            if (in_array($flag['key'], $visited, true)) {
                return $this->result($flag, false, false, null, 'error', 0);
            }
            $v = array_merge($visited, [$flag['key']]);
            foreach ($flag['prerequisites'] as $p) {
                if (!isset($this->flags[$p['flagKey']])) {
                    return $this->result($flag, false, false, null, 'error', 0);
                }
                $parent = $this->flags[$p['flagKey']];
                $pr = $this->evaluate($parent, $context, $unitId, $v);
                $matched = $pr['enabled'] && $pr['variation'] === $p['variationKey'];
                if (!$matched) {
                    $def = $this->defaultVariation($flag);
                    return $this->result($flag, false, $this->parse($def['value'] ?? 'false'), $def['key'] ?? null, 'prerequisite_failed', $this->bucket($flag['key'], $unitId));
                }
            }
        }
        if (!empty($flag['rules'])) {
            foreach ($flag['rules'] as $rule) {
                if (empty($rule['expression'])) continue;
                if (!$this->evalRule($rule['expression'], $unitId, $context)) continue;
                if (isset($rule['variation']) && isset($flag['variations'][$rule['variation']])) {
                    $sel = $flag['variations'][$rule['variation']];
                    return $this->result($flag, true, $this->parse($sel['value']), $sel['key'], 'target_match', $this->bucket($flag['key'], $unitId));
                }
                if (isset($rule['rolloutPercentage'])) {
                    $pct = $rule['rolloutPercentage'];
                    $inR = self::ffi()->doppio_native_enabled($flag['key'], strlen($flag['key']), $unitId, strlen($unitId), $pct) !== 0;
                    $b = $this->bucket($flag['key'], $unitId);
                    if ($inR) {
                        $sel = $this->defaultVariation($flag);
                        return $this->result($flag, true, $this->parse($sel['value'] ?? 'true'), $sel['key'] ?? 'on', 'target_match', $b);
                    }
                    $def = $this->defaultVariation($flag);
                    return $this->result($flag, false, $this->parse($def['value'] ?? 'false'), $def['key'] ?? null, 'default', $b);
                }
            }
        }
        $rollout = $flag['rolloutPercentage'] ?? 100;
        $b = $this->bucket($flag['key'], $unitId);
        $enabled = self::ffi()->doppio_native_enabled($flag['key'], strlen($flag['key']), $unitId, strlen($unitId), $rollout) !== 0;
        if ($enabled) {
            $sel = $this->defaultVariation($flag);
            return $this->result($flag, true, $this->parse($sel['value'] ?? 'true'), $sel['key'] ?? 'on', 'rollout', $b);
        }
        $def = $this->defaultVariation($flag);
        return $this->result($flag, false, $this->parse($def['value'] ?? 'false'), $def['key'] ?? null, 'rollout_miss', $b);
    }

    private function evalRule(string $expr, string $unitId, array $context): bool
    {
        if (strpos($expr, 'user.') === false && strpos($expr, 'account.') === false && strpos($expr, 'custom.') === false) {
            return self::ffi()->doppio_native_eval_cel($expr, strlen($expr), $unitId, strlen($unitId)) !== 0;
        }
        return $this->evalContext($expr, $unitId, $context);
    }

    private function evalContext(string $expr, string $unitId, array $context): bool
    {
        $flat = [
            'unit_id' => $unitId,
            'user.id' => $unitId,
            'user.country' => $context['country'] ?? null,
            'user.plan' => $context['plan'] ?? null,
            'account.plan' => $context['plan'] ?? null,
        ];
        if (isset($context['custom']) && is_array($context['custom'])) {
            foreach ($context['custom'] as $k => $v) { $flat["custom.$k"] = $v; }
        }
        if (isset($context['extra']) && is_array($context['extra'])) {
            foreach ($context['extra'] as $k => $v) { $flat[$k] = $v; }
        }
        if (preg_match('/^([\w.]+)\s*==\s*"([^"]+)"$/', $expr, $m)) {
            $field = $m[1]; $expected = $m[2];
            return (string)($flat[$field] ?? '') === $expected;
        }
        if (preg_match('/^([\w.]+)\s+in\s+\[(.*)\]$/', $expr, $m)) {
            $field = $m[1];
            $items = array_map(fn($s) => trim(trim($s), "\"'"), explode(',', $m[2]));
            return in_array((string)($flat[$field] ?? ''), $items, true);
        }
        return self::ffi()->doppio_native_eval_cel($expr, strlen($expr), $unitId, strlen($unitId)) !== 0;
    }

    private function defaultVariation(array $flag): ?array
    {
        $vs = $flag['variations'] ?? null;
        if (!is_array($vs) || empty($vs)) return null;
        $idx = $flag['defaultVariation'] ?? 0;
        if ($idx < 0 || $idx >= count($vs)) $idx = 0;
        return $vs[$idx];
    }

    private function parse($raw): mixed
    {
        if ($raw === 'true') return true;
        if ($raw === 'false') return false;
        if (is_numeric($raw) && !is_array($raw)) return (float)$raw + 0;
        $dec = json_decode($raw, true);
        return (json_last_error() === JSON_ERROR_NONE) ? $dec : $raw;
    }

    private function result(array $flag, bool $enabled, mixed $value, ?string $variation, string $reason, int $bucket): array
    {
        return ['flagKey' => $flag['key'], 'enabled' => $enabled, 'value' => $value, 'variation' => $variation, 'reason' => $reason, 'bucket' => $bucket];
    }
}
