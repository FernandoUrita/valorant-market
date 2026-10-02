# Valorant Buy & Sell — Supabase + Netlify

This package is a standalone React + Vite + Tailwind version of the marketplace. It uses Supabase Auth (Google, PKCE) and PostgreSQL database functions. It does not need Cloudflare or ChatGPT login.

## Current status

- Supabase URL and publishable key are configured for your project.
- Database SQL and frontend code are prepared and tested locally.
- Run the SQL in your own Supabase project, enable Google OAuth, and deploy to Netlify to activate this version.
- Existing Sites data remains in its original database; it has not been copied into Supabase. The previous live site is unchanged.

## 1. Create the database

Open your Supabase project → SQL Editor → New query. Copy **all** of `supabase/setup.sql` and run it. The SQL creates private tables, enables RLS, imports catalog IDs, and grants only controlled application RPC access. Keep the `vm` schema private; do not expose it in Data API settings.

Admin access is assigned to the verified Google email `uritaf40@gmail.com`. If this is not the intended administrator, change the single `vm.admin_emails` seed in the SQL before running it. Browser users cannot change their roles, credits, or admin access directly.

## 2. Enable Google login

In Google Cloud / Google Auth Platform:

1. Create an OAuth client of type **Web application**.
2. Configure branding, audience, and basic `openid`, email, and profile scopes.
3. If your OAuth app is in Testing, add your email and other testers to Test users.
4. Add your future Netlify site origin to Authorized JavaScript origins, and `http://localhost:5173` for local testing.
5. Add this Authorized redirect URI exactly:

   `https://msmvmrzfaltsgdpaluyw.supabase.co/auth/v1/callback`

In Supabase → Authentication → Sign In / Providers → Google:

- Enable Google.
- Enter the Google Client ID and Client Secret there.
- Save. No Gmail inbox permission is requested by the app.

In Supabase → Authentication → URL Configuration:

- Site URL: your final Netlify site origin, e.g. `https://your-site.netlify.app`.
- Redirect URLs: `https://your-site.netlify.app/auth/callback` and, for local testing, `http://localhost:5173/auth/callback`.
- When adding your custom domain, add that domain's `/auth/callback` URL too and update Site URL.

## 3. Deploy to Netlify

### Git deployment

Upload the contents of this package into your GitHub repository (this folder must be the repository root), then in Netlify choose **Add new project → Import an existing project**.

- Build command: `npm run build`
- Publish directory: `dist`
- Node: 22 or later
- `netlify.toml` is included.

The app defaults to your supplied project URL and publishable key. Optional Netlify environment variables:

```
VITE_SUPABASE_URL=https://msmvmrzfaltsgdpaluyw.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=<your publishable key>
```

These are public client values. Do not put a secret or service-role key in a VITE variable. Rebuild after changing them.

### Manual upload

The `dist` folder in this package contains the built frontend. Upload **dist** to Netlify Drop. Its `_redirects` file supports full account links and the Google callback route. Google login and live data still require steps 1 and 2.

## 4. First login and marketplace setup

1. Open `/profile` and click **Continue with Google**.
2. Add Facebook URL, email, WhatsApp number, and display name.
3. The default role is Buyer with 100 credits.
4. Request Seller or Midman under **Trust & activity → Role approval**.
5. The administrator approves requests in **Admin review**. The administrator can submit and approve their own role request when setting up their seller profile.
6. Create listings, select inventory, choose Rush / Not rush, and publish.

## Preserved features

- Searchable listings and collections, account summary modal and full inventory page.
- Seller contact channels with prefilled WhatsApp/email inquiry and listing URL; copy-message option for Facebook.
- Profiles, forum posts and replies, private website inquiries.
- Buyer / admin-approved Seller / admin-approved Midman.
- Admin-reviewed reports; confirmed reports deduct 25 credits.
- Zero credits pauses access for 7 days; expiry restores access with 25 credits on the next authenticated request.
- Sales count only after buyer confirmation, plus midman confirmation when assigned.
- Listings with confirmed sales are marked Sold.

## Existing data migration

Do not paste old Sites user IDs into Supabase ownership columns. Supabase Auth uses new user UUIDs. Any transfer of existing production records needs an export from the original database and an explicit mapping of old IDs to verified Supabase Auth users, including reports and transaction participants. This package starts with a new Supabase database and retains the original site as the source for a later reviewed import.

## Local development and validation

```
npm ci
npm run dev
npm run build
node tests/database.mjs
```

Database tests use a local PostgreSQL runtime and cover inventory persistence, role/admin permissions, transaction ownership, report review idempotency, suspension expiry, private inquiries, and anonymous read/write restrictions. Google OAuth requires the actual provider configuration and an interactive login to verify end to end.

Documentation:
- https://supabase.com/docs/guides/auth/social-login/auth-google
- https://supabase.com/docs/guides/database/functions
- https://docs.netlify.com/build/frameworks/framework-setup-guides/vite/
