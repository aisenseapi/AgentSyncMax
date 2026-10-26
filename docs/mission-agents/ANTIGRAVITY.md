# Antigravity Mission-profil

Sist verifisert: 30. august 2026.

Status: Verifisert med lokal CLI, offisiell headless-dokumentasjon og fullførte AgentSync-missions.

## Installert variant

- Kommando: `agy`
- Versjon: `1.1.22`
- Distribusjon: Google Antigravity CLI for Windows

## AgentSync-kommando

```text
agy
  --mode accept-edits
  --input-format stream-json
  --output-format stream-json
  --sandbox
  --dangerously-skip-permissions
```

Prompten sendes som én NDJSON-linje på stdin:

```json
{"event":"user","message":{"content":"<oppdrag>"}}
```

`--print` skal ikke brukes i denne streamingprofilen. I Antigravity CLI 1.1.22 tar flagget neste kommandolinjeelement som prompt. Kombinasjonen `--print --mode ...` gjør derfor at `--mode` blir tolket som prompt og at CLI-en avslutter med exit code 2 før modellen starter.

## Hvorfor begge stream-flagg er nødvendige

Antigravity dokumenterer at `--input-format stream-json` krever `--output-format stream-json`. Streamingprosessen leser hele turns fra stdin og leverer en `result`-hendelse per turn. AgentSync lukker stdin etter den ene mission-prompten, slik at prosessen kan avslutte.

Profilkontrollen krever dette paret. En senere endring kan derfor ikke ved et uhell kombinere stream-inndata med `json` eller `text`-utdata.

## Tillatelser og sandkasse

`--dangerously-skip-permissions` auto-godkjenner verktøyforespørsler. Dette brukes fordi en headless Mission ikke har et interaktivt tillatelsesvindu. Samtidig aktiverer `--sandbox` Antigravity sin terminalbegrensning, og Mission-prompten forbyr commit, push og endringer i `.agent-state`.

Navnet på tillatelsesflagget er med vilje tydelig. Det skal ikke skjules i dokumentasjonen eller forveksles med full operativsystemtilgang.

## Utdata

Den offisielle strømkontrakten starter med `init`, fortsetter med `step_update` og avslutter med `result`. `result.status` kan blant annet være `SUCCESS`, `ERROR`, `CANCELED`, `INTERRUPTED`, `INVALID` eller `WAITING`.

AgentSync leser hendelsene mens prosessen kjører og bruker terminalhendelsen som sluttresultat.

## Verifikasjon

- Lokal `agy --version`: 1.1.22
- Lokal `agy --help`: alle brukte flagg finnes
- Ekte streaming-smoketest uten `--print`: exit code 0, `result.status: SUCCESS` og forventet slutttekst
- Historikk ved kontroll: tre fullførte og én feilet Antigravity-mission
- Fullførte missions beviser at samlet streaming-, sandbox- og tillatelsesprofil kan kjøre i ekte prosjektmapper

## Failover

Antigravity har modellvalg, men AgentSync velger ikke en ukjent reservemodell automatisk. Ikke-null exit og `result.error` skal vises. Brukeren kan deretter starte på nytt med ønsket agent eller modell.

## Kilder

- [Google Antigravity headless mode](https://antigravity.google/docs/cli/headless/)
- [Offisiell Antigravity CLI-kilde](https://github.com/google-antigravity/antigravity-cli)
- Lokal `agy --help`, versjon 1.1.22
