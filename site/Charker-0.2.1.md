<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Charker 0.2.1

Fixes sign-in succeeding but finding no charger for some accounts outside mainland China.

- Accounts in Hong Kong, Taiwan, Singapore, South Korea and several other regions were sent to the wrong Anker server and saw no devices after signing in. They now reach the right one.
- If the country you pick differs from where the account was registered, Charker switches to the account's own server.
- If you are already signed in and still see no devices, sign out and sign in again.
