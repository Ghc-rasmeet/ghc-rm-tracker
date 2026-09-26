# GHC Hub — rebuild kit

Live: https://ghc-rm-tracker.vercel.app  ·  Code: github.com/Ghc-rasmeet/ghc-rm-tracker  ·  v4.0 — files: index.html (home), touch.html, insurance.html, common.js, style.css

## What lives where
| Layer | Where | Versioned by |
|---|---|---|
| App (index.html) | GitHub repo | every commit — History tab |
| Database structure | schema.sql (this folder, keep in repo) | update whenever new SQL is run |
| Database data | Backup button → GHC_backup_<date>.xlsx → Google Drive | weekly |
| Edge function | admin-users.ts (this folder) | edit + redeploy in Supabase |
| Hosting | Vercel project "ghc-rm-tracker" | nothing to save — mirrors GitHub |
| Admin logins | GitHub (rasmeet@…) → Supabase + Vercel sign in via GitHub | — |

## Weekly routine
1. Zoho export → send to Claude for check (optional) → Upload clients
2. Backup → save file to Drive, dated

## Every new feature
- File only: upload new index.html to GitHub (commit message = version number)
- With SQL: run SQL in Supabase first, then paste the same SQL at the end of schema.sql and commit it

## Full rebuild from nothing (≈1 hour)
1. Supabase → New project (note URL + publishable key)
2. SQL Editor → paste all of schema.sql → Run
3. Edge Functions → deploy admin-users.ts as "admin-users"
4. Authentication → Users → create logins (same emails as before)
5. SQL Editor → run the name/role updates at the bottom of schema.sql
6. In index.html set SUPABASE_URL / SUPABASE_KEY to the new project's values → commit
7. Vercel → Add New → Import repo → Deploy (or existing project redeploys on commit)
8. Sign in as manager → bottom "restore from backup" → pick latest GHC_backup file

## Roll back the app to an earlier version
GitHub → History → click the commit → open index.html → Download → upload to repo as index.html → commit
