# Security

## Reporting a vulnerability

Report it privately with the **Report a vulnerability** button on this repository's **Security** tab.
Please don't open a public issue. We'll acknowledge the report and keep you updated until it's fixed.

## Using this SDK safely

- Never put your Bolna API key (`bn-...`) in the app. Only your backend holds it; the app receives a
  short-lived, single-use session from your backend's session route.
- Serve that route over HTTPS and put your own user authentication on it. Otherwise anyone who finds
  the URL can start calls on your Bolna account.
- Rate-limit the route per user, and pass Bolna's `429` through unchanged so the SDK reports `at_capacity`.
- Treat `user_data` as untrusted input wherever your agent prompt uses it.
