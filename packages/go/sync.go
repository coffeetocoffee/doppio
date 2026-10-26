package doppio

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type SyncClient struct {
	Endpoint  string
	ClientKey string
	Flags     map[string]FlagDefinition
	LastSeq   *int
	pending   []map[string]any
}

func NewSyncClient(endpoint, clientKey string) *SyncClient {
	return &SyncClient{Endpoint: strings.TrimRight(endpoint, "/"), ClientKey: clientKey, Flags: map[string]FlagDefinition{}}
}

func (s *SyncClient) request(method, path string, body any) ([]byte, error) {
	u := s.Endpoint + path
	var req *http.Request
	var err error
	if body != nil {
		b, _ := json.Marshal(body)
		req, err = http.NewRequest(method, u, strings.NewReader(string(b)))
	} else {
		req, err = http.NewRequest(method, u, nil)
	}
	if err != nil {
		return nil, err
	}
	if s.ClientKey != "" {
		req.Header.Set("Authorization", "Bearer "+s.ClientKey)
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 4096)
	for {
		n, e := resp.Body.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if e != nil {
			break
		}
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("http %d", resp.StatusCode)
	}
	return buf, nil
}

func (s *SyncClient) FetchOnce() ([]FlagDefinition, error) {
	seq := 0
	if s.LastSeq != nil {
		seq = *s.LastSeq
	}
	b, err := s.request("GET", fmt.Sprintf("/sync/updates/%d", seq), nil)
	if err != nil {
		return nil, err
	}
	var msg map[string]any
	if err := json.Unmarshal(b, &msg); err != nil {
		return nil, err
	}
	s.HandleMessage(msg)
	out := []FlagDefinition{}
	for _, f := range s.Flags {
		out = append(out, f)
	}
	return out, nil
}

func (s *SyncClient) HandleMessage(msg map[string]any) {
	kind, _ := msg["type"].(string)
	switch kind {
	case "snapshot":
		s.Flags = map[string]FlagDefinition{}
		if arr, ok := msg["flags"].([]any); ok {
			for _, it := range arr {
				if m, ok := it.(map[string]any); ok {
					fd := FlagDefinition{}
					if v, ok := m["key"].(string); ok {
						fd.Key = v
					}
					if v, ok := m["enabled"].(bool); ok {
						fd.Enabled = v
					}
					s.Flags[fd.Key] = fd
				}
			}
		}
		if seq, ok := msg["seq"].(float64); ok {
			v := int(seq)
			s.LastSeq = &v
		}
	case "delta":
		if arr, ok := msg["changes"].([]any); ok {
			for _, it := range arr {
				m, ok := it.(map[string]any)
				if !ok {
					continue
				}
				key, _ := m["key"].(string)
				if b, _ := m["deleted"].(bool); b {
					delete(s.Flags, key)
					continue
				}
				fd := FlagDefinition{}
				if v, ok := m["key"].(string); ok {
					fd.Key = v
				}
				if v, ok := m["enabled"].(bool); ok {
					fd.Enabled = v
				}
				s.Flags[fd.Key] = fd
			}
		}
		if seq, ok := msg["seq"].(float64); ok {
			v := int(seq)
			s.LastSeq = &v
		}
	}
	_ = url.Values{}
}

func (s *SyncClient) QueueExposure(e map[string]any) { s.pending = append(s.pending, e) }

func (s *SyncClient) Flush() (int, error) {
	if len(s.pending) == 0 || s.Endpoint == "" {
		return 0, nil
	}
	events := []map[string]any{}
	for _, e := range s.pending {
		events = append(events, e)
	}
	_, err := s.request("POST", "/collect", map[string]any{"events": events})
	if err != nil {
		return 0, err
	}
	n := len(s.pending)
	s.pending = nil
	return n, nil
}

func (s *SyncClient) StartPolling(interval time.Duration, stop <-chan struct{}) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				s.FetchOnce()
			}
		}
	}()
}