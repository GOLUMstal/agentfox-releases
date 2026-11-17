# Agent Fox — versiones publicadas

Este repositorio solo contiene **versiones firmadas** de Agent Fox, una extensión
de Firefox que conecta Claude Code con el navegador. El código fuente vive en un
repositorio privado; este se publica automáticamente desde GitHub Actions.

- `updates.json` — manifiesto de actualizaciones que consulta Firefox.
- `xpi/` — extensiones firmadas por Mozilla (distribución no pública).
- `server/` — servidor MCP y host nativo empaquetados (solo requieren Node.js).
- `server.json` — última versión del servidor.
- `install.sh` — instalador para Linux.

## Instalación (Linux, Firefox nativo)

```bash
curl -fsSL https://golumstal.github.io/agentfox-releases/install.sh | bash
```

Licencia MIT. Basado en [agentfox](https://github.com/lemon9247/agentfox) de Willow Sparks.
