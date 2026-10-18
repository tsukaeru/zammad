# Hotaru reply suggestions in the classic composer

This fork adds customer reply previews to the classic agent email composer.
A preview stays outside the contenteditable body. Tab or the acceptance button
first rechecks its evidence with Hotaru, then inserts escaped, editable text
through Zammad's contenteditable insertion operation. Generation and acceptance
never create an article. Sending remains the normal Zammad action.

The feature starts disabled. It requires both `hotaru_reply_drafts = true` and
an explicit ticket group ID in `hotaru_reply_draft_group_ids`. These are Zammad
settings, available through the Rails console. Keep the group list empty until
staging verification has passed.

Configure these environment variables on the Zammad Rails server, then restart
its application processes:

- `HOTARU_REPLY_DRAFT_URL`: fixed HTTPS origin of the Hotaru service, with no
  path, query, fragment or user information.
- `HOTARU_REPLY_DRAFT_INTEGRATION_ID`: stable configured instance identifier
  matching the Hotaru integration.
- `HOTARU_REPLY_DRAFT_SECRET`: 64 lowercase hexadecimal characters representing
  a separately provisioned random 32 byte shared secret. Provision the same
  value in the corresponding Hotaru integration. Never store it in Git,
  browser settings or frontend configuration.

The proxy accepts only an active agent browser session with CSRF protection
and ticket change access. It derives actor and integration identity on the
server. It clears Zammad's request permission cache and reads uncached records
again after generation. The browser cannot supply a different Hotaru origin,
actor or integration. HTTPS calls have bounded connection/read/write timeouts,
response limits, no redirects and no automatic retries. Generation has a
10 second per-agent throttle through the configured Rails cache; Hotaru must
also enforce its own shared concurrency and rate limits.

The signed body contains `integration_id`, `actor_id`, `ticket_id`,
`request_id`, and `language`. Validation adds `evidence_revision`. The signature
is HMAC SHA-256 using the decoded shared secret over the exact UTF-8 bytes
`timestamp + "\n" + nonce + "\n" + body`. Request headers are
`X-Hotaru-Timestamp`, `X-Hotaru-Nonce`, and `X-Hotaru-Signature`. Hotaru owns
freshness, replay rejection, live source permissions and evidence validation.
No ticket body or draft text is sent to the proxy by the browser.

The initial implementation supports public email replies. A signature or quote
alone permits a preview and is preserved on acceptance. Authored drafts and
embedded content prevent generation. Typing, Escape, recipient/subject changes,
channel or visibility changes, ticket notifications, navigation, focus outside
the composer and controller teardown discard results. Text module/autocomplete
menus take priority. Shift+Tab keeps normal focus navigation. After timeout,
retry is explicit. Acceptance requires a matching request and revision, the
same composer state and focus, and a successful live validation response.

## Verification

Run the focused synthetic browser and protocol checks:

```sh
npm ci --prefix test/hotaru --ignore-scripts --no-audit --no-fund
npm test --prefix test/hotaru
ruby test/hotaru/client_test.rb
bundle exec rspec spec/requests/hotaru_reply_drafts_spec.rb
```

Browser tests use installed Google Chrome on macOS. Set `CHROME_PATH` to the
Chrome executable elsewhere. They compile the production composer controller,
execute its Hotaru setup, use the production contenteditable plugin and widget,
and provide synthetic ticket/session/transport state. They prove insertion,
undo, escaping, preview exclusion, signatures, quotes, menu priority, lifecycle
invalidation, pending acceptance protection, timeout/retry and feature gates.
They do not replace a running full Zammad application or staging end-to-end test.
Rails request specs cover actual session/CSRF/policy enforcement with the
external Hotaru transport replaced. Focused fork CI runs those specs with
per-run random database and Redis credentials and loopback-only service ports.
The same workflow runs the browser and signing checks. Inherited upstream
packaging/general CI jobs are skipped in this fork; packaging is unverified.

## Release gate

Implementation base: upstream `stable` commit
`c958f837c1130693efc9f00660e4fdf601bac1d6`. The exact installed Cloudmatika and
Tsukaeru releases remain unverified. Do not deploy this branch until the
installed releases are established, the patch is rebased onto their verified
source releases, Rails checks are green, secrets are separately provisioned,
and a synthetic staging ticket proves browser-to-Rails-to-Hotaru generation,
revocation, revision changes, acceptance, undo and normal sending. Pilot one
approved group. Rollback is disabling `hotaru_reply_drafts`; ordinary composing
and sending continue.
