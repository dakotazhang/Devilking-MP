# Review and regression requirements

Version 1.1.0 passed 102 interface/protection tests, 3 native simulator UI flows and unsigned arm64/iOS16.1 package validation. The simulator was iPhone 17e on iOS26.5 with Xcode26.6. This document retains acceptance requirements; iOS16.1 physical-device layout, the second signed device and real subscription writes remain pending user testing.

## 1.1.0 redesign acceptance

- Five tabs: dashboard, downloaders, discovery, subscriptions and settings. Retain old Emby connection compatibility while removing its standalone library tab.
- A fresh installation defaults to global read-only, with independent per-service management permission and qB1/TR migration protection. Existing connection imports must not grant management authority.
- Current downloader traffic, task counts and directory free space remain distinct from stale, unknown and failed observations. Do not add shared NAS free space across clients.
- Metadata search and recommendations use read-only media routes. Only a separately confirmed subscription operation may schedule MoviePilot searches/downloads.
- Read native source/ID pairs and actual TV seasons. Preserve specials season zero. Reject detail identity changes and malformed duplicate lookup results.
- Persist a subscription write intent before dispatch. Keep uncertain outcomes blocked across view changes and relaunch; no automatic business-write retries. Corrupt records fail closed.
- Root and privacy-cover layout must not expand interactive content into the status bar. Refresh and speed controls must remain below the top safe area, including their loading/disabled states.

The new fixture suites cover dashboard parsing/aggregation, read-only authorization and subscription intent persistence. Results belong to the actual CI run, not to this checklist. Production checking during development remains authentication plus read-only requests; live downloader or subscription writes require their own explicitly scoped verification.

### Required simulator and phone checks

1. Launch each tab on a notched iPhone simulator. Validate each visible top control's frame is below the status bar and is hittable; nonblack screenshot pixels alone are insufficient.
2. Exercise empty, loading, offline and long Chinese content; open search with keyboard, dismiss it, enter detail sheets and return from background.
3. Confirm read-only browsing and searches do not issue business writes. Revoke permission or change connection between confirmation and dispatch, and check that the old operation is cancelled.
4. Simulate a subscription POST timeout, reopen the view and recreate the ledger. The next action must use read-only reconciliation, without another POST.
5. Reinstall/upgrade on the user's iOS 16.1 device, then separately validate their second device and certificate installation. Simulator results do not establish that the original phone defect has been fixed.

## Earlier Core findings

| Initial issue | Current disposition and regression requirement |
| --- | --- |
| IPv4 classification could discard DNS labels and accept an external HTTP hostname as local. | **Resolved.** Require exactly four original ASCII decimal components, valid octets and an allowed local subnet. Reject empty labels, alternate numeric notation and a hostname such as `10.1.2.3.evil.example`. |
| Authorization could change during an awaited task read before a write. | **Resolved.** Bind management authorization to the connection generation and recheck it immediately before writing. Backgrounding, migration-protection changes, connection replacement and disconnect invalidate pending authority. Recheck each TR409 challenge attempt. |
| A single-task action accepted bulk identifiers. | **Resolved.** Require one hexadecimal hash:40characters for TR,40or64for qB. Reject `all`, empty values, numeric IDs and separators at the mutation boundary. |
| Missing site fields appeared as healthy zero values or enabled status. | **Resolved.** Incomplete/error account caches have unavailable metrics and an explicit status. Do not infer site configuration state from account statistics. |
| Malformed collections became empty success and missing TR state became stopped. | **Resolved.** Validate required collection shapes and task identity/state fields. Represent unknown states explicitly and retain the last valid list on an invalid response. |
| Metadata identity omitted its source. | **Resolved for the supported native contract.** Include `media_source` with `media_id`; compatibility fallbacks must not merge unrelated sources. |
| Follow-up read failure was overwritten by a successful action message. | **Resolved.** Distinguish request acknowledgement from verified readback. An incomplete readback must not prompt automatic write replay. |
| Old requests could repopulate data after a connection change. | **Resolved.** Clear relevant service data and publish results only for the current generation while unlocked. Clear authenticated image caches when their connection changes. |

## Security and protocol invariants

- Store credentials in device-only, WhenUnlocked Keychain items. Keep secrets out of profiles, source, URLs and diagnostics.
- Use ephemeral URLSession configuration, standard TLS trust validation and same-origin redirect restrictions. Do not add a certificate-validation bypass.
- Parse numeric data without nonfinite or out-of-range integer conversion traps. Unknown data must not imply health.
- Reject duplicate configured downloader entry URLs. This does not discover every DNS or reverse-proxy alias; document each configured role accurately.
- Use sanitized import/save errors, not raw descriptions containing credential-file content.
- Use a stable per-installation Emby device identifier.
- Fetch authenticated Emby posters using a token header. Validate identifiers, image content type and size; bound memory caching. Never place tokens in artwork query strings.
- Keep global read-only on and management disabled by default. Migration protection independently blocks the affected downloader profiles, and actual actions require confirmation.
- Do not expose file deletion, path moving, forced rechecking or reannounce as incidental management actions.
- TR409 authentication/session negotiation is bounded. A network timeout must never automatically replay a write.
- Preserve MP semantics: S suspends, R resumes, P is pending; API tokens use X-API-KEY, login JWTs use Bearer.
- Preserve necessary third-party copyright/license notices. The project's author and maintainer is dakotazhang; removing an upstream notice is not part of branding changes.

## Verification boundaries

Build/test results belong in the corresponding CI run or release notes. Source review and fixture tests do not prove live write behavior against a user's server. Run integration probes read-only unless an administrator deliberately authorizes a scoped test.

Physical-device acceptance must cover installation/re-signing, local-network permissions, biometric prompts and the chosen remote-access path. A simulator run is not evidence that these work on every phone.

iOS may suspend background apps. Describe foreground/manual refresh accurately; do not advertise it as continuous background monitoring. An online service and a fresh app request also do not establish that every account cache is current or healthy.

## ATS compatibility

Apple documents numeric/local address access for iOS10–16 and IP/CIDR exceptions for iOS17+. Keep exceptions narrowly scoped and retain HTTPS requirements for external service addresses. Validate behavior on the actual supported OS versions.

- [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [NSExceptionDomains](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppTransportSecurity/NSExceptionDomains)
