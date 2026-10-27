# Cloudflare Workers Edge Example

## Deploy

```sh
npm install -g wrangler
wrangler kv:namespace create FLAGS_KV
# update wrangler.toml with the namespace id
wrangler deploy
```

## Smoke test

```sh
curl https://doppio-edge.<your-subdomain>.workers.dev/snapshot
```