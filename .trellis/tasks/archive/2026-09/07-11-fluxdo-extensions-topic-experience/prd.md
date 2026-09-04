# FluxDo extensions and topic experience

## Goal

Extend Dexo's Linux.do experience with native implementations of the FluxDo
metaverse/LDC/CDK feature set, a redesigned in-app browser, persistent read
styling for topic lists, and a complete Topic Detail action/search experience.

The implementation must use FluxDo as the behavior and visual reference while
remaining native UIKit, iOS 15 compatible, localized, and backed by real APIs
or persisted state. Fake controls and non-functional placeholder entries are
not acceptable.

## User Value

- Reach Linux.do extension features without leaving Dexo.
- Distinguish previously opened topics while scanning long lists.
- Browse external and Linux.do web content in a consistent in-app experience.
- Search within a topic and access the same high-value topic operations shown
  in FluxDo without relying on hidden gestures.

## Confirmed Scope

1. Native metaverse, LDC, and CDK features based on FluxDo behavior.
2. FluxDo-style in-app browser redesign integrated with the current Dexo theme.
3. Persistent read/visited styling that grays topics after they are opened.
4. Topic Detail top-right actions and in-topic search based on FluxDo.

## Requirements

- Preserve the existing UIKit architecture and iOS 15 minimum deployment target.
- Use `String(localized:)` for all user-facing strings.
- Reuse existing Linux.do authentication, cookies, Cloudflare recovery, and
  network stack instead of introducing a separate session model.
- Metaverse/LDC/CDK must use real endpoints and persisted user configuration.
- FluxDo entries that are only placeholders or "coming soon" must not be copied
  as fake Dexo actions.
- The in-app browser must preserve authenticated Linux.do cookies and support
  standard navigation, refresh/stop, sharing, external-browser handoff, and a
  user-friendly loading/error state.
- Discourse reading state (`unseen`, `unread_posts`, `last_read_post_number`,
  `highest_post_number`) is authoritative for topic emphasis.
- Successful reading-timing updates must immediately merge into visible topic
  lists so cards update without a full refresh.
- Topics with remaining unread posts or new replies must remain or become
  high-emphasis again instead of being permanently gray after one open.
- Topic Detail must provide an accessible top-right action surface and topic
  search without removing existing reply, bookmark, share, timeline, reaction,
  export, and reading-progress behavior.
- Permission-sensitive topic actions such as edit or notification level must
  only appear or enable when the topic/user permissions allow them.
- Topic search must use the real search endpoint scoped by `topic:<id>`, decode
  `post_number`, and jump to exact result floors.

## Proposed Workstreams

### A. Metaverse / LDC / CDK

- The FluxDo "metaverse" is a service-management page, not an independent
  metaverse backend or virtual-world API.
- Implement LDC (`https://credit.linux.do`) and CDK (`https://cdk.linux.do`)
  OAuth authorization, disable/logout, reauthorization, cached user info,
  balance cards, and web-dashboard handoff.
- Reuse the Connect OAuth approval flow and send the required
  `X-Requested-With: XMLHttpRequest` callback header.
- Store LDC reward Client ID/Secret in Keychain; store only non-sensitive
  enablement and cached display data in local preferences.
- LDC may additionally support the confirmed FluxDo post-reward flow: merchant
  credential configuration, fixed/custom amount, confirmation, API submission,
  and local duplicate/cooldown protection.
- CDK native scope is authorization, score display, refresh, disable, and web
  dashboard handoff. FluxDo contains no native CDK exchange/history workflow.
- Do not add FluxDo's non-functional "more services coming" placeholder.

### B. In-App Browser

- Keep Dexo's account-isolated history/bookmark persistence and 200-item limit.
- Replace the permanent URL form and bottom toolbar with a FluxDo-style address
  capsule, compact controls, loading progress, and a real more menu.
- Support bookmark toggle, copy URL, external open, share, refresh/stop,
  back/forward, and confirmed handoff for non-HTTP schemes.
- Add browser home/library navigation for bookmarks and history. Downloads are
  included only with a real download implementation.
- Centralize all internal browser entry points on the same controller/session.

### C. Topic Visited Styling

- Decode and propagate Discourse read-tracking fields through topic models.
- On successful `/topics/timings`, merge the highest seen post into visible
  topic lists and notify reusable list surfaces immediately.
- Lower only title color and weight for fully read topics; preserve avatars,
  tags, counters, and unread/new indicators.

### D. Topic Detail Actions / Search

- Add the FluxDo-style top-right menu structure using native UIKit menus/sheets.
- Add in-topic search with query state, result navigation, loading/error/empty
  states, and safe interaction with paginated posts.
- Map screenshot actions to existing Dexo capabilities before adding new API
  routes.
- First release includes bookmark, local read-later, notification level, share
  link, OP filter, permission-gated edit, share image, export, in-app browser,
  reading settings, and navigation-bar topic search.

## Acceptance Criteria

- [ ] Metaverse, LDC, and CDK screens expose only working real operations and
      handle logged-out, loading, empty, success, and failure states.
- [ ] The in-app browser visually matches the agreed FluxDo direction, shares
      authenticated cookies, and supports navigation, refresh, share, external
      open, and recoverable errors.
- [ ] Fully read topics use lower-emphasis title styling based on server state;
      new replies restore unread emphasis.
- [ ] Visited styling is applied consistently wherever the shared topic card is
      used and does not overwrite server unread/new indicators.
- [ ] Topic Detail exposes the agreed top-right operations with correct
      permission gating and no placeholder actions.
- [ ] Topic search returns real matching posts, supports previous/next result
      navigation, and can jump to the selected post/floor.
- [ ] Existing Topic Detail reply, bookmark, reaction, share, timeline, export,
      Cloudflare recovery, and reading-progress behavior remains functional.
- [ ] All new UI is localized, UIKit-only, iOS 15 compatible, and passes the
      project build and targeted tests.

## Out of Scope Until Research Confirms Support

- AI features.
- Fake "coming soon" FluxDo entries.
- Porting Flutter/Riverpod implementation architecture.
- Background token earning, blockchain, or wallet behavior not backed by a
  confirmed Linux.do/FluxDo endpoint and user-visible contract.

## Resolved Product Decisions

- LDC post rewards are included in the first extension scope.
- Read styling changes title color and weight only.
- Topic Detail first-release actions follow the confirmed FluxDo mapping and do
  not add placeholder filters or unsupported service operations.

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
