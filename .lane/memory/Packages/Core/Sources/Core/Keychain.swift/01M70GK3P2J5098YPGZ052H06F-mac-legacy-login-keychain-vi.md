---
id: 01M70GK3P2J5098YPGZ052H06F
anchor: KeychainItem
created: 2026-11-09T15:59:51Z
norm: '1'
---

Mac: legacy login keychain via SecItemAdd, not the data-protection keychain. The item's ACL trusts the creating app by designated requirement (identifier dev.yap.Yap + Apple Development leaf CN), so make run rebuilds read it without a prompt as long as project.yml keeps signing with the same Apple Development cert. Data-protection keychain would need keychain-access-groups + a provisioning profile for both the dev build and the Developer ID release (release.sh signs manually, no profile). Cost: switching between a dev build and a Developer ID release prompts once (Always Allow). Never ad-hoc sign: the DR becomes a cdhash and every rebuild prompts.
