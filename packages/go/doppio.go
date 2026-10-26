package doppio

import (
	"encoding/binary"
	"fmt"
)

type EvaluationContext struct {
	UserID  string
	UnitID  string
	Country string
	Plan    string
	Custom  map[string]any
}

type Variation struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

type Rule struct {
	ID                string `json:"id,omitempty"`
	Priority          int    `json:"priority,omitempty"`
	Expression        string `json:"expression"`
	Variation         *int   `json:"variation,omitempty"`
	RolloutPercentage *int   `json:"rolloutPercentage,omitempty"`
}

type Prerequisite struct {
	FlagKey      string `json:"flagKey"`
	VariationKey string `json:"variationKey"`
}

type FlagDefinition struct {
	Key               string         `json:"key"`
	Enabled           bool           `json:"enabled"`
	RolloutPercentage *int           `json:"rolloutPercentage,omitempty"`
	Variations        []Variation    `json:"variations,omitempty"`
	DefaultVariation  *int           `json:"defaultVariation,omitempty"`
	Prerequisites     []Prerequisite `json:"prerequisites,omitempty"`
	Rules             []Rule         `json:"rules,omitempty"`
}

const bucketCount = 100000

func xxh32(data []byte, seed uint32) uint32 {
	const p1, p2, p3, p4, p5 = 0x9E3779B1, 0x85EBCA77, 0xC2B2AE3D, 0x27D4EB2F, 0x165667B1
	mask := uint32(0xFFFFFFFF)
	rotl := func(v uint32, b int) uint32 { return (v<<b | v>>(32-b)) & mask }
	n := len(data)
	i := 0
	var h uint32
	if n >= 16 {
		v1 := (seed + p1 + p2) & mask
		v2 := (seed + p2) & mask
		v3 := seed & mask
		v4 := (seed - p1) & mask
		for i+16 <= n {
			lane := binary.LittleEndian.Uint32(data[i:])
			v1 = rotl((v1+(lane*p2))&mask, 13) * p1 & mask
			lane = binary.LittleEndian.Uint32(data[i+4:])
			v2 = rotl((v2+(lane*p2))&mask, 13) * p1 & mask
			lane = binary.LittleEndian.Uint32(data[i+8:])
			v3 = rotl((v3+(lane*p2))&mask, 13) * p1 & mask
			lane = binary.LittleEndian.Uint32(data[i+12:])
			v4 = rotl((v4+(lane*p2))&mask, 13) * p1 & mask
			i += 16
		}
		h = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & mask
	} else {
		h = (seed + p5) & mask
	}
	h = (h + uint32(n)) & mask
	for i+4 <= n {
		k := binary.LittleEndian.Uint32(data[i:]) * p3 & mask
		k = rotl(k, 17) * p4 & mask
		h = (h + k) & mask
		h = rotl(h, 17)*p4&mask + (h-h) // noop safeguard
		i += 4
	}
	_ = h
	// simpler: redo tail carefully
	h = (seed + p5) & mask
	if n >= 16 {
		// recompute base not needed; keep previous h from blocks already done above? We overwrote; redo minimal:
	}
	// fallback: recompute fully is complex; instead just use a simpler correct path below by recomputing from scratch for all sizes:
	h = (seed + p5) & mask
	h = (h + uint32(n)) & mask
	i = 0
	if n >= 16 {
		v1 := (seed + p1 + p2) & mask
		v2 := (seed + p2) & mask
		v3 := seed & mask
		v4 := (seed - p1) & mask
		for i+16 <= n {
			v1 = rotl((v1+(binary.LittleEndian.Uint32(data[i:])*p2))&mask, 13) * p1 & mask
			v2 = rotl((v2+(binary.LittleEndian.Uint32(data[i+4:])*p2))&mask, 13) * p1 & mask
			v3 = rotl((v3+(binary.LittleEndian.Uint32(data[i+8:])*p2))&mask, 13) * p1 & mask
			v4 = rotl((v4+(binary.LittleEndian.Uint32(data[i+12:])*p2))&mask, 13) * p1 & mask
			i += 16
		}
		h = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & mask
		h = (h + uint32(n)) & mask
	}
	for i+4 <= n {
		k := binary.LittleEndian.Uint32(data[i:]) * p3 & mask
		k = rotl(k, 17) * p4 & mask
		h = (h + k) & mask
		h = rotl(h, 17)*p4 & mask
		i += 4
	}
	for i < n {
		h = (h + uint32(data[i])*p5) & mask
		h = rotl(h, 11)*p1 & mask
		i++
	}
	h ^= h >> 15
	h = (h * p2) & mask
	h ^= h >> 13
	h = (h * p3) & mask
	h ^= h >> 16
	return h
}

func bucketUnit(flagKey, unitID string) int {
	salt := []byte(flagKey)
	buf := append([]byte{}, salt...)
	buf = append(buf, 0)
	buf = append(buf, []byte(unitID)...)
	return int(xxh32(buf, 0)) % bucketCount
}

func inRollout(flagKey, unitID string, pct int) bool {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	thr := pct * (bucketCount / 100)
	return bucketUnit(flagKey, unitID) < thr
}

type Client struct {
	flags  map[string]FlagDefinition
	storage Storage
	sync   *SyncClient
}

func NewClient(endpoint, clientKey string) *Client {
	c := &Client{flags: map[string]FlagDefinition{}, storage: &MemoryStorage{}}
	if endpoint != "" {
		c.sync = NewSyncClient(endpoint, clientKey)
	}
	return c
}

func (c *Client) LoadFlags(flags []FlagDefinition) {
	for _, f := range flags {
		c.flags[f.Key] = f
	}
	if c.storage != nil {
		c.storage.SaveFlags(flags)
	}
}

func (c *Client) RestoreFromStorage() {
	if c.storage == nil {
		return
	}
	for _, f := range c.storage.LoadFlags() {
		c.flags[f.Key] = f
	}
}

func (c *Client) IsEnabled(flagKey, unitID string) bool {
	f, ok := c.flags[flagKey]
	if !ok {
		return false
	}
	if !f.Enabled {
		return false
	}
	pct := 100
	if f.RolloutPercentage != nil {
		pct = *f.RolloutPercentage
	}
	return inRollout(flagKey, unitID, pct)
}

func (c *Client) Get(flagKey, unitID string) (bool, error) {
	f, ok := c.flags[flagKey]
	if !ok {
		return false, fmt.Errorf("unknown flag %s", flagKey)
	}
	_ = f
	return c.IsEnabled(flagKey, unitID), nil
}