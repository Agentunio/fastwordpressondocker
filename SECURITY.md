# Security

This project is intended for local development only.

The default WordPress admin credentials are public because they are included in
this repository. Change the username and password in `scripts/init.sh` before the
first start if you use this project anywhere outside a private local sandbox.

By default, WordPress and phpMyAdmin ports are bound to `127.0.0.1`, so they are
available from the host machine only. Do not change these bindings to a public
or LAN address while using the default credentials.
