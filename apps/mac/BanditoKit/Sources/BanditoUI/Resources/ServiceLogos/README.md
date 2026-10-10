# Service logos

The logos on the Marketplace tiles of the Mac app. Each file is named after the catalog template id
(`daemon/src/integrations_catalog.json`), so `brave-search.svg` is the logo of the `brave-search` template.

- Source: [Simple Icons](https://simpleicons.org), npm package `simple-icons`, version **13.21.0**
  (`icons/<slug>.svg`, copied unchanged).
- Slugs used: `github`, `linear`, `notion`, `sentry`, `atlassian`, `stripe`, `supabase`, `cloudflare`, `brave`
  (file `brave-search.svg`), `gitlab`, `vercel`, `netlify`, `grafana`, `posthog`, `huggingface`, `mongodb`, `railway`,
  `render`, `snyk`, `prisma`, and `google` (file `toolbox-postgres.svg`: Google's logo for Google MCP Toolbox for PostgreSQL).
- License of the icon set: **CC0 1.0 Universal** (public domain dedication; `LICENSE.md` of the package).
- Not included, because the catalog has no template that uses them, or Simple Icons 13.21.0 has no such logo:
  `playwright`, `exa`, `context7`, `firecrawl`, `composio`, `neon` (no logo in this version; their tiles keep the symbol).

The logos are trademarks of their owners. They are used only to show which service a tile stands for
(nominative use, to identify compatibility). They do not imply endorsement by, or affiliation with, the owners.

The app draws each logo in white (template rendering) on the tile of the service's brand colour (`accent` in the catalog).
