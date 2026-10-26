# Mission-agentprofiler

Sist verifisert: 30. august 2026.

Disse dokumentene beskriver den faktiske kontrakten mellom AgentSync Mission Control og hver støttet CLI. Formålet er at kommandoer, tillatelser, prompttransport og utdata skal være dokumenterte og testbare, ikke antatt.

## Bevisnivå

En profil bygger på tre separate bevis:

1. Offisiell dokumentasjon fra leverandøren.
2. `--version` og `--help` fra CLI-en som er installert på denne maskinen.
3. En reell, ufarlig smoketest eller en tidligere fullført AgentSync-mission.

Offisiell dokumentasjon beskriver produktet generelt. Lokal CLI-hjelp beskriver den installerte varianten. En smoketest beviser at den samlede kombinasjonen faktisk kan starte, lese prompten og levere maskinlesbar utdata.

## Verifisert oversikt

| Agent | Installert versjon | Prompttransport | Utdata | Lokal kjøring |
| --- | --- | --- | --- | --- |
| Codex | 0.151.0-alpha.7.2 | stdin med `-` | JSONL | Exit 0, eksakt svar, ingen filer |
| Claude Code | 2.1.251 | stdin som tekst | stream-json | CLI-kontrakt verifisert, innlogging manglet ved kontroll |
| Antigravity | 1.1.22 | NDJSON på stdin | stream-json | Flere fullførte Mission-oppdrag |
| OpenCode | 1.18.23 | stdin | JSON-hendelser | Exit 0 med `--auto`, ingen filer |
| Cline | 3.0.60 | eget argument via native exe | JSON-hendelser | Exit 0 med retries, ingen filer |
| Aider | 0.86.2 | unik midlertidig promptfil | tekst | Fullført Mission med lokal Ollama-modell |

## Regler for profilendringer

- En CLI-oppdatering skal kontrolleres med lokal `--version` og relevant `--help`.
- Alle flagg som AgentSync bruker skal finnes i hjelpen til den installerte CLI-en.
- Kjente avhengigheter og konflikter mellom flagg skal ligge som kodeinvarianter og tester.
- En profil regnes ikke som fullverdig verifisert før en ufarlig kjøring har avsluttet med exit 0.
- AgentSync skal sende store eller flerlinjede prompts via stdin eller promptfil når CLI-en støtter det.
- Ingen profil får committe, pushe eller skrive agentattribusjon på vegne av Mission Control.

## Failover

AgentSync bruker failover innenfor samme agent når leverandøren har en dokumentert mekanisme som beholder samme sikkerhetsmodell. Cline får tre interne modellforsøk med `--retries 3`. Claude støtter et eksplisitt fallback-modelvalg, men AgentSync setter ikke en modell som brukeren ikke har valgt.

AgentSync bytter ikke automatisk til en annen agent etter en feil. Et slikt bytte kan endre kostnad, modell, tillatelsesmodell og filer. Feilen skal forklares tydelig, og brukeren kan starte et nytt oppdrag med en annen agent.

## Profildokumenter

- [Codex](CODEX.md)
- [Claude Code](CLAUDE.md)
- [Antigravity](ANTIGRAVITY.md)
- [OpenCode](OPENCODE.md)
- [Cline](CLINE.md)
- [Aider](AIDER.md)
