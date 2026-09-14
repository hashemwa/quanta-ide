# Terminal renderer dependencies

- `@xterm/xterm` 6.0.0: `xterm.js`, `xterm.css`, and `xterm-LICENSE`.
- `@xterm/addon-fit` 0.11.0: `addon-fit.js` and `addon-fit-LICENSE`.

Assets were downloaded from the official npm registry and checked against each package's published SHA-512 integrity value. They are bundled locally; terminal rendering does not load a CDN or require network access. Preserve the supplied MIT license files when redistributing these assets.

The app uses its existing WebKit presentation approach inside native panel chrome. A native PTY connects the renderer to the user's login shell. No web server or Python helper is required for terminal operation.

Upstream documentation: https://xtermjs.org/docs/
