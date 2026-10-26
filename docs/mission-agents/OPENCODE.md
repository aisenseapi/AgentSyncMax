# OpenCode Mission-profil

Sist verifisert: 30. august 2026.

Status: Verifisert med lokal CLI, offisiell dokumentasjon, smoketest og fullførte AgentSync-missions.

## Installert variant

- Versjon: `1.18.23`
- Kjørbar fil: native `opencode.exe` i OpenCode sin lokale bin-mappe

## AgentSync-kommando

```text
opencode run
  --format json
  --dir <prosjektmappe>
  --auto
```

Prompten sendes på stdin. Den installerte versjonen aksepterer denne transporten, og AgentSync unngår dermed lange og flerlinjede Windows-argumenter.

## Tillatelser

OpenCode beskriver `--auto` som automatisk godkjenning av tillatelser som ikke er eksplisitt avvist. Flagget er nødvendig når et headless kodeoppdrag skal kunne redigere filer uten et interaktivt tillatelsesvindu.

Dette er et kraftig valg. AgentSync begrenser konsekvensene med valgt prosjektmappe, Mission-instruksen, Git-diff eller checkpoint, og ved å forby commit og push. OpenCode sine eksplisitte deny-regler gjelder fortsatt.

## Utdata

`--format json` gir rå JSON-hendelser. Faktisk smoketest leverte `step_start`, `text` og `step_finish`, med token- og kostnadsmetadata i slutthendelsen.

## Verifikasjon

Smoketestprofil:

```text
opencode run --format json --dir <tom testmappe> --auto
```

Resultat 30. august 2026:

- Prompt via stdin: bestått
- Exit code: `0`
- Sluttmelding: `AGENTSYNC_OPENCODE_OK`
- Kostnad rapportert av CLI: `0`
- Opprettede prosjektfiler: `0`

AgentSync-historikken hadde ved samme kontroll ni fullførte OpenCode-missions og én eldre feil. En eldre permission-feil er grunnen til at den dokumenterte `--auto`-profilen nå brukes.

## Git og prosjektmappe

`--dir` peker OpenCode direkte på valgt mappe. AgentSync legger ikke inn et Git-krav. Git-prosjekter kontrolleres med Git-diff, mens mapper uten Git kontrolleres med AgentSync-checkpoint.

## Failover

AgentSync bruker ikke automatisk en annen OpenCode-provider eller modell. Provider, modell, kostnad og tillatelser kan være forskjellige. Feilen skal vises, og et eventuelt nytt agentvalg gjøres eksplisitt.

## Kilder

- [OpenCode CLI documentation](https://dev.opencode.ai/docs/cli)
- Lokal `opencode run --help`, versjon 1.18.23
- Lokal AgentSync-smoketest 30. august 2026
