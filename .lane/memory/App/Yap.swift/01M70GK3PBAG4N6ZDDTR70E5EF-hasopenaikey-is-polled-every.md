---
id: 01M70GK3PBAG4N6ZDDTR70E5EF
anchor: refreshOpenAIKey
created: 2026-11-09T15:59:51Z
norm: '1'
---

hasOpenAIKey is polled every 2s, so it uses KeychainItem.exists (attributes only, no data): that never needs the ACL and can't raise a prompt. Only read the key's data when a clip actually uses OpenAI.
