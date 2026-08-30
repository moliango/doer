# FluxDo Porting Conventions

> How to port features from the FluxDo reference app into Dexo.
> Established across the trust-requirements / invite-links / NewAPI check-in /
> AI model service / search ports (2026-07).

---

## Reference repository

- Local checkout: `/Users/naine/Documents/AndroidWorkspace/fluxdo` (Flutter).
- Feature subsystems worth knowing:
  - `lib/pages/trust_level_requirements_page.dart` — connect.linux.do HTML →
    native cards, with user-summary fallback thresholds.
  - `lib/pages/invite_links_page.dart` + `lib/services/discourse/_users.dart`
    — invite endpoints and expiry presets.
  - `packages/ai_model_manager/` — AI provider/model management (+ chat, not
    ported yet).
  - `lib/pages/search_page.dart` + `lib/models/search_filter.dart` +
    `lib/services/discourse/_search.dart` — search experience.

## Porting rules

1. **Behavior and endpoints are copied verbatim; UI is rebuilt native** in the
   app's card style (insetGrouped / rounded 16 cards / accent from
   `AppSettings.shared.themeStyle.accentColor`). Do not port Flutter/Riverpod
   architecture.
2. **Keep persisted JSON shapes FluxDo-compatible** when the data may be
   extended later (e.g. AIProvider uses `base_url`, `models[]`,
   `capabilitiesUserEdited` keys). Secrets always move to Keychain, never
   JSON/UserDefaults.
3. **Placeholder/coming-soon FluxDo entries are not copied** (established in
   the 07-11 task PRD).
4. Intentional simplifications get a `ponytail:` comment naming the ceiling
   and are listed as deviations in the task's implement.md.

## Discourse endpoint contracts learned from FluxDo

| Feature | Endpoint | Notes |
|---------|----------|-------|
| Trust requirements | GET `https://connect.linux.do/` | Needs web-session cookies; `.linux.do`-domain cookies (incl. `cf_clearance`) flow to the subdomain via `WebCookieStore.cookieHeader(for:)`. Anonymous → Cloudflare challenge page (no `div.card`) → fall back to `/u/{username}/summary.json`-based thresholds. Host match is `linux.do` or `*.linux.do`, not `contains("linux.do")`. Empty-state Connect cards must not overwrite the trust widget snapshot. |
| Trust widget | App Group `group.com.naine.doer` | App writes `TrustLevelWidgetSnapshot`; widget reads it. Kind `DoerTrustLevelWidget`. Deep link `doer://trust`. |
| Policy accept | PUT `/policy/accept` | Form `post_id`. Session cookie + CSRF. Pair: PUT `/policy/unaccept`. Native `ContentBlock.policy`. |
| GitHub releases | GET GitHub `/releases/latest` | Optional `githubProxyPrefix` via `GitHubProxy.applyIfValid`. Invalid prefix must not be cached. |
| APNs | `registerForRemoteNotifications` + `remote-notification` | Cookie login cannot use Discourse `push_url`. Silent push wakes `BackgroundNotificationDeliveryPipeline`. |
| Pending invites | GET `/u/{username}/invited/pending` | Link built as `{baseURL}/invites/{invite_key}` when response has no link field. |
| Create invite | POST `/invites` | `max_redemptions_allowed=1`, optional `expires_at` ISO8601 / `description` / `email`. Session cookie + CSRF (handled by `DiscourseAuthInterceptor`). ~24h rate limit per invite. |
| Recent searches | GET/DELETE `/u/recent-searches.json` | `{"recent_searches": [String]}`. |
| AI semantic search | GET `/discourse-ai/embeddings/semantic-search?q=` | Same payload as `/search.json`. Fire in parallel with page-1 relevance search; merge with RRF `score = Σ 1/(rank+5)` keyed by topic id (Discourse frontend parity). 403 / `error_type=not_found` ⇒ plugin absent, disable for session. |
| NewAPI check-in | POST `{base}/api/user/checkin`, probe GET `{base}/api/user/self` | Headers: `Authorization: Bearer`, `New-Api-User`, `Cookie`. 401/403/“未登录” ⇒ authenticationExpired → auto re-login WebView flow. |
| OpenAI-compatible model list | GET `{formatAPIHost(base)}/models` | `formatAPIHost`: trailing `#` = strict URL; existing `/v<N>[alpha|beta]` kept; else append `/v1` (Gemini `/v1beta`). |
