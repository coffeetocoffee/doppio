package main

import (
	"encoding/json"
	"fmt"
	"os"
	"doppio"
)

type Fixture struct {
	Flags     []doppio.FlagDefinition `json:"flags"`
	Contexts  []map[string]any        `json:"contexts"`
}

func main() {
	data, _ := os.ReadFile(os.Args[1])
	var fx Fixture
	json.Unmarshal(data, &fx)
	c := doppio.NewClient("", "")
	c.LoadFlags(fx.Flags)
	type Row struct {
		Flag  string `json:"flag"`
		Ctx   string `json:"ctx"`
		Value bool   `json:"value"`
	}
	var out []Row
	for _, ctx := range fx.Contexts {
		for _, f := range fx.Flags {
			v, _ := c.Get(f.Key, ctx["targetingKey"].(string))
			out = append(out, Row{Flag: f.Key, Ctx: ctx["targetingKey"].(string), Value: v})
		}
	}
	b, _ := json.Marshal(out)
	fmt.Println(string(b))
}