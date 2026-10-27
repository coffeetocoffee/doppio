//go:build openfeature
// +build openfeature

package doppio_test

import (
	"context"
	"testing"
	
	doppio "github.com/doppio/sdk-go"
	"github.com/openfeature/go-sdk"
)

func TestProviderMetadata(t *testing.T) {
	c := doppio.NewClient("", "")
	c.LoadFlags([]doppio.FlagDefinition{
		{Key: "f", Enabled: true},
	})
	provider := doppio.NewProvider(c)
	meta, err := provider.Metadata(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if meta.Name != "Doppio Feature Flag Provider" {
		t.Errorf("expected provider name 'Doppio Feature Flag Provider', got '%s'", meta.Name)
	}
}

func TestProviderBooleanEvaluation(t *testing.T) {
	c := doppio.NewClient("", "")
	c.LoadFlags([]doppio.FlagDefinition{
		{Key: "enabled-flag", Enabled: true, RolloutPercentage: 100},
		{Key: "disabled-flag", Enabled: false, RolloutPercentage: 0},
	})
	provider := doppio.NewProvider(c)

	// Enabled flag
	res1, err := provider.ResolveBoolean(context.Background(), "enabled-flag", false, doppio.EvaluationContext{
		UserID:  "user-1",
		UnitID:  "user-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res1.Value != true {
		t.Errorf("expected enabled flag to return true, got %v", res1.Value)
	}
	if res1.Reason != "SPLIT" {
		t.Errorf("expected SPLIT reason, got %s", res1.Reason)
	}

	// Disabled flag
	res2, err := provider.ResolveBoolean(context.Background(), "disabled-flag", true, doppio.EvaluationContext{
		UserID:  "user-1",
		UnitID:  "user-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res2.Value != false {
		t.Errorf("expected disabled flag to return false, got %v", res2.Value)
	}

	// Missing flag
	res3, err := provider.ResolveBoolean(context.Background(), "missing-flag", true, doppio.EvaluationContext{
		UserID:  "user-1",
		UnitID:  "user-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res3.Value != true {
		t.Errorf("expected missing flag to return default true, got %v", res3.Value)
	}
}

func TestProviderTargetingContext(t *testing.T) {
	c := doppio.NewClient("", "")
	c.LoadFlags([]doppio.FlagDefinition{
		{
			Key: "targeted-flag",
			Enabled: true,
			Rules: []doppio.Rule{
				{
					ID:     "vip-rule",
					Expression: `user.plan == "premium"`,
					Variation: 1,
				},
			},
			Variations: []doppio.Variation{
				{Key: "standard", Value: "false"},
				{Key: "premium", Value: "true"},
			},
			DefaultVariation: 0,
			RolloutPercentage: 100,
		},
	})
	provider := doppio.NewProvider(c)

	premiumRes, err := provider.ResolveBoolean(context.Background(), "targeted-flag", false, doppio.EvaluationContext{
		UserID:   "user-1",
		UnitID:   "user-1",
		Custom:   map[string]any{"plan": "premium"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if premiumRes.Value != true {
		t.Errorf("expected premium user -> true, got %v", premiumRes.Value)
	}

	standardRes, err := provider.ResolveBoolean(context.Background(), "targeted-flag", false, doppio.EvaluationContext{
		UserID:   "user-2",
		UnitID:   "user-2",
		Custom:   map[string]any{"plan": "free"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if standardRes.Value != false {
		t.Errorf("expected free user -> false, got %v", standardRes.Value)
	}
}

func TestProviderDeterministicEvaluation(t *testing.T) {
	c := doppio.NewClient("", "")
	c.LoadFlags([]doppio.FlagDefinition{
		{Key: "det-flag", Enabled: true, RolloutPercentage: 50},
	})
	provider := doppio.NewProvider(c)

	res1, err := provider.ResolveBoolean(context.Background(), "det-flag", false, doppio.EvaluationContext{
		UserID:  "user-1",
		UnitID:  "user-1",
	})
	if err != nil {
		t.Fatal(err)
	}

	res2, err := provider.ResolveBoolean(context.Background(), "det-flag", false, doppio.EvaluationContext{
		UserID:  "user-1",
		UnitID:  "user-1",
	})
	if err != nil {
		t.Fatal(err)
	}

	if res1.Value != res2.Value {
		t.Errorf("deterministic evaluation should return same result")
	}
	if res1.Reason != res2.Reason {
		t.Errorf("deterministic evaluation should return same reason")
	}
}

func TestProviderStringEvaluation(t *testing.T) {
	c := doppio.NewClient("", "")
	c.LoadFlags([]doppio.FlagDefinition{
		{Key: "string-flag", Enabled: true, RolloutPercentage: 100,
			Variations: []doppio.Variation{{Key: "on", Value: "hello world"}},
			DefaultVariation: 0, RolloutPercentage: 100},
	})
	provider := doppio.NewProvider(c)

	res, err := provider.ResolveString(context.Background(), "string-flag", "default", doppio.EvaluationContext{
		UserID:  "user-1",
		UnitID:  "user-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Value != "hello world" {
		t.Errorf("expected 'hello world', got %v", res.Value)
	}
}

func TestProviderMissingFlagReturnsDefault(t *testing.T) {
	c := doppio.NewClient("", "")
	c.LoadFlags([]doppio.FlagDefinition{
		{Key: "existing-flag", Enabled: true, RolloutPercentage: 100},
	})
	provider := doppio.NewProvider(c)

	res, err := provider.ResolveBoolean(context.Background(), "missing-flag", true, doppio.EvaluationContext{
		UserID:  "user-1",
		UnitID:  "user-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Value != true {
		t.Errorf("expected missing flag to return default true, got %v", res.Value)
	}
}


