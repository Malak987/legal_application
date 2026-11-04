# Authentication callbacks: web-first lawyer invitations

Lawyer invitations are accepted **on the web dashboard**. The mobile app never receives an invitation link and needs no native App Link / Universal Link configuration, signing fingerprint, Apple account, Mac or iPhone.

## Invitation lifecycle

1. An administrator invites the lawyer from the dashboard (`admin_panel/`). The `invite-lawyer` Edge Function creates the pending lawyer profile and calls `auth.admin.inviteUserByEmail` with `redirectTo = https://legal-dashboard-1.web.app/auth/callback` and a server-generated one-time claim. The role is never supplied by a client.
2. Supabase sends the invitation email. The link is
   `https://qqfzbecwhewswkyxgebu.supabase.co/auth/v1/verify?token=…&type=invite&redirect_to=https://legal-dashboard-1.web.app/auth/callback`.
3. The invitee opens it in **any browser**, on a phone or a computer. Supabase verifies the token, confirms the email, fires the `link_migrated_auth_user` trigger (which links `auth_user_id`, sets `onboarding_status = 'active'`, creates the public lawyer listing and deletes the private pending row), and redirects to the dashboard callback with an implicit-flow session (`#access_token=…&type=invite`).
4. The dashboard consumes that callback in memory only: it strips the fragment from the address bar before any request, validates the exact callback URL, rejects expired/used links (`error`/`error_code`), and checks the Auth user with the callback token.
5. **Invitation identity verification** (dashboard `AuthService.restoreRecoveryCallback`, `type=invite`): the Auth user must have `email_confirmed_at`; the RLS-protected `public.users` profile resolved by `auth_user_id` must have `role = 'lawyer'`, `onboarding_status = 'active'`, and an email equal to the Auth email. Nothing supplied by the browser (role, lawyer id, activation flag, user metadata) is ever treated as authorization.
6. The dedicated page `/auth/callback` → `InvitationActivationScreen` shows password + confirm fields, validates at least 8 characters and an exact match, and updates the password through `PUT /auth/v1/user` with the short-lived callback access token.
7. On success the temporary session is revoked (`POST /auth/v1/logout`), the tokens are dropped from memory, nothing is written to persistent storage, and the page shows:
   **"Your account has been activated successfully. Open the Legal app and sign in using your email and password."**
8. The lawyer opens the Flutter app and uses the ordinary email/password sign-in.

Expired, already-used, mismatched (`type` not `invite`, wrong callback URL, wrong host/path), unconfirmed, or not-yet-active invitations are rejected with explicit messages: either "invalid, expired, or already used" or "email confirmed but the lawyer profile is not active yet". No token, URL or session value is logged or rendered.

## Mobile app

The mobile app keeps ordinary Supabase email/password authentication and password recovery. After sign-in it loads the profile from `public.users` and refuses access unless the account is an active client or an **active lawyer whose profile email matches the Auth email**. A `type=invite` callback is explicitly ignored by the app, so a stray invite link can never create an app session.

### Password recovery (unchanged, optional deep link)

Mobile password reset still uses the same exact callback. If the OS opens the app for `https://legal-dashboard-1.web.app/auth/callback#…&type=recovery`, `app_links` hands the URI to the session controller and the app shows its reset-password screen. If the OS opens the browser instead — the normal case, since no association document is published — the dashboard's own recovery screen handles the same link. Both paths work; neither is required for invitations.

`AndroidManifest.xml` and `Runner.entitlements` still declare that one callback path for recovery. No association files (`assetlinks.json`, `apple-app-site-association`) are generated or published, and no signing/Apple identifiers are needed.

## Deployment

Only the dashboard needs to be deployed; the mobile app is unchanged in how it is built and installed.

```bash
cd admin_panel && node scripts/build_web.mjs
firebase deploy --only hosting --project legal-dashboard-1
```

`firebase.json` keeps the `/api` function rewrites and the Flutter SPA fallback unchanged. Supabase Auth must keep `https://legal-dashboard-1.web.app/auth/callback` in its redirect allow-list (already configured); no other Auth setting, Edge Function or migration changes are required.

## Verification boundary

No build, automated test, invitation, email, account creation or manual acceptance flow has been run for this change. The end-to-end invitation and login journey must be verified manually.
