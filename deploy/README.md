# Deployment Notes

## HTTP/2

The control plane speaks HTTP/1.1 (Zig `std.http` has no native HTTP/2 stack in
0.17). Terminate HTTP/2 at a reverse proxy and proxy to the control plane over
HTTP/1.1. This is the standard deployment pattern and is what we recommend.

### Caddy

```
doppio.example.com {
    encode zstd gzip
    reverse_proxy localhost:8080 {
        flush_interval -1   # keep SSE/WebSocket streaming unbuffered
    }
}
```

Caddy negotiates HTTP/2 with clients automatically and speaks HTTP/1.1 to the
upstream. `/sync/stream` (SSE) and `/sync/ws` (WebSocket) need upgrade/streaming
passthrough, which Caddy and nginx both provide by default.

### nginx

```
server {
    listen 443 ssl http2;
    server_name doppio.example.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;   # SSE
        proxy_read_timeout 3600s;
    }
}
```

## Topologies

- `deploy/enterprise/` — PostgreSQL + Valkey + ClickHouse compose.
- `deploy/managed/` — vendor-operated, same binary.
