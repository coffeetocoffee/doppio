package doppio

import "testing"

func TestIsEnabledFullRollout(t *testing.T) {
	c := NewClient("", "")
	c.LoadFlags([]FlagDefinition{{Key: "f", Enabled: true}})
	if !c.IsEnabled("f", "u1") {
		t.Fatal("expected enabled")
	}
}

func TestStorageRoundTrip(t *testing.T) {
	tmp := t.TempDir() + "/flags.json"
	fs := &FileStorage{Path: tmp}
	fs.SaveFlags([]FlagDefinition{{Key: "f", Enabled: true}})
	got := fs.LoadFlags()
	if len(got) != 1 || got[0].Key != "f" {
		t.Fatal("storage round trip failed")
	}
}

func TestSyncHandleMessage(t *testing.T) {
	sc := NewSyncClient("http://x", "")
	sc.HandleMessage(map[string]any{"type": "snapshot", "seq": float64(5), "flags": []any{map[string]any{"key": "f", "enabled": true}}})
	if len(sc.Flags) != 1 {
		t.Fatal("snapshot not applied")
	}
}