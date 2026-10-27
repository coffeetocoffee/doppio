//go:build openfeature
// +build openfeature
// OpenFeature Provider for Doppio (Go SDK)
//
// Implements the OpenFeature Provider interface to allow Doppio to be used
// as a feature flag backend for OpenFeature-compatible applications.
//
// Install: go get github.com/doppio/sdk-go
// Usage:
//
//	import (
//	    "github.com/openfeature/go-sdk"
//	    "github.com/openfeature/go-sdk/constant"
//	    doppio "github.com/doppio/sdk-go"
//	    "github.com/doppio/sdk-go/openfeature"
//	)
//
//	func main() {
//	    client := doppio.NewClient("", "")
//	    client.LoadFlags([]doppio.FlagDefinition{...})
//
//	    provider := openfeature.NewProvider(client)
//	    of.SetProvider(provider)
//
//	    ofClient := of.NewClient("my-app", "sha256:12345")
//	    enabled, _ := ofClient.BooleanValue(context.Background(), "flag-key", false)
//	}
package doppio

import (
	"context"
	"fmt"
)

// Provider implements the OpenFeature Provider interface
type Provider struct {
	client *Client
}

// NewProvider creates a new OpenFeature provider wrapping a Doppio client
func NewProvider(client *Client) *Provider {
	return &Provider{client: client}
}

// Metadata returns the provider metadata
func (p *Provider) Metadata(ctx context.Context) (Metadata, error) {
	return Metadata{
		Name: "Doppio Feature Flag Provider",
	}, nil
}

// ResolveBoolean implements the OpenFeature boolean evaluation
func (p *Provider) ResolveBoolean(
	ctx context.Context,
	flagKey string,
	defaultValue bool,
	evalCtx EvaluationContext,
) (Resolution[bool], error) {
	enabled, err := p.client.Get(flagKey, evalCtx.UnitID)
	if err != nil {
		return Resolution[bool]{Value: defaultValue, Reason: constant.Error}, nil
	}

	return Resolution[bool]{
		Value:  enabled,
		Reason: constant.TargetingMatch,
		Variant: getVariation(p.client, flagKey, evalCtx.UnitID),
	}, nil
}

// ResolveString implements the OpenFeature string evaluation
func (p *Provider) ResolveString(
	ctx context.Context,
	flagKey string,
	defaultValue string,
	evalCtx EvaluationContext,
) (Resolution[string], error) {
	return Resolution[string]{
		Value:  defaultValue,
		Reason: constant.Error,
	}, nil
}

// ResolveInteger implements the OpenFeature integer evaluation
func (p *Provider) ResolveInteger(
	ctx context.Context,
	flagKey string,
	defaultValue int64,
	evalCtx EvaluationContext,
) (Resolution[int64], error) {
	return Resolution[int64]{
		Value:  defaultValue,
		Reason: constant.Error,
	}, nil
}

// ResolveFloat implements the OpenFeature float evaluation
func (p *Provider) ResolveFloat(
	ctx context.Context,
	flagKey string,
	defaultValue float64,
	evalCtx EvaluationContext,
) (Resolution[float64], error) {
	return Resolution[float64]{
		Value:  defaultValue,
		Reason: constant.Error,
	}, nil
}

// ResolveObject implements the OpenFeature object evaluation
func (p *Provider) ResolveStruct(
	ctx context.Context,
	flagKey string,
	defaultValue interface{},
	evalCtx EvaluationContext,
) (Resolution[interface{}], error) {
	return Resolution[interface{}]{
		Value:  defaultValue,
		Reason: constant.Error,
	}, nil
}

func getVariant(c *Client, flagKey string, unitID string) string {
	// Placeholder - would need variations field in FlagDefinition and GetWithVariations
	return ""
}

// Metadata type for OpenFeature
type Metadata = struct {
	Name string `json:"name"`
}

// Resolution type for OpenFeature returns
type Resolution[T any] = struct {
	Value    T           `json:"value"`
	Default  bool        `json:"default"`
	Variant  string      `json:"variant"`
	Reason   string      `json:"reason"`
	Version  interface{} `json:"version"`
	Metadata Metadata     `json:"metadata"`
}

// constant package references (to be provided by openfeature go-sdk)
var _ = fmt.Sprintf


