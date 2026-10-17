# Security

Do not post live credentials in public issues, pull requests or screenshots.
Remove session cookies, device proofs, phone numbers, pairing links/QR codes,
signed media URLs, private server addresses, signing certificates and keys.
The repository's screenshots use fictional data only.

Git authorship is public metadata. Use a GitHub noreply address if you do not
want a personal email published, and inspect author/committer fields before
pushing. Secret scanners do not classify ordinary names or emails as secrets.
Ignoring a file does not remove it from an existing Git history.

For a vulnerability, use **Security → Report a vulnerability** if private
reporting is enabled. Otherwise request a private contact in an issue, without
exploit details or private data. There is no guaranteed response SLA. Only the
current `main` branch is maintained.

The client requires trusted HTTPS and stores device sessions per server in
Keychain, not Boosty access tokens. For server incidents, read the shared server's
[security policy](https://github.com/staners2/boosty-samsung-tv/blob/main/SECURITY.md).

Русский: не публикуйте действующие QR, cookie, токены, номера телефонов,
подписанные ссылки и ключи. Уязвимости сообщайте приватно; если форма недоступна,
запросите канал связи без технических деталей.
