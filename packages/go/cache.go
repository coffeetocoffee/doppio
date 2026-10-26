package doppio

import (
	"encoding/json"
	"os"
)

type Storage interface {
	LoadFlags() []FlagDefinition
	SaveFlags([]FlagDefinition)
}

type MemoryStorage struct {
	flags []FlagDefinition
}

func (m *MemoryStorage) LoadFlags() []FlagDefinition { return m.flags }
func (m *MemoryStorage) SaveFlags(f []FlagDefinition) { m.flags = append([]FlagDefinition{}, f...) }

type FileStorage struct{ Path string }

func (f *FileStorage) LoadFlags() []FlagDefinition {
	b, err := os.ReadFile(f.Path)
	if err != nil {
		return nil
	}
	var raw []map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil
	}
	out := []FlagDefinition{}
	for _, r := range raw {
		fd := FlagDefinition{}
		if v, ok := r["key"].(string); ok {
			fd.Key = v
		}
		if v, ok := r["enabled"].(bool); ok {
			fd.Enabled = v
		}
		out = append(out, fd)
	}
	return out
}
func (f *FileStorage) SaveFlags(flags []FlagDefinition) {
	b, _ := json.Marshal(flags)
	os.MkdirAll(dirOf(f.Path), 0755)
	os.WriteFile(f.Path, b, 0644)
}

func dirOf(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' || p[i] == '\\' {
			return p[:i]
		}
	}
	return "."
}