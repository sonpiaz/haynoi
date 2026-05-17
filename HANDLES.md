# Haynoi — Handle Lock Checklist

Sprint: ~15 phút. Mở từng link, đăng ký với email primary (sonxpiaz@gmail.com).

## Domain (✅ done)
- [x] [haynoi.com](https://www.namecheap.com) — Namecheap 2yr $26.66 — order #202691206
- [ ] [haynoi.ai](https://www.namecheap.com/domains/registration/results/?domain=haynoi.ai) — $92.98/yr — **CRITICAL for voice AI category**
- [ ] [haynoi.app](https://www.namecheap.com/domains/registration/results/?domain=haynoi.app) — defensive, ~$15/yr
- [ ] [haynoi.dev](https://www.namecheap.com/domains/registration/results/?domain=haynoi.dev) — defensive, ~$12/yr

## Code/Package (free, primary @haynoi available)
- [ ] [GitHub user @haynoi](https://github.com/signup) — register account, then add to org or use for brand
- [ ] [npm haynoi](https://www.npmjs.com/signup) — publish placeholder package after register
  ```bash
  cd ~/haynoi && npm init -y --scope=@haynoi && npm publish --access public
  # or non-scoped: npm publish a 1-line placeholder
  ```

## Social — @haynoi available
- [ ] [TikTok @haynoi](https://www.tiktok.com/signup) — confirmed FREE

## Social — @haynoi TAKEN, use @haynoiapp variant
- [ ] [Instagram @haynoiapp](https://www.instagram.com/accounts/emailsignup/) — primary @haynoi taken by personal user "Hayley Phommaravongsa"
- [ ] [Threads @haynoiapp](https://www.threads.net/login) — auto-linked with Instagram, same handle
- [ ] [YouTube @haynoiapp](https://www.youtube.com/account) — primary @haynoi taken by VN channel "30 Haynoi30"

## Social — manual check required (anti-scraper)
- [ ] **X/Twitter** — go to [x.com/i/flow/signup](https://x.com/i/flow/signup), try `@haynoi` then `@haynoiapp` if taken
- [ ] **LinkedIn Company** — [linkedin.com/company/setup/new](https://www.linkedin.com/company/setup/new/), try slug `haynoi` then `haynoi-app`

## Brand consistency rule

If @haynoi taken on a platform → use **@haynoiapp** (matches `.app` domain naming convention, used by Linear, Frame, etc.)

## After locking — verify

```bash
# Quick sanity check that all handles resolve
for url in github.com/haynoi npmjs.com/package/haynoi tiktok.com/@haynoi instagram.com/haynoiapp threads.net/@haynoiapp youtube.com/@haynoiapp; do
  curl -sI -L --max-time 5 "https://$url" | head -1 | sed "s|^|$url: |"
done
```
