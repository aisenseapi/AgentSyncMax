# Claude Code Mission-profil

Sist verifisert: 30. august 2026.

Status: CLI-kontrakten er verifisert. En live Mission-test kunne ikke kjøres fordi Claude CLI ikke var innlogget ved kontrollen.

## Installert variant

- Versjon: `2.1.251 (Claude Code)`
- Kjørbar fil: native `claude.exe` i brukerens lokale bin-mappe
- Innloggingskontroll: `claude auth status`

AgentSync markerer Claude som utilgjengelig når `loggedIn` er `false`, og viser at `claude auth login` må kjøres. Den starter ikke et oppdrag som med sikkerhet vil feile på autentisering.

## AgentSync-kommando

```text
claude
  -p
  --verbose
  --output-format stream-json
  --permission-mode acceptEdits
```

Prompten sendes som vanlig tekst på stdin og ligger ikke i argumentlisten. `-p` aktiverer ikke-interaktiv print-modus. `stream-json` gir hendelser som kan vises løpende i Mission Control.

## Tillatelser

`acceptEdits` tillater filredigeringer uten at hver redigering må bekreftes. Det er ikke det samme som `--dangerously-skip-permissions`. Shellkommandoer, nettverk og øvrige verktøy følger fortsatt Claude Code sine aktive tillatelsesregler.

AgentSync bruker ikke `--dangerously-skip-permissions` for Claude. Hvis en nødvendig handling blir avvist i headless-modus, skal missionen markeres som feilet med den faktiske tillatelsesfeilen.

## Utdata og kjente avhengigheter

- `--output-format stream-json` krever print-modus.
- `--verbose` gjør at komplette stream-hendelser blir tilgjengelige i denne CLI-varianten.
- Prompten kan inneholde linjeskift uten Windows-escaping fordi den sendes via stdin.
- AgentSync setter ikke `--no-session-persistence`; native Claude-historikk skal fortsatt kunne synkes.

## Modell-failover

Claude Code har et dokumentert `--fallback-model` for print-modus når primærmodellen er overbelastet. AgentSync setter ikke dette automatisk fordi fallback-modellen må være et bevisst bruker- eller konfigurasjonsvalg. En fremtidig AgentSync-innstilling kan eksponere dette eksplisitt.

## Verifikasjon

- Lokal `--version`: bestått
- Lokal `--help`: alle brukte flagg finnes
- Lokal auth-status: ikke innlogget ved kontrolltidspunktet
- Reell modellkjøring: ikke utført, og derfor ikke feilaktig merket som bestått

## Kilder

- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- Lokal `claude --help`, versjon 2.1.251
- Lokal `claude auth status`
