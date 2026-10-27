<?php
namespace Doppio;
class Doppio {
    public function __construct(array $options = []) {}
    public static function init(array $options = []): self { return new self($options); }
    public function isEnabled(string $flagKey, string $unitId): bool { return false; }
    public function get(string $flagKey, array $context = []): mixed { return null; }
}