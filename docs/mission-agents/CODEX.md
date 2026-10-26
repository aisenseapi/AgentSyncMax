# Codex Mission-profil

Sist verifisert: 30. august 2026.

Status: Verifisert med lokal CLI og reell smoketest.

## Installert variant

- Versjon: `codex-cli 0.151.0-alpha.7.2`
- Distribusjon: CLI-en som følger den lokale OpenAI Codex-installasjonen
- Kjørbar fil: finnes dynamisk under Codex-appens versjonerte `bin`-mappe

Den versjonerte undermappen kan endres ved appoppdatering. AgentSync finner derfor den aktuelle kjørbare filen ved oppstart og lagrer ikke denne hash-baserte banen i konfigurasjonen.

## AgentSync-kommando

```text
codex exec
  --cd <prosjektmappe>
  --approve-for-me
  --skip-git-repo-check
  --json
  -
```

Hele prompten skrives til stdin. `-` gjør eksplisitt at stdin er prompten. Dette unngår Windows-grensen for lange kommandolinjer og problemer med linjeskift.

## Kritisk flaggkonflikt

Denne installerte CLI-en beskriver `--approve-for-me` som automatisk review med `workspace-write`-sandkasse. Derfor skal AgentSync ikke også sende `--sandbox workspace-write`.

Følgende kombinasjon er ugyldig i versjon 0.151.0-alpha.7.2:

```text
--sandbox workspace-write --approve-for-me
```

CLI-en avslutter da før modellen starter:

```text
error: the argument '--sandbox <SANDBOX_MODE>' cannot be used with '--approve-for-me'
```

AgentSync har en kodeinvariant og en enhetstest som avviser denne kombinasjonen før prosessstart.

## Offisiell dokumentasjon og lokal variant

Den offentlige dokumentasjonen anbefaler `codex exec --sandbox workspace-write` for automatisering som skal kunne redigere prosjektet. Den lokale Codex-appvarianten har i tillegg `--approve-for-me`. AgentSync følger den installerte CLI-kontrakten fordi den er smalere og ble bevist med reell kjøring.

`--skip-git-repo-check` er nødvendig fordi AgentSync også støtter prosjektmapper uten Git. `--json` gir en JSONL-strøm med blant annet `thread.started`, `turn.started`, `item.*` og `turn.completed`.

## Verifikasjon

Testprofil:

```text
codex exec --cd <tom testmappe> --approve-for-me --skip-git-repo-check --json -
```

Resultat 30. august 2026:

- Exit code: `0`
- Sluttmelding: `AGENTSYNC_CODEX_OK`
- Opprettede prosjektfiler: `0`
- Testmappen var tom etter kjøringen

## Failover og feil

- Feil i CLI-profilen skal stoppe før modellen startes.
- AgentSync skal ikke automatisk bytte fra Codex til en annen agent.
- Automatisk review er ikke det samme som full tilgang. Codex beholder sandkasse, filsystemgrenser og nettverksgrenser.

## Kilder

- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Codex CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
- [Codex Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review)
- Lokal `codex exec --help`, versjon 0.151.0-alpha.7.2
