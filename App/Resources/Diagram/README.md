# Diagram renderer

`mermaid.html`, `mermaid.js` and `mermaid-licenses.txt` are copied unchanged
from Loom's `packages/web_view/priv/static` at commit `aad5efc49`. They are
the web view's isolated Mermaid frame: Mermaid 12.2.0 with Loom's fixed strict
configuration, source limits and SVG checks, built by Loom's `make gen-client`
(Loom's protocol-change/091). To update them, copy the three files from a
newer Loom commit and name that commit here.

`host.html` and `host.js` are this app's own. They stand in for the web
view's session page: they hold the frame in an `allow-scripts` sandbox, accept
messages only from that frame's window, and relay them to Swift.
`DiagramView.swift` serves all five files from the app bundle under a private
URL scheme, with the same content policies the web view sends, and refuses
every other request and navigation.
